//
//  RequesterFulfillmentNotificationTests.swift
//  CommonPlateiosTests
//
// Focused coverage for the Week 3 Day 6 Slice 6E requester-fulfillment
// notification: payload-type parsing, the router's exactly-once latch for
// this distinct intent, and that it stays fully independent of the existing
// helper new-request intent (`HelperNotificationRoutingTests`).
//
// `UNUserNotificationCenterDelegate`'s own methods have no public
// initializer to drive from a unit test (see `HelperNotificationRoutingTests`
// header comment); coverage targets `HelperNotificationRouter
// .handleUserActedOnNotification` directly, the same entry point both real
// delegate methods funnel into.
import Foundation
import XCTest
@testable import CommonPlateios

// MARK: - Payload type parsing

final class RequesterFulfillmentNotificationPayloadParsingTests: XCTestCase {
    func testAWellFormedPayloadIsRecognized() {
        XCTAssertTrue(
            RequesterFulfillmentNotificationPayloadParser.isRequesterFulfillmentPayload(
                userInfo: ["type": "requester-order-placed"]
            )
        )
    }

    /// Routing never depends on `requestId`: the accepted contract always
    /// opens Home regardless of which request was placed.
    func testRecognizedRegardlessOfWhetherARequestIdIsPresent() {
        XCTAssertTrue(
            RequesterFulfillmentNotificationPayloadParser.isRequesterFulfillmentPayload(
                userInfo: ["type": "requester-order-placed", "requestId": "abc123"]
            )
        )
    }

    func testRejectsAnUnrelatedNotificationType() {
        XCTAssertFalse(
            RequesterFulfillmentNotificationPayloadParser.isRequesterFulfillmentPayload(
                userInfo: ["type": "new-request"]
            )
        )
    }

    func testRejectsAMissingType() {
        XCTAssertFalse(
            RequesterFulfillmentNotificationPayloadParser.isRequesterFulfillmentPayload(userInfo: [:])
        )
    }

    func testRejectsANonStringType() {
        XCTAssertFalse(
            RequesterFulfillmentNotificationPayloadParser.isRequesterFulfillmentPayload(
                userInfo: ["type": 12345]
            )
        )
    }
}

// MARK: - Router latch

@MainActor
final class RequesterFulfillmentNotificationRouterTests: XCTestCase {
    func testAWellFormedPayloadBecomesThePendingNotice() {
        let router = HelperNotificationRouter()

        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"])

        XCTAssertTrue(router.pendingRequesterFulfillmentNotice)
    }

    func testAnUnrelatedPayloadNeverBecomesThePendingNotice() {
        let router = HelperNotificationRouter()

        router.handleUserActedOnNotification(userInfo: ["type": "unrelated"])

        XCTAssertFalse(router.pendingRequesterFulfillmentNotice)
    }

    func testConsumingClearsTheNoticeSoItCannotBeShownTwice() {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"])

        XCTAssertTrue(router.consumeNextPresentableRequesterFulfillmentNotice())

        XCTAssertFalse(
            router.consumeNextPresentableRequesterFulfillmentNotice(),
            "a second consume must not reopen the same notice"
        )
        XCTAssertFalse(router.pendingRequesterFulfillmentNotice)
    }

    func testConsumingWithNothingPendingReturnsFalse() {
        let router = HelperNotificationRouter()

        XCTAssertFalse(router.consumeNextPresentableRequesterFulfillmentNotice())
    }

    func testConsumingTheNoticeDoesNotAdvanceItsOwnGeneration() {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"])
        let generationAfterTap = router.requesterFulfillmentRoutingGeneration

        _ = router.consumeNextPresentableRequesterFulfillmentNotice()

        XCTAssertEqual(router.requesterFulfillmentRoutingGeneration, generationAfterTap)
    }

    func testOneNewTapAdvancesItsOwnGenerationExactlyOnce() {
        let router = HelperNotificationRouter()
        let startingGeneration = router.requesterFulfillmentRoutingGeneration

        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"])

        XCTAssertEqual(router.requesterFulfillmentRoutingGeneration, startingGeneration + 1)
    }

    func testASecondTapAfterConsumptionCreatesAFreshIntent() {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"])
        let firstGeneration = router.requesterFulfillmentRoutingGeneration
        XCTAssertTrue(router.consumeNextPresentableRequesterFulfillmentNotice())

        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"])

        XCTAssertEqual(router.requesterFulfillmentRoutingGeneration, firstGeneration + 1)
        XCTAssertTrue(router.pendingRequesterFulfillmentNotice)
    }

    // MARK: - Multiple requester-fulfillment taps (independent-review fix)

    /// Two taps arriving before either is consumed must both be retained,
    /// not coalesced into one `Bool` — the defect the review found.
    func testTwoTapsArrivingBeforeEitherIsConsumedAreBothRetained() {
        let router = HelperNotificationRouter()

        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"])
        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"])

        XCTAssertEqual(router.pendingRequesterFulfillmentCount, 2)
        XCTAssertTrue(router.pendingRequesterFulfillmentNotice)
    }

    /// A second tap while the first notice is still active (i.e. not yet
    /// consumed) must not be lost: consuming must still yield both, one at a
    /// time.
    func testASecondTapWhileTheFirstNoticeIsStillActiveIsNotLost() {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"])
        // Simulates presenting the first notice without yet consuming it —
        // e.g. `ContentView` finding its alert already visible and declining
        // to consume until it can actually show the next one.
        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"])

        XCTAssertTrue(router.consumeNextPresentableRequesterFulfillmentNotice())
        XCTAssertTrue(
            router.pendingRequesterFulfillmentNotice,
            "the second tap must still be pending after only one consume"
        )
        XCTAssertTrue(router.consumeNextPresentableRequesterFulfillmentNotice())
        XCTAssertFalse(router.pendingRequesterFulfillmentNotice)
    }

    /// Each requester intent is eventually presented/consumed exactly once:
    /// three taps yield exactly three consumes, never fewer (lost) or more
    /// (replayed).
    func testEachRequesterIntentIsEventuallyConsumedExactlyOnce() {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"])
        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"])
        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"])

        XCTAssertTrue(router.consumeNextPresentableRequesterFulfillmentNotice())
        XCTAssertTrue(router.consumeNextPresentableRequesterFulfillmentNotice())
        XCTAssertTrue(router.consumeNextPresentableRequesterFulfillmentNotice())
        XCTAssertFalse(
            router.consumeNextPresentableRequesterFulfillmentNotice(),
            "a fourth consume must find nothing pending"
        )
    }

    // MARK: - Independence from the helper new-request intent

    /// The two notification types are mutually exclusive by payload `type`,
    /// so a single tap can only ever be one or the other — but this proves
    /// the router itself keeps the two intents from interfering even so.
    func testAHelperTapNeverArmsTheRequesterFulfillmentNotice() {
        let router = HelperNotificationRouter()

        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "abc"])

        XCTAssertEqual(router.pendingRequestID, "abc")
        XCTAssertFalse(router.pendingRequesterFulfillmentNotice)
        XCTAssertEqual(router.requesterFulfillmentRoutingGeneration, 0)
    }

    func testARequesterFulfillmentTapNeverArmsTheHelperRoute() {
        let router = HelperNotificationRouter()

        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"])

        XCTAssertNil(router.pendingRequestID)
        XCTAssertEqual(router.routingGeneration, 0)
        XCTAssertTrue(router.pendingRequesterFulfillmentNotice)
    }

    /// Consuming one intent must never clear or advance the other's state —
    /// each stays independently correct and exactly-once.
    func testConsumingOneIntentLeavesTheOtherUntouched() throws {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "abc"])
        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"])

        XCTAssertEqual(router.pendingRequestID, "abc")
        router.markHelperIntentHandled(tapSequence: try XCTUnwrap(router.pendingRequestTapSequence))
        XCTAssertNil(router.pendingRequestID)

        XCTAssertTrue(router.pendingRequesterFulfillmentNotice)
        XCTAssertEqual(router.requesterFulfillmentRoutingGeneration, 1)
        XCTAssertTrue(router.consumeNextPresentableRequesterFulfillmentNotice())
    }

    // MARK: - Tap-order authority across intent types (narrow re-review fix)
    //
    // A first fix captured a resolution's "own" sequence by reading
    // `router.latestTapSequence` inside `ContentView`'s `.task` closure, on
    // the theory that nothing else could run before that read since there
    // was no preceding `await`. A narrow independent re-review found that
    // theory false: SwiftUI's own gap between "a tap advanced the counter"
    // and "the closure actually starts running" is a real scheduling window,
    // and a further tap landing in that window would have made the closure
    // misattribute a *later* tap's sequence to the one it was meant to be
    // processing.
    //
    // These cases are written to reproduce exactly that window rather than
    // asserting on a value manually captured immediately after
    // `handleUserActedOnNotification` returns (that pattern is what let the
    // first fix's own tests pass while the underlying defect remained). Each
    // one drives further `handleUserActedOnNotification` calls — simulating
    // taps landing during the gap — strictly *before* reading whatever the
    // router hands back for the earlier tap, so a test only passes if the
    // router itself froze that tap's authority at capture time, not if the
    // test happens to read a global counter at a favorable moment.

    /// requester A arrives, then helper B arrives before A is "processed" —
    /// i.e. before anything reads the queue again. A must not be presentable:
    /// showing it would reset `path` to Home over whatever B's own
    /// resolution does, even though nothing here ever manually captured a
    /// sequence number for A.
    func testARequesterTapCannotResetNavigationWhenALaterHelperTapArrivedBeforeItWasProcessed() {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"]) // A
        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "b"]) // B, before A is processed

        XCTAssertFalse(
            router.consumeNextPresentableRequesterFulfillmentNotice(),
            "A must not be presentable once a later helper tap has been captured"
        )
    }

    /// helper A arrives, then requester B arrives before A is "processed".
    /// `pendingRequestTapSequence` is read only now — after B — and must
    /// still report A's own frozen claim (not B's), because a requester tap
    /// never touches the helper slot. That frozen value must then fail the
    /// fence against the router's current `latestTapSequence`, which B did
    /// advance.
    func testAHelperTapRetainsItsOwnSequenceAndIsFencedOutWhenALaterRequesterTapArrivedBeforeItWasProcessed() throws {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "a"]) // A

        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"]) // B, before A is processed

        // "Processing" A now: peek its own claim, still frozen from capture.
        let capturedByA = try XCTUnwrap(
            router.pendingRequestTapSequence,
            "A's own claim must still be readable — a requester tap must never touch the helper slot"
        )
        XCTAssertEqual(router.pendingRequestID, "a")
        XCTAssertFalse(
            TapAuthorityFence.isStillAuthoritative(
                capturedSequence: capturedByA,
                currentSequence: router.latestTapSequence
            ),
            "A's frozen claim must lose to the later requester tap"
        )
    }

    /// helper A arrives; its attempt synchronously snapshots its own claim
    /// (exactly as `HelperNotificationRouteDriver` does, before any `await`)
    /// — then helper B arrives, overwriting the single helper slot, before
    /// A's (now in-flight) resolution is "processed". A's captured claim must
    /// still lose the fence, so A cannot overwrite B's navigation.
    func testAnEarlierHelperTapCannotOverwriteALaterHelperTapWhenProcessedAfterIt() throws {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "a"]) // A
        // A's attempt starting synchronously, before any later tap can land:
        let capturedByA = try XCTUnwrap(router.pendingRequestTapSequence)
        XCTAssertEqual(router.pendingRequestID, "a")

        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "b"]) // B, while A is in flight
        XCTAssertEqual(router.pendingRequestID, "b", "B must own the helper slot from here on")

        // A's resolution is "processed" (fenced) only now, after B.
        XCTAssertFalse(
            TapAuthorityFence.isStillAuthoritative(
                capturedSequence: capturedByA,
                currentSequence: router.latestTapSequence
            ),
            "A must not be able to overwrite B's later navigation"
        )
    }

    /// No later tap of either kind: A's own frozen claim, read only after
    /// the fact, stays authoritative.
    func testAHelperTapsCaptureStaysAuthoritativeWithNoLaterTap() throws {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "abc"])

        let capturedByHelperTap = try XCTUnwrap(router.pendingRequestTapSequence)
        XCTAssertEqual(router.pendingRequestID, "abc")

        XCTAssertTrue(
            TapAuthorityFence.isStillAuthoritative(
                capturedSequence: capturedByHelperTap,
                currentSequence: router.latestTapSequence
            )
        )
    }

    /// Two requester taps, neither followed by a helper tap: both must
    /// remain independently presentable, each dequeued exactly once, in tap
    /// order — no coalescing, and no cross-invalidation between same-type
    /// intents the way a later helper tap invalidates an earlier one.
    func testTwoRequesterTapsWithNoInterveningHelperTapAreBothPresentableInOrder() {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"]) // A
        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"]) // B

        XCTAssertTrue(router.consumeNextPresentableRequesterFulfillmentNotice(), "A must still be presentable")
        XCTAssertTrue(router.consumeNextPresentableRequesterFulfillmentNotice(), "B must still be presentable")
        XCTAssertFalse(router.consumeNextPresentableRequesterFulfillmentNotice())
    }

    /// A deeper proof that each queued requester intent keeps its own
    /// capture-time snapshot rather than sharing one: A is captured before a
    /// helper tap, C after it. A must be dropped as stale while C — queued
    /// right behind it — still presents, proving staleness is decided per
    /// intent, not for the whole queue at once.
    func testAnOlderQueuedRequesterNoticeIsDroppedWhileAYoungerOneBehindItStillPresents() {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"]) // A, before any helper tap
        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "h"]) // an intervening helper tap
        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"]) // C, after the helper tap

        XCTAssertTrue(
            router.consumeNextPresentableRequesterFulfillmentNotice(),
            "A is stale (dropped) and C, right behind it, is presentable — this call must reach C"
        )
        XCTAssertFalse(
            router.consumeNextPresentableRequesterFulfillmentNotice(),
            "only C was presentable; nothing should remain"
        )
    }

    /// A malformed payload must not advance either counter, so it can never
    /// be mistaken for a later tap that invalidates an already-captured
    /// intent.
    func testAMalformedPayloadDoesNotAdvanceValidTapAuthority() throws {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "abc"])
        let capturedByHelperTap = try XCTUnwrap(router.pendingRequestTapSequence)
        let sequenceBeforeNoise = router.latestTapSequence
        let helperSequenceBeforeNoise = router.latestHelperTapSequence

        router.handleUserActedOnNotification(userInfo: ["type": "unrelated"])
        router.handleUserActedOnNotification(userInfo: [:])

        XCTAssertEqual(router.latestTapSequence, sequenceBeforeNoise)
        XCTAssertEqual(router.latestHelperTapSequence, helperSequenceBeforeNoise)
        XCTAssertEqual(router.pendingRequestID, "abc")
        XCTAssertTrue(
            TapAuthorityFence.isStillAuthoritative(
                capturedSequence: capturedByHelperTap,
                currentSequence: router.latestTapSequence
            ),
            "noise must never be able to invalidate an already-captured intent"
        )
    }

    /// The wrong-purpose case for the requester queue specifically: a
    /// malformed/unrelated payload arriving between two requester taps must
    /// not be treated as a helper tap and must not make the first one stale.
    func testAWrongPurposePayloadBetweenTwoRequesterTapsDoesNotMakeTheFirstOneStale() {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"]) // A
        router.handleUserActedOnNotification(userInfo: ["type": "unrelated"]) // noise
        router.handleUserActedOnNotification(userInfo: ["type": "requester-order-placed"]) // B

        XCTAssertTrue(router.consumeNextPresentableRequesterFulfillmentNotice(), "A must still be presentable")
        XCTAssertTrue(router.consumeNextPresentableRequesterFulfillmentNotice(), "B must still be presentable")
    }
}

// MARK: - The pure fence comparison, isolated from the router

final class TapAuthorityFenceTests: XCTestCase {
    func testEqualSequencesAreAuthoritative() {
        XCTAssertTrue(
            TapAuthorityFence.isStillAuthoritative(capturedSequence: 3, currentSequence: 3)
        )
    }

    func testALaterCurrentSequenceIsNotAuthoritative() {
        XCTAssertFalse(
            TapAuthorityFence.isStillAuthoritative(capturedSequence: 3, currentSequence: 4)
        )
    }
}

// Note: that a consumed notice actually empties `ContentView`'s navigation
// path and presents the `.alert` on screen — including
// `presentNextRequesterFulfillmentNoticeIfPossible()`'s "don't consume what
// you can't show right now" gate, and `routeToNotification`'s
// `TapAuthorityFence` guard around the final `path =` write — is not covered
// here. There is no UI-test target in this repository (see
// `AlertSignupPresentationTests` and `RequestFoodView`'s pre-entry-notice
// coverage for the same documented limitation elsewhere), so that wiring is
// verified by code inspection only, not by an automated test. What this file
// does cover automatically, and what those `ContentView` call sites are built
// from: the router's exactly-once, non-coalescing, per-intent-sequenced queue
// for the requester-fulfillment intent, the per-intent frozen claim for the
// helper intent, and the pure `TapAuthorityFence` comparison both are fenced
// through.
