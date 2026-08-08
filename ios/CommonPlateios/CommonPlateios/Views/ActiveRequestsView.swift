//
//  ActiveRequestsView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

struct ActiveRequestsView: View {
    @ObservedObject var store: RequestStore
    @State private var presentedClaimUnavailableNotice: ClaimUnavailableNotice?
    @State private var isActiveRequestsVisible = false

    /// The public list minus a request this helper is actively holding. The
    /// backend already excludes actively claimed requests from `GET
    /// /api/requests`; this covers the window before the next refresh, so the
    /// same request is never both pinned above and advertised below as though
    /// it were still open to anyone.
    private var availableRequests: [FoodRequest] {
        Self.availableRequests(
            store.requests,
            activeClaimRequestID: store.activeClaim?.requestID
        )
    }

    static func availableRequests(
        _ requests: [FoodRequest],
        activeClaimRequestID: String?
    ) -> [FoodRequest] {
        guard let activeClaimRequestID else {
            return requests
        }
        return requests.filter { $0.id != activeClaimRequestID }
    }

    var body: some View {
        VStack(spacing: 0) {
            pinnedHeader

            listContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Active Requests")
        // Claim-unavailable safety notices are delivered here in store-owned
        // FIFO order, whether the list was already visible or has just been
        // uncovered by a dismissed flow.
        .alert(item: $presentedClaimUnavailableNotice) { notice in
            Alert(
                title: Text(Self.claimUnavailableTitle(for: notice.reason)),
                message: Self.claimUnavailableDetail(for: notice.reason).map(Text.init),
                dismissButton: .default(Text("OK")) {
                    store.acknowledgeClaimUnavailableNotice(id: notice.id)
                }
            )
        }
        // A notice can arrive after this screen is already visible, such as when
        // a preserved reservation expires while the helper is on the list. Keep
        // observing the store, but arm presentation only while Active Requests
        // is actually visible: this view remains in the navigation hierarchy
        // under a pushed detail screen and must not present an alert from there.
        .onAppear {
            isActiveRequestsVisible = true
            presentNextClaimUnavailableNoticeIfNeeded()
        }
        .onDisappear {
            isActiveRequestsVisible = false
        }
        .onChange(of: store.claimUnavailableNotice?.id) { _, _ in
            presentNextClaimUnavailableNoticeIfNeeded()
        }
        .onChange(of: presentedClaimUnavailableNotice?.id) { _, presentedID in
            if presentedID == nil {
                presentNextClaimUnavailableNoticeIfNeeded()
            }
        }
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

    /// Everything that stays above the list regardless of its state.
    @ViewBuilder
    private var pinnedHeader: some View {
        // A confirmed placement whose claimant screen is already gone has
        // nowhere else to land: the claim is cleared and the request is removed
        // from the list, so without this the helper never learns the order was
        // recorded and the confirmation can never be acknowledged.
        placementConfirmationItem

        // Pinned above every list state, including loading and empty: a
        // reservation the helper is holding must stay reachable even when the
        // public list has nothing in it.
        activeReservationItem
    }

    @ViewBuilder
    private var listContent: some View {
        if !store.hasSuccessfullyFetchedRequests {
            initialState
        } else if availableRequests.isEmpty {
            emptyState
        } else {
            requestsList
        }
    }

    /// The helper's own reservation, kept reachable independently of the public
    /// list. It reads only from confirmed store state, sends no request, and
    /// re-enters the existing claimant flow rather than starting a second claim
    /// — which also makes a claim that confirmed after its detail screen was
    /// dismissed reachable instead of stranded.
    @ViewBuilder
    private var activeReservationItem: some View {
        if let claim = store.activeClaim {
            NavigationLink(value: AppRoute.fulfillment(claim.request)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.activeReservationTitle)
                        .font(.headline)

                    Text(claim.request.diningSpot.name)
                        .font(.subheadline)

                    Text(claim.request.foodDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Text(Self.reservedUntilText(claim.claimExpiresAt))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityIdentifier("active-reservation-item")
        }
    }

    /// The confirmed placement the helper has not acknowledged yet, carrying the
    /// same message the claimant screen would have shown.
    ///
    /// Rendered as inline content rather than an alert or a sheet. This screen
    /// already owns one modal — the claim-unavailable alert — and the claimant
    /// screen shows this same confirmation in its own success section, so the
    /// two surfaces can never contend for one presentation: whichever screen the
    /// helper is actually on renders it, and the covered one is just layout.
    @ViewBuilder
    private var placementConfirmationItem: some View {
        if let confirmation = store.fulfillmentConfirmation {
            VStack(alignment: .leading, spacing: 8) {
                Text(FulfillRequestView.confirmationTitle)
                    .font(.headline)

                // Which meal this result belongs to. The request is out of the
                // list and the claim is cleared by now, so the confirmation
                // carries its own public identity — matching the reservation
                // card above it, which a helper may have just been reading.
                Text(confirmation.vendor)
                    .font(.subheadline)
                    .accessibilityIdentifier("placement-confirmation-vendor")

                Text(confirmation.foodDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("placement-confirmation-food")

                Text(FulfillRequestView.confirmationDetail(for: confirmation.kind))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(Self.confirmationAcknowledgeTitle) {
                    store.acknowledgeFulfillmentConfirmation(id: confirmation.id)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("placement-confirmation-acknowledge")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.12))
            )
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityIdentifier("placement-confirmation-item")
        }
    }

    /// Acknowledgement from the list itself. The claimant screen's button says
    /// "Back to Active Requests" because it navigates; this one is already
    /// there, so it only dismisses the message.
    static let confirmationAcknowledgeTitle = "Got it"

    static let activeReservationTitle = "You’re helping with a request"

    /// The authoritative backend deadline, shown without a countdown.
    static func reservedUntilText(_ claimExpiresAt: Date) -> String {
        "Reserved until \(claimExpiresAt.formatted(date: .omitted, time: .shortened))"
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

    /// Backend membership and order are authoritative and are rendered as-is.
    /// Every request in this list is one the backend has already decided is
    /// available now: a scheduled request is withheld until its `visibleFrom`,
    /// so nothing here is waiting to begin and there is no imminent-versus-later
    /// distinction left for the app to draw. Per-row timing text comes from the
    /// backend's canonical `pickupWindowText`, already formatted in campus time,
    /// so the app never reads the device clock to describe a request.
    private var requestsList: some View {
        List {
            if store.refreshError != nil {
                Section {
                    refreshFailureWarning
                }
            }

            Section("Meals needing help") {
                ForEach(availableRequests) { request in
                    NavigationLink(value: AppRoute.requestDetail(request)) {
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

    private func presentNextClaimUnavailableNoticeIfNeeded() {
        presentedClaimUnavailableNotice = Self.noticeToPresent(
            presented: presentedClaimUnavailableNotice,
            storeNotice: store.claimUnavailableNotice,
            isViewVisible: isActiveRequestsVisible
        )
    }

    /// Which notice the alert should be showing. An alert already on screen is
    /// never swapped out from under the helper: newer notices wait in the store
    /// queue until the presented one is acknowledged by ID, at which point this
    /// returns the next queue head instead of nil.
    static func noticeToPresent(
        presented: ClaimUnavailableNotice?,
        storeNotice: ClaimUnavailableNotice?,
        isViewVisible: Bool = true
    ) -> ClaimUnavailableNotice? {
        guard isViewVisible else {
            return presented
        }
        return presented ?? storeNotice
    }

    /// Locked copy for the race conflict; a calm shared sentence for every
    /// other confirmed-unavailable outcome. The store already refreshed the
    /// list from backend truth before this is shown.
    static func claimUnavailableTitle(for reason: ClaimUnavailableReason?) -> String {
        switch reason {
        case .alreadyClaimed:
            return RequestDetailView.alreadyClaimedNotice
        case .claimExpired:
            return "Your reservation expired."
        case .fulfillmentClaimExpired:
            return "Your reservation ran out"
        case .reservationNoLongerValid:
            return "This meal is no longer reserved for you."
        case .fulfillmentAlreadyPlaced:
            return "This order is already recorded in CommonPlate."
        case .fulfillmentRequestNotFound:
            return "We couldn’t find this request."
        case .noLongerAvailable, nil:
            return RequestDetailView.noLongerAvailableNotice
        case .notYetAvailable:
            // The same sentence a claim before the start produces, so a helper
            // who arrives by notification tap and one who presses Claim are
            // told the same true thing.
            return RequestDetailView.notYetAvailableNotice
        case .temporarilyUnavailable:
            return RequestDetailView.temporarilyUnavailableNotice
        }
    }

    /// An expired reservation is the one case that needs a second sentence: the
    /// helper must not place a real order against a request they no longer hold.
    static func claimUnavailableDetail(for reason: ClaimUnavailableReason?) -> String? {
        switch reason {
        case .claimExpired:
            return "Please don’t place an order for that request. Someone else may already be helping."
        case .fulfillmentClaimExpired:
            return "If you already completed the Grubhub order, don’t place it again. CommonPlate may not have saved the details, so the student may not have been emailed. If you had not ordered yet, do not start now."
        case .reservationNoLongerValid:
            return "Someone else may have recorded it. Don’t place another Grubhub order."
        case .fulfillmentAlreadyPlaced:
            // Reached both by a race on a first submission and — since the
            // one-use manual repeat exists — by the repeat that the backend
            // answers with REQUEST_ALREADY_PLACED. In that second case the
            // original response was never readable, so its notification result
            // is unknown here. Placement is the only thing this verdict proves;
            // claiming the student was told would overstate it, and a helper
            // who knows the email may not have gone out can reach them another
            // way. Same register as the emailStatusUnknown confirmation.
            return "Don’t place another Grubhub order. We couldn’t confirm whether the student’s email was sent, so they may not know the order is ready."
        case .fulfillmentRequestNotFound:
            return "It may already have been recorded or removed. Don’t place another Grubhub order."
        // `.notYetAvailable` needs no second sentence either: nothing was
        // ordered, nothing was lost, and the first sentence already says the
        // only thing there is to do about it.
        case .alreadyClaimed, .noLongerAvailable, .notYetAvailable,
             .temporarilyUnavailable, nil:
            return nil
        }
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
