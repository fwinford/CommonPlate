//
//  HelperNotificationRouter.swift
//  CommonPlateios
//
// The `UNUserNotificationCenterDelegate` for helper new-request push (Week 3
// Day 6 tap-routing slice). Two responsibilities only:
//
// 1. Foreground presentation: while CommonPlate is in the foreground, show
//    the same visible system banner/sound a backgrounded delivery would —
//    ordinary `UNUserNotificationCenter` foreground presentation is enough,
//    so nothing here invents a custom in-app notification surface.
// 2. Capturing a tap (from background, or a cold launch) as one pending
//    `requestId` that `ContentView` consumes exactly once when it is ready
//    to navigate. Held in memory only: this object is created in
//    `PushAppDelegate.init`, before `application(_:willFinishLaunchingWithOptions:)`
//    runs, so a launch-time tap is captured before `ContentView` exists and
//    is still there the first time it asks — no persistence beyond the
//    process's own lifetime is needed.
//
// This delegate never fabricates request availability from the payload —
// `requestId` is routing context only. Resolving whether the request is
// still open is `RequestStore.resolveHelperNotificationRequest(id:)`'s job.
//
// Also captures the distinct requester-fulfillment tap intent (Week 3 Day 6
// Slice 6E, `RequesterFulfillmentNotificationPayload`): a tap always opens
// Home and shows a one-time "Your order was placed." notice, with no
// backend truth to resolve first. It is deliberately kept as its own
// published pair below rather than folded into `pendingRequestID`/
// `routingGeneration` — the two intents must stay independently correct and
// exactly-once, and reusing one latch for both would let consuming one
// intent silently interact with the other.
//
// Independent review (Week 3 Day 6 Slice 6E) found a correctness defect, and
// a narrow independent re-review found the first fix still assigned tap
// authority too late: reading `latestTapSequence` from inside a consumer's
// `.task` closure — even "synchronously, before any `await`" — is not safe,
// because SwiftUI's own task-scheduling gap between "a tap advanced the
// counter" and "the closure actually starts running" is exactly where a
// further tap can advance the counter again. A closure that reads the
// counter at that point can misattribute a *later* tap's value to an
// *earlier* one it is still processing.
//
// The corrected rule: a tap's authority is decided the instant the router
// itself receives it, never later.
//
// - Every valid tap — helper or requester-fulfillment — claims the next
//   value from `latestTapSequence` inside `handleUserActedOnNotification`,
//   and that value is stored *with* the intent it belongs to
//   (`PendingHelperIntent.tapSequence`, or, for a requester-fulfillment tap,
//   as a snapshot of `latestHelperTapSequence` — see below). Consuming an
//   intent later hands back that original, frozen value; nothing derives it
//   from whatever the counter happens to read at consumption time.
// - A helper resolution is stale once *any* later tap of either kind has
//   been captured: its own `tapSequence`, compared against the router's
//   current `latestTapSequence`, stops matching the moment either type
//   advances the shared counter again.
// - A queued requester-fulfillment notice is different: several of them are
//   meant to queue and each still gets presented — a later requester tap
//   must never invalidate an earlier one (`consumeNextPresentableRequesterFulfillmentNotice()`
//   proves this). Only a *helper* tap should knock a still-queued "your
//   order was placed" notice off Home, since only a helper tap represents a
//   more specific navigation intent to protect. So each requester intent
//   instead snapshots `latestHelperTapSequence` — a second counter advanced
//   only by helper taps — at capture time, and is stale only once that
//   snapshot no longer matches the router's current value.
//
// `TapAuthorityFence` is the one pure comparison both cases reduce to,
// applied to two different pairs of sequence numbers.
import Combine
import Foundation
import UserNotifications

/// Whether a value captured from some monotonic tap-authority counter at
/// intent-capture time is still current, given that counter's value read
/// again immediately before a navigation mutation. Pure and independently
/// testable apart from `ContentView`/SwiftUI or `HelperNotificationRouter`:
/// the one comparison Slice 6E's tap-ordering requirement reduces to, reused
/// for both the helper-resolution fence (against the fully shared
/// `latestTapSequence`) and the requester-notice fence (against the
/// helper-only `latestHelperTapSequence`). Equality means "nothing that
/// should supersede this intent has been captured since"; inequality means
/// this intent is stale and must not mutate navigation.
enum TapAuthorityFence {
    static func isStillAuthoritative(capturedSequence: Int, currentSequence: Int) -> Bool {
        capturedSequence == currentSequence
    }
}

/// A helper new-request tap's captured intent: the routing `requestId`, and
/// this specific tap's own claim on `latestTapSequence`, frozen the instant
/// `handleUserActedOnNotification` captures it.
private struct PendingHelperIntent {
    let requestID: String
    let tapSequence: Int
}

/// A requester-fulfillment tap's captured intent. `helperTapSequenceAtCapture`
/// is a snapshot of `latestHelperTapSequence` taken the instant this tap was
/// captured — see the type header for why a requester intent's staleness
/// depends only on later *helper* taps, never on later requester taps.
private struct PendingRequesterFulfillmentIntent {
    let helperTapSequenceAtCapture: Int
}

@MainActor
final class HelperNotificationRouter: NSObject, ObservableObject {
    @Published private var pendingHelperIntent: PendingHelperIntent?

    /// Advances only when a *new* tap intent is captured, never when one is
    /// consumed. `ContentView` keys its resolution `.task(id:)` on this value
    /// instead of on `pendingRequestID` directly: consuming the pending ID
    /// clears it (see below), and if that clear were the same value driving
    /// the task's identity, the task would rewrite its own id mid-flight and
    /// SwiftUI would cancel its own in-flight backend resolution. Keeping
    /// "a new intent arrived" and "the pending value was read" as two
    /// separate published facts is what keeps consumption from being able to
    /// self-cancel the work it started.
    @Published private(set) var routingGeneration = 0

    /// FIFO queue of requester-fulfillment intents waiting to be presented.
    /// A real queue, not a count or `Bool`, so each tap is retained with its
    /// own capture-time snapshot rather than coalesced into one latch.
    @Published private var pendingRequesterFulfillmentIntents: [PendingRequesterFulfillmentIntent] = []
    /// Advances only when a *new* requester-fulfillment tap is captured,
    /// never when one is consumed — the same shape as `routingGeneration`,
    /// for the same self-cancellation reason.
    @Published private(set) var requesterFulfillmentRoutingGeneration = 0

    /// One counter shared by both intent types; every valid tap — helper or
    /// requester-fulfillment — claims the next value. Used for the helper
    /// resolution's own staleness fence: see the type header.
    @Published private(set) var latestTapSequence = 0
    /// A second counter advanced only by valid helper taps. Used for the
    /// requester-notice staleness fence: see the type header.
    @Published private(set) var latestHelperTapSequence = 0

    /// Non-nil exactly while a captured helper tap is waiting to be routed.
    /// An unconsumed peek — reading it does not clear it, matching how
    /// `ContentView` needs to read this alongside `pendingRequestTapSequence`
    /// before choosing to consume both together.
    var pendingRequestID: String? { pendingHelperIntent?.requestID }
    /// The pending helper tap's own frozen claim on `latestTapSequence` —
    /// see the type header for why this must never be read from
    /// `latestTapSequence` directly at consumption time instead.
    var pendingRequestTapSequence: Int? { pendingHelperIntent?.tapSequence }

    /// Whether at least one requester-fulfillment notice is currently
    /// queued, presentable or not.
    var pendingRequesterFulfillmentNotice: Bool { !pendingRequesterFulfillmentIntents.isEmpty }
    /// How many requester-fulfillment taps are currently queued.
    var pendingRequesterFulfillmentCount: Int { pendingRequesterFulfillmentIntents.count }

    /// The testable entry point: extracts the payload and records the
    /// pending route. Called by the `UNUserNotificationCenterDelegate` bridge
    /// below, and directly by tests, since `UNNotificationResponse` has no
    /// public initializer to construct one against.
    func handleUserActedOnNotification(userInfo: [AnyHashable: Any]) {
        if let payload = HelperNotificationPayloadParser.parse(userInfo: userInfo) {
            latestTapSequence += 1
            latestHelperTapSequence = latestTapSequence
            pendingHelperIntent = PendingHelperIntent(requestID: payload.requestID, tapSequence: latestTapSequence)
            routingGeneration += 1
            return
        }
        if RequesterFulfillmentNotificationPayloadParser.isRequesterFulfillmentPayload(userInfo: userInfo) {
            latestTapSequence += 1
            pendingRequesterFulfillmentIntents.append(
                PendingRequesterFulfillmentIntent(helperTapSequenceAtCapture: latestHelperTapSequence)
            )
            requesterFulfillmentRoutingGeneration += 1
        }
    }

    /// Reads and clears the pending route together, so a route is applied
    /// exactly once even if this is called from more than one place (a
    /// launch-time check and a later state-change observer) for the same tap.
    /// Deliberately leaves `routingGeneration` untouched — see its doc comment.
    /// Callers that also need `pendingRequestTapSequence` must read it first:
    /// this clears the whole intent, sequence included.
    func consumePendingRequestID() -> String? {
        defer { pendingHelperIntent = nil }
        return pendingHelperIntent?.requestID
    }

    /// Claims and dequeues requester-fulfillment intents in tap order until
    /// it finds one still authoritative — a helper tap has not been captured
    /// since it was captured — or the queue empties. Discarding a stale
    /// leading intent along the way rather than leaving it queued is
    /// intentional: it can never become authoritative again (only a *later*
    /// helper tap can invalidate it, and time does not run backwards), so
    /// nothing is gained by keeping it, and every later, still-queued
    /// intent's own turn should not have to wait behind a notice that can
    /// never be shown. Returns `true` exactly when a presentable one was
    /// dequeued and should now be shown; `false` when nothing presentable
    /// remains.
    func consumeNextPresentableRequesterFulfillmentNotice() -> Bool {
        while !pendingRequesterFulfillmentIntents.isEmpty {
            let intent = pendingRequesterFulfillmentIntents.removeFirst()
            if TapAuthorityFence.isStillAuthoritative(
                capturedSequence: intent.helperTapSequenceAtCapture,
                currentSequence: latestHelperTapSequence
            ) {
                return true
            }
        }
        return false
    }
}

extension HelperNotificationRouter: UNUserNotificationCenterDelegate {
    /// Foreground presentation. Unconditional: the only push CommonPlate
    /// currently sends is the helper new-request alert, and the accepted
    /// contract requires it to be visible in the foreground too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// A tap from background or terminated state. `completionHandler()` is
    /// called immediately — routing itself is asynchronous app state, not
    /// something the system needs to wait on.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            self.handleUserActedOnNotification(userInfo: userInfo)
        }
        completionHandler()
    }
}
