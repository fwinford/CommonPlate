//
//  HelperJourneyFulfillmentTests.swift
//  CommonPlateiosTests
//
// Focused W4-H1 presentation proof that needs no network: the Helping page's
// accepted copy and derivations, the Open Grubhub safety gate, Finish helping
// enablement, the success copy / exactly-once ledger / Reduce Motion plan, and
// source-level guarantees that the legacy T−3 interaction, the acknowledgement
// gate, and helper Screenshot Assistance are absent.
//
// Store-driven lifecycle proof lives in `HelperCompletionLifecycleTests`.
// Source inspection below proves wiring only; it is not simulator or
// physical-device evidence of rendering, motion, haptics, or VoiceOver.
import Foundation
import UIKit
import XCTest
@testable import CommonPlateios

@MainActor
final class HelperJourneyFulfillmentTests: XCTestCase {
    private let requestID = "helping-target"

    // MARK: - Entry and Helping page copy

    func testStartHelpingAndHelpingPageCopyIsExact() {
        XCTAssertEqual(RequestDetailView.claimActionTitle, "Start helping")
        XCTAssertEqual(FulfillRequestView.navigationTitle, "Helping")
        XCTAssertEqual(FulfillRequestView.reservedUntilLabel, "Reserved until")
        XCTAssertEqual(FulfillRequestView.addFiveMinutesTitle, "Add 5 minutes")
        XCTAssertEqual(FulfillRequestView.fiveMinutesAddedTitle, "5 minutes added")
        XCTAssertEqual(FulfillRequestView.cantExtendTitle, "Can't extend")
        XCTAssertEqual(FulfillRequestView.stopHelpingTitle, "Stop helping")
        XCTAssertEqual(FulfillRequestView.reservationWarningTitle, "5 minutes remain")
        XCTAssertEqual(FulfillRequestView.placeOrderHeading, "Place the order")
        XCTAssertEqual(FulfillRequestView.openGrubhubTitle, "Open Grubhub")
        XCTAssertEqual(FulfillRequestView.afterYouOrderHeading, "After you order")
        XCTAssertEqual(FulfillRequestView.submitTitle, "Finish helping")
        XCTAssertEqual(FulfillRequestView.submittingTitle, "Submitting…")
    }

    /// The accepted primary hierarchy, in order, with request timing as
    /// secondary context inside Dining location rather than its own section.
    func testHelpingPageHierarchyIsInTheAcceptedOrder() throws {
        let source = try appSource("Views/FulfillRequestView.swift")
        let placeOrder = try XCTUnwrap(section(
            of: source,
            from: "private func placeOrderSection(claim: ActiveClaimPresentation)",
            to: "/// The Open Grubhub safety gate for this screen's live state."
        ))
        let markers = [
            "label: Self.diningLocationLabel",
            "request.timingDescription",
            "label: Self.mealSwipesLabel",
            "label: Self.mealRequestLabel",
            // W4-R4 removed pickup name from the request contract, so the
            // `Name on order` row it rendered is gone from this hierarchy —
            // the removal H1's own third READY repair already accepted.
            "Text(Self.openGrubhubTitle)"
        ]
        var cursor = placeOrder.startIndex
        for marker in markers {
            let range = try XCTUnwrap(
                placeOrder.range(of: marker, range: cursor..<placeOrder.endIndex),
                "\(marker) out of order"
            )
            cursor = range.upperBound
        }
        XCTAssertEqual(FulfillRequestView.diningLocationLabel, "Dining location")
        XCTAssertEqual(FulfillRequestView.mealSwipesLabel, "Meal swipes")
        XCTAssertEqual(FulfillRequestView.mealRequestLabel, "Meal request")

        // Timing belongs to Dining location: it appears before the first
        // divider, not as its own labelled row.
        let timing = try XCTUnwrap(placeOrder.range(of: "request.timingDescription"))
        let firstDivider = try XCTUnwrap(placeOrder.range(of: "HelpingDivider()"))
        XCTAssertLessThan(timing.lowerBound, firstDivider.lowerBound)
        // No divider between the last labelled row and Open Grubhub. W4-R4
        // removed the `Name on order` row this previously anchored on, so it
        // anchors on Meal request — now the last row before Open Grubhub —
        // and the "no divider above Open Grubhub" property is unchanged.
        let mealRequest = try XCTUnwrap(placeOrder.range(of: "label: Self.mealRequestLabel"))
        XCTAssertNil(placeOrder.range(
            of: "HelpingDivider()",
            range: mealRequest.upperBound..<placeOrder.endIndex
        ))
    }

    /// `Reserved until HH:MM` is the authoritative expiry, statically
    /// formatted — the same rendering VoiceOver reads.
    func testReservedUntilDerivesFromTheAuthoritativeExpiry() {
        let expiry = Date(timeIntervalSince1970: 1_789_000_000)
        let time = expiry.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(FulfillRequestView.reservedUntilTime(expiry), time)
        XCTAssertEqual(ActiveRequestsView.reservedUntilText(expiry), "Reserved until \(time)")
    }

    // MARK: - Legacy T−3 removal

    func testLegacyT3InteractionIsGoneFromTheApp() throws {
        let retired = [
            "\"Need more time?\"",
            "\"Give me 5 more minutes\"",
            "\"Keep my current time\"",
            "claimExtensionPromptLead",
            "isShowingClaimExtensionPrompt",
            "hasResolvedClaimExtensionPrompt",
            "dismissClaimExtensionPrompt",
            "presentClaimExtensionPromptIfEligible"
        ]
        for file in try allAppSwiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for term in retired {
                XCTAssertFalse(source.contains(term), "\(term) in \(file.lastPathComponent)")
            }
        }
    }

    /// The warning draws attention back to the Helping page only: its one
    /// foreground route pushes the existing `.fulfillment` destination, and
    /// the Helping page renders the warning as a status line beside the one
    /// pair of reservation controls.
    func testWarningCreatesNoSeparateScreenOrDuplicateControls() throws {
        let contentView = try appSource("ContentView.swift")
        let warningRoute = try XCTUnwrap(section(
            of: contentView,
            from: ".onChange(of: requestStore.isShowingReservationWarning)",
            to: "// A requester-fulfillment tap always opens Home"
        ))
        XCTAssertTrue(warningRoute.contains("AppRoute.appending(.fulfillment(activeClaim.request)"))

        let helping = try appSource("Views/FulfillRequestView.swift")
        XCTAssertEqual(occurrences(of: "await store.extendActiveClaim()", in: helping), 1)
        XCTAssertEqual(occurrences(of: "await store.releaseActiveClaim()", in: helping), 1)
        let warningLine = try XCTUnwrap(section(
            of: helping,
            from: "if store.isShowingReservationWarning {",
            to: "private func reservationControls(claim: ActiveClaimPresentation)"
        ))
        XCTAssertFalse(warningLine.contains("Button"))
    }

    // MARK: - Open Grubhub safety gate

    func testOpenGrubhubGateTruthTable() {
        func gate(
            active: String? = "helping-target",
            fulfilling: Bool = false,
            ambiguity: Bool = false,
            confirmation: String? = nil
        ) -> Bool {
            FulfillRequestView.isOpenGrubhubAvailable(
                requestID: requestID,
                activeClaimRequestID: active,
                isFulfilling: fulfilling,
                hasFulfillmentAmbiguity: ambiguity,
                confirmationRequestID: confirmation
            )
        }

        XCTAssertTrue(gate())
        XCTAssertFalse(gate(active: nil), "no confirmed active reservation")
        XCTAssertFalse(gate(active: "another-request"), "reservation is for another request")
        XCTAssertFalse(gate(fulfilling: true), "during Finish helping submission")
        XCTAssertFalse(gate(ambiguity: true), "during ambiguity/recovery")
        XCTAssertFalse(gate(confirmation: requestID), "after confirmed placement")
        XCTAssertFalse(gate(active: nil, confirmation: nil), "placed relaunch")
    }

    func testOpenGrubhubIsRenderedOnlyBehindTheGateAndReachesNoStore() throws {
        let source = try appSource("Views/FulfillRequestView.swift")
        let button = try XCTUnwrap(source.range(of: "Button(action: openGrubhub)"))
        let gate = try XCTUnwrap(source.range(of: "if isOpenGrubhubAvailable {"))
        XCTAssertLessThan(gate.lowerBound, button.lowerBound)

        let action = try XCTUnwrap(section(
            of: source,
            from: "private func openGrubhub() {",
            to: "// MARK: - After you order"
        ))
        XCTAssertTrue(action.contains("guard isOpenGrubhubAvailable else { return }"))
        XCTAssertFalse(action.contains("store."), "the handoff must not touch RequestStore")

        let handoff = try XCTUnwrap(section(
            of: source,
            from: "enum GrubhubHandoff {",
            to: "/// The claimant-only continuous Helping page (W4-H1)"
        ))
        XCTAssertFalse(handoff.contains("RequestStore"))
        XCTAssertEqual(GrubhubHandoff.appURL.absoluteString, "grubhub://")
        XCTAssertEqual(
            FulfillRequestView.grubhubOpenFailureNotice,
            "Couldn't open Grubhub. Open the Grubhub app to place the order."
        )
    }

    // MARK: - Manual fulfillment

    func testFinishHelpingRequiresEveryRequiredFieldToBeValid() {
        let complete = FulfillmentFormDraft(
            orderNumber: "0070154321",
            eta: FulfillmentReadyTime.thirtyMinutes.etaValue,
            readyTime: .thirtyMinutes,
            contactMessage: ""
        )
        XCTAssertTrue(FulfillRequestView.isSubmissionEnabled(draft: complete, isOperationallyAvailable: true))
        XCTAssertFalse(FulfillRequestView.isSubmissionEnabled(draft: complete, isOperationallyAvailable: false))

        var noETA = complete
        noETA.readyTime = nil
        noETA.eta = ""
        var lettersInOrderNumber = complete
        lettersInOrderNumber.orderNumber = "70A"
        var emptyOrderNumber = complete
        emptyOrderNumber.orderNumber = "  "
        var tooLong = complete
        tooLong.orderNumber = String(repeating: "1", count: 51)
        for draft in [noETA, lettersInOrderNumber, emptyOrderNumber, tooLong] {
            XCTAssertFalse(
                FulfillRequestView.isSubmissionEnabled(draft: draft, isOperationallyAvailable: true),
                "\(draft)"
            )
        }

        // Message is optional.
        var withMessage = complete
        withMessage.contactMessage = "By the pickup shelf"
        XCTAssertTrue(FulfillRequestView.isSubmissionEnabled(draft: withMessage, isOperationallyAvailable: true))
    }

    /// The manual fields map onto the unchanged `orderNumber` / `eta` /
    /// `contactMessage` contract, with digits (and leading zeroes) preserved.
    func testManualFieldsMapToTheExistingFulfillmentContract() async throws {
        var submitted: FulfillmentSubmissionValues?
        let result = try await FulfillRequestView.orchestrateSubmission(
            draft: FulfillmentFormDraft(
                orderNumber: " 0070154321 ",
                eta: FulfillmentReadyTime.asap.etaValue,
                readyTime: .asap,
                contactMessage: "  "
            ),
            presentation: FulfillmentValidationPresentation()
        ) { values in
            submitted = values
        }
        XCTAssertTrue(result.didSubmit)
        XCTAssertEqual(
            submitted,
            FulfillmentSubmissionValues(orderNumber: "0070154321", eta: "ASAP", contactMessage: nil)
        )
    }

    func testSubmittingIsNotPresentedAsSuccess() {
        XCTAssertTrue(FulfillRequestView.showsSubmittingState(isFulfilling: true, hasMatchingAmbiguity: false))
        XCTAssertFalse(FulfillRequestView.showsSubmittingState(isFulfilling: false, hasMatchingAmbiguity: false))
        XCTAssertFalse(FulfillRequestView.showsSubmittingState(isFulfilling: true, hasMatchingAmbiguity: true))
        XCTAssertFalse(FulfillRequestView.submittingTitle.localizedCaseInsensitiveContains("thanks"))
    }

    /// Faith's physical-acceptance decision: `After you order` proceeds
    /// straight to its fields. The V1 Reply-To disclosure belongs to W4-T1.
    func testAfterYouOrderHasNoReplyToDisclosureBeforeItsFields() throws {
        let source = try appSource("Views/FulfillRequestView.swift")
        for retired in [
            "If the email reaches the student, they can reply to your verified NYU email.",
            "helperEmailNotice",
            "fulfillment-verified-helper-notice"
        ] {
            XCTAssertFalse(source.contains(retired), retired)
        }
        let section = try XCTUnwrap(self.section(
            of: source,
            from: "private var afterYouOrderSection: some View {",
            to: "private var fulfillmentFields: some View {"
        ))
        let heading = try XCTUnwrap(section.range(of: "Text(Self.afterYouOrderHeading)"))
        let fields = try XCTUnwrap(section.range(of: "fulfillmentFields"))
        XCTAssertNil(
            section.range(of: "Text(", range: heading.upperBound..<fields.lowerBound),
            "no explanatory paragraph between the heading and the fields"
        )
    }

    /// Request Detail follows the approved flat H1 summary (Figma 357:1085):
    /// meal swipes with timing, dining location, meal request, and a pinned
    /// `Start helping` — no card treatment and no explanatory reservation copy.
    func testRequestDetailUsesTheApprovedFlatSummaryAndPinnedStartHelping() throws {
        let source = try appSource("Views/RequestDetailView.swift")
        let summary = try XCTUnwrap(section(
            of: source,
            from: "private var requestSummary: some View {",
            to: "private var claimSection: some View {"
        ))
        var cursor = summary.startIndex
        for marker in [
            "RequestDetailEyebrow(text: \"Meal swipes\")",
            "RequestCardView.mealSwipesText(request.mealSwipes)",
            "request.timingDescription",
            "RequestDetailDivider()",
            "RequestDetailEyebrow(text: \"Dining location\")",
            "request.diningSpot.name",
            "RequestDetailDivider()",
            "RequestDetailEyebrow(text: \"Meal request\")",
            "request.foodDescription"
        ] {
            let range = try XCTUnwrap(
                summary.range(of: marker, range: cursor..<summary.endIndex),
                "\(marker) out of order"
            )
            cursor = range.upperBound
        }
        for retired in ["RoundedRectangle", ".background(", "Form {", "Section("] {
            XCTAssertFalse(summary.contains(retired), retired)
        }

        let body = try XCTUnwrap(section(
            of: source,
            from: "    var body: some View {",
            to: ".navigationTitle(\"Request\")"
        ))
        XCTAssertFalse(body.contains("Form {"))
        XCTAssertFalse(body.contains("Section(\"Food request\")"))
        let scroll = try XCTUnwrap(body.range(of: "ScrollView {"))
        let pinned = try XCTUnwrap(body.range(of: ".safeAreaInset(edge: .bottom) {"))
        XCTAssertLessThan(scroll.lowerBound, pinned.lowerBound)
        XCTAssertTrue(body[pinned.lowerBound...].contains("claimSection"))

        let claim = try XCTUnwrap(section(
            of: source,
            from: "private var claimSection: some View {",
            to: "static let claimActionTitle"
        ))
        // Same production bottom-action geometry as Home's `Request a Meal`.
        XCTAssertTrue(claim.contains(".commonPlateMajorPrimaryAction()"))
        XCTAssertFalse(claim.contains("HelperPrimaryActionButtonStyle"))
        let pinnedSurface = body[pinned.lowerBound...]
        XCTAssertTrue(pinnedSurface.contains(".padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)"))
        XCTAssertTrue(pinnedSurface.contains(".padding(.top, CommonPlateStyle.Spacing.xl)"))
        XCTAssertTrue(pinnedSurface.contains("LinearGradient"))
        XCTAssertFalse(pinnedSurface.contains(".padding(.bottom"), "safe-area inset is the only bottom clearance")
        XCTAssertFalse(pinnedSurface.contains("settingsPageInset"))

        let home = try appSource("Views/HomeExchangeView.swift")
        let homeCTA = try XCTUnwrap(section(
            of: home,
            from: "private var requestMealButton: some View {",
            to: "// MARK: - Copy"
        ))
        for shared in [
            ".commonPlateMajorPrimaryAction()",
            ".padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)",
            ".frame(height: CommonPlateStyle.Spacing.xl)"
        ] {
            XCTAssertTrue(homeCTA.contains(shared), "Home reference: \(shared)")
        }
        XCTAssertTrue(claim.contains("startClaim()"))
        XCTAssertFalse(claim.contains("claimConsequenceNotice"))
    }

    func testNoHelperScreenshotAssistanceIsIntroduced() throws {
        let source = try appSource("Views/FulfillRequestView.swift")
        for term in ["Screenshot", "PhotosPicker", "ScreenshotProposal"] {
            XCTAssertFalse(source.contains(term), term)
        }
    }

    // MARK: - Success

    func testSuccessAnnouncementIsConciseAndTruthful() {
        XCTAssertEqual(
            HelperSuccessCopy.accessibilityAnnouncement(for: .notificationSent),
            "Thanks for helping. We emailed the requester."
        )
        XCTAssertEqual(
            HelperSuccessCopy.accessibilityAnnouncement(for: .notificationFailed),
            "Thanks for helping. We couldn't email the requester."
        )
        XCTAssertEqual(
            HelperSuccessCopy.accessibilityAnnouncement(for: .emailStatusUnknown),
            "Thanks for helping."
        )
    }

    func testSuccessLedgerAllowsOneHapticAndOneHomeReturnPerConfirmation() {
        var ledger = HelperSuccessPresentationLedger()
        let first = UUID()
        let second = UUID()

        XCTAssertFalse(ledger.hasResolved(first))
        XCTAssertTrue(ledger.claimSuccessHaptic(for: first))
        XCTAssertTrue(ledger.hasResolved(first))
        XCTAssertFalse(ledger.claimSuccessHaptic(for: first), "a rebuilt presentation must not replay the haptic")
        XCTAssertTrue(ledger.claimHomeReturn(for: first))
        XCTAssertFalse(ledger.claimHomeReturn(for: first), "Home return happens exactly once")

        XCTAssertTrue(ledger.claimSuccessHaptic(for: second))
        XCTAssertTrue(ledger.claimHomeReturn(for: second))

        // A relaunched process starts empty, but it also has no confirmation
        // to present (see `HelperCompletionLifecycleTests`).
        XCTAssertEqual(HelperSuccessPresentationLedger(), HelperSuccessPresentationLedger())
    }

    /// The one success haptic lives only in the coordinator's production
    /// resolve effect, which runs only behind the ledger at an active resolve
    /// (proven behaviorally in `HelperSuccessForegroundProgressionTests`).
    /// Submit, ambiguity, failure, and relaunch paths have no call.
    func testSuccessHapticHasExactlyOneCallSite() throws {
        let success = try appSource("Views/HelperSuccessView.swift")
        XCTAssertEqual(occurrences(of: "CommonPlateHaptics.success()", in: success), 1)
        let resolve = try XCTUnwrap(section(
            of: success,
            from: "static func productionResolve(_ confirmation: FulfillmentConfirmation) {",
            to: "func update(confirmation newConfirmation: FulfillmentConfirmation?"
        ))
        XCTAssertTrue(resolve.contains("CommonPlateHaptics.success()"))

        for path in [
            "ContentView.swift",
            "Views/FulfillRequestView.swift",
            "Stores/RequestStore.swift",
            "Views/HomeExchangeView.swift",
            "Views/ActiveRequestsView.swift",
            "Views/RequestDetailView.swift"
        ] {
            XCTAssertFalse(try appSource(path).contains("CommonPlateHaptics"), path)
        }
    }

    /// Success is presented only from in-process confirmed placement, has no
    /// acknowledgement control, and performs the one Home return itself.
    func testSuccessPresentationHasNoAcknowledgementAndReturnsHomeOnce() throws {
        let success = try appSource("Views/HelperSuccessView.swift")
        XCTAssertFalse(success.contains("Button"), "no Got It / Done / acknowledgement control")
        for retired in ["Got It", "Got it", "\"Done\"", "The order was placed", "Order recorded"] {
            XCTAssertFalse(success.contains(retired), retired)
        }

        let contentView = try appSource("ContentView.swift")
        XCTAssertTrue(contentView.contains("if let confirmation = requestStore.fulfillmentConfirmation {"))
        let install = try XCTUnwrap(section(
            of: contentView,
            from: "private func installHelperSuccessHomeReturn() {",
            to: "/// Request Food owns a vertical Soft Flow transition."
        ))
        XCTAssertTrue(install.contains("AppRoute.afterHelperSuccess(from: pathBinding.wrappedValue)"))
        XCTAssertTrue(install.contains("store.dismissFulfillmentConfirmation(id: confirmation.id)"))
        // Scene activity and confirmation changes both feed the coordinator.
        XCTAssertEqual(occurrences(of: "helperSuccessCoordinator.updateSceneActivity(isActive: isActive)", in: contentView), 2)
        XCTAssertTrue(contentView.contains(".onChange(of: requestStore.fulfillmentConfirmation?.id)"))

        // No other surface renders or retires a confirmation.
        for path in ["Views/HomeExchangeView.swift", "Views/ActiveRequestsView.swift"] {
            XCTAssertFalse(try appSource(path).contains("fulfillmentConfirmation"), path)
        }
        // The store creates a confirmation only from confirmed placement.
        let store = try appSource("Stores/RequestStore.swift")
        XCTAssertEqual(occurrences(of: "fulfillmentConfirmation = FulfillmentConfirmation(", in: store), 1)
        XCTAssertFalse(store.contains("unacknowledgedPlacement"))
    }

    func testReduceMotionMateriallyLowersDisplacementAndKeepsTheTicketToMealTransition() {
        let standard = HelperSuccessMotionPlan.plan(reduceMotion: false)
        let reduced = HelperSuccessMotionPlan.plan(reduceMotion: true)
        XCTAssertEqual(standard, .standard)
        XCTAssertEqual(reduced, .reducedMotion)

        XCTAssertGreaterThan(abs(standard.ticketStartOffset.height), 0)
        XCTAssertNotEqual(standard.ticketStartOffset.width, 0, "a curved, connected path")
        XCTAssertLessThanOrEqual(abs(standard.ticketRotation), 8, "minimal rotation")

        XCTAssertEqual(reduced.ticketStartOffset, .zero)
        XCTAssertEqual(reduced.ticketRotation, 0)
        XCTAssertEqual(reduced.ticketEndScale, 1)
        XCTAssertEqual(reduced.mealStartScale, 1)
        XCTAssertEqual(reduced.copyRise, 0)
        // Meaning is preserved: the ticket still crossfades to the meal.
        XCTAssertGreaterThan(reduced.transformDuration, .zero)

        // Brief and readable in both modes.
        for plan in [standard, reduced] {
            XCTAssertGreaterThanOrEqual(plan.readableDwell, .milliseconds(1500))
            XCTAssertLessThanOrEqual(plan.totalDuration, .seconds(4))
        }

        let success = try? appSource("Views/HelperSuccessView.swift")
        XCTAssertEqual(success?.contains("HelperSuccessMotionPlan.plan(reduceMotion: reduceMotion)"), true)
        XCTAssertEqual(success?.contains("Image(\"HelperSuccessTicket\")"), true)
        XCTAssertEqual(success?.contains("Image(\"HelperSuccessMeal\")"), true)
        for forbidden in ["checkmark", "confetti", "particle", ".spring", "bouncy"] {
            XCTAssertEqual(success?.localizedCaseInsensitiveContains(forbidden), false, forbidden)
        }
    }

    /// Both success graphics render as templates tinted by the adaptive
    /// `AccentColor`, exactly like the existing `TicketToMealMotif`, so the
    /// approved ticket and meal geometry stays visible on the dark canvas.
    func testSuccessGraphicsAdaptToLightAndDarkAppearance() throws {
        let bundle = Bundle(for: RequestStore.self)
        for name in ["HelperSuccessTicket", "HelperSuccessMeal"] {
            let image = try XCTUnwrap(UIImage(named: name, in: bundle, compatibleWith: nil), name)
            XCTAssertEqual(image.renderingMode, .alwaysTemplate, name)

            let contents = try String(
                contentsOf: appRoot().appendingPathComponent("Assets.xcassets/\(name).imageset/Contents.json"),
                encoding: .utf8
            )
            XCTAssertTrue(contents.contains("\"template-rendering-intent\" : \"template\""), name)
            XCTAssertTrue(contents.contains("\"preserves-vector-representation\" : true"), name)
        }

        let accent = try XCTUnwrap(UIColor(named: "AccentColor", in: bundle, compatibleWith: nil))
        let light = accent.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = accent.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        XCTAssertNotEqual(light, dark, "the tint adapts to appearance")
        let canvas = try XCTUnwrap(UIColor(named: "CommonPlateBaseCanvas", in: bundle, compatibleWith: nil))
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        XCTAssertGreaterThan(
            luminance(dark) - luminance(canvas),
            0.2,
            "the dark-appearance graphic is clearly lighter than the dark canvas"
        )

        let success = try appSource("Views/HelperSuccessView.swift")
        XCTAssertEqual(occurrences(of: ".renderingMode(.template)", in: success), 2)
        XCTAssertEqual(occurrences(of: ".foregroundStyle(Color.accentColor)", in: success), 2)
    }

    // MARK: - Helpers

    private func luminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    private func appRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios (project folder)
            .appendingPathComponent("CommonPlateios")
    }

    private func appSource(_ relativePath: String) throws -> String {
        try String(contentsOf: appRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func allAppSwiftFiles() throws -> [URL] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: appRoot(), includingPropertiesForKeys: nil)
        )
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func section(of source: String, from start: String, to end: String) -> Substring? {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            return nil
        }
        return source[startRange.lowerBound..<endRange.lowerBound]
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
