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
    /// A claim is already running for this helper.
    case operationInProgress
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

    /// Navigation is driven straight from confirmed store state, so there is no
    /// second source of truth that could open the fulfillment flow before the
    /// backend granted the claim. Dismissing (including a back swipe) leaves the
    /// claim flow through the store rather than stranding the claim.
    private var isShowingClaimedFlow: Binding<Bool> {
        Binding(
            get: { Self.opensClaimedFlow(activeClaim: store.activeClaim, requestID: request.id) },
            set: { isShowing in
                if !isShowing {
                    store.leaveActiveClaimFlow()
                }
            }
        )
    }

    /// The single rule for entering the claimant-only flow: a confirmed claim
    /// for *this* request exists in memory. There is no loading, optimistic, or
    /// error path into it.
    static func opensClaimedFlow(
        activeClaim: ActiveClaimPresentation?,
        requestID: String
    ) -> Bool {
        activeClaim?.requestID == requestID
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
                if let inlineClaimError {
                    Text(inlineClaimError.message)
                        .foregroundStyle(
                            inlineClaimError == .publicActionsPaused
                                ? Color.secondary
                                : Color.red
                        )
                        .accessibilityIdentifier("claim-error")
                }

                // A confirmed pause and an unconfirmed claim both withdraw the
                // action: one because the backend will refuse it, the other
                // because the POST may already have been applied.
                if Self.showsClaimAction(for: inlineClaimError) {
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
        }
        .navigationTitle("Request")
        .navigationDestination(isPresented: isShowingClaimedFlow) {
            FulfillRequestView(request: request, store: store)
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

    /// Locked action title: tapping it claims immediately, with no confirmation
    /// step in between.
    static let claimActionTitle = "Help with this request"

    /// The claim action is withheld only where offering it would be untruthful:
    /// a paused backend will refuse it, and an unconfirmed claim may already
    /// have succeeded, so a second attempt could double-book the helper.
    static func showsClaimAction(for error: ClaimPresentationError?) -> Bool {
        error != .publicActionsPaused && error != .ambiguous
    }

    private func startClaim() {
        Task {
            // The store owns duplicate-submit protection and error state; a
            // rejected duplicate never reaches the network.
            try? await store.claim(requestID: request.id)
        }
    }
}
