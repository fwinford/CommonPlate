//
//  APIConfiguration.swift
//  CommonPlateios
//
//  Created by faith on 7/13/26.
//
// Centralizes backend base-URL ownership, per docs/week-2-integration-spec.md.
// Views, services, and stores must not hard-code backend URLs; they receive
// configuration through this type instead.
//
// INTERNAL DEVELOPMENT BUILD — DO NOT DISTRIBUTE (Day 4)
//
// Day 4 claim functionality is internal-development-only. The app can reserve a
// real request and reveal a real requester's pickup name, but it cannot submit
// fulfillment, notify the requester, or release a claim, and a reservation is
// lost if the app is terminated. Every one of those boundaries becomes a broken
// promise involving a real meal once someone other than the developer runs it.
//
// - Deployed public actions must remain paused (`PUBLIC_ACTIONS_PAUSED=true`).
// - Do not distribute this build to students through TestFlight before Day 5
//   fulfillment is implemented and accepted.
//
// The only configuration below is `localSimulator`; adding a device or deployed
// base URL is not on its own permission to ship this build.
import Foundation

struct APIConfiguration {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Simulator local backend. Port matches `app.ts`'s default (`process.env.PORT || 3000`);
    /// the simulator reaches the host Mac's loopback interface directly.
    static let localSimulator = APIConfiguration(baseURL: URL(string: "http://localhost:3000")!)
}
