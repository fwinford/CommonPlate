//
//  ScreenshotProposalPreferencesStorage.swift
//  CommonPlateios
//
// W4-S1 local presentation preferences only — not participant identity, not
// backend authority, and not itself an AI Assistance Settings UI
// implementation. `isAIAssistanceEnabled` is the single Screenshot Assistance
// On/Off control: Off retires current attempts and prevents any external
// transfer; On enables Screenshot Assistance but never itself authorizes a
// transfer.
// `hasCompletedScreenshotHelp` (W4-R2 2026-09-01 sync) is the independent
// first-use Screenshot Help education-completion flag: it tracks only whether
// the requester has completed Screenshot Help through `Got it` and is never
// inferred from AI-enabled state.
//
// W4-S3: there is deliberately no persisted external-AI consent, participant or
// installation consent record, or revocation state. Permission to send
// screenshots to an external provider exists only per attempt, in memory, via
// the requester's `Use external AI` action. The pre-S3
// `commonplate.screenshotProposal.thirdPartyConsentRecorded` key may still sit
// in `UserDefaults` from an earlier build; nothing reads it, and it can never
// authorize a transfer.
import Foundation

protocol ScreenshotProposalPreferencesStoring: AnyObject {
    var isAIAssistanceEnabled: Bool { get set }
    var hasCompletedScreenshotHelp: Bool { get set }
}

final class UserDefaultsScreenshotProposalPreferencesStorage: ScreenshotProposalPreferencesStoring {
    private let defaults: UserDefaults
    private let enabledKey = "commonplate.screenshotProposal.aiAssistanceEnabled"
    private let helpCompletedKey = "commonplate.screenshotProposal.helpCompleted"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Defaults to available (`true`) when never set: the feature is
    /// discoverable, not opt-in-only. Being On authorizes nothing external:
    /// every external-AI transfer needs the requester's own per-attempt
    /// `Use external AI` action.
    var isAIAssistanceEnabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    /// Defaults to `false` when never set: education is shown until the
    /// requester actually completes it once.
    var hasCompletedScreenshotHelp: Bool {
        get { defaults.bool(forKey: helpCompletedKey) }
        set { defaults.set(newValue, forKey: helpCompletedKey) }
    }
}
