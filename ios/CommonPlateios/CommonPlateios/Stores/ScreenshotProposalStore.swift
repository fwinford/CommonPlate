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

/// A specific screenshot selection's identity, minted synchronously by
/// `beginSelection(...)` at the moment the requester picks an image — before
/// any local normalization, OCR, disclosure wait, or network transfer for it
/// has started. Every later async stage re-checks `isCurrent(_:)` against
/// this exact token before proceeding to the next stage or mutating shared
/// state, so the newest selection always wins regardless of how long an
/// older selection's own preprocessing takes ("last selection wins from the
/// moment the requester chooses it" — an inversion where an earlier
/// selection's work finishes after a later one's is otherwise possible).
/// Only this file can mint one, so no caller can fabricate a token that
/// reads as current.
struct ScreenshotSelectionToken: Equatable {
    fileprivate let generation: Int
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
    @Published private(set) var hasRecordedThirdPartyConsent: Bool
    /// W4-R2 2026-09-01 sync: independent local Screenshot Help
    /// education-completion state — never inferred from or coupled to
    /// `hasRecordedThirdPartyConsent`/`isAIAssistanceEnabled`. See
    /// `recordScreenshotHelpCompleted()`.
    @Published private(set) var hasCompletedScreenshotHelp: Bool
    /// Generations with analysis work currently in flight. A set, not a
    /// single flag (review finding: one shared boolean can be cleared by
    /// older work while newer work is still running) — mirrors
    /// `EmailAlertStateStore.inFlightAuthorities`. `isApplying` below reports
    /// only whether the *current* generation is among them, so a superseded
    /// generation finishing (and removing itself) can never clear busy state
    /// a newer generation still owns.
    @Published private var inFlightGenerations: Set<Int> = []
    private var currentGeneration = 0

    /// The real, cancellable unit of work behind each generation's network
    /// transfer. This is the actual enforceable handoff between
    /// authorization and transfer initiation (review finding: a plain
    /// boolean re-check ahead of an `await` still leaves a suspension
    /// window). This project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION =
    /// MainActor`, so `ScreenshotProposalService`/`APIClient` are themselves
    /// main-actor-isolated too — the risk here was never an actor hop
    /// between this store and them. It is the `await` on real I/O inside
    /// `URLSession.data(for:)` itself: any `await` suspends this store's own
    /// execution and frees the main actor to run other queued main-actor
    /// work — including a Settings toggle's handler — while the network call
    /// is genuinely in flight. A plain boolean re-checked only once, just
    /// before making that call, cannot react to a state change that happens
    /// *during* that suspension; nothing would be watching. `Task.cancel()`
    /// closes exactly that gap: it sets the task's cancellation flag
    /// synchronously and immediately, independent of when or where the
    /// task's body happens to be running — including before it has started
    /// running at all — and `APIClient.execute`/`ScreenshotProposalService`
    /// already translate both a pre-start and a mid-flight cancellation into
    /// `CancellationError`, including cancelling the underlying
    /// `URLSessionTask` if the network call had already begun. Cancelling
    /// here is therefore a real "stop mattering right now" instruction,
    /// cooperatively observed by the async call chain itself — not a hint a
    /// race can still slip past.
    private var inFlightTasks: [Int: Task<Result<ScreenshotProposalOutcome, Error>, Never>] = [:]

    private let service: ScreenshotProposalService
    private let preferences: ScreenshotProposalPreferencesStoring

    /// Whether analysis for the current selection is in flight. `false` for
    /// a superseded generation's still-finishing work, even while that work
    /// is technically still running.
    var isApplying: Bool {
        inFlightGenerations.contains(currentGeneration)
    }

    init(
        service: ScreenshotProposalService,
        preferences: ScreenshotProposalPreferencesStoring
    ) {
        self.service = service
        self.preferences = preferences
        self.isAIAssistanceEnabled = preferences.isAIAssistanceEnabled
        self.hasRecordedThirdPartyConsent = preferences.hasRecordedThirdPartyConsent
        self.hasCompletedScreenshotHelp = preferences.hasCompletedScreenshotHelp
    }

    /// Cancels every currently tracked transfer task. Called whenever
    /// something must stop mattering *right now*, synchronously, rather than
    /// merely "the next time someone happens to check a flag."
    private func cancelAllInFlightTasks() {
        for task in inFlightTasks.values {
            task.cancel()
        }
        inFlightTasks.removeAll()
    }

    /// Off must retire the current generation, not just cancel its task
    /// (review finding: "turning it back On cannot allow an old analysis
    /// outcome to become current"). Bumping `currentGeneration` here means
    /// `isCurrent(_:)` becomes `false` for every token minted before this
    /// call, deterministically, regardless of the cancellation's own timing
    /// — so even in the (already-prevented) case where a cancelled task's
    /// result somehow still reached `analyzeScreenshot`'s post-await check,
    /// that check would fail for an independent reason. Turning AI
    /// Assistance back On does not itself revive anything: a later analysis
    /// only ever starts from a fresh `beginSelection(...)` token.
    func setAIAssistanceEnabled(_ enabled: Bool) {
        preferences.isAIAssistanceEnabled = enabled
        isAIAssistanceEnabled = enabled
        if !enabled {
            currentGeneration += 1
            notice = nil
            cancelAllInFlightTasks()
        }
    }

    /// First-use third-party (OpenAI) transfer disclosure acceptance.
    /// Recorded once; normal repeat use relies on this without
    /// re-disclosing.
    func recordThirdPartyConsent() {
        preferences.hasRecordedThirdPartyConsent = true
        hasRecordedThirdPartyConsent = true
    }

    /// W4-R2 2026-09-01 sync: records Screenshot Help education completion.
    /// Callers must invoke this only when the requester actually completes
    /// Screenshot Help through `Got it` — never merely because Screenshot
    /// Help was presented or a detail state was opened. Independent of
    /// `recordThirdPartyConsent()`/`setAIAssistanceEnabled(_:)`: neither
    /// consent nor the AI-enabled toggle infers or is inferred from this
    /// state.
    func recordScreenshotHelpCompleted() {
        preferences.hasCompletedScreenshotHelp = true
        hasCompletedScreenshotHelp = true
    }

    func clearNotice() {
        notice = nil
    }

    /// Whether `token` is still the current selection. Every async stage in
    /// `RequestFoodView`'s screenshot pipeline (image load, OCR, disclosure
    /// wait, immediately before network transfer, and after it returns)
    /// checks this before proceeding or mutating shared state; a `false`
    /// result means abort silently — the work belongs to a selection the
    /// requester has since replaced or left.
    func isCurrent(_ token: ScreenshotSelectionToken) -> Bool {
        token.generation == currentGeneration
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
    func beginSelection(
        clearing draft: inout RequestFoodFormDraft,
        manualEdits: ScreenshotFieldManualEditState
    ) -> ScreenshotSelectionToken {
        // A newer selection immediately retires and cancels whatever the
        // previous one was doing, synchronously — see `cancelAllInFlightTasks`.
        cancelAllInFlightTasks()
        currentGeneration += 1
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
        return ScreenshotSelectionToken(generation: currentGeneration)
    }

    /// Invalidates the current selection without touching any draft — for
    /// screen disappearance (review finding: "invalidate old work on
    /// relevant dismissal/disappearance"), where there is no longer a live
    /// `RequestFoodFormDraft` to clear stale values from, but any in-flight
    /// work for this screen must still stop mattering: `isCurrent(_:)` will
    /// report `false` for whatever token it was still carrying.
    func invalidateCurrentSelection() {
        cancelAllInFlightTasks()
        currentGeneration += 1
        notice = nil
    }

    /// Analyzes exactly one already-normalized screenshot for `token`.
    ///
    /// The actual network transfer runs inside a `Task` this store creates,
    /// tracks by generation, and can cancel synchronously from
    /// `setAIAssistanceEnabled(false)`, `beginSelection(...)`, or
    /// `invalidateCurrentSelection()` — this is the real enforceable handoff
    /// the review required: `Task.cancel()` takes effect immediately and is
    /// observed by `Task.checkCancellation()`/`URLSession`'s
    /// cancellation-aware async APIs even if the cancellation happens before
    /// the task's body has started running at all. The suspension this
    /// closes is `URLSession.data(for:)`'s own `await` on real I/O — see
    /// `inFlightTasks`'s declaration for why a plain boolean re-check cannot
    /// close it even though this project's default main-actor isolation
    /// means no actor hop is involved. A cancellation that arrives *after*
    /// the underlying `URLSessionTask` has genuinely begun cannot
    /// retroactively un-send bytes already in flight; what it guarantees is
    /// that this store never treats that transfer's response, once it
    /// returns, as usable.
    ///
    /// Nothing here mutates `draft`; the caller applies the result
    /// synchronously afterward via `apply(_:manualEdits:to:)`, since a
    /// SwiftUI `@State` draft cannot be passed `inout` across an `await`
    /// suspension point.
    /// W4-R4: `images` is the complete set of normalized screenshots for one
    /// logical order (1 to 5). They are analyzed together in one call rather
    /// than one at a time, so overlapping evidence describes one order
    /// instead of several.
    func analyzeScreenshot(
        images: [ScreenshotAnalysisInput],
        participantAuthority: String?,
        token: ScreenshotSelectionToken
    ) async -> ScreenshotProposalOutcome? {
        guard !images.isEmpty,
              images.count <= ScreenshotProposalStore.maxScreenshotSelection else {
            return nil
        }
        guard isCurrent(token) else { return nil }
        guard isAIAssistanceEnabled else { return nil }
        guard let participantAuthority else {
            notice = .verificationRequired
            return nil
        }

        let task = Task<Result<ScreenshotProposalOutcome, Error>, Never> { [service] in
            do {
                // Observed even if this task was cancelled before its body
                // ever started running — the transfer below is never
                // reached in that case.
                try Task.checkCancellation()
                let outcome = try await service.requestProposal(
                    images: images,
                    authority: participantAuthority
                )
                return .success(outcome)
            } catch {
                return .failure(error)
            }
        }
        inFlightTasks[token.generation] = task
        inFlightGenerations.insert(token.generation)
        defer {
            inFlightGenerations.remove(token.generation)
            inFlightTasks.removeValue(forKey: token.generation)
        }

        let result = await task.value

        // `isAIAssistanceEnabled` is not re-checked separately here: Off
        // already retired this generation (`setAIAssistanceEnabled`), so a
        // stale `token` already fails `isCurrent` below in that case.
        guard isCurrent(token) else { return nil }

        switch result {
        case .success(let outcome):
            return outcome
        case .failure(let error):
            if error is CancellationError {
                // Leaving mid-analysis, or being cancelled by a newer
                // selection/AI-Off, is not a reportable failure.
                return nil
            }
            notice = ScreenshotProposalNotice.map(error)
            return nil
        }
    }

    /// Applies an outcome `analyzeScreenshot` returned. Synchronous and
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
