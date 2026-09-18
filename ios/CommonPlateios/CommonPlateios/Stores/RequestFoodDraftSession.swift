//
//  RequestFoodDraftSession.swift
//  CommonPlateios
//
// W4-R2 process-lifetime Request Food draft continuity. This owner is created
// by ContentView above the transient pushed route. It deliberately has no
// disk/server storage and no request-create, D1, credential, or operation
// authority.
import SwiftUI
import Combine

@MainActor
final class RequestFoodDraftSession: ObservableObject {
    @Published var draft = RequestFoodFormDraft()

    /// Manual-precedence is part of the unfinished draft's meaning. Keeping
    /// these flags beside the values prevents a later screenshot selected
    /// after route re-entry from overwriting a value the requester had
    /// already edited manually.
    @Published var screenshotManualEdits = ScreenshotFieldManualEditState()

    /// Retains the truthful "Filled from screenshot" presentation for values
    /// that remain accepted and unedited when the route is recreated.
    @Published var screenshotProvenance = ScreenshotProposalAppliedFields()

    /// Called only after request creation is authoritatively confirmed. D1
    /// ambiguity, verification, route departure, backgrounding, and every
    /// definitive non-create leave this owner untouched.
    func clearAfterAuthoritativeCreation() {
        draft = RequestFoodFormDraft()
        screenshotManualEdits = ScreenshotFieldManualEditState()
        screenshotProvenance = ScreenshotProposalAppliedFields()
    }

    /// W4-D2 FIX 2026-09-18 (independent-review MUST FIX 2), Path A: installs
    /// the trusted draft `RequestStore` restored from a terminal NO-CREATE's
    /// recovered payload, and resets every other session-owned field —
    /// `screenshotManualEdits`, `screenshotProvenance`, and anything else this
    /// owner holds — so no manual-edit or provenance state left over from a
    /// previous request/session can attach to it.
    func replaceForTerminalRecovery(restoring draft: RequestFoodFormDraft) {
        self.draft = draft
        screenshotManualEdits = ScreenshotFieldManualEditState()
        screenshotProvenance = ScreenshotProposalAppliedFields()
    }

    /// W4-D2 FIX 2026-09-18 (independent-review MUST FIX 2), Path B: opens a
    /// new Request Food form after a terminal NO-CREATE whose payload was
    /// unavailable. Behaviorally identical to `clearAfterAuthoritativeCreation()`
    /// — a genuinely fresh session — kept as its own named operation so this
    /// call site's intent (terminal recovery, not a successful creation)
    /// stays legible and the two can be changed independently if they ever
    /// need to diverge.
    func startEmptyAfterTerminalRecovery() {
        clearAfterAuthoritativeCreation()
    }
}
