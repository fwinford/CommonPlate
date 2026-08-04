//
//  AlertSubscriptionStore.swift
//  CommonPlateios
//
// The one state owner for email alert signup. Coordinates
// AlertSubscriptionService and updates local state only after a confirmed
// backend response, per docs/system-contract.md. Owns no SwiftUI screen.
//
// Deliberately not part of RequestStore: alert signup is not a request
// operation, shares none of its collection, claim, or placement state, and
// must never inherit request-shaped error recovery. There is exactly one owner
// here — no separate view model sits beside it.
//
// Nothing here is persisted. The accepted state lasts for this session only;
// surviving relaunch is a separate, later slice with its own contract.
import Combine
import Foundation

/// Where the signup screen is in the flow. `checkEmail` is the transient
/// presentation of the backend's generic accepted response and asserts nothing
/// about subscription status.
enum AlertSignupPhase: Equatable {
    case editing
    case submitting
    case checkEmail
}

/// A failure that belongs beside the email field, because the address itself is
/// what has to change.
enum AlertSignupFieldError: Equatable {
    case invalidNYUEmail
}

/// A failure that belongs to the screen rather than to the address. Each case
/// exists because its honest next step differs from the others'.
enum AlertSignupFailure: Equatable {
    /// Signup is closed on the backend. Not an address problem.
    case paused
    /// Too many attempts from here. Waiting is the only next step.
    case rateLimited
    /// The confirmation email could not be started. Signup did not succeed, and
    /// an explicit manual retry is appropriate.
    case confirmationEmailUnavailable
    /// Receipt is uncertain. Never retried automatically, and never described
    /// as either success or failure.
    case ambiguousOutcome
    /// Bounded generic failure. Definitive, with nothing specific to offer.
    case unknown
}

@MainActor
final class AlertSubscriptionStore: ObservableObject {
    @Published private(set) var phase: AlertSignupPhase = .editing
    @Published private(set) var fieldError: AlertSignupFieldError?
    @Published private(set) var failure: AlertSignupFailure?
    /// The address as typed. Owned here rather than by the screen so that
    /// changing addresses is one state transition instead of two that can
    /// drift apart. It is draft text only and asserts nothing about any
    /// subscription; like the rest of this store it is never persisted.
    @Published private(set) var email: String = ""

    private let service: AlertSubscriptionService

    init(service: AlertSubscriptionService) {
        self.service = service
    }

    var isSubmitting: Bool {
        phase == .submitting
    }

    /// Records what the person has typed. Presentation state is deliberately
    /// left alone: when an error is cleared is existing accepted behavior and
    /// is not what this slice changes.
    func updateEmail(_ value: String) {
        email = value
    }

    /// `POST /api/subscribe`, at most once at a time and never retried
    /// automatically.
    ///
    /// A locally unusable address is refused here, before any request is
    /// started. The accepted phase is entered only on the backend's confirmed
    /// generic acceptance, and even then records nothing about the subscriber's
    /// actual status, because that response cannot report one.
    func submit(email: String) async {
        // A repeated tap while a signup is in flight, or after one has been
        // accepted, must not start a second POST: signup is a mutation, and
        // the backend's generic response gives the client nothing with which to
        // reconcile a duplicate.
        guard phase == .editing else { return }

        // The submitted address is the field's value. The screen already passes
        // what it holds, so this only keeps the owner authoritative for callers
        // that submit an address directly.
        self.email = email

        guard AlertSignupEmailValidator.isAllowedNYUEmail(email) else {
            fieldError = .invalidNYUEmail
            failure = nil
            return
        }

        phase = .submitting
        fieldError = nil
        failure = nil

        do {
            try await service.subscribe(email: AlertSignupEmailValidator.normalize(email))
            phase = .checkEmail
        } catch {
            phase = .editing
            apply(error)
        }
    }

    /// Returns to the editable form for this session with an empty field.
    ///
    /// It clears presentation only: there is no local subscription truth to
    /// discard, because none was ever recorded. The previous address is not
    /// unsubscribed, cancelled, or altered on the backend — nothing is sent —
    /// and whatever the backend already did with it stands.
    ///
    /// The field is emptied because entering a different address is the whole
    /// point of the action; leaving the previous one in place invites
    /// resubmitting the address the person just chose to move on from.
    func useDifferentEmail() {
        guard phase == .checkEmail else { return }
        phase = .editing
        email = ""
        fieldError = nil
        failure = nil
    }

    private func apply(_ error: Error) {
        guard let subscriptionError = error as? AlertSubscriptionError else {
            failure = .unknown
            return
        }

        switch subscriptionError {
        case .invalidEmail:
            // The backend is authoritative on the allowlist, so its refusal is
            // shown against the field exactly as a local one is.
            fieldError = .invalidNYUEmail
        case .publicActionsPaused:
            failure = .paused
        case .rateLimited:
            failure = .rateLimited
        case .confirmationEmailUnavailable:
            failure = .confirmationEmailUnavailable
        case .ambiguousSignupOutcome:
            failure = .ambiguousOutcome
        case .unknownFailure:
            failure = .unknown
        }
    }
}
