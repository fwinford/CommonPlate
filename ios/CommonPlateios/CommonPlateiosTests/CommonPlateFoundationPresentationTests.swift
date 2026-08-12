//
//  CommonPlateFoundationPresentationTests.swift
//  CommonPlateiosTests
//
// Focused W4-F1 source-scope proof for the presentation seams that SwiftUI
// unit tests cannot inspect without a UI-test target: the native-first action
// hierarchy, Home identity presentation, and F1-owned helper vocabulary.
import Foundation
import XCTest
@testable import CommonPlateios

final class CommonPlateFoundationPresentationTests: XCTestCase {
    func testSharedActionStylesKeepTheHierarchyWithModerateRoundedRectangles() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Design/CommonPlateButtonStyles.swift")

        XCTAssertTrue(source.contains("func commonPlatePrimaryAction()"))
        XCTAssertTrue(source.contains("buttonStyle(CommonPlateFilledActionStyle())"))
        XCTAssertTrue(source.contains("func commonPlateSecondaryAction()"))
        XCTAssertTrue(source.contains("buttonStyle(CommonPlateSoftActionStyle())"))
        XCTAssertTrue(source.contains("func commonPlateTertiaryAction()"))
        XCTAssertTrue(source.contains("func commonPlateDestructiveAction()"))
        XCTAssertTrue(source.contains("buttonStyle(CommonPlateDestructiveButtonStyle())"))
        XCTAssertTrue(source.contains(".stroke(isEnabled ? Color.red : .gray"))
        XCTAssertTrue(source.contains("foregroundStyle(isEnabled ? Color.red : .secondary)"))
        let sharedRoundedRectangle =
            "RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)"
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: sharedRoundedRectangle).count - 1,
            2,
            "Primary and secondary actions must share the F1 rounded-rectangle token."
        )
        XCTAssertFalse(source.contains("Capsule"))
        XCTAssertTrue(source.contains("commonPlateActionLabelLayout()"))
        XCTAssertTrue(source.contains("lineLimit(nil)"))
        XCTAssertTrue(source.contains("fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(source.contains("padding(.horizontal, CommonPlateStyle.Spacing.l)"))
        XCTAssertTrue(source.contains("padding(.vertical, CommonPlateStyle.Spacing.m)"))
        XCTAssertTrue(source.contains("maxWidth: .infinity"))
        XCTAssertTrue(source.contains("minHeight: CommonPlateStyle.Control.minimumHeight"))
        XCTAssertFalse(source.contains(".frame(width:"))
        XCTAssertFalse(source.contains(".clipped()"))
        XCTAssertFalse(source.contains("lineLimit(1)"))
        XCTAssertFalse(source.contains("minimumScaleFactor"))

        let tokens = try fileSource("ios/CommonPlateios/CommonPlateios/Design/CommonPlateStyle.swift")
        XCTAssertTrue(tokens.contains("enum Radius"))
        XCTAssertTrue(tokens.contains("static let standard: CGFloat"))
        XCTAssertTrue(tokens.contains("static let minimumHeight: CGFloat"))
    }

    func testHomeKeepsTheEstablishedMaskedIdentityAndDestructiveRemovalPresentation() throws {
        let section = try declarationSource(
            startMarker: "private var participantIdentitySection: some View {",
            endMarker: "static let changeEmailTitle"
        )

        XCTAssertTrue(section.contains("identity.masked"))
        XCTAssertTrue(section.contains("home-verified-identity"))
        XCTAssertTrue(section.contains("home-change-email"))
        XCTAssertTrue(section.contains("home-remove-email"))
        XCTAssertTrue(section.contains("commonPlateDestructiveAction()"))
        XCTAssertTrue(section.contains("Label(\"Verified as \\(identity.masked)\", systemImage: \"checkmark.circle.fill\")"))
        XCTAssertEqual(section.components(separatedBy: "Divider()").count - 1, 2)
        XCTAssertFalse(section.contains("commonPlateGroupedSurface"))
        XCTAssertFalse(section.contains("CommonPlateStyle.Color.warmSurface"))

        XCTAssertTrue(section.contains("Button(Self.removeEmailTitle, role: .destructive)"))
    }

    func testHomeUsesHelperWhenItNamesTheHelpingRole() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/ContentView.swift")
        XCTAssertTrue(source.contains("A helper with extra meal swipes chooses a request to help with."))
        XCTAssertFalse(source.contains("Another student with extra meal swipes chooses a request to help with."))
    }

    func testHomeHasNativeVerticalOverflowWithoutChangingContentOrder() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/ContentView.swift")
        XCTAssertTrue(source.contains("ScrollView {"))

        let requestFood = try XCTUnwrap(source.range(of: "NavigationLink(\"I need food\""))
        let help = try XCTUnwrap(source.range(of: "NavigationLink(\"Help with a request\""))
        let identity = try XCTUnwrap(source.range(of: "participantIdentitySection"))
        let privacy = try XCTUnwrap(source.range(of: "NavigationLink(\"Privacy & Safety\""))
        XCTAssertLessThan(requestFood.lowerBound, help.lowerBound)
        XCTAssertLessThan(help.lowerBound, identity.lowerBound)
        XCTAssertLessThan(identity.lowerBound, privacy.lowerBound)
    }

    func testVerificationUsesDirectScrollableHierarchyWithoutGroupedSurfaces() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ParticipantVerificationView.swift")
        let homeSource = try fileSource("ios/CommonPlateios/CommonPlateios/ContentView.swift")
        let header = try declarationSource(
            startMarker: "private var verificationBrandHeader: some View {",
            endMarker: "@ViewBuilder\n    private var emailSection: some View {",
            in: "ios/CommonPlateios/CommonPlateios/Views/ParticipantVerificationView.swift"
        )
        let email = try declarationSource(
            startMarker: "private var emailSection: some View {",
            endMarker: "private func codeSection(address: String) -> some View {",
            in: "ios/CommonPlateios/CommonPlateios/Views/ParticipantVerificationView.swift"
        )
        let code = try declarationSource(
            startMarker: "private func codeSection(address: String) -> some View {",
            endMarker: "    static let codeLifetimeNotice",
            in: "ios/CommonPlateios/CommonPlateios/Views/ParticipantVerificationView.swift"
        )

        XCTAssertTrue(source.contains("ScrollView {"))
        XCTAssertTrue(source.contains(".scrollDismissesKeyboard(.interactively)"))
        let verificationCanvas = try XCTUnwrap(pageCanvasUsage(in: source))
        XCTAssertEqual(verificationCanvas, pageCanvasUsage(in: homeSource))
        XCTAssertFalse(verificationCanvas.contains("warmSurface"))
        XCTAssertFalse(source.contains("Form {"))
        XCTAssertFalse(source.contains("Section {"))
        XCTAssertTrue(source.contains("participant-verification-brand-header"))
        XCTAssertTrue(source.contains("Text(\"CommonPlate at NYU\")"))
        XCTAssertTrue(source.contains("Your code expires in 10 minutes."))
        XCTAssertTrue(source.contains("participant-verification-code-lifetime"))
        XCTAssertFalse(header.contains("Section"))
        XCTAssertFalse(header.contains("commonPlateGroupedSurface"))
        XCTAssertFalse(email.contains("commonPlateGroupedSurface"))
        XCTAssertTrue(source.contains("ToolbarItem(placement: .cancellationAction)"))
        XCTAssertTrue(source.contains("Button(\"Cancel\")"))
        XCTAssertTrue(source.contains("case .awaitingCode(let address, _, _):\n                        codeSection(address: address)"))
        XCTAssertFalse(code.contains("Form {"))
        XCTAssertFalse(code.contains("Section {"))
        XCTAssertFalse(code.contains("commonPlateGroupedSurface"))
        XCTAssertFalse(source.contains("commonPlateGroupedSurface"))
    }

    /// The presentation contract is semantic: Home and verification share a
    /// full-page canvas, and it is not the grouped warm-surface treatment.
    /// It intentionally does not pin a particular token name.
    private func pageCanvasUsage(in source: String) -> String? {
        let pattern = #"\.background\(CommonPlateStyle\.Color\.(?!warmSurface)[A-Za-z][A-Za-z0-9]*\.ignoresSafeArea\(\)\)"#
        guard let range = source.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(source[range])
    }

    private func declarationSource(
        startMarker: String,
        endMarker: String,
        in relativePath: String = "ios/CommonPlateios/CommonPlateios/ContentView.swift"
    ) throws -> String {
        let source = try fileSource(relativePath)
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(source.range(of: endMarker, range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
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
