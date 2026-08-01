//
//  RequestDetailView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

/// How a claim attempt is presented to the helper. Backend codes are mapped
/// deliberately, with a fallback for anything unrecognized, per the error
/// contract in docs/week-2-integration-spec.md. The stable code itself stays on
/// the request-scoped `RequestStore` event; only the copy lives here.
enum ClaimPresentationError: Equatable {
    /// HTTP 409 `REQUEST_ALREADY_CLAIMED`. Locked message.
    case alreadyClaimed
    /// Expired, out of claimable time, already placed, or missing — one calm
    /// "no longer available" register rather than four error states.
    case noLongerAvailable
    /// `PUBLIC_ACTIONS_PAUSED`.
    case publicActionsPaused
    /// `RATE_LIMITED`.
    case rateLimited
    /// The claim POST may have been applied server-side without iOS seeing the
    /// credentials. Never retried automatically.
    case ambiguous
    /// A claim on *this* request is already in flight for this helper.
    case operationInProgress
    /// A claim on a *different* request is in flight. Nothing has been started
    /// for this one and nothing is held yet — it is a short wait, not a
    /// commitment made elsewhere.
    case otherClaimInProgress
    /// A confirmed reservation on a different request is already held.
    case existingActiveClaim
    /// A confirmed placement result is still waiting to be acknowledged.
    case pendingPlacementAcknowledgement
    /// `INTERNAL_FAILURE`, transport loss before submission, or an unmapped code.
    case couldNotStart

    var message: String {
        switch self {
        case .alreadyClaimed:
            // Locked race-conflict copy. Must match the backend's own message
            // for HTTP 409 REQUEST_ALREADY_CLAIMED exactly.
            return RequestDetailView.alreadyClaimedNotice
        case .noLongerAvailable:
            return RequestDetailView.noLongerAvailableNotice
        case .publicActionsPaused:
            // One source for the locked Day 2 helper-pause sentence.
            return RequestDetailView.helperPauseNotice
        case .rateLimited:
            return "Too many attempts. Please wait a moment and try again."
        case .ambiguous:
            return "We couldn’t confirm whether you started helping with this request. Check Active Requests before trying again."
        case .operationInProgress:
            return "You’re already starting to help with this request."
        case .otherClaimInProgress:
            return RequestDetailView.otherClaimInProgressTitle
                + " " + RequestDetailView.otherClaimInProgressNotice
        case .existingActiveClaim:
            return "You’re already helping with another request. Finish that one or wait for its reservation to end."
        case .pendingPlacementAcknowledgement:
            return RequestDetailView.pendingPlacementTitle
                + " " + RequestDetailView.pendingPlacementNotice
        case .couldNotStart:
            return "We couldn’t start helping with this request. Please try again in a moment."
        }
    }

    static func map(_ error: Error) -> ClaimPresentationError {
        guard let serviceError = error as? RequestServiceError else {
            return .couldNotStart
        }

        switch serviceError {
        case .notFound:
            return .noLongerAvailable
        case .serverError(let code, _):
            switch code {
            case ClaimErrorCode.requestAlreadyClaimed:
                return .alreadyClaimed
            case ClaimErrorCode.requestExpired,
                 ClaimErrorCode.requestInsufficientTime,
                 ClaimErrorCode.requestAlreadyPlaced,
                 ClaimErrorCode.requestNotFound:
                return .noLongerAvailable
            case ClaimErrorCode.publicActionsPaused:
                return .publicActionsPaused
            case ClaimErrorCode.rateLimited:
                return .rateLimited
            default:
                // Includes INVALID_REQUEST_ID and INTERNAL_FAILURE: neither is
                // the helper's to act on beyond trying again.
                return .couldNotStart
            }
        case .ambiguousClaimOutcome:
            return .ambiguous
        case .operationInProgress:
            return .operationInProgress
        case .otherClaimInProgress:
            return .otherClaimInProgress
        case .existingActiveClaim:
            return .existingActiveClaim
        case .unacknowledgedPlacement:
            return .pendingPlacementAcknowledgement
        default:
            return .couldNotStart
        }
    }
}

struct RequestDetailView: View {
    /// Locked Day 2 copy: shown when the backend refuses claiming because
    /// public actions are paused.
    static let helperPauseNotice = "Helping with this meal is temporarily unavailable."

    /// Locked race-conflict copy, identical to the backend's HTTP 409
    /// `REQUEST_ALREADY_CLAIMED` message.
    static let alreadyClaimedNotice = "Someone else just started helping with this request."

    /// Shared "unavailable" register for expired, out-of-time, already-placed,
    /// and missing requests. Matches the backend's own `REQUEST_EXPIRED` message.
    static let noLongerAvailableNotice = "This request is no longer available."

    let request: FoodRequest
    @ObservedObject var store: RequestStore

    @Environment(\.dismiss) private var dismiss

    /// Whether the claimant flow is pushed from this screen. Entering is driven
    /// only by confirmed store state (see `onChange` below), so nothing can open
    /// the flow before the backend granted the claim. Leaving is ordinary
    /// navigation: Back writes `false` here and touches no claim state, because
    /// dismissing a screen is not a decision to give up a reservation the
    /// backend still holds.
    @State private var isPresentingClaimedFlow = false

    /// The single rule for entering the claimant-only flow: a confirmed claim
    /// for *this* request exists in memory. There is no loading, optimistic, or
    /// error path into it.
    static func opensClaimedFlow(
        activeClaim: ActiveClaimPresentation?,
        requestID: String
    ) -> Bool {
        activeClaim?.requestID == requestID
    }

    /// A confirmed placement clears claimant credentials immediately, but its
    /// confirmation stays on the claimant screen until acknowledged. This
    /// keeps the destination alive for that safe terminal presentation only.
    static func keepsClaimedFlowPresented(
        activeRequestID: String?,
        confirmationRequestID: String?,
        requestID: String
    ) -> Bool {
        activeRequestID == requestID || confirmationRequestID == requestID
    }

    static func shouldDismiss(
        for notice: ClaimUnavailableNotice?,
        requestID: String
    ) -> Bool {
        notice?.requestID == requestID
    }

    /// Suppressed once the helper is being sent back to Active Requests: the
    /// notice belongs on the list they land on, not on the screen leaving view.
    private var inlineClaimError: ClaimPresentationError? {
        guard store.claimUnavailableNotice?.requestID != request.id,
              let claimError = store.claimError(for: request.id) else {
            return nil
        }
        return ClaimPresentationError.map(claimError)
    }

    var body: some View {
        Form {
            Section("Food request") {
                Text(request.diningSpot.name)
                    .font(.headline)
                if let address = request.diningSpot.address {
                    Text(address)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(request.foodDescription)
                Text(request.timingDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if Self.opensClaimedFlow(activeClaim: store.activeClaim, requestID: request.id) {
                    // Already reserved by this helper. Offering the claim action
                    // again would only produce a refusal, so this screen becomes
                    // a way back into the reservation they already hold.
                    continueHelpingLink
                } else {
                    claimSection
                }
            }
        }
        .navigationTitle("Request")
        .navigationDestination(isPresented: $isPresentingClaimedFlow) {
            FulfillRequestView(request: request, store: store) {
                dismiss()
            }
        }
        // Confirmed claim success is the only thing that opens the flow. The
        // claim ending closes it; a manual Back leaves `activeClaim` untouched,
        // so this does not fire and the reservation survives the navigation.
        .onChange(of: store.activeClaim?.requestID) { _, activeRequestID in
            if Self.keepsClaimedFlowPresented(
                activeRequestID: activeRequestID,
                confirmationRequestID: store.fulfillmentConfirmation?.requestID,
                requestID: request.id
            ) {
                isPresentingClaimedFlow = true
            } else if isPresentingClaimedFlow {
                isPresentingClaimedFlow = false
            }
        }
        // A stale detail screen must never outlive the backend's verdict.
        .onChange(of: store.claimUnavailableNotice?.id) { _, noticeID in
            if let noticeID,
               let notice = store.claimUnavailableNotice,
               notice.id == noticeID,
               Self.shouldDismiss(for: notice, requestID: request.id) {
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var continueHelpingLink: some View {
        if let activeClaim = store.activeClaim {
            NavigationLink {
                FulfillRequestView(request: request, store: store) {
                    dismiss()
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.continueHelpingTitle)
                    Text(ActiveRequestsView.reservedUntilText(activeClaim.claimExpiresAt))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("claim-continue")
        }
    }

    @ViewBuilder
    private var claimSection: some View {
        let inlineClaimError = self.inlineClaimError

        if let inlineClaimError {
            Text(inlineClaimError.message)
                .foregroundStyle(
                    inlineClaimError == .publicActionsPaused
                        ? Color.secondary
                        : Color.red
                )
                .accessibilityIdentifier("claim-error")
        }

        // Rather than leave the helper tapping an action that can only be
        // refused, send them to the reservation that is blocking this one.
        if inlineClaimError == .existingActiveClaim, let activeClaim = store.activeClaim {
            NavigationLink {
                // This claimant screen sits on top of a *different* request's
                // detail, so its own `dismiss` would pop back onto that stale
                // screen rather than to the list its button names. Dismissing
                // this detail instead takes both levels off at once, matching
                // the other two entry points.
                FulfillRequestView(request: activeClaim.request, store: store) {
                    dismiss()
                }
            } label: {
                Text(Self.goToActiveReservationTitle)
            }
            .accessibilityIdentifier("go-to-active-reservation")
        }

        // A confirmed pause and an unconfirmed claim both withdraw the
        // action: one because the backend will refuse it, the other
        // because the POST may already have been applied.
        if Self.showsClaimAction(for: inlineClaimError) {
            // Stated before the tap, because the tap is the commitment: it
            // reserves the request immediately and there is no way to hand it
            // back early. Deliberately vague about the length — the backend caps
            // the reservation at the request's own expiration, so a full fifteen
            // minutes is never guaranteed.
            Text(Self.claimConsequenceNotice)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("claim-consequence-notice")

            Button {
                startClaim()
            } label: {
                if store.isClaiming(requestID: request.id) {
                    HStack {
                        ProgressView()
                        Text("Starting…")
                    }
                } else {
                    Text(Self.claimActionTitle)
                }
            }
            // Request-scoped: an in-flight claim on another request must
            // not silently grey out this one. The store's own mutex
            // stays authoritative and refuses the duplicate with
            // `operationInProgress`, which explains itself in copy
            // rather than leaving a dead control on screen.
            .disabled(store.isClaiming(requestID: request.id))
            .accessibilityIdentifier("claim-action")
        }
    }

    /// Locked action title: tapping it claims immediately, with no confirmation
    /// step in between.
    static let claimActionTitle = "Help with this request"

    /// What the tap actually does, said before it happens. One tap is enough —
    /// a confirmation screen would not add understanding, but an unexplained
    /// action would leave a helper reserving a real student's meal, and blocking
    /// every other helper from it, without knowing they had done so.
    static let claimConsequenceNotice =
        "Tapping this reserves the request for you for a few minutes, so no one else starts the same order."

    /// Re-entry for a request this helper already reserved.
    static let continueHelpingTitle = "Continue helping with this request"

    /// Re-entry for the *other* request whose reservation is blocking this one.
    static let goToActiveReservationTitle = "Go to the request you’re helping with"

    /// A claim already in flight for a different request. The action stays on
    /// screen: unlike a held reservation this clears itself in a moment, so the
    /// helper is asked to wait rather than sent somewhere else.
    static let otherClaimInProgressTitle = "Please wait."
    static let otherClaimInProgressNotice =
        "You’re already starting to help with another request. Wait for that request to finish before choosing this one."

    /// The acknowledgement gate. Week 2 holds one placement result at a time, so
    /// the previous one has to be read and dismissed — from the Active Requests
    /// item that carries it — before another request can be started.
    static let pendingPlacementTitle = "Review your previous order."
    static let pendingPlacementNotice =
        "Acknowledge the previous placement result before helping with another request."

    /// The claim action is withheld only where offering it would be untruthful:
    /// a paused backend will refuse it, an unconfirmed claim may already have
    /// succeeded so a second attempt could double-book the helper, an existing
    /// reservation elsewhere makes this claim impossible until that one ends,
    /// and an unacknowledged placement result blocks every new claim until it
    /// is read. In each case the store refuses before building a request, so
    /// leaving the button would be a control that can only fail.
    static func showsClaimAction(for error: ClaimPresentationError?) -> Bool {
        error != .publicActionsPaused
            && error != .ambiguous
            && error != .existingActiveClaim
            && error != .pendingPlacementAcknowledgement
    }

    private func startClaim() {
        Task {
            // The store owns duplicate-submit protection and error state; a
            // rejected duplicate never reaches the network.
            try? await store.claim(requestID: request.id)
        }
    }
}
