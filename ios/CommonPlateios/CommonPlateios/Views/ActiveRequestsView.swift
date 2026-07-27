//
//  ActiveRequestsView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

struct ActiveRequestsView: View {
    @ObservedObject var store: RequestStore

    var body: some View {
        Group {
            if !store.hasSuccessfullyFetchedRequests {
                initialState
            } else if store.requests.isEmpty {
                emptyState
            } else {
                requestsList
            }
        }
        .navigationTitle("Active Requests")
        // `.task` starts once per appearance and is not restarted by ordinary
        // body re-evaluation, so redraws cannot start a fetch loop; the
        // `isFetching` guard additionally covers an appearance that lands while
        // a pull-to-refresh or Try Again fetch is still running. On the first
        // appearance this is the initial load. On a later appearance,
        // `fetchRequests()` sees `hasSuccessfullyFetchedRequests` and classifies
        // the call as a refresh, which keeps the current meals visible while it
        // runs and keeps them if it fails.
        .task {
            guard !store.isFetching else {
                return
            }
            await store.fetchRequests()
        }
    }

    /// Shown until a fetch has succeeded at least once. A fetch that is
    /// cancelled, or whose snapshot is ignored because a confirmed mutation
    /// advanced the collection revision, ends with no success and no published
    /// error — so recovery is offered whenever a fetch has been attempted and is
    /// no longer running, rather than only when `initialFetchError` is non-nil.
    @ViewBuilder
    private var initialState: some View {
        if store.hasAttemptedRequestFetch && !store.isFetching {
            VStack(spacing: 12) {
                Text("We couldn’t load who needs help right now.")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text("Please try again in a moment.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Try Again") {
                    fetchRequests()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        } else {
            ProgressView("Loading…")
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("No one needs help with a meal right now.")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text("Check back soon.")
                    .foregroundStyle(.secondary)

                Button("Refresh") {
                    fetchRequests()
                }
                .buttonStyle(.bordered)
                .disabled(store.isFetching)

                if store.refreshError != nil {
                    refreshFailureWarning
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
        .refreshable {
            await store.fetchRequests()
        }
    }

    /// Backend order is authoritative and is rendered as-is. The public list
    /// response carries no server-evaluated timing category, and the backend's
    /// ASAP rule ("no `windowStart`, or `windowStart` within an hour of server
    /// time") cannot be reproduced on device without trusting the device clock.
    /// Splitting on whether `windowStart`/`windowEnd` merely exist misclassified
    /// imminent meals as "Later Today", so the requests are shown as one list
    /// until the API provides a timing category. Per-row timing text still comes
    /// from the backend's canonical `pickupWindowText`.
    private var requestsList: some View {
        List {
            if store.refreshError != nil {
                Section {
                    refreshFailureWarning
                }
            }

            Section("Meals needing help") {
                ForEach(store.requests) { request in
                    NavigationLink {
                        RequestDetailView(request: request)
                    } label: {
                        RequestRowView(request: request)
                    }
                }
            }
        }
        .refreshable {
            await store.fetchRequests()
        }
    }

    private var refreshFailureWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Couldn’t refresh. Some meals shown may no longer be available.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Try Again") {
                fetchRequests()
            }
            .disabled(store.isFetching)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fetchRequests() {
        Task {
            await store.fetchRequests()
        }
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
