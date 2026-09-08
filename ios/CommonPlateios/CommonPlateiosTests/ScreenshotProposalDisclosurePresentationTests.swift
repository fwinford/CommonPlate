//
//  ScreenshotProposalDisclosurePresentationTests.swift
//  CommonPlateiosTests
//

import XCTest
@testable import CommonPlateios

/// W4-R2 2026-09-01 round-2 sync: the required remote-AI disclosure now
/// presents in the same centered-modal shell `ScreenshotHelpView` uses, with
/// accepted compact, vendor-neutral copy replacing the superseded
/// `.sheet`-presented, OpenAI-naming wording.
final class ScreenshotProposalDisclosurePresentationTests: XCTestCase {
    /// Sync item 5: the accepted exact compact title/body/action copy.
    func testAcceptedCompactCopyAndActions() {
        XCTAssertEqual(ScreenshotProposalDisclosureView.title, "Use Screenshot Assistance?")
        XCTAssertEqual(
            ScreenshotProposalDisclosureView.body,
            "The screenshot you choose is sent for AI analysis to suggest request details. You review everything before posting."
        )
    }

    /// Sync item 6: no named provider/vendor in the compact disclosure, and
    /// none of the superseded longer disclosure's retention/storage or
    /// field-by-field enumeration prose survives.
    func testNoProviderNameOrSupersededLongerCopy() {
        XCTAssertFalse(ScreenshotProposalDisclosureView.title.contains("OpenAI"))
        XCTAssertFalse(ScreenshotProposalDisclosureView.body.contains("OpenAI"))
        XCTAssertFalse(ScreenshotProposalDisclosureView.body.contains("does not store"))
        XCTAssertFalse(ScreenshotProposalDisclosureView.body.contains("location, food description"))
        XCTAssertNotEqual(ScreenshotProposalDisclosureView.title, "Analyze this screenshot with AI?")
    }

    func testAcceptedActionLabelsAreContinueAndNotNow() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ScreenshotProposalDisclosureView.swift")

        XCTAssertTrue(source.contains("Button(\"Continue\")"))
        XCTAssertTrue(source.contains("Button(\"Not now\")"))
        XCTAssertFalse(source.contains("Button(\"Cancel\")"))
    }

    /// W4-R2 2026-09-05 sync item 4: `Not now` must be the full-width
    /// `.commonPlateSecondaryAction()` treatment (matching `Continue`'s
    /// footprint), stacked beneath it — not the plain-style, footnote-sized,
    /// accent-colored tertiary text link it was.
    func testNotNowUsesTheFullWidthSecondaryTreatmentNotATertiaryLink() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ScreenshotProposalDisclosureView.swift")

        let continueRange = try XCTUnwrap(source.range(of: "Button(\"Continue\")"))
        let notNowRange = try XCTUnwrap(source.range(of: "Button(\"Not now\")"))
        XCTAssertTrue(continueRange.lowerBound < notNowRange.lowerBound, "Continue must precede Not now")

        let notNowTail = String(source[notNowRange.upperBound...].prefix(200))
        XCTAssertTrue(notNowTail.contains(".commonPlateSecondaryAction()"))
        XCTAssertFalse(notNowTail.contains(".commonPlateTertiaryAction()"))
        XCTAssertFalse(source.contains(".commonPlateTertiaryAction()"))
    }

    /// W4-R2 2026-09-05 sync item 4: this view's own body needs the same
    /// accessibility-size `ScrollView` fallback pattern
    /// `ScreenshotHelpView.overview` already uses, so content can actually
    /// reach past the shared outer 480pt accessibility-size cap rather than
    /// clipping against it with no way to scroll.
    func testAccessibilitySizeScrollFallbackMatchesScreenshotHelpsPattern() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ScreenshotProposalDisclosureView.swift")

        XCTAssertTrue(source.contains("@Environment(\\.dynamicTypeSize) private var dynamicTypeSize"))
        XCTAssertTrue(source.contains("dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(source.contains("ScrollView {"))
    }

    /// Sync item 4: the disclosure is a local centered overlay sharing
    /// Screenshot Help's own outer modal geometry — not a `.sheet`.
    func testDisclosurePresentsAsACenteredOverlaySharingScreenshotHelpsGeometry() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")

        XCTAssertFalse(source.contains(".sheet(isPresented: $isPresentingScreenshotDisclosure)"))
        XCTAssertTrue(source.contains("if isPresentingScreenshotDisclosure {"))

        guard let startRange = source.range(of: "if isPresentingScreenshotDisclosure {") else {
            XCTFail("expected to find the disclosure overlay")
            return
        }
        let overlaySource = String(source[startRange.lowerBound...])
        guard let closingRange = overlaySource.range(of: "\n            }") else {
            XCTFail("expected to find the overlay's closing brace")
            return
        }
        let block = String(overlaySource[overlaySource.startIndex..<closingRange.upperBound])

        XCTAssertTrue(block.contains("ZStack {"))
        XCTAssertTrue(block.contains("Color.black.opacity(0.34)"))
        XCTAssertTrue(block.contains(".frame(width: 314)"))
        XCTAssertTrue(block.contains(".frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 480 : nil)"))
        XCTAssertTrue(block.contains("RoundedRectangle(cornerRadius: 22, style: .continuous)"))
        XCTAssertTrue(block.contains("request-screenshot-disclosure-modal"))
        XCTAssertTrue(block.contains(".accessibilityAddTraits(.isModal)"))
        XCTAssertTrue(block.contains(".ignoresSafeArea()"))
    }

    /// Both overlays hide the rest of the screen from accessibility while
    /// showing, matching Screenshot Help's own existing behavior.
    func testUnderlyingContentIsAccessibilityHiddenWhileEitherOverlayShows() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")

        XCTAssertTrue(
            source.contains(".accessibilityHidden(isPresentingScreenshotHelp || isPresentingScreenshotDisclosure)")
        )
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
