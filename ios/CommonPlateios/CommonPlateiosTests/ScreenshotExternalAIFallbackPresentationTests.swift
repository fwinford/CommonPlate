//
//  ScreenshotExternalAIFallbackPresentationTests.swift
//  CommonPlateiosTests
//
// W4-S3 presentation and structure proof for the external-AI fallback popup
// (exact copy/actions, centered-modal shell, not an embedded form state or a
// new navigation screen), the reuse of the existing compact success UI for both
// provider classes, the single Settings control, and the shared runtime's
// independence from any telemetry infrastructure. There is no UI-test target (`docs/testing.md`), so shell and
// wiring are proven by source inspection, exactly as the accepted disclosure and
// Screenshot Help presentations were.
import XCTest
@testable import CommonPlateios

final class ScreenshotExternalAIFallbackPresentationTests: XCTestCase {
    // MARK: - Exact copy and actions

    func testExactAcceptedCopyAndActions() {
        XCTAssertEqual(ScreenshotExternalAIFallbackView.title, "Couldn’t analyze these on your device")
        XCTAssertEqual(
            ScreenshotExternalAIFallbackView.body,
            "CommonPlate can send these screenshots to OpenAI, an external AI provider, to suggest request details."
        )
        XCTAssertEqual(ScreenshotExternalAIFallbackView.useExternalAIActionTitle, "Use external AI")
        XCTAssertEqual(ScreenshotExternalAIFallbackView.continueManuallyActionTitle, "Continue manually")
    }

    func testTitleUsesTheTypographicApostropheTheAcceptedCopyUses() {
        XCTAssertTrue(ScreenshotExternalAIFallbackView.title.contains("\u{2019}"))
        XCTAssertFalse(ScreenshotExternalAIFallbackView.title.contains("'"))
    }

    func testCopyUsesNoProhibitedTerminology() {
        let userFacing = [
            ScreenshotExternalAIFallbackView.title,
            ScreenshotExternalAIFallbackView.body,
            ScreenshotExternalAIFallbackView.useExternalAIActionTitle,
            ScreenshotExternalAIFallbackView.continueManuallyActionTitle,
        ].map { $0.lowercased() }
        for prohibited in ["remote assistance", "cloud inference", "provider fallback", "local provider"] {
            for text in userFacing {
                XCTAssertFalse(text.contains(prohibited), "`\(prohibited)` must not appear in \(text)")
            }
        }
        // The user-facing distinction is your device versus OpenAI, an external
        // AI provider.
        XCTAssertTrue(ScreenshotExternalAIFallbackView.title.contains("your device"))
        XCTAssertTrue(ScreenshotExternalAIFallbackView.body.contains("OpenAI, an external AI provider"))
    }

    /// No added subtitle, and none of the previously proposed line; no
    /// retention wording either (Faith's decision).
    func testNoSubtitleNoSupersededLineAndNoRetentionWording() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ScreenshotExternalAIFallbackView.swift")
        XCTAssertFalse(source.contains("Nothing is posted automatically"))
        XCTAssertFalse(ScreenshotExternalAIFallbackView.body.lowercased().contains("retain"))
        XCTAssertFalse(ScreenshotExternalAIFallbackView.body.lowercased().contains("stored"))
        // Exactly two `Text` views (title and body) and two buttons.
        XCTAssertEqual(source.components(separatedBy: "Text(Self.").count - 1, 2)
        XCTAssertEqual(source.components(separatedBy: "Button(Self.").count - 1, 2)
        XCTAssertTrue(source.contains("Button(Self.useExternalAIActionTitle) {"))
        XCTAssertTrue(source.contains("Button(Self.continueManuallyActionTitle) {"))
    }

    func testUseExternalAIIsPrimaryAndPrecedesContinueManuallyWhichIsSecondary() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ScreenshotExternalAIFallbackView.swift")
        let usePosition = try XCTUnwrap(source.range(of: "Button(Self.useExternalAIActionTitle)"))
        let manualPosition = try XCTUnwrap(source.range(of: "Button(Self.continueManuallyActionTitle)"))
        XCTAssertTrue(usePosition.lowerBound < manualPosition.lowerBound)
        let useTail = String(source[usePosition.upperBound...].prefix(160))
        let manualTail = String(source[manualPosition.upperBound...].prefix(160))
        XCTAssertTrue(useTail.contains(".commonPlatePrimaryAction()"))
        XCTAssertTrue(manualTail.contains(".commonPlateSecondaryAction()"))
    }

    func testAccessibilitySizeScrollFallbackMatchesTheModalFamily() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ScreenshotExternalAIFallbackView.swift")
        XCTAssertTrue(source.contains("@Environment(\\.dynamicTypeSize) private var dynamicTypeSize"))
        XCTAssertTrue(source.contains("dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(source.contains("ScrollView {"))
    }

    // MARK: - Centered-modal shell, not an embedded state or a new screen

    func testPopupPresentsAsACenteredOverlaySharingScreenshotHelpsGeometry() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")

        XCTAssertFalse(source.contains(".sheet(isPresented: $isPresentingScreenshotDisclosure)"))
        XCTAssertFalse(source.contains(".fullScreenCover"))
        XCTAssertFalse(source.contains("navigationDestination(isPresented: screenshot"))

        let start = try XCTUnwrap(source.range(of: "if screenshotProposalStore.isAwaitingExternalAIPermission {"))
        let overlay = String(source[start.lowerBound...])
        let end = try XCTUnwrap(overlay.range(of: "\n            }\n        }\n        .navigationTitle"))
        let block = String(overlay[overlay.startIndex..<end.upperBound])

        XCTAssertTrue(block.contains("ZStack {"))
        XCTAssertTrue(block.contains("Color.black.opacity(0.34)"))
        XCTAssertTrue(block.contains("ScreenshotExternalAIFallbackView("))
        XCTAssertTrue(block.contains("onUseExternalAI: useExternalScreenshotAI"))
        XCTAssertTrue(block.contains("onContinueManually: continueScreenshotManually"))
        XCTAssertTrue(block.contains(".frame(width: 314)"))
        XCTAssertTrue(block.contains(".frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 480 : nil)"))
        XCTAssertTrue(block.contains("RoundedRectangle(cornerRadius: 22, style: .continuous)"))
        XCTAssertTrue(block.contains("request-screenshot-external-ai-modal"))
        XCTAssertTrue(block.contains(".accessibilityAddTraits(.isModal)"))
        XCTAssertTrue(block.contains(".ignoresSafeArea()"))
    }

    func testUnderlyingContentIsAccessibilityHiddenWhileEitherOverlayShows() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")
        XCTAssertTrue(
            source.contains(".accessibilityHidden(isPresentingScreenshotHelp || screenshotProposalStore.isAwaitingExternalAIPermission)")
        )
    }

    /// The popup is exceptional UI: nothing about it is embedded in the
    /// Screenshot Assistance row of the form.
    func testPopupIsNotEmbeddedInTheScreenshotAssistanceRow() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")
        let start = try XCTUnwrap(source.range(of: "private var screenshotAssistanceRow: some View {"))
        let end = try XCTUnwrap(source.range(of: "static let screenshotAssistanceTitle", range: start.upperBound..<source.endIndex))
        let row = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(row.contains("ScreenshotExternalAIFallbackView"))
        XCTAssertFalse(row.contains("Use external AI"))
        XCTAssertFalse(row.contains("isAwaitingExternalAIPermission"))
        XCTAssertFalse(row.contains("Couldn"))
    }

    // MARK: - Actions are wired to the per-attempt permission boundary

    func testUseExternalAIRunsOneStoreAttemptAndAppliesThroughTheSharedApplyPath() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")
        let start = try XCTUnwrap(source.range(of: "private func useExternalScreenshotAI() {"))
        let end = try XCTUnwrap(source.range(of: "/// W4-S3: `Continue manually`", range: start.upperBound..<source.endIndex))
        let block = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(block.contains("screenshotProposalStore.useExternalAI("))
        XCTAssertTrue(block.contains("identityStore.currentAuthority()"))
        XCTAssertTrue(block.contains("applyScreenshotOutcome(resolved.outcome, token: resolved.token)"))
        XCTAssertTrue(block.contains("screenshotProposalStore.isCurrent(resolved.token)"))
        // No path from the popup back into another popup or a persisted grant.
        XCTAssertFalse(block.contains("isAwaitingExternalAIPermission"))
        XCTAssertFalse(block.lowercased().contains("consent"))
    }

    /// The only caller of `useExternalAI` in the requester view is the popup's
    /// primary action — no other control, flow, or lifecycle hook can start an
    /// external transfer.
    func testOnlyThePopupsPrimaryActionCanStartAnExternalAttempt() throws {
        let view = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")
        XCTAssertEqual(view.components(separatedBy: "screenshotProposalStore.useExternalAI(").count - 1, 1)
        XCTAssertEqual(view.components(separatedBy: "runExternalScreenshotAnalysis()").count - 1, 2) // call + declaration
        for file in [
            "ios/CommonPlateios/CommonPlateios/Views/RequestFoodEntryView.swift",
            "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift",
            "ios/CommonPlateios/CommonPlateios/ContentView.swift",
        ] {
            let source = try fileSource(file)
            XCTAssertFalse(source.contains("useExternalAI("), "\(file) must not start an external attempt")
        }
        // Inside the store, the runtime's external path is reached from
        // `useExternalAI` alone.
        let store = try fileSource("ios/CommonPlateios/CommonPlateios/Stores/ScreenshotProposalStore.swift")
        XCTAssertEqual(store.components(separatedBy: "runtime.runExternal(").count - 1, 1)
        XCTAssertEqual(store.components(separatedBy: "runtime.authorizeExternalTransfer(").count - 1, 1)
    }

    // MARK: - Success UI is the existing compact treatment for both classes

    func testBothProviderClassesEndInTheSameExistingCompactCheckedTreatment() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")

        // One apply path for local and external results; one place that sets
        // the checked row, guarded by the outcome's eligibility.
        XCTAssertEqual(source.components(separatedBy: "screenshotChecked = true").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: "screenshotProposalStore.apply(").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: "applyScreenshotOutcome(").count - 1, 4) // three calls (local, external, authority-loss retirement) + declaration
        let apply = try XCTUnwrap(source.range(of: "private func applyScreenshotOutcome("))
        let tail = String(source[apply.upperBound...])
        XCTAssertLessThan(
            try XCTUnwrap(tail.range(of: "if outcome.eligible {")).lowerBound,
            try XCTUnwrap(tail.range(of: "screenshotChecked = true")).lowerBound
        )

        XCTAssertEqual(RequestFoodView.screenshotCheckedLabel, "✓ Screenshot checked")
        XCTAssertEqual(RequestFoodView.screenshotChangeLabel, "Change")
        // No new success card, provider-specific success copy, or identifier.
        // The popup's modal is the only external-AI identifier in the view.
        XCTAssertEqual(source.components(separatedBy: "request-screenshot-external").count - 1, 1)
        XCTAssertTrue(source.contains("request-screenshot-external-ai-modal"))
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

    // MARK: - Settings: one Screenshot Assistance control, nothing external

    func testSettingsKeepsASingleScreenshotAssistanceToggleAndNoRemoteAIControl() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")
        XCTAssertEqual(source.components(separatedBy: "title: \"Screenshot Assistance\"").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: "settings-ai-assistance-toggle").count - 1, 1)
        for text in ["Remote AI", "External AI", "external AI", "OpenAI", "Use external AI"] {
            XCTAssertFalse(source.contains("title: \"\(text)"), text)
            XCTAssertFalse(source.contains("Text(\"\(text)"), text)
        }
        // The toggle only flips the one store setting.
        XCTAssertTrue(source.contains("screenshotProposalStore.setAIAssistanceEnabled(newValue)"))
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
