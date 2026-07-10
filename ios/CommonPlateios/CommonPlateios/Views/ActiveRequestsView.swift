//
//  ActiveRequestsView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

struct ActiveRequestsView: View {
    let requests: [FoodRequest]
    let onFulfill: (FoodRequest) -> Void

    private var asapRequests: [FoodRequest] {
        activeRequests
            .filter { $0.shouldShowInASAPSection }
            .sorted { $0.expiresAt < $1.expiresAt }
    }

    private var laterTodayRequests: [FoodRequest] {
        activeRequests
            .filter { !$0.shouldShowInASAPSection }
            .sorted {
                ($0.preferredPickupTime ?? $0.createdAt) < ($1.preferredPickupTime ?? $1.createdAt)
            }
    }

    private var activeRequests: [FoodRequest] {
        requests.filter { $0.isActive }
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
    let request: FoodRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(request.diningSpot.name)
                .font(.headline)

            Text(request.foodDescription)
                .lineLimit(2)

            Text(request.listTimingDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
