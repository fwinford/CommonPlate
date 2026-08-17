//
//  SettingsRequestAlertsToggleTests.swift
//  CommonPlateiosTests
//
// Focused coverage for the W4-H2 FIX Settings Email/Push toggle source of
// truth: the approved Figma `Control / Toggle` is binary (Off/On only, no
// pending/halfway state), and the read side must consume only the W4-N0
// authoritative Email read and the existing accepted Push truth — never
// `AlertSubscriptionStore.phase`, Check Email presentation history, or a
// remembered signup submission. See `SettingsView.isEmailToggleOn` and
// `SettingsView.isPushToggleOn`.
import Foundation
import XCTest
@testable import CommonPlateios

final class SettingsRequestAlertsToggleTests: XCTestCase {
    // MARK: - Email toggle source (W4-N0 only)

    func testEmailToggleIsOnOnlyWhenN0ReportsActive() {
        XCTAssertTrue(SettingsView.isEmailToggleOn(.active))
    }

    func testEmailToggleIsOffWhenN0ReportsInactive() {
        XCTAssertFalse(SettingsView.isEmailToggleOn(.inactive))
    }

    /// The load-bearing "never fabricate On" guarantee: not-yet-read,
    /// unreadable, and a superseded-identity read all collapse to the same
    /// `.unknown` case, and none of them may render as On.
    func testEmailToggleIsOffWhenN0StateIsUnknown() {
        XCTAssertFalse(SettingsView.isEmailToggleOn(.unknown))
    }

    // MARK: - Push toggle source (existing accepted Push truth only)

    func testPushToggleIsOnOnlyWhenStablyOn() {
        XCTAssertTrue(SettingsView.isPushToggleOn(.on))
    }

    func testPushToggleIsOffForEveryNonStableOnState() {
        XCTAssertFalse(SettingsView.isPushToggleOn(.off))
        XCTAssertFalse(SettingsView.isPushToggleOn(.settingUp))
        XCTAssertFalse(SettingsView.isPushToggleOn(.denied))
        XCTAssertFalse(SettingsView.isPushToggleOn(.failed))
        XCTAssertFalse(SettingsView.isPushToggleOn(.ambiguous(desiredEnabled: true)))
        XCTAssertFalse(SettingsView.isPushToggleOn(.ambiguous(desiredEnabled: false)))
    }

    // MARK: - Email Unknown presentation (Faith's resolution, item 1)

    /// The toggle must never be interactive while N0 truth is Unknown — a
    /// disabled Off-looking switch, not an interactive one, is what keeps
    /// this from reading as a truth claim of confirmed Off.
    func testEmailToggleIsNotInteractiveWhileUnknown() {
        XCTAssertFalse(SettingsView.isEmailToggleInteractive(.unknown))
        XCTAssertTrue(SettingsView.isEmailToggleInteractive(.active))
        XCTAssertTrue(SettingsView.isEmailToggleInteractive(.inactive))
    }

    /// No inline status at all once truth is established either way — the
    /// status exists only to explain away an ambiguous-looking Off toggle.
    func testNoInlineStatusOnceTruthIsEstablished() {
        XCTAssertNil(SettingsView.emailUnknownStatusMessage(state: .active, isRefreshing: false))
        XCTAssertNil(SettingsView.emailUnknownStatusMessage(state: .inactive, isRefreshing: false))
        XCTAssertNil(SettingsView.emailUnknownStatusMessage(state: .inactive, isRefreshing: true))
    }

    func testInlineStatusReadsCheckingWhileARefreshForTheCurrentParticipantIsInFlight() {
        XCTAssertEqual(
            SettingsView.emailUnknownStatusMessage(state: .unknown, isRefreshing: true),
            SettingsView.emailAlertsCheckingStatus
        )
    }

    func testInlineStatusReadsUnavailableWhenUnknownAndNoRefreshIsInFlight() {
        XCTAssertEqual(
            SettingsView.emailUnknownStatusMessage(state: .unknown, isRefreshing: false),
            SettingsView.emailAlertsUnavailableStatus
        )
    }

    // MARK: - Refresh cue: no semantic release threshold (Faith's resolution, item 2)

    // MARK: - Unverified participant presentation (simulator FIX, item 5)

    func testRequestAlertsSectionBranchesOnParticipantVerification() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")

        XCTAssertTrue(source.contains("if participantIdentityStore.isVerified {"))
        XCTAssertTrue(source.contains("requestAlertsVerificationPrompt"))
        XCTAssertEqual(
            SettingsView.requestAlertsVerificationPromptText,
            "Required to manage request alerts."
        )
        XCTAssertEqual(SettingsView.verifyNYUEmailActionTitle, "Verify NYU email")
    }

    /// HQ decision 7: the unverified row must expose an explicit actionable
    /// button, not passive-only text and not a bare disclosure chevron.
    func testUnverifiedPromptExposesAnExplicitVerifyButton() throws {
        let prompt = try declarationSource(
            startMarker: "private var requestAlertsVerificationPrompt: some View {",
            endMarker: "static let requestAlertsVerificationPromptText",
            in: "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift"
        )
        XCTAssertTrue(prompt.contains("Button {"))
        XCTAssertTrue(prompt.contains("Text(Self.verifyNYUEmailActionTitle)"))
        XCTAssertTrue(prompt.contains(".commonPlateSecondaryAction()"))
        XCTAssertFalse(prompt.contains("CommonPlateDisclosureIndicator"))
    }

    /// The unverified prompt opens the same focused overlay the toggles
    /// themselves open — no second verification path — and the generic N0
    /// unavailable/checking status can only ever render inside the verified
    /// branch, never for an unverified participant.
    func testUnverifiedPromptOpensTheSameOverlayAndNeverShowsTheGenericN0Status() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")

        let prompt = try declarationSource(
            startMarker: "private var requestAlertsVerificationPrompt: some View {",
            endMarker: "static let requestAlertsVerificationPromptText",
            in: "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift"
        )
        XCTAssertTrue(prompt.contains("isPresentingRequestAlerts = true"))
        XCTAssertFalse(prompt.contains(SettingsView.emailAlertsUnavailableStatus))
        XCTAssertFalse(prompt.contains(SettingsView.emailAlertsCheckingStatus))
        XCTAssertTrue(source.contains("RequestAlertsOverlayView("))
    }

    private func declarationSource(
        startMarker: String,
        endMarker: String,
        in relativePath: String
    ) throws -> String {
        let source = try fileSource(relativePath)
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(source.range(of: endMarker, range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Settings Figma-measured spacing (simulator FIX, item 4)

    func testSettingsMetricsMatchApprovedFigmaMeasurements() {
        XCTAssertEqual(CommonPlateStyle.Metrics.settingsPageInset, 18)
        XCTAssertEqual(CommonPlateStyle.Metrics.settingsRowInset, 16)
    }

    func testSettingsViewUsesTheMeasuredInsetsNotTheGeneralSpacingScale() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")

        XCTAssertTrue(source.contains("CommonPlateStyle.Metrics.settingsPageInset"))
        XCTAssertEqual(
            source.components(separatedBy: "CommonPlateStyle.Metrics.settingsRowInset").count - 1,
            6,
            "expected the measured row inset on: identity content, the inline status, the toggle row, "
                + "the verification prompt row, the shared divider, and the About & Help row"
        )
    }

    func testPullRefreshPhaseHasNoReleaseThresholdCase() {
        // Compile-time proof: `PullRefreshPhase` has exactly the four cases
        // below. If a `.releaseThreshold` case is reintroduced, this
        // exhaustive switch fails to compile rather than silently passing.
        // `.recoverySuccess` replaces the old generic `.success` case (HQ
        // decision 6): the checkmark is gated on genuine Unavailable →
        // healthy recovery, not on any successful fetch.
        func exhaustive(_ phase: PullRefreshPhase) -> String {
            switch phase {
            case .idle: return "idle"
            case .pulling: return "pulling"
            case .refreshing: return "refreshing"
            case .recoverySuccess: return "recoverySuccess"
            }
        }
        XCTAssertEqual(exhaustive(.idle), "idle")
    }
}
