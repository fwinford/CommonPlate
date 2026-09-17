//
//  RequestFoodDraftSessionTests.swift
//  CommonPlateiosTests
//

import XCTest
@testable import CommonPlateios

@MainActor
final class RequestFoodDraftSessionTests: XCTestCase {
    func testManualDraftSurvivesRouteRecreationAndBackgroundInSameProcess() {
        let owner = RequestFoodDraftSession()
        let chosenTime = Date(timeIntervalSince1970: 1_776_000_000)
        owner.draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: "140 E 14th St"),
            menuPath: .mealExchange,
            timing: .later,
            preferredPickupTime: chosenTime,
            mealSwipes: 3,
            mealEntries: ["Chicken bowl with salsa", "Side salad", "Iced tea", "", ""],
            diningDollarsText: "4.75"
        )

        // Route exit/re-entry and scene backgrounding recreate views, not this
        // ContentView-owned process object.
        let reenteredOwner = owner

        XCTAssertEqual(reenteredOwner.draft.selectedDiningSpot?.name, "Palladium")
        XCTAssertEqual(reenteredOwner.draft.timing, .later)
        XCTAssertEqual(reenteredOwner.draft.preferredPickupTime, chosenTime)
        XCTAssertEqual(reenteredOwner.draft.mealSwipes, 3)
        // W4-R4: every structured value survives route recreation with the
        // rest of the draft, including the typed Dining Dollar estimate.
        XCTAssertEqual(reenteredOwner.draft.menuPath, .mealExchange)
        XCTAssertEqual(
            reenteredOwner.draft.activeMealEntries,
            ["Chicken bowl with salsa", "Side salad", "Iced tea"]
        )
        XCTAssertEqual(reenteredOwner.draft.diningDollarsText, "4.75")
    }

    func testProposalAndManualPrecedenceMetadataSurviveWithDraft() {
        let owner = RequestFoodDraftSession()
        owner.draft.selectedDiningSpot = DiningSpot(name: "Palladium", address: nil)
        owner.draft.mealEntries[0] = "Manual edit after proposal"
        owner.draft.mealSwipes = 2
        owner.screenshotManualEdits.manuallyEditedMealEntries = [0]
        owner.screenshotProvenance.location = true
        owner.screenshotProvenance.mealSwipes = true

        let reenteredOwner = owner

        XCTAssertEqual(reenteredOwner.draft.mealEntries[0], "Manual edit after proposal")
        XCTAssertTrue(reenteredOwner.screenshotManualEdits.hasManuallyEditedMealEntry(0))
        XCTAssertTrue(reenteredOwner.screenshotProvenance.location)
        XCTAssertFalse(reenteredOwner.screenshotProvenance.mealEntries.contains(0))
        XCTAssertTrue(reenteredOwner.screenshotProvenance.mealSwipes)
    }

    func testAuthoritativeCreationClearsCompletedDraftAndS1Metadata() {
        let owner = RequestFoodDraftSession()
        owner.draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            menuPath: .diningDollars,
            timing: .later,
            preferredPickupTime: Date(timeIntervalSince1970: 1_776_000_000),
            mealSwipes: 4,
            mealEntries: ["Completed request", "", "", "", ""],
            orderDetails: "Completed order",
            diningDollarsText: "12.34"
        )
        owner.screenshotManualEdits.hasManuallyEditedLocation = true
        owner.screenshotManualEdits.manuallyEditedMealEntries = [0]
        owner.screenshotManualEdits.hasManuallyEditedMealSwipes = true
        owner.screenshotProvenance.location = true

        owner.clearAfterAuthoritativeCreation()

        XCTAssertNil(owner.draft.selectedDiningSpot)
        // A completed creation clears every structured value too, so a
        // genuinely new Request Food entry inherits nothing.
        XCTAssertEqual(owner.draft.mealEntries, RequestFoodFormDraft.emptyMealEntries)
        XCTAssertEqual(owner.draft.orderDetails, "")
        XCTAssertEqual(owner.draft.diningDollarsText, "")
        XCTAssertEqual(owner.draft.menuPath, .mealExchange)
        XCTAssertEqual(owner.draft.timing, .asap)
        XCTAssertEqual(owner.draft.mealSwipes, RequestFoodFormDraft.mealSwipeOptions.first)
        XCTAssertEqual(owner.screenshotManualEdits, ScreenshotFieldManualEditState())
        XCTAssertEqual(owner.screenshotProvenance, ScreenshotProposalAppliedFields())
    }

    func testOwnerIsWiredAboveRouteWithoutDurableOrCreateAuthority() throws {
        let contentSource = try fileSource("ios/CommonPlateios/CommonPlateios/ContentView.swift")
        let entrySource = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodEntryView.swift")
        let ownerSource = try fileSource("ios/CommonPlateios/CommonPlateios/Stores/RequestFoodDraftSession.swift")

        XCTAssertTrue(contentSource.contains("@StateObject private var requestFoodDraftSession"))
        XCTAssertTrue(contentSource.contains("draftSession: requestFoodDraftSession"))
        XCTAssertTrue(entrySource.contains("@ObservedObject var draftSession"))
        XCTAssertTrue(entrySource.contains("draftSession: draftSession"))
        for forbidden in ["UserDefaults", "AppStorage", "FileManager", "RequestService", "createRequest("] {
            XCTAssertFalse(ownerSource.contains(forbidden), forbidden)
        }
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
