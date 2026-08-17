//
//  HomeExchangeBoardStateTests.swift
//  CommonPlateiosTests
//
// Focused W4-H2 coverage for `HomeExchangeView.boardState`, the pure
// derivation behind Home's populated/low-activity, empty (E1), and
// unavailable (U4) board presentation. Exercised directly, without
// instantiating `RequestStore`, matching this target's existing
// testable-`static-func` pattern.
import Foundation
import XCTest
@testable import CommonPlateios

final class HomeExchangeBoardStateTests: XCTestCase {
    private func request(id: String) -> FoodRequest {
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
            status: .open
        )
    }

    func testLoadingBeforeAnyFetchAttempt() {
        let state = HomeExchangeView.boardState(
            hasSuccessfullyFetchedRequests: false,
            hasAttemptedRequestFetch: false,
            hasFailedInitialFetchAtLeastOnce: false,
            isFetching: false,
            requests: []
        )
        XCTAssertEqual(state, .loading)
    }

    /// Only the genuinely first-ever attempt reaches `.loading` while in
    /// flight — it has never yet failed, so `hasFailedInitialFetchAtLeastOnce`
    /// is still `false`.
    func testLoadingWhileTheFirstEverFetchIsInFlight() {
        let state = HomeExchangeView.boardState(
            hasSuccessfullyFetchedRequests: false,
            hasAttemptedRequestFetch: true,
            hasFailedInitialFetchAtLeastOnce: false,
            isFetching: true,
            requests: []
        )
        XCTAssertEqual(state, .loading)
    }

    /// U4: reached once a fetch has been attempted, has finished, and has
    /// never yet succeeded.
    func testUnavailableAfterAFinishedNeverSucceededFetch() {
        let state = HomeExchangeView.boardState(
            hasSuccessfullyFetchedRequests: false,
            hasAttemptedRequestFetch: true,
            hasFailedInitialFetchAtLeastOnce: true,
            isFetching: false,
            requests: []
        )
        XCTAssertEqual(state, .unavailable)
    }

    /// A retry (pull-to-refresh, or a later automatic attempt) launched from
    /// an already-resolved Unavailable state must keep showing Unavailable
    /// while it is in flight — not regress to the bare initial `.loading`
    /// presentation, which drops `Needs help` and every other Home element.
    /// `RequestStore.fetchRequests()` republishes exactly the same
    /// `hasAttemptedRequestFetch: true, isFetching: true,
    /// hasSuccessfullyFetchedRequests: false` snapshot for this retry as it
    /// does for the very first attempt in flight — only
    /// `hasFailedInitialFetchAtLeastOnce` tells the two apart.
    func testRetryInFlightAfterAnEarlierFailureStaysUnavailable() {
        let state = HomeExchangeView.boardState(
            hasSuccessfullyFetchedRequests: false,
            hasAttemptedRequestFetch: true,
            hasFailedInitialFetchAtLeastOnce: true,
            isFetching: true,
            requests: []
        )
        XCTAssertEqual(
            state,
            .unavailable,
            "expected a retry-in-flight after a prior failure to stay Unavailable, not regress to Loading"
        )
    }

    /// E1: a successful fetch with nothing to show — never confused with
    /// U4, which requires a fetch that never succeeded.
    func testEmptyAfterASuccessfulFetchWithNoRequests() {
        let state = HomeExchangeView.boardState(
            hasSuccessfullyFetchedRequests: true,
            hasAttemptedRequestFetch: true,
            hasFailedInitialFetchAtLeastOnce: false,
            isFetching: false,
            requests: []
        )
        XCTAssertEqual(state, .empty)
    }

    func testPopulatedPreservesBackendOrderAndMembershipExactly() {
        let requests = [request(id: "a"), request(id: "b"), request(id: "c")]
        let state = HomeExchangeView.boardState(
            hasSuccessfullyFetchedRequests: true,
            hasAttemptedRequestFetch: true,
            hasFailedInitialFetchAtLeastOnce: false,
            isFetching: false,
            requests: requests
        )
        guard case .populated(let rendered) = state else {
            return XCTFail("expected .populated")
        }
        XCTAssertEqual(rendered.map(\.id), ["a", "b", "c"])
    }

    /// Low Activity (Section 5): one real open request uses the exact same
    /// populated-board architecture — no special low-density state.
    func testSingleRequestUsesTheOrdinaryPopulatedState() {
        let state = HomeExchangeView.boardState(
            hasSuccessfullyFetchedRequests: true,
            hasAttemptedRequestFetch: true,
            hasFailedInitialFetchAtLeastOnce: false,
            isFetching: false,
            requests: [request(id: "only")]
        )
        guard case .populated(let rendered) = state else {
            return XCTFail("expected .populated")
        }
        XCTAssertEqual(rendered.count, 1)
    }

    // MARK: - HQ decision 5: initial-load presentation deadline

    /// Before the deadline elapses, an in-flight first-ever fetch still
    /// presents Loading exactly as before — this is a maximum wait, not an
    /// early exit.
    func testLoadingWhileFirstFetchInFlightBeforeDeadlineElapses() {
        let state = HomeExchangeView.boardState(
            hasSuccessfullyFetchedRequests: false,
            hasAttemptedRequestFetch: true,
            hasFailedInitialFetchAtLeastOnce: false,
            isFetching: true,
            requests: [],
            hasInitialLoadDeadlineElapsed: false
        )
        XCTAssertEqual(state, .loading)
    }

    /// Once the presentation deadline elapses with no authoritative result
    /// yet, Home leaves Loading for Exchange Unavailable even though the
    /// fetch itself is still in flight.
    func testUnavailableOnceDeadlineElapsesWithNoAuthoritativeResultYet() {
        let state = HomeExchangeView.boardState(
            hasSuccessfullyFetchedRequests: false,
            hasAttemptedRequestFetch: true,
            hasFailedInitialFetchAtLeastOnce: false,
            isFetching: true,
            requests: [],
            hasInitialLoadDeadlineElapsed: true
        )
        XCTAssertEqual(state, .unavailable)
    }

    /// The deadline flag is irrelevant once a fetch has actually succeeded —
    /// a same-still-current fetch that resolves after 5 seconds still
    /// recovers Home into its truthful populated state.
    func testDeadlineElapsedIsIgnoredOnceFetchHasSucceeded() {
        let requests = [request(id: "a")]
        let state = HomeExchangeView.boardState(
            hasSuccessfullyFetchedRequests: true,
            hasAttemptedRequestFetch: true,
            hasFailedInitialFetchAtLeastOnce: false,
            isFetching: false,
            requests: requests,
            hasInitialLoadDeadlineElapsed: true
        )
        guard case .populated(let rendered) = state else {
            return XCTFail("expected .populated even though the deadline elapsed")
        }
        XCTAssertEqual(rendered.map(\.id), ["a"])
    }

    /// The deadline flag is irrelevant once a fetch has already failed
    /// authoritatively — the ordinary failed-fetch path already reaches
    /// Unavailable on its own.
    func testDeadlineElapsedIsIgnoredOnceFetchHasFailed() {
        let state = HomeExchangeView.boardState(
            hasSuccessfullyFetchedRequests: false,
            hasAttemptedRequestFetch: true,
            hasFailedInitialFetchAtLeastOnce: true,
            isFetching: false,
            requests: [],
            hasInitialLoadDeadlineElapsed: true
        )
        XCTAssertEqual(state, .unavailable)
    }

    /// Omitting the parameter (every other existing call site) preserves the
    /// pre-deadline behavior exactly — the default is `false`.
    func testDeadlineParameterDefaultsToFalse() {
        let state = HomeExchangeView.boardState(
            hasSuccessfullyFetchedRequests: false,
            hasAttemptedRequestFetch: true,
            hasFailedInitialFetchAtLeastOnce: false,
            isFetching: true,
            requests: []
        )
        XCTAssertEqual(state, .loading)
    }

    /// A refresh in flight after an earlier success must keep showing the
    /// last-known board, not regress to loading/unavailable — matching
    /// `ActiveRequestsView`'s existing refresh-preserves-content contract.
    func testRefreshInFlightAfterEarlierSuccessStaysPopulated() {
        let state = HomeExchangeView.boardState(
            hasSuccessfullyFetchedRequests: true,
            hasAttemptedRequestFetch: true,
            hasFailedInitialFetchAtLeastOnce: false,
            isFetching: true,
            requests: [request(id: "a")]
        )
        guard case .populated = state else {
            return XCTFail("expected .populated, not a regression to loading/unavailable")
        }
    }
}
