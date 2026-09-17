//
//  APIConfiguration.swift
//  CommonPlateios
//
//  Created by faith on 7/13/26.
//
// Centralizes backend base-URL ownership, per docs/system-contract.md.
// Views, services, and stores must not hard-code backend URLs; they receive
// configuration through this type instead.
//
// Only the local simulator backend is configured here. Adding a deployed base
// URL requires a separate release decision.
import Foundation

struct APIConfiguration {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Simulator local backend. Port matches `app.ts`'s default (`process.env.PORT || 3000`);
    /// the simulator reaches the host Mac's loopback interface directly.
    /// Uses stable loopback rather than a specific global/temporary IPv6
    /// address, which can rotate (SLAAC privacy addressing) and go stale.
    static let localSimulator = APIConfiguration(
        baseURL: URL(string: "http://127.0.0.1:3000")!
    )
}
