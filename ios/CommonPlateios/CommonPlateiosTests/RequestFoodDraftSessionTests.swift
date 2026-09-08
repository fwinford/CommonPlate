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
            foodRequest: "Chicken bowl with salsa",
            pickupName: "Taylor",
            timing: .later,
            preferredPickupTime: chosenTime,
            mealSwipes: 3
        )

        // Route exit/re-entry and scene backgrounding recreate views, not this
        // ContentView-owned process object.
        let reenteredOwner = owner

        XCTAssertEqual(reenteredOwner.draft.selectedDiningSpot?.name, "Palladium")
        XCTAssertEqual(reenteredOwner.draft.foodRequest, "Chicken bowl with salsa")
        XCTAssertEqual(reenteredOwner.draft.pickupName, "Taylor")
        XCTAssertEqual(reenteredOwner.draft.timing, .later)
        XCTAssertEqual(reenteredOwner.draft.preferredPickupTime, chosenTime)
        XCTAssertEqual(reenteredOwner.draft.mealSwipes, 3)
    }

    func testProposalAndManualPrecedenceMetadataSurviveWithDraft() {
        let owner = RequestFoodDraftSession()
        owner.draft.selectedDiningSpot = DiningSpot(name: "Palladium", address: nil)
        owner.draft.foodRequest = "Manual edit after proposal"
        owner.draft.mealSwipes = 2
        owner.screenshotManualEdits.hasManuallyEditedFoodRequest = true
        owner.screenshotProvenance.location = true
        owner.screenshotProvenance.mealSwipes = true

        let reenteredOwner = owner

        XCTAssertEqual(reenteredOwner.draft.foodRequest, "Manual edit after proposal")
        XCTAssertTrue(reenteredOwner.screenshotManualEdits.hasManuallyEditedFoodRequest)
        XCTAssertTrue(reenteredOwner.screenshotProvenance.location)
        XCTAssertFalse(reenteredOwner.screenshotProvenance.foodRequest)
        XCTAssertTrue(reenteredOwner.screenshotProvenance.mealSwipes)
    }

    func testAuthoritativeCreationClearsCompletedDraftAndS1Metadata() {
        let owner = RequestFoodDraftSession()
        owner.draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "Completed request",
            pickupName: "Taylor",
            timing: .later,
            preferredPickupTime: Date(timeIntervalSince1970: 1_776_000_000),
            mealSwipes: 4
        )
        owner.screenshotManualEdits.hasManuallyEditedLocation = true
        owner.screenshotManualEdits.hasManuallyEditedFoodRequest = true
        owner.screenshotManualEdits.hasManuallyEditedMealSwipes = true
        owner.screenshotProvenance.location = true

        owner.clearAfterAuthoritativeCreation()

        XCTAssertNil(owner.draft.selectedDiningSpot)
        XCTAssertEqual(owner.draft.foodRequest, "")
        XCTAssertEqual(owner.draft.pickupName, "")
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
