//
//  FulfillRequestView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

/// Copy for a failed extension attempt. The reservation itself is never
/// shortened by a failure, and none of these states offer an automatic retry —
/// only one extension is ever granted, so a second attempt could only be
/// refused or double-counted.
enum ClaimExtensionPresentationError: Equatable {
    /// `CLAIM_EXTENSION_INSUFFICIENT_TIME` — a full five minutes does not fit
    /// before the request's own expiration. Partial extensions do not exist.
    case insufficientTime
    /// `CLAIM_EXTENSION_ALREADY_USED`.
    case alreadyUsed
    /// `PUBLIC_ACTIONS_PAUSED`.
    case publicActionsPaused
    /// `RATE_LIMITED`.
    case rateLimited
    /// The extension may or may not have been applied server-side, so the
    /// earlier known deadline is kept.
    case ambiguous
    /// `INTERNAL_FAILURE`, transport loss before submission, or an unmapped code.
    case couldNotExtend

    var message: String {
        switch self {
        case .insufficientTime:
            return "There isn’t enough time left on this request for five more minutes."
        case .alreadyUsed:
            return "This reservation has already been extended once."
        case .publicActionsPaused:
            return RequestDetailView.helperPauseNotice
        case .rateLimited:
            return "Too many attempts. Please wait a moment and try again."
        case .ambiguous:
            return "We couldn’t confirm the extra time. Work from the reservation time shown above."
        case .couldNotExtend:
            return "We couldn’t add more time. Work from the reservation time shown above."
        }
    }

    /// Returns `nil` for failures the store resolves by ending the flow
    /// entirely (expired claim, invalid token, request gone) — those are
    /// announced on Active Requests, not on a screen that is being dismissed.
    static func map(_ error: RequestServiceError?) -> ClaimExtensionPresentationError? {
        guard let error else {
            return nil
        }

        switch error {
        case .serverError(let code, _):
            switch code {
            case ClaimErrorCode.claimExtensionInsufficientTime:
                return .insufficientTime
            case ClaimErrorCode.claimExtensionAlreadyUsed:
                return .alreadyUsed
            case ClaimErrorCode.publicActionsPaused:
                return .publicActionsPaused
            case ClaimErrorCode.rateLimited:
                return .rateLimited
            case ClaimErrorCode.claimExpired,
                 ClaimErrorCode.invalidClaimToken,
                 ClaimErrorCode.requestNotClaimed,
                 ClaimErrorCode.requestAlreadyPlaced,
                 ClaimErrorCode.requestExpired,
                 ClaimErrorCode.requestNotFound:
                return nil
            default:
                return .couldNotExtend
            }
        case .ambiguousExtensionOutcome:
            return .ambiguous
        default:
            return .couldNotExtend
        }
    }
}

enum FulfillmentPresentationError: Equatable {
    case invalidDetails
    case rateLimited
    case temporarilyUnavailable
    case couldNotRecord

    var message: String {
        switch self {
        case .invalidDetails:
            return "Check the order details and try recording them again. Do not place another external order."
        case .rateLimited:
            return "Too many attempts. Wait a moment before recording these same order details again. Do not place another external order."
        case .temporarilyUnavailable:
            return "We couldn’t record the order right now. Keep these order details and do not place another external order."
        case .couldNotRecord:
            // `INTERNAL_FAILURE` lands here, and the accepted contract records
            // that it can accompany a placement that may in fact have committed
            // (an exhausted unknown-commit result). So this must not assert that
            // nothing was recorded. Re-submitting the same CommonPlate details
            // is safe and is a real recovery — the backend answers a repeat with
            // REQUEST_ALREADY_PLACED — but placing a second external order is
            // not, and the two must not read as the same action.
            return "We couldn’t confirm whether CommonPlate recorded the order. You may try submitting these same order details again, but do not place another external order."
        }
    }

    static func map(_ error: RequestServiceError?) -> FulfillmentPresentationError? {
        guard let error else { return nil }
        switch error {
        case .serverError(let code, _):
            switch code {
            case "INVALID_FULFILLMENT_PAYLOAD":
                return .invalidDetails
            case ClaimErrorCode.rateLimited:
                return .rateLimited
            case "TRANSACTIONS_UNAVAILABLE":
                return .temporarilyUnavailable
            case ClaimErrorCode.claimExpired,
                 ClaimErrorCode.invalidClaimToken,
                 ClaimErrorCode.requestNotClaimed,
                 ClaimErrorCode.requestAlreadyPlaced,
                 ClaimErrorCode.requestNotFound:
                return nil
            default:
                return .couldNotRecord
            }
        case .ambiguousFulfillmentOutcome, .unresolvedFulfillment:
            return nil
        default:
            return .couldNotRecord
        }
    }
}

/// The claimant-only flow, reachable only from a confirmed backend claim. It is
/// the single place the pickup name is readable, and it never holds the raw
/// claim token — extension goes through `RequestStore`, which owns the token.
struct FulfillRequestView: View {
    /// The one-time extension prompt asks about the *reservation*, not about
    /// ordering: order submission does not exist yet, so "Still ordering?" would
    /// ask a helper to confirm an activity this screen tells them not to start.
    static let extensionPromptTitle = "Need more time?"

    /// Extending is the only thing this prompt can do. Declining keeps the
    /// current deadline — it is not a way to give the request back, and the
    /// wording must not suggest otherwise.
    static let extensionAcceptTitle = "Give me 5 more minutes"
    static let extensionDeclineTitle = "Keep my current time"

    let request: FoodRequest
    @ObservedObject var store: RequestStore
    var onReturnToActiveRequests: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var fulfillerEmail = ""
    @State private var orderNumber = ""
    @State private var eta = ""
    @State private var contactMessage = ""

    /// The claim this screen is showing. Nil once the store ends the flow —
    /// which pops the screen — so the body never renders claimant-private data
    /// without a live claim behind it.
    private var claim: ActiveClaimPresentation? {
        guard let activeClaim = store.activeClaim,
              activeClaim.requestID == request.id else {
            return nil
        }
        return activeClaim
    }

    var body: some View {
        Form {
            if let confirmation = matchingConfirmation {
                confirmationSection(confirmation)
            } else if let claim {
                if store.isShowingClaimExtensionPrompt {
                    extensionPromptSection
                }

                Section("Reservation") {
                    Label {
                        Text(Self.completedOrderNotice)
                            .font(.headline)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("fulfillment-completed-order-notice")

                    Text(Self.reservationNotice(claimExpiresAt: claim.claimExpiresAt))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("claim-reservation-notice")
                }

                Section("Order info") {
                    Text(request.foodDescription)

                    Text("\(request.diningSpot.name) · \(request.timingDescription)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Pickup name")
                        Spacer()
                        Text(claim.pickupName)
                            .fontWeight(.semibold)
                    }
                    .accessibilityIdentifier("claim-pickup-name")
                }

                if let extensionError = ClaimExtensionPresentationError.map(store.claimExtensionError) {
                    Section {
                        Text(extensionError.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("claim-extension-error")
                    }
                }

                if let ambiguity = matchingAmbiguity {
                    Section {
                        Text(Self.ambiguousTitle)
                            .font(.headline)
                        Text(Self.ambiguousDetail(isCheckingStatus: ambiguity.isCheckingStatus))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("fulfillment-ambiguous-detail")
                        if ambiguity.isCheckingStatus {
                            HStack {
                                ProgressView()
                                Text("Checking the request once…")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("fulfillment-ambiguous-state")
                } else {
                    fulfillmentForm

                    if let fulfillmentError = FulfillmentPresentationError.map(store.fulfillError) {
                        Section {
                            Text(fulfillmentError.message)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("fulfillment-error")
                        }
                    }
                }

            }
        }
        .navigationTitle("Help with Request")
        // The claim ending — expiration, or a backend verdict that the
        // reservation is no longer ours — closes this screen from either entry
        // path, so claimant-private state is never left on display without a
        // live claim behind it and the notice lands on Active Requests. Back
        // navigation does not clear `activeClaim`, so it does not trigger this.
        .onChange(of: store.activeClaim?.requestID) { _, activeRequestID in
            if activeRequestID != request.id && matchingConfirmation == nil {
                dismiss()
            }
        }
    }

    private var matchingConfirmation: FulfillmentConfirmation? {
        guard let confirmation = store.fulfillmentConfirmation,
              confirmation.requestID == request.id else { return nil }
        return confirmation
    }

    private var matchingAmbiguity: FulfillmentAmbiguityPresentation? {
        guard let ambiguity = store.fulfillmentAmbiguity,
              ambiguity.requestID == request.id else { return nil }
        return ambiguity
    }

    private var fulfillmentForm: some View {
        Section("Record completed order") {
            TextField("Helper email", text: $fulfillerEmail)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("fulfillment-email")

            Text(Self.helperEmailNotice)
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("Order number", text: $orderNumber)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .accessibilityIdentifier("fulfillment-order-number")

            TextField("ETA", text: $eta)
                .accessibilityIdentifier("fulfillment-eta")

            TextField("Message to requester (optional)", text: $contactMessage, axis: .vertical)
                .lineLimit(2...5)
                .accessibilityIdentifier("fulfillment-contact-message")

            Button {
                submitFulfillment()
            } label: {
                if store.isFulfilling {
                    HStack {
                        ProgressView()
                        Text("Recording…")
                    }
                } else {
                    Text(Self.submitTitle)
                }
            }
            .disabled(!isSubmissionEnabled)
            .accessibilityIdentifier("fulfillment-submit")
        }
    }

    @ViewBuilder
    private func confirmationSection(_ confirmation: FulfillmentConfirmation) -> some View {
        Section {
            Text(Self.confirmationTitle)
                .font(.title2.bold())
            Text(Self.confirmationDetail(for: confirmation.kind))
            Button(Self.returnTitle) {
                store.acknowledgeFulfillmentConfirmation(id: confirmation.id)
                if let onReturnToActiveRequests {
                    onReturnToActiveRequests()
                } else {
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("fulfillment-confirmation-return")
        }
        .accessibilityIdentifier("fulfillment-confirmation")
    }

    private var isSubmissionEnabled: Bool {
        Self.requiredFieldsArePresent(
            fulfillerEmail: fulfillerEmail,
            orderNumber: orderNumber,
            eta: eta
        ) && store.canSubmitFulfillment(requestID: request.id)
    }

    static func requiredFieldsArePresent(
        fulfillerEmail: String,
        orderNumber: String,
        eta: String
    ) -> Bool {
        !fulfillerEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !orderNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !eta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitFulfillment() {
        let email = fulfillerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = orderNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let etaText = eta.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = contactMessage.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            try? await store.fulfill(
                requestID: request.id,
                fulfillerEmail: email,
                orderNumber: number,
                eta: etaText,
                contactMessage: message.isEmpty ? nil : message
            )
        }
    }

    private var extensionPromptSection: some View {
        Section {
            Text(Self.extensionPromptTitle)
                .font(.headline)
                .accessibilityIdentifier("claim-extension-prompt")

            Button {
                Task {
                    await store.extendActiveClaim()
                }
            } label: {
                if store.isExtendingClaim {
                    HStack {
                        ProgressView()
                        Text("Adding time…")
                    }
                } else {
                    Text(Self.extensionAcceptTitle)
                }
            }
            .disabled(store.isExtendingClaim)
            .accessibilityIdentifier("claim-extension-accept")

            Button(Self.extensionDeclineTitle) {
                store.dismissClaimExtensionPrompt()
            }
            .disabled(store.isExtendingClaim)
            .accessibilityIdentifier("claim-extension-decline")
        }
    }

    /// The authoritative reservation deadline, stated once. Deliberately not a
    /// live countdown: the backend owns expiration, and a ticking client clock
    /// would imply a precision iOS does not have.
    static func reservationNotice(claimExpiresAt: Date) -> String {
        let time = claimExpiresAt.formatted(date: .omitted, time: .shortened)
        return "This request is reserved for you until \(time)."
    }

    static let completedOrderNotice =
        "Only record this after you have already placed the external order."
    static let helperEmailNotice =
        "This is the reply address the requester can use if their order-details email is sent."
    static let submitTitle = "Confirm placement"
    static let ambiguousTitle = "We couldn’t confirm the result"

    /// While the single read-only status check is still running.
    static let ambiguousCheckingDetail =
        "The order may already have been recorded. Do not submit again or place another order while we check."

    /// After that one read came back inconclusive (`open`, `claimed`, `404`, a
    /// decoding failure, or a transport failure). Nothing further is attempted —
    /// no second POST, no second GET, no polling — so the copy must stop
    /// implying a check is still running and say what the helper is left with.
    static let ambiguousUnresolvedDetail =
        "We still couldn’t confirm whether the order was recorded. Do not submit again or place another order. Return to Active Requests; this reservation will remain blocked until it expires."

    static func ambiguousDetail(isCheckingStatus: Bool) -> String {
        isCheckingStatus ? ambiguousCheckingDetail : ambiguousUnresolvedDetail
    }
    static let confirmationTitle = "Order recorded"
    static let returnTitle = "Return to Active Requests"

    static func confirmationDetail(for kind: FulfillmentConfirmationKind) -> String {
        switch kind {
        case .notificationSent:
            return "We emailed the requester the order details."
        case .notificationFailed:
            return "We couldn’t send the requester email, but the request is already marked placed. Do not place another order."
        case .emailStatusUnknown:
            return "We confirmed the request was placed, but we couldn’t confirm whether the requester email was sent. Do not place another order."
        }
    }
}
