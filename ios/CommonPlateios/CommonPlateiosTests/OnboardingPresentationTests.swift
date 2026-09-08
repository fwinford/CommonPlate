//
//  OnboardingPresentationTests.swift
//  CommonPlateiosTests
//
// Focused W4-R1 proof that onboarding is a local presentation preference,
// never a participant role or authority record.

import XCTest
@testable import CommonPlateios

@MainActor
final class OnboardingPresentationTests: XCTestCase {
    func testFreshInstallationStartsWithOnboardingIncomplete() {
        let storage = InMemoryOnboardingPresentationStorage()

        XCTAssertFalse(OnboardingPresentationStore(storage: storage).hasCompletedOnboarding)
    }

    func testCompletionPersistsAcrossStoreReconstruction() {
        let storage = InMemoryOnboardingPresentationStorage()
        let firstStore = OnboardingPresentationStore(storage: storage)

        firstStore.completeOnboarding()

        XCTAssertTrue(storage.hasCompletedOnboarding)
        XCTAssertTrue(OnboardingPresentationStore(storage: storage).hasCompletedOnboarding)
    }

    func testCompletionPersistsThroughTheProductionUserDefaultsStorageBoundary() {
        let suiteName = "OnboardingPresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = UserDefaultsOnboardingPresentationStorage(defaults: defaults)

        OnboardingPresentationStore(storage: storage).completeOnboarding()

        let reconstructedStorage = UserDefaultsOnboardingPresentationStorage(defaults: defaults)
        XCTAssertTrue(OnboardingPresentationStore(storage: reconstructedStorage).hasCompletedOnboarding)
    }

    func testRequesterWalkthroughKeepsItsRequiredOrderedContent() throws {
        let requester = OnboardingWalkthroughView.content(for: .gettingAMeal)

        XCTAssertEqual(requester.title, "Getting a meal")
        XCTAssertEqual(requester.steps, [
            "Build your order in Grubhub",
            "Add your order details to CommonPlate",
            "A student reserves and places your order",
            "CommonPlate emails you the pickup details"
        ])
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/OnboardingExperienceView.swift")
        XCTAssertTrue(source.contains("WalkthroughStepRow("))
        XCTAssertTrue(source.contains("Text(\"\\(number)\")"))
        XCTAssertTrue(source.contains("Color.accentColor.opacity(0.12)"))
        XCTAssertTrue(source.contains(".frame(width: 46, height: 46)"))
        XCTAssertTrue(source.contains("HStack(alignment: .center, spacing: CommonPlateStyle.Spacing.l)"))
        XCTAssertTrue(source.contains(".padding(.horizontal, CommonPlateStyle.Spacing.s)"))
        XCTAssertFalse(source.contains("You build the order you want."))
        XCTAssertFalse(source.contains("CommonPlate helps another student place it for you."))
    }

    func testChooserUsesTheApprovedSmallTicketArrowBowlMotif() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/OnboardingExperienceView.swift")

        XCTAssertTrue(source.contains("Image(\"TicketToMealMotif\")"))
        XCTAssertTrue(source.contains(".renderingMode(.template)"))
        XCTAssertTrue(source.contains(".foregroundStyle(Color.accentColor)"))
        XCTAssertTrue(source.contains(".frame(width: 118, height: 46)"))
        XCTAssertFalse(source.contains("TicketOutline"))
        XCTAssertFalse(source.contains("BowlOutline"))
    }

    func testHelperWalkthroughKeepsItsRequiredOrderedContentAndAlertNote() throws {
        let helper = OnboardingWalkthroughView.content(for: .usingExtraSwipes)
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/OnboardingExperienceView.swift")

        XCTAssertEqual(helper.title, "Using your extra swipes")
        XCTAssertEqual(helper.steps, [
            "Browse available requests",
            "Choose a request",
            "Place the order in Grubhub",
            "Add the pickup details to CommonPlate"
        ])
        XCTAssertTrue(source.contains("CommonPlateStyle.Color.warmSurface"))
        XCTAssertFalse(source.contains("Choose a request, place the order in Grubhub, and give CommonPlate the pickup details."))
        XCTAssertTrue(source.contains("No requests available?"))
        XCTAssertTrue(source.contains("Turn on request alerts from Home."))
        XCTAssertFalse(source.contains("CommonPlate sends you the pickup details you need."))
        XCTAssertFalse(source.contains("CommonPlate sends the student the pickup details you entered."))
    }

    func testWalkthroughUsesSystemTitlesAndResponsiveBoundedContinuePlacement() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/OnboardingExperienceView.swift")
        let walkthrough = try declarationSource(
            startMarker: "struct OnboardingWalkthroughView: View {",
            endMarker: "private enum OnboardingWalkthroughLayout",
            in: source
        )

        XCTAssertTrue(walkthrough.contains("GeometryReader { geometry in"))
        XCTAssertTrue(walkthrough.contains("ScrollView {"))
        XCTAssertTrue(walkthrough.contains(".font(.title.weight(.bold))"))
        XCTAssertTrue(walkthrough.contains(".multilineTextAlignment(.center)"))
        XCTAssertFalse(walkthrough.contains("commonPlateBrandDisplay"))
        XCTAssertTrue(walkthrough.contains("Spacer(minLength: 0)"))
        XCTAssertTrue(walkthrough.contains(".frame(maxHeight: OnboardingWalkthroughLayout.continueSeparationMaximum)"))
        XCTAssertTrue(walkthrough.contains(".padding(.top, CommonPlateStyle.Spacing.l)"))
        XCTAssertTrue(walkthrough.contains(".frame(minHeight: geometry.size.height, alignment: .top)"))
        XCTAssertTrue(source.contains("static let continueSeparationMaximum: CGFloat = 128"))
    }

    func testHomeReplaysTheSameExperienceWithoutChangingCompletionOrIdentity() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/ContentView.swift")
        let onboarding = try fileSource("ios/CommonPlateios/CommonPlateios/Views/OnboardingExperienceView.swift")
        // W4-H2: the "How CommonPlate Works" entry point relocated from
        // Home's inline utility group to the shared Settings route; the
        // replay wiring itself (`onboardingChooser` destination/coordinator)
        // is unchanged and remains owned by `ContentView`.
        let settings = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")

        XCTAssertTrue(source.contains("if onboardingStore.hasCompletedOnboarding"))
        XCTAssertTrue(settings.contains("NavigationLink(value: AppRoute.onboardingChooser)"))
        XCTAssertTrue(settings.contains("\"How CommonPlate Works\""))
        XCTAssertTrue(source.contains("onboardingFlowCoordinator.beginReplay()"))
        XCTAssertTrue(source.contains("case .onboardingChooser:"))
        XCTAssertTrue(source.contains(".onAppear {\n                    onboardingFlowCoordinator.beginReplay()"))
        XCTAssertFalse(source.contains(".simultaneousGesture"))
        let storageSource = try fileSource("ios/CommonPlateios/CommonPlateios/Stores/OnboardingPresentationStorage.swift")
        let beginReplay = try declarationSource(
            startMarker: "func beginReplay() {",
            endMarker: "func replayNavigationChanged",
            in: storageSource
        )
        XCTAssertFalse(beginReplay.contains("selectedIntent = nil"))
        XCTAssertTrue(source.contains("completeOnboardingFromWalkthrough()"))
        XCTAssertFalse(onboarding.contains("@Environment(\\.dismiss) private var dismiss"))
        XCTAssertFalse(onboarding.contains("await Task.yield()"))

        let storage = InMemoryOnboardingPresentationStorage()
        let store = OnboardingPresentationStore(storage: storage)
        store.completeOnboarding()
        let coordinator = OnboardingFlowCoordinator(presentationStore: store)

        coordinator.beginReplay()
        coordinator.selectedIntent = .usingExtraSwipes
        coordinator.continueFromWalkthrough()

        XCTAssertTrue(store.hasCompletedOnboarding)
        XCTAssertTrue(storage.hasCompletedOnboarding)
        XCTAssertFalse(coordinator.isReplaying)
        XCTAssertNil(coordinator.selectedIntent)
        XCTAssertEqual(coordinator.completionPresentationIntent, .usingExtraSwipes)
        coordinator.finishCompletionPresentation()
        XCTAssertFalse(coordinator.isCompletingOnboarding)
    }

    func testFirstLaunchActionsAreTitleOnlyAndBothContinuePathsSynchronouslyReachPersistedHomeState() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/OnboardingExperienceView.swift")

        for intent in [OnboardingIntent.gettingAMeal, .usingExtraSwipes] {
            let storage = InMemoryOnboardingPresentationStorage()
            let store = OnboardingPresentationStore(storage: storage)
            let coordinator = OnboardingFlowCoordinator(presentationStore: store)
            coordinator.selectedIntent = intent
            coordinator.continueFromWalkthrough()

            XCTAssertNil(coordinator.selectedIntent)
            XCTAssertFalse(coordinator.isReplaying)
            XCTAssertTrue(coordinator.isCompletingOnboarding)
            XCTAssertTrue(store.hasCompletedOnboarding)
            XCTAssertTrue(storage.hasCompletedOnboarding)
        }

        XCTAssertTrue(source.contains("onStartFlow(intent)"))
        XCTAssertTrue(source.contains("padding(.bottom, CommonPlateStyle.Spacing.m)"))
        XCTAssertTrue(source.contains("padding(.top, CommonPlateStyle.Spacing.s)"))
        XCTAssertTrue(source.contains(".frame(maxWidth: 520)"))
        XCTAssertTrue(source.contains(".frame(minHeight: geometry.size.height, alignment: .top)"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: ".commonPlateMajorActionFrame()").count - 1,
            2
        )
        XCTAssertFalse(source.contains("See how getting a meal works"))
        XCTAssertFalse(source.contains("See how using extra swipes works"))
        XCTAssertFalse(source.contains("subtitle:"))
    }

    /// W4-H2 supersedes R1's two-zone static composition with the live
    /// exchange board (E1). This now proves the board-first replacement
    /// structure instead of the retired zone layout.
    func testHomeUsesTheBoardFirstExchangeComposition() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertTrue(source.contains("GeometryReader { geometry in"))
        XCTAssertTrue(source.contains(".frame(minHeight: geometry.size.height, alignment: .top)"))
        XCTAssertTrue(source.contains("continueHelpingSection"))
        XCTAssertTrue(source.contains("boardSection"))
        XCTAssertTrue(source.contains("home-request-a-meal"))
        XCTAssertFalse(source.contains("HomeActionRow"))
        XCTAssertFalse(source.contains("Text(\"More\")"))
        XCTAssertFalse(source.contains("Get alerts for new requests"))
        XCTAssertFalse(source.contains("Find a request"))
    }

    func testCompletionTransitionUsesTheSelectedSoftBrandSettleAndPreservesReduceMotion() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/ContentView.swift")

        XCTAssertTrue(source.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
        let storageSource = try fileSource("ios/CommonPlateios/CommonPlateios/Stores/OnboardingPresentationStorage.swift")

        XCTAssertTrue(source.contains("SoftBrandSettlePresentation("))
        XCTAssertTrue(source.contains("completionPresentationIntent"))
        XCTAssertTrue(source.contains("OnboardingWalkthroughView(intent: intent, onContinue: {})"))
        XCTAssertTrue(source.contains("home(hasArrived)"))
        XCTAssertTrue(source.contains("hasArrived || reduceMotion ? 0 : -7"))
        XCTAssertTrue(source.contains(".easeInOut(duration: 0.31)"))
        XCTAssertTrue(source.contains(".offset(y: hasArrived || reduceMotion ? 0 : 9)"))
        XCTAssertTrue(source.contains("duration: 0.43"))
        XCTAssertTrue(source.contains("duration: 0.47"))
        XCTAssertTrue(source.contains(".offset(y: brandHasSettled || reduceMotion ? 0 : 2)"))
        XCTAssertTrue(source.contains(".easeInOut(duration: 0.17)"))
        XCTAssertTrue(source.contains("transaction.disablesAnimations = true"))
        XCTAssertTrue(source.contains("withTransaction(transaction)"))
        XCTAssertTrue(source.contains("path = []"))
        XCTAssertTrue(storageSource.contains("@Published private(set) var isCompletingOnboarding = false"))
        XCTAssertTrue(storageSource.contains("completionPresentationIntent = selectedIntent"))
        XCTAssertFalse(storageSource.contains("Task.yield"))
        XCTAssertFalse(storageSource.contains("sleep("))
    }

    func testFinalR1MotionAndNavigationSeamsStayDistinct() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/ContentView.swift")
        let onboarding = try fileSource("ios/CommonPlateios/CommonPlateios/Views/OnboardingExperienceView.swift")
        let requestEntry = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodEntryView.swift")
        // W4-H2: both entry points relocated from Home to the shared
        // Settings route; the destination-building switch itself
        // (`case .onboardingChooser:` / `case .privacySafety:`) stays in
        // `ContentView` and is unchanged.
        let settings = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")

        XCTAssertTrue(source.contains("SoftFlowEnterDestination"))
        XCTAssertTrue(source.contains("case walkthrough(OnboardingIntent)"))
        XCTAssertTrue(source.contains("case route(AppRoute)"))
        XCTAssertTrue(source.contains("duration: 0.28"))
        // W4-R2 2026-09-05 sync item 8: `SoftFlowEnterDestination` gained a
        // `playsOwnSettle` parameter (defaulting to `true`, so every route
        // besides `.requestFood` keeps this exact offset/gating behavior
        // unchanged) so Request Food's own local Bottom Continuity settle can
        // become the entrance's sole owner without duplicating this shared
        // wrapper's own settle/hit-testing gate.
        XCTAssertTrue(source.contains("offset(y: playsOwnSettle && !hasEntered && !reduceMotion ? 6 : 0)"))
        XCTAssertTrue(source.contains("var playsOwnSettle: Bool = true"))
        XCTAssertTrue(source.contains("playsOwnSettle: route != .requestFood"))
        XCTAssertTrue(source.contains(".allowsHitTesting(playsOwnSettle ? hasEntered : true)"))
        XCTAssertTrue(source.contains("flowPresentation = .walkthrough(intent)\n            onboardingFlowCoordinator.selectedIntent = intent"))
        XCTAssertTrue(source.contains("flowPresentation = .route(route)\n            path = AppRoute.appending(route, to: path)"))
        XCTAssertTrue(source.contains("if case .route(let route)? = flowPresentation, newPath.last != route"))
        XCTAssertTrue(source.contains("if case .walkthrough? = flowPresentation, intent == nil"))
        // W4-R2: Request Food is now pushed through the same typed
        // `AppRoute.requestFood` destination every other route uses —
        // superseding the former Home-owned sheet special-case — and exits
        // through the same `finishPrimaryRoute` truncation every other
        // primary route uses.
        XCTAssertFalse(source.contains("isRequestFoodPresented"))
        XCTAssertFalse(source.contains("requestFoodPresentationPath"))
        XCTAssertTrue(source.contains("case .requestFood:"))
        XCTAssertTrue(source.contains("onExit: { finishPrimaryRoute(.requestFood) }"))
        XCTAssertFalse(requestEntry.contains("Color.clear"))
        // The pushed destination must keep ParticipantVerificationView's own
        // NavigationStack behind the accepted modal boundary. Mounting it
        // directly inside ContentView's typed root stack makes an interactive
        // request-food push fail with AnyNavigationPath comparison mismatch.
        XCTAssertTrue(requestEntry.contains(".sheet(isPresented: isPresentingEntryVerification)"))
        XCTAssertTrue(requestEntry.contains("case .verification:\n                CommonPlateStyle.Color.baseCanvas"))
        // The form destination no longer wraps itself in a second, nested
        // `NavigationStack` now that it is pushed directly on the root one.
        XCTAssertFalse(requestEntry.contains("NavigationStack {"))
        XCTAssertFalse(source.contains("flowDestination(for:"))
        XCTAssertFalse(source.contains("if let flowPresentation {"))
        XCTAssertTrue(settings.contains("NavigationLink(value: AppRoute.onboardingChooser)"))
        XCTAssertTrue(settings.contains("NavigationLink(value: AppRoute.privacySafety)"))
        XCTAssertTrue(source.contains(".toolbar(.hidden, for: .navigationBar)"))
        XCTAssertTrue(onboarding.contains(".overlay(alignment: .topLeading)"))
        XCTAssertTrue(onboarding.contains("navigationBarBackButtonHidden(onBack != nil)"))
        XCTAssertTrue(onboarding.contains(".toolbar(onBack == nil ? .automatic : .hidden, for: .navigationBar)"))
        XCTAssertTrue(onboarding.contains("CommonPlateWarmGhostBackButton"))
        XCTAssertTrue(onboarding.contains("Image(systemName: \"chevron.left\")"))
        XCTAssertTrue(onboarding.contains(".font(.system(size: 17, weight: .semibold))"))
        XCTAssertFalse(onboarding.contains(".font(.body.weight(.semibold))"))
        XCTAssertTrue(onboarding.contains("frame(width: 44, height: 44)"))
    }

    /// W4-R2 restyled these two fields into the approved `Requester / Form
    /// Field` bordered-card control (a `Menu` for meal swipes, matching the
    /// approved component's plain value display with no native
    /// `Picker`/list chrome) — the exact SwiftUI declaration this test
    /// pinned to before that restyle no longer exists. The substantive
    /// guarantee this test guards remains true and is asserted directly: the
    /// bounded meal-swipe range is unchanged, driven by the same
    /// `RequestFoodFormDraft.mealSwipeOptions`, and the accepted field labels
    /// are unchanged. The revised READY contract also removes the permanent
    /// meal-swipes helper sentence with no replacement, and the final R2
    /// contract renames the field label to `Name on order` with no separate
    /// timing-mixed sentence.
    func testRequesterGuidanceUsesTheAcceptedLabelsWithoutChangingThePickerRange() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")

        XCTAssertTrue(source.contains("mealSwipesControl"))
        XCTAssertTrue(source.contains("static let mealSwipesLabel = \"Meal swipes\""))
        XCTAssertFalse(source.contains("Choose how many meal swipes your Grubhub order requires."))
        XCTAssertTrue(source.contains("static let pickupNameLabel = \"Name on order\""))
        XCTAssertFalse(source.contains("Enter the name you want the Grubhub order placed under."))
        XCTAssertFalse(source.contains("The student placing the order will use this name and approximate time."))
        XCTAssertTrue(source.contains("RequestFoodFormDraft.mealSwipeOptions"))
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func declarationSource(
        startMarker: String,
        endMarker: String,
        in source: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(source.range(of: endMarker, range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}

private final class InMemoryOnboardingPresentationStorage: OnboardingPresentationStoring {
    var hasCompletedOnboarding = false
}
