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

    /// W4-H2: this presentation relocated from Home to the shared Settings
    /// route (compact identity, left Change Email, right destructive Remove
    /// Email). The masked-identity/destructive-removal invariants this test
    /// previously proved against `ContentView` now apply to `SettingsView`.
    func testSettingsKeepsTheAcceptedMaskedIdentityAndDestructiveRemovalPresentation() throws {
        let section = try declarationSource(
            startMarker: "private var identitySection: some View {",
            endMarker: "@ViewBuilder\n    private func identityActions",
            in: "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift"
        )

        XCTAssertTrue(section.contains("identity.masked"))
        XCTAssertTrue(section.contains("settings-verified-identity"))
        XCTAssertTrue(section.contains("Label(identity.masked, systemImage: \"checkmark.circle.fill\")"))
        XCTAssertTrue(section.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertFalse(section.contains("commonPlateGroupedSurface"))

        let changeEmail = try declarationSource(
            startMarker: "private var changeEmailButton: some View {",
            endMarker: "private var removeEmailButton: some View {",
            in: "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift"
        )
        XCTAssertTrue(changeEmail.contains(".commonPlateTertiaryAction()"))
        XCTAssertTrue(changeEmail.contains(".frame(minHeight: 44)"))
        XCTAssertTrue(changeEmail.contains(".contentShape(Rectangle())"))
        XCTAssertFalse(changeEmail.contains("commonPlatePrimaryAction"))
        XCTAssertFalse(changeEmail.contains("commonPlateSecondaryAction"))
        XCTAssertFalse(changeEmail.contains("background("))

        let removeEmail = try declarationSource(
            startMarker: "private var removeEmailButton: some View {",
            endMarker: "static let changeEmailTitle",
            in: "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift"
        )
        XCTAssertTrue(removeEmail.contains("Button(Self.removeEmailTitle, role: .destructive)"))
        XCTAssertTrue(removeEmail.contains("settings-remove-email"))
        XCTAssertTrue(removeEmail.contains("commonPlateDestructiveAction()"))
    }

    /// W4-H2 Settings fidelity pass: the approved Figma drops identity out of
    /// a grouped card entirely and strips About & Help's explanatory
    /// subtitles, replacing the oversized warm/yellowish card with a plain
    /// native row surface. Request Alerts keeps its subtitle and its
    /// existing accepted `.alerts` destination unchanged — this pass adds
    /// visual fidelity only, no new Email/Push toggle semantics.
    func testSettingsFidelityDropsIdentityCardStripsAboutHelpSubtitlesAndKeepsRequestAlertsBehavior() throws {
        let identity = try declarationSource(
            startMarker: "private var identitySection: some View {",
            endMarker: "@ViewBuilder\n    private func identityActions",
            in: "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift"
        )
        XCTAssertFalse(identity.contains("CommonPlateStyle.Color.warmSurface"))

        let aboutHelp = try declarationSource(
            startMarker: "private var aboutAndHelpSection: some View {",
            endMarker: "private func sectionHeading",
            in: "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift"
        )
        XCTAssertFalse(aboutHelp.contains("CommonPlateStyle.Color.warmSurface"))
        XCTAssertFalse(aboutHelp.contains("How requesting and helping fit together"))
        XCTAssertFalse(aboutHelp.contains("Understand the exchange’s safety boundaries"))
        XCTAssertFalse(aboutHelp.contains("Get help with CommonPlate"))
        XCTAssertTrue(aboutHelp.contains("SettingsRow(title: \"How CommonPlate Works\")"))
        XCTAssertTrue(aboutHelp.contains("SettingsRow(title: \"Privacy & Safety\")"))
        XCTAssertTrue(aboutHelp.contains("SettingsRow(title: \"Support\")"))

        let requestAlerts = try declarationSource(
            startMarker: "private var requestAlertsSection: some View {",
            endMarker: "// MARK: - About & Help",
            in: "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift"
        )
        // Final H2 visual alignment FIX (supersedes both the prior "Request
        // Alerts remains inline in Settings for later management" wording
        // and the intermediate compact "Set up"/"Manage" row): Settings
        // presents Email/Push as the approved Figma `Control / Toggle` rows,
        // not the embedded `AlertSignupView` form and not a `NavigationLink`
        // destination — turning a toggle on opens the existing focused
        // overlay instead.
        XCTAssertFalse(requestAlerts.contains("NavigationLink(value: AppRoute.alerts)"))
        XCTAssertFalse(requestAlerts.contains("subtitle: \"Manage how CommonPlate can alert you\""))
        XCTAssertFalse(requestAlerts.contains("AlertSignupView("))
        XCTAssertTrue(requestAlerts.contains("Toggle(title, isOn: isOn)"))

        let settings = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")
        XCTAssertTrue(settings.contains("title: \"Email\""))
        XCTAssertTrue(settings.contains("title: \"Push\""))
    }

    /// W4-H2: Home is now the live exchange board, not a static launcher.
    /// Request a Meal remains persistently available and Settings remains
    /// reachable from the gear — this replaces the old two-zone-composition
    /// proof, which asserted structure H2 explicitly supersedes.
    func testHomeExchangeKeepsRequestAMealPersistentAndSettingsReachable() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertTrue(source.contains("home-request-a-meal"))
        XCTAssertTrue(source.contains("NavigationLink(value: AppRoute.settings)"))
        XCTAssertTrue(source.contains(".safeAreaInset(edge: .bottom)"))
        XCTAssertFalse(source.contains("Find a request"))
        XCTAssertFalse(source.contains("AppRoute.activeRequests"))
    }

    func testHomeUsesHelperWhenItNamesTheHelpingRole() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/ContentView.swift")
        XCTAssertTrue(source.contains("A helper with extra meal swipes chooses a request to help with."))
        XCTAssertFalse(source.contains("Another student with extra meal swipes chooses a request to help with."))
    }

    /// W4-H2: Home is now the board-first exchange — there is no "Find a
    /// request" launcher step, and identity/Privacy & Safety relocated to
    /// Settings. This proves the new content order instead: the board
    /// heading precedes the persistent Request a Meal action, which remains
    /// reachable via native vertical overflow (`safeAreaInset`, not a fixed
    /// absolute layout).
    func testHomeHasNativeVerticalOverflowWithoutChangingContentOrder() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        XCTAssertTrue(source.contains("ScrollView {"))
        XCTAssertTrue(source.contains(".safeAreaInset(edge: .bottom)"))

        let header = try XCTUnwrap(source.range(of: "private var header: some View"))
        let board = try XCTUnwrap(source.range(of: "private var boardSection: some View"))
        let requestMeal = try XCTUnwrap(source.range(of: "private var requestMealButton: some View"))
        XCTAssertLessThan(header.lowerBound, board.lowerBound)
        XCTAssertLessThan(board.lowerBound, requestMeal.lowerBound)
    }

    func testVerificationUsesDirectScrollableHierarchyWithoutGroupedSurfaces() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ParticipantVerificationView.swift")
        // W4-H2: Home's full-page canvas now lives in `HomeExchangeView`.
        let homeSource = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
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
