//
//  PushSubscriptionStore.swift
//  CommonPlateios
//
// The one state owner for CommonPlate push-notification preference (Week 3
// Day 6 Slice 6A.2). Coordinates installation identity, Apple's notification
// permission, APNs device-token registration, and backend synchronization
// through `InstallationPushService`.
//
// Deliberately separate from `AlertSubscriptionStore` and `RequestStore`: per
// the Week 3 Day 6 cross-slice contract, email alerts and push notifications
// are independent controls with no shared state, error semantics, or backend
// endpoint. This sends no notification and never touches email state.
//
// `state` is truthful by construction. It becomes `.on` only after Apple
// permission allows notifications, an APNs token was received, and the
// backend confirmed `enabled: true` — never optimistically. Turning push off
// follows the same rule in reverse: `.off` is shown only after the backend
// confirms `enabled: false`, and a failed disable preserves the last
// confirmed `.on` state rather than claiming delivery stopped.
import Combine
import Foundation
import UserNotifications

/// What the push control shows. Internal state names only — user-facing copy
/// belongs to the view, exactly like `AlertSignupPhase`/`AlertSignupFailure`.
enum PushPreferenceState: Equatable {
    case off
    case settingUp
    case on
    case denied
    case failed
}

enum PushSyncFailure: Equatable {
    case couldNotEnable
    case couldNotDisable
}

@MainActor
final class PushSubscriptionStore: ObservableObject {
    @Published private(set) var state: PushPreferenceState
    @Published private(set) var failure: PushSyncFailure?

    private let service: InstallationPushService
    private let installationStorage: PushInstallationStorage
    private let authorizationCoordinator: PushAuthorizationCoordinator
    private let remoteNotificationRegistrar: RemoteNotificationRegistering
    private let settingsOpener: PushSettingsOpener
    private let registrationTimeout: Duration

    /// How long a Settings-recovery intent stays actionable after `Open
    /// Settings` is tapped. Bounds the accepted "return shortly after
    /// enabling permission" flow: a person who abandons that Settings visit
    /// and only grants permission much later — through this flow or any
    /// unrelated one — must take a fresh explicit in-app action rather than
    /// have CommonPlate silently enable push on some later, unconnected app
    /// open. A defensive implementation boundary around the already-accepted
    /// Settings excursion, not a notification-delivery guarantee.
    static let settingsRecoveryIntentLifetime: TimeInterval = 10 * 60

    /// Every dependency is injected with no default, matching
    /// `AlertSubscriptionStore`: no caller — and no test — can reach the
    /// developer's real `UserDefaults` or Apple's real notification system by
    /// omission.
    init(
        service: InstallationPushService,
        installationStorage: PushInstallationStorage,
        authorizationCoordinator: PushAuthorizationCoordinator,
        remoteNotificationRegistrar: RemoteNotificationRegistering,
        settingsOpener: PushSettingsOpener,
        registrationTimeout: Duration = .seconds(20)
    ) {
        self.service = service
        self.installationStorage = installationStorage
        self.authorizationCoordinator = authorizationCoordinator
        self.remoteNotificationRegistrar = remoteNotificationRegistrar
        self.settingsOpener = settingsOpener
        self.registrationTimeout = registrationTimeout

        // A previously confirmed installation starts in a checking state
        // rather than claiming `.on` before this launch has reconfirmed it —
        // and rather than showing `.off` and flashing back to `.on` a moment
        // later. `refreshAuthorizationStatus()` resolves this on first
        // appearance; nothing here starts async work from `init` itself.
        self.state = installationStorage.lastConfirmedPushEnabled == true ? .settingUp : .off
    }

    var isBusy: Bool {
        state == .settingUp
    }

    // MARK: - Permission lifecycle

    /// Called when the push control first appears and whenever the app or
    /// that screen becomes active again — never on launch alone, and never
    /// from a background timer. This is also what dismissing the CommonPlate
    /// explanation (`Not now`, navigating back) ultimately runs into: nothing
    /// calls this store when the explanation is merely shown or dismissed —
    /// so the guarantee that a bare denied read is never acted on without a
    /// pending recovery intent is what keeps that dismissal from ever landing
    /// on the Settings-recovery card by accident, however many times the
    /// screen reappears.
    func refreshAuthorizationStatus(now: Date = Date()) async {
        let status = await authorizationCoordinator.currentAuthorizationStatus()

        switch status {
        case .denied:
            if hasFreshRecoveryIntent(now: now) {
                // Sent to Settings, still denied on return, and within the
                // accepted recovery window: stay in recovery and wait for a
                // later activation to try again. Left in place (not
                // consumed) so that later activation can still find it.
                if state != .denied { state = .denied }
                return
            }
            if installationStorage.lastConfirmedPushEnabled == true {
                // A previously-on installation whose permission was revoked
                // is proactively surfaced and reconciled toward the backend,
                // regardless of whether anyone asked — this is genuine news.
                if state != .denied { state = .denied }
                await reconcileRevokedPermissionIfNeeded()
                return
            }
            // Never confirmed on, and nobody asked CommonPlate to act on
            // Apple's permission right now. A bare denied read here is not
            // itself news: treating it as such would show the recovery card
            // for an ordinary screen visit, or for dismissing the
            // explanation, exactly as if the person had gone through
            // `Open Settings` when they never did. Preserve whatever the
            // last backend-confirmed state was.
            return
        case .authorized, .provisional, .ephemeral:
            if hasFreshRecoveryIntent(now: now) {
                // Consumed before starting the async work below, so a
                // repeated foreground event during setup — or a second
                // activation after this one already began — can never start
                // a duplicate recovery attempt from the same intent.
                consumeRecoveryIntent()
                await registerAndSynchronize(requestingPermission: false)
            } else if installationStorage.lastConfirmedPushEnabled == true, state != .on {
                await registerAndSynchronize(requestingPermission: false)
            } else if state == .denied {
                // Permission was restored outside any recovery this store
                // initiated, and this installation was never confirmed on:
                // wait for an explicit enable rather than turning push on
                // unasked.
                state = .off
            }
        case .notDetermined:
            consumeRecoveryIntent()
            if state == .denied || state == .failed {
                state = .off
            }
        @unknown default:
            // Conservative: an authorization status this code does not
            // recognize must not be treated as fully enabled. Only surface
            // it, though, under the same conditions a genuine denial would.
            if hasFreshRecoveryIntent(now: now) || installationStorage.lastConfirmedPushEnabled == true {
                if state != .denied { state = .denied }
            }
        }
    }

    // MARK: - Enabling

    /// Called only after the person taps `Enable notifications` in the
    /// CommonPlate explanation — never automatically, and never from
    /// `.denied` (that state's only recovery action is `openSystemSettings`).
    func enableAfterExplanation() async {
        guard state == .off || state == .failed else { return }
        await registerAndSynchronize(requestingPermission: true)
    }

    private func registerAndSynchronize(requestingPermission: Bool) async {
        failure = nil
        state = .settingUp

        if requestingPermission {
            let status = await authorizationCoordinator.currentAuthorizationStatus()
            switch status {
            case .notDetermined:
                let granted: Bool
                do {
                    granted = try await authorizationCoordinator.requestAuthorization()
                } catch {
                    state = .failed
                    failure = .couldNotEnable
                    return
                }
                guard granted else {
                    state = .denied
                    return
                }
            case .denied:
                state = .denied
                return
            case .authorized, .provisional, .ephemeral:
                // Permission was already granted from an earlier launch or
                // Settings visit; no second system prompt is possible or
                // needed.
                break
            @unknown default:
                state = .denied
                return
            }
        }

        let token: String
        do {
            token = try await remoteNotificationRegistrar.registerAndAwaitToken(timeout: registrationTimeout)
        } catch {
            state = .failed
            failure = .couldNotEnable
            return
        }

        let credential = installationStorage.installationCredential()
        do {
            let confirmedEnabled = try await service.synchronizeEnabled(
                credential: credential,
                apnsToken: token,
                environment: .current
            )
            installationStorage.recordConfirmedPushEnabled(confirmedEnabled)
            state = confirmedEnabled ? .on : .off
        } catch {
            state = .failed
            failure = .couldNotEnable
        }
    }

    // MARK: - Disabling

    /// Explicit user action only. Never optimistic: `.off` is shown only
    /// after the backend confirms it, and a failed attempt preserves the
    /// last confirmed `.on` state rather than claiming delivery stopped.
    func disable() async {
        guard state == .on else { return }
        failure = nil
        state = .settingUp

        let credential = installationStorage.installationCredential()
        do {
            let confirmedEnabled = try await service.synchronizeDisabled(credential: credential)
            installationStorage.recordConfirmedPushEnabled(confirmedEnabled)
            state = confirmedEnabled ? .on : .off
        } catch {
            state = .on
            failure = .couldNotDisable
        }
    }

    // MARK: - Recovery

    /// Never invoked except by an explicit `Open Settings` tap. Records the
    /// pending recovery intent's start time first, so a permission change
    /// picked up on a later activation within `settingsRecoveryIntentLifetime`
    /// — even after this process was suspended and relaunched while Settings
    /// was open — completes registration automatically instead of silently
    /// doing nothing.
    func openSystemSettings(now: Date = Date()) {
        guard state == .denied else { return }
        installationStorage.setSettingsRecoveryIntentStartedAt(now)
        settingsOpener.openSettings()
    }

    /// Whether a Settings-recovery intent is currently pending and still
    /// within its accepted lifetime. A stale intent — none exists, the
    /// stored value cannot be read as a `Date`, its start time is in the
    /// future, or more than `settingsRecoveryIntentLifetime` has elapsed —
    /// is cleared here as a side effect, so it never lingers to be found
    /// fresh by mistake on some later, unconnected check.
    private func hasFreshRecoveryIntent(now: Date) -> Bool {
        guard let startedAt = installationStorage.settingsRecoveryIntentStartedAt else {
            return false
        }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed >= 0, elapsed <= Self.settingsRecoveryIntentLifetime else {
            installationStorage.setSettingsRecoveryIntentStartedAt(nil)
            return false
        }
        return true
    }

    /// The one place a pending recovery intent is cleared because it was
    /// actually acted on (or because permission returned to
    /// `.notDetermined`, which invalidates it) — as opposed to
    /// `hasFreshRecoveryIntent`'s clearing of a merely stale one. Called
    /// before starting the async registration work it authorizes, so a
    /// repeated foreground event cannot consume — and act on — the same
    /// intent twice.
    private func consumeRecoveryIntent() {
        installationStorage.setSettingsRecoveryIntentStartedAt(nil)
    }

    /// A revoked permission must not silently leave the backend believing
    /// push is still enabled. A failed reconciliation attempt here is not
    /// itself reported to the person; it is retried the next time
    /// `refreshAuthorizationStatus()` runs — the next app activation or
    /// screen visit — rather than through a background worker.
    private func reconcileRevokedPermissionIfNeeded() async {
        guard installationStorage.lastConfirmedPushEnabled != false else { return }
        let credential = installationStorage.installationCredential()
        do {
            let confirmedEnabled = try await service.synchronizeDisabled(credential: credential)
            installationStorage.recordConfirmedPushEnabled(confirmedEnabled)
        } catch {
            // Left for the next bounded lifecycle opportunity; see above.
        }
    }
}
