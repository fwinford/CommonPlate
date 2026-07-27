//
//  ActiveRequestsView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

struct ActiveRequestsView: View {
    @ObservedObject var store: RequestStore

    private var asapRequests: [FoodRequest] {
        store.requests.filter { $0.timing == .asap }
    }

    private var laterTodayRequests: [FoodRequest] {
        store.requests.filter { $0.timing == .later }
    }

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
        .task {
            guard !store.hasSuccessfullyFetchedRequests,
                  store.initialFetchError == nil,
                  !store.isFetching else {
                return
            }
            await store.fetchRequests()
        }
    }

    @ViewBuilder
    private var initialState: some View {
        if store.initialFetchError != nil {
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
                .disabled(store.isFetching)
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

    private var requestsList: some View {
        List {
            if store.refreshError != nil {
                Section {
                    refreshFailureWarning
                }
            }

            if !asapRequests.isEmpty {
                Section("ASAP") {
                    ForEach(asapRequests) { request in
                        NavigationLink {
                            RequestDetailView(request: request)
                        } label: {
                            RequestRowView(request: request)
                        }
                    }
                }
            }

            if !laterTodayRequests.isEmpty {
                Section("Later Today") {
                    ForEach(laterTodayRequests) { request in
                        NavigationLink {
                            RequestDetailView(request: request)
                        } label: {
                            RequestRowView(request: request)
                        }
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
