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
}
