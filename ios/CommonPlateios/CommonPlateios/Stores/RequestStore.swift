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
/// record. Both are process-local and are cleared together when the flow ends.
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

/// The exact values submitted on the original fulfillment POST. They stay in
/// private store memory only while that submission is unresolved, so a manual
/// recovery can repeat the same CommonPlate write without asking a recreated
/// view to reconstruct or retain claimant-entered details.
private struct FulfillmentSubmissionSnapshot: Equatable {
    let fulfillerEmail: String
    let orderNumber: String
    let eta: String
    let contactMessage: String?
}

private struct FulfillmentAttempt: Equatable {
    let id: UUID
    let claimID: UUID
    let requestID: String
    let submission: FulfillmentSubmissionSnapshot
    /// Non-nil only for the single manual repeat. This ties its independent
    /// operation identity back to the original ambiguity it is allowed to
    /// resolve, so a stale recovery response cannot act on another context.
    let originatingAmbiguityID: UUID?
}

private struct FulfillmentAmbiguityContext: Equatable {
    let id: UUID
    let claimID: UUID
    let requestID: String
    let submission: FulfillmentSubmissionSnapshot
    var hasConsumedRecovery: Bool
}

struct FulfillmentAmbiguityPresentation: Identifiable, Equatable {
    let id: UUID
    let requestID: String
    fileprivate(set) var isCheckingStatus: Bool
    fileprivate(set) var isRecoveryAvailable: Bool
    fileprivate(set) var isRecovering: Bool
}

enum FulfillmentConfirmationKind: Equatable {
    case notificationSent
    case notificationFailed
    case emailStatusUnknown
}

struct FulfillmentConfirmation: Identifiable, Equatable {
    let id: UUID
    let requestID: String
    /// Public request identity, copied off the confirmed placed request so the
    /// Active Requests card can still name the meal. Both the active claim and
    /// the list row are gone by the time that card is the only surviving
    /// surface, so the identity has to travel on the confirmation itself.
    /// These are public projection fields only — no claimant-private value
    /// (pickup name, token, deadline) may be carried here.
    let vendor: String
    let foodDescription: String
    let kind: FulfillmentConfirmationKind
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
    /// Fulfillment-specific expiration warning. The helper may already have
    /// placed the external order, so the copy must forbid a second one.
    case fulfillmentClaimExpired
    /// The backend confirmed the token is wrong or the request is no longer
    /// actively claimed by this helper.
    case reservationNoLongerValid
    /// The backend confirmed placement was already recorded.
    case fulfillmentAlreadyPlaced
    /// The request could not be found. This is terminal for the local claim but
    /// must not imply that another external order is safe.
    case fulfillmentRequestNotFound
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

/// Stable backend claim and extension error codes, centralized so handling
/// cannot drift into scattered string literals.
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

    /// Whether a probe is running right now, and whether one has ever been
    /// started. `.unknown` alone cannot tell those apart, and the difference is
    /// the difference between a spinner that is about to answer and a spinner
    /// that never will: a probe cancelled by a screen exit resolves back to
    /// `.unknown` with nothing left running, which is a finished attempt with no
    /// result rather than a check in progress.
    @Published private(set) var isCheckingRequestCreationAvailability = false
    @Published private(set) var hasAttemptedRequestCreationAvailabilityCheck = false

    @Published private(set) var isCreating = false
    @Published private(set) var createError: RequestServiceError?

    /// `POST /api/request` has no client operation identity. After an ambiguous
    /// result, this process-local guard blocks every later create to prevent
    /// duplicates; it clears only when the store is destroyed. Durable recovery
    /// requires backend idempotency and reconciliation.
    @Published private(set) var unresolvedCreateError: RequestServiceError?

    /// Read-only projection of the process-lifetime create block, for views
    /// that need to render it but have no use for the underlying error.
    var hasUnresolvedCreateAmbiguity: Bool {
        unresolvedCreateError != nil
    }

    @Published private(set) var isClaiming = false
    @Published private(set) var claimErrorEvent: ClaimErrorEvent?

    /// Every backend-confirmed reason the helper cannot have a request, in the
    /// order it was produced. Active Requests presents the oldest element while
    /// request-scoped flows locate their own matching element, so neither a
    /// covered list nor an unrelated earlier notice can drop a safety message.
    @Published private(set) var claimUnavailableNotices: [ClaimUnavailableNotice] = []

    /// The oldest notice still waiting for acknowledgement. This preserves the
    /// existing Active Requests presentation boundary while the queue itself
    /// remains store-owned.
    var claimUnavailableNotice: ClaimUnavailableNotice? {
        claimUnavailableNotices.first
    }

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
    @Published private(set) var fulfillmentAmbiguity: FulfillmentAmbiguityPresentation?
    @Published private(set) var fulfillmentConfirmation: FulfillmentConfirmation?

    /// Non-secret presentation for the helper's active claim, if any. The
    /// matching raw token is held separately in private store-only state.
    @Published private(set) var activeClaim: ActiveClaimPresentation?

    private let service: RequestService
    private var fetchGeneration = 0
    private var collectionRevision = 0
    private var activeClaimAuthorization: ActiveClaimAuthorization?
    private var activeClaimAttempt: ClaimAttempt?
    private var activeClaimExtensionAttempt: ClaimExtensionAttempt?
    private var activeFulfillmentAttempt: FulfillmentAttempt?
    private var fulfillmentAmbiguityContext: FulfillmentAmbiguityContext?

    /// The claim identity a placement submission has been attempted under. The
    /// claimant screen permits that submission only after the external order is
    /// already placed, so this records that the helper may be holding a real
    /// order — which changes what an expiration is allowed to tell them. It
    /// outlives the attempt itself and is cleared with the claim.
    private var fulfillmentSubmissionClaimID: UUID?

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

    /// Runs one fail-closed availability probe. Cancellation returns to
    /// `.unknown`; other failures become `.unavailable`. Concurrent calls are
    /// dropped, and recovery is always requester-initiated.
    func refreshRequestCreationAvailability() async {
        guard !isCheckingRequestCreationAvailability else {
            return
        }
        hasAttemptedRequestCreationAvailabilityCheck = true
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
    ///
    /// Only `ambiguousCreateOutcome` arms the process-lifetime block. Decoded
    /// server errors and the non-envelope 404 path are treated as definitive
    /// and do not arm it.
    func createRequest(_ payload: CreateRequestPayload) async throws {
        if let unresolvedCreateError {
            createError = unresolvedCreateError
            throw unresolvedCreateError
        }
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
            if case .ambiguousCreateOutcome = serviceError {
                unresolvedCreateError = serviceError
            }
            throw serviceError
        }
    }

    /// Publishes the pickup name and stores the raw token only after a confirmed
    /// claim response. Duplicate or second-request claims are refused before
    /// POST so the single active claim, token, and lifecycle timer cannot be
    /// overwritten.
    func claim(requestID: String) async throws {
        // One unacknowledged placement result gates the next claim so a real
        // sent, failed, or unknown-email outcome cannot be overwritten. The
        // refusal is recorded before any POST so the detail screen can explain it.
        if let confirmation = fulfillmentConfirmation {
            recordPreflightClaimRefusal(
                .unacknowledgedPlacement,
                requestID: requestID,
                operationID: confirmation.id
            )
            throw RequestServiceError.unacknowledgedPlacement
        }
        if let activeClaim {
            let refusal: RequestServiceError = activeClaim.requestID == requestID
                ? .operationInProgress
                : .existingActiveClaim
            // Recorded, not just thrown: the caller discards the error, so
            // without an event the tap looks like it did nothing and the
            // accepted copy for this refusal never reaches the helper.
            recordPreflightClaimRefusal(
                refusal,
                requestID: requestID,
                operationID: activeClaimAuthorization?.claimID
            )
            throw refusal
        }
        guard !isClaiming else {
            // Only the same request can honestly be described as "already
            // starting". An attempt in flight for a *different* request blocks
            // this one just as firmly, but for a different reason and only for
            // a moment, so it gets its own refusal rather than borrowing copy
            // that would misdescribe the request in front of the helper.
            let refusal: RequestServiceError = activeClaimAttempt?.requestID == requestID
                ? .operationInProgress
                : .otherClaimInProgress
            recordPreflightClaimRefusal(
                refusal,
                requestID: requestID,
                operationID: activeClaimAttempt?.id
            )
            throw refusal
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
                // This attempt was the blocker. Any "wait for that request"
                // refusal it caused on another screen is now stale — and this
                // runs after the catch, so a real rejection recorded for *this*
                // request is left alone by the case match.
                clearPreflightClaimRefusal { error in
                    if case .otherClaimInProgress = error { return true }
                    return false
                }
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
              fulfillmentAmbiguityContext == nil,
              activeFulfillmentAttempt == nil,
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
    /// from backend truth. There is no release endpoint, so the backend reopens
    /// the reservation when the claim lapses.
    ///
    /// Deliberately **not** wired to Back or a swipe dismissal. Leaving the
    /// claimant screen is navigation, not a decision to give up a reservation
    /// the backend still holds; dropping the pickup name and token there left
    /// the request blocked for every other helper with no local way back in.
    /// This remains the seam for an explicit end-of-flow action. Confirmed
    /// fulfillment clears the same state through `clearActiveClaim`.
    func leaveActiveClaimFlow() {
        // An unresolved POST may already have recorded the external order. Its
        // raw token and claimant context are intentionally retained until
        // placement is positively resolved or the claim expires.
        guard fulfillmentAmbiguityContext == nil else {
            return
        }
        clearActiveClaim()
        refreshRequestsAfterClaimConflict()
    }

    /// Re-checks the backend-provided deadline when the app becomes active.
    /// The captured claim identity is passed through the same expiration seam
    /// as the timer, so this check cannot clear a replacement claim.
    func revalidateActiveClaimExpiration(now: Date = Date()) {
        guard let claim = activeClaim,
              let authorization = activeClaimAuthorization,
              authorization.requestID == claim.requestID,
              activeClaimExtensionAttempt == nil else {
            return
        }

        if claim.claimExpiresAt <= now {
            markActiveClaimExpired(
                claimID: authorization.claimID,
                requestID: authorization.requestID,
                expiration: claim.claimExpiresAt
            )
        } else {
            startClaimLifecycleTimer()
        }
    }

    /// Removes only the exactly acknowledged notice. A stale or unknown
    /// acknowledgement cannot clear or reorder any other queued notice.
    func acknowledgeClaimUnavailableNotice(id: UUID) {
        guard let index = claimUnavailableNotices.firstIndex(where: { $0.id == id }) else {
            return
        }
        claimUnavailableNotices.remove(at: index)
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
        fulfillError = nil
        fulfillmentAmbiguity = nil
        fulfillmentAmbiguityContext = nil
        fulfillmentSubmissionClaimID = nil
        // `fulfillmentConfirmation` and its outcome are deliberately untouched.
        // A confirmed placement the helper has not acknowledged yet is terminal
        // information about a real order; starting to help with something else
        // is not a reason to drop it, and Active Requests keeps it reachable.
        isShowingClaimExtensionPrompt = false
        hasResolvedClaimExtensionPrompt = false
        // The attempt that was "already starting" has finished starting.
        clearPreflightClaimRefusal { error in
            if case .operationInProgress = error { return true }
            return false
        }
        startClaimLifecycleTimer()
    }

    private func clearActiveClaim() {
        let clearedClaimID = activeClaimAuthorization?.claimID
        claimLifecycleTask?.cancel()
        claimLifecycleTask = nil
        invalidateActiveExtensionAttempt()
        invalidateActiveFulfillmentAttempt()
        activeClaim = nil
        activeClaimAuthorization = nil
        isShowingClaimExtensionPrompt = false
        hasResolvedClaimExtensionPrompt = false
        claimExtensionError = nil
        if fulfillmentAmbiguityContext?.claimID == clearedClaimID {
            fulfillmentAmbiguityContext = nil
            fulfillmentAmbiguity = nil
        }
        if fulfillmentSubmissionClaimID == clearedClaimID {
            fulfillmentSubmissionClaimID = nil
        }
        // The reservation that was blocking other requests is gone, so a
        // refusal that only described it must not keep telling the helper they
        // are already helping with something else.
        clearPreflightClaimRefusal { error in
            if case .existingActiveClaim = error { return true }
            return false
        }
    }

    private func invalidateActiveExtensionAttempt() {
        activeClaimExtensionAttempt = nil
        isExtendingClaim = false
    }

    private func invalidateActiveFulfillmentAttempt() {
        activeFulfillmentAttempt = nil
        isFulfilling = false
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
    /// Foreground activation also re-checks this backend-provided deadline.
    /// Timer callbacks and foreground checks both carry the private claim
    /// identity, so neither can clear a replacement claim.
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
              fulfillmentAmbiguityContext == nil,
              activeFulfillmentAttempt == nil,
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

    /// Whether the helper may already be holding a completed external order for
    /// this claim identity. Resolved from store state rather than passed in by
    /// the caller: the timer, the foreground check, and the post-attempt resume
    /// all reach the same expiration for the same reason, and a Boolean argument
    /// meant one of them could silently answer differently by omitting it.
    private func mayHavePlacedExternalOrder(claimID: UUID) -> Bool {
        fulfillmentSubmissionClaimID == claimID
            || fulfillmentAmbiguityContext?.claimID == claimID
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
        // A POST whose outcome has not returned must retain claimant state.
        // Once its outcome is known to be ambiguous, the accepted contract
        // preserves that state only until positive resolution or expiration.
        if let activeFulfillmentAttempt {
            let expectedAmbiguityID = activeFulfillmentAttempt.originatingAmbiguityID
                ?? activeFulfillmentAttempt.id
            // The POST itself may already be committing and must reach a
            // terminal response before claimant state is cleared. Expiration
            // may act only once an ambiguous POST has handed ownership to its
            // read-only status check, which is safe to abandon at the deadline.
            guard fulfillmentAmbiguityContext?.id == expectedAmbiguityID,
                  fulfillmentAmbiguity?.id == expectedAmbiguityID,
                  fulfillmentAmbiguity?.isCheckingStatus == true else {
                return
            }
        }
        // Resolved before the teardown: `clearActiveClaim` drops the submission
        // and ambiguity records this answer is derived from, and the notice has
        // to outlive both of them.
        let reason: ClaimUnavailableReason = mayHavePlacedExternalOrder(claimID: claimID)
            ? .fulfillmentClaimExpired
            : .claimExpired
        clearActiveClaim()
        reportClaimUnavailable(
            reason,
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
        case ClaimErrorCode.claimExpired:
            // The backend confirming expiry is the same event the timer and the
            // foreground check announce, so it answers the same question: if a
            // placement was already submitted under this claim, the helper may
            // be holding a real order and must be told not to place a second
            // one. Resolved before `clearActiveClaim` drops the state it reads.
            guard extensionAttemptIsCurrent(attempt) else { return }
            let reason: ClaimUnavailableReason =
                mayHavePlacedExternalOrder(claimID: attempt.claimID)
                    ? .fulfillmentClaimExpired
                    : .claimExpired
            clearActiveClaim()
            reportClaimUnavailable(
                reason,
                requestID: attempt.requestID,
                operationID: attempt.claimID,
                backendCode: code
            )
        case ClaimErrorCode.invalidClaimToken,
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

    /// Publishes preflight refusals as request-scoped events because the caller
    /// discards thrown errors. `operationID` keeps repeated taps tied to the
    /// same blocker.
    private func recordPreflightClaimRefusal(
        _ error: RequestServiceError,
        requestID: String,
        operationID: UUID?
    ) {
        claimErrorEvent = ClaimErrorEvent(
            id: UUID(),
            requestID: requestID,
            claimAttemptID: operationID ?? UUID(),
            backendCode: nil,
            error: error
        )
    }

    /// Drops a pre-flight refusal whose blocker has gone away. Matched by case
    /// so a real backend rejection is never swallowed by unrelated cleanup.
    private func clearPreflightClaimRefusal(
        where matches: (RequestServiceError) -> Bool
    ) {
        guard let event = claimErrorEvent, matches(event.error) else {
            return
        }
        claimErrorEvent = nil
    }

    func claimError(for requestID: String) -> RequestServiceError? {
        guard claimErrorEvent?.requestID == requestID else {
            return nil
        }
        return claimErrorEvent?.error
    }

    /// The newest queued terminal event for this request. Detail recovery must
    /// not assume the FIFO head belongs to the screen currently visible: an
    /// older notice for another request may still be waiting to be presented.
    func claimUnavailableNotice(for requestID: String) -> ClaimUnavailableNotice? {
        claimUnavailableNotices.last { $0.requestID == requestID }
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
        claimUnavailableNotices.append(ClaimUnavailableNotice(
            id: UUID(),
            requestID: requestID,
            operationID: operationID,
            backendCode: backendCode,
            reason: reason
        ))
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
        contactMessage: String?,
        now: Date = Date()
    ) async throws {
        guard !isFulfilling else {
            throw RequestServiceError.operationInProgress
        }
        guard activeClaimExtensionAttempt == nil else {
            throw RequestServiceError.operationInProgress
        }
        guard fulfillmentAmbiguityContext == nil else {
            throw RequestServiceError.unresolvedFulfillment
        }
        guard let claim = activeClaim,
              claim.requestID == requestID,
              let authorization = activeClaimAuthorization,
              authorization.requestID == requestID,
              !authorization.claimToken.isEmpty else {
            fulfillError = .noActiveClaim
            throw RequestServiceError.noActiveClaim
        }

        guard claim.claimExpiresAt > now else {
            let error = RequestServiceError.claimExpired
            fulfillError = error
            // Submission is offered only after the external order is placed, so
            // reaching this line means the helper may be holding a real order
            // even though no POST was sent. Recorded before the expiration is
            // announced so it gets the fulfillment-specific warning.
            fulfillmentSubmissionClaimID = authorization.claimID
            markActiveClaimExpired(
                claimID: authorization.claimID,
                requestID: requestID,
                expiration: claim.claimExpiresAt
            )
            throw error
        }

        let submission = FulfillmentSubmissionSnapshot(
            fulfillerEmail: fulfillerEmail,
            orderNumber: orderNumber,
            eta: eta,
            contactMessage: contactMessage
        )
        let attempt = FulfillmentAttempt(
            id: UUID(),
            claimID: authorization.claimID,
            requestID: requestID,
            submission: submission,
            originatingAmbiguityID: nil
        )
        try await performFulfillment(attempt: attempt, claimToken: authorization.claimToken)
    }

    /// Performs the one explicit CommonPlate-only repeat after the original
    /// POST and its read-only status check both remained unresolved. The caller
    /// supplies identities only; the raw token and exact original payload stay
    /// private to the matching store context.
    func resubmitAmbiguousFulfillment(
        ambiguityID: UUID,
        requestID: String,
        now: Date = Date()
    ) async throws {
        guard !isFulfilling, activeFulfillmentAttempt == nil else {
            throw RequestServiceError.operationInProgress
        }
        guard activeClaimExtensionAttempt == nil else {
            throw RequestServiceError.operationInProgress
        }
        guard var context = fulfillmentAmbiguityContext,
              context.id == ambiguityID,
              context.requestID == requestID,
              !context.hasConsumedRecovery,
              let ambiguity = fulfillmentAmbiguity,
              ambiguity.id == ambiguityID,
              ambiguity.requestID == requestID,
              !ambiguity.isCheckingStatus,
              ambiguity.isRecoveryAvailable,
              let claim = activeClaim,
              claim.requestID == requestID,
              let authorization = activeClaimAuthorization,
              authorization.claimID == context.claimID,
              authorization.requestID == requestID,
              !authorization.claimToken.isEmpty else {
            throw RequestServiceError.unresolvedFulfillment
        }

        // Consumed on the main actor before the first suspension point. A
        // duplicate tap, recreated view, or navigation re-entry sees the same
        // context with no remaining POST opportunity.
        context.hasConsumedRecovery = true
        fulfillmentAmbiguityContext = context
        fulfillmentAmbiguity?.isRecoveryAvailable = false

        guard claim.claimExpiresAt > now else {
            let error = RequestServiceError.claimExpired
            fulfillError = error
            fulfillmentSubmissionClaimID = authorization.claimID
            markActiveClaimExpired(
                claimID: authorization.claimID,
                requestID: requestID,
                expiration: claim.claimExpiresAt
            )
            throw error
        }

        fulfillmentAmbiguity?.isRecovering = true
        let attempt = FulfillmentAttempt(
            id: UUID(),
            claimID: authorization.claimID,
            requestID: requestID,
            submission: context.submission,
            originatingAmbiguityID: context.id
        )
        try await performFulfillment(attempt: attempt, claimToken: authorization.claimToken)
    }

    private func performFulfillment(
        attempt: FulfillmentAttempt,
        claimToken: String
    ) async throws {
        activeFulfillmentAttempt = attempt
        fulfillmentSubmissionClaimID = attempt.claimID
        isFulfilling = true
        fulfillError = nil
        claimLifecycleTask?.cancel()
        claimLifecycleTask = nil
        defer {
            if activeFulfillmentAttempt == attempt {
                activeFulfillmentAttempt = nil
                isFulfilling = false
                resumeClaimLifecycleAfterFulfillmentAttempt(attempt)
            }
        }
        do {
            let outcome = try await service.fulfillRequest(
                id: attempt.requestID,
                claimToken: claimToken,
                fulfillerEmail: attempt.submission.fulfillerEmail,
                orderNumber: attempt.submission.orderNumber,
                eta: attempt.submission.eta,
                contactMessage: attempt.submission.contactMessage
            )
            guard fulfillmentAttemptIsCurrent(attempt) else { return }
            applyConfirmedFulfillment(
                request: outcome.request,
                notificationStatus: outcome.notificationStatus,
                attempt: attempt
            )
        } catch is CancellationError {
            guard fulfillmentAttemptIsCurrent(attempt) else { return }
            if attempt.originatingAmbiguityID != nil {
                settleRecoveryAsPermanentlyBlocked(attempt: attempt)
            }
            throw CancellationError()
        } catch {
            guard fulfillmentAttemptIsCurrent(attempt) else { return }
            let serviceError = Self.asServiceError(error)
            fulfillError = serviceError
            if Self.warrantsPlacementStatusCheck(serviceError, attempt: attempt) {
                await revalidateAmbiguousFulfillment(attempt: attempt)
                if fulfillmentConfirmation?.requestID == attempt.requestID {
                    return
                }
            } else {
                applyConfirmedFulfillmentConflict(serviceError, attempt: attempt)
                if fulfillmentAttemptIsCurrent(attempt),
                   attempt.originatingAmbiguityID != nil {
                    settleRecoveryAsPermanentlyBlocked(attempt: attempt)
                }
            }
            throw serviceError
        }
    }

    /// Whether store-owned claim state permits a fulfillment submission. Form
    /// fields are validated by the view; this checks the same-request claim,
    /// private raw token, backend deadline, duplicate guard, and ambiguity lock.
    ///
    /// The confirmation check is request-scoped on purpose. A confirmed
    /// placement blocks resubmitting *that* request, but an outstanding
    /// confirmation the helper has not acknowledged yet says nothing about a
    /// different reservation and must not disable it.
    func canSubmitFulfillment(requestID: String, now: Date = Date()) -> Bool {
        guard !isFulfilling,
              activeClaimExtensionAttempt == nil,
              fulfillmentAmbiguityContext == nil,
              fulfillmentConfirmation?.requestID != requestID,
              let claim = activeClaim,
              claim.requestID == requestID,
              claim.claimExpiresAt > now,
              let authorization = activeClaimAuthorization,
              authorization.requestID == requestID,
              !authorization.claimToken.isEmpty else {
            return false
        }
        return true
    }

    /// Clears one confirmation, matched by exact ID so a queued newer result is
    /// never dropped by an acknowledgement meant for an older one. Callable from
    /// the claimant screen's success section and from the Active Requests item
    /// that keeps the same confirmation reachable after that screen is gone.
    func acknowledgeFulfillmentConfirmation(id: UUID) {
        guard fulfillmentConfirmation?.id == id else { return }
        fulfillmentConfirmation = nil
        confirmedFulfillmentOutcome = nil
        // The refusal this confirmation caused is now obsolete. Left in place it
        // would keep explaining a block that no longer exists on whichever
        // detail screen recorded it.
        clearPreflightClaimRefusal { error in
            if case .unacknowledgedPlacement = error { return true }
            return false
        }
    }

    private func fulfillmentAttemptIsCurrent(_ attempt: FulfillmentAttempt) -> Bool {
        guard activeFulfillmentAttempt == attempt,
              activeClaimAuthorization?.claimID == attempt.claimID,
              activeClaimAuthorization?.requestID == attempt.requestID,
              activeClaim?.requestID == attempt.requestID else {
            return false
        }
        guard let originatingAmbiguityID = attempt.originatingAmbiguityID else {
            return true
        }
        return fulfillmentAmbiguityContext?.id == originatingAmbiguityID
            && fulfillmentAmbiguityContext?.claimID == attempt.claimID
            && fulfillmentAmbiguityContext?.requestID == attempt.requestID
    }

    private func applyConfirmedFulfillment(
        request: FoodRequest,
        notificationStatus: NotificationDeliveryStatus?,
        attempt: FulfillmentAttempt
    ) {
        guard fulfillmentAttemptIsCurrent(attempt), request.status == .placed else { return }

        fulfillError = nil
        advanceCollectionRevision()
        requests.removeAll { $0.id == request.id }

        let kind: FulfillmentConfirmationKind
        switch notificationStatus {
        case .sent:
            kind = .notificationSent
        case .failed:
            kind = .notificationFailed
        case nil:
            kind = .emailStatusUnknown
        }
        fulfillmentConfirmation = FulfillmentConfirmation(
            id: UUID(),
            requestID: request.id,
            vendor: request.diningSpot.name,
            foodDescription: request.foodDescription,
            kind: kind
        )
        if let notificationStatus {
            confirmedFulfillmentOutcome = FulfillOutcome(
                request: request,
                notificationStatus: notificationStatus
            )
        } else {
            confirmedFulfillmentOutcome = nil
        }
        fulfillmentAmbiguityContext = nil
        fulfillmentAmbiguity = nil
        clearActiveClaim()
    }

    /// Performs exactly one read-only status check after an ambiguous POST.
    /// Only `placed` resolves it; every other result leaves the submission
    /// blocked with the claimant token and context preserved.
    private func revalidateAmbiguousFulfillment(attempt: FulfillmentAttempt) async {
        guard fulfillmentAttemptIsCurrent(attempt) else { return }

        let context: FulfillmentAmbiguityContext
        if let originatingAmbiguityID = attempt.originatingAmbiguityID {
            guard let existingContext = fulfillmentAmbiguityContext,
                  existingContext.id == originatingAmbiguityID,
                  existingContext.claimID == attempt.claimID,
                  existingContext.requestID == attempt.requestID,
                  existingContext.submission == attempt.submission,
                  existingContext.hasConsumedRecovery else {
                return
            }
            context = existingContext
        } else {
            context = FulfillmentAmbiguityContext(
                id: attempt.id,
                claimID: attempt.claimID,
                requestID: attempt.requestID,
                submission: attempt.submission,
                hasConsumedRecovery: false
            )
            fulfillmentAmbiguityContext = context
        }
        fulfillmentAmbiguity = FulfillmentAmbiguityPresentation(
            id: context.id,
            requestID: context.requestID,
            isCheckingStatus: true,
            isRecoveryAvailable: false,
            isRecovering: false
        )
        // The one-shot read may be slow. Expiration still has to retire this
        // unresolved claim, so restore its identity-scoped deadline timer now
        // rather than waiting for the read to finish.
        startClaimLifecycleTimer()
        // The one-shot placement result now owns the safety state. An extension
        // POST cannot help resolve it and could clear context on a predictable
        // no-longer-claimed response.
        isShowingClaimExtensionPrompt = false
        hasResolvedClaimExtensionPrompt = true

        do {
            let request = try await service.fetchRequest(id: context.requestID)
            guard fulfillmentAmbiguityContext == context,
                  fulfillmentAttemptIsCurrent(attempt) else { return }
            if request.status == .placed {
                applyConfirmedFulfillment(
                    request: request,
                    notificationStatus: nil,
                    attempt: attempt
                )
                return
            }
        } catch {
            // 404, decoding, and transport failures are all inconclusive. The
            // raw token and claimant context remain held in private memory.
        }

        guard fulfillmentAmbiguityContext == context,
              fulfillmentAttemptIsCurrent(attempt) else { return }
        fulfillmentAmbiguity?.isCheckingStatus = false
        fulfillmentAmbiguity?.isRecoveryAvailable = !context.hasConsumedRecovery
    }

    /// Runs the one privacy-safe status check only after an ambiguous response,
    /// or after `INTERNAL_FAILURE` on the consumed manual repeat. Pre-transaction
    /// refusals do not qualify, and the check never reopens recovery.
    private static func warrantsPlacementStatusCheck(
        _ error: RequestServiceError,
        attempt: FulfillmentAttempt
    ) -> Bool {
        if case .ambiguousFulfillmentOutcome = error {
            return true
        }
        guard attempt.originatingAmbiguityID != nil,
              case .serverError(let code, _) = error else {
            return false
        }
        return code == ClaimErrorCode.internalFailure
    }

    private func settleRecoveryAsPermanentlyBlocked(attempt: FulfillmentAttempt) {
        guard let originatingAmbiguityID = attempt.originatingAmbiguityID,
              let context = fulfillmentAmbiguityContext,
              context.id == originatingAmbiguityID,
              context.claimID == attempt.claimID,
              context.requestID == attempt.requestID,
              context.hasConsumedRecovery,
              fulfillmentAmbiguity?.id == originatingAmbiguityID else {
            return
        }
        fulfillmentAmbiguity?.isCheckingStatus = false
        fulfillmentAmbiguity?.isRecoveryAvailable = false
        fulfillmentAmbiguity?.isRecovering = false
    }

    private func resumeClaimLifecycleAfterFulfillmentAttempt(_ attempt: FulfillmentAttempt) {
        guard activeFulfillmentAttempt == nil,
              let claim = activeClaim,
              let authorization = activeClaimAuthorization,
              authorization.claimID == attempt.claimID,
              authorization.requestID == attempt.requestID,
              claim.requestID == attempt.requestID else {
            return
        }

        if claim.claimExpiresAt <= Date() {
            markActiveClaimExpired(
                claimID: attempt.claimID,
                requestID: attempt.requestID,
                expiration: claim.claimExpiresAt
            )
        } else {
            startClaimLifecycleTimer()
        }
    }

    private func applyConfirmedFulfillmentConflict(
        _ error: RequestServiceError,
        attempt: FulfillmentAttempt
    ) {
        guard fulfillmentAttemptIsCurrent(attempt),
              case .serverError(let code, _) = error else { return }

        let reason: ClaimUnavailableReason
        switch code {
        case ClaimErrorCode.claimExpired:
            reason = .fulfillmentClaimExpired
        case ClaimErrorCode.invalidClaimToken,
             ClaimErrorCode.requestNotClaimed:
            reason = .reservationNoLongerValid
        case ClaimErrorCode.requestAlreadyPlaced:
            reason = .fulfillmentAlreadyPlaced
            advanceCollectionRevision()
            requests.removeAll { $0.id == attempt.requestID }
        case ClaimErrorCode.requestNotFound:
            reason = .fulfillmentRequestNotFound
        default:
            return
        }

        clearActiveClaim()
        reportClaimUnavailable(
            reason,
            requestID: attempt.requestID,
            operationID: attempt.id,
            backendCode: code
        )
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
