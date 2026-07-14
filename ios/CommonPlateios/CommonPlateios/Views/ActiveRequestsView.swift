//
//  ActiveRequestsView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

struct ActiveRequestsView: View {
    let requests: [LocalSimulatedRequest]
    let onFulfill: (LocalSimulatedRequest) -> Void

    private var asapRequests: [LocalSimulatedRequest] {
        activeRequests
            .filter { $0.canonicalRequest.shouldShowInASAPSection }
            .sorted { $0.canonicalRequest.expiresAt < $1.canonicalRequest.expiresAt }
    }

    private var laterTodayRequests: [LocalSimulatedRequest] {
        activeRequests
            .filter { !$0.canonicalRequest.shouldShowInASAPSection }
            .sorted {
                ($0.canonicalRequest.preferredPickupTime ?? $0.canonicalRequest.createdAt) <
                    ($1.canonicalRequest.preferredPickupTime ?? $1.canonicalRequest.createdAt)
            }
    }

    private var activeRequests: [LocalSimulatedRequest] {
        requests.filter { $0.canonicalRequest.isActive }
    }

    var body: some View {
        Group {
            if activeRequests.isEmpty {
                VStack(spacing: 12) {
                    Text("No active requests right now.")
                        .font(.headline)

                    Text("Requests here still need help. They expire after a few hours so the list stays current.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                List {
                    if !asapRequests.isEmpty {
                        Section("ASAP") {
                            ForEach(asapRequests) { request in
                                NavigationLink {
                                    RequestDetailView(request: request, onFulfill: onFulfill)
                                } label: {
                                    RequestRowView(request: request)
                                }
                            }
                        }
                    }

                    if !laterTodayRequests.isEmpty {
                        Section("Later today") {
                            ForEach(laterTodayRequests) { request in
                                NavigationLink {
                                    RequestDetailView(request: request, onFulfill: onFulfill)
                                } label: {
                                    RequestRowView(request: request)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Active Requests")
    }
}

struct RequestRowView: View {
    let request: LocalSimulatedRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(request.canonicalRequest.diningSpot.name)
                .font(.headline)

            Text(request.canonicalRequest.foodDescription)
                .lineLimit(2)

            Text(request.listTimingDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
