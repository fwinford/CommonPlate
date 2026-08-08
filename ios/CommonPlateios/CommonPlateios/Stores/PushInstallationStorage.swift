//
//  PushInstallationStorage.swift
//  CommonPlateios
//
// Local identity and reconciliation state for push (Week 3 Day 6 Slice 6A).
//
// Two things live here, in ordinary app-local `UserDefaults` and nothing
// else: an opaque installation credential, generated once and reused for the
// lifetime of this app installation, and the push-enabled state this
// installation last had *confirmed by the backend*. Neither is a person,
// account, login, or email identity, and neither is written to the Keychain —
// reinstalling the app must produce a new installation, which a Keychain
// value can survive and a `UserDefaults` value cannot.
//
// The credential proves only continuity of calls from this installation. The
// confirmed-enabled flag is presentation/reconciliation state, not
// independent backend truth: it is set only after a successful
// synchronization call, exactly like `AlertSignupPresentationStorage`'s
// record is written only after a confirmed accepted response.
import Foundation

protocol PushInstallationStorage {
    /// Returns this installation's credential, generating and persisting one
    /// on first access if none exists yet. Stable for the app installation's
    /// lifetime; deleting and reinstalling the app removes it.
    func installationCredential() -> String

    /// The push-enabled state last confirmed by the backend, or `nil` if this
    /// installation has never completed a synchronization call.
    var lastConfirmedPushEnabled: Bool? { get }

    /// Records the backend's confirmed state after a successful
    /// synchronization. The only writer of this value.
    func recordConfirmedPushEnabled(_ enabled: Bool)

    /// The moment CommonPlate most recently opened Settings for permission
    /// recovery, or `nil` while no recovery is pending. Set the instant
    /// `Open Settings` is tapped, cleared once that flow resolves (success
    /// or failure), once permission reads `.notDetermined` again, or once
    /// `PushSubscriptionStore` finds it older than its accepted recovery
    /// lifetime. This storage layer has no time-based logic of its own — it
    /// only records and returns the timestamp; `PushSubscriptionStore` is
    /// the sole judge of freshness. This is the one signal that distinguishes
    /// an ordinary screen visit, which must never treat a bare denied read as
    /// something to act on, from an actual pending recovery, where a
    /// permission change should be picked up automatically. Persisted
    /// because going to Settings and back — and the recovery window itself —
    /// are not guaranteed to keep the process alive in memory.
    var settingsRecoveryIntentStartedAt: Date? { get }

    func setSettingsRecoveryIntentStartedAt(_ date: Date?)
}

/// `UserDefaults`-backed storage, matching
/// `UserDefaultsAlertSignupPresentationStorage`: the app has no other
/// preference mechanism to reuse, and neither value here is a secret in the
/// sense the Keychain exists for.
struct UserDefaultsPushInstallationStorage: PushInstallationStorage {
    private static let credentialKey = "com.commonplate.push.installationCredential"
    private static let confirmedEnabledKey = "com.commonplate.push.lastConfirmedEnabled"
    private static let settingsRecoveryIntentStartedAtKey = "com.commonplate.push.settingsRecoveryIntentStartedAt"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func installationCredential() -> String {
        if let existing = defaults.string(forKey: Self.credentialKey) {
            return existing
        }
        let generated = InstallationCredentialGenerator.generate()
        defaults.set(generated, forKey: Self.credentialKey)
        return generated
    }

    var lastConfirmedPushEnabled: Bool? {
        // `UserDefaults.bool(forKey:)` returns `false` for an absent key, so
        // presence is checked separately: "never synchronized" and
        // "confirmed off" must not collapse into the same value.
        guard defaults.object(forKey: Self.confirmedEnabledKey) != nil else {
            return nil
        }
        return defaults.bool(forKey: Self.confirmedEnabledKey)
    }

    func recordConfirmedPushEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.confirmedEnabledKey)
    }

    // An absent key, or a value that was somehow stored as something other
    // than a `Date`, both correctly read as `nil` — "no recovery pending" —
    // through the same `as?` cast, with no separate malformed-state handling
    // needed.
    var settingsRecoveryIntentStartedAt: Date? {
        defaults.object(forKey: Self.settingsRecoveryIntentStartedAtKey) as? Date
    }

    func setSettingsRecoveryIntentStartedAt(_ date: Date?) {
        guard let date else {
            defaults.removeObject(forKey: Self.settingsRecoveryIntentStartedAtKey)
            return
        }
        defaults.set(date, forKey: Self.settingsRecoveryIntentStartedAtKey)
    }
}

/// Cryptographically random credential generation, shared by whichever
/// storage implementation needs to mint one. `src/installationCredential.ts`
/// is this value's backend counterpart: 32 random bytes, base64url-encoded,
/// no padding.
enum InstallationCredentialGenerator {
    static let byteCount = 32

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        // `errSecSuccess` is effectively guaranteed on-device; a failure here
        // would mean the platform's secure random source itself is
        // unavailable, which nothing in this app can meaningfully recover
        // from.
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed unexpectedly")
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    /// Standard base64, remapped to the unpadded URL-safe alphabet the
    /// backend's `isValidRawInstallationCredential` expects.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
