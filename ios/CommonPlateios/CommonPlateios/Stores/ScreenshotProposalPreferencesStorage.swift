//
//  ScreenshotProposalPreferencesStorage.swift
//  CommonPlateios
//
// W4-S1 local presentation/consent preferences only — not participant
// identity, not backend authority, and not itself an AI Assistance Settings
// UI implementation. `isAIAssistanceEnabled` is the app-level kill switch:
// Off prevents any provider transfer regardless of consent history.
// `hasRecordedThirdPartyConsent` is the first-use OpenAI-transfer disclosure
// acceptance; once recorded, normal repeat use is not re-disclosed.
import Foundation

protocol ScreenshotProposalPreferencesStoring: AnyObject {
    var isAIAssistanceEnabled: Bool { get set }
    var hasRecordedThirdPartyConsent: Bool { get set }
}

final class UserDefaultsScreenshotProposalPreferencesStorage: ScreenshotProposalPreferencesStoring {
    private let defaults: UserDefaults
    private let enabledKey = "commonplate.screenshotProposal.aiAssistanceEnabled"
    private let consentKey = "commonplate.screenshotProposal.thirdPartyConsentRecorded"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Defaults to available (`true`) when never set: the feature is
    /// discoverable, not opt-in-only. Every use still requires the separate
    /// first-use consent gate below before any screenshot leaves the device.
    var isAIAssistanceEnabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    var hasRecordedThirdPartyConsent: Bool {
        get { defaults.bool(forKey: consentKey) }
        set { defaults.set(newValue, forKey: consentKey) }
    }
}
