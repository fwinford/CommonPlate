//
//  ParticipantIdentityStore.swift
//  CommonPlateios
//
// Coordinates ParticipantVerificationService and installation-local storage,
// and updates state only after confirmed backend responses (W3-I1). Owns no
// SwiftUI screen; views call its operation-specific methods.
import Combine
import Foundation

/// The remembered identity, in the form a screen may render.
///
/// `masked` is the only spelling any view shows. The full principal stays
/// available for the one thing that needs it — prefilling nothing, comparing
/// nothing, just the Change Email flow's own confirmation — and the credential
/// is not here at all: it lives in private store state so it cannot reach
/// view-readable observable state, exactly like the raw claim token.
struct ParticipantIdentityPresentation: Equatable {
    let principal: String
    let masked: String
    let verifiedAt: Date
}

/// Where a verification flow currently is. `nil` is not a stage — a store with
/// no flow running has `flow == nil` — because "no flow" and "a flow at its
/// first step" are different things: only the second may show a form.
enum ParticipantVerificationStage: Equatable {
    /// Collecting the address. Reached by the first gate, and by Change Email.
    case enteringEmail
    /// A code has been mailed. Carries the backend's own deadlines rather than
    /// any locally computed ones.
    case awaitingCode(email: String, expiresAt: Date, resendAvailableAt: Date)
}

/// Why a verification flow is running. The two are not interchangeable: a
/// replacement must leave the current identity intact until it succeeds, and a
/// first verification has nothing to protect.
enum ParticipantVerificationPurpose: Equatable {
    case firstVerification
    case emailReplacement
}

/// The exact participant action that opened a first-verification flow.
///
/// This is deliberately operation identity, not navigation identity and not a
/// generic "resume after verification" flag. A requester operation carries a
/// fresh UUID; a helper operation carries both a fresh UUID and the exact
/// request it intends to claim. Only the initiating destination holds the same
/// value, so another mounted screen cannot consume identity becoming available.
enum ParticipantVerificationContinuation: Equatable {
    case requestCreation(operationID: UUID)
    case claim(requestID: String, operationID: UUID)
}

struct ParticipantVerificationFlow: Equatable {
    let purpose: ParticipantVerificationPurpose
    var stage: ParticipantVerificationStage
}

/// Copy-bearing presentation of a verification failure. The stable backend code
/// stays on the service error; only the sentence lives here.
enum ParticipantVerificationPresentationError: Equatable {
    case ineligibleEmail
    case resendTooSoon
    case codeIncorrect
    case codeExpired
    case codeNotRequested
    case attemptsExceeded
    case temporarilyUnavailable

    var message: String {
        switch self {
        case .ineligibleEmail:
            return NYUEmailPolicy.requiredMessage
        case .resendTooSoon:
            return "We just sent a code. Check your email, then try again in a moment."
        case .codeIncorrect:
            return "That code is incorrect. Check your email and try again."
        case .codeExpired:
            return "That code has expired. Send a new one."
        case .codeNotRequested:
            return "Send a code to this email first."
        case .attemptsExceeded:
            return "Too many incorrect codes. Send a new code to try again."
        case .temporarilyUnavailable:
            return "We couldn’t verify your email right now. Please try again in a moment."
        }
    }

    static func map(_ error: Error) -> ParticipantVerificationPresentationError {
        guard let serviceError = error as? ParticipantVerificationError else {
            return .temporarilyUnavailable
        }
        switch serviceError {
        case .ineligibleEmail:
            return .ineligibleEmail
        case .resendTooSoon:
            return .resendTooSoon
        case .codeIncorrect:
            return .codeIncorrect
        case .codeExpired:
            return .codeExpired
        case .codeNotRequested:
            return .codeNotRequested
        case .attemptsExceeded:
            return .attemptsExceeded
        case .temporarilyUnavailable, .couldNotReachBackend:
            return .temporarilyUnavailable
        }
    }
}

@MainActor
final class ParticipantIdentityStore: ObservableObject {
    /// The remembered verified identity, or `nil` when this installation has
    /// none. Presentation state: the backend remains authoritative, and
    /// `discardRejectedIdentity()` is how its verdict gets applied here.
    @Published private(set) var identity: ParticipantIdentityPresentation?

    /// The verification flow currently running, if any.
    @Published private(set) var flow: ParticipantVerificationFlow?

    /// One operation-scoped continuation at most. It survives code errors and
    /// retries, is consumed once after successful verification, and is retired
    /// by cancellation, abandonment, or a destination mismatch.
    @Published private(set) var pendingContinuation: ParticipantVerificationContinuation?

    @Published private(set) var isRequestingCode = false
    @Published private(set) var isSubmittingCode = false
    @Published private(set) var verificationError: ParticipantVerificationPresentationError?

    /// Set once when a stored identity is refused by the backend, so the
    /// verification screen can explain why it is asking again rather than
    /// appearing for no visible reason.
    @Published private(set) var wasIdentityRevoked = false

    var isVerified: Bool { identity != nil }

    private let service: ParticipantVerificationService
    private let storage: ParticipantIdentityStorage
    private let now: () -> Date

    /// The bearer credential. Private, and never published: view-readable state
    /// must not be able to leak it into a screenshot, a log, or a diagnostic
    /// dump — the same boundary `RequestStore` keeps around the raw claim token.
    private var authority: String?

    init(
        service: ParticipantVerificationService,
        storage: ParticipantIdentityStorage,
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.storage = storage
        self.now = now
        restoreRememberedIdentity()
    }

    /// The credential a participant action presents, or `nil` when this
    /// installation has none. `RequestStore` reads this and nothing else about
    /// identity, so the request flow cannot fabricate one.
    func currentAuthority() -> String? {
        authority
    }

    // MARK: - Remembered identity

    /// Restores a same-install identity at launch. Missing or unusable stored
    /// state simply leaves the app unverified — it is never repaired, guessed
    /// at, or partially restored.
    private func restoreRememberedIdentity() {
        guard let record = storage.loadValidIdentity() else {
            identity = nil
            authority = nil
            return
        }
        identity = Self.presentation(for: record)
        authority = record.authority
    }

    /// Applies a backend refusal of the stored credential.
    ///
    /// This is the only path by which client state loses an identity it did not
    /// itself replace, and it exists because the backend is authoritative: a
    /// credential it will not accept is not an identity, whatever this
    /// installation remembers. Any flow in progress is left alone — a
    /// replacement that is mid-verification is not invalidated by the old
    /// identity being refused.
    func discardRejectedIdentity() {
        guard identity != nil || authority != nil else { return }
        storage.clear()
        identity = nil
        authority = nil
        wasIdentityRevoked = true
    }

    /// Explicit participant-initiated local identity forgetting (W3-I4),
    /// distinct from `discardRejectedIdentity()`: that applies a backend
    /// refusal and sets `wasIdentityRevoked` so the next verification screen
    /// can explain why it is asking again. This is the student's own choice,
    /// not a refusal, so no such notice is raised — the installation simply
    /// becomes unverified, exactly as if it had never verified. Removal-
    /// safety gating (an active reservation, in-flight fulfillment, or an
    /// unresolved W3-D1 create) is the caller's responsibility; this clears
    /// only the installation-local participant credential and its
    /// presentation, reusing the same `storage.clear()` call
    /// `discardRejectedIdentity()` already uses. Guarded by `flow == nil`
    /// like `beginEmailReplacement()`, matching the existing precedent that
    /// Remove Email is never offered while a flow is running.
    func removeIdentity() {
        guard flow == nil, identity != nil || authority != nil else { return }
        storage.clear()
        identity = nil
        authority = nil
    }

    // MARK: - Verification flow

    /// Opens the verification flow for a participant action that needs it.
    /// Idempotent while a flow is already running, so a second gated tap does
    /// not restart the student's progress.
    func beginVerificationIfNeeded() {
        guard !isVerified, flow == nil, pendingContinuation == nil else { return }
        flow = ParticipantVerificationFlow(
            purpose: .firstVerification,
            stage: .enteringEmail
        )
        verificationError = nil
    }

    /// Opens first verification for one exact mutation. A competing operation
    /// cannot replace an in-progress one, even if both screens are mounted.
    @discardableResult
    func beginVerification(
        for continuation: ParticipantVerificationContinuation
    ) -> Bool {
        guard !isVerified, flow == nil, pendingContinuation == nil else {
            return false
        }
        pendingContinuation = continuation
        flow = ParticipantVerificationFlow(
            purpose: .firstVerification,
            stage: .enteringEmail
        )
        verificationError = nil
        return true
    }

    /// One-use handoff after verified identity exists. Equality is the whole
    /// authorization: a request-A continuation cannot be consumed by request B,
    /// and a duplicate callback loses because the value is cleared atomically
    /// on the main actor before the mutation task starts.
    func consumeContinuation(
        _ continuation: ParticipantVerificationContinuation
    ) -> Bool {
        guard isVerified,
              flow == nil,
              pendingContinuation == continuation else {
            return false
        }
        pendingContinuation = nil
        return true
    }

    /// Retires only the caller's own continuation. A stale destination cannot
    /// cancel a newer flow it does not own.
    func retireContinuation(
        _ continuation: ParticipantVerificationContinuation
    ) {
        guard pendingContinuation == continuation else { return }
        pendingContinuation = nil
        if flow?.purpose == .firstVerification {
            flow = nil
            verificationError = nil
            isRequestingCode = false
            isSubmittingCode = false
        }
    }

    /// Opens the Change Email flow. The current identity stays active and
    /// usable throughout: nothing is cleared here, and only a successful
    /// replacement verification changes it.
    func beginEmailReplacement() {
        guard flow == nil, pendingContinuation == nil else { return }
        flow = ParticipantVerificationFlow(
            purpose: .emailReplacement,
            stage: .enteringEmail
        )
        verificationError = nil
    }

    /// Abandons the running flow. A replacement abandoned here leaves the
    /// existing identity exactly as it was — abandonment is not a decision to
    /// stop being verified.
    func cancelVerification() {
        flow = nil
        pendingContinuation = nil
        verificationError = nil
        isRequestingCode = false
        isSubmittingCode = false
    }

    /// Acknowledges the "you need to verify again" explanation, so it is shown
    /// once rather than on every later visit.
    func acknowledgeRevocationNotice() {
        wasIdentityRevoked = false
    }

    /// Requests the emailed code for `email`. Refuses an obviously ineligible
    /// address locally, before spending a request on it; the backend remains
    /// authoritative and applies the identical allowlist.
    func requestCode(for email: String) async {
        guard flow != nil, !isRequestingCode, !isSubmittingCode else { return }
        let normalized = NYUEmailPolicy.normalize(email)
        guard NYUEmailPolicy.isAllowed(normalized) else {
            verificationError = .ineligibleEmail
            return
        }

        isRequestingCode = true
        verificationError = nil
        defer { isRequestingCode = false }

        do {
            let challenge = try await service.startVerification(email: normalized)
            guard flow != nil else { return }
            flow?.stage = .awaitingCode(
                email: normalized,
                expiresAt: challenge.expiresAt,
                resendAvailableAt: challenge.resendAvailableAt
            )
        } catch is CancellationError {
            return
        } catch {
            guard flow != nil else { return }
            verificationError = ParticipantVerificationPresentationError.map(error)
        }
    }

    /// Resends the code for the address already being verified. A refusal
    /// inside the cooldown is reported and changes nothing — deliberately not
    /// retried, because the point of the cooldown is that one address is not
    /// mailed repeatedly.
    func resendCode() async {
        guard case .awaitingCode(let email, _, _)? = flow?.stage else { return }
        guard !isRequestingCode, !isSubmittingCode else { return }

        isRequestingCode = true
        verificationError = nil
        defer { isRequestingCode = false }

        do {
            let challenge = try await service.startVerification(email: email)
            guard case .awaitingCode(let current, _, _)? = flow?.stage,
                  current == email else { return }
            flow?.stage = .awaitingCode(
                email: email,
                expiresAt: challenge.expiresAt,
                resendAvailableAt: challenge.resendAvailableAt
            )
        } catch is CancellationError {
            return
        } catch {
            guard case .awaitingCode? = flow?.stage else { return }
            verificationError = ParticipantVerificationPresentationError.map(error)
        }
    }

    /// Submits a code. Returns `true` only after the backend has established
    /// authority *and* it has been remembered — the one signal a caller may
    /// treat as "this student is now verified".
    ///
    /// Every failure path returns `false` and leaves the previous identity, if
    /// any, exactly as it was. A replacement that fails, expires, or is refused
    /// does not destroy the identity it was replacing.
    @discardableResult
    func submitCode(_ code: String) async -> Bool {
        guard case .awaitingCode(let email, _, _)? = flow?.stage else { return false }
        guard !isRequestingCode, !isSubmittingCode else { return false }

        isSubmittingCode = true
        verificationError = nil
        defer { isSubmittingCode = false }

        do {
            let verified = try await service.redeemVerification(
                email: email,
                code: code.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard case .awaitingCode(let current, _, _)? = flow?.stage,
                  current == email else {
                // The flow was cancelled or restarted under this call. The
                // backend did verify, but applying it now would replace an
                // identity the student has since moved away from.
                return false
            }
            guard adopt(verified) else {
                verificationError = .temporarilyUnavailable
                return false
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard case .awaitingCode? = flow?.stage else { return false }
            verificationError = ParticipantVerificationPresentationError.map(error)
            return false
        }
    }

    /// Writes the confirmed identity, then publishes it.
    ///
    /// Storage first, deliberately. If persisting failed after the app had
    /// already started acting verified, the student would be verified until the
    /// next launch and silently not afterwards; this way the remembered state
    /// and the in-memory state come from the same successful write.
    ///
    /// The previous credential is replaced, not merged — a Change Email leaves
    /// no way to keep acting as the old principal — while requests and claims
    /// already created stay bound to whoever created them, because those
    /// bindings live on the backend and nothing here touches them.
    @discardableResult
    private func adopt(_ verified: VerifiedParticipantIdentity) -> Bool {
        let record = ParticipantIdentityRecord(
            principal: NYUEmailPolicy.normalize(verified.principal),
            authority: verified.authority,
            verifiedAt: now()
        )
        guard storage.save(record) else { return false }
        authority = record.authority
        flow = nil
        // Publish identity last. A destination observing this change can now
        // consume its continuation immediately; it never sees verified
        // presentation paired with a still-running flow.
        identity = Self.presentation(for: record)
        verificationError = nil
        wasIdentityRevoked = false
        return true
    }

    private static func presentation(
        for record: ParticipantIdentityRecord
    ) -> ParticipantIdentityPresentation {
        ParticipantIdentityPresentation(
            principal: record.principal,
            masked: maskedAddress(record.principal),
            verifiedAt: record.verifiedAt
        )
    }

    /// A recognizable but not fully spelled-out address.
    ///
    /// Enough for the student to confirm *which* of their addresses this is —
    /// the whole point of showing it — without printing a full address onto a
    /// screen someone may be reading over their shoulder. The domain stays
    /// intact because it is not the identifying part and hiding it would make
    /// the line useless for telling `@nyu.edu` from `@stern.nyu.edu`.
    static func maskedAddress(_ principal: String) -> String {
        let normalized = NYUEmailPolicy.normalize(principal)
        guard let separator = normalized.lastIndex(of: "@"),
              separator != normalized.startIndex else {
            return normalized
        }
        let local = String(normalized[normalized.startIndex..<separator])
        let domain = String(normalized[separator...])
        let visibleCount = local.count > 2 ? 2 : 1
        let visible = String(local.prefix(visibleCount))
        let hidden = String(repeating: "•", count: max(local.count - visibleCount, 1))
        return "\(visible)\(hidden)\(domain)"
    }
}
