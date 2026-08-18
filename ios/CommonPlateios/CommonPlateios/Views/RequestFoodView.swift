//
//  RequestFoodView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import PhotosUI
import SwiftUI
import UIKit

/// One locally-prepared screenshot ready for analysis: the normalized image
/// bytes plus the independent on-device Vision OCR text
/// (`ScreenshotLocalTextRecognizer`) that gates and corroborates whatever
/// the OpenAI provider later returns for it.
struct ScreenshotAnalysisInput {
    let data: Data
    let mimeType: String
    let localEvidenceText: String
}

enum RequestFoodFormError: Error, Equatable {
    case missingDiningSpot
    case missingFood
    case missingPickupName
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
        case .invalidScheduledTime:
            return "Choose a pickup time later today."
        case .scheduledTimingUnavailable:
            return RequestFoodView.lapsedScheduledTimingNotice
        }
    }
}

enum RequestCreatePresentationError: Equatable {
    case invalidRequest
    /// `PARTICIPANT_VERIFICATION_REQUIRED`. Reachable only if the gate and this
    /// screen disagree about whether this installation is verified — the form
    /// asks for verification before submitting — so it says the same thing the
    /// gate does rather than inventing a second explanation.
    case verificationRequired
    /// `PARTICIPANT_AUTHORITY_INVALID`. The stored identity has been discarded
    /// by the time this renders, so the correction is to verify again.
    case verificationExpired
    /// `PARTICIPANT_VERIFICATION_UNAVAILABLE`. The backend could not check.
    /// Never presented as "you are not verified", because it does not say that.
    case verificationUnavailable
    /// `PARTICIPANT_PRINCIPAL_MISMATCH`. This app never sends an address, so
    /// this is a build/contract disagreement rather than anything the student
    /// typed; it is still recoverable by verifying the address they want.
    case principalMismatch
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
        case .verificationRequired:
            return "Verify your NYU email to post a request."
        case .verificationExpired, .principalMismatch:
            return "Your NYU email needs to be verified again before posting."
        case .verificationUnavailable:
            return "We couldn’t check your NYU verification. Please try again in a moment."
        case .requestLimitReached:
            // Under the revised W3-R1 presentation contract, the daily quota is
            // not advertised on the ordinary form — only this actual-limit
            // recovery sentence, reached solely by a real backend refusal.
            return RequestFoodView.postingLimitReachedNotice
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
            case ParticipantErrorCode.verificationRequired:
                return .verificationRequired
            case ParticipantErrorCode.authorityInvalid:
                return .verificationExpired
            case ParticipantErrorCode.verificationUnavailable:
                return .verificationUnavailable
            case ParticipantErrorCode.principalMismatch:
                return .principalMismatch
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

    /// Shown when the backend answers `REQUEST_LIMIT_REACHED`. Names the reset
    /// the requester is actually waiting for — campus midnight, not the
    /// device's — rather than a vague "tomorrow", and never describes the
    /// refusal in API terms, which is not what happened and not something a
    /// student can act on.
    static let postingLimitReachedNotice =
        "Daily request limit reached. Try again after midnight Eastern Time."

    /// Shown beneath the single scheduled-time control, which collects only a
    /// start; the end is derived by the backend. The student would otherwise
    /// have no way to know when helpers actually see this, or for how long.
    static let scheduledWindowNotice =
        "Helpers will start seeing this request at this time, and for 3 hours after it."

    /// Shown once no start is left inside the current campus day. Scheduling is
    /// withheld rather than offered as an unusable picker; tomorrow scheduling
    /// is not part of this flow.
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

    @ObservedObject var store: RequestStore
    /// The one W4-S1 state owner for AI screenshot proposals. Entirely
    /// separate from `store`: it never calls `store.createRequest(...)` and
    /// only ever mutates `draft` through the manual-precedence-aware
    /// application this screen calls below.
    @ObservedObject var screenshotProposalStore: ScreenshotProposalStore
    /// Observed, not owned: the verified identity outlives this screen, and the
    /// gate below has to see the same one every other participant action does.
    @ObservedObject var identityStore: ParticipantIdentityStore
    /// Shared production owner for the exact draft/operation continuation.
    /// This view reports lifecycle events; it does not keep a parallel pending
    /// intent in private SwiftUI state.
    @ObservedObject var verificationCoordinator:
        ParticipantActionVerificationCoordinator
    /// The destination that owns this form. Continuation consumption checks it
    /// so navigation replacement (including notification routing) cannot let a
    /// still-mounted stale form post after verification.
    @Binding var path: [AppRoute]
    let onExit: () -> Void

    @State private var draft = RequestFoodFormDraft()
    @State private var validationPresentation = RequestFoodValidationPresentation()
    @State private var submissionError: RequestCreatePresentationError?
    /// Set only by a local rejection that had no text field to focus. Backend
    /// failures never set it — they own `submissionError`, which is the
    /// authoritative message for anything the server decided.
    @State private var showsLocalRejectionPointer = false
    @State private var didCreateRequest = false
    @FocusState private var focusedField: RequestFoodFormField?

    // MARK: - W4-S1 AI screenshot assistance

    @State private var selectedScreenshotItem: PhotosPickerItem?
    /// A normalized image, plus its independently-derived local OCR evidence
    /// text, already picked and awaiting the first-use disclosure decision.
    /// Discarded (never sent) on Cancel, on a newer selection superseding it,
    /// or on leaving this screen.
    @State private var pendingScreenshotForConsent: ScreenshotAnalysisInput?
    /// The selection `pendingScreenshotForConsent` belongs to. Checked
    /// against `screenshotProposalStore.isCurrent(_:)` before the disclosure
    /// decision is ever acted on, so a stale sheet left open behind a newer
    /// selection cannot start analysis for a screenshot the requester has
    /// already replaced.
    @State private var pendingConsentToken: ScreenshotSelectionToken?
    @State private var isPresentingScreenshotDisclosure = false
    /// Explicit requester-interaction provenance for the three allowlisted
    /// proposal fields (see `ScreenshotFieldManualEditState`'s declaration).
    /// Set only by this screen's three custom bindings below — never by a
    /// store-applied proposal write — and never reset for the lifetime of
    /// this view.
    @State private var screenshotManualEdits = ScreenshotFieldManualEditState()

    /// Campus time, not device time. Every day boundary, every clamp, and the
    /// picker itself are computed here, so the same selection means the same
    /// New York instant on a phone in Brooklyn and one in Berkeley.
    private var calendar: Calendar {
        NYUCampusTime.calendar
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

    let diningSpots = SupportedVendorCatalog.diningSpots

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
        // Campus time for everything this screen draws and reads, including the
        // scheduled-start picker. Without these, a phone left on another
        // timezone would offer and display its own wall clock while the backend
        // interpreted the resulting instant as New York — the requester would
        // pick 6 PM and helpers would see a different hour.
        .environment(\.timeZone, NYUCampusTime.timeZone)
        .environment(\.calendar, NYUCampusTime.calendar)
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
        // A sheet, not a push: this screen stays mounted underneath, so the
        // draft it holds is still there when verification finishes — and still
        // there when it does not.
        .sheet(isPresented: isPresentingVerification) {
            ParticipantVerificationView(
                store: identityStore,
                cancel: verificationCoordinator.requesterCancelled
            )
        }
        .onChange(of: identityStore.identity) { previous, current in
            guard case .requestCreation(let submittedDraft)? =
                    verificationCoordinator.requesterIdentityDidChange(
                        from: previous,
                        to: current,
                        path: path
                    ) else {
                return
            }
            // The coordinator cleared both continuation owners before
            // returning this exact snapshot, so no duplicate publication can
            // enqueue another create.
            Task { await submit(draftSnapshot: submittedDraft) }
        }
        .onChange(of: path) { _, currentPath in
            verificationCoordinator.requesterNavigationChanged(path: currentPath)
        }
        .onDisappear {
            verificationCoordinator.requesterDisappeared()
            // Review finding: old work must be invalidated on disappearance,
            // not just superseded by a later selection — otherwise a
            // still-running analysis for a screen the requester has already
            // left could still be applied if this exact view instance were
            // ever reused.
            screenshotProposalStore.invalidateCurrentSelection()
        }
        .onChange(of: selectedScreenshotItem) { _, newItem in
            guard let newItem else { return }
            // A newer selection immediately supersedes anything the previous
            // one was doing, including a still-open disclosure sheet for it.
            isPresentingScreenshotDisclosure = false
            pendingScreenshotForConsent = nil
            pendingConsentToken = nil
            // Minted synchronously, here, before any async work for this
            // selection starts — "last selection wins from the moment the
            // requester chooses it," not from whenever its preprocessing
            // happens to finish.
            let token = screenshotProposalStore.beginSelection(
                clearing: &draft,
                manualEdits: screenshotManualEdits
            )
            Task { await processSelectedScreenshot(newItem, token: token) }
        }
        .sheet(isPresented: $isPresentingScreenshotDisclosure) {
            ScreenshotProposalDisclosureView(
                onContinue: acceptScreenshotDisclosure,
                onCancel: cancelScreenshotDisclosure
            )
        }
    }

    // MARK: - W4-S1 AI screenshot assistance

    @ViewBuilder
    private var screenshotAssistanceRow: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
            // `.images`, not `.screenshots`: a genuine Grubhub screenshot
            // saved via AirDrop/Files/a share sheet loses the OS's own
            // screenshot tag, and the deterministic eligibility gate
            // (`screenshotEligibility.ts`) — not this filter — is what
            // actually decides whether the selected image is a supported
            // category.
            PhotosPicker(
                selection: $selectedScreenshotItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                if screenshotProposalStore.isApplying {
                    HStack {
                        ProgressView()
                        Text("Analyzing screenshot…")
                    }
                } else {
                    Text("Add from Grubhub screenshot")
                }
            }
            .disabled(!screenshotProposalStore.isAIAssistanceEnabled || screenshotProposalStore.isApplying)
            .accessibilityIdentifier("request-screenshot-picker")

            if !screenshotProposalStore.isAIAssistanceEnabled {
                Text("AI screenshot assistance is off. Turn it on in Settings, or fill out the form manually.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("request-screenshot-disabled-notice")
            } else if let notice = screenshotProposalStore.notice {
                Text(notice.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("request-screenshot-notice")
            } else {
                Text("Optional. Manual entry always works, whether or not you use this.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Local normalization (resize/compress) plus independent on-device
    /// Vision OCR — no network call yet, and both run before any disclosure
    /// or transmission decision. OCR runs against the original selected
    /// image (before compression) for the best recognition fidelity; the
    /// evidence text is what actually gates and corroborates analysis, not
    /// the image bytes.
    ///
    /// Every stage below re-checks `screenshotProposalStore.isCurrent(token)`
    /// and `.isAIAssistanceEnabled` before proceeding: a newer selection or
    /// AI Assistance being turned Off at any point must stop this exact
    /// attempt from reaching the next stage, and in particular must make
    /// network transfer for it impossible.
    @MainActor
    private func processSelectedScreenshot(
        _ item: PhotosPickerItem,
        token: ScreenshotSelectionToken
    ) async {
        selectedScreenshotItem = nil

        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        guard screenshotProposalStore.isCurrent(token), screenshotProposalStore.isAIAssistanceEnabled else {
            return
        }

        guard let uiImage = UIImage(data: data),
              let normalized = ScreenshotImageNormalizer.normalize(uiImage) else {
            return
        }
        guard screenshotProposalStore.isCurrent(token), screenshotProposalStore.isAIAssistanceEnabled else {
            return
        }

        let evidenceText = await ScreenshotLocalTextRecognizer.recognizeText(in: uiImage)
        guard screenshotProposalStore.isCurrent(token), screenshotProposalStore.isAIAssistanceEnabled else {
            return
        }

        let input = ScreenshotAnalysisInput(
            data: normalized.data,
            mimeType: normalized.mimeType,
            localEvidenceText: evidenceText
        )

        if screenshotProposalStore.hasRecordedThirdPartyConsent {
            await beginScreenshotAnalysis(input, token: token)
        } else {
            pendingScreenshotForConsent = input
            pendingConsentToken = token
            isPresentingScreenshotDisclosure = true
        }
    }

    private func acceptScreenshotDisclosure() {
        isPresentingScreenshotDisclosure = false
        guard let pending = pendingScreenshotForConsent, let token = pendingConsentToken else {
            return
        }
        pendingScreenshotForConsent = nil
        pendingConsentToken = nil
        // The disclosure sheet can only be showing for the current
        // selection (a newer one clears it on appearance, above), but this
        // still checks explicitly rather than assuming that invariant holds
        // forever.
        guard screenshotProposalStore.isCurrent(token) else { return }
        screenshotProposalStore.recordThirdPartyConsent()
        Task { await beginScreenshotAnalysis(pending, token: token) }
    }

    private func cancelScreenshotDisclosure() {
        isPresentingScreenshotDisclosure = false
        pendingScreenshotForConsent = nil
        pendingConsentToken = nil
    }

    @MainActor
    private func beginScreenshotAnalysis(
        _ input: ScreenshotAnalysisInput,
        token: ScreenshotSelectionToken
    ) async {
        let outcome = await screenshotProposalStore.analyzeScreenshot(
            imageData: input.data,
            mimeType: input.mimeType,
            localEvidenceText: input.localEvidenceText,
            participantAuthority: identityStore.currentAuthority(),
            token: token
        )
        // Applied synchronously, after the suspension point above: a
        // `@State` draft cannot be passed `inout` across an `await`, so the
        // outcome returns here and is applied in one non-suspending step.
        // Re-checked again here (not just inside `analyzeScreenshot`): the
        // gap between that call returning and this line running is itself a
        // point where a newer selection could have started.
        guard let outcome, screenshotProposalStore.isCurrent(token) else { return }
        screenshotProposalStore.apply(
            outcome,
            manualEdits: screenshotManualEdits,
            to: &draft
        )
    }

    /// The only path that may set `screenshotManualEdits.hasManuallyEditedMealSwipes`
    /// — latches on genuine user interaction with the picker, including
    /// reselecting the same value, and never on a store-applied proposal
    /// write (which mutates `draft.mealSwipes` directly).
    private var mealSwipesBinding: Binding<Int> {
        Binding(
            get: { draft.mealSwipes },
            set: { newValue in
                draft.mealSwipes = newValue
                screenshotManualEdits.hasManuallyEditedMealSwipes = true
            }
        )
    }

    /// The only path that may set
    /// `screenshotManualEdits.hasManuallyEditedLocation` — latches on any
    /// real picker interaction, including selecting `nil` ("Select a spot")
    /// to manually clear an AI-proposed location. A store-applied proposal
    /// write never goes through this binding.
    private var selectedDiningSpotBinding: Binding<DiningSpot?> {
        Binding(
            get: { draft.selectedDiningSpot },
            set: { newValue in
                draft.selectedDiningSpot = newValue
                screenshotManualEdits.hasManuallyEditedLocation = true
            }
        )
    }

    /// The only path that may set
    /// `screenshotManualEdits.hasManuallyEditedFoodRequest` — latches on the
    /// first keystroke and stays latched even if the requester later clears
    /// the field back to empty, so a subsequent AI proposal can never
    /// silently regain ownership just because the text happens to be empty
    /// again.
    private var foodRequestBinding: Binding<String> {
        Binding(
            get: { draft.foodRequest },
            set: { newValue in
                draft.foodRequest = newValue
                screenshotManualEdits.hasManuallyEditedFoodRequest = true
            }
        )
    }

    /// The sheet is open exactly while the identity store has a flow running.
    /// Read-only from this screen's side — dismissing it goes through
    /// `cancelVerification()`, so an abandoned flow is abandoned in one place.
    private var isPresentingVerification: Binding<Bool> {
        Binding(
            get: { verificationCoordinator.isPresentingRequestCreationVerification },
            set: { isPresented in
                if !isPresented {
                    verificationCoordinator.requesterSheetDismissed()
                }
            }
        )
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
                        onExit()
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

            Button("Back to Home") {
                onExit()
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
                screenshotAssistanceRow

                // A custom binding, not `$draft.selectedDiningSpot` directly
                // — see `selectedDiningSpotBinding`'s declaration.
                Picker("NYU dining spot", selection: selectedDiningSpotBinding) {
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

                // A custom binding, not `$draft.foodRequest` directly — see
                // `foodRequestBinding`'s declaration.
                TextField("What do you want?", text: foodRequestBinding, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
                    .focused($focusedField, equals: .foodDescription)
                    .accessibilityHint(Text(fieldError(.foodDescription, errors: errors) ?? ""))

                fieldErrorText(
                    .foodDescription,
                    errors: errors,
                    identifier: "request-food-error"
                )

                // V1 meal-swipe requirement (W3-C1): meal swipes only, no
                // Dining Dollars. A bounded picker, not free-form entry, so
                // this app can never submit a value the backend would refuse.
                // A custom binding, not `$draft.mealSwipes` directly, so
                // `screenshotManualEdits.hasManuallyEditedMealSwipes` latches
                // on genuine user interaction only — never on an AI-applied
                // write, which mutates `draft` directly rather than through
                // this binding.
                Picker("Meal swipes needed", selection: mealSwipesBinding) {
                    ForEach(RequestFoodFormDraft.mealSwipeOptions, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .accessibilityIdentifier("request-meal-swipes-picker")

                Text("Choose how many meal swipes your Grubhub order requires.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Pickup") {
                TextField("Pickup name", text: $draft.pickupName)
                    .focused($focusedField, equals: .pickupName)
                    .accessibilityHint(Text(fieldError(.pickupName, errors: errors) ?? ""))

                Text("Enter the name you want the Grubhub order placed under.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                fieldErrorText(
                    .pickupName,
                    errors: errors,
                    identifier: "request-pickup-name-error"
                )

                // Only the timings that still have a selectable start are
                // offered, so "Later" cannot be selected when it is
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

                // The three-hour rule is explained once at this timing choice.
                // A `Later` draft already reads it, tied to the concrete start
                // it chose, in `scheduledWindowNotice` above; restating the
                // generic form here would say the same thing twice on one
                // screen. An `ASAP` draft has no picked start to attach it to,
                // so this is that draft's only occurrence of the rule.
                if draft.timing == .asap {
                    Text(Self.formExpirationNotice(for: draft.timing))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("request-form-expiration")
                }
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
                            onExit()
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
    private func submit(draftSnapshot: RequestFoodFormDraft? = nil) async {
        submissionError = nil
        showsLocalRejectionPointer = false

        let submittedDraft = draftSnapshot ?? draft

        // The gate, and the whole reason it lives here rather than in the
        // store: `draft` is `@State` on a screen that stays mounted behind the
        // verification sheet, so the completed request survives verification by
        // construction. Nothing is submitted, cleared, or reset on the way in
        // or the way out — a failed, expired, abandoned, or ambiguous
        // verification simply returns to the same filled form.
        if !identityStore.isVerified {
            _ = verificationCoordinator.beginRequestCreation(
                draft: submittedDraft,
                path: path
            )
            return
        }

        let now = Date()
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
            timing: draft.timing,
            preferredPickupTime: draft.preferredPickupTime,
            mealSwipes: draft.mealSwipes,
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

    static func formExpirationNotice(for timing: RequestTiming) -> String {
        switch timing {
        case .asap:
            return "An ASAP request expires 3 hours after you post it."
        case .later:
            return "A scheduled request expires 3 hours after the time you choose."
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

    /// Scheduling is possible only while a selectable start remains inside the
    /// current campus day. Both the day boundary and the cutoff come from
    /// `Calendar`, never raw second arithmetic, so the rule stays correct
    /// across a DST transition instead of being 23 or 25 hours wrong.
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
        timing: RequestTiming,
        preferredPickupTime: Date,
        mealSwipes: Int,
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

        switch timing {
        case .asap:
            return CreateRequestPayload(
                vendor: trimmedVendor,
                food: trimmedFood,
                pickupName: trimmedPickupName,
                timing: .asap,
                windowStart: nil,
                mealSwipes: mealSwipes
            )
        case .later:
            // Only the start. The end of a request's availability is derived
            // from it by the backend (`src/requestTiming.ts`), and the create
            // shape is strict, so sending an end would both be refused and
            // claim authority this app does not have.
            return CreateRequestPayload(
                vendor: trimmedVendor,
                food: trimmedFood,
                pickupName: trimmedPickupName,
                timing: .scheduled,
                windowStart: preferredPickupTime,
                mealSwipes: mealSwipes
            )
        }
    }

    /// How far before the next campus-day boundary the last selectable start
    /// sits.
    ///
    /// Deliberately unchanged from the value accepted before W3-R1, when a
    /// selection meant a 30-minute pickup window, so `scheduledTimingUnavailable`
    /// and its recovery path still open and close at exactly the instants they
    /// always have. Under the current contract this is a same-day scheduling
    /// horizon and not a window length: availability runs three hours from the
    /// chosen start and may cross midnight. Moving it is a product decision,
    /// not a consequence of the timing change.
    static let scheduledStartCutoffMinutesBeforeDayEnd = 30

    static func endOfDay(containing date: Date, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
    }

    static func latestScheduledStart(on date: Date, calendar: Calendar) -> Date? {
        guard let endOfDay = endOfDay(containing: date, calendar: calendar) else {
            return nil
        }
        return calendar.date(
            byAdding: .minute,
            value: -scheduledStartCutoffMinutesBeforeDayEnd,
            to: endOfDay
        )
    }

    /// Whether this start may still be selected: it has not already passed, and
    /// it falls on or before the last start of the current campus day.
    ///
    /// This decides what the picker offers and what Submit accepts. It is not a
    /// lifecycle rule — the backend decides when a request is actually visible
    /// and when it expires, from its own clock.
    static func isValidScheduledWindow(
        startingAt start: Date,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard start >= now,
              let latestStart = latestScheduledStart(on: now, calendar: calendar) else {
            return false
        }
        return start <= latestStart
    }
}
