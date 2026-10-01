//
//  ScreenshotProposalStore.swift
//  CommonPlateios
//
// The one state owner for the W4-S1 non-authoritative AI screenshot
// proposal capability. Entirely separate from `RequestStore`: this store can
// never call `RequestStore.createRequest(...)`, mint/consume a W3-D1
// operation identity, or otherwise touch Request/D1 lifecycle. It only ever
// mutates the caller-supplied `RequestFoodFormDraft` it is handed, and only
// within the accepted allowlist (location, literal food, meal swipes).
import Combine
import Foundation

/// Non-fatal presentation outcome of one analysis attempt. `unsupported` and
/// `noUsefulExtraction` are ordinary partial-proposal outcomes, not errors —
/// they exist so presentation can explain "nothing to fill in" without
/// treating it the same as an actual failure.
enum ScreenshotProposalNotice: Equatable {
    case verificationRequired
    case verificationExpired
    case invalidImage
    case unsupportedScreenshot
    case noUsefulExtraction
    case unavailable

    var message: String {
        switch self {
        case .verificationRequired:
            return "Verify your NYU email to use AI screenshot assistance."
        case .verificationExpired:
            return "Your NYU email needs to be verified again to use AI screenshot assistance."
        case .invalidImage:
            return "Choose a single Grubhub cart or order-detail screenshot."
        case .unsupportedScreenshot:
            // Approved Figma `Requester / Screenshot Assistance,
            // State=Unsupported` recovery-note wording.
            return "This screenshot doesn’t have enough request details. Try another screenshot or continue manually."
        case .noUsefulExtraction:
            // Approved Figma `Requester / Screenshot Assistance,
            // State=No useful extraction` recovery-note wording.
            return "CommonPlate couldn’t find request details in this screenshot. Your form is unchanged."
        case .unavailable:
            return "We couldn’t analyze that screenshot right now. You can still fill out the form manually."
        }
    }

    static func map(_ error: Error) -> ScreenshotProposalNotice {
        guard let serviceError = error as? ScreenshotProposalServiceError else {
            return .unavailable
        }
        switch serviceError {
        case .verificationRequired:
            return .verificationRequired
        case .authorityInvalid:
            return .verificationExpired
        case .invalidImage:
            return .invalidImage
        case .unavailable:
            return .unavailable
        }
    }
}

/// Explicit requester-interaction provenance for the three allowlisted
/// proposal fields, owned beside the process/session draft and passed into
/// every store call that reads or clears them.
///
/// Deliberately not inferred from value equality (review finding: value
/// equality is wrong whenever a requester types then clears a field while a
/// proposal is pending, or changes an AI value and later manually returns to
/// the same value — neither is distinguishable from "never touched" by
/// comparing values alone). Each flag is set by exactly one thing: a real
/// user interaction with that field's control (`RequestFoodView`'s custom
/// bindings). A store-applied proposal write never sets it — that is what
/// keeps a programmatic AI write from ever being mistaken for a manual edit.
///
/// A flag represents current, non-empty requester content — never edit
/// history. Clearing a field removes only that field's protection. Structured
/// meal names and details therefore use separate sets: an edit to one is
/// never authority over the other.
struct ScreenshotFieldManualEditState: Equatable {
    var hasManuallyEditedLocation = false
    var hasManuallyEditedMealSwipes = false
    /// Indices are fixed draft positions, so a temporarily hidden meal keeps
    /// the authority belonging to each of its current subfields.
    var manuallyEditedMealItemNames: Set<Int> = []
    var manuallyEditedMealItemDetails: Set<Int> = []
    /// The Dining-Dollars-only order-details field, which the same
    /// manual-precedence rule covers.
    var hasManuallyEditedOrderDetails = false
    /// A current-cart estimate is still only a proposal. Once the requester
    /// edits it, later screenshot selections cannot overwrite that value.
    var hasManuallyEditedDiningDollars = false

    func hasManuallyEditedMealItemName(_ index: Int) -> Bool {
        manuallyEditedMealItemNames.contains(index)
    }

    func hasManuallyEditedMealItemDetails(_ index: Int) -> Bool {
        manuallyEditedMealItemDetails.contains(index)
    }
}

/// Which of the three allowlisted proposal fields a single `apply(...)` call
/// actually wrote into the draft (W4-R2 presentation plumbing only — this
/// carries no additional S1 authority). `RequestFoodView` uses this purely to
/// drive its own provenance caption ("Filled from screenshot") and brief
/// afterglow on exactly the fields that changed; it has no bearing on what
/// `apply(...)` is allowed to write, which remains governed entirely by the
/// allowlist and manual-precedence rules below.
struct ScreenshotProposalAppliedFields: Equatable {
    var location = false
    var mealSwipes = false
    /// Exactly the structured meal subfields this call wrote. These are also
    /// the independent presentation-provenance units.
    var mealItemNames: Set<Int> = []
    var mealItemDetails: Set<Int> = []
    var orderDetails = false
    var diningDollars = false
    /// A proposal contained at least one field that was kept because it
    /// currently held requester-owned non-empty content. This is deliberately
    /// aggregate: the UI displays one temporary message per rerun.
    var preservedManualFieldCount = 0

    var didPreserveManualContent: Bool {
        preservedManualFieldCount > 0
    }

    /// Compatibility/readability helper for effects that operate on an entire
    /// meal card, not authority or provenance. Never use this to decide
    /// whether either subfield may be changed.
    var mealEntries: Set<Int> {
        mealItemNames.union(mealItemDetails)
    }

    var isEmpty: Bool {
        !location && !mealSwipes && mealItemNames.isEmpty && mealItemDetails.isEmpty && !orderDetails && !diningDollars
    }
}

/// Why the external-AI popup is (or would have been) offered: the two
/// requester-visible local fallback outcomes. Each maps to an existing
/// requester treatment when external AI cannot be offered.
enum ScreenshotExternalFallbackReason: Equatable {
    /// Local model unavailable, combination not qualified, or attempt failed →
    /// the existing `.unavailable` notice.
    case localUnavailable
    /// Local attempt completed with zero usable valid fields → the existing
    /// `.noUsefulExtraction` treatment.
    case noUsefulExtraction
}

/// The screenshots of one selection whose local attempt ended in an
/// external-AI-eligible outcome, held only in process memory by the owning
/// store while the requester decides. Never persisted; released on
/// `Continue manually`, replacement, Settings OFF, screen disappearance, or
/// once the external attempt starts.
private struct PendingExternalFallback {
    let token: ScreenshotSelectionToken
    /// The Requester workflow's evaluation of the selection: the eligible
    /// screenshots (never an ineligible one) and their on-device evidence.
    let evaluation: ScreenshotAssistanceRuntime<RequesterOrderWorkflow>.Evaluation
    /// The local outcome that made external AI the fallback, kept so that the
    /// same outcome can be presented if the popup can no longer be offered.
    let reason: ScreenshotExternalFallbackReason
}

@MainActor
final class ScreenshotProposalStore: ObservableObject {
    /// W4-R4: the exact number of screenshots that may be selected as
    /// evidence for one logical Grubhub order. Mirrors the backend's own
    /// `MAX_SCREENSHOT_IMAGES` (`src/screenshotProposalRoute.ts`), which
    /// enforces the same bound independently of what this client sends.
    static let maxScreenshotSelection = 5

    @Published private(set) var notice: ScreenshotProposalNotice?
    @Published private(set) var isAIAssistanceEnabled: Bool
    /// W4-R2 2026-09-01 sync: independent local Screenshot Help
    /// education-completion state — never inferred from or coupled to
    /// `isAIAssistanceEnabled`. See `recordScreenshotHelpCompleted()`.
    @Published private(set) var hasCompletedScreenshotHelp: Bool
    /// Generations with analysis work currently in flight. A set, not a
    /// single flag (review finding: one shared boolean can be cleared by
    /// older work while newer work is still running) — mirrors
    /// `EmailAlertStateStore.inFlightAuthorities`. `isApplying` below reports
    /// only whether the *current* generation is among them, so a superseded
    /// generation finishing (and removing itself) can never clear busy state
    /// a newer generation still owns.
    @Published private var inFlightGenerations: Set<Int> = []
    /// W4-S3: non-nil exactly while the external-AI fallback popup is offered.
    @Published private var pendingExternalFallback: PendingExternalFallback?

    private let service: ScreenshotProposalService
    /// The shared runtime, parameterized with the Requester workflow adapter.
    private let runtime: ScreenshotAssistanceRuntime<RequesterOrderWorkflow>
    /// W4-S3: generation identity, cancellation, and stale-result fencing are
    /// the shared runtime's mechanism (`ScreenshotAttemptFence`), and the fence
    /// is the RUNTIME's own — every token it mints identifies it, so the
    /// runtime can itself refuse an external permission for a stale attempt.
    /// This store keeps the Requester policy on top of it. Cancelling a tracked
    /// task is a real "stop mattering right now" instruction, cooperatively
    /// observed by the async call chain itself — not a hint a race can still
    /// slip past.
    private var fence: ScreenshotAttemptFence { runtime.fence }
    private let preferences: ScreenshotProposalPreferencesStoring

    /// Whether analysis for the current selection is in flight. `false` for
    /// a superseded generation's still-finishing work, even while that work
    /// is technically still running.
    var isApplying: Bool {
        inFlightGenerations.contains(fence.currentGeneration)
    }

    /// W4-S3: whether the centered `Couldn’t analyze these on your device`
    /// popup is being offered for the current selection.
    var isAwaitingExternalAIPermission: Bool {
        pendingExternalFallback != nil
    }

    /// The local fallback reason retained by the pending popup, readable for
    /// proof only.
    var pendingExternalFallbackReason: ScreenshotExternalFallbackReason? {
        pendingExternalFallback?.reason
    }

    init(
        service: ScreenshotProposalService,
        preferences: ScreenshotProposalPreferencesStoring,
        runtime: ScreenshotAssistanceRuntime<RequesterOrderWorkflow>? = nil
    ) {
        self.service = service
        self.preferences = preferences
        self.runtime = runtime ?? RequesterScreenshotAssistanceProduction.makeRuntime(service: service)
        self.isAIAssistanceEnabled = preferences.isAIAssistanceEnabled
        self.hasCompletedScreenshotHelp = preferences.hasCompletedScreenshotHelp
    }

    /// Off must retire the current generation, not just cancel its task
    /// (review finding: "turning it back On cannot allow an old analysis
    /// outcome to become current"). Retiring makes `isCurrent(_:)` `false`
    /// for every token minted before this call, deterministically, regardless
    /// of the cancellation's own timing. W4-S3: Off also retires a pending
    /// external-AI popup and its in-memory screenshots, so no transfer can be
    /// prevented from starting OR applied late. Turning Screenshot Assistance
    /// back On does not itself revive anything, and authorizes nothing
    /// external: a later analysis only ever starts from a fresh
    /// `beginSelection(...)` token, and any external transfer needs its own
    /// `Use external AI` action.
    func setAIAssistanceEnabled(_ enabled: Bool) {
        preferences.isAIAssistanceEnabled = enabled
        isAIAssistanceEnabled = enabled
        if !enabled {
            retireCurrentSelection()
        }
    }

    /// W4-R2 2026-09-01 sync: records Screenshot Help education completion.
    /// Callers must invoke this only when the requester actually completes
    /// Screenshot Help through `Got it` — never merely because Screenshot
    /// Help was presented or a detail state was opened. Independent of
    /// `setAIAssistanceEnabled(_:)`: the AI-enabled toggle neither infers nor
    /// is inferred from this state.
    func recordScreenshotHelpCompleted() {
        preferences.hasCompletedScreenshotHelp = true
        hasCompletedScreenshotHelp = true
    }

    func clearNotice() {
        notice = nil
    }

    /// Whether `token` is still the current selection. Every async stage in
    /// `RequestFoodView`'s screenshot pipeline (image load, OCR, local
    /// analysis, immediately before any external transfer, and after it
    /// returns) checks this before proceeding or mutating shared state; a
    /// `false` result means abort silently — the work belongs to a selection
    /// the requester has since replaced or left.
    func isCurrent(_ token: ScreenshotSelectionToken) -> Bool {
        fence.isCurrent(token)
    }

    /// Mints a new selection identity and immediately clears whatever is
    /// still AI-owned in `draft` from the previous selection — synchronously,
    /// before any async work for the new selection begins. This is what
    /// makes stale-generation clearing correct even when the new image later
    /// fails to load, decode, or OCR: the old AI-owned values are already
    /// gone by the time any of that could fail, not left in place until a
    /// later analysis call "wins."
    ///
    /// A field with current requester-owned non-empty content is never cleared
    /// here. Screenshot-derived values remain eligible to be replaced by a
    /// newer proposal, while each structured meal subfield is handled alone.
    ///
    /// A new selection retires any previous external-AI popup and its
    /// permission state: permission is per selected screenshot set and can
    /// never carry over to this one.
    func beginSelection(
        clearing draft: inout RequestFoodFormDraft,
        manualEdits: ScreenshotFieldManualEditState
    ) -> ScreenshotSelectionToken {
        // A newer selection immediately retires and cancels whatever the
        // previous one was doing, synchronously — see `ScreenshotAttemptFence`.
        discardPendingExternalFallback()
        let token = fence.beginAttempt()
        notice = nil
        if !manualEdits.hasManuallyEditedLocation {
            draft.selectedDiningSpot = nil
        }
        for index in 0..<RequestFoodFormDraft.maxMealSwipes {
            if !manualEdits.hasManuallyEditedMealItemName(index) {
                draft.mealEntries[index].name = ""
            }
            if !manualEdits.hasManuallyEditedMealItemDetails(index) {
                draft.mealEntries[index].details = nil
            }
        }
        if !manualEdits.hasManuallyEditedOrderDetails {
            draft.orderDetails = ""
        }
        if !manualEdits.hasManuallyEditedMealSwipes {
            draft.mealSwipes = RequestFoodFormDraft.mealSwipeOptions.first!
        }
        // `menuPath` and `diningDollarsText` are deliberately untouched here
        // and everywhere else in this store: Screenshot Assistance proposes
        // values, it does not decide which menu the requester is using or how
        // many Dining Dollars they need.
        return token
    }

    /// Invalidates the current selection without touching any draft — for
    /// screen disappearance (review finding: "invalidate old work on
    /// relevant dismissal/disappearance"), where there is no longer a live
    /// `RequestFoodFormDraft` to clear stale values from, but any in-flight
    /// work or pending external-AI popup for this screen must still stop
    /// mattering: `isCurrent(_:)` will report `false` for whatever token it
    /// was still carrying.
    func invalidateCurrentSelection() {
        retireCurrentSelection()
    }

    private func retireCurrentSelection() {
        discardPendingExternalFallback()
        fence.retire()
        notice = nil
    }

    /// Releases the pending external-AI popup state and its in-memory
    /// screenshots.
    private func discardPendingExternalFallback() {
        guard pendingExternalFallback != nil else { return }
        pendingExternalFallback = nil
    }

    /// Analyzes the already-prepared screenshots of one selection, local-first.
    ///
    /// 1. The Requester workflow's deterministic on-device eligibility gate
    ///    runs first (it derives its own on-device OCR evidence from the
    ///    ordered selection). A wholly ineligible selection returns an
    ///    ineligible outcome (existing `unsupportedScreenshot` treatment) and
    ///    NEVER reaches any provider or the external-AI popup.
    /// 2. One local attempt runs. A useful result (at least one valid proposal
    ///    field, even partial) is returned to be applied.
    /// 3. Only when the local attempt was unavailable/unqualified, failed, or
    ///    completed with zero usable fields is the external-AI popup offered
    ///    (`isAwaitingExternalAIPermission`) — with nothing sent. This method
    ///    returns `nil` in that case, and for cancelled/stale/superseded work.
    ///    Without current participant authority the popup is not offered and
    ///    the same local outcome is presented as the ordinary requester
    ///    treatment instead (`.unavailable` notice, or the empty eligible
    ///    outcome, which `apply` turns into `.noUsefulExtraction`).
    ///
    /// This method can never cause an external transfer; only
    /// `useExternalAI(participantAuthority:)` can, and only after the
    /// requester's explicit `Use external AI` action.
    ///
    /// Nothing here mutates `draft`; the caller applies the result
    /// synchronously afterward via `apply(_:manualEdits:to:)`, since a
    /// SwiftUI `@State` draft cannot be passed `inout` across an `await`
    /// suspension point.
    /// W4-R4: `images` is the complete set of normalized screenshots for one
    /// logical order (1 to 5), analyzed together rather than one at a time, so
    /// overlapping evidence describes one order instead of several.
    ///
    /// `participantAuthority` supplies the requester's CURRENT participant
    /// authority (`nil` once it was lost after this already-admitted form
    /// mounted). It is evaluated ONLY at the moment the external-AI popup would
    /// be offered — after evidence derivation and the local attempt have
    /// finished — never earlier, so authority lost while those ran can never
    /// still yield the offer. Local analysis and its ordinary outcome notice are
    /// unaffected by it, and its value is not retained.
    func analyzeScreenshot(
        images: [ScreenshotPreparedImage],
        participantAuthority: @MainActor () -> String?,
        token: ScreenshotSelectionToken
    ) async -> ScreenshotProposalOutcome? {
        guard !images.isEmpty,
              images.count <= ScreenshotProposalStore.maxScreenshotSelection,
              let selection = ScreenshotSelection(images: images) else {
            return nil
        }
        guard isCurrent(token) else { return nil }
        guard isAIAssistanceEnabled else { return nil }

        // The Requester workflow's eligibility gate and OCR evidence
        // derivation. Tracked by the fence so a retired selection stops
        // recognizing immediately, but deliberately NOT counted as in flight:
        // `isApplying` keeps covering exactly the provider attempt, as it did
        // when this preparation ran in the view before the store was called.
        let evaluationTask = Task<ScreenshotAssistanceRuntime<RequesterOrderWorkflow>.Evaluation?, Never> { [runtime] in
            await runtime.evaluate(selection, for: token)
        }
        fence.track(evaluationTask, for: token)
        let derived = await evaluationTask.value
        fence.untrack(token)
        guard isCurrent(token) else { return nil }

        guard let evaluation = derived else {
            return ScreenshotProposalOutcome(eligible: false, proposal: .empty)
        }

        let task = Task<ScreenshotAnalysisAttemptResult<ScreenshotProposalOutcome>, Never> { [runtime] in
            await runtime.runLocal(evaluation)
        }
        fence.track(task, for: token)
        inFlightGenerations.insert(token.generation)
        defer {
            inFlightGenerations.remove(token.generation)
            fence.untrack(token)
        }

        let result = await task.value

        // `isAIAssistanceEnabled` is not re-checked separately here: Off
        // already retired this generation, so a stale `token` already fails
        // `isCurrent` below in that case.
        guard isCurrent(token) else { return nil }

        switch result {
        case .completed(let analysis):
            // Requester does not surface provider-cited evidence; whatever the
            // runtime returned beside the outcome is released here.
            let outcome = analysis.outcome
            guard outcome.eligible else { return outcome }
            if outcome.isEmpty {
                return resolveExternalFallback(
                    .noUsefulExtraction,
                    evaluation: evaluation,
                    participantAuthority: participantAuthority,
                    token: token
                )
            }
            return outcome
        case .localUnavailable, .failed:
            return resolveExternalFallback(
                .localUnavailable,
                evaluation: evaluation,
                participantAuthority: participantAuthority,
                token: token
            )
        case .cancelled:
            // Leaving mid-analysis, or being cancelled by a newer
            // selection/AI-Off, is not a reportable failure.
            return nil
        }
    }

    /// A local fallback outcome (`reason`) either holds the external-AI popup
    /// or, when current participant authority is missing, is presented as the
    /// ordinary requester outcome it always was. Only the offer depends on
    /// authority; no verification prompt is ever launched from here.
    ///
    /// `participantAuthority` is evaluated here, at the offer decision, and
    /// nowhere else on the analysis path.
    ///
    /// Returns what the caller should apply: `nil` when the popup is now
    /// pending or the reason has only a notice, otherwise the ordinary empty
    /// outcome.
    private func resolveExternalFallback(
        _ reason: ScreenshotExternalFallbackReason,
        evaluation: ScreenshotAssistanceRuntime<RequesterOrderWorkflow>.Evaluation,
        participantAuthority: @MainActor () -> String?,
        token: ScreenshotSelectionToken
    ) -> ScreenshotProposalOutcome? {
        guard participantAuthority() != nil else {
            return presentLocalOutcome(for: reason)
        }
        pendingExternalFallback = PendingExternalFallback(
            token: token,
            evaluation: evaluation,
            reason: reason
        )
        return nil
    }

    /// The existing requester treatment for a local fallback outcome:
    /// `.unavailable` is a notice (nothing to apply); zero usable fields is the
    /// ordinary eligible-but-empty outcome, which `apply` turns into the
    /// existing `.noUsefulExtraction` treatment.
    private func presentLocalOutcome(for reason: ScreenshotExternalFallbackReason) -> ScreenshotProposalOutcome? {
        switch reason {
        case .localUnavailable:
            notice = .unavailable
            return nil
        case .noUsefulExtraction:
            return ScreenshotProposalOutcome(eligible: true, proposal: .empty)
        }
    }

    /// Participant authority was lost while the popup was pending: the
    /// external action is no longer usable, so it is retired (its held
    /// screenshots released, nothing sent, no verification prompt) and the
    /// local outcome that originally caused it is presented instead. Returns
    /// the outcome the caller must apply (with its token), or `nil` when
    /// nothing is pending, the selection is no longer current, or the
    /// treatment is notice-only.
    func retireExternalFallbackForLostAuthority() -> (token: ScreenshotSelectionToken, outcome: ScreenshotProposalOutcome)? {
        guard let pending = pendingExternalFallback else { return nil }
        discardPendingExternalFallback()
        guard isCurrent(pending.token), isAIAssistanceEnabled,
              let outcome = presentLocalOutcome(for: pending.reason) else {
            return nil
        }
        return (pending.token, outcome)
    }

    /// `Continue manually`: sends nothing off-device, dismisses the popup,
    /// releases the held screenshots, and leaves manual entry (and Screenshot
    /// Assistance itself, still On) exactly as they were.
    func continueManually() {
        discardPendingExternalFallback()
    }

    /// `Use external AI`: the requester's explicit permission to send the
    /// CURRENTLY SELECTED screenshots, through CommonPlate, to OpenAI for this
    /// one external attempt. There is no second confirmation, and the
    /// permission is consumed here: it is not persisted, remembered, or reusable.
    ///
    /// This is one terminal attempt for the selection. Whatever it produces —
    /// a useful proposal, nothing useful, or a failure — ends with the existing
    /// requester treatment; it never offers the popup again for the same
    /// selection (the requester may `Change` the selection).
    ///
    /// Returns the outcome to apply, with the token it belongs to, or `nil` for
    /// stale/cancelled/superseded/failed work (a failure sets `notice`).
    func useExternalAI(
        participantAuthority: @escaping @MainActor () -> String?
    ) async -> (token: ScreenshotSelectionToken, outcome: ScreenshotProposalOutcome)? {
        guard let pending = pendingExternalFallback,
              isCurrent(pending.token),
              isAIAssistanceEnabled else {
            // A retired popup's permission can never be used.
            discardPendingExternalFallback()
            return nil
        }
        // Consumed: the popup is gone and the held screenshots are now owned
        // solely by this one attempt. A second tap finds nothing pending.
        pendingExternalFallback = nil
        let token = pending.token

        // Authority lost between the popup being offered and this tap (the view
        // normally retires the popup first): send nothing, surface no
        // verification prompt from Screenshot Assistance, and present the
        // local outcome that originally caused the popup. Manual entry stays
        // available. This tap-time check is not sufficient by itself: the
        // runtime reads authority again at the transfer boundary.
        guard participantAuthority() != nil else {
            return presentLocalOutcome(for: pending.reason).map { (token, $0) }
        }

        // The runtime mints the permission for exactly this token and this
        // evaluation, and only while the token is current and is the attempt the
        // evaluation was produced for. A refusal means the selection was
        // retired: nothing is resumed and no resource exists.
        guard let permission = runtime.authorizeExternalTransfer(for: token, evaluation: pending.evaluation) else {
            return nil
        }

        let task = Task<Result<ScreenshotProposalOutcome, Error>, Never> { [runtime] in
            do {
                // Observed even if this task was cancelled before its body
                // ever started running — the transfer is never reached in
                // that case.
                try Task.checkCancellation()
                let analysis = try await runtime.runExternal(
                    authority: participantAuthority,
                    permission: permission
                )
                return .success(analysis.outcome)
            } catch {
                return .failure(error)
            }
        }
        fence.track(task, for: token)
        inFlightGenerations.insert(token.generation)
        defer {
            inFlightGenerations.remove(token.generation)
            fence.untrack(token)
        }

        let result = await task.value

        if case .failure(let error) = result,
           let failure = error as? ScreenshotAnalysisFailure {
            // Refused by the runtime's own gates, before any provider work: no
            // provider call. A retired selection presents nothing; authority
            // that disappeared after the tap presents the local outcome that
            // caused the popup, exactly as the tap-time check does.
            switch failure {
            case .authorityUnavailable:
                guard isCurrent(token), isAIAssistanceEnabled else { return nil }
                return presentLocalOutcome(for: pending.reason).map { (token, $0) }
            case .permissionUnavailable:
                return nil
            default:
                break
            }
        }

        // A transfer that already began cannot be recalled, but its result is
        // never treated as usable once this selection has been retired.
        guard isCurrent(token) else { return nil }

        switch result {
        case .success(let outcome):
            return (token, outcome)
        case .failure(let error):
            if error is CancellationError { return nil }
            notice = ScreenshotProposalNotice.map(error)
            return nil
        }
    }

    /// Applies an outcome `analyzeScreenshot` (or `useExternalAI`) returned. Synchronous and
    /// side-effect-bounded to `draft`/`notice` only — safe to call with an
    /// `inout` `@State` draft because it never suspends. Callers must check
    /// `isCurrent(token)` again immediately before calling this (the result
    /// may have gone stale during the gap between `analyzeScreenshot`
    /// returning and this being called back on the main actor).
    ///
    /// A field with current requester-owned non-empty content never receives a
    /// proposed value here. `preservedManualFieldCount` records only values a
    /// proposal actually tried to replace, so it can drive the bounded rerun
    /// feedback without treating every successful run as preservation.
    @discardableResult
    func apply(
        _ outcome: ScreenshotProposalOutcome,
        manualEdits: ScreenshotFieldManualEditState,
        to draft: inout RequestFoodFormDraft
    ) -> ScreenshotProposalAppliedFields {
        var applied = ScreenshotProposalAppliedFields()
        if let spot = outcome.proposal.selectedDiningSpot {
            if manualEdits.hasManuallyEditedLocation {
                applied.preservedManualFieldCount += 1
            } else {
                draft.selectedDiningSpot = spot
                applied.location = true
            }
        }
        // Meal swipes first, so the entry fill below writes into the count
        // this same proposal just established rather than the previous one.
        if let mealSwipes = outcome.proposal.mealSwipes {
            if manualEdits.hasManuallyEditedMealSwipes {
                applied.preservedManualFieldCount += 1
            } else {
                draft.mealSwipes = mealSwipes
                applied.mealSwipes = true
            }
        }

        if let mealItems = outcome.proposal.mealItems, !mealItems.isEmpty {
            switch draft.menuPath {
            case .mealExchange:
                // One proposed item per active meal field, in order. A name
                // and its optional details are independent manual-authority
                // and provenance units; writing one never authorizes writing
                // the other.
                for index in draft.activeMealEntryIndices
                where index < mealItems.count {
                    let proposal = mealItems[index]
                    if manualEdits.hasManuallyEditedMealItemName(index) {
                        applied.preservedManualFieldCount += 1
                    } else {
                        draft.mealEntries[index].name = proposal.name
                        applied.mealItemNames.insert(index)
                    }
                    // `nil` means this partial proposal did not offer a
                    // Details value. It must not manufacture an update by
                    // clearing a sibling field; the next selection's normal
                    // AI-owned clearing remains the generation boundary.
                    if let details = proposal.details {
                        if manualEdits.hasManuallyEditedMealItemDetails(index) {
                            applied.preservedManualFieldCount += 1
                        } else {
                            draft.mealEntries[index].details = details
                            applied.mealItemDetails.insert(index)
                        }
                    }
                }
            case .diningDollars:
                // The Dining-Dollars-only path has one order-details field
                // rather than per-swipe entries, so the observed items are
                // joined into it — the same values, in the same order, in the
                // one field this path actually has. Matches the backend's
                // `deriveFoodSummary` item-to-text convention
                // (`src/structuredRequest.ts`): "name (details)" when details
                // are present, else just "name".
                if !manualEdits.hasManuallyEditedOrderDetails {
                    draft.orderDetails = mealItems
                        .map { item in item.details.map { "\(item.name) (\($0))" } ?? item.name }
                        .joined(separator: "; ")
                    applied.orderDetails = true
                } else {
                    applied.preservedManualFieldCount += 1
                }
            }
        }

        // This narrow R4 authority is populated only by the backend's
        // independent current-cart/order-level OCR rule. It remains a draft
        // value the requester can edit; it never selects a menu path or
        // submits a request.
        if let cents = outcome.proposal.estimatedDiningDollarsCents,
           draft.menuPath == .mealExchange,
           !manualEdits.hasManuallyEditedDiningDollars {
            draft.diningDollarsText = DiningDollarsEntry.formatted(cents: cents)
            applied.diningDollars = true
        } else if outcome.proposal.estimatedDiningDollarsCents != nil,
                  draft.menuPath == .mealExchange {
            applied.preservedManualFieldCount += 1
        }

        if !outcome.eligible {
            notice = .unsupportedScreenshot
        } else if outcome.isEmpty {
            notice = .noUsefulExtraction
        }

        return applied
    }
}
