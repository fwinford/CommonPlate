//
//  ScreenshotAssistanceDisclosurePresentationTests.swift
//  CommonPlateiosTests
//
// W4-S3 consent-authority revision (2026-10-01 HQ sync) presentation and
// structure proof: the exact copy/actions of the `Turn on Screenshot
// Assistance?` disclosure (replacing the retired per-attempt external-AI
// fallback popup as the consent boundary), its identical centered-modal shell
// in both presentation sites (`RequestFoodView`'s Off-state row and
// `SettingsView`'s toggle), that no per-attempt external-AI popup surface
// remains anywhere, the single Settings control, and the shared runtime's
// continued independence from any telemetry infrastructure. There is no
// UI-test target (`docs/testing.md`), so shell and wiring are proven by source
// inspection, exactly as the retired disclosure/popup presentations were.
import XCTest
@testable import CommonPlateios

final class ScreenshotAssistanceDisclosurePresentationTests: XCTestCase {
    // MARK: - Exact copy and actions

    func testExactAcceptedCopyAndActions() {
        XCTAssertEqual(ScreenshotAssistanceDisclosureView.title, "Turn on Screenshot Assistance?")
        XCTAssertEqual(
            ScreenshotAssistanceDisclosureView.body,
            "Screenshot Assistance can help fill in details from screenshots you add to CommonPlate. Some screenshots may be sent to OpenAI to generate these suggestions."
        )
        XCTAssertEqual(
            ScreenshotAssistanceDisclosureView.offRecoveryLine,
            "You can turn Screenshot Assistance off anytime in Settings."
        )
        XCTAssertEqual(ScreenshotAssistanceDisclosureView.turnOnActionTitle, "Turn On")
        XCTAssertEqual(ScreenshotAssistanceDisclosureView.notNowActionTitle, "Not Now")
    }

    func testCopyUsesNoOnDeviceRoutingOrFallbackArchitectureLanguage() {
        let userFacing = [
            ScreenshotAssistanceDisclosureView.title,
            ScreenshotAssistanceDisclosureView.body,
            ScreenshotAssistanceDisclosureView.offRecoveryLine,
            ScreenshotAssistanceDisclosureView.turnOnActionTitle,
            ScreenshotAssistanceDisclosureView.notNowActionTitle,
        ].map { $0.lowercased() }
        for prohibited in [
            "on-device", "on device", "local provider", "local model", "fallback", "qualification",
            "remote assistance", "cloud inference", "localevidencetext", "ocr",
        ] {
            for text in userFacing {
                XCTAssertFalse(text.contains(prohibited), "`\(prohibited)` must not appear in \(text)")
            }
        }
        XCTAssertTrue(ScreenshotAssistanceDisclosureView.body.contains("OpenAI"))
    }

    func testNoSubtitleAndExactlyThreeTextViewsAndTwoButtons() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ScreenshotAssistanceDisclosureView.swift")
        XCTAssertEqual(source.components(separatedBy: "Text(Self.").count - 1, 3, "title, body, and the off-recovery line")
        XCTAssertEqual(source.components(separatedBy: "Button(Self.").count - 1, 2)
        XCTAssertTrue(source.contains("Button(Self.turnOnActionTitle) {"))
        XCTAssertTrue(source.contains("Button(Self.notNowActionTitle) {"))
    }

    func testTurnOnIsPrimaryAndPrecedesNotNowWhichIsSecondary() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ScreenshotAssistanceDisclosureView.swift")
        let turnOnPosition = try XCTUnwrap(source.range(of: "Button(Self.turnOnActionTitle)"))
        let notNowPosition = try XCTUnwrap(source.range(of: "Button(Self.notNowActionTitle)"))
        XCTAssertTrue(turnOnPosition.lowerBound < notNowPosition.lowerBound)
        let turnOnTail = String(source[turnOnPosition.upperBound...].prefix(160))
        let notNowTail = String(source[notNowPosition.upperBound...].prefix(160))
        XCTAssertTrue(turnOnTail.contains(".commonPlatePrimaryAction()"))
        XCTAssertTrue(notNowTail.contains(".commonPlateSecondaryAction()"))
    }

    func testAccessibilitySizeScrollFallbackMatchesTheModalFamily() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ScreenshotAssistanceDisclosureView.swift")
        XCTAssertTrue(source.contains("@Environment(\\.dynamicTypeSize) private var dynamicTypeSize"))
        XCTAssertTrue(source.contains("dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(source.contains("ScrollView {"))
    }

    // MARK: - RequestFoodView: centered-modal shell, not an embedded state or a new screen

    func testRequestFoodViewPresentsTheDisclosureAsACenteredOverlaySharingScreenshotHelpsGeometry() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")

        XCTAssertFalse(source.contains(".sheet(isPresented: $isPresentingScreenshotAssistanceDisclosure)"))
        XCTAssertFalse(source.contains(".fullScreenCover"))
        XCTAssertFalse(source.contains("navigationDestination(isPresented: screenshot"))

        let start = try XCTUnwrap(source.range(of: "if isPresentingScreenshotAssistanceDisclosure {"))
        let overlay = String(source[start.lowerBound...])
        let end = try XCTUnwrap(overlay.range(of: "\n            }\n        }\n        .navigationTitle"))
        let block = String(overlay[overlay.startIndex..<end.upperBound])

        XCTAssertTrue(block.contains("ZStack {"))
        XCTAssertTrue(block.contains("Color.black.opacity(0.34)"))
        XCTAssertTrue(block.contains("ScreenshotAssistanceDisclosureView("))
        XCTAssertTrue(block.contains("onTurnOn: confirmTurnOnScreenshotAssistance"))
        XCTAssertTrue(block.contains("onNotNow: dismissScreenshotAssistanceDisclosure"))
        XCTAssertTrue(block.contains(".frame(width: 314)"))
        XCTAssertTrue(block.contains(".frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 480 : nil)"))
        XCTAssertTrue(block.contains("RoundedRectangle(cornerRadius: 22, style: .continuous)"))
        XCTAssertTrue(block.contains("request-screenshot-assistance-disclosure-modal"))
        XCTAssertTrue(block.contains(".accessibilityAddTraits(.isModal)"))
        XCTAssertTrue(block.contains(".ignoresSafeArea()"))
    }

    func testUnderlyingContentIsAccessibilityHiddenWhileEitherOverlayShows() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")
        XCTAssertTrue(
            source.contains(".accessibilityHidden(isPresentingScreenshotHelp || isPresentingScreenshotAssistanceDisclosure)")
        )
    }

    /// The disclosure is exceptional UI: nothing about it is embedded in the
    /// Screenshot Assistance row of the form.
    func testDisclosureIsNotEmbeddedInTheScreenshotAssistanceRow() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")
        let start = try XCTUnwrap(source.range(of: "private var screenshotAssistanceRow: some View {"))
        let end = try XCTUnwrap(source.range(of: "static let screenshotAssistanceTitle", range: start.upperBound..<source.endIndex))
        let row = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(row.contains("ScreenshotAssistanceDisclosureView"))
        XCTAssertFalse(row.contains("Turn on Screenshot Assistance?"))
        XCTAssertFalse(row.contains("isPresentingScreenshotAssistanceDisclosure"))
    }

    /// `Turn on Screenshot Assistance` only ever opens the disclosure; `Turn
    /// On` there is the only path that grants consent and proceeds.
    func testTurnOnRowOnlyPresentsTheDisclosureAndDoesNotItselfEnable() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")
        let start = try XCTUnwrap(source.range(of: "private func beginTurnOnScreenshotAssistanceFlow() {"))
        let end = try XCTUnwrap(source.range(of: "private func confirmTurnOnScreenshotAssistance() {"))
        let flow = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(flow.contains("isPresentingScreenshotAssistanceDisclosure = true"))
        XCTAssertFalse(flow.contains("setAIAssistanceEnabled"))
        XCTAssertFalse(flow.contains("proceedToScreenshotSelection"))
    }

    func testConfirmTurnOnGrantsConsentThenProceedsToSelection() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")
        let start = try XCTUnwrap(source.range(of: "private func confirmTurnOnScreenshotAssistance() {"))
        let end = try XCTUnwrap(source.range(of: "private func dismissScreenshotAssistanceDisclosure() {"))
        let flow = String(source[start.lowerBound..<end.lowerBound])
        let dismiss = try XCTUnwrap(flow.range(of: "isPresentingScreenshotAssistanceDisclosure = false"))
        let grant = try XCTUnwrap(flow.range(of: "screenshotProposalStore.setAIAssistanceEnabled(true)"))
        let proceed = try XCTUnwrap(flow.range(of: "proceedToScreenshotSelection()"))
        XCTAssertLessThan(dismiss.lowerBound, grant.lowerBound, "the disclosure is dismissed before granting")
        XCTAssertLessThan(grant.lowerBound, proceed.lowerBound, "consent is granted before continuing into the picker step")
    }

    func testNotNowOnlyDismissesAndRecordsNoConsent() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")
        let start = try XCTUnwrap(source.range(of: "private func dismissScreenshotAssistanceDisclosure() {"))
        let end = try XCTUnwrap(source.range(of: "@MainActor\n    private func beginScreenshotAnalysis("))
        let flow = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(flow.contains("isPresentingScreenshotAssistanceDisclosure = false"))
        XCTAssertFalse(flow.contains("setAIAssistanceEnabled"))
        XCTAssertFalse(flow.contains("proceedToScreenshotSelection"))
    }

    // MARK: - Settings: one Screenshot Assistance control, routed through the same disclosure

    func testSettingsKeepsASingleScreenshotAssistanceToggleAndNoRemoteAIControl() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")
        XCTAssertEqual(source.components(separatedBy: "title: \"Screenshot Assistance\"").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: "settings-ai-assistance-toggle").count - 1, 1)
        for text in ["Remote AI", "External AI", "external AI", "OpenAI", "Use external AI"] {
            XCTAssertFalse(source.contains("title: \"\(text)"), text)
            XCTAssertFalse(source.contains("Text(\"\(text)"), text)
        }
    }

    func testSettingsToggleOnPresentsTheDisclosureAndOffCallsSetAIAssistanceEnabledDirectly() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")
        let start = try XCTUnwrap(source.range(of: "private var aiAssistanceToggleBinding: Binding<Bool> {"))
        let end = try XCTUnwrap(source.range(of: "private func confirmTurnOnScreenshotAssistance() {"))
        let binding = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(binding.contains("isPresentingScreenshotAssistanceDisclosure = true"))
        XCTAssertTrue(binding.contains("screenshotProposalStore.setAIAssistanceEnabled(false)"))
        XCTAssertFalse(binding.contains("setAIAssistanceEnabled(true)"), "On never flips the setting directly — only `Turn On` does")
    }

    func testSettingsPresentsTheIdenticalDisclosureInTheSameCenteredModalShell() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")
        let start = try XCTUnwrap(source.range(of: "if isPresentingScreenshotAssistanceDisclosure {"))
        let block = String(source[start.lowerBound...].prefix(1400))
        XCTAssertTrue(block.contains("ScreenshotAssistanceDisclosureView("))
        XCTAssertTrue(block.contains("onTurnOn: confirmTurnOnScreenshotAssistance"))
        XCTAssertTrue(block.contains("onNotNow: dismissScreenshotAssistanceDisclosure"))
        XCTAssertTrue(block.contains(".frame(width: 314)"))
        XCTAssertTrue(block.contains("RoundedRectangle(cornerRadius: 22, style: .continuous)"))
        XCTAssertTrue(block.contains("settings-screenshot-assistance-disclosure-modal"))
        XCTAssertTrue(block.contains(".accessibilityAddTraits(.isModal)"))
    }

    // MARK: - No per-attempt external-AI popup surface remains anywhere

    func testTheRetiredPerAttemptPopupViewFileNoLongerExists() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let retiredPath = root.appendingPathComponent(
            "ios/CommonPlateios/CommonPlateios/Views/ScreenshotExternalAIFallbackView.swift"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: retiredPath.path))
    }

    func testNoPerAttemptPopupReferenceRemainsInTheRequesterOrSettingsSurfaces() throws {
        for file in [
            "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift",
            "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift",
            "ios/CommonPlateios/CommonPlateios/Views/RequestFoodEntryView.swift",
            "ios/CommonPlateios/CommonPlateios/Stores/ScreenshotProposalStore.swift",
        ] {
            let source = try fileSource(file)
            for forbidden in [
                "ScreenshotExternalAIFallbackView", "isAwaitingExternalAIPermission", "useExternalAI(",
                "continueManually(", "pendingExternalFallback", "retireExternalFallbackForLostAuthority",
                "Couldn\u{2019}t analyze these on your device", "Use external AI", "Continue manually",
            ] {
                XCTAssertFalse(source.contains(forbidden), "\(file) must not reference `\(forbidden)`")
            }
        }
    }

    // MARK: - Success UI is the existing compact treatment for both classes

    func testBothProviderClassesEndInTheSameExistingCompactCheckedTreatment() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")

        // One apply path for local and external results; one place that sets
        // the checked row, guarded by the outcome's eligibility.
        XCTAssertEqual(source.components(separatedBy: "screenshotChecked = true").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: "screenshotProposalStore.apply(").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: "applyScreenshotOutcome(").count - 1, 3) // analysis, explicit Switch, declaration
        XCTAssertTrue(source.contains("applyScreenshotOutcome(conflict.outcome, token: conflict.token)"))
        let apply = try XCTUnwrap(source.range(of: "private func applyScreenshotOutcome("))
        let tail = String(source[apply.upperBound...])
        XCTAssertLessThan(
            try XCTUnwrap(tail.range(of: "if outcome.eligible {")).lowerBound,
            try XCTUnwrap(tail.range(of: "screenshotChecked = true")).lowerBound
        )

        XCTAssertEqual(RequestFoodView.screenshotCheckedLabel, "✓ Screenshot checked")
        XCTAssertEqual(RequestFoodView.screenshotChangeLabel, "Change")
        // No new success card, provider-specific success copy, or identifier
        // beyond the one disclosure modal.
        XCTAssertEqual(source.components(separatedBy: "request-screenshot-assistance-disclosure").count - 1, 1)
    }

    func testRoutineSuccessAndFailureCopyStaysProviderNeutral() {
        for notice in [
            ScreenshotProposalNotice.unsupportedScreenshot, .noUsefulExtraction, .unavailable,
            .invalidImage, .verificationRequired, .verificationExpired,
        ] {
            let message = notice.message.lowercased()
            XCTAssertFalse(message.contains("openai"), "\(notice)")
            for prohibited in ["remote assistance", "cloud inference", "provider fallback", "local provider"] {
                XCTAssertFalse(message.contains(prohibited), "\(notice)")
            }
        }
    }

    // MARK: - No telemetry dependency in the shared runtime

    func testTheSharedRuntimeAndProvidersDependOnNoTelemetryInfrastructure() throws {
        // The shared runtime, validator, providers, and preparer carry no
        // telemetry at all.
        let directory = "ios/CommonPlateios/CommonPlateios/Services/ScreenshotAssistance"
        for file in [
            "ScreenshotAssistanceRuntime.swift", "ScreenshotWorkflow.swift", "ScreenshotProviders.swift",
            "ScreenshotQualification.swift", "ScreenshotSelection.swift", "ScreenshotEvidence.swift",
            "ScreenshotTextRecognizing.swift", "ScreenshotInputPreparer.swift", "ScreenshotAttemptFence.swift",
            "Requester/RequesterOrderWorkflow.swift", "Requester/RequesterOrderDeterministicEvidence.swift",
            "Requester/RequesterOrderOutputValidator.swift", "Requester/RequesterAppleOnDeviceProvider.swift",
            "Requester/RequesterOpenAIExternalProvider.swift",
        ] {
            let source = try fileSource("\(directory)/\(file)")
            XCTAssertFalse(source.contains("Telemetry"), file)
            XCTAssertFalse(source.contains("Datadog"), file)
        }
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
