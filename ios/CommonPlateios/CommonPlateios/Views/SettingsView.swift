//
//  SettingsView.swift
//  CommonPlateios
//
// W4-H2's one shared secondary utility route (Section 11), reached from
// Home's gear. Presentation architecture only: identity, Request Alerts, and
// About & Help behavior are all unchanged accepted runtime, relocated here
// from R1's Home-inline utility group rather than reimplemented.
import SwiftUI

struct SettingsView: View {
    @ObservedObject var requestStore: RequestStore
    @ObservedObject var participantIdentityStore: ParticipantIdentityStore
    @ObservedObject var alertSubscriptionStore: AlertSubscriptionStore
    @ObservedObject var pushSubscriptionStore: PushSubscriptionStore
    @ObservedObject var unsubscribeStore: ParticipantEmailUnsubscribeStore
    /// The one W4-N0 authoritative source for the Email toggle's On/Off
    /// presentation (Section 4/approved Figma `Control / Toggle`). Never
    /// `alertSubscriptionStore.phase`, Check Email presentation history, or a
    /// remembered signup submission.
    @ObservedObject var emailAlertStateStore: EmailAlertStateStore
    /// W4-S1's app-level AI Assistance Settings control. Off prevents any
    /// screenshot selection from starting a new transfer, and cancels/fences
    /// a pending one that has not yet actually begun transfer; it cannot
    /// recall bytes a transfer had already genuinely started sending, but
    /// generation/cancellation fencing guarantees that transfer's response
    /// is never applied. On only restores availability for a later
    /// selection — the separate first-use disclosure gate is unaffected by
    /// this toggle and still governs every actual transfer.
    @ObservedObject var screenshotProposalStore: ScreenshotProposalStore

    /// W3-I4: open only between tapping Remove Email and the mutation
    /// actually running. Cancel (or dismissing any other way) leaves
    /// `participantIdentityStore` untouched — the confirmation dialog itself
    /// has no side effect, only its destructive button does. Relocated
    /// verbatim from `ContentView`, which owned this identically before H2.
    @State private var isPresentingRemoveEmailConfirmation = false

    /// HQ decision 4: the compact Request Alerts row opens the same focused
    /// centered overlay Empty Exchange's quick entry already uses (Section
    /// 12), reusing that presentation rather than expanding a second copy of
    /// setup UI inline in Settings. This creates no new/permanent Settings
    /// navigation destination — it is the identical overlay-over-the-current-
    /// screen pattern `HomeExchangeView` already uses for its own quick
    /// entry.
    @State private var isPresentingRequestAlerts = false

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xl) {
                    identitySection
                    requestAlertsSection
                    aiAssistanceSection
                    aboutAndHelpSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, CommonPlateStyle.Metrics.settingsPageInset)
                .padding(.vertical, CommonPlateStyle.Spacing.l)
            }
            .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
            .navigationTitle("Settings")
            .task {
                await emailAlertStateStore.refresh()
            }
            // Review triage (finding 6): Change Email replacing the
            // authoritative identity while this screen stays mounted must
            // still reconcile the Email toggle for the new participant —
            // the initial `.task` above only ever ran once, for whichever
            // identity was current when Settings first appeared. Reuses the
            // same reconciliation call the Off-mutation and Request Alerts
            // overlay-dismissal boundaries already use; no new N0 read path.
            .onChange(of: participantIdentityStore.identity) { _, _ in
                Task { await emailAlertStateStore.refresh() }
            }

            if isPresentingRequestAlerts {
                RequestAlertsOverlayView(
                    identityStore: participantIdentityStore,
                    alertSubscriptionStore: alertSubscriptionStore,
                    pushSubscriptionStore: pushSubscriptionStore,
                    unsubscribeStore: unsubscribeStore,
                    onDismiss: {
                        isPresentingRequestAlerts = false
                        // Reconcile the Email toggle against N0 truth as soon
                        // as the focused setup presentation closes, rather
                        // than waiting for this screen to be left and
                        // reopened — the toggle itself never assumes the
                        // attempt succeeded.
                        Task { await emailAlertStateStore.refresh() }
                    }
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isPresentingRequestAlerts)
        // W3-I4: Cancel is the dialog's implicit dismissal path too — only
        // the destructive button below has any effect on
        // `participantIdentityStore`.
        .confirmationDialog(
            Self.removeEmailConfirmationTitle,
            isPresented: $isPresentingRemoveEmailConfirmation,
            titleVisibility: .visible
        ) {
            Button(Self.removeEmailTitle, role: .destructive) {
                participantIdentityStore.removeIdentity()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.removeEmailConfirmationMessage)
        }
    }

    // MARK: - Identity

    @ViewBuilder
    private var identitySection: some View {
        if let identity = participantIdentityStore.identity {
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
                sectionHeading("IDENTITY")

                // Figma's approved compact identity treatment sits flat on
                // the page, not inside a grouped warm-surface card — see
                // the warm-surface token's own documented intent in
                // CommonPlateStyle.swift ("native identity/settings
                // sections intentionally do not use this treatment").
                VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
                    Label(identity.masked, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .accessibilityIdentifier("settings-verified-identity")
                    Text("Verified NYU email")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    ViewThatFits(in: .horizontal) {
                        identityActions(axis: .horizontal)
                        identityActions(axis: .vertical)
                    }

                    if isRemoveEmailBlocked {
                        CommonPlateInlineStatus(
                            kind: removeEmailBlockedStatusKind,
                            message: removeEmailBlockedNotice
                        )
                        .accessibilityIdentifier("settings-remove-email-blocked-notice")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, CommonPlateStyle.Metrics.settingsRowInset)
            }
        }
    }

    @ViewBuilder
    private func identityActions(axis: Axis) -> some View {
        if axis == .horizontal {
            HStack {
                changeEmailButton
                Spacer()
                removeEmailButton
            }
        } else {
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
                changeEmailButton
                removeEmailButton
            }
        }
    }

    private var changeEmailButton: some View {
        Button(Self.changeEmailTitle) {
            participantIdentityStore.beginEmailReplacement()
        }
        .commonPlateTertiaryAction()
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityIdentifier("settings-change-email")
    }

    private var removeEmailButton: some View {
        Button(Self.removeEmailTitle, role: .destructive) {
            isPresentingRemoveEmailConfirmation = true
        }
        .commonPlateDestructiveAction()
        .disabled(isRemoveEmailBlocked)
        .accessibilityIdentifier("settings-remove-email")
    }

    static let changeEmailTitle = "Change Email"
    static let removeEmailTitle = "Remove Email"
    static let removeEmailConfirmationTitle = "Remove this email?"
    static let removeEmailConfirmationMessage =
        "You’ll need to verify an NYU email again before posting or helping with a request. Your request and help history is not affected."
    static let removeEmailNotYetAvailableNotice =
        "Checking whether your email can be removed. Try again in a moment."
    static let removeEmailUnavailableNotice =
        "Remove Email is temporarily unavailable."
    static let removeEmailBlockedByReservationNotice =
        "You can’t remove your email while you have an active reservation or an in-progress request. Finish or release that first."
    static let removeEmailBlockedByPendingCreateNotice =
        "CommonPlate is still confirming a request you submitted. You can remove your email once that finishes."

    /// Identical precedence to `ContentView`'s pre-H2 implementation (W3-I4):
    /// the cold/relaunch readiness check first, then an active
    /// reservation/in-progress request, then an unresolved create.
    private var isRemoveEmailBlocked: Bool {
        !requestStore.hasEstablishedRemovalSafety
            || requestStore.activeClaim != nil
            || requestStore.hasUnresolvedCreateAmbiguity
    }

    private var removeEmailBlockedNotice: String {
        if !requestStore.hasEstablishedRemovalSafety {
            return requestStore.isResolvingReservationStateForRemoval
                ? Self.removeEmailNotYetAvailableNotice
                : Self.removeEmailUnavailableNotice
        }
        if requestStore.activeClaim != nil {
            return Self.removeEmailBlockedByReservationNotice
        }
        return Self.removeEmailBlockedByPendingCreateNotice
    }

    private var removeEmailBlockedStatusKind: CommonPlateStatusKind {
        ContentView.removeEmailBlockedStatusKind(
            hasEstablishedRemovalSafety: requestStore.hasEstablishedRemovalSafety,
            isResolvingReservationStateForRemoval: requestStore.isResolvingReservationStateForRemoval,
            hasActiveClaim: requestStore.activeClaim != nil
        )
    }

    // MARK: - Request Alerts

    /// HQ decision 4 / final H2 visual alignment (supersedes both the prior
    /// "Request Alerts remains inline in Settings for later management"
    /// wording and the intermediate "Set up"/"Manage" compact-row copy).
    /// Settings presents Email and Push as the approved Figma `Control /
    /// Toggle` component: flat rows, no subtitle, no "Set up"/"Manage"/"Try
    /// again" row buttons. Tapping a row toward On opens the already-approved
    /// focused centered Request Alerts presentation (`RequestAlertsOverlayView`,
    /// Section 12) — the same overlay Empty Exchange's quick entry already
    /// uses — for setup/permission; it never fabricates On before the
    /// underlying channel truth actually confirms it. This creates no new/
    /// permanent Settings navigation destination for Request Alerts.
    private var requestAlertsSection: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
            sectionHeading("REQUEST ALERTS")

            if participantIdentityStore.isVerified {
                VStack(alignment: .leading, spacing: 0) {
                    requestAlertsToggleRow(
                        title: "Email",
                        isOn: emailToggleBinding,
                        isEnabled: Self.isEmailToggleInteractive(emailAlertStateStore.state),
                        accessibilityIdentifier: "settings-email-alerts-toggle"
                    )

                    if let emailUnknownStatusMessage {
                        CommonPlateInlineStatus(
                            kind: emailAlertStateStore.isRefreshing ? .loading : .uncertain,
                            message: emailUnknownStatusMessage
                        )
                        .padding(.horizontal, CommonPlateStyle.Metrics.settingsRowInset)
                        .padding(.bottom, CommonPlateStyle.Spacing.xs)
                        .accessibilityIdentifier("settings-email-alerts-status")
                    }

                    aboutAndHelpDivider

                    requestAlertsToggleRow(
                        title: "Push",
                        isOn: pushToggleBinding,
                        isEnabled: true,
                        accessibilityIdentifier: "settings-push-alerts-toggle"
                    )
                }
            } else {
                requestAlertsVerificationPrompt
            }
        }
    }

    /// Faith's resolution (simulator FIX, item 5), refined by HQ decision 7:
    /// an unverified participant is a *different* presentation cause than a
    /// genuine N0 read failure — `EmailAlertStateStore.state` reads
    /// `.unknown` for both because there is no participant authority to ask,
    /// but that is never shown as the generic "Email alert status
    /// unavailable" here. Neither toggle is rendered at all while unverified,
    /// since neither can claim real Email or Push truth yet.
    ///
    /// HQ decision 7 supersedes the prior passive-text-only treatment: Faith
    /// observed it did not visually read as actionable. This row now exposes
    /// an explicit `Verify NYU email` button — reusing the existing
    /// `commonPlateSecondaryAction()` style rather than a bare disclosure
    /// chevron or passive gray body text implying a permanent child
    /// destination — with supporting copy explaining the prerequisite above
    /// it. Tapping the button opens the same focused
    /// `RequestAlertsOverlayView` the toggles themselves open, which already
    /// owns the accepted verify → resume-attempted-setup continuation
    /// (`beginVerificationIfNeeded()` / `isPresentingVerification`) — no
    /// second verification path or new Settings destination is introduced
    /// here.
    private var requestAlertsVerificationPrompt: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
            Text(Self.requestAlertsVerificationPromptText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                isPresentingRequestAlerts = true
            } label: {
                Text(Self.verifyNYUEmailActionTitle)
            }
            .commonPlateSecondaryAction()
            .accessibilityIdentifier("settings-request-alerts-verify-action")
        }
        .padding(.horizontal, CommonPlateStyle.Metrics.settingsRowInset)
    }

    static let requestAlertsVerificationPromptText = "Required to manage request alerts."
    static let verifyNYUEmailActionTitle = "Verify NYU email"

    /// Faith's resolution for W4-N0 Unknown Email truth (final H2 visual
    /// alignment FIX, item 1): a disabled — never interactive — Off-looking
    /// toggle is not itself enough, because a viewer cannot distinguish "not
    /// yet established" from a truth claim of confirmed Off. This inline
    /// status, shown only while `emailAlertStateStore.state == .unknown`,
    /// makes that distinction explicit without inventing a third toggle
    /// visual state — the toggle itself stays the same approved binary
    /// Off/On glyph, just disabled. Copy distinguishes *why* truth is
    /// unavailable: a read still in flight reads as "Checking…", while a
    /// failed/unresolved read (including an unusable credential) reads as
    /// "unavailable" — reusing `CommonPlateStatusKind.loading`/`.uncertain`,
    /// the same accepted status vocabulary `removeEmailBlockedStatusKind`
    /// already uses elsewhere in this screen. Once N0 establishes `.active`
    /// or `.inactive`, this disappears and the toggle becomes the ordinary
    /// interactive On/Off control.
    private var emailUnknownStatusMessage: String? {
        Self.emailUnknownStatusMessage(
            state: emailAlertStateStore.state,
            isRefreshing: emailAlertStateStore.isRefreshing
        )
    }

    /// Extracted as a pure, directly testable mapping — see
    /// `SettingsRequestAlertsToggleTests`.
    static func emailUnknownStatusMessage(state: EmailAlertState, isRefreshing: Bool) -> String? {
        guard state == .unknown else { return nil }
        return isRefreshing ? Self.emailAlertsCheckingStatus : Self.emailAlertsUnavailableStatus
    }

    /// Extracted as a pure, directly testable mapping — see
    /// `SettingsRequestAlertsToggleTests`.
    static func isEmailToggleInteractive(_ state: EmailAlertState) -> Bool {
        state != .unknown
    }

    static let emailAlertsCheckingStatus = "Checking your email alert status…"
    static let emailAlertsUnavailableStatus = "Email alert status unavailable."

    private func requestAlertsToggleRow(
        title: String,
        isOn: Binding<Bool>,
        isEnabled: Bool,
        accessibilityIdentifier: String
    ) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .tint(Color.accentColor)
                .disabled(!isEnabled)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
        .frame(minHeight: CommonPlateStyle.Control.minimumHeight)
        .padding(.horizontal, CommonPlateStyle.Metrics.settingsRowInset)
    }

    /// Approved Figma `Control / Toggle` behavior, exactly: "Binary
    /// CommonPlate settings toggle. Visual states are Off and On
    /// only—there is intentionally no pending/halfway toggle state. Email
    /// Off→On may open a setup/confirmation flow, but the toggle remains
    /// visually Off until the existing Email subscription truth confirms it
    /// is actually enabled." The read side therefore consumes only the W4-N0
    /// authoritative `.active` truth — never `alertSubscriptionStore.phase`,
    /// Check Email presentation history, or a remembered signup submission —
    /// so `.unknown` (not yet read, unreadable, or a superseded identity) and
    /// `.inactive` both render identically Off, and never fabricate On.
    ///
    /// Turning the toggle On does not itself assert Email On: it opens the
    /// focused Request Alerts presentation, which owns the real signup/
    /// confirmation lifecycle unchanged. The toggle only reads On again once
    /// a later `emailAlertStateStore.refresh()` (this screen's own `.task`,
    /// or the overlay's own lifecycle) observes confirmed truth.
    ///
    /// Turning the toggle Off runs the existing accepted participant-
    /// authorized unsubscribe mutation (W3-N2) — the same action the
    /// focused overlay's "Turn off email alerts" button already performs —
    /// then reconciles N0 truth with a fresh `refresh()` so the toggle
    /// reflects the newly confirmed Off state rather than assuming it.
    /// Extracted as a pure, directly testable mapping — see
    /// `SettingsViewToggleSourceTests` — rather than only asserting on the
    /// view body.
    static func isEmailToggleOn(_ state: EmailAlertState) -> Bool {
        state == .active
    }

    /// Extracted as a pure, directly testable mapping — see
    /// `SettingsViewToggleSourceTests`.
    static func isPushToggleOn(_ state: PushPreferenceState) -> Bool {
        state == .on
    }

    private var emailToggleBinding: Binding<Bool> {
        Binding(
            get: { Self.isEmailToggleOn(emailAlertStateStore.state) },
            set: { newValue in
                if newValue {
                    isPresentingRequestAlerts = true
                } else {
                    Task {
                        await unsubscribeStore.turnOffEmailAlerts(
                            authority: participantIdentityStore.currentAuthority()
                        )
                        await emailAlertStateStore.refresh()
                    }
                }
            }
        )
    }

    /// Reads only the existing accepted authoritative Push truth
    /// (`PushSubscriptionStore.state == .on`); every other state
    /// (`.off`, `.settingUp`, `.denied`, `.failed`, `.ambiguous`) renders
    /// Off, matching the approved toggle's "Push appearance must likewise
    /// reflect the existing authoritative Push state rather than a local
    /// visual boolean." Turning the toggle On opens the same focused Request
    /// Alerts presentation, which already embeds the existing accepted Push
    /// explanation/permission/recovery flow (`PushNotificationSection`) —
    /// this row invents no separate setup path. Turning it Off from a
    /// confirmed On runs the existing accepted `disable()` mutation exactly
    /// as the overlay's own "Turn off" control already does.
    private var pushToggleBinding: Binding<Bool> {
        Binding(
            get: { Self.isPushToggleOn(pushSubscriptionStore.state) },
            set: { newValue in
                if newValue {
                    isPresentingRequestAlerts = true
                } else {
                    Task { await pushSubscriptionStore.disable() }
                }
            }
        )
    }

    // MARK: - AI Assistance

    /// W4-S1: a single app-level kill switch, independent of Request Alerts'
    /// Email/Push toggles above — it shares no state with them. Off disables
    /// `RequestFoodView`'s picker, retires the current screenshot selection
    /// in `ScreenshotProposalStore`, and cancels whatever transfer task that
    /// selection had (`ScreenshotProposalStore.setAIAssistanceEnabled`): work
    /// that has not yet started transfer is prevented from ever starting it.
    /// A transfer that had already genuinely begun before Off cannot be
    /// recalled — bytes already sent stay sent — but generation/cancellation
    /// fencing guarantees its response, whenever it arrives, can never be
    /// applied to the draft. It does not by itself grant or revoke the
    /// separate first-use third-party disclosure recorded the first time a
    /// screenshot is actually sent.
    private var aiAssistanceSection: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
            sectionHeading("AI FEATURES")

            // W4-R2: one named toggle, no permanent explanatory paragraph
            // (superseded `aiAssistanceExplanation`). The required first-use
            // third-party disclosure (`ScreenshotProposalDisclosureView`) is
            // unchanged and still shown at the actual invocation flow.
            requestAlertsToggleRow(
                title: "Screenshot Assistance",
                isOn: aiAssistanceToggleBinding,
                isEnabled: true,
                accessibilityIdentifier: "settings-ai-assistance-toggle"
            )
        }
    }

    private var aiAssistanceToggleBinding: Binding<Bool> {
        Binding(
            get: { screenshotProposalStore.isAIAssistanceEnabled },
            set: { newValue in
                screenshotProposalStore.setAIAssistanceEnabled(newValue)
            }
        )
    }

    // MARK: - About & Help

    /// The approved Figma's About & Help rows sit almost flush with the
    /// page — a near-canvas background separated only by hairline dividers
    /// — not a strongly tinted grouped card. `baseCanvas` (already the
    /// page's own background token) reads as that same quiet, neutral
    /// treatment without introducing a new color; the divider reuses
    /// `requestCardBorder`, which already matches the approved Figma's
    /// divider tone exactly.
    private var aboutAndHelpSection: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
            sectionHeading("ABOUT & HELP")

            VStack(spacing: 0) {
                NavigationLink(value: AppRoute.onboardingChooser) {
                    SettingsRow(title: "How CommonPlate Works")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-how-commonplate-works")

                aboutAndHelpDivider

                NavigationLink(value: AppRoute.privacySafety) {
                    SettingsRow(title: "Privacy & Safety")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-privacy-safety")

                aboutAndHelpDivider

                NavigationLink(value: AppRoute.support) {
                    SettingsRow(title: "Support")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-support")
            }
            .background(
                CommonPlateStyle.Color.baseCanvas,
                in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
            )
        }
    }

    private var aboutAndHelpDivider: some View {
        Rectangle()
            .fill(CommonPlateStyle.Color.requestCardBorder)
            .frame(height: 1)
            .padding(.horizontal, CommonPlateStyle.Metrics.settingsRowInset)
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// The approved Figma's About & Help rows carry no subtitle; `subtitle`
    /// stays optional so Request Alerts (which does) and About & Help (which
    /// no longer does) share one row component.
    private struct SettingsRow: View {
        let title: String
        var subtitle: String?

        var body: some View {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: CommonPlateStyle.Spacing.s)
                CommonPlateDisclosureIndicator()
            }
            .frame(minHeight: CommonPlateStyle.Control.minimumHeight)
            .padding(.horizontal, CommonPlateStyle.Metrics.settingsRowInset)
            .padding(.vertical, CommonPlateStyle.Spacing.s)
            .contentShape(Rectangle())
        }
    }
}
