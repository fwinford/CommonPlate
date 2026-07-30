//
//  RequestStore.swift
//  CommonPlateios
//
//  Created by faith on 7/13/26.
//
// Coordinates RequestService calls and updates local state only after
// confirmed backend responses, per docs/week-2-integration-spec.md. Owns no
// SwiftUI screen; views call its operation-specific methods.
import Combine
import Foundation

/// View-readable, non-secret presentation for the helper's active claim. The
/// matching raw token lives only in `RequestStore`'s private authorization
/// record. Both are discarded naturally on app restart and cleared together
/// when the flow ends. Week 2 does not implement durable claim recovery.
///
/// Every timestamp here is backend-owned. `claimExpiresAt` advances only when
/// the extension endpoint confirms a new deadline; `requestExpiresAt` is the
/// request's own availability deadline, kept so the client can tell in advance
/// that a full five-minute extension cannot fit and skip a prompt that could
/// only fail.
struct ActiveClaimPresentation {
    /// The confirmed public request this claim reserves, exactly as the claim
    /// response returned it. Held so the claimant flow can be re-entered from
    /// Active Requests after the detail screen that started the claim is gone —
    /// including a claim that confirmed late — without re-fetching, re-claiming,
    /// or depending on the request still appearing in the public collection.
    let request: FoodRequest
    let pickupName: String
    fileprivate(set) var claimExpiresAt: Date
    fileprivate(set) var claimExtendedAt: Date?
    fileprivate(set) var isExtensionAvailable: Bool

    var requestID: String {
        request.id
    }

    var requestExpiresAt: Date {
        request.expiresAt
    }

    /// The one permitted extension has been granted, so no further prompt or
    /// extension request may be made.
    var hasUsedExtension: Bool {
        claimExtendedAt != nil
    }
}

/// Store-only authorization for the active claim. This is deliberately private
/// so the raw token cannot enter view-readable observable state.
private struct ActiveClaimAuthorization {
    let claimID: UUID
    let requestID: String
    let claimToken: String
}

private struct ClaimAttempt: Equatable {
    let id: UUID
    let requestID: String
}

private struct ClaimExtensionAttempt: Equatable {
    let id: UUID
    let claimID: UUID
    let requestID: String
    let originalExpiration: Date
}

/// Backend-confirmed reasons a helper cannot start (or continue) helping with a
/// request. Each carries the same recovery — leave the stale screen and return
/// to a refreshed Active Requests list — because in every case the backend has
/// already decided the answer and no client state can override it.
enum ClaimUnavailableReason: Equatable {
    /// HTTP 409 `REQUEST_ALREADY_CLAIMED`. Locked product copy; another helper
    /// won the race.
    case alreadyClaimed
    /// `REQUEST_EXPIRED`, `REQUEST_INSUFFICIENT_TIME`, `REQUEST_ALREADY_PLACED`,
    /// or `REQUEST_NOT_FOUND` — grouped because the helper's next step is
    /// identical and the distinction is not theirs to act on. The backend code
    /// stays available on the request-scoped event for diagnosis.
    case noLongerAvailable
    /// The reservation ran out while the helper was in the fulfillment flow.
    case claimExpired
}

struct ClaimErrorEvent: Identifiable {
    let id: UUID
    let requestID: String
    let claimAttemptID: UUID
    let backendCode: String?
    let error: RequestServiceError
}

struct ClaimUnavailableNotice: Identifiable, Equatable {
    let id: UUID
    let requestID: String
    let operationID: UUID
    let backendCode: String?
    let reason: ClaimUnavailableReason
}

/// Backend stable error codes for the accepted Day 4 claim and extension
/// routes (docs/week-2-integration-spec.md, "Error contract"). Kept as one
/// list so code handling cannot drift into scattered string literals.
enum ClaimErrorCode {
    static let invalidRequestID = "INVALID_REQUEST_ID"
    static let requestNotFound = "REQUEST_NOT_FOUND"
    static let requestAlreadyClaimed = "REQUEST_ALREADY_CLAIMED"
    static let requestAlreadyPlaced = "REQUEST_ALREADY_PLACED"
    static let requestExpired = "REQUEST_EXPIRED"
    static let requestInsufficientTime = "REQUEST_INSUFFICIENT_TIME"
    static let requestNotClaimed = "REQUEST_NOT_CLAIMED"
    static let invalidClaimToken = "INVALID_CLAIM_TOKEN"
    static let claimExpired = "CLAIM_EXPIRED"
    static let claimExtensionAlreadyUsed = "CLAIM_EXTENSION_ALREADY_USED"
    static let claimExtensionInsufficientTime = "CLAIM_EXTENSION_INSUFFICIENT_TIME"
    static let publicActionsPaused = "PUBLIC_ACTIONS_PAUSED"
    static let rateLimited = "RATE_LIMITED"
    static let internalFailure = "INTERNAL_FAILURE"
}

/// Whether `POST /api/request` may be offered to the requester, as resolved
/// from `GET /api/public-actions`.
///
/// Deliberately narrow: this describes request creation only. It is not an
/// app-wide configuration cache, and no other flow reads it. Presentation is
/// fail-closed — `.unknown`, `.paused`, and `.unavailable` all mean the
/// requester form must not be shown, and only `.available` may reveal it.
/// `.paused` and `.unavailable` stay distinct because the product must not
/// claim posting is paused when it simply could not find out.
enum RequestCreationAvailability: Equatable {
    /// No answer yet: the probe has not run, is running, or was cancelled.
    case unknown
    /// The backend reported `paused: false`.
    case available
    /// The backend reported `paused: true`.
    case paused
    /// The probe failed, returned a non-success status, or could not be decoded.
    case unavailable
}

@MainActor
final class RequestStore: ObservableObject {
    @Published private(set) var requests: [FoodRequest] = []

    /// False until `GET /api/requests` has returned successfully at least once.
    /// This remains false after an initial failure, but becomes true for a
    /// successful empty response.
    @Published private(set) var hasSuccessfullyFetchedRequests = false

    /// True once `fetchRequests()` has been entered at least once, regardless of
    /// how that fetch ended. Separates "no fetch has been attempted yet" from
    /// "a fetch finished without producing a usable collection". The second case
    /// publishes no error — it happens when a fetch is cancelled, or when its
    /// snapshot is ignored because a confirmed mutation advanced
    /// `collectionRevision` — so callers cannot rely on `initialFetchError`
    /// alone to decide whether recovery should be offered.
    @Published private(set) var hasAttemptedRequestFetch = false
    @Published private(set) var isLoadingInitialRequests = false
    @Published private(set) var isRefreshingRequests = false
    @Published private(set) var initialFetchError: RequestServiceError?
    @Published private(set) var refreshError: RequestServiceError?

    /// Fail-closed availability of request creation. Starts `.unknown` so a
    /// screen that has not yet probed cannot reveal the requester form.
    @Published private(set) var requestCreationAvailability: RequestCreationAvailability = .unknown

    @Published private(set) var isCreating = false
    @Published private(set) var createError: RequestServiceError?

    @Published private(set) var isClaiming = false
    @Published private(set) var claimErrorEvent: ClaimErrorEvent?

    /// Set when the backend confirms the helper cannot have this request. The
    /// detail flow watches it to leave, and Active Requests watches it to show
    /// the notice — so the message survives the screen that caused it.
    @Published private(set) var claimUnavailableNotice: ClaimUnavailableNotice?

    @Published private(set) var isExtendingClaim = false
    @Published private(set) var claimExtensionError: RequestServiceError?

    /// Whether the one-time "Still ordering?" prompt is currently offered.
    @Published private(set) var isShowingClaimExtensionPrompt = false

    /// True once the prompt has been answered, extended, or ruled out. The
    /// prompt is never offered a second time for the same claim.
    @Published private(set) var hasResolvedClaimExtensionPrompt = false

    @Published private(set) var isFulfilling = false
    @Published private(set) var fulfillError: RequestServiceError?
    @Published private(set) var confirmedFulfillmentOutcome: FulfillOutcome?

    /// Non-secret presentation for the helper's active claim, if any. The
    /// matching raw token is held separately in private store-only state.
    @Published private(set) var activeClaim: ActiveClaimPresentation?

    private let service: RequestService
    private var fetchGeneration = 0
    private var collectionRevision = 0
    private var isCheckingRequestCreationAvailability = false
    private var activeClaimAuthorization: ActiveClaimAuthorization?
    private var activeClaimAttempt: ClaimAttempt?
    private var activeClaimExtensionAttempt: ClaimExtensionAttempt?

    /// One local timer per active claim, scheduled from the backend's
    /// `claimExpiresAt`. It replaces polling entirely: nothing is re-fetched to
    /// discover the prompt moment or the expiration moment.
    private var claimLifecycleTask: Task<Void, Never>?

    /// How far ahead of the reservation deadline the one-time prompt appears.
    static let claimExtensionPromptLead: TimeInterval = 3 * 60

    /// The extension the backend grants, used only to decide in advance whether
    /// a full extension could fit before the request's own `expiresAt`. The
    /// backend re-checks this and remains authoritative.
    static let claimExtensionDuration: TimeInterval = 5 * 60

    init(service: RequestService) {
        self.service = service
    }

    var isFetching: Bool {
        isLoadingInitialRequests || isRefreshingRequests
    }

    /// `GET /api/requests`. Before the first successful response this is an
    /// initial load (including retries after an initial failure). Later calls
    /// are refreshes that preserve the current collection until success.
    func fetchRequests() async {
        hasAttemptedRequestFetch = true
        fetchGeneration += 1
        let generation = fetchGeneration
        let startingCollectionRevision = collectionRevision
        let isRefresh = hasSuccessfullyFetchedRequests

        if isRefresh {
            isRefreshingRequests = true
            refreshError = nil
        } else {
            isLoadingInitialRequests = true
            initialFetchError = nil
        }

        defer {
            if generation == fetchGeneration {
                if isRefresh {
                    isRefreshingRequests = false
                } else {
                    isLoadingInitialRequests = false
                }
            }
        }

        do {
            let fetchedRequests = try await service.fetchActiveRequests()
            guard generation == fetchGeneration,
                  startingCollectionRevision == collectionRevision else {
                return
            }
            requests = fetchedRequests
            hasSuccessfullyFetchedRequests = true
            if isRefresh {
                refreshError = nil
            } else {
                initialFetchError = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == fetchGeneration,
                  startingCollectionRevision == collectionRevision else {
                return
            }
            if isRefresh {
                refreshError = Self.asServiceError(error)
            } else {
                initialFetchError = Self.asServiceError(error)
            }
        }
    }

    /// `GET /api/public-actions`. Resolves whether the requester form may be
    /// shown at all.
    ///
    /// Fail-closed in both directions: the state is reset to `.unknown` before
    /// the probe starts, so a screen can never keep showing the form on the
    /// strength of an earlier answer, and every failure — transport, non-2xx,
    /// or an undecodable body — resolves to `.unavailable` rather than
    /// `.available`. A cancelled probe returns to `.unknown` instead, because
    /// cancellation is not evidence that posting is unavailable; both states
    /// withhold the form, so nothing is revealed either way.
    ///
    /// A concurrent second call is dropped rather than restarting the probe,
    /// so a redraw cannot reset a check that is already in flight.
    func refreshRequestCreationAvailability() async {
        guard !isCheckingRequestCreationAvailability else {
            return
        }
        isCheckingRequestCreationAvailability = true
        requestCreationAvailability = .unknown
        defer { isCheckingRequestCreationAvailability = false }

        do {
            let paused = try await service.fetchPublicActionsPaused()
            requestCreationAvailability = paused ? .paused : .available
        } catch is CancellationError {
            requestCreationAvailability = .unknown
        } catch {
            requestCreationAvailability = .unavailable
        }
    }

    /// `POST /api/request`. Not automatically retried on failure, including
    /// when the service reports an ambiguous create outcome. Returns normally
    /// only after the confirmed request has been added to local state.
    func createRequest(_ payload: CreateRequestPayload) async throws {
        guard !isCreating else {
            throw RequestServiceError.operationInProgress
        }
        isCreating = true
        createError = nil
        defer { isCreating = false }
        do {
            let created = try await service.createRequest(payload)
            advanceCollectionRevision()
            applyConfirmed(created)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let serviceError = Self.asServiceError(error)
            createError = serviceError
            throw serviceError
        }
    }

    /// `POST /api/request/:id/claim`. Local list state and the in-memory
    /// active claim are updated only after the backend confirms the claim.
    /// An ambiguous response never fabricates claim credentials. Returns
    /// normally only after both confirmed request and claim state are updated,
    /// which is also the only point at which the pickup name becomes readable
    /// anywhere in the app.
    ///
    /// A duplicate call while one is in flight throws `operationInProgress`
    /// before any second request is built, so repeated taps cannot produce a
    /// second claim POST.
    ///
    /// Only one confirmed claim may be held locally at a time. A second claim
    /// is refused because `beginActiveClaim` would otherwise replace the first
    /// claim's presentation, its private token, and its lifecycle timer,
    /// leaving that request reserved on the backend with no local claimant
    /// state and no way to reach its pickup name. Week 2 has no release
    /// endpoint, so the only safe answer is not to start the second claim.
    /// Returning to the active request still routes into its existing flow
    /// through `activeClaim`, which needs no new claim call.
    ///
    /// The refusal is reported as `existingActiveClaim` when the held claim
    /// belongs to a *different* request, so the helper can be pointed at the
    /// reservation they actually hold instead of being told they are already
    /// starting to help with the request in front of them.
    func claim(requestID: String) async throws {
        if let activeClaim {
            throw activeClaim.requestID == requestID
                ? RequestServiceError.operationInProgress
                : RequestServiceError.existingActiveClaim
        }
        guard !isClaiming else {
            throw RequestServiceError.operationInProgress
        }
        let attempt = ClaimAttempt(id: UUID(), requestID: requestID)
        activeClaimAttempt = attempt
        isClaiming = true
        if claimErrorEvent?.requestID == requestID {
            claimErrorEvent = nil
        }
        defer {
            if activeClaimAttempt == attempt {
                activeClaimAttempt = nil
                isClaiming = false
            }
        }
        do {
            let outcome = try await service.claimRequest(id: requestID)
            guard activeClaimAttempt == attempt else {
                return
            }
            advanceCollectionRevision()
            applyConfirmed(outcome.request)
            beginActiveClaim(
                presentation: ActiveClaimPresentation(
                    request: outcome.request,
                    pickupName: outcome.pickupName,
                    claimExpiresAt: outcome.claimExpiresAt,
                    claimExtendedAt: nil,
                    isExtensionAvailable: true
                ),
                authorization: ActiveClaimAuthorization(
                    claimID: UUID(),
                    requestID: outcome.request.id,
                    claimToken: outcome.claimToken
                )
            )
        } catch is CancellationError {
            guard activeClaimAttempt == attempt else {
                return
            }
            throw CancellationError()
        } catch {
            guard activeClaimAttempt == attempt else {
                return
            }
            let serviceError = Self.asServiceError(error)
            let backendCode = Self.backendCode(for: serviceError)
            claimErrorEvent = ClaimErrorEvent(
                id: UUID(),
                requestID: requestID,
                claimAttemptID: attempt.id,
                backendCode: backendCode,
                error: serviceError
            )
            if let reason = Self.unavailableReason(for: serviceError) {
                reportClaimUnavailable(
                    reason,
                    requestID: requestID,
                    operationID: attempt.id,
                    backendCode: backendCode
                )
            }
            throw serviceError
        }
    }

    /// `POST /api/request/:id/claim/extend`, sending the active claim's raw
    /// token. Answering the prompt resolves it either way, so a failed or
    /// unconfirmed attempt cannot re-open the prompt into a retry loop, and
    /// the local expiration advances only on a confirmed backend response.
    func extendActiveClaim() async {
        guard !isExtendingClaim,
              activeClaimExtensionAttempt == nil,
              let claim = activeClaim,
              claim.isExtensionAvailable,
              let authorization = activeClaimAuthorization,
              authorization.requestID == claim.requestID else {
            return
        }
        let attempt = ClaimExtensionAttempt(
            id: UUID(),
            claimID: authorization.claimID,
            requestID: authorization.requestID,
            originalExpiration: claim.claimExpiresAt
        )
        activeClaimExtensionAttempt = attempt
        isExtendingClaim = true
        claimExtensionError = nil
        resolveClaimExtensionPrompt()
        claimLifecycleTask?.cancel()
        claimLifecycleTask = nil
        defer {
            if activeClaimExtensionAttempt == attempt {
                activeClaimExtensionAttempt = nil
                isExtendingClaim = false
            }
        }

        do {
            let outcome = try await service.extendClaim(
                id: authorization.requestID,
                claimToken: authorization.claimToken
            )
            guard extensionAttemptIsCurrent(attempt),
                  var current = activeClaim else {
                return
            }
            current.claimExpiresAt = outcome.claimExpiresAt
            current.claimExtendedAt = outcome.claimExtendedAt
            current.isExtensionAvailable = false
            activeClaim = current
            guard finishExtensionAttempt(attempt) else {
                return
            }
            // The reservation moved, so the expiration timer is rescheduled
            // against the new backend deadline. No further prompt is possible.
            startClaimLifecycleTimer()
        } catch {
            guard extensionAttemptIsCurrent(attempt) else {
                return
            }
            let serviceError = Self.asServiceError(error)
            claimExtensionError = serviceError
            applyExtensionFailure(serviceError, for: attempt)
            guard finishExtensionAttempt(attempt) else {
                return
            }
            resumeLifecycleAfterFailedExtension(attempt)
        }
    }

    /// The helper declined the prompt. The claim continues untouched; only the
    /// prompt is retired so it cannot reappear.
    func dismissClaimExtensionPrompt() {
        resolveClaimExtensionPrompt()
    }

    /// Ends the claim locally: the in-memory claim and its raw token are
    /// dropped, the local timer is cancelled, and Active Requests is refreshed
    /// from backend truth. Week 2 has no release endpoint, so this abandons the
    /// reservation locally rather than returning it — the backend reopens it on
    /// its own schedule when the claim lapses.
    ///
    /// Deliberately **not** wired to Back or a swipe dismissal. Leaving the
    /// claimant screen is navigation, not a decision to give up a reservation
    /// the backend still holds; dropping the pickup name and token there left
    /// the request blocked for every other helper with no local way back in.
    /// This stays the seam for an explicit end-of-flow action — today only the
    /// tests exercise it — and Day 5 fulfillment clears the same state through
    /// `clearActiveClaim` after confirmed placement.
    func leaveActiveClaimFlow() {
        clearActiveClaim()
        refreshRequestsAfterClaimConflict()
    }

    /// Clears the notice once the helper has seen it on Active Requests.
    func acknowledgeClaimUnavailableNotice(id: UUID) {
        guard claimUnavailableNotice?.id == id else {
            return
        }
        claimUnavailableNotice = nil
    }

    // MARK: - Active-claim lifecycle

    private func beginActiveClaim(
        presentation: ActiveClaimPresentation,
        authorization: ActiveClaimAuthorization
    ) {
        claimLifecycleTask?.cancel()
        invalidateActiveExtensionAttempt()
        activeClaim = presentation
        activeClaimAuthorization = authorization
        claimExtensionError = nil
        isShowingClaimExtensionPrompt = false
        hasResolvedClaimExtensionPrompt = false
        startClaimLifecycleTimer()
    }

    private func clearActiveClaim() {
        claimLifecycleTask?.cancel()
        claimLifecycleTask = nil
        invalidateActiveExtensionAttempt()
        activeClaim = nil
        activeClaimAuthorization = nil
        isShowingClaimExtensionPrompt = false
        hasResolvedClaimExtensionPrompt = false
        claimExtensionError = nil
    }

    private func invalidateActiveExtensionAttempt() {
        activeClaimExtensionAttempt = nil
        isExtendingClaim = false
    }

    private func extensionAttemptIsCurrent(_ attempt: ClaimExtensionAttempt) -> Bool {
        activeClaimExtensionAttempt == attempt
            && activeClaimAuthorization?.claimID == attempt.claimID
            && activeClaimAuthorization?.requestID == attempt.requestID
            && activeClaim?.requestID == attempt.requestID
    }

    private func finishExtensionAttempt(_ attempt: ClaimExtensionAttempt) -> Bool {
        guard extensionAttemptIsCurrent(attempt) else {
            return false
        }
        activeClaimExtensionAttempt = nil
        isExtendingClaim = false
        return true
    }

    /// Schedules the prompt moment and the expiration moment from the backend's
    /// `claimExpiresAt`. Device time is used only to decide *when* to run these
    /// local UI steps — it never decides whether a claim is valid, which stays
    /// the backend's answer on the next mutation.
    ///
    /// Day 5 requirement: this timer is the only thing that ends a claim
    /// locally, and it is not revalidated when the app returns to the
    /// foreground. If the sleep resumes late, the reservation deadline stays on
    /// screen past its expiry. Today that is only a wrong sentence, because the
    /// claimant screen cannot submit an order. Before real ordering ships,
    /// re-check `activeClaim.claimExpiresAt` against wall-clock time on
    /// `scenePhase == .active` — expiring immediately if it has passed and
    /// rescheduling otherwise — so no order can be placed against a lapsed
    /// reservation.
    private func startClaimLifecycleTimer() {
        claimLifecycleTask?.cancel()
        guard let claim = activeClaim,
              let authorization = activeClaimAuthorization,
              authorization.requestID == claim.requestID,
              activeClaimExtensionAttempt == nil else {
            claimLifecycleTask = nil
            return
        }
        let claimID = authorization.claimID
        let requestID = claim.requestID
        let expiration = claim.claimExpiresAt
        let promptMoment = expiration.addingTimeInterval(-Self.claimExtensionPromptLead)

        claimLifecycleTask = Task { [weak self] in
            if let interval = Self.secondsUntil(promptMoment) {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.presentClaimExtensionPromptIfEligible(
                claimID: claimID,
                requestID: requestID,
                expiration: expiration
            )

            if let interval = Self.secondsUntil(expiration) {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.markActiveClaimExpired(
                claimID: claimID,
                requestID: requestID,
                expiration: expiration
            )
        }
    }

    /// Nil when the moment has already passed, so the caller acts immediately
    /// instead of sleeping a negative duration.
    private static func secondsUntil(_ moment: Date) -> TimeInterval? {
        let interval = moment.timeIntervalSinceNow
        return interval > 0 ? interval : nil
    }

    private func presentClaimExtensionPromptIfEligible(
        claimID: UUID,
        requestID: String,
        expiration: Date
    ) {
        guard let claim = activeClaim,
              activeClaimAuthorization?.claimID == claimID,
              claim.requestID == requestID,
              claim.claimExpiresAt == expiration,
              claim.isExtensionAvailable,
              activeClaimExtensionAttempt == nil,
              !hasResolvedClaimExtensionPrompt else {
            return
        }
        // A prompt the backend is guaranteed to refuse is worse than no prompt:
        // extension is granted only when a full five minutes still fits inside
        // the request's own expiration.
        guard claim.claimExpiresAt.addingTimeInterval(Self.claimExtensionDuration)
                <= claim.requestExpiresAt else {
            hasResolvedClaimExtensionPrompt = true
            var resolvedClaim = claim
            resolvedClaim.isExtensionAvailable = false
            activeClaim = resolvedClaim
            return
        }
        isShowingClaimExtensionPrompt = true
    }

    private func markActiveClaimExpired(
        claimID: UUID,
        requestID: String,
        expiration: Date
    ) {
        guard let claim = activeClaim,
              activeClaimAuthorization?.claimID == claimID,
              claim.requestID == requestID,
              claim.claimExpiresAt == expiration,
              activeClaimExtensionAttempt == nil else {
            return
        }
        clearActiveClaim()
        reportClaimUnavailable(
            .claimExpired,
            requestID: requestID,
            operationID: claimID,
            backendCode: ClaimErrorCode.claimExpired
        )
    }

    private func resolveClaimExtensionPrompt() {
        isShowingClaimExtensionPrompt = false
        hasResolvedClaimExtensionPrompt = true
        if var claim = activeClaim {
            claim.isExtensionAvailable = false
            activeClaim = claim
        }
    }

    /// Applies the backend's verdict on a failed extension. Nothing here grants
    /// time; the worst case leaves the helper on the deadline they already had.
    private func applyExtensionFailure(
        _ error: RequestServiceError,
        for attempt: ClaimExtensionAttempt
    ) {
        guard case .serverError(let code, _) = error else {
            // Ambiguous or transport failure: the extension may or may not have
            // been applied, so the known-safe (earlier) deadline is kept and no
            // retry is offered.
            return
        }

        switch code {
        case ClaimErrorCode.claimExpired,
             ClaimErrorCode.invalidClaimToken,
             ClaimErrorCode.requestNotClaimed:
            // The reservation is no longer ours; treat it exactly like running
            // out of time rather than leaving a dead claim on screen.
            guard extensionAttemptIsCurrent(attempt) else { return }
            clearActiveClaim()
            reportClaimUnavailable(
                .claimExpired,
                requestID: attempt.requestID,
                operationID: attempt.claimID,
                backendCode: code
            )
        case ClaimErrorCode.requestAlreadyPlaced,
             ClaimErrorCode.requestExpired,
             ClaimErrorCode.requestNotFound:
            guard extensionAttemptIsCurrent(attempt) else { return }
            clearActiveClaim()
            reportClaimUnavailable(
                .noLongerAvailable,
                requestID: attempt.requestID,
                operationID: attempt.claimID,
                backendCode: code
            )
        case ClaimErrorCode.claimExtensionAlreadyUsed:
            // The backend already granted the one extension; stop offering it
            // without inventing a timestamp or a new local deadline.
            guard extensionAttemptIsCurrent(attempt), var current = activeClaim else { return }
            current.isExtensionAvailable = false
            activeClaim = current
        default:
            // Insufficient time, paused, rate limited, internal failure: the
            // current reservation still stands and the prompt stays retired.
            break
        }
    }

    private func resumeLifecycleAfterFailedExtension(_ attempt: ClaimExtensionAttempt) {
        guard activeClaimExtensionAttempt == nil,
              activeClaimAuthorization?.claimID == attempt.claimID,
              activeClaimAuthorization?.requestID == attempt.requestID,
              activeClaim?.requestID == attempt.requestID,
              activeClaim?.claimExpiresAt == attempt.originalExpiration else {
            return
        }
        if attempt.originalExpiration <= Date() {
            markActiveClaimExpired(
                claimID: attempt.claimID,
                requestID: attempt.requestID,
                expiration: attempt.originalExpiration
            )
        } else {
            startClaimLifecycleTimer()
        }
    }

    // MARK: - Claim conflicts

    /// Maps a confirmed backend rejection of a claim attempt. `nil` means the
    /// helper stays on the detail screen (paused, rate limited, transient
    /// failure, or an outcome iOS could not confirm) rather than being sent
    /// back as though the request were gone.
    static func unavailableReason(for error: RequestServiceError) -> ClaimUnavailableReason? {
        switch error {
        case .notFound:
            return .noLongerAvailable
        case .serverError(let code, _):
            switch code {
            case ClaimErrorCode.requestAlreadyClaimed:
                return .alreadyClaimed
            case ClaimErrorCode.requestExpired,
                 ClaimErrorCode.requestInsufficientTime,
                 ClaimErrorCode.requestAlreadyPlaced,
                 ClaimErrorCode.requestNotFound:
                return .noLongerAvailable
            default:
                return nil
            }
        default:
            return nil
        }
    }

    func claimError(for requestID: String) -> RequestServiceError? {
        guard claimErrorEvent?.requestID == requestID else {
            return nil
        }
        return claimErrorEvent?.error
    }

    func isClaiming(requestID: String) -> Bool {
        isClaiming && activeClaimAttempt?.requestID == requestID
    }

    private static func backendCode(for error: RequestServiceError) -> String? {
        switch error {
        case .serverError(let code, _):
            return code
        case .notFound:
            return ClaimErrorCode.requestNotFound
        default:
            return nil
        }
    }

    private func reportClaimUnavailable(
        _ reason: ClaimUnavailableReason,
        requestID: String,
        operationID: UUID,
        backendCode: String?
    ) {
        claimUnavailableNotice = ClaimUnavailableNotice(
            id: UUID(),
            requestID: requestID,
            operationID: operationID,
            backendCode: backendCode,
            reason: reason
        )
        refreshRequestsAfterClaimConflict()
    }

    /// Refreshes from backend truth in its own task, so the refresh survives the
    /// screen that started the claim being dismissed and its task cancelled.
    private func refreshRequestsAfterClaimConflict() {
        Task { [weak self] in
            await self?.fetchRequests()
        }
    }

    /// `POST /api/request/:id/fulfill`. Requires the in-memory active claim
    /// for `requestID`; not automatically retried on failure, including when
    /// the outcome is ambiguous (`RequestServiceError.ambiguousFulfillmentOutcome`).
    /// Returns normally only after confirmed request/notification state is applied.
    func fulfill(
        requestID: String,
        fulfillerEmail: String,
        orderNumber: String,
        eta: String,
        note: String?,
        contactMessage: String?
    ) async throws {
        guard !isFulfilling else {
            throw RequestServiceError.operationInProgress
        }
        confirmedFulfillmentOutcome = nil
        guard let activeClaim,
              activeClaim.requestID == requestID,
              let authorization = activeClaimAuthorization,
              authorization.requestID == requestID else {
            fulfillError = .noActiveClaim
            throw RequestServiceError.noActiveClaim
        }

        isFulfilling = true
        fulfillError = nil
        defer { isFulfilling = false }
        do {
            let outcome = try await service.fulfillRequest(
                id: requestID,
                claimToken: authorization.claimToken,
                fulfillerEmail: fulfillerEmail,
                orderNumber: orderNumber,
                eta: eta,
                note: note,
                contactMessage: contactMessage
            )
            advanceCollectionRevision()
            applyConfirmed(outcome.request)
            confirmedFulfillmentOutcome = outcome
            if self.activeClaimAuthorization?.claimID == authorization.claimID {
                clearActiveClaim()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let serviceError = Self.asServiceError(error)
            fulfillError = serviceError
            throw serviceError
        }
    }

    /// Marks a backend-confirmed canonical collection change. Fetches capture
    /// this revision when they start, so a response based on older canonical
    /// state cannot overwrite a later create, claim, or fulfillment result.
    private func advanceCollectionRevision() {
        collectionRevision += 1
    }

    private func applyConfirmed(_ request: FoodRequest) {
        if let index = requests.firstIndex(where: { $0.id == request.id }) {
            requests[index] = request
        } else {
            requests.append(request)
        }
    }

    private static func asServiceError(_ error: Error) -> RequestServiceError {
        (error as? RequestServiceError) ?? .transport(underlying: error)
    }
}
