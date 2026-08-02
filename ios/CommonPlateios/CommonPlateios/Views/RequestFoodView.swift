//
//  RequestFoodView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

enum RequestFoodFormError: Error, Equatable {
    case missingDiningSpot
    case missingFood
    case missingPickupName
    case missingEmail
    case invalidEmail
    case invalidScheduledTime
    /// A `Later` selection that outlived scheduling itself. Distinct from
    /// `invalidScheduledTime` because the correction is different: there is no
    /// pickup time left to choose today, only ASAP.
    case scheduledTimingUnavailable

    var message: String {
        switch self {
        case .missingDiningSpot:
            return "Choose an NYU dining spot."
        case .missingFood:
            return "Tell us what food you need."
        case .missingPickupName:
            return "Enter the name to use for the order."
        case .missingEmail:
            return "Enter your email address."
        case .invalidEmail:
            return "Enter a valid email address."
        case .invalidScheduledTime:
            return "Choose a pickup time that leaves a full 30-minute window today."
        case .scheduledTimingUnavailable:
            return RequestFoodView.lapsedScheduledTimingNotice
        }
    }
}

enum RequestCreatePresentationError: Equatable {
    case invalidRequest
    case requestLimitReached
    /// `RATE_LIMITED`. Distinct from `requestLimitReached`: that one is the
    /// daily allowance and reopens tomorrow, this one is a short per-IP
    /// throttle that clears in about a minute. Both are refused ahead of the
    /// write, so neither is ambiguous.
    case rateLimited
    case publicActionsPaused
    case creationFailed
    case ambiguous
    case operationInProgress

    var message: String {
        switch self {
        case .invalidRequest:
            return "Check the information you entered and try again."
        case .requestLimitReached:
            return "CommonPlate attempts to limit each email to three meal requests a day. Please try again tomorrow."
        case .rateLimited:
            // Same sentence the helper sees for a throttled claim, since the
            // situation and the next step are identical.
            return "Too many attempts. Please wait a moment and try again."
        case .publicActionsPaused:
            // One source for the locked sentence, so the notice shown before
            // data entry and this submit-time backstop cannot drift apart.
            return RequestFoodView.pauseNotice
        case .creationFailed:
            return "We couldn’t post your request. Please try again in a moment."
        case .ambiguous:
            return "We couldn’t confirm whether your request was posted. Check Active Requests before submitting again."
        case .operationInProgress:
            return "Your request is already being posted."
        }
    }

    static func map(_ error: Error) -> RequestCreatePresentationError {
        guard let serviceError = error as? RequestServiceError else {
            return .creationFailed
        }

        switch serviceError {
        case .serverError(let code, _):
            switch code {
            case "INVALID_REQUEST":
                return .invalidRequest
            case "REQUEST_LIMIT_REACHED":
                return .requestLimitReached
            case "RATE_LIMITED":
                return .rateLimited
            case "PUBLIC_ACTIONS_PAUSED":
                return .publicActionsPaused
            case "REQUEST_CREATION_FAILED":
                return .creationFailed
            default:
                return .creationFailed
            }
        case .ambiguousCreateOutcome:
            return .ambiguous
        case .operationInProgress:
            return .operationInProgress
        default:
            return .creationFailed
        }
    }
}

/// The one form-level error rendered beside the request submission action.
/// Field validation never enters this state; those errors remain owned by
/// their adjacent field rows.
struct RequestSubmissionSectionPresentation: Equatable {
    let error: RequestCreatePresentationError
    let message: String
    let showsReturnHomeAction: Bool
}

/// What the requester screen shows. Availability is resolved before any field
/// exists, so `.form` — the only state with editable private fields and a
/// submit control — is reachable only from a confirmed `.available` answer.
enum RequestFormPresentation: Equatable {
    /// An earlier create may already have posted a request, so creation is
    /// blocked for the rest of this process. This outranks every availability
    /// state: whether posting happens to be open, paused, or unknown is a
    /// smaller fact than "your request may already exist", and none of those
    /// answers would change what this student can do next.
    case blockedByUnresolvedCreateAmbiguity
    /// A probe is running. No fields, no submit. Reached only while a check is
    /// genuinely in flight, so this state always has an answer coming.
    case checkingAvailability
    case form
    /// Posting is paused, or availability could not be established. `retryable`
    /// is false for a paused backend, where retrying changes nothing.
    case unavailable(message: String, retryable: Bool)
    /// A create was confirmed by the backend.
    case success
}

/// Requester-facing request form. Temporary input and presentation state stay
/// here; confirmed canonical collection state is owned by `RequestStore`.
struct RequestFoodView: View {
    /// Shared verbatim with the web request form.
    static let pauseNotice = "Posting a meal request is temporarily unavailable."

    /// Shown when the pause probe itself failed. Deliberately not the locked
    /// sentence: the app does not know that posting is paused, only that it
    /// could not find out, and it must not claim otherwise.
    static let availabilityUnknownNotice =
        "We couldn’t check whether posting is available right now. Please try again in a moment."

    /// Explains why email is collected: public endpoints never return it, and
    /// request creation does not guarantee email delivery.
    static let emailPurposeNotice =
        "We use your email to coordinate updates about your request. Helpers never see it."

    /// Requester-facing expiration copy. These two sentences must stay equal to
    /// the backend contract in `src/createRequestRoute.ts`, which writes
    /// `expiresAt` explicitly at creation: an ASAP request expires five hours
    /// after the backend creation time, and a scheduled request expires at its
    /// validated `windowEnd`. Neither sentence promises fulfillment.
    static let asapExpirationNotice =
        "Your request is now visible to helpers. It will expire in 5 hours if it is not fulfilled."
    static let scheduledExpirationNotice =
        "Your request is now visible to helpers. It will expire when the pickup window ends if it is not fulfilled."

    /// Shown beneath the single scheduled-time control, which collects only a
    /// start; the end is derived. The student would otherwise have no way to
    /// know what helpers actually see.
    static let scheduledWindowNotice =
        "Helpers will see a 30-minute pickup window starting at this time."

    /// Shown when no full 30-minute window fits before the next calendar-day
    /// boundary. Scheduling is withheld rather than offered as an unusable
    /// picker; tomorrow scheduling is not part of this flow.
    static let scheduledUnavailableNotice = "Scheduled pickups reopen tomorrow."

    /// The same fact plus the only move left, for a requester who selected
    /// `Later` while it was still offered and stayed on the form past the last
    /// valid window. Their selection is never rewritten for them — a draft that
    /// silently changes itself is worse than one that explains what to do — so
    /// the error names ASAP and waits for them to choose it.
    static let lapsedScheduledTimingNotice =
        "Scheduled pickups reopen tomorrow. Choose ASAP to post this request now."

    /// The pointer shown beside `Submit Request` when a local rejection has no
    /// text field to focus. Every invalid field already carries its own message,
    /// but the only two that cannot take focus are pickers, and a tap that moves
    /// nothing and says nothing reads as a broken button — which is exactly what
    /// a lapsed `Later` selection produced.
    static let localRejectionPointerNotice = "Check the highlighted fields above."

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: RequestStore

    @State private var draft = RequestFoodFormDraft()
    @State private var validationPresentation = RequestFoodValidationPresentation()
    @State private var submissionError: RequestCreatePresentationError?
    /// Set only by a local rejection that had no text field to focus. Backend
    /// failures never set it — they own `submissionError`, which is the
    /// authoritative message for anything the server decided.
    @State private var showsLocalRejectionPointer = false
    @State private var didCreateRequest = false
    /// The timing of the request the backend confirmed, captured at submission
    /// so the success screen states that request's real expiration rather than
    /// whatever the picker happens to show afterwards.
    @State private var confirmedTiming: RequestTiming = .asap
    @FocusState private var focusedField: RequestFoodFormField?

    private var calendar: Calendar {
        Calendar.current
    }

    /// The store-owned create ambiguity outlives this view and takes precedence
    /// over local submission errors.
    private var effectiveSubmissionError: RequestCreatePresentationError? {
        Self.effectiveSubmissionError(
            hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity,
            submissionError: submissionError
        )
    }

    private var isSubmissionEnabled: Bool {
        Self.isSubmissionEnabled(
            draft: draft,
            submissionError: effectiveSubmissionError,
            isCreating: store.isCreating
        )
    }

    let diningSpots = [
        DiningSpot(name: "Crave NYU", address: "John A. Paulson Center, 6th Floor"),
        DiningSpot(name: "Dunkin' at U-Hall", address: "U-Hall, 108 E 14th St"),
        DiningSpot(name: "Jasper Kane Cafe", address: "BROOKLYN, Rogers Hall"),
        DiningSpot(name: "Peet's Coffee at Kimmel", address: "Kimmel Center, 60 Washington Sq S, 2nd Floor"),
        DiningSpot(name: "Cafe 370", address: "BROOKLYN - 370 Jay St"),
        DiningSpot(name: "Flavor Lab by NYU Eats", address: "Jasper Kane Cafe"),
        DiningSpot(name: "Cafe 181", address: "John A. Paulson Center, 6th Floor"),
        DiningSpot(name: "Upstein - Vedge Craft & Smoothie Lab", address: "Weinstein Hall, 5 University Pl #11"),
        DiningSpot(name: "Upstein - Shareables, Cluckstein, Slidestein & Taqueria", address: "Weinstein Hall, 5 University Pl #11"),
        DiningSpot(name: "True Burger at UHall", address: "U-Hall, 110 E. 14th"),
        DiningSpot(name: "Palladium", address: "Palladium Hall, 140 E 14th St")
    ]

    var body: some View {
        Group {
            switch Self.presentation(
                hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity,
                availability: store.requestCreationAvailability,
                isCheckingAvailability: store.isCheckingRequestCreationAvailability,
                hasAttemptedAvailabilityCheck: store.hasAttemptedRequestCreationAvailabilityCheck,
                didCreateRequest: didCreateRequest
            ) {
            case .blockedByUnresolvedCreateAmbiguity:
                blockedByAmbiguityView
            case .success:
                successView
            case .checkingAvailability:
                availabilityCheckView
            case .unavailable(let message, let retryable):
                unavailableView(message: message, retryable: retryable)
            case .form:
                requestForm
            }
        }
        .navigationTitle("Request Food")
        // Runs before anything is rendered, and the pre-probe state is
        // `.unknown`, so the form cannot flash while the answer is pending.
        // Skipped entirely while blocked: the answer could not change this
        // screen, so asking for it would be a request made for nothing.
        .task {
            guard Self.shouldProbeAvailability(
                hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity
            ) else {
                return
            }
            await store.refreshRequestCreationAvailability()
        }
    }

    /// The blocked screen. It deliberately renders no fields and no submit
    /// control — there is nothing here to correct and nothing to resend — and
    /// it takes its copy and its single action from the same
    /// `submissionSectionPresentation` seam the in-form error row uses, so the
    /// two can never drift into saying different things about one situation.
    private var blockedByAmbiguityView: some View {
        VStack(spacing: 16) {
            if let presentation = Self.submissionSectionPresentation(for: .ambiguous) {
                Text(presentation.message)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("request-submission-error")

                if presentation.showsReturnHomeAction {
                    Button("Back to Home") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("request-ambiguous-dismiss")
                }
            }
        }
        .padding()
    }

    /// Only confirmed availability reveals the form. An `.unknown` result after
    /// a completed probe becomes retryable once no check is running.
    static func presentation(
        hasUnresolvedCreateAmbiguity: Bool,
        availability: RequestCreationAvailability,
        isCheckingAvailability: Bool,
        hasAttemptedAvailabilityCheck: Bool,
        didCreateRequest: Bool
    ) -> RequestFormPresentation {
        // First, ahead of everything. A paused or unresolved availability answer
        // is true but beside the point once a create may already have posted:
        // showing it would replace the one warning that matters with a smaller
        // one, and the student would leave thinking nothing had happened.
        if hasUnresolvedCreateAmbiguity {
            return .blockedByUnresolvedCreateAmbiguity
        }

        if didCreateRequest {
            return .success
        }

        switch availability {
        case .available:
            return .form
        case .unknown:
            if isCheckingAvailability {
                return .checkingAvailability
            }
            return hasAttemptedAvailabilityCheck
                ? .unavailable(message: availabilityUnknownNotice, retryable: true)
                // Nothing has run yet — the screen's own `.task` is about to
                // start the first probe. Withheld, never retryable: there is
                // nothing to retry.
                : .checkingAvailability
        case .paused:
            return .unavailable(message: pauseNotice, retryable: false)
        case .unavailable:
            return .unavailable(message: availabilityUnknownNotice, retryable: true)
        }
    }

    private var availabilityCheckView: some View {
        ProgressView("Checking availability…")
            .padding()
    }

    private func unavailableView(message: String, retryable: Bool) -> some View {
        VStack(spacing: 16) {
            Text(message)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("request-unavailable-notice")

            if retryable {
                Button("Try Again") {
                    Task {
                        await store.refreshRequestCreationAvailability()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }

    private var successView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text("Request posted")
                .font(.title)
                .fontWeight(.bold)

            Text(Self.expirationNotice(for: confirmedTiming))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("request-success-expiration")

            Button("Back to Home") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var requestForm: some View {
        let now = Date()
        let latestScheduledStart = Self.latestScheduledStart(on: now, calendar: calendar)
            ?? Self.endOfDay(containing: now, calendar: calendar)
            ?? now
        let scheduledStartRange = min(now, latestScheduledStart)...latestScheduledStart
        let isScheduledTimingAvailable = Self.isScheduledTimingAvailable(
            now: now,
            calendar: calendar
        )
        let timingOptions = Self.availableTimingOptions(now: now, calendar: calendar)
        let errors = validationErrors(now: now)
        let visibleScheduleError = validationPresentation
            .visibleError(for: .pickupSchedule, from: errors)?
            .error

        return Form {
            Section("Food request") {
                Picker("NYU dining spot", selection: $draft.selectedDiningSpot) {
                    Text("Select a spot").tag(nil as DiningSpot?)

                    ForEach(diningSpots) { spot in
                        Text(spot.name).tag(Optional(spot))
                    }
                }

                fieldErrorText(
                    .diningSpot,
                    errors: errors,
                    identifier: "request-dining-spot-error"
                )

                if let address = draft.selectedDiningSpot?.address {
                    Text(address)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                TextField("What do you want?", text: $draft.foodRequest, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
                    .focused($focusedField, equals: .foodDescription)
                    .accessibilityHint(Text(fieldError(.foodDescription, errors: errors) ?? ""))

                fieldErrorText(
                    .foodDescription,
                    errors: errors,
                    identifier: "request-food-error"
                )
            }

            Section("Pickup") {
                TextField("Name to use for the order", text: $draft.pickupName)
                    .focused($focusedField, equals: .pickupName)
                    .accessibilityHint(Text(fieldError(.pickupName, errors: errors) ?? ""))

                fieldErrorText(
                    .pickupName,
                    errors: errors,
                    identifier: "request-pickup-name-error"
                )

                // Only the timings a full 30-minute window can still fit into
                // are offered, so "Later" cannot be selected when it is
                // impossible.
                Picker("When do you need it?", selection: $draft.timing) {
                    ForEach(timingOptions) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: draft.timing) { _, newTiming in
                    guard newTiming == .later else {
                        return
                    }
                    draft.preferredPickupTime = min(
                        max(draft.preferredPickupTime, now),
                        latestScheduledStart
                    )
                }

                // Withheld once the lapsed-Later error is on screen: that
                // message already opens with this exact sentence, and printing
                // it twice would read as two separate findings about the same
                // closed window.
                if Self.showsScheduledUnavailableNotice(
                    isScheduledTimingAvailable: isScheduledTimingAvailable,
                    visibleScheduleError: visibleScheduleError
                ) {
                    Text(Self.scheduledUnavailableNotice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("scheduled-unavailable-notice")
                }

                if draft.timing == .later && isScheduledTimingAvailable {
                    DatePicker(
                        "Around what time?",
                        selection: $draft.preferredPickupTime,
                        in: scheduledStartRange,
                        displayedComponents: [.hourAndMinute]
                    )
                }

                // This one location is deliberately outside the available-only
                // DatePicker branch. If time passes while "Later" is selected,
                // a submitted scheduling error stays visible beside the timing
                // controls rather than disappearing with the picker.
                fieldErrorText(
                    .pickupSchedule,
                    errors: errors,
                    identifier: "request-pickup-schedule-error"
                )

                if draft.timing == .later && isScheduledTimingAvailable {
                    Text(Self.scheduledWindowNotice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("scheduled-window-notice")
                }

                Text("The student placing the order will use this name and approximate time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(Self.formExpirationNotice(for: draft.timing))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("request-form-expiration")
            }

            Section("Contact") {
                TextField("Email, required", text: $draft.email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .requesterEmail)
                    .accessibilityHint(Text(fieldError(.requesterEmail, errors: errors) ?? ""))

                fieldErrorText(
                    .requesterEmail,
                    errors: errors,
                    identifier: "request-email-error"
                )

                Text(Self.emailPurposeNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                // Only when the rejection had nowhere to move focus. A backend
                // failure owns this section through `submissionError` and is
                // never replaced or accompanied by the pointer.
                if Self.showsLocalRejectionPointer(
                    isPresenting: showsLocalRejectionPointer,
                    submissionError: effectiveSubmissionError
                ) {
                    Text(Self.localRejectionPointerNotice)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("request-submission-pointer")
                }

                if let presentation = Self.submissionSectionPresentation(for: effectiveSubmissionError) {
                    Text(presentation.message)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("request-submission-error")

                    // The ambiguous outcome disables submission permanently and
                    // offers no retry, so without a way out the student is left
                    // on a form they cannot use. Leaving is the only action;
                    // the entered values stay untouched until they choose it.
                    if presentation.showsReturnHomeAction {
                        Button("Back to Home") {
                            dismiss()
                        }
                        .accessibilityIdentifier("request-ambiguous-dismiss")
                    }
                }

                Button {
                    Task {
                        await submit()
                    }
                } label: {
                    if store.isCreating {
                        HStack {
                            ProgressView()
                            Text("Posting…")
                        }
                    } else {
                        Text("Submit Request")
                    }
                }
                .disabled(!isSubmissionEnabled)
            }
        }
        .onChange(of: focusedField) { previousField, currentField in
            let transitionNow = Date()
            validationPresentation.handleFocusTransition(
                from: previousField,
                to: currentField,
                errors: validationErrors(now: transitionNow)
            )
        }
        // Any edit — including switching the timing to ASAP, which is the
        // correction the lapsed-Later message asks for — retires the pointer.
        // The field errors themselves keep updating live on their own terms.
        .onChange(of: draft) { _, _ in
            showsLocalRejectionPointer = false
        }
    }

    @MainActor
    private func submit() async {
        submissionError = nil
        showsLocalRejectionPointer = false

        let now = Date()
        let submittedDraft = draft
        do {
            let result = try await Self.orchestrateSubmission(
                draft: submittedDraft,
                now: now,
                calendar: calendar,
                presentation: validationPresentation
            ) { payload in
                try await store.createRequest(payload)
            }
            validationPresentation = result.presentation
            if result.didSubmit {
                confirmedTiming = submittedDraft.timing
                didCreateRequest = true
            } else {
                focusedField = result.firstInvalidTextField
                showsLocalRejectionPointer = Self.showsLocalRejectionPointer(for: result)
            }
        } catch {
            submissionError = RequestCreatePresentationError.map(error)
        }
    }

    /// Validates and normalizes the draft before invoking submit; `RequestStore`
    /// retains lifecycle and duplicate-operation authority.
    static func orchestrateSubmission(
        draft: RequestFoodFormDraft,
        now: Date,
        calendar: Calendar,
        presentation: RequestFoodValidationPresentation,
        submission: (CreateRequestPayload) async throws -> Void
    ) async throws -> RequestFoodSubmissionResult {
        let scheduledWindowIsValid = isValidScheduledWindow(
            startingAt: draft.preferredPickupTime,
            now: now,
            calendar: calendar
        )
        let errors = RequestFoodFormValidator.validate(
            selectedDiningSpot: draft.selectedDiningSpot,
            foodRequest: draft.foodRequest,
            pickupName: draft.pickupName,
            email: draft.email,
            timing: draft.timing,
            isScheduledWindowValid: scheduledWindowIsValid,
            // Same `now` as the window check above: one snapshot decides both
            // halves of this submission, so they cannot disagree.
            isScheduledTimingAvailable: isScheduledTimingAvailable(
                now: now,
                calendar: calendar
            )
        )
        var updatedPresentation = presentation
        updatedPresentation.presentAll(errors)

        guard errors.isEmpty else {
            return RequestFoodSubmissionResult(
                presentation: updatedPresentation,
                firstInvalidTextField: errors.first { $0.field.isTextField }?.field,
                didSubmit: false
            )
        }

        let payload = try makePayload(
            selectedDiningSpot: draft.selectedDiningSpot,
            foodRequest: draft.foodRequest,
            pickupName: draft.pickupName,
            email: draft.email,
            timing: draft.timing,
            preferredPickupTime: draft.preferredPickupTime,
            now: now,
            calendar: calendar
        )
        try await submission(payload)
        return RequestFoodSubmissionResult(
            presentation: updatedPresentation,
            firstInvalidTextField: nil,
            didSubmit: true
        )
    }

    /// Every caller passes the snapshot it is already reasoning about — the
    /// render's `now`, or the focus transition's — so availability, validity,
    /// and what is drawn are all answers about the same instant.
    private func validationErrors(now: Date) -> [RequestFoodFieldError] {
        RequestFoodFormValidator.validate(
            selectedDiningSpot: draft.selectedDiningSpot,
            foodRequest: draft.foodRequest,
            pickupName: draft.pickupName,
            email: draft.email,
            timing: draft.timing,
            isScheduledWindowValid: Self.isValidScheduledWindow(
                startingAt: draft.preferredPickupTime,
                now: now,
                calendar: calendar
            ),
            isScheduledTimingAvailable: Self.isScheduledTimingAvailable(
                now: now,
                calendar: calendar
            )
        )
    }

    private func fieldError(
        _ field: RequestFoodFormField,
        errors: [RequestFoodFieldError]
    ) -> String? {
        validationPresentation.visibleError(for: field, from: errors)?.message
    }

    @ViewBuilder
    private func fieldErrorText(
        _ field: RequestFoodFormField,
        errors: [RequestFoodFieldError],
        identifier: String
    ) -> some View {
        if let message = fieldError(field, errors: errors) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier(identifier)
        }
    }

    /// Success-screen expiration copy for the timing the backend confirmed.
    static func expirationNotice(for timing: RequestTiming) -> String {
        switch timing {
        case .asap:
            return asapExpirationNotice
        case .later:
            return scheduledExpirationNotice
        }
    }

    static func formExpirationNotice(for timing: RequestTiming) -> String {
        switch timing {
        case .asap:
            return "An ASAP request expires 5 hours after you post it."
        case .later:
            return "A scheduled request expires when the pickup window ends."
        }
    }

    /// An ambiguous create is the only state that gets an escape action. The
    /// POST may already have succeeded, so submission stays disabled and no
    /// retry is offered — leaving is the only safe move. Confirmed backend
    /// rejections are recoverable in place and must not receive it.
    static func showsReturnHomeAction(
        for error: RequestCreatePresentationError?
    ) -> Bool {
        error == .ambiguous
    }

    /// The plain "reopen tomorrow" footnote is suppressed exactly when the
    /// lapsed-Later error is visible, because that error already states it and
    /// then adds the correction. It still renders for an ASAP draft, where it is
    /// the only explanation of why `Later` is missing from the picker.
    static func showsScheduledUnavailableNotice(
        isScheduledTimingAvailable: Bool,
        visibleScheduleError: RequestFoodFormError?
    ) -> Bool {
        !isScheduledTimingAvailable && visibleScheduleError != .scheduledTimingUnavailable
    }

    /// A local rejection that moved focus has already answered the tap. One that
    /// could not — every remaining error belongs to a picker — needs a line the
    /// requester can see without hunting up a form they may be scrolled past.
    static func showsLocalRejectionPointer(for result: RequestFoodSubmissionResult) -> Bool {
        !result.didSubmit && result.firstInvalidTextField == nil
    }

    /// The render-time rule. The pointer is local-only, so a backend answer
    /// always wins the section.
    static func showsLocalRejectionPointer(
        isPresenting: Bool,
        submissionError: RequestCreatePresentationError?
    ) -> Bool {
        isPresenting && submissionError == nil
    }

    static func submissionSectionPresentation(
        for error: RequestCreatePresentationError?
    ) -> RequestSubmissionSectionPresentation? {
        guard let error else { return nil }
        return RequestSubmissionSectionPresentation(
            error: error,
            message: error.message,
            showsReturnHomeAction: showsReturnHomeAction(for: error)
        )
    }

    /// Submission stays disabled after an ambiguous outcome, so a request that
    /// may already exist cannot be posted a second time.
    static func allowsSubmission(
        after error: RequestCreatePresentationError?
    ) -> Bool {
        error != .ambiguous
    }

    /// Whether entering the screen should start an availability probe.
    ///
    /// A blocked screen has no use for the answer: `presentation` returns the
    /// blocked state regardless of what comes back, so probing would spend a
    /// request to change nothing. Skipping it also keeps the store's
    /// availability flags at whatever they already were, rather than churning
    /// them behind a screen that never reads them.
    static func shouldProbeAvailability(
        hasUnresolvedCreateAmbiguity: Bool
    ) -> Bool {
        !hasUnresolvedCreateAmbiguity
    }

    static func effectiveSubmissionError(
        hasUnresolvedCreateAmbiguity: Bool,
        submissionError: RequestCreatePresentationError?
    ) -> RequestCreatePresentationError? {
        hasUnresolvedCreateAmbiguity ? .ambiguous : submissionError
    }

    /// The request button communicates only whether every required control has
    /// a value and whether the existing lifecycle permits another attempt.
    /// Format and scheduling validity deliberately remain Submit-time checks so
    /// a completed but malformed value can reveal its adjacent error.
    static func isSubmissionEnabled(
        draft: RequestFoodFormDraft,
        submissionError: RequestCreatePresentationError?,
        isCreating: Bool
    ) -> Bool {
        guard !isCreating, allowsSubmission(after: submissionError) else {
            return false
        }
        return RequestFoodFormValidator.hasRequiredInput(draft)
    }

    /// Scheduling is possible only while a full 30-minute window still fits
    /// before the next calendar-day boundary. Both the boundary and the
    /// 30-minute addition come from `Calendar`, never raw second arithmetic.
    static func isScheduledTimingAvailable(now: Date, calendar: Calendar) -> Bool {
        isValidScheduledWindow(startingAt: now, now: now, calendar: calendar)
    }

    /// The timings the picker may offer. "Later" is withheld entirely rather
    /// than presented as an unusable date picker.
    static func availableTimingOptions(
        now: Date,
        calendar: Calendar
    ) -> [RequestTiming] {
        isScheduledTimingAvailable(now: now, calendar: calendar)
            ? RequestTiming.allCases
            : [.asap]
    }

    static func makePayload(
        selectedDiningSpot: DiningSpot?,
        foodRequest: String,
        pickupName: String,
        email: String,
        timing: RequestTiming,
        preferredPickupTime: Date,
        now: Date,
        calendar: Calendar
    ) throws -> CreateRequestPayload {
        let scheduledWindowIsValid = isValidScheduledWindow(
            startingAt: preferredPickupTime,
            now: now,
            calendar: calendar
        )
        let errors = RequestFoodFormValidator.validate(
            selectedDiningSpot: selectedDiningSpot,
            foodRequest: foodRequest,
            pickupName: pickupName,
            email: email,
            timing: timing,
            isScheduledWindowValid: scheduledWindowIsValid,
            isScheduledTimingAvailable: isScheduledTimingAvailable(
                now: now,
                calendar: calendar
            )
        )
        if let firstError = errors.first {
            throw firstError.error
        }
        guard let selectedDiningSpot else {
            throw RequestFoodFormError.missingDiningSpot
        }

        let trimmedVendor = selectedDiningSpot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFood = foodRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPickupName = pickupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

        switch timing {
        case .asap:
            return CreateRequestPayload(
                vendor: trimmedVendor,
                food: trimmedFood,
                pickupName: trimmedPickupName,
                email: trimmedEmail,
                timing: .asap,
                windowStart: nil,
                windowEnd: nil
            )
        case .later:
            guard let windowEnd = calendar.date(
                byAdding: .minute,
                value: 30,
                to: preferredPickupTime
            ) else {
                throw RequestFoodFormError.invalidScheduledTime
            }

            return CreateRequestPayload(
                vendor: trimmedVendor,
                food: trimmedFood,
                pickupName: trimmedPickupName,
                email: trimmedEmail,
                timing: .scheduled,
                windowStart: preferredPickupTime,
                windowEnd: windowEnd
            )
        }
    }

    static func endOfDay(containing date: Date, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
    }

    static func latestScheduledStart(on date: Date, calendar: Calendar) -> Date? {
        guard let endOfDay = endOfDay(containing: date, calendar: calendar) else {
            return nil
        }
        return calendar.date(byAdding: .minute, value: -30, to: endOfDay)
    }

    static func isValidScheduledWindow(
        startingAt start: Date,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard start >= now,
              let end = calendar.date(byAdding: .minute, value: 30, to: start),
              end > start,
              let dayEnd = endOfDay(containing: now, calendar: calendar) else {
            return false
        }
        return end <= dayEnd
    }

    static func isValidEmail(_ value: String) -> Bool {
        RequestFoodFormValidator.isValidEmail(value)
    }
}
