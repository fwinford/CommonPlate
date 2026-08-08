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
/// array lets a confirmed placement return to Active Requests by truncating the
/// path in one update, so the completed claimant screen and the stale detail
/// beneath it leave together and neither survives to be reached with Back.
enum AppRoute: Hashable {
    case requestFood
    case activeRequests
    case alerts
    case privacySafety
    /// The public request screen. Carries the request by value because the
    /// backend removes a placed request from the list, so an ID that had to be
    /// looked up again would resolve to nothing at exactly the moment it matters.
    case requestDetail(FoodRequest)
    /// The claimant-only reservation screen. Reachable from a confirmed claim on
    /// the detail screen and from the pinned active-reservation item; the route
    /// itself carries no claimant-private value, only the public request.
    case fulfillment(FoodRequest)
}

extension AppRoute {
    /// The path that lands directly on the populated Active Requests screen.
    ///
    /// Everything pushed after Active Requests is dropped, which is what the
    /// confirmation button promises: no blank reservation destination, no
    /// completed fulfillment form, and no stale detail for a request that has
    /// already been placed. Falls back to a stack containing Active Requests
    /// itself so the action always keeps its word, even if it is somehow invoked
    /// from a path that never went through the list.
    static func returningToActiveRequests(from path: [AppRoute]) -> [AppRoute] {
        guard let index = path.lastIndex(of: .activeRequests) else {
            return [.activeRequests]
        }
        return Array(path[...index])
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
            case .requestFood, .activeRequests, .alerts, .privacySafety:
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
        // Including `.notYetAvailable`: there is no detail screen to show for a
        // request the backend is still withholding, so the tap lands on Active
        // Requests and the reason is carried by the recovery notice there.
        case .unavailable, .notYetAvailable, .temporarilyUnavailable:
            return [.activeRequests]
        }
    }
}
