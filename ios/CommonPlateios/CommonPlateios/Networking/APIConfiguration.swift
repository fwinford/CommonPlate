//
//  APIConfiguration.swift
//  CommonPlateios
//
//  Created by faith on 7/13/26.
//
// Centralizes backend base-URL ownership, per docs/week-2-integration-spec.md.
// Views, services, and stores must not hard-code backend URLs; they receive
// configuration through this type instead.
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
