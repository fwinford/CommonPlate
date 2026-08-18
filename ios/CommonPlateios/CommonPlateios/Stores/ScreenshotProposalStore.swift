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
            return "That screenshot type isn’t supported yet. Choose a Grubhub cart or order-detail screenshot, or fill out the form manually."
        case .noUsefulExtraction:
            return "We couldn’t find anything usable in that screenshot. You can still fill out the form manually."
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
/// proposal fields, owned by `RequestFoodView` and passed into every store
/// call that reads or clears them.
///
/// Deliberately not inferred from value equality (review finding: value
/// equality is wrong whenever a requester types then clears a field while a
/// proposal is pending, changes an AI value and later manually returns to
/// the same value, or manually clears a location back to `nil` — every one
/// of those must retire AI ownership, and none of them is distinguishable
/// from "never touched" by comparing values alone). Each flag is set by
/// exactly one thing: a real user interaction with that field's control
/// (`RequestFoodView`'s custom bindings). A store-applied proposal write
/// never sets it — that is what keeps a programmatic AI write from ever
/// being mistaken for a manual edit. Once true, a flag is never reset for
/// the lifetime of one `RequestFoodView` instance: manual ownership, once
/// established, is permanent.
struct ScreenshotFieldManualEditState: Equatable {
    var hasManuallyEditedLocation = false
    var hasManuallyEditedFoodRequest = false
    var hasManuallyEditedMealSwipes = false
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
    @Published private(set) var notice: ScreenshotProposalNotice?
    @Published private(set) var isAIAssistanceEnabled: Bool
    @Published private(set) var hasRecordedThirdPartyConsent: Bool
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
    /// A field the requester has manually edited (`manualEdits`) is never
    /// cleared here, regardless of its current value — manual ownership is
    /// permanent for the lifetime of this screen, never merely "until the
    /// value happens to match an old AI value again."
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
        if !manualEdits.hasManuallyEditedFoodRequest {
            draft.foodRequest = ""
        }
        if !manualEdits.hasManuallyEditedMealSwipes {
            draft.mealSwipes = RequestFoodFormDraft.mealSwipeOptions.first!
        }
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
    func analyzeScreenshot(
        imageData: Data,
        mimeType: String,
        localEvidenceText: String,
        participantAuthority: String?,
        token: ScreenshotSelectionToken
    ) async -> ScreenshotProposalOutcome? {
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
                    imageData: imageData,
                    mimeType: mimeType,
                    localEvidenceText: localEvidenceText,
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
    /// A field the requester has manually edited never receives a proposed
    /// value here, regardless of its current value.
    func apply(
        _ outcome: ScreenshotProposalOutcome,
        manualEdits: ScreenshotFieldManualEditState,
        to draft: inout RequestFoodFormDraft
    ) {
        if let spot = outcome.proposal.selectedDiningSpot, !manualEdits.hasManuallyEditedLocation {
            draft.selectedDiningSpot = spot
        }
        if let food = outcome.proposal.foodRequest, !manualEdits.hasManuallyEditedFoodRequest {
            draft.foodRequest = food
        }
        if let mealSwipes = outcome.proposal.mealSwipes, !manualEdits.hasManuallyEditedMealSwipes {
            draft.mealSwipes = mealSwipes
        }

        if !outcome.eligible {
            notice = .unsupportedScreenshot
        } else if outcome.isEmpty {
            notice = .noUsefulExtraction
        }
    }
}
