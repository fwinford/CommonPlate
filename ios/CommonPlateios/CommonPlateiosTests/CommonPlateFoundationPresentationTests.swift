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
        XCTAssertTrue(source.contains("func commonPlateMajorActionFrame()"))
        XCTAssertTrue(source.contains("frame(maxWidth: CommonPlateStyle.Control.majorActionMaximumWidth)"))
        XCTAssertTrue(source.contains("lineLimit(nil)"))
        XCTAssertTrue(source.contains("fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(source.contains("padding(.horizontal, CommonPlateStyle.Spacing.l)"), "Ordinary actions keep their existing inset.")
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
        XCTAssertTrue(tokens.contains("static let majorActionMinimumHeight: CGFloat = 52"))
        XCTAssertTrue(tokens.contains("static let majorActionMaximumWidth: CGFloat = 292"))

        XCTAssertTrue(source.contains("func commonPlateMajorPrimaryAction()"))
        XCTAssertTrue(source.contains("func commonPlateMajorSecondaryAction()"))
        XCTAssertTrue(source.contains("font(.title3.weight(.semibold))"))
        XCTAssertTrue(source.contains("shadow(color: .black.opacity(isEnabled ? 0.18 : 0), radius: 4, y: 2)"))
        XCTAssertTrue(source.contains("scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.985 : 1)"))
        XCTAssertTrue(source.contains("opacity(configuration.isPressed && isEnabled ? 0.88 : 1)"))
        XCTAssertTrue(source.contains("struct CommonPlateFlatActionButtonStyle: ButtonStyle"))
        XCTAssertTrue(source.contains("opacity(configuration.isPressed ? 0.62 : 1)"))
    }

    func testHomeKeepsTheAcceptedMaskedIdentityAndDestructiveRemovalPresentation() throws {
        let section = try declarationSource(
            startMarker: "private var participantIdentitySection: some View {",
            endMarker: "static let changeEmailTitle"
        )

        XCTAssertTrue(section.contains("identity.masked"))
        XCTAssertTrue(section.contains("home-verified-identity"))
        XCTAssertTrue(section.contains("home-change-email"))
        XCTAssertTrue(section.contains("home-remove-email"))
        XCTAssertTrue(section.contains("commonPlateDestructiveAction()"))
        XCTAssertTrue(section.contains("Label(identity.masked, systemImage: \"checkmark.circle.fill\")"))
        XCTAssertTrue(section.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertEqual(section.components(separatedBy: "Divider()").count - 1, 0)
        XCTAssertFalse(section.contains("commonPlateGroupedSurface"))
        XCTAssertFalse(section.contains("CommonPlateStyle.Color.warmSurface"))

        XCTAssertTrue(section.contains("Button(Self.removeEmailTitle, role: .destructive)"))

        let changeEmail = try declarationSource(
            startMarker: "private var changeEmailButton: some View {",
            endMarker: "private var removeEmailButton: some View {"
        )
        XCTAssertTrue(changeEmail.contains(".commonPlateTertiaryAction()"))
        XCTAssertTrue(changeEmail.contains(".frame(minHeight: 44)"))
        XCTAssertTrue(changeEmail.contains(".contentShape(Rectangle())"))
        XCTAssertFalse(changeEmail.contains("commonPlatePrimaryAction"))
        XCTAssertFalse(changeEmail.contains("commonPlateSecondaryAction"))
        XCTAssertFalse(changeEmail.contains("background("))

        let home = try declarationSource(
            startMarker: "private func recurringHome(brandHasSettled: Bool) -> some View {",
            endMarker: "/// The remembered verified identity"
        )
        XCTAssertTrue(home.contains("Text(\"Request alerts\")"))
        let alertsStart = try XCTUnwrap(home.range(of: "NavigationLink(value: AppRoute.alerts)"))
        let alertsEnd = try XCTUnwrap(home.range(of: ".padding(.top", range: alertsStart.upperBound..<home.endIndex))
        let alertsAction = String(home[alertsStart.lowerBound..<alertsEnd.lowerBound])
        XCTAssertTrue(alertsAction.contains("alignment: .center"))
        XCTAssertFalse(alertsAction.contains("chevron.right"))
        XCTAssertFalse(home.contains("Text(\"More\")"))
        XCTAssertFalse(home.contains("Get alerts for new requests"))
        XCTAssertTrue(home.contains("CommonPlateStyle.Color.warmSurface"))
        XCTAssertEqual(home.components(separatedBy: "Divider()").count - 1, 1)
        XCTAssertFalse(home.contains("You’ll verify an NYU email once before posting or helping with a request."))
    }

    func testHomeUsesHelperWhenItNamesTheHelpingRole() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/ContentView.swift")
        XCTAssertTrue(source.contains("A helper with extra meal swipes chooses a request to help with."))
        XCTAssertFalse(source.contains("Another student with extra meal swipes chooses a request to help with."))
    }

    func testHomeHasNativeVerticalOverflowWithoutChangingContentOrder() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/ContentView.swift")
        XCTAssertTrue(source.contains("ScrollView {"))

        let requestFood = try XCTUnwrap(source.range(of: "Text(\"Request a meal\")"))
        let help = try XCTUnwrap(source.range(of: "Text(\"Find a request\")"))
        let identity = try XCTUnwrap(source.range(of: "participantIdentitySection"))
        let privacy = try XCTUnwrap(source.range(of: "UtilityActionRow(title: \"Privacy & Safety\")"))
        XCTAssertLessThan(requestFood.lowerBound, help.lowerBound)
        XCTAssertLessThan(help.lowerBound, privacy.lowerBound)
        XCTAssertLessThan(privacy.lowerBound, identity.lowerBound)
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
        let dismissalControl = try declarationSource(
            startMarker: ".toolbar {",
            endMarker: "    /// Verification is an approved",
            in: "ios/CommonPlateios/CommonPlateios/Views/ParticipantVerificationView.swift"
        )
        XCTAssertTrue(dismissalControl.contains("ToolbarItem(placement: .topBarLeading)"))
        XCTAssertTrue(dismissalControl.contains("Button(action: cancel)"))
        XCTAssertTrue(dismissalControl.contains("Image(systemName: \"xmark\")"))
        XCTAssertTrue(dismissalControl.contains(".font(.system(size: 17, weight: .semibold))"))
        XCTAssertTrue(dismissalControl.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(dismissalControl.contains(".background(CommonPlateStyle.Color.warmSurface, in: Circle())"))
        XCTAssertTrue(dismissalControl.contains(".accessibilityLabel(\"Close email verification\")"))
        XCTAssertFalse(dismissalControl.contains("Button(\"Cancel\")"))
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
