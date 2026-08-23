//
//  HomeOwnershipPartitionRegressionTests.swift
//  CommonPlateiosTests
//
// W4-H4 review follow-up (ACTIVE / FIX): the existing `ownRequestsPreview`
// coverage in HomeExchangeBoardStateTests exercises an already-partitioned
// `owned` array — it proves the 0/1/2/3+ preview shape but not the upstream
// invariant that every caller-owned request in a mixed authoritative board
// is excluded from `Needs help right now`, including an owned request beyond
// the two-card Home preview. This file exercises the production
// `HomeExchangeView.partitionByOwnership` seam directly — the same function
// `ownRequests` and `populatedBoard(_:)` both derive from — against a mixed
// authoritative list, without duplicating its filtering algorithm.
import Foundation
import XCTest
@testable import CommonPlateios

final class HomeOwnershipPartitionRegressionTests: XCTestCase {
    private func request(id: String, ownership: RequestOwnership) -> FoodRequest {
        FoodRequest(
            id: id,
            diningSpot: DiningSpot(name: "Palladium", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 2,
            windowStart: nil,
            windowEnd: nil,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            status: .open,
            ownership: ownership
        )
    }

    /// Mixed authoritative order: 4 owned requests interleaved with 3
    /// helper-eligible requests owned by other participants, so accidental
    /// reordering within either zone is detectable.
    private var mixedAuthoritativeBoard: [FoodRequest] {
        [
            request(id: "owned-1", ownership: .own),
            request(id: "other-1", ownership: .notOwn),
            request(id: "owned-2", ownership: .own),
            request(id: "other-2", ownership: .notOwn),
            request(id: "owned-3", ownership: .own),
            request(id: "other-3", ownership: .notOwn),
            request(id: "owned-4", ownership: .own),
        ]
    }

    /// 1. The full authoritative owned partition contains every owned
    /// request, in authoritative order.
    func testPartitionOwnedContainsEveryOwnedRequestInAuthoritativeOrder() {
        let partition = HomeExchangeView.partitionByOwnership(mixedAuthoritativeBoard)
        XCTAssertEqual(partition.owned.map(\.id), ["owned-1", "owned-2", "owned-3", "owned-4"])
    }

    /// 2. The Home ownership preview contains only the first two when owned
    /// count is 3+.
    func testHomePreviewCapsAtTwoWhenFourAreOwned() {
        let partition = HomeExchangeView.partitionByOwnership(mixedAuthoritativeBoard)
        let preview = HomeExchangeView.ownRequestsPreview(partition.owned)
        XCTAssertEqual(preview.cards.map(\.id), ["owned-1", "owned-2"])
        XCTAssertEqual(preview.seeAllCount, 4)
    }

    /// 3. The third and later owned requests remain part of the
    /// authoritative owned set even though hidden from the Home preview.
    func testThirdAndLaterOwnedRequestsRemainInTheAuthoritativeOwnedSetDespiteBeingHiddenFromThePreview() {
        let partition = HomeExchangeView.partitionByOwnership(mixedAuthoritativeBoard)
        let preview = HomeExchangeView.ownRequestsPreview(partition.owned)
        let hiddenFromPreview = Set(partition.owned.map(\.id)).subtracting(preview.cards.map(\.id))

        XCTAssertEqual(hiddenFromPreview, ["owned-3", "owned-4"])
        XCTAssertTrue(partition.owned.map(\.id).contains("owned-3"))
        XCTAssertTrue(partition.owned.map(\.id).contains("owned-4"))
    }

    /// 4. None of the owned requests appear in `Needs help right now`,
    /// including the ones beyond the two-card Home preview.
    func testNoneOfTheOwnedRequestsAppearInNeedsHelpRegardlessOfPreviewVisibility() {
        let partition = HomeExchangeView.partitionByOwnership(mixedAuthoritativeBoard)
        let ownedIDs = Set(partition.owned.map(\.id))
        let needsHelpIDs = Set(partition.needsHelp.map(\.id))

        XCTAssertTrue(ownedIDs.isDisjoint(with: needsHelpIDs))
        for ownedID in ["owned-1", "owned-2", "owned-3", "owned-4"] {
            XCTAssertFalse(needsHelpIDs.contains(ownedID))
        }
    }

    /// 5. Eligible non-owned requests remain in `Needs help` in accepted
    /// (authoritative) order.
    func testEligibleNonOwnedRequestsRemainInNeedsHelpInAuthoritativeOrder() {
        let partition = HomeExchangeView.partitionByOwnership(mixedAuthoritativeBoard)
        XCTAssertEqual(partition.needsHelp.map(\.id), ["other-1", "other-2", "other-3"])
    }

    /// 6. Ownership/filtering authority is unchanged: partitioning is driven
    /// solely by `FoodRequest.isOwnRequest` (`ownership == .own`), never a
    /// local heuristic, and every input request lands in exactly one zone.
    func testPartitionIsExhaustiveAndDrivenOnlyByIsOwnRequest() {
        let partition = HomeExchangeView.partitionByOwnership(mixedAuthoritativeBoard)

        XCTAssertEqual(partition.owned.count + partition.needsHelp.count, mixedAuthoritativeBoard.count)
        XCTAssertTrue(partition.owned.allSatisfy(\.isOwnRequest))
        XCTAssertTrue(partition.needsHelp.allSatisfy { !$0.isOwnRequest })
    }
}
