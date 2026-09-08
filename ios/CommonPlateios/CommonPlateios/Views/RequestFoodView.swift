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

/// W4-R2 2026-08-31 device/prototype sync: whether the newest completed
/// screenshot analysis was eligible, shown as the compact `✓ Screenshot
/// checked` result row. This supersedes the withdrawn item-21 three-outcome
/// explanatory copy — the row no longer distinguishes which of S1's outcomes
/// occurred, only that a completed analysis exists to show/replace with
/// `Change`.

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
    /// W4-R2: the requester tapped Submit and an authoritative answer is
    /// pending. Centered, one native indeterminate progress owner, no
    /// percentage and no haptic — the requester cannot yet know whether this
    /// will end in `.success` or a definitive failure.
    case posting
    /// W4-R2 D1: a durable unresolved create operation from a previous
    /// attempt (this session or a relaunch) is actively being reconciled
    /// against authoritative backend truth. Distinct from
    /// `.blockedByUnresolvedCreateAmbiguity`, which is the same ambiguity
    /// already resolved as still-unresolved: this state always has an answer
    /// coming, and neither success nor error semantics apply while it is
    /// pending.
    case checkingCreateAmbiguity
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
    /// Process/session-only draft state owned above this transient route.
    /// RequestStore remains the sole create/D1 authority.
    @ObservedObject var draftSession: RequestFoodDraftSession
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

    @State private var validationPresentation = RequestFoodValidationPresentation()
    @State private var submissionError: RequestCreatePresentationError?
    /// Set only by a local rejection that had no text field to focus. Backend
    /// failures never set it — they own `submissionError`, which is the
    /// authoritative message for anything the server decided.
    @State private var showsLocalRejectionPointer = false
    @State private var didCreateRequest = false
    /// Fences the semantic Success acknowledgement if SwiftUI re-evaluates
    /// the success task while this destination remains mounted.
    @State private var hasAcknowledgedSuccess = false
    /// W4-R2 definitive-failure presentation: true only while the centered
    /// `SAVED DRAFT` / `Review draft` failure state (rather than the ordinary
    /// editable form) is showing. Never true for D1 ambiguity, which has its
    /// own dedicated presentation, or for local field-validation rejections,
    /// which stay inline on the still-visible form.
    @State private var isShowingFailureSummary = false
    @FocusState private var focusedField: RequestFoodFormField?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Independent-review fix: `.frame(maxHeight:)` alone does not behave as
    /// a passive "shrink to content, capped" constraint here — confirmed by
    /// a direct `UIHostingController` layout diagnostic against this exact
    /// wrapper chain (`.frame(width: 314).frame(maxHeight: 480)`), which
    /// showed even trivial one-line content forced to the full 480pt: this
    /// flexible frame expands to fill whatever it is proposed (screen
    /// height, since the enclosing `ZStack` ignores the safe area) up to its
    /// max, rather than reporting the child's own smaller natural size. That
    /// is the true, physically-confirmed cause of the persistent dead space
    /// below `Got it` — not anything inside `ScreenshotHelpView`, which was
    /// re-verified (with the same diagnostic) to correctly hug its own
    /// content to ~420pt once nothing forces it wider. The height cap is
    /// therefore applied only when content can actually need it —
    /// accessibility Dynamic Type sizes, where `ScreenshotHelpView`'s own
    /// internal `ScrollView` fallback also engages — and omitted entirely at
    /// ordinary sizes, letting the modal hug its true content height.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // MARK: - W4-S1 AI screenshot assistance

    @State private var selectedScreenshotItem: PhotosPickerItem?
    /// W4-R2 2026-09-01 sync: the required remote-AI disclosure now gates
    /// *before* photo selection, not after — see `beginScreenshotAssistanceFlow()`.
    /// There is therefore no pending-selection-awaiting-consent state to hold
    /// anymore: nothing has been picked yet at the point disclosure shows.
    /// W4-R2 2026-09-01 round-2 sync: owned as a `Binding` (not local
    /// `@State`), matching `isPresentingScreenshotHelp` below, so
    /// `RequestFoodEntryView` can also suppress its toolbar Back button while
    /// this centered overlay owns input — the same competing-Back-control
    /// concern that binding's declaration already explains.
    @Binding var isPresentingScreenshotDisclosure: Bool
    /// W4-R2 2026-09-01 sync: presents the system photo picker only once
    /// disclosure (if needed) and Screenshot Help (if needed) are satisfied —
    /// `beginScreenshotAssistanceFlow()` is the only place that sets this
    /// `true`. Programmatic (`.photosPicker(isPresented:)`), not a direct
    /// `PhotosPicker` link, so the row's tap can run that gating decision
    /// first.
    @State private var isPresentingScreenshotPicker = false
    /// W4-R2 Screenshot Help (`What should I screenshot?`): one local
    /// centered overlay, independent of the disclosure/consent sheet above.
    /// Owned as a `Binding` (not local `@State`) so `RequestFoodEntryView`
    /// can suppress its own toolbar Back button while this overlay owns
    /// input — a competing, still-functional underlying Back control was the
    /// exact walkthrough finding this closes: leaving it merely disabled
    /// would still be the "decorative/nonfunctional Back" item 9 already
    /// prohibits, so the entry screen removes it from the toolbar entirely
    /// instead.
    @Binding var isPresentingScreenshotHelp: Bool
    /// W4-R2 2026-08-31 round-2 sync: true exactly while `presentation` is
    /// `.posting` or `.success`, so `RequestFoodEntryView` can remove its
    /// Back control for the transient submission sequence — no alternative
    /// cancel/dismiss action replaces it. Owned as a binding for the same
    /// reason `isPresentingScreenshotHelp` is: the entry screen, not this
    /// view, owns the toolbar Back item.
    @Binding var isSuppressingBackNavigation: Bool
    /// Prototype C exact-time selection. The sheet owns only presentation;
    /// the selected value continues to live in the same `draft` as quick-time
    /// choices and request creation.
    @State private var isPresentingExactTimePicker = false
    /// W4-R2 2026-09-02 sync: the on-demand `How timing works` explanation.
    /// Purely local presentation state — opening/dismissing it never touches
    /// `draft`.
    @State private var isPresentingTimingInfo = false
    /// W4-R2 motion: exactly the fields `apply(...)` just changed, shown with
    /// a brief restrained afterglow and cleared shortly after — never a
    /// sequential/typing animation and never a haptic (S1 proposals get no
    /// haptic at all).
    @State private var screenshotAfterglowFields = ScreenshotProposalAppliedFields()
    /// W4-R2 2026-08-31 sync: whether the newest analysis for the current
    /// selection completed and was eligible. Reset when a new selection
    /// begins (`Change`/a fresh pick), so the compact result row only ever
    /// reflects the current selection's own outcome.
    @State private var screenshotChecked = false

    /// Short aliases keep the existing field/submission code operating on the
    /// shared owner without introducing a second local copy.
    private var draft: RequestFoodFormDraft {
        get { draftSession.draft }
        nonmutating set { draftSession.draft = newValue }
    }

    /// Explicit requester-interaction provenance for the three allowlisted
    /// proposal fields (see `ScreenshotFieldManualEditState`'s declaration).
    /// Set only by this screen's three custom bindings below — never by a
    /// store-applied proposal write — and retained with the process draft.
    private var screenshotManualEdits: ScreenshotFieldManualEditState {
        get { draftSession.screenshotManualEdits }
        nonmutating set { draftSession.screenshotManualEdits = newValue }
    }

    /// Which allowlisted fields currently hold an accepted screenshot value
    /// that the requester has not manually edited since. This presentation
    /// provenance is retained with the process draft across route recreation.
    private var screenshotProvenance: ScreenshotProposalAppliedFields {
        get { draftSession.screenshotProvenance }
        nonmutating set { draftSession.screenshotProvenance = newValue }
    }

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

    /// Computed once per body evaluation so both the switch below and the
    /// Posting/Success Back-suppression side effect agree on the same
    /// answer.
    private var presentation: RequestFormPresentation {
        Self.presentation(
            hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity,
            availability: store.requestCreationAvailability,
            isCheckingAvailability: store.isCheckingRequestCreationAvailability,
            hasAttemptedAvailabilityCheck: store.hasAttemptedRequestCreationAvailabilityCheck,
            didCreateRequest: didCreateRequest,
            isCreating: store.isCreating
        )
    }

    var body: some View {
        ZStack {
            Group {
                switch presentation {
                case .blockedByUnresolvedCreateAmbiguity:
                    blockedByAmbiguityView
                case .checkingCreateAmbiguity:
                    checkingCreateAmbiguityView
                case .posting:
                    postingView
                case .success:
                    successView
                case .checkingAvailability:
                    availabilityCheckView
                case .unavailable(let message, let retryable):
                    unavailableView(message: message, retryable: retryable)
                case .form:
                    if isShowingFailureSummary, let error = effectiveSubmissionError {
                        definitiveFailureView(error: error)
                    } else {
                        requestForm
                    }
                }
            }
            .accessibilityHidden(isPresentingScreenshotHelp || isPresentingScreenshotDisclosure)

            if isPresentingScreenshotHelp {
                // W4-R2 final walkthrough sync: both layers share one
                // `ignoresSafeArea()` container so the modal centers against
                // the full device screen (status bar/nav bar included), not
                // merely the safe content area beneath the pushed
                // `Request Food` navigation bar — that narrower centering
                // context was what previously read as "not actually
                // centered."
                ZStack {
                    Color.black.opacity(0.34)
                        .accessibilityHidden(true)

                    ScreenshotHelpView {
                        // W4-R2 2026-09-01 sync item 5: `Got it` — and only
                        // `Got it` — owns marking Screenshot Help completed.
                        // The overlay's only dismissal path is this closure,
                        // so mere presentation or a local detail Back can
                        // never reach here and mark it learned.
                        screenshotProposalStore.recordScreenshotHelpCompleted()
                        isPresentingScreenshotHelp = false
                        isPresentingScreenshotPicker = true
                    }
                    // Independent-review fix: `.frame(maxHeight:)` expands to
                    // fill the proposed height rather than passively capping
                    // smaller content (see `dynamicTypeSize`'s declaration).
                    // Applying it only for accessibility Dynamic Type sizes —
                    // exactly where `ScreenshotHelpView`'s own internal
                    // `ScrollView` fallback engages — lets ordinary sizes hug
                    // their true content height with no cap at all.
                    .frame(width: 314)
                    .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 480 : nil)
                    .background(
                        CommonPlateStyle.Color.baseCanvas,
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
                    .padding(.horizontal, CommonPlateStyle.Spacing.l)
                    .accessibilityIdentifier("request-screenshot-help-modal")
                    .accessibilityAddTraits(.isModal)
                }
                .ignoresSafeArea()
            }

            if isPresentingScreenshotDisclosure {
                // W4-R2 2026-09-01 round-2 sync item 4: the same centered
                // modal shell as Screenshot Help above — same outer
                // white-card width/height/position/corner radius and dimmed
                // background treatment — replacing the previous `.sheet`
                // bottom-sheet presentation.
                ZStack {
                    Color.black.opacity(0.34)
                        .accessibilityHidden(true)

                    ScreenshotProposalDisclosureView(
                        onContinue: acceptScreenshotDisclosure,
                        onCancel: cancelScreenshotDisclosure
                    )
                    .frame(width: 314)
                    .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 480 : nil)
                    .background(
                        CommonPlateStyle.Color.baseCanvas,
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
                    .padding(.horizontal, CommonPlateStyle.Spacing.l)
                    .accessibilityIdentifier("request-screenshot-disclosure-modal")
                    .accessibilityAddTraits(.isModal)
                }
                .ignoresSafeArea()
            }
        }
        .navigationTitle("Request Food")
        // W4-R2 2026-08-31 round-2 sync: keeps `isSuppressingBackNavigation`
        // in lockstep with `presentation`, including the first render
        // (`initial: true`) — a fresh instance that mounts already `.posting`
        // (e.g. restored mid-submission) must not briefly show Back before
        // this runs.
        .onChange(of: presentation, initial: true) { _, newPresentation in
            isSuppressingBackNavigation = Self.shouldSuppressBackNavigation(presentation: newPresentation)
        }
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
            // Minted synchronously, here, before any async work for this
            // selection starts — "last selection wins from the moment the
            // requester chooses it," not from whenever its preprocessing
            // happens to finish.
            let token = screenshotProposalStore.beginSelection(
                clearing: &draft,
                manualEdits: screenshotManualEdits
            )
            // Mirrors `beginSelection`'s own draft-clearing rule: a field the
            // requester has not manually edited loses its stale provenance
            // exactly when its stale AI value is cleared, never a field
            // manual ownership already covers.
            if !screenshotManualEdits.hasManuallyEditedLocation { screenshotProvenance.location = false }
            if !screenshotManualEdits.hasManuallyEditedFoodRequest { screenshotProvenance.foodRequest = false }
            if !screenshotManualEdits.hasManuallyEditedMealSwipes { screenshotProvenance.mealSwipes = false }
            screenshotAfterglowFields = ScreenshotProposalAppliedFields()
            // A fresh selection starts its own result: the prior selection's
            // `✓ Screenshot checked` row must not keep describing this new,
            // not-yet-analyzed selection.
            screenshotChecked = false
            Task { await processSelectedScreenshot(newItem, token: token) }
        }
        // W4-R2 2026-09-01 round-2 sync: the disclosure is now the local
        // centered-modal overlay above, not a `.sheet` — see
        // `isPresentingScreenshotDisclosure`'s declaration.
        // W4-R2 2026-09-01 sync: programmatic presentation so
        // `beginScreenshotAssistanceFlow()` can run the
        // disclosure/Help gating decision before the system picker ever
        // opens, rather than a direct `PhotosPicker` link opening it
        // immediately on tap.
        .photosPicker(
            isPresented: $isPresentingScreenshotPicker,
            selection: $selectedScreenshotItem,
            matching: .images,
            photoLibrary: .shared()
        )
        .sheet(isPresented: $isPresentingExactTimePicker) {
            exactTimePickerSheet
        }
    }

    // MARK: - W4-S1 AI screenshot assistance

    /// Approved Figma `Requester / Screenshot Assistance` component: a title
    /// row with `Optional`, a full-width pill action using the same
    /// request-card surface/border tokens, and — only for the Unsupported/No
    /// useful extraction outcomes — a bordered recovery-note box with the
    /// approved exact wording. Every other `ScreenshotProposalNotice` case
    /// (verification/invalid-image/unavailable) is not part of the approved
    /// component's variant set; it keeps its existing accepted message text,
    /// presented in the same recovery-note box for visual consistency only.
    @ViewBuilder
    private var screenshotAssistanceRow: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
            HStack {
                Text(Self.screenshotAssistanceTitle)
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text(
                    screenshotProposalStore.isAIAssistanceEnabled
                        ? Self.screenshotAssistanceOptionalLabel
                        : Self.screenshotAssistanceOffLabel
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // W4-R2 2026-09-01 round-2 sync item 1: Off remains a
            // discoverable, directly recoverable opt-in from Request Food
            // itself — never a disabled `Choose Grubhub screenshot` control
            // plus explanatory text.
            if !screenshotProposalStore.isAIAssistanceEnabled {
                Button {
                    beginTurnOnScreenshotAssistanceFlow()
                } label: {
                    Text(Self.turnOnScreenshotAssistanceLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, CommonPlateStyle.Spacing.m)
                        .background(
                            CommonPlateStyle.Color.requestCardSurface,
                            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                                .strokeBorder(CommonPlateStyle.Color.requestCardBorder)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("request-screenshot-turn-on")
            } else if screenshotChecked && !screenshotProposalStore.isApplying {
                // W4-R2 2026-08-31 sync: the compact completed-result row
                // replaces the initial picker affordance once analysis for
                // the current selection has finished. `Change` is the only
                // actionable element — it reopens the same picker to select
                // and analyze another screenshot.
                HStack(spacing: CommonPlateStyle.Spacing.s) {
                    Text(Self.screenshotCheckedLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        beginScreenshotAssistanceFlow()
                    } label: {
                        Text(Self.screenshotChangeLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .accessibilityIdentifier("request-screenshot-change")
                }
                .padding(.vertical, CommonPlateStyle.Spacing.m)
                .padding(.horizontal, CommonPlateStyle.Spacing.m)
                .frame(maxWidth: .infinity)
                .background(
                    CommonPlateStyle.Color.requestCardSurface,
                    in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                        .strokeBorder(CommonPlateStyle.Color.requestCardBorder)
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("request-screenshot-checked-row")
            } else {
                Button {
                    beginScreenshotAssistanceFlow()
                } label: {
                    HStack(spacing: CommonPlateStyle.Spacing.xs) {
                        if screenshotProposalStore.isApplying {
                            ProgressView()
                                .tint(Color.accentColor)
                        }
                        Text(
                            screenshotProposalStore.isApplying
                                ? Self.screenshotAnalyzingLabel
                                : Self.screenshotChooseLabel
                        )
                        .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, CommonPlateStyle.Spacing.m)
                    .background(
                        CommonPlateStyle.Color.requestCardSurface,
                        in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                            .strokeBorder(CommonPlateStyle.Color.requestCardBorder)
                    )
                }
                .buttonStyle(.plain)
                .disabled(screenshotProposalStore.isApplying)
                .accessibilityIdentifier("request-screenshot-picker")
            }

            // W4-R2 2026-09-01 sync item 1: the permanent `What should I
            // screenshot?` support row is removed — Screenshot Help now
            // appears only as automatic first-use contextual education (see
            // `beginScreenshotAssistanceFlow()`), never as a standalone
            // always-visible entry point. W4-R2 2026-09-01 round-2 sync item
            // 1: the Off state itself is handled entirely by the
            // `Turn on Screenshot Assistance` branch above — there is no
            // separate withdrawn Off notice anymore.
            if screenshotProposalStore.isAIAssistanceEnabled,
               let notice = screenshotProposalStore.notice, notice != .noUsefulExtraction {
                // `.noUsefulExtraction` is excluded: the compact `✓
                // Screenshot checked` result row above already communicates
                // that this exact eligible analysis completed, so this box
                // would otherwise duplicate that fact.
                Text(notice.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(CommonPlateStyle.Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        CommonPlateStyle.Color.requestCardSurface,
                        in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                            .strokeBorder(CommonPlateStyle.Color.requestCardBorder)
                    )
                    .accessibilityIdentifier("request-screenshot-notice")
            }

        }
    }

    static let screenshotCheckedLabel = "✓ Screenshot checked"
    static let screenshotChangeLabel = "Change"

    static let screenshotAssistanceTitle = "Screenshot Assistance"
    static let screenshotAssistanceOptionalLabel = "Optional"
    static let screenshotAssistanceOffLabel = "Off"
    static let screenshotChooseLabel = "Choose Grubhub screenshot"
    static let screenshotAnalyzingLabel = "Analyzing screenshot…"
    static let turnOnScreenshotAssistanceLabel = "Turn on Screenshot Assistance"

    /// W4-R2 2026-09-01 sync item 3, "First-use remote route ordering": the
    /// only entry point for `Choose Grubhub screenshot` / `Change`. Runs the
    /// required disclosure/Help gating decision *before* the system photo
    /// picker ever opens:
    ///
    /// ```
    /// Choose Grubhub screenshot
    ///   → required remote-AI disclosure/permission (if no consent yet)
    ///     → Accept → Screenshot Help (if unseen) → photo picker
    ///     → Decline → stop: no Help, no picker, no provider bytes
    ///   → Screenshot Help (if consent already granted but Help unseen)
    ///     → photo picker
    ///   → photo picker directly (if both already satisfied)
    /// ```
    ///
    /// Consent (`hasRecordedThirdPartyConsent`) and Help-completion
    /// (`hasCompletedScreenshotHelp`) are independent booleans (item 4): this
    /// reads them independently and never infers one from the other.
    private func beginScreenshotAssistanceFlow() {
        guard screenshotProposalStore.isAIAssistanceEnabled, !screenshotProposalStore.isApplying else {
            return
        }
        guard screenshotProposalStore.hasRecordedThirdPartyConsent else {
            isPresentingScreenshotDisclosure = true
            return
        }
        proceedAfterConsent()
    }

    /// Shared continuation once third-party consent is known to already
    /// exist (either it already did, or `acceptScreenshotDisclosure()` just
    /// recorded it): Screenshot Help first-use education, then the picker.
    private func proceedAfterConsent() {
        if screenshotProposalStore.hasCompletedScreenshotHelp {
            isPresentingScreenshotPicker = true
        } else {
            isPresentingScreenshotHelp = true
        }
    }

    /// Local normalization (resize/compress) plus independent on-device
    /// Vision OCR — no network call yet. OCR runs against the original
    /// selected image (before compression) for the best recognition
    /// fidelity; the evidence text is what actually gates and corroborates
    /// analysis, not the image bytes. By the time a selection reaches this
    /// screen, disclosure/Help gating has already run in
    /// `beginScreenshotAssistanceFlow()` — the picker only ever opens once
    /// consent exists — so this proceeds straight to analysis.
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
        await beginScreenshotAnalysis(input, token: token)
    }

    /// W4-R2 2026-09-01 round-2 sync item 2: `Continue` turns Screenshot
    /// Assistance on unconditionally — a no-op when it was already on (the
    /// existing `beginScreenshotAssistanceFlow()` entry point), and the
    /// actual Off → On transition when reached from
    /// `beginTurnOnScreenshotAssistanceFlow()` — so both entry points share
    /// this one accept handler rather than each needing its own.
    private func acceptScreenshotDisclosure() {
        isPresentingScreenshotDisclosure = false
        screenshotProposalStore.setAIAssistanceEnabled(true)
        screenshotProposalStore.recordThirdPartyConsent()
        proceedAfterConsent()
    }

    /// W4-R2 item 19, final first-use consent/toggle coupling: Decline sends
    /// nothing to OpenAI, shows no Screenshot Help, opens no photo picker,
    /// records no consent, and turns Screenshot Assistance Off —
    /// `setAIAssistanceEnabled(false)` also cancels any other in-flight
    /// analysis and retires every token this generation minted, matching
    /// "Off prevents transfer". Manual Request Food remains fully usable: this
    /// only touches AI assistance state, never `draft`. A later deliberate
    /// re-enable is a plain toggle action, not consent — it does not call
    /// `recordThirdPartyConsent()`, so the next invoked analysis presents this
    /// same disclosure again.
    private func cancelScreenshotDisclosure() {
        isPresentingScreenshotDisclosure = false
        screenshotProposalStore.setAIAssistanceEnabled(false)
    }

    /// W4-R2 2026-09-01 round-2 sync item 2: `Turn on Screenshot Assistance`
    /// is a second entry point into the exact same disclosure/consent gate
    /// `beginScreenshotAssistanceFlow()` already uses, not a second
    /// disclosure design — this only differs from that function in that it
    /// runs while Screenshot Assistance starts Off (so it has no existing
    /// `isAIAssistanceEnabled` guard to pass first). Consent already
    /// recorded (e.g. previously granted, then later turned Off) turns
    /// Screenshot Assistance back on directly and defers to the same shared
    /// `proceedAfterConsent()` continuation; consent absent shows the same
    /// disclosure, whose `Continue` action (`acceptScreenshotDisclosure()`)
    /// turns Screenshot Assistance on. `Not now` leaves it Off, as above.
    private func beginTurnOnScreenshotAssistanceFlow() {
        guard screenshotProposalStore.hasRecordedThirdPartyConsent else {
            isPresentingScreenshotDisclosure = true
            return
        }
        screenshotProposalStore.setAIAssistanceEnabled(true)
        proceedAfterConsent()
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
        let applied = screenshotProposalStore.apply(
            outcome,
            manualEdits: screenshotManualEdits,
            to: &draft
        )
        if applied.location { screenshotProvenance.location = true }
        if applied.foodRequest { screenshotProvenance.foodRequest = true }
        if applied.mealSwipes { screenshotProvenance.mealSwipes = true }

        // W4-R2 2026-08-31 sync: an ineligible screenshot keeps its existing
        // `unsupportedScreenshot` notice presentation untouched — only an
        // eligible completed analysis shows the compact result row.
        if outcome.eligible {
            screenshotChecked = true
        }

        // W4-R2 motion: only the fields this exact call changed receive the
        // brief restrained afterglow — no sequential animation, no haptic.
        // Fenced by the same token every other stage here checks, so a
        // superseded selection's delayed clear cannot erase a later
        // selection's still-current afterglow.
        guard !applied.isEmpty else { return }
        screenshotAfterglowFields = applied
        Task {
            try? await Task.sleep(for: Self.afterglowDuration)
            guard screenshotProposalStore.isCurrent(token) else { return }
            screenshotAfterglowFields = ScreenshotProposalAppliedFields()
        }
    }

    static let afterglowDuration: Duration = .milliseconds(900)

    static let filledFromScreenshotLabel = "Filled from screenshot"

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
                screenshotProvenance.mealSwipes = false
            }
        )
    }

    /// The only path that may set
    /// `screenshotManualEdits.hasManuallyEditedLocation` — latches on a real
    /// picker interaction that leaves a real value selected. Selecting `nil`
    /// ("Select a spot") is a manual clear (W4-R2 2026-08-31 sync): the field
    /// becomes empty and unlatches, so it is eligible for a future screenshot
    /// suggestion again rather than permanently locked requester-owned-empty.
    /// A store-applied proposal write never goes through this binding.
    private var selectedDiningSpotBinding: Binding<DiningSpot?> {
        Binding(
            get: { draft.selectedDiningSpot },
            set: { newValue in
                draft.selectedDiningSpot = newValue
                screenshotManualEdits.hasManuallyEditedLocation = newValue != nil
                screenshotProvenance.location = false
            }
        )
    }

    /// The only path that may set
    /// `screenshotManualEdits.hasManuallyEditedFoodRequest` — latches on a
    /// nonempty manual edit. Clearing the field back to empty (W4-R2
    /// 2026-08-31 sync: "a manually cleared field becomes empty and eligible
    /// for future screenshot suggestions again") unlatches it, rather than
    /// permanently locking out a later AI proposal just because the
    /// requester once typed something here.
    private var foodRequestBinding: Binding<String> {
        Binding(
            get: { draft.foodRequest },
            set: { newValue in
                draft.foodRequest = newValue
                screenshotManualEdits.hasManuallyEditedFoodRequest = !newValue.isEmpty
                screenshotProvenance.foodRequest = false
            }
        )
    }

    private var pickupNameBinding: Binding<String> {
        Binding(
            get: { draft.pickupName },
            set: { draft.pickupName = $0 }
        )
    }

    private var preferredPickupTimeBinding: Binding<Date> {
        Binding(
            get: { draft.preferredPickupTime },
            set: { draft.preferredPickupTime = $0 }
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
    /// control — there is nothing here to correct and nothing to resend.
    /// No haptic: D1 unresolved is neither success nor error semantics.
    /// Identical presentation to `checkingCreateAmbiguityView` (approved
    /// Figma `12 · D1 ambiguity · checking`, which shows the progress glyph,
    /// title, duplicate-submission warning, and `Go to Home` together as one
    /// state) — the only difference is whether reconciliation is still
    /// actively running.
    private var blockedByAmbiguityView: some View {
        unresolvedCreateAmbiguityView(isActivelyChecking: false)
    }

    /// W4-R2 D1: reconciliation of a durable unresolved create is actively
    /// running. No success/error haptic — this state always has an answer
    /// coming, resolving into either `.success` or the same still-unresolved
    /// presentation once reconciliation stops without resolving.
    private var checkingCreateAmbiguityView: some View {
        unresolvedCreateAmbiguityView(isActivelyChecking: true)
    }

    /// Approved Figma `12 · D1 ambiguity · checking`: icon + title, an
    /// explanatory subtitle, a duplicate-submission warning callout, and one
    /// `Go to Home` exit — present regardless of whether reconciliation is
    /// still actively polling, since leaving is always safe and the durable
    /// record survives this screen closing.
    private func unresolvedCreateAmbiguityView(isActivelyChecking: Bool) -> some View {
        VStack(spacing: CommonPlateStyle.Spacing.l) {
            statusIcon(systemName: "ellipsis")

            VStack(spacing: CommonPlateStyle.Spacing.xs) {
                Text(Self.checkingCreateAmbiguityTitle)
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)

                Text(Self.checkingCreateAmbiguitySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)

            Text(Self.duplicateSubmissionWarning)
                .font(.footnote)
                .multilineTextAlignment(.leading)
                .padding(CommonPlateStyle.Spacing.m)
                .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth, alignment: .leading)
                .background(
                    CommonPlateStyle.Color.warmSurface,
                    in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                )
                .accessibilityIdentifier("request-submission-error")

            Button(Self.goToHomeLabel) {
                onExit()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("request-ambiguous-dismiss")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(CommonPlateStyle.Color.baseCanvas)
        .accessibilityIdentifier(isActivelyChecking ? "request-checking-ambiguity" : "request-blocked-ambiguity")
    }

    /// W4-R2 Posting: one native indeterminate progress owner, centered, no
    /// percentage and no haptic. Reached only from an ordinary in-flight
    /// submission (`store.isCreating` with no unresolved ambiguity); resolves
    /// into `.success` (one haptic, direct replacement in the same locus) or
    /// `definitiveFailureView` (one haptic).
    private var postingView: some View {
        VStack(spacing: CommonPlateStyle.Spacing.m) {
            ProgressView()
                .controlSize(.large)
                // W4-R2: the one native indeterminate progress owner tinted
                // CommonPlate purple — no custom progress/percentage/stages,
                // no start haptic.
                .tint(Color.accentColor)
            Text(Self.postingTitle)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(CommonPlateStyle.Color.baseCanvas)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("request-posting")
    }

    /// W4-R2 definitive failure: a centered result state (not the ordinary
    /// editable form) naming what happened, the exact draft that is still
    /// saved, and one way back into it. The title is the approved Figma
    /// wording; the subtitle is the existing, already-approved per-error
    /// `error.message` — preserving the distinct guidance those messages
    /// already carry (e.g. a rate limit or verification issue reads
    /// differently from an ordinary creation failure) rather than collapsing
    /// every definitive outcome into one generic sentence. The draft summary
    /// restates only already-entered field values — vendor, timing, quantity
    /// — never new copy. `Review draft` returns to the exact same,
    /// still-intact `RequestFoodFormDraft`; nothing here clears or mutates it.
    private func definitiveFailureView(error: RequestCreatePresentationError) -> some View {
        VStack(spacing: CommonPlateStyle.Spacing.l) {
            statusIcon(systemName: "xmark")

            VStack(spacing: CommonPlateStyle.Spacing.xs) {
                Text(Self.definitiveFailureTitle)
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)

                Text(error.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("request-submission-error")
            }
            .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)

            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
                Text(Self.savedDraftLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("request-saved-draft-label")

                Text(Self.draftSummaryText(for: draft))
                    .font(.subheadline)
                    .accessibilityIdentifier("request-saved-draft-summary")
            }
            .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth, alignment: .leading)
            .padding(CommonPlateStyle.Spacing.m)
            .background(
                CommonPlateStyle.Color.warmSurface,
                in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
            )

            Spacer(minLength: 0)

            Button(Self.reviewDraftLabel) {
                isShowingFailureSummary = false
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: CommonPlateStyle.Control.majorActionMaximumWidth)
            .accessibilityIdentifier("request-review-draft")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(CommonPlateStyle.Color.baseCanvas)
    }

    /// The soft circular icon badge shared by every W4-R2 status state
    /// (approved Figma `Requester / Status` component).
    private func statusIcon(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.title2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 56, height: 56)
            .background(CommonPlateStyle.Color.warmSurface, in: Circle())
            .accessibilityHidden(true)
    }

    static let goToHomeLabel = "Go to Home"
    static let checkingCreateAmbiguityTitle = "Checking your request"
    static let checkingCreateAmbiguitySubtitle = "CommonPlate can’t confirm yet whether it was posted."
    static let duplicateSubmissionWarning = "Don’t submit another request yet. CommonPlate will keep checking this one."
    static let postingTitle = "Posting request…"
    static let definitiveFailureTitle = "Your request wasn’t posted"
    static let savedDraftLabel = "SAVED DRAFT"
    static let reviewDraftLabel = "Review draft"

    /// A truthful restatement of only already-entered draft values — vendor,
    /// timing, quantity — never new copy and never anything the backend
    /// returned.
    static func draftSummaryText(for draft: RequestFoodFormDraft) -> String {
        let vendor = draft.selectedDiningSpot?.name ?? "—"
        let quantity = RequestCardView.mealSwipesText(draft.mealSwipes)
        let timing: String
        switch draft.timing {
        case .asap:
            timing = "ASAP"
        case .later:
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            formatter.timeZone = NYUCampusTime.timeZone
            timing = formatter.string(from: draft.preferredPickupTime)
        }
        return "\(vendor) · \(quantity) · \(timing)"
    }

    /// Only confirmed availability reveals the form. An `.unknown` result after
    /// a completed probe becomes retryable once no check is running.
    static func presentation(
        hasUnresolvedCreateAmbiguity: Bool,
        availability: RequestCreationAvailability,
        isCheckingAvailability: Bool,
        hasAttemptedAvailabilityCheck: Bool,
        didCreateRequest: Bool,
        /// Defaults to `false` so every existing call site not concerned with
        /// the W4-R2 centered Posting/Checking states is unaffected: passing
        /// no value reproduces the exact presentation this function already
        /// returned before those states existed.
        isCreating: Bool = false
    ) -> RequestFormPresentation {
        // First, ahead of everything. A paused or unresolved availability answer
        // is true but beside the point once a create may already have posted:
        // showing it would replace the one warning that matters with a smaller
        // one, and the student would leave thinking nothing had happened.
        if hasUnresolvedCreateAmbiguity {
            // D1 reconciliation actively running (`isCreating`) reads
            // "Checking your request" with progress; already-resolved
            // still-unresolved ambiguity reads the static warning with its
            // one `Go to Home` exit. Neither carries success/error semantics.
            return isCreating ? .checkingCreateAmbiguity : .blockedByUnresolvedCreateAmbiguity
        }

        if didCreateRequest {
            return .success
        }

        // An ordinary submission in flight (never true except from `.form`,
        // since only that state's Submit action calls `store.createRequest`)
        // replaces the form with the centered Posting state until an
        // authoritative answer exists.
        if isCreating {
            return .posting
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

    /// W4-R2 2026-08-31 round-2 sync: Back is available for every ordinary
    /// state — including D1 ambiguity, availability checks/unavailable, and
    /// the ordinary/failure form — and suppressed only for the transient
    /// Posting/Success submission sequence, which supplies its own exit
    /// (Posting resolves on its own; Success dismisses natively after its
    /// dwell). No other exit replaces the suppressed Back control.
    static func shouldSuppressBackNavigation(presentation: RequestFormPresentation) -> Bool {
        switch presentation {
        case .posting, .success:
            return true
        case .blockedByUnresolvedCreateAmbiguity, .checkingCreateAmbiguity,
             .checkingAvailability, .unavailable, .form:
            return false
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

    /// W4-R2: authoritative creation directly replaces the Posting
    /// spinner/copy in the same centered locus with this state — no CTA. One
    /// success haptic fires exactly once, at the moment this state is first
    /// shown; VoiceOver receives its own announcement rather than relying on
    /// the visual dwell. Held for `successDwellDuration`, then this screen
    /// natively dismisses to Home itself — an explicit control would be a
    /// second acknowledgement this contract does not call for.
    private var successView: some View {
        VStack(spacing: CommonPlateStyle.Spacing.l) {
            statusIcon(systemName: "checkmark")

            Text(Self.successMessage)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("request-success-message")
                .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        // The approved Figma group is optically centered about 30 points
        // above the geometric viewport center.
        .padding(.bottom, 60)
        .background(CommonPlateStyle.Color.baseCanvas)
        .accessibilityElement(children: .combine)
        .task {
            guard !hasAcknowledgedSuccess else { return }
            hasAcknowledgedSuccess = true
            CommonPlateHaptics.success()
            UIAccessibility.post(
                notification: .announcement,
                argument: Self.successMessage
            )
            do {
                try await Task.sleep(for: Self.successDwellDuration)
            } catch {
                return
            }
            onExit()
        }
    }

    static let successMessage = "Your request is posted"
    /// Faith's final motion handoff: held for about 1.7 seconds before this
    /// screen natively dismisses to Home.
    static let successDwellDuration: Duration = .milliseconds(1600)

    private var requestForm: some View {
        let now = Date()
        let isScheduledTimingAvailable = Self.isScheduledTimingAvailable(
            now: now,
            calendar: calendar
        )
        let timingOptions = Self.availableTimingOptions(now: now, calendar: calendar)
        let quickScheduledTimes = Self.quickScheduledTimes(now: now, calendar: calendar)
        // W4-R2 2026-09-02 physical-walkthrough sync (stable Timing
        // footprint): the same gating the removed `if` used, now driving
        // visibility/interactivity of an always-mounted view instead of its
        // presence in the tree.
        let isLaterActive = draft.timing == .later && isScheduledTimingAvailable
        let errors = validationErrors(now: now)
        let visibleScheduleError = validationPresentation
            .visibleError(for: .pickupSchedule, from: errors)?
            .error

        // W4-R2 2026-09-02 physical-walkthrough sync (final vertical
        // composition — B-style baseline rhythm + restrained A-style
        // adaptive spacing). Faith preferred the earlier fixed-spacing
        // prototype's rhythm over a version that concentrated all spare
        // viewport height into one dominant gap, but still wants `Post
        // request` to land in the lower Home-like CTA zone when the form
        // fits on screen. `GeometryReader` + `.frame(minHeight:
        // geometry.size.height, alignment: .top)` is kept — it's still the
        // only way to give a `ScrollView`'s content any spare height to
        // negotiate at all (same technique `HomeExchangeView.exchangeContent`
        // uses) — but the negotiation itself is now distributed across six
        // `adaptiveMajorGap()` calls, one at each major inter-section
        // relationship, instead of one capped spacer immediately above the
        // button. Each stays close to its `.m` baseline and grows only a
        // small bounded amount toward `.l`; six of them growing together on
        // very short content still land `Post request` low, without any one
        // gap reading as an exaggerated cavity. Unlike Home's `Request a
        // Meal`, which lives entirely outside its `ScrollView` in a
        // permanent `.safeAreaInset(edge: .bottom)`, `Post request` stays
        // ordinary scroll content throughout: on tall content the minHeight
        // is already satisfied and every gap collapses to its `.m` floor,
        // and the button scrolls with the form exactly as before.
        return GeometryReader { geometry in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Screenshot Assistance and the eyebrow above it are not one
                // of the six adaptive relationships Faith named — this
                // header-to-first-row gap stays the plain fixed `.m` rhythm
                // it already had.
                VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                    Text(Self.yourOrderEyebrow)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)

                    screenshotAssistanceRow
                }

                // Major relationship: Screenshot Assistance → Dining location.
                adaptiveMajorGap()

                // Each field keeps its own error/address text at the same
                // fixed `.m` rhythm it already had — only the gap *between*
                // logical field groups is adaptive, not a field's relation
                // to its own inline error text.
                VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                    RequesterFormFieldContainer(
                        label: Self.diningLocationLabel,
                        showsProvenance: screenshotProvenance.location,
                        isGlowing: screenshotAfterglowFields.location,
                        provenanceIdentifier: "request-dining-spot-provenance"
                    ) {
                        diningSpotControl
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
                }

                // Major relationship: Dining location → Order details.
                adaptiveMajorGap()

                VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                    RequesterFormFieldContainer(
                        label: Self.orderDetailsLabel,
                        isMultiline: true,
                        showsProvenance: screenshotProvenance.foodRequest,
                        isGlowing: screenshotAfterglowFields.foodRequest,
                        provenanceIdentifier: "request-food-provenance"
                    ) {
                        // A custom binding, not `$draft.foodRequest` directly
                        // — see `foodRequestBinding`'s declaration.
                        TextField(Self.orderDetailsPlaceholder, text: foodRequestBinding, axis: .vertical)
                            .font(.subheadline)
                            .lineLimit(4, reservesSpace: true)
                            .focused($focusedField, equals: .foodDescription)
                            .accessibilityLabel(Self.orderDetailsLabel)
                            .accessibilityHint(Text(fieldError(.foodDescription, errors: errors) ?? ""))
                    }

                    fieldErrorText(
                        .foodDescription,
                        errors: errors,
                        identifier: "request-food-error"
                    )
                }

                // Major relationship: Order details → Meal swipes.
                adaptiveMajorGap()

                RequesterFormFieldContainer(
                    label: Self.mealSwipesLabel,
                    showsProvenance: screenshotProvenance.mealSwipes,
                    isGlowing: screenshotAfterglowFields.mealSwipes,
                    provenanceIdentifier: "request-meal-swipes-provenance"
                ) {
                    mealSwipesControl
                }

                // Major relationship: Meal swipes → PICKUP / Name on order.
                adaptiveMajorGap()

                VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                    Text(Self.pickupEyebrow)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)

                    RequesterFormFieldContainer(
                        label: Self.pickupNameLabel,
                        showsProvenance: false,
                        provenanceIdentifier: "request-pickup-name-provenance"
                    ) {
                        TextField(Self.pickupNamePlaceholder, text: pickupNameBinding)
                            .font(.subheadline)
                            .focused($focusedField, equals: .pickupName)
                            .accessibilityLabel(Self.pickupNameLabel)
                            .accessibilityHint(Text(fieldError(.pickupName, errors: errors) ?? ""))
                    }

                    fieldErrorText(
                        .pickupName,
                        errors: errors,
                        identifier: "request-pickup-name-error"
                    )
                }

                // Major relationship: Name on order → Timing.
                adaptiveMajorGap()

                // W4-R2 2026-08-31 round-2 sync: every timing-related row
                // below — label, control, ASAP's explanation, and every
                // Later-only addition — is one single stack child, not five
                // separate ones. Splitting them across multiple outer
                // siblings was the actual source of the reported excessive
                // ASAP spacing: each always-present wrapper VStack below
                // (needed so `.animation(value:)` has a stable subtree to
                // animate) still claimed its own full gap on both sides even
                // while genuinely empty in ASAP mode, where nothing filled
                // that reserved space. Grouping them here collapses those
                // empty gaps down to the tighter `.xs` rhythm already used
                // between this block's own rows, while Later's real content
                // is unaffected. This whole block is the Timing side of the
                // adjacent "Name on order → Timing" adaptive gap above — its
                // own internal `.xs` rhythm is unrelated and untouched.
                VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
                        // W4-R2 2026-09-02 physical-walkthrough sync: the
                        // info affordance moves to the row's trailing edge —
                        // the same leading-label/trailing-secondary-affordance
                        // composition `screenshotAssistanceRow`'s header
                        // already uses — so it no longer crowds `Timing`
                        // itself.
                        HStack(spacing: CommonPlateStyle.Spacing.xs) {
                            Text(Self.timingLabel)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            // W4-R2 2026-09-02 sync item 4: a quiet secondary
                            // information affordance replacing the removed
                            // persistent Timing subtitles below — on-demand,
                            // not permanent form chrome.
                            // W4-R2 2026-09-05 sync item 7: at least a 44×44
                            // effective tap target around the visually quiet
                            // glyph — only this control, not the surrounding
                            // Timing header, becomes tappable.
                            Button {
                                isPresentingTimingInfo = true
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityLabel(Self.timingInfoAccessibilityLabel)
                            .accessibilityIdentifier("request-timing-info")
                        }
                        .alert(
                            Self.timingInfoTitle,
                            isPresented: $isPresentingTimingInfo
                        ) {
                            Button("OK", role: .cancel) {}
                        } message: {
                            Text(Self.timingInfoBody)
                        }

                        // Only the timings that still have a selectable start
                        // are offered, so "Later" cannot be selected when it
                        // is impossible.
                        timingControl(timingOptions: timingOptions)
                            .onChange(of: draft.timing) { _, newTiming in
                                guard newTiming == .later else {
                                    return
                                }
                                if !Self.isValidScheduledWindow(
                                    startingAt: draft.preferredPickupTime,
                                    now: now,
                                    calendar: calendar
                                ), let firstQuickTime = quickScheduledTimes.first {
                                    draft.preferredPickupTime = firstQuickTime
                                }
                            }

                        // Withheld once the lapsed-Later error is on screen:
                        // that message already opens with this exact
                        // sentence, and printing it twice would read as two
                        // separate findings about the same closed window.
                        if Self.showsScheduledUnavailableNotice(
                            isScheduledTimingAvailable: isScheduledTimingAvailable,
                            visibleScheduleError: visibleScheduleError
                        ) {
                            Text(Self.scheduledUnavailableNotice)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("scheduled-unavailable-notice")
                        }

                        // W4-R2 2026-09-02 physical-walkthrough sync (stable
                        // Timing footprint): always mounted, never
                        // conditionally inserted/removed, so its natural
                        // layout height is reserved identically whether ASAP
                        // or Later is selected — this is what stops `Post
                        // request` from visibly traveling when the requester
                        // switches Timing (previously, removing this view
                        // entirely in ASAP mode removed its height from the
                        // layout too). Quiet Settle's reveal/hide is
                        // reproduced directly via the same `.opacity`/
                        // `.offset` values `QuietSettleModifier` already used
                        // for insertion/removal, animated by `.animation(
                        // value:)` instead of `.transition` — a transition
                        // only fires on insertion/removal, which no longer
                        // happens here, so the identical visual motion is
                        // driven as an ordinary state-change animation
                        // instead. This subtree deliberately still does not
                        // share an ancestor with `timingControl` above, so
                        // this reveal/hide continues to never bleed into an
                        // authored segment-selection animation on the
                        // ASAP/Later pill, which stays governed by no
                        // animation modifier at all. When Later is not
                        // active — ASAP, or Later while scheduling happens to
                        // be unavailable — the reserved region is inert:
                        // `.allowsHitTesting(false)` keeps its invisible
                        // controls untappable and `.accessibilityHidden`
                        // keeps VoiceOver from focusing them.
                        laterTimeChoices(quickTimes: quickScheduledTimes)
                            .padding(.top, CommonPlateStyle.Spacing.s)
                            .opacity(isLaterActive ? 1 : 0)
                            .offset(y: isLaterActive ? 0 : 8)
                            .allowsHitTesting(isLaterActive)
                            .accessibilityHidden(!isLaterActive)
                            .animation(reduceMotion ? nil : Self.quietSettleAnimation, value: draft.timing)

                        // This one location is deliberately outside the
                        // available-only DatePicker branch. If time passes
                        // while "Later" is selected, a submitted scheduling
                        // error stays visible beside the timing controls
                        // rather than disappearing with the picker.
                        fieldErrorText(
                            .pickupSchedule,
                            errors: errors,
                            identifier: "request-pickup-schedule-error"
                        )

                    }

                // Major relationship: Timing → Post request.
                adaptiveMajorGap()

                VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
                    // Only when the rejection had nowhere to move focus. A
                    // backend failure owns this section through
                    // `submissionError` and is never replaced or accompanied
                    // by the pointer.
                    if Self.showsLocalRejectionPointer(
                        isPresenting: showsLocalRejectionPointer,
                        submissionError: effectiveSubmissionError
                    ) {
                        Text(Self.localRejectionPointerNotice)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("request-submission-pointer")
                    }

                    // W4-R2: a backend-authoritative outcome for
                    // `effectiveSubmissionError` is never rendered inline
                    // here — D1 ambiguity has its own dedicated
                    // `blockedByAmbiguityView` and every other definitive
                    // outcome has its own dedicated `definitiveFailureView`
                    // (`isShowingFailureSummary`), both reached via
                    // `presentation(...)` before this form ever re-renders.
                    // This section remains reachable only through
                    // `effectiveSubmissionError`'s continued use in
                    // `isSubmissionEnabled` below, disabling Post request for
                    // the same instant it takes to transition away.

                    Button {
                        Task {
                            await submit()
                        }
                    } label: {
                        Text(Self.postRequestLabel)
                    }
                    .commonPlatePrimaryAction()
                    .disabled(!isSubmissionEnabled)
                }
            }
            .padding(.horizontal, CommonPlateStyle.Spacing.l)
            .padding(.top, CommonPlateStyle.Spacing.l)
            // ScrollView already respects the device safe area. A second
            // 20-point bottom inset produced an earlier walkthrough's
            // oversized gap; this remains the only source of bottom
            // clearance beyond the safe area itself, matching
            // `requestMealButton`'s own reliance on `.safeAreaInset` alone.
            .padding(.bottom, CommonPlateStyle.Spacing.xs)
            // Forces this content to at least fill the available viewport so
            // the six `adaptiveMajorGap()` calls above have height to
            // distribute expansion into on short content; has no effect once
            // content already exceeds `geometry.size.height`.
            .frame(minHeight: geometry.size.height, alignment: .top)
        }
        .background(CommonPlateStyle.Color.baseCanvas)
        .scrollDismissesKeyboard(.interactively)
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
    }

    // MARK: - W4-R2 approved `Requester / Form Field` controls

    /// A custom binding, not `$draft.selectedDiningSpot` directly — see
    /// `selectedDiningSpotBinding`'s declaration. A plain `Menu`, not
    /// `Picker(.menu)`, so no automatic chevron/list-row chrome is added —
    /// the approved field box shows only placeholder/value text.
    private var diningSpotControl: some View {
        Menu {
            Button(Self.selectDiningLocationPlaceholder) {
                selectedDiningSpotBinding.wrappedValue = nil
            }
            ForEach(diningSpots) { spot in
                Button(spot.name) {
                    selectedDiningSpotBinding.wrappedValue = spot
                }
            }
        } label: {
            HStack {
                Text(draft.selectedDiningSpot?.name ?? Self.selectDiningLocationPlaceholder)
                    .font(.subheadline)
                    .foregroundStyle(draft.selectedDiningSpot == nil ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // W4-R2: an obvious native-selectable affordance within the
                // approved bordered field, superseding the former deliberate
                // omission of picker chrome — the catalog/control model is
                // unchanged.
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("request-dining-spot-picker")
        .accessibilityLabel(
            "\(Self.diningLocationLabel): \(draft.selectedDiningSpot?.name ?? Self.selectDiningLocationPlaceholder)"
        )
    }

    /// A custom binding, not `$draft.mealSwipes` directly, so
    /// `screenshotManualEdits.hasManuallyEditedMealSwipes` latches on genuine
    /// user interaction only — never on an AI-applied write, which mutates
    /// `draft` directly rather than through this binding. V1 meal-swipe
    /// requirement (W3-C1): meal swipes only, no Dining Dollars — a bounded
    /// menu, not free-form entry, so this app can never submit a value the
    /// backend would refuse.
    private var mealSwipesControl: some View {
        Menu {
            ForEach(RequestFoodFormDraft.mealSwipeOptions, id: \.self) { count in
                Button("\(count)") {
                    mealSwipesBinding.wrappedValue = count
                }
            }
        } label: {
            HStack {
                Text(RequestCardView.mealSwipesText(draft.mealSwipes))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // W4-R2: same native-selectable affordance as Dining
                // location; the bounded `1...5` menu and its semantics are
                // unchanged.
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("request-meal-swipes-picker")
        .accessibilityLabel("\(Self.mealSwipesLabel): \(RequestCardView.mealSwipesText(draft.mealSwipes))")
    }

    /// Fast and quiet, matching the sync's "interaction remains fast and
    /// quiet" — not the bouncy/spring timing this sync explicitly excludes.
    private static let quietSettleAnimation: Animation = .easeOut(duration: 0.22)

    /// Approved Figma `Requester / Timing` segmented control: same
    /// warm-surface/baseCanvas grammar as the request-card and form-field
    /// tokens, reused rather than native `.pickerStyle(.segmented)`'s system
    /// coloring. Selection/validation authority is unchanged — this is
    /// presentation only.
    private func timingControl(timingOptions: [RequestTiming]) -> some View {
        HStack(spacing: CommonPlateStyle.Spacing.xs) {
            ForEach(timingOptions) { option in
                let isSelected = draft.timing == option
                Button {
                    draft.timing = option
                } label: {
                    Text(option.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, CommonPlateStyle.Spacing.s)
                        .background(
                            isSelected ? CommonPlateStyle.Color.baseCanvas : Color.clear,
                            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard - 3, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(CommonPlateStyle.Spacing.xs)
        .background(
            CommonPlateStyle.Color.requestCardSurface,
            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    /// Prototype C's lightweight secondary row. Values are generated from the
    /// same accepted scheduling validator used by submission, so a quick
    /// choice cannot present a time the payload would refuse.
    private func laterTimeChoices(quickTimes: [Date]) -> some View {
        // W4-R2 2026-09-02 sync item 3: the selected pill is the sole source
        // of truth for the selected Later time — no separate `Selected:`
        // line. A custom selection is one whose minute matches none of the
        // current quick choices; `Choose time` then becomes that chosen time
        // and visibly reads as selected, exactly like a quick-time pill.
        let isCustomTimeSelected = !quickTimes.contains {
            Self.isSameCampusMinute($0, draft.preferredPickupTime, calendar: calendar)
        }

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CommonPlateStyle.Spacing.s) {
                ForEach(quickTimes, id: \.self) { time in
                    let isSelected = Self.isSameCampusMinute(
                        time,
                        draft.preferredPickupTime,
                        calendar: calendar
                    )
                    quickTimeButton(time, isSelected: isSelected)
                }

                chooseTimeButton(isCustomTimeSelected: isCustomTimeSelected)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Before a custom selection this reads `Choose time`; after one, it
    /// becomes the effective chosen time and visibly reads as selected —
    /// the same pill-is-the-selection contract `quickTimeButton` already
    /// uses, so there is never a second representation of the custom value.
    @ViewBuilder
    private func chooseTimeButton(isCustomTimeSelected: Bool) -> some View {
        if isCustomTimeSelected {
            Button(Self.timeLabel(for: draft.preferredPickupTime)) {
                isPresentingExactTimePicker = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityAddTraits(.isSelected)
            .accessibilityIdentifier("request-choose-exact-time")
        } else {
            Button(Self.chooseTimeLabel) {
                isPresentingExactTimePicker = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("request-choose-exact-time")
        }
    }

    @ViewBuilder
    private func quickTimeButton(_ time: Date, isSelected: Bool) -> some View {
        if isSelected {
            Button(Self.timeLabel(for: time)) {
                draft.preferredPickupTime = time
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityAddTraits(.isSelected)
        } else {
            Button(Self.timeLabel(for: time)) {
                draft.preferredPickupTime = time
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    /// W4-R2 2026-09-02 physical-walkthrough sync (final vertical
    /// composition): one instance of this is placed at each of the six major
    /// inter-section relationships in `requestForm`. It is the sole flexible
    /// element at each of those six positions — the `.frame(minHeight:
    /// geometry.size.height, alignment: .top)` on `requestForm`'s outer
    /// content is what gives any of them spare height to negotiate at all,
    /// exactly as a single `Spacer` would; the only difference from a plain
    /// `Spacer` is the shared `.frame(maxHeight:)` ceiling, so growth is
    /// distributed in small, bounded amounts across all six rather than
    /// concentrated in one dominant gap.
    private func adaptiveMajorGap() -> some View {
        Spacer(minLength: Self.majorGapMinimum)
            .frame(maxHeight: Self.majorGapMaximum)
    }

    /// Native iOS wheel time selection, completed with the native Done
    /// toolbar action. It writes directly to the mounted request draft.
    private var exactTimePickerSheet: some View {
        let now = Date()
        let latest = Self.latestScheduledStart(on: now, calendar: calendar) ?? now
        let range = min(now, latest)...latest

        return NavigationStack {
            Form {
                DatePicker(
                    Self.chooseTimeLabel,
                    selection: preferredPickupTimeBinding,
                    in: range,
                    displayedComponents: [.hourAndMinute]
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .accessibilityLabel(Self.chooseTimeLabel)
                .accessibilityIdentifier("request-native-time-picker")
            }
            .navigationTitle(Self.chooseTimeLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isPresentingExactTimePicker = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    static let yourOrderEyebrow = "YOUR ORDER"
    static let pickupEyebrow = "PICKUP"
    static let diningLocationLabel = "Dining location"
    static let selectDiningLocationPlaceholder = "Choose dining location"
    static let orderDetailsLabel = "Order details"
    static let orderDetailsPlaceholder = "What would you like to order?"
    static let mealSwipesLabel = "Meal swipes"
    static let timingLabel = "Timing"
    static let chooseTimeLabel = "Choose time"
    static let pickupNameLabel = "Name on order"
    static let pickupNamePlaceholder = "Name for the Grubhub order"
    static let postRequestLabel = "Post request"
    static let asapTimingNotice =
        "If no one places the order, it expires 3 hours after you post it."
    /// W4-R2 2026-09-02 sync item 4: exact on-demand explanation replacing
    /// the removed persistent `asapTimingNotice`/`scheduledWindowNotice`
    /// subtitles.
    static let timingInfoTitle = "How timing works"
    static let timingInfoBody =
        "ASAP starts now. Later starts at the time you choose. Requests stay open for 3 hours."
    static let timingInfoAccessibilityLabel = "Timing information"
    /// W4-R2 2026-09-03 physical-walkthrough sync (CTA-visibility regression
    /// fix): the shared baseline/ceiling every `adaptiveMajorGap()` uses.
    /// A prior round bumped this to `.l`/`.xl` for a "roomier form" polish
    /// pass; combined with the stable Timing footprint's fixed reserved
    /// height (below) and a same-round typography bump, that made the
    /// form's un-stretched natural content height taller than the viewport
    /// on the tested device — `Post request` sat partially below the fold in
    /// the ordinary ASAP state, which is a harder constraint than any
    /// amount of roominess. Reverted to the earlier `.m`/`.l` bounds: the
    /// same baseline used for every minor relationship elsewhere in this
    /// form (Screenshot Assistance → its header, a field → its own error
    /// text), so the six major relationships are coherent with the rest of
    /// the form without adding extra fixed height on top of the footprint's
    /// own cost. Six of them growing together still land `Post request` low
    /// on short content without any one gap reading as exaggerated.
    static let majorGapMinimum = CommonPlateStyle.Spacing.m
    static let majorGapMaximum = CommonPlateStyle.Spacing.l

    @MainActor
    private func submit(draftSnapshot: RequestFoodFormDraft? = nil) async {
        submissionError = nil
        showsLocalRejectionPointer = false
        isShowingFailureSummary = false

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
                // The store has authoritatively confirmed creation. Clear the
                // completed process/session draft now so a genuinely new
                // Request Food entry cannot inherit it. Ambiguous and failed
                // paths never reach this branch.
                draftSession.clearAfterAuthoritativeCreation()
            } else {
                focusedField = result.firstInvalidTextField
                showsLocalRejectionPointer = Self.showsLocalRejectionPointer(for: result)
            }
        } catch {
            // W4-R2 2026-09-05 sync item 6: the real catch path calls the
            // same production-owned decision `submissionFailureOutcome(for:
            // hasUnresolvedCreateAmbiguity:)` a test can drive directly with
            // a real thrown error — not a second, independently-maintained
            // reconstruction of the same map/gate logic.
            let outcome = Self.submissionFailureOutcome(
                for: error,
                hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity
            )
            submissionError = outcome.mapped
            if outcome.isDefinitiveFailure {
                CommonPlateHaptics.error()
                isShowingFailureSummary = true
            }
        }
    }

    /// The one production-owned decision `submit()`'s real catch path calls
    /// verbatim: map the caught error to its local presentation, then decide
    /// whether it is a definitive non-create (haptic + failure summary) or an
    /// unresolved/write-uncertain outcome, using the exact same
    /// `isDefinitiveNonCreate` gate. Extracted (independent-review fix) so a
    /// test can drive a real ambiguous `REQUEST_CREATION_FAILED` outcome and a
    /// real definitive `INVALID_REQUEST` outcome through this exact function
    /// — the same one `submit()` calls — rather than only reconstructing the
    /// same decision independently against pure functions `submit()` might
    /// stop calling without a test noticing. `mapped` alone is not
    /// authoritative: it is this view's own local presentation mapping of the
    /// caught Swift error, and `RequestStore.createRequest` can arm
    /// `hasUnresolvedCreateAmbiguity` for the exact same server code
    /// (`REQUEST_CREATION_FAILED`) that this local mapping resolves to
    /// `.creationFailed`, a definitive-looking case
    /// (`RequestOperationErrorCode.isWriteUncertain`). Deciding the haptic
    /// from `mapped` alone could therefore fire the authoritative-failure
    /// haptic for a write whose outcome is still unresolved and may in fact
    /// have succeeded. The store's own D1 authority —
    /// `hasUnresolvedCreateAmbiguity`, read fresh by the caller after the
    /// throw — is the one place that actually knows whether this exact write
    /// is unresolved, so it is the deciding signal, not a second local guess
    /// at the same fact.
    static func submissionFailureOutcome(
        for error: Error,
        hasUnresolvedCreateAmbiguity: Bool
    ) -> RequestFoodSubmissionFailureOutcome {
        let mapped = RequestCreatePresentationError.map(error)
        return RequestFoodSubmissionFailureOutcome(
            mapped: mapped,
            isDefinitiveFailure: isDefinitiveNonCreate(
                mapped: mapped,
                hasUnresolvedCreateAmbiguity: hasUnresolvedCreateAmbiguity
            )
        )
    }

    /// The one authoritative decision point for whether a caught submission
    /// error is a definitive non-create (error haptic + failure summary) as
    /// opposed to an unresolved/write-uncertain outcome. An armed
    /// `hasUnresolvedCreateAmbiguity` always outranks the local `mapped`
    /// value: `RequestFoodView.presentation(...)` already renders the D1
    /// blocked/checking states ahead of the ordinary form whenever ambiguity
    /// is armed, so this keeps the haptic/failure-summary side effect
    /// consistent with what the requester actually sees rather than firing a
    /// definitive-failure cue for a write the store itself has not ruled
    /// out. `.operationInProgress` remains excluded regardless: it is a
    /// local in-process guard, never an authoritative backend answer.
    static func isDefinitiveNonCreate(
        mapped: RequestCreatePresentationError,
        hasUnresolvedCreateAmbiguity: Bool
    ) -> Bool {
        guard !hasUnresolvedCreateAmbiguity else { return false }
        return mapped != .ambiguous && mapped != .operationInProgress
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
            return asapTimingNotice
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

    /// Nearby half-hour choices beginning at the next campus-clock boundary.
    /// The values are not product constants: every candidate is calendar-
    /// derived from `now`, then admitted only by the existing Later validator.
    static func quickScheduledTimes(
        now: Date,
        calendar: Calendar,
        maximumCount: Int = 3
    ) -> [Date] {
        guard maximumCount > 0,
              let hourStart = calendar.dateInterval(of: .hour, for: now)?.start else {
            return []
        }

        let minutesIntoHour = calendar.dateComponents([.minute], from: hourStart, to: now).minute ?? 0
        let firstOffset = ((minutesIntoHour / 30) + 1) * 30
        guard let first = calendar.date(byAdding: .minute, value: firstOffset, to: hourStart) else {
            return []
        }

        return (0..<maximumCount).compactMap { index in
            guard let candidate = calendar.date(byAdding: .minute, value: index * 30, to: first),
                  isValidScheduledWindow(startingAt: candidate, now: now, calendar: calendar) else {
                return nil
            }
            return candidate
        }
    }

    static func isSameCampusMinute(_ lhs: Date, _ rhs: Date, calendar: Calendar) -> Bool {
        calendar.isDate(lhs, equalTo: rhs, toGranularity: .minute)
    }

    static func timeLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = NYUCampusTime.timeZone
        return formatter.string(from: date)
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

/// W4-R2 approved `Requester / Form Field` visual language (Figma node
/// `209:364`): a bold field label with inline trailing `Filled from
/// screenshot` provenance, and a bordered warm-canvas control box beneath.
/// Reused for Dining location, Order details, Meal swipes, and Pickup name —
/// the four approved field kinds. Purely presentational: it owns no draft
/// state and enforces no validation; the caller's `content` is the actual
/// interactive control.
struct RequesterFormFieldContainer<Content: View>: View {
    let label: String
    var isMultiline: Bool = false
    var showsProvenance: Bool = false
    var isGlowing: Bool = false
    var provenanceIdentifier: String?
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // `ViewThatFits` lets the provenance caption drop to its own line
            // under larger Dynamic Type sizes rather than clipping or
            // overlapping the label — the approved component's own
            // documented behavior ("may wrap/stack rather than clipping").
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: CommonPlateStyle.Spacing.s) {
                    labelText
                    Spacer(minLength: CommonPlateStyle.Spacing.s)
                    provenanceText
                }
                VStack(alignment: .leading, spacing: 2) {
                    labelText
                    provenanceText
                }
            }

            content
                .padding(.horizontal, 13)
                .padding(.vertical, isMultiline ? 11 : 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CommonPlateStyle.Color.baseCanvas)
                .overlay(
                    RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                        .strokeBorder(CommonPlateStyle.Color.requestCardBorder)
                )
                .clipShape(RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous))
        }
    }

    private var labelText: some View {
        Text(label)
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var provenanceText: some View {
        if showsProvenance {
            Text(RequestFoodView.filledFromScreenshotLabel)
                .font(.caption2)
                .foregroundStyle(isGlowing ? Color.accentColor : Color.accentColor.opacity(0.82))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: isGlowing)
                .accessibilityIdentifier(provenanceIdentifier ?? "")
        }
    }
}
