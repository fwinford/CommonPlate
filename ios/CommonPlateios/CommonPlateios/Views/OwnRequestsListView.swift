//
//  OwnRequestsListView.swift
//  CommonPlateios
//
// W4-H4's `See all N` destination: an ordinary subordinate expansion of
// Home's ownership preview, not a second ownership authority. Renders the
// exact authoritative currently-open owned-request set Home's `See all N`
// action was tapped with, preserving that same authoritative ordering. It is
// not request history, not completed requests, not V2 My Requests, and
// exposes no Edit/Remove or other request-management affordance.
import SwiftUI

struct OwnRequestsListView: View {
    let requests: [FoodRequest]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: CommonPlateStyle.Spacing.m) {
                ForEach(requests) { request in
                    NavigationLink(value: AppRoute.requestDetail(request)) {
                        RequestCardView(request: request, kind: .own, showsOwnershipEyebrow: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("own-requests-list-card-\(request.id)")
                }
            }
            .padding(CommonPlateStyle.Spacing.l)
        }
        .navigationTitle(HomeExchangeView.ownRequestsHeading(count: requests.count))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("own-requests-list")
    }
}
