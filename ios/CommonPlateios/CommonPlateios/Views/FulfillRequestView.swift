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

/// The choices offered for "When will it be ready?".
///
/// This is a presentation control over an unchanged backend contract: `eta` is
/// still a required free-form string on `POST /api/request/:id/fulfill`, and the
/// selected choice encodes into it verbatim. Same text both ways on purpose —
/// the student reads this value in the order-details email, so what the helper
/// picked is exactly what the student is told.
enum FulfillmentReadyTime: String, CaseIterable, Identifiable, Hashable {
    case asap
    case fifteenMinutes
    case thirtyMinutes
    case fortyFiveMinutes
    case sixtyMinutes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .asap:
            return "ASAP"
        case .fifteenMinutes:
            return "15 minutes"
        case .thirtyMinutes:
            return "30 minutes"
        case .fortyFiveMinutes:
            return "45 minutes"
        case .sixtyMinutes:
            return "60 minutes"
        }
    }

    /// What is sent as the backend `eta` field.
    var etaValue: String { label }

    /// The option a stored `eta` string came from, or nil if it was not one of
    /// these choices — a request placed before this control existed can carry
    /// any free text, and that must not be silently rewritten into a choice.
    static func option(forETA eta: String) -> FulfillmentReadyTime? {
        let trimmed = eta.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.first {
            $0.etaValue.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    /// `ASAP` unless draft state already holds one of the other valid choices.
    static func initialSelection(draftETA: String?) -> FulfillmentReadyTime {
        guard let draftETA, let option = option(forETA: draftETA) else {
            return .asap
        }
        return option
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
            // The fallback, and only the fallback. Every rule the backend
            // enforces on these fields is mirrored locally and named on the
            // field itself, so reaching this means the rejection could not be
            // attributed — the response envelope carries `fields: null` and no
            // field attribution of its own.
            //
            // Which is exactly why this cannot point at highlighted fields: by
            // definition none are highlighted here, so that instruction sent
            // the helper looking for a marker that does not exist. It names the
            // two values the helper can actually re-check instead, without
            // claiming which one the backend refused — nothing in the response
            // says. The locked safety sentence stays: this is still a state
            // where a second real order would cost a student money.
            return "We couldn’t save these details. Check your email address and order number, then tap “I placed this order” again. Don’t place another Grubhub order."
        case .rateLimited:
            return "Too many tries. Wait a moment, then tap “I placed this order” again. Don’t place another Grubhub order."
        case .temporarilyUnavailable:
            return "CommonPlate can’t save the order right now. Stay on this screen and try again in a moment. Don’t place another Grubhub order."
        case .couldNotRecord:
            // `INTERNAL_FAILURE` lands here, and the accepted contract records
            // that it can accompany a placement that may in fact have committed
            // (an exhausted unknown-commit result). So this must not assert that
            // nothing was recorded. Re-submitting the same CommonPlate details
            // is safe and is a real recovery — the backend answers a repeat with
            // REQUEST_ALREADY_PLACED — but a second Grubhub order is not, and
            // the two must not read as the same action.
            return "CommonPlate may not have saved your order. Tap “I placed this order” again. Trying again here only updates CommonPlate. It does not place another Grubhub order."
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
    @Binding var path: [AppRoute]

    /// The encoded backend `eta` string is written only from `readyTime`, so the
    /// value the helper picked and the value the student reads are the same text.
    @State private var draft = FulfillmentFormDraft()

    /// A field revalidates live only after its own error has appeared. This is
    /// intentionally view-local and independent from request creation.
    @State private var validationPresentation = FulfillmentValidationPresentation()
    @FocusState private var focusedField: FulfillmentFormField?

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

                    // One instruction, not a tutorial: the helper already knows
                    // how their own Grubhub order works, they only need to know
                    // which name to put on it.
                    Text(Self.pickupNameInstruction(pickupName: claim.pickupName))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("claim-pickup-name-instruction")
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
                    let isShowingRecovery = Self.showsAmbiguityRecoveryCopy(
                        isRecoveryAvailable: ambiguity.isRecoveryAvailable,
                        isRecovering: ambiguity.isRecovering
                    )
                    Section {
                        // Before the question, not after it: the helper needs
                        // the state they are in before they read what the
                        // action does about it.
                        if isShowingRecovery {
                            Text(Self.ambiguityRecoveryContext)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("fulfillment-ambiguity-recovery-context")
                        }
                        Text(isShowingRecovery
                             ? Self.ambiguityRecoveryTitle
                             : Self.ambiguousTitle(isCheckingStatus: ambiguity.isCheckingStatus))
                            .font(.headline)
                        Text(isShowingRecovery
                             ? Self.ambiguityRecoveryDetail
                             : Self.ambiguousDetail(isCheckingStatus: ambiguity.isCheckingStatus))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("fulfillment-ambiguous-detail")
                        if ambiguity.isCheckingStatus {
                            HStack {
                                ProgressView()
                                Text("Checking…")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        if ambiguity.isRecovering {
                            HStack {
                                ProgressView()
                                Text("Saving…")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        if Self.showsAmbiguityRecoveryAction(
                            isCheckingStatus: ambiguity.isCheckingStatus,
                            isRecoveryAvailable: ambiguity.isRecoveryAvailable
                        ) {
                            Button(Self.ambiguityRecoveryActionTitle) {
                                let ambiguityID = ambiguity.id
                                Task {
                                    try? await store.resubmitAmbiguousFulfillment(
                                        ambiguityID: ambiguityID,
                                        requestID: request.id
                                    )
                                }
                            }
                            .disabled(store.isFulfilling)
                            .accessibilityIdentifier("fulfillment-ambiguity-recovery")
                        }
                        // Navigation only. It uses the same exit the
                        // confirmation section uses, minus the store call —
                        // nothing here resolves the ambiguity or unblocks a
                        // second submission.
                        if Self.showsAmbiguityReturnAction(
                            isCheckingStatus: ambiguity.isCheckingStatus
                        ) {
                            Button(Self.returnTitle) {
                                Self.returnToActiveRequests(from: store) {
                                    returnToActiveRequests()
                                }
                            }
                            .accessibilityIdentifier("fulfillment-ambiguous-return")
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
        .navigationTitle(Self.navigationTitle)
        // The one place the ETA control's default is decided. `eta` is this
        // screen's draft state and survives its own re-appearances, so a helper
        // who already chose "30 minutes" and came back does not silently get
        // ASAP; only an empty or unrecognised draft falls back to the default.
        .onAppear {
            draft.readyTime = FulfillmentReadyTime.initialSelection(draftETA: draft.eta)
            draft.eta = draft.readyTime.etaValue
        }
        .onChange(of: focusedField) { previousField, currentField in
            validationPresentation.handleFocusTransition(
                from: previousField,
                to: currentField,
                errors: currentFieldErrors
            )
        }
        // The claim ending — expiration, or a backend verdict that the
        // reservation is no longer ours — closes this screen from either entry
        // path, so claimant-private state is never left on display without a
        // live claim behind it and the notice lands on Active Requests. The
        // whole helper flow is unwound rather than one level, because the
        // request detail underneath is just as stale. Back navigation does not
        // clear `activeClaim`, so it does not trigger this.
        .onChange(of: store.activeClaim?.requestID) { _, activeRequestID in
            if !Self.keepsClaimedFlowPresented(
                activeRequestID: activeRequestID,
                confirmationRequestID: store.fulfillmentConfirmation?.requestID,
                requestID: request.id
            ) {
                returnToActiveRequests()
            }
        }
        // The same rule from the confirmation's side, so the invariant holds no
        // matter which surface acknowledged the placement — this screen's own
        // button, or the Active Requests card that carries the same result. A
        // screen with nothing left to render leaves instead of going blank.
        .onChange(of: store.fulfillmentConfirmation?.id) { _, _ in
            if !Self.hasPresentableContent(
                hasClaim: claim != nil,
                hasConfirmation: matchingConfirmation != nil
            ) {
                returnToActiveRequests()
            }
        }
    }

    /// The only exit this screen has. Rewriting the path — rather than
    /// dismissing — is what removes the completed claimant screen *and* the
    /// request detail that opened it in one update. A `dismiss()` read on that
    /// detail could not do it: it is below this screen in the stack, so SwiftUI
    /// does not act on it while this screen is on top, which is what left the
    /// emptied reservation screen visible after a confirmed placement.
    private func returnToActiveRequests() {
        path = AppRoute.returningToActiveRequests(from: path)
    }

    /// This screen renders nothing at all once both the claim and the
    /// confirmation are gone — exactly the state acknowledging a placement
    /// produces. It is never a state a helper should see, because the same
    /// acknowledgement takes the screen off the stack; stated here so a
    /// regression that leaves the destination behind is a test failure rather
    /// than a blank screen under a "Your reservation" title.
    static func hasPresentableContent(hasClaim: Bool, hasConfirmation: Bool) -> Bool {
        hasClaim || hasConfirmation
    }

    /// A confirmed placement clears claimant credentials immediately, but its
    /// confirmation stays on this screen until acknowledged. This keeps the
    /// screen on the stack for that safe terminal presentation only.
    static func keepsClaimedFlowPresented(
        activeRequestID: String?,
        confirmationRequestID: String?,
        requestID: String
    ) -> Bool {
        activeRequestID == requestID || confirmationRequestID == requestID
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

    /// Headerless on purpose. "After you’ve ordered" duplicated the instruction
    /// already given at the top of the screen and pushed the fields further down
    /// a form that was reading as too long.
    private var fulfillmentForm: some View {
        Section {
            TextField("Your email", text: $draft.fulfillerEmail)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .fulfillerEmail)
                .accessibilityIdentifier("fulfillment-email")
                .accessibilityHint(Text(fieldError(.fulfillerEmail) ?? ""))

            fieldErrorText(.fulfillerEmail, identifier: "fulfillment-email-error")

            Text(Self.helperEmailNotice)
                .font(.footnote)
                .foregroundStyle(.secondary)

            // A digits-only contract, so the keypad matches it. The binding
            // stays a `String` and nothing filters or reformats it as the
            // helper types: a paste that carries letters keeps them on screen
            // and is explained by the field's own message, rather than being
            // silently rewritten into something the helper never entered.
            // Leading zeroes are text here and survive to the wire intact.
            TextField("Order number", text: $draft.orderNumber)
                .keyboardType(.numberPad)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .orderNumber)
                .accessibilityIdentifier("fulfillment-order-number")
                .accessibilityHint(Text(fieldError(.orderNumber) ?? ""))

            fieldErrorText(.orderNumber, identifier: "fulfillment-order-number-error")

            Text(Self.orderNumberNotice)
                .font(.footnote)
                .foregroundStyle(.secondary)

            // A menu picker, not a text field. The free-text row read as static
            // text — a helper could not tell "Ready in  15 minutes" was theirs
            // to change — and left them inventing a phrasing for an order that
            // might be ready immediately or in an hour.
            Picker(Self.readyTimeQuestion, selection: $draft.readyTime) {
                ForEach(FulfillmentReadyTime.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("fulfillment-eta")
            .onChange(of: draft.readyTime) { _, selection in
                draft.eta = selection.etaValue
            }

            TextField(
                "Message to the student (optional)",
                text: $draft.contactMessage,
                axis: .vertical
            )
                .lineLimit(2...5)
                .accessibilityIdentifier("fulfillment-contact-message")

            Button {
                submitFulfillment()
            } label: {
                if store.isFulfilling {
                    HStack {
                        ProgressView()
                        Text("Saving…")
                    }
                } else {
                    Text(Self.submitTitle)
                }
            }
            .disabled(!isSubmissionEnabled)
            .accessibilityIdentifier("fulfillment-submit")
        }
    }

    private var currentFieldErrors: [FulfillmentFieldError] {
        FulfillmentFormValidator.validate(
            fulfillerEmail: draft.fulfillerEmail,
            orderNumber: draft.orderNumber
        )
    }

    private func fieldError(_ field: FulfillmentFormField) -> String? {
        validationPresentation
            .visibleErrors(from: currentFieldErrors)
            .first { $0.field == field }?
            .message
    }

    /// The message sits immediately below the field it names, in the same red
    /// the form already uses for a failed submission, so the invalid field is
    /// identified where the helper is already looking.
    @ViewBuilder
    private func fieldErrorText(
        _ field: FulfillmentFormField,
        identifier: String
    ) -> some View {
        if let message = fieldError(field) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier(identifier)
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
                returnToActiveRequests()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("fulfillment-confirmation-return")
        }
        .accessibilityIdentifier("fulfillment-confirmation")
    }

    private var isSubmissionEnabled: Bool {
        Self.isSubmissionEnabled(
            draft: draft,
            isOperationallyAvailable: store.canSubmitFulfillment(requestID: request.id)
        )
    }

    static func isSubmissionEnabled(
        draft: FulfillmentFormDraft,
        isOperationallyAvailable: Bool
    ) -> Bool {
        guard isOperationallyAvailable else { return false }

        return !draft.fulfillerEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.orderNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.eta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitFulfillment() {
        let submittedDraft = draft
        let currentPresentation = validationPresentation
        Task {
            do {
                let result = try await Self.orchestrateSubmission(
                    draft: submittedDraft,
                    presentation: currentPresentation
                ) { values in
                    try await store.fulfill(
                        requestID: request.id,
                        fulfillerEmail: values.fulfillerEmail,
                        orderNumber: values.orderNumber,
                        eta: values.eta,
                        contactMessage: values.contactMessage
                    )
                }
                validationPresentation = result.presentation
                if !result.didSubmit {
                    focusedField = result.firstInvalidTextField
                }
            } catch {
                // RequestStore owns and publishes backend/lifecycle failures.
                // The draft remains untouched for correction or retry.
            }
        }
    }

    /// The production submit seam. Form validation and normalization complete
    /// before the injected closure can reach `RequestStore`; lifecycle and
    /// duplicate protection remain entirely store-owned.
    static func orchestrateSubmission(
        draft: FulfillmentFormDraft,
        presentation: FulfillmentValidationPresentation,
        submission: (FulfillmentSubmissionValues) async throws -> Void
    ) async throws -> FulfillmentSubmissionResult {
        let email = draft.fulfillerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = draft.orderNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let eta = draft.eta.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = draft.contactMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let errors = FulfillmentFormValidator.validate(
            fulfillerEmail: email,
            orderNumber: number
        )
        var updatedPresentation = presentation
        updatedPresentation.presentAll(errors)

        guard errors.isEmpty else {
            return FulfillmentSubmissionResult(
                presentation: updatedPresentation,
                firstInvalidTextField: errors.first?.field,
                didSubmit: false
            )
        }

        try await submission(FulfillmentSubmissionValues(
            fulfillerEmail: email,
            orderNumber: number,
            eta: eta,
            contactMessage: message.isEmpty ? nil : message
        ))
        return FulfillmentSubmissionResult(
            presentation: updatedPresentation,
            firstInvalidTextField: nil,
            didSubmit: true
        )
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

    static let navigationTitle = "Your reservation"

    /// The order comes first and this screen only records it. Stated as the two
    /// steps they are, near the top, because it is the one instruction a helper
    /// has to act on before touching anything else on the screen.
    static let completedOrderNotice =
        "Place the Grubhub order first. Then save the details here."
    /// The student sees this address on the emailed order details and can reply
    /// to it, so the disclosure has to be plain rather than conditional.
    static let helperEmailNotice =
        "The student will see this email and can reply."
    static let orderNumberNotice = "From your Grubhub confirmation."
    /// A question, because the control answers one. "Ready in" read as a label
    /// on a value rather than as something to choose.
    static let readyTimeQuestion = "When will it be ready?"
    static let submitTitle = "I placed this order"

    /// The single pickup-name instruction. The helper does not need to be taught
    /// Grubhub; they need to be told which name to use, once, next to the name.
    static func pickupNameInstruction(pickupName: String) -> String {
        "Use “\(pickupName)” as the pickup name in Grubhub."
    }

    /// While the single read-only status check is still running.
    static let ambiguousCheckingTitle = "We’re checking your order"
    static let ambiguousCheckingDetail =
        "Your order may already be saved. Don’t tap again or place another Grubhub order while we check."

    /// After every permitted recovery action has been exhausted. At this point
    /// there is no further POST, GET, or polling, so the copy must stop implying
    /// a check is still running and say what the helper is left with.
    ///
    /// Deliberately generic about *why*. This state is reached from transport
    /// loss, an undecodable response, and an explicit server refusal
    /// (`RATE_LIMITED`, `TRANSACTIONS_UNAVAILABLE`, `INTERNAL_FAILURE`,
    /// `INVALID_FULFILLMENT_PAYLOAD`) alike, so naming a lost connection would
    /// be false in the refusal cases. Either write may still have landed — the
    /// original one especially — which is exactly why no second real order is
    /// safe.
    static let ambiguousUnresolvedTitle = "CommonPlate still can’t confirm the order details."
    static let ambiguousUnresolvedDetail =
        "The original save or the one-time retry may have worked. Don’t place another Grubhub order. You can’t try saving again from this screen."

    /// Shown immediately above the locked recovery question. The checking-state
    /// sentence that carried this fact ("Your order may already be saved") is
    /// replaced the moment the recovery is offered, so without this the helper
    /// decides whether to resend without being told what state they are in. The
    /// locked strings say what the action does; this says what it is answering.
    static let ambiguityRecoveryContext =
        "CommonPlate still can’t confirm whether the first save worked, so these order details may already be recorded."

    static let ambiguityRecoveryTitle = "Try saving to CommonPlate once more?"
    static let ambiguityRecoveryDetail =
        "This sends the same order details to CommonPlate one more time. It will not place another Grubhub order or charge you again. Don’t place another Grubhub order."
    static let ambiguityRecoveryActionTitle = "Send details to CommonPlate once more"

    static func ambiguousTitle(isCheckingStatus: Bool) -> String {
        isCheckingStatus ? ambiguousCheckingTitle : ambiguousUnresolvedTitle
    }

    static func ambiguousDetail(isCheckingStatus: Bool) -> String {
        isCheckingStatus ? ambiguousCheckingDetail : ambiguousUnresolvedDetail
    }

    static func showsAmbiguityRecoveryAction(
        isCheckingStatus: Bool,
        isRecoveryAvailable: Bool
    ) -> Bool {
        !isCheckingStatus && isRecoveryAvailable
    }

    /// Whether the section is presenting the recovery decision — the offer
    /// itself, or the permitted repeat already running. Both states must carry
    /// the context sentence and the locked question, because the helper who is
    /// watching their one attempt run is owed the same framing as the helper
    /// deciding to start it.
    static func showsAmbiguityRecoveryCopy(
        isRecoveryAvailable: Bool,
        isRecovering: Bool
    ) -> Bool {
        isRecoveryAvailable || isRecovering
    }

    /// The settled state names an exit, so it has to offer one. Withheld while
    /// the single check is still running: leaving mid-read would invite a tap
    /// on a state that is about to answer itself.
    static func showsAmbiguityReturnAction(isCheckingStatus: Bool) -> Bool {
        !isCheckingStatus
    }

    /// The settled unresolved state's only action, isolated so it is provable
    /// that leaving is *purely* navigation: it resolves nothing, clears no
    /// claim, re-enables no submission, and sends no request. The reservation
    /// stays held and blocked until it expires, exactly as the copy says.
    static func returnToActiveRequests(
        from store: RequestStore,
        navigate: () -> Void
    ) {
        _ = store
        navigate()
    }

    static let confirmationTitle = "Order recorded"
    static let returnTitle = "Back to Active Requests"

    static func confirmationDetail(for kind: FulfillmentConfirmationKind) -> String {
        switch kind {
        case .notificationSent:
            return "We sent the order details to the student’s email. They’ll pick up the food themselves—you’re done. If they reply, it goes to the address you entered."
        case .notificationFailed:
            return "Your order is recorded, but we couldn’t email the student. They may not know their food is waiting. Don’t place another Grubhub order."
        case .emailStatusUnknown:
            return "Your order is recorded. We couldn’t tell whether the student’s email went out, so they may not know their food is waiting. Don’t place another Grubhub order."
        }
    }
}
