//
//  AppRoute.swift
//  CommonPlateios
//

import Foundation

/// Every destination in the app's single navigation stack, addressed by value.
///
/// The stack is app state, not a chain of `dismiss()` calls. That is the whole
/// point of this type: a claimant screen sits *above* the request detail that
/// opened it, and a `DismissAction` read on the detail cannot reliably remove
/// both levels from underneath the screen calling it. Expressing the stack as an
/// array lets the helper flow rewrite the path in one update: a confirmed claim
/// replaces its pre-claim detail with Helping (W4-H1), and a finished flow
/// leaves to Home after confirmed placement or to Active Requests after a
/// non-success end, so no stale detail survives to be reached with Back.
enum AppRoute: Hashable {
    case requestFood
    case activeRequests
    case alerts
    /// The completed-onboarding replay chooser. Keeping it in the same typed
    /// path as Privacy & Safety gives its chevron row the same native push.
    case onboardingChooser
    case privacySafety
    /// W4-H2's one shared secondary utility route, reached from Home's gear.
    /// Owns compact identity presentation, the Request Alerts management row
    /// (`.alerts`), and About & Help destination rows.
    case settings
    /// W4-H2 About & Help destination row. Minimal placeholder content —
    /// final trust/support content belongs to T1.
    case support
    /// The public request screen. Carries the request by value because the
    /// backend removes a placed request from the list, so an ID that had to be
    /// looked up again would resolve to nothing at exactly the moment it matters.
    case requestDetail(FoodRequest)
    /// The claimant-only reservation screen (Helping). Replaces the detail
    /// screen once a claim confirms, and is the held request's one destination
    /// from every other entry; the route itself carries no claimant-private
    /// value, only the public request.
    case fulfillment(FoodRequest)
    /// W4-H4's `See all N` destination: the complete authoritative
    /// currently-open owned-request set, carried by value for the same reason
    /// `requestDetail` is — a request can leave the board between the tap and
    /// the destination rendering. Not history, not V2 My Requests, not
    /// request management: an ordinary subordinate expansion of the same Home
    /// ownership preview.
    case ownRequests([FoodRequest])
}

extension AppRoute {
    /// The path that lands directly on the populated Active Requests screen,
    /// where a non-success end to the helper flow presents its notice.
    ///
    /// Everything pushed after Active Requests is dropped: no blank
    /// reservation destination and no stale detail for a request that is no
    /// longer the helper's. Falls back to a stack containing Active Requests
    /// itself so the notice always has somewhere real to land, even from a
    /// path that never went through the list.
    ///
    /// W4-H1: not used after confirmed placement — see `afterHelperSuccess`.
    static func returningToActiveRequests(from path: [AppRoute]) -> [AppRoute] {
        guard let index = path.lastIndex(of: .activeRequests) else {
            return [.activeRequests]
        }
        return Array(path[...index])
    }

    /// W4-H1: the one destination after authoritatively confirmed helper
    /// completion — Home, the empty path — regardless of whether the helper
    /// entered from Home, Active Requests, or a helper notification. Applied
    /// once by the automatic success presentation after its readable dwell.
    static func afterHelperSuccess(from path: [AppRoute]) -> [AppRoute] {
        _ = path
        return []
    }

    /// W4-H1 active-reservation navigation: the path once `activeClaim` is
    /// this helper's confirmed reservation. Request Detail is pre-claim only,
    /// so no destination for the held request — its now-stale detail, or an
    /// earlier Helping copy — stays in the stack. The path is cut at the first
    /// such destination and Helping takes its place, which leaves whatever was
    /// beneath the detail (normally Home) as Back's destination. A path that
    /// never contained the request simply gains Helping on top.
    static func enteringHeldRequest(
        _ activeClaim: ActiveClaimPresentation,
        from path: [AppRoute]
    ) -> [AppRoute] {
        let base: [AppRoute]
        if let index = path.firstIndex(where: {
            containsHelperDestination(in: [$0], requestID: activeClaim.requestID)
        }) {
            base = Array(path[..<index])
        } else {
            base = path
        }
        return base + [.fulfillment(activeClaim.request)]
    }

    /// Pushes `route` unless it is already on top. Entering the claimant flow is
    /// driven by confirmed store state, and that state can republish while the
    /// screen it opens is already showing; without this a single claim could
    /// stack two identical destinations.
    static func appending(_ route: AppRoute, to path: [AppRoute]) -> [AppRoute] {
        guard path.last != route else {
            return path
        }
        return path + [route]
    }

    /// Whether the stack still contains a request-detail or claimant destination
    /// for `requestID`.
    static func containsHelperDestination(
        in path: [AppRoute],
        requestID: String
    ) -> Bool {
        path.contains { route in
            switch route {
            case .requestDetail(let request), .fulfillment(let request):
                return request.id == requestID
            case .requestFood, .activeRequests, .alerts, .onboardingChooser,
                 .privacySafety, .settings, .support, .ownRequests:
                return false
            }
        }
    }

    /// The path a helper new-request notification tap replaces the current
    /// one with, once `RequestStore.resolveHelperNotificationRequest(id:)`
    /// has answered from backend truth. A tap is a fresh navigation intent —
    /// whatever the helper was doing before is discarded, matching "opens
    /// CommonPlate and routes toward the specific request" — and Active
    /// Requests always sits underneath, so Back and any later completed-flow
    /// truncation (`returningToActiveRequests`) land somewhere real.
    static func afterNotificationResolution(
        _ resolution: HelperNotificationResolution
    ) -> [AppRoute] {
        switch resolution {
        case .available(let request):
            return [.activeRequests, .requestDetail(request)]
        // W4-H1: the tapped request is this helper's confirmed reservation.
        // Helping is its one destination, with the same Active Requests base
        // the reservation-warning tap uses and no Request Detail.
        case .heldByCurrentHelper(let request):
            return [.activeRequests, .fulfillment(request)]
        // Including `.notYetAvailable`: there is no detail screen to show for a
        // request the backend is still withholding, so the tap lands on Active
        // Requests and the reason is carried by the recovery notice there.
        case .unavailable, .notYetAvailable, .temporarilyUnavailable:
            return [.activeRequests]
        }
    }
}
