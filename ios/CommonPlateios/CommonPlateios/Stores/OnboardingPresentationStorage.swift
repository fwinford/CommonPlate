//
//  OnboardingPresentationStorage.swift
//  CommonPlateios
//
// The onboarding record is deliberately only a local presentation preference.
// It is not participant identity, a role, or backend authority.

import Combine
import Foundation
import SwiftUI

protocol OnboardingPresentationStoring: AnyObject {
    var hasCompletedOnboarding: Bool { get set }
}

final class UserDefaultsOnboardingPresentationStorage: OnboardingPresentationStoring {
    private let defaults: UserDefaults
    private let key = "commonplate.onboarding.completed"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}

@MainActor
final class OnboardingPresentationStore: ObservableObject {
    @Published private(set) var hasCompletedOnboarding: Bool

    private let storage: OnboardingPresentationStoring

    init(storage: OnboardingPresentationStoring) {
        self.storage = storage
        hasCompletedOnboarding = storage.hasCompletedOnboarding
    }

    func completeOnboarding() {
        storage.hasCompletedOnboarding = true
        hasCompletedOnboarding = true
    }
}

/// Owns the ephemeral navigation state above the chooser and walkthrough.
/// `continueFromWalkthrough()` deliberately clears the destination and changes
/// the root presentation state synchronously, rather than relying on a child
/// view's dismissal or an animation completion.
@MainActor
final class OnboardingFlowCoordinator: ObservableObject {
    @Published var selectedIntent: OnboardingIntent?
    @Published private(set) var isReplaying = false
    /// Presentation-only latch for the one completion transition. It is never
    /// persisted and never contributes to whether onboarding is complete.
    @Published private(set) var isCompletingOnboarding = false
    /// The outgoing screen retained only for the completion presentation.
    /// `selectedIntent` still clears synchronously, so this value owns no
    /// navigation or correctness state.
    @Published private(set) var completionPresentationIntent: OnboardingIntent?

    private let presentationStore: OnboardingPresentationStore

    init(presentationStore: OnboardingPresentationStore) {
        self.presentationStore = presentationStore
    }

    func beginReplay() {
        isCompletingOnboarding = false
        completionPresentationIntent = nil
        isReplaying = true
    }

    func replayNavigationChanged(isChooserInPath: Bool) {
        if !isChooserInPath && selectedIntent == nil && !isCompletingOnboarding {
            isReplaying = false
        }
    }

    func continueFromWalkthrough() {
        completionPresentationIntent = selectedIntent
        isCompletingOnboarding = true

        // The root replacement owns the visible completion transition. The
        // navigation destination still clears immediately, but doing so in a
        // disabled transaction prevents a native pop animation from competing
        // with that one root-level moment. Correctness remains entirely
        // synchronous and does not wait for either presentation to finish.
        var navigationClearTransaction = Transaction()
        navigationClearTransaction.disablesAnimations = true
        withTransaction(navigationClearTransaction) {
            selectedIntent = nil
        }

        if !presentationStore.hasCompletedOnboarding {
            presentationStore.completeOnboarding()
        }
        isReplaying = false
    }

    func finishCompletionPresentation() {
        completionPresentationIntent = nil
        isCompletingOnboarding = false
    }
}
