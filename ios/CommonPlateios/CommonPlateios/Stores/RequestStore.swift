//
//  RequestStore.swift
//  CommonPlateios
//
//  Created by faith on 7/13/26.
//
// Coordinates RequestService calls and updates local state only after
// confirmed backend responses, per docs/system-contract.md. Owns no
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
///
/// `claimToken` is `nil` after W3-H1 continuation: the raw token generated at
/// claim time is never persisted, so a claim restored from
/// `continueActiveReservationIfNeeded()` after a relaunch has none. Extend,
/// release, and fulfillment all accept verified participant authority as an
/// additive authorization path for exactly this case — the raw-token path is
/// preserved unchanged for the still-in-process case — so a continued claim
/// with no token can be viewed, extended, released, and fulfilled, all from
/// this same process.
private struct ActiveClaimAuthorization {
    let claimID: UUID
    let requestID: String
    let claimToken: String?
    /// Exact authority that established a continuation-restored reservation.
    /// Nil for an in-process claim, whose raw token remains preferred and is
    /// sufficient. This is reservation-scoped private state, never the app's
    /// current/presentation identity and never persisted.
    let participantAuthority: String?
}

/// W3-D1: marks an `unresolvedCreateError` armed by restoring a durable
/// operation record, not by an in-process POST. Carries no information — the
/// durable record itself, not this marker, is the recovery state — and
/// exists only so `reconcilePendingCreateOperationIfNeeded` can express "an
/// unresolved operation exists" through the same
/// `.ambiguousCreateOutcome(underlying:)` case an in-process ambiguous
/// attempt uses, which is what lets `RequestFoodView` present both with the
/// identical truthful copy.
private struct PendingRequestOperationRestored: Error {}

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

private struct ClaimReleaseAttempt: Equatable {
    let id: UUID
    let claimID: UUID
    let requestID: String
}

/// The exact values submitted on the original fulfillment POST. They stay in
/// private store memory only while that submission is unresolved, so a manual
/// recovery can repeat the same CommonPlate write without asking a recreated
/// view to reconstruct or retain claimant-entered details.
private struct FulfillmentSubmissionSnapshot: Equatable {
    let orderNumber: String
    let eta: String
    let contactMessage: String?
}

private struct FulfillmentAttempt: Equatable {
    let id: UUID
    let claimID: UUID
    let requestID: String
    let submission: FulfillmentSubmissionSnapshot
    let authorization: FulfillmentAuthorization
    /// Non-nil only for the single manual repeat. This ties its independent
    /// operation identity back to the original ambiguity it is allowed to
    /// resolve, so a stale recovery response cannot act on another context.
    let originatingAmbiguityID: UUID?
}

/// How `performFulfillment` authorizes the POST (W3-H1 continuation): the raw
/// token, preserved unchanged, when the claim is still in-process; verified
/// participant authority, additive, when a relaunch already discarded it.
/// Mirrors the backend's own `FulfillmentAuthorization` in
/// `fulfillmentRoute.ts`.
private enum FulfillmentAuthorization: Equatable {
    case token(String)
    case participant(String)

    var participantAuthority: String? {
        guard case .participant(let authority) = self else { return nil }
        return authority
    }
}

private struct FulfillmentAmbiguityContext: Equatable {
    let id: UUID
    let claimID: UUID
    let requestID: String
    let submission: FulfillmentSubmissionSnapshot
    let authorization: FulfillmentAuthorization
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
    /// `REQUEST_NOT_YET_AVAILABLE`: a scheduled request opened before its
    /// start. Deliberately not folded into `noLongerAvailable` — that reason
    /// exists for requests there is no point returning to, and this one is the
    /// opposite situation.
    case notYetAvailable
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
    /// A helper new-request notification tap could not be resolved against
    /// current backend truth (transport, timeout, server, or decoding
    /// failure). Kept distinct from `noLongerAvailable`: the request may
    /// still be open, so this must read as "try again", never as "gone".
    case temporarilyUnavailable
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

/// The outcome of resolving a helper new-request notification tap against
/// backend truth. `requestId` in the push payload is routing context, never
/// lifecycle truth, so this is the only way a tap may reach a detail screen.
enum HelperNotificationResolution: Equatable {
    case available(FoodRequest)
    /// The backend has current lifecycle truth and it is not open: an
    /// authoritative 404 (the request no longer exists), or a decoded
    /// non-open status. Never used for a failure that leaves truth unknown.
    case unavailable
    /// The backend answered `REQUEST_NOT_YET_AVAILABLE`: a scheduled request
    /// whose start has not arrived. Distinct from both neighbours, and it has
    /// to be. `.unavailable` would say a request that is still coming is gone;
    /// `.temporarilyUnavailable` would blame the network for an answer the
    /// backend gave clearly. This is settled truth about the request, and the
    /// only one of the three worth coming back for.
    case notYetAvailable
    /// Current backend truth could not be established — transport, timeout,
    /// a server failure, or a response that could not be decoded. This is
    /// deliberately distinct from `.unavailable`: it must never be presented
    /// as "this request is gone", only as "try again".
    case temporarilyUnavailable
}

/// Truth established by the active-reservation continuation read (W3-H1).
/// `unknown` is deliberately not absence: transport, server, and decoding
/// failures cannot prove that a reservation ended.
enum ActiveReservationContinuationOutcome {
    case active(ActiveClaimPresentation)
    case none
    case unknown
}

/// Stable backend W3-D1 request-create operation error codes, matching
/// `createRequestRoute.ts` exactly. Centralized for the same reason
/// `ClaimErrorCode` is: handling must not drift into scattered string
/// literals.
enum RequestOperationErrorCode {
    static let invalidOperationId = "INVALID_OPERATION_ID"
    static let operationUnauthorized = "OPERATION_UNAUTHORIZED"
    static let operationExpired = "OPERATION_EXPIRED"

    /// Ordinary `POST /api/request` rejections that `createRequestRoute.ts`
    /// returns from `validateCreateRequest` — after the operation-identity
    /// gate has already found this identity unrecognized ("not-found"), but
    /// strictly before the daily-limit read or either write
    /// (`createRequestWithOperation`/`RequestOperation.create`). Provably no
    /// Request or ledger row exists for the operation when either of these is
    /// returned.
    static let invalidVendor = "INVALID_VENDOR"
    static let participantPrincipalMismatch = "PARTICIPANT_PRINCIPAL_MISMATCH"
    /// The generic shape/validation refusal `validateCreateShape` produces —
    /// also strictly pre-write, for the identical reason.
    static let invalidRequest = "INVALID_REQUEST"
    /// The daily-limit refusal, read and returned before either write begins.
    static let requestLimitReached = "REQUEST_LIMIT_REACHED"
    /// The route-level create throttle, which runs before the handler and
    /// therefore before the operation lookup or either create write.
    static let rateLimited = "RATE_LIMITED"

    /// Every backend answer that definitively resolves an operation as *not*
    /// creating a Request and that can never be recovered by resubmitting the
    /// same identity — as opposed to `.ambiguousCreateOutcome`, which stays
    /// open. `operationUnauthorized` belongs here too: once the backend has
    /// refused an identity as bound to someone else, replaying it again can
    /// only repeat that refusal, so there is nothing left to keep durable
    /// state open for.
    ///
    /// The validation and quota ordinary-rejection codes belong here for the
    /// same reason:
    /// `createRequestRoute.ts` returns every one of them before any
    /// Request/`RequestOperation` write is attempted for this operation, so
    /// they are exactly as definitive as the three operation-identity codes
    /// above — a stale durable record behind one of them must not survive to
    /// be replayed after conditions change (e.g. quota resetting the next
    /// day) or to permanently block a later intentional create.
    ///
    /// `REQUEST_CREATION_FAILED` is deliberately excluded: `createRequestRoute.ts`
    /// returns that same code from paths that can follow a write attempt
    /// (the outer catch wraps the write, requester-confirmation, and
    /// notification-dispatch section), so it cannot be trusted as proof no
    /// write occurred. `RequestService.createRequest` still decodes it as an
    /// ordinary `.serverError` — pre-existing, accepted immediate-retry
    /// presentation this fix does not change — but because it is absent
    /// here, the durable record survives it rather than being retired as if
    /// creation had been definitively ruled out.
    static func isDefinitiveNonCreate(_ code: String) -> Bool {
        code == invalidOperationId
            || code == operationUnauthorized
            || code == operationExpired
            || code == invalidVendor
            || code == participantPrincipalMismatch
            || code == invalidRequest
            || code == requestLimitReached
            || code == rateLimited
    }

    /// The write-uncertain counterpart to `isDefinitiveNonCreate`: a decoded
    /// `.serverError` whose code is not definitive non-create, so the exact
    /// operation's write outcome remains unknown. `RATE_LIMITED` belongs to
    /// the definitive set above; a bare HTTP 404 is the separate
    /// `RequestServiceError.notFound` case and is retired directly by the
    /// fresh-create catch. `REQUEST_CREATION_FAILED` is currently the only
    /// readable `.serverError` code `createRequestRoute.ts` can return from a
    /// path that may follow a write attempt.
    static let requestCreationFailed = "REQUEST_CREATION_FAILED"

    static func isWriteUncertain(_ code: String) -> Bool {
        code == requestCreationFailed
    }
}

/// Stable backend claim and extension error codes, centralized so handling
/// cannot drift into scattered string literals.
enum ClaimErrorCode {
    static let invalidRequestID = "INVALID_REQUEST_ID"
    static let requestNotFound = "REQUEST_NOT_FOUND"
    static let requestAlreadyClaimed = "REQUEST_ALREADY_CLAIMED"
    static let requestAlreadyPlaced = "REQUEST_ALREADY_PLACED"
    static let requestExpired = "REQUEST_EXPIRED"
    /// A scheduled request whose start has not arrived. Distinct from
    /// `requestExpired`: nothing has run out, it has not begun.
    static let requestNotYetAvailable = "REQUEST_NOT_YET_AVAILABLE"
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

    /// W3-D1: after an ambiguous `POST /api/request` result — including one
    /// restored from durable storage at relaunch — this guard blocks every
    /// later *fresh* create, so a lost response can never produce a second
    /// logical operation. It is armed by `createRequest` and by
    /// `reconcilePendingCreateOperationIfNeeded`, and retired only by an
    /// authoritative backend outcome for the exact operation it names:
    /// created (`201`/reconciled `200`), `OPERATION_EXPIRED`,
    /// `INVALID_OPERATION_ID`, or `OPERATION_UNAUTHORIZED`. It is never
    /// cleared just because the operation could not be reconciled this
    /// attempt — that leaves it exactly as armed as it already was.
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

    /// Whether the W3-H1 five-minute reservation warning is currently offered
    /// in-app. Foreground-only presentation: while CommonPlate is not visible
    /// at the warning instant, the scheduled local notification is the
    /// warning instead, and the two must never both be true for one
    /// reservation — see `presentReservationWarningIfEligible`.
    @Published private(set) var isShowingReservationWarning = false

    @Published private(set) var isReleasingClaim = false
    @Published private(set) var releaseClaimError: RequestServiceError?

    @Published private(set) var isFulfilling = false
    @Published private(set) var fulfillError: RequestServiceError?
    @Published private(set) var confirmedFulfillmentOutcome: FulfillOutcome?
    @Published private(set) var fulfillmentAmbiguity: FulfillmentAmbiguityPresentation?
    @Published private(set) var fulfillmentConfirmation: FulfillmentConfirmation?

    /// Non-secret presentation for the helper's active claim, if any. The
    /// matching raw token is held separately in private store-only state.
    @Published private(set) var activeClaim: ActiveClaimPresentation?

    private let service: RequestService
    /// The app's existing installation credential (Week 3 Day 6 Slice 6E),
    /// read from the same storage `PushSubscriptionStore` uses. Reading it
    /// here has no default: an omitted provider must be a compile error, not
    /// a silently disconnected one, the same reasoning `ContentView` already
    /// applies to `remoteNotificationRegistrar` and `notificationRouter`. This
    /// is the only thing `RequestStore` knows about installations — no push
    /// preference, no APNs registration state, matching the accepted
    /// boundary that push state stays separate from this store.
    private let installationCredentialProvider: () -> String
    /// The verified participant credential this installation holds, or `nil`
    /// (W3-I1). Read from `ParticipantIdentityStore`, which owns the whole
    /// verification lifecycle; this store knows nothing else about identity —
    /// no address, no flow state, no storage — so the request flow cannot
    /// fabricate verification it was never granted. No default, matching
    /// `installationCredentialProvider`: an omitted provider must be a compile
    /// error rather than a silently unverified app.
    private let participantAuthorityProvider: () -> String?
    /// Invoked when the backend refuses the credential this store presented.
    /// The identity store owns discarding it; publishing the refusal back
    /// through a closure keeps this store from reaching into that lifecycle.
    private let participantAuthorityRejected: () -> Void
    /// Owns the W3-H1 five-minute local warning notification's lifecycle.
    /// `RequestStore` decides *when* one is due; this decides how it actually
    /// gets scheduled, rescheduled, and canceled. See
    /// `ReservationWarningScheduling` for why this stays UIKit/
    /// UserNotifications-free here.
    private let reservationWarningScheduler: ReservationWarningScheduling
    /// W3-D1's durable unresolved-create record. In-memory by default
    /// (`InMemoryPendingRequestOperationStorage`) so every pre-D1 call site
    /// and test keeps compiling unchanged; `ContentView` passes the real
    /// `UserDefaultsPendingRequestOperationStorage` for actual cross-launch
    /// durability.
    private let operationStorage: PendingRequestOperationStorage
    private var fetchGeneration = 0
    private var collectionRevision = 0
    private var activeClaimAuthorization: ActiveClaimAuthorization?
    private var activeClaimAttempt: ClaimAttempt?
    private var activeClaimExtensionAttempt: ClaimExtensionAttempt?
    private var activeClaimReleaseAttempt: ClaimReleaseAttempt?
    private var activeFulfillmentAttempt: FulfillmentAttempt?
    private var fulfillmentAmbiguityContext: FulfillmentAmbiguityContext?

    /// Actual scene visibility supplied by `ContentView`. A live process is
    /// not necessarily visible: inactive and background scenes must leave the
    /// local warning available instead of manufacturing a foreground warning.
    private var isApplicationVisible = false

    /// Whether the in-app reservation warning has already been shown for the
    /// claim's *current* deadline. Reset in `beginActiveClaim` (a new claim or
    /// a continuation-restored one starts a fresh cycle) and again on a
    /// successful extension (the deadline moved, so five minutes before the
    /// new one is a legitimately new warning instant) — but not on a failed
    /// extension, which leaves the deadline, and this flag, untouched.
    private var hasShownReservationWarning = false

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

    /// How far ahead of the reservation deadline the W3-H1 warning fires.
    /// Fixed at five minutes, matching the backend's own fixed
    /// `CLAIM_EXTENSION_MS` framing — this is presentation timing only, never
    /// a value the backend is asked to confirm.
    static let reservationWarningLead: TimeInterval = 5 * 60

    init(
        service: RequestService,
        installationCredentialProvider: @escaping () -> String,
        participantAuthorityProvider: @escaping () -> String?,
        participantAuthorityRejected: @escaping () -> Void,
        reservationWarningScheduler: ReservationWarningScheduling = NoOpReservationWarningScheduler(),
        operationStorage: PendingRequestOperationStorage = InMemoryPendingRequestOperationStorage()
    ) {
        self.service = service
        self.installationCredentialProvider = installationCredentialProvider
        self.participantAuthorityProvider = participantAuthorityProvider
        self.participantAuthorityRejected = participantAuthorityRejected
        self.reservationWarningScheduler = reservationWarningScheduler
        self.operationStorage = operationStorage
    }

    /// Applies a backend verdict on the credential just presented.
    ///
    /// Only `PARTICIPANT_AUTHORITY_INVALID` discards a stored identity: it is
    /// the backend saying the credential names nothing it will accept.
    /// `PARTICIPANT_VERIFICATION_REQUIRED` deliberately does not — that answer
    /// is what an unverified caller gets, and treating it as revocation would
    /// let an unrelated request wipe an identity that is perfectly valid.
    private func applyParticipantVerdict(
        _ error: RequestServiceError,
        presentedAuthority: String?
    ) {
        guard case .serverError(let code, _) = error,
              code == ParticipantErrorCode.authorityInvalid,
              let presentedAuthority,
              // The backend rejected the credential this request actually
              // sent. A newer Change Email result must not be erased by that
              // stale response; equality with the still-current credential is
              // the accepted W3-I1 response fence.
              participantAuthorityProvider() == presentedAuthority else {
            return
        }
        participantAuthorityRejected()
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

    /// Resolves a helper new-request notification tap's `requestId` against
    /// backend truth (`GET /api/request/:id`), per the accepted
    /// notification-tap contract: a `requestId` in the push payload is
    /// routing context only, and only current backend truth may decide the
    /// result. A decoded response settles it — `.open` is `.available`,
    /// anything else is an authoritative `.unavailable` — and an
    /// authoritative 404 (`RequestServiceError.notFound`, the document does
    /// not exist) is `.unavailable` too. A decoded `REQUEST_NOT_YET_AVAILABLE`
    /// is settled truth as well, and resolves to `.notYetAvailable`: the
    /// backend answered, it simply answered "not yet", which must not be
    /// reported as a transient failure the helper should retry into. Every
    /// other failure — transport, timeout, any other server status, or a
    /// decoding failure — means current truth could not be established, which
    /// resolves to `.temporarilyUnavailable` rather than being guessed as
    /// "gone".
    /// Rethrows only cancellation, so a caller whose screen went away before
    /// this finished can tell "no answer yet" apart from either resolved
    /// outcome.
    func resolveHelperNotificationRequest(id: String) async throws -> HelperNotificationResolution {
        try Task.checkCancellation()
        do {
            let request = try await service.fetchRequest(id: id)
            return request.status == .open ? .available(request) : .unavailable
        } catch is CancellationError {
            throw CancellationError()
        } catch RequestServiceError.notFound {
            return .unavailable
        } catch let error as RequestServiceError {
            if case .serverError(let code, _) = error,
               code == ClaimErrorCode.requestNotYetAvailable {
                return .notYetAvailable
            }
            return .temporarilyUnavailable
        } catch {
            return .temporarilyUnavailable
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
    /// W3-D1: mints one fresh operation identity for this exact intentional
    /// submission and persists the durable recovery record for it
    /// immediately before sending — after this point the operation may reach
    /// the backend, so the record must already be safe to survive
    /// termination. A decoded definitive non-create (`INVALID_OPERATION_ID`,
    /// `OPERATION_EXPIRED`, `OPERATION_UNAUTHORIZED`, and the ordinary
    /// pre-write rejection codes `RequestOperationErrorCode.isDefinitiveNonCreate`
    /// recognizes) retires the durable record, exactly like ordinary success
    /// does, so a later intentional submission mints its own new identity
    /// rather than being blocked by one that can never resolve.
    /// `ambiguousCreateOutcome` and any write-uncertain decoded server
    /// response (`RequestOperationErrorCode.isWriteUncertain` — currently
    /// only a readable `REQUEST_CREATION_FAILED`) instead arm the
    /// unresolved-create block, mirroring
    /// `reconcilePendingCreateOperationIfNeeded`'s own default: the backend
    /// may have written this exact operation, so nothing may mint a
    /// replacement identity or overwrite its durable record until
    /// authoritative reconciliation resolves it. A bare 404 and the
    /// `RATE_LIMITED` middleware refusal are also definitive non-creates:
    /// both retire the record without arming the block. Every other outcome
    /// preserves its existing behavior.
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
        // Filled in here, immediately before sending, rather than by
        // `RequestFoodView.makePayload`: the credential is store-owned
        // installation identity, not a form field, and this keeps every
        // existing call that builds a `CreateRequestPayload` directly
        // (including `RequestFoodView`'s own tests) unaware of it.
        var submittedPayload = payload
        submittedPayload.installationCredential = installationCredentialProvider()
        // Read here, immediately before sending, rather than captured at
        // init: an identity replaced by Change Email mid-session must bind
        // the request to the principal that is current now.
        let participantAuthority = participantAuthorityProvider()
        let operationId = UUID().uuidString
        if let participantAuthority,
           let participantIdentifier = Self.participantIdentifier(fromAuthority: participantAuthority) {
            operationStorage.save(
                PendingRequestOperationRecord(
                    operationId: operationId,
                    participantIdentifier: participantIdentifier,
                    vendor: submittedPayload.vendor,
                    food: submittedPayload.food,
                    pickupName: submittedPayload.pickupName,
                    timing: submittedPayload.timing,
                    windowStart: submittedPayload.windowStart,
                    mealSwipes: submittedPayload.mealSwipes
                )
            )
        }
        do {
            let created = try await service.createRequest(
                submittedPayload,
                operationId: operationId,
                participantAuthority: participantAuthority
            )
            operationStorage.clear()
            advanceCollectionRevision()
            applyConfirmed(created)
        } catch is CancellationError {
            // `RequestService.createRequest` only ever lets a raw
            // `CancellationError` reach here from its own leading
            // `Task.checkCancellation()` — before headers, body encoding, or
            // any `URLSession` call exist. Every cancellation at or after
            // that point is instead wrapped as
            // `.ambiguousCreateOutcome(underlying: CancellationError())` and
            // handled below. This is therefore a proven pre-transmission
            // cancellation of the record just saved above: no ambiguous
            // server mutation exists, so the record this attempt wrote must
            // be retired rather than left to be replayed as an unintended
            // submission on a later relaunch.
            operationStorage.clear()
            throw CancellationError()
        } catch {
            let serviceError = Self.asServiceError(error)
            createError = serviceError
            applyParticipantVerdict(
                serviceError,
                presentedAuthority: participantAuthority
            )
            switch serviceError {
            case .ambiguousCreateOutcome:
                unresolvedCreateError = serviceError
            case .notFound:
                // This service case is reserved for a route-level HTTP 404:
                // no create handler ran, so this exact operation did not
                // create anything and must not survive for relaunch replay.
                operationStorage.clear()
            case .serverError(let code, _) where RequestOperationErrorCode.isDefinitiveNonCreate(code):
                operationStorage.clear()
            case .serverError(let code, _) where RequestOperationErrorCode.isWriteUncertain(code):
                // The write result is not proven — e.g. a readable
                // `REQUEST_CREATION_FAILED`, which `createRequestRoute.ts`
                // can return from a path that follows a write attempt. Arm
                // the block exactly like an ambiguous transport outcome, so
                // a same-session retry cannot mint a replacement operation
                // that silently overwrites this operation's durable record.
                unresolvedCreateError = serviceError
            default:
                // Do not broaden either classification: other received
                // outcomes retain their existing behavior.
                break
            }
            throw serviceError
        }
    }

    /// W3-D1 relaunch reconciliation. Restores a durable unresolved
    /// request-create operation left over from a previous process (or an
    /// earlier ambiguous attempt still unresolved this session) and
    /// reconciles it against authoritative backend truth, using the exact
    /// same operation identity and submitted fields as the original attempt —
    /// never a newly minted identity and never a re-derived payload.
    ///
    /// Safe to call more than once — a no-op once nothing durable remains, and
    /// a no-op while a create is already in flight. Never exposes or acts on
    /// restored state that is malformed or bound to a different participant
    /// than the one currently verified: `.isValidRecord` and the
    /// participant-identifier comparison below are the only shape/authority
    /// checks this performs, and neither ever repairs or reinterprets what it
    /// finds. Returns `true` only once the restored operation has been
    /// confirmed created.
    @discardableResult
    func reconcilePendingCreateOperationIfNeeded() async -> Bool {
        guard !isCreating, let record = operationStorage.load() else {
            return false
        }
        guard Self.isValidRecord(record) else {
            // Never guessed at or repaired: unusable restored state is
            // retired outright, exactly like a definitive non-create outcome
            // would be, since there is nothing here that could ever be
            // reconciled.
            operationStorage.clear()
            return false
        }
        let participantAuthority = participantAuthorityProvider()
        guard let participantAuthority,
              let currentIdentifier = Self.participantIdentifier(fromAuthority: participantAuthority),
              currentIdentifier == record.participantIdentifier else {
            // Left in storage untouched: the participant it belongs to may
            // still return this session (or a later one). This session simply
            // cannot act on it, expose it, or fold it into an ordinary create
            // under a different identity.
            return false
        }

        // Restored state takes over immediately, before the network call:
        // the mere existence of a valid, participant-matched unresolved
        // operation already means "your request may already exist", the same
        // truth an in-process ambiguous outcome tells this store.
        if unresolvedCreateError == nil {
            unresolvedCreateError = .ambiguousCreateOutcome(underlying: PendingRequestOperationRestored())
        }
        isCreating = true
        createError = nil
        defer { isCreating = false }

        // Re-read here, immediately before sending, exactly like the fresh
        // path: the record itself never carries this — it is store-owned
        // installation identity, not part of the operation's durable
        // identity — so a recovered create restores the *current*
        // association rather than reconstructing a stale one.
        var recoveredPayload = Self.payload(from: record)
        recoveredPayload.installationCredential = installationCredentialProvider()

        do {
            let created = try await service.createRequest(
                recoveredPayload,
                operationId: record.operationId,
                participantAuthority: participantAuthority
            )
            operationStorage.clear()
            unresolvedCreateError = nil
            advanceCollectionRevision()
            applyConfirmed(created)
            return true
        } catch is CancellationError {
            return false
        } catch {
            let serviceError = Self.asServiceError(error)
            applyParticipantVerdict(
                serviceError,
                presentedAuthority: participantAuthority
            )
            switch serviceError {
            case .notFound:
                // The create route is absent at this base URL, so no handler
                // ran and this restored operation cannot have been created by
                // this response. Retire it like the fresh-create path does.
                operationStorage.clear()
                unresolvedCreateError = nil
            case .serverError(let code, _) where RequestOperationErrorCode.isDefinitiveNonCreate(code):
                operationStorage.clear()
                unresolvedCreateError = nil
            default:
                // Still unresolved: transport/decoding failures and every
                // other outcome leave both the durable record and the block
                // exactly as armed as they already were, so a later attempt —
                // automatic or the next relaunch — can reconcile the same
                // exact operation again.
                unresolvedCreateError = serviceError
            }
            return false
        }
    }

    /// The participant-identity segment of a verified authority credential —
    /// the same leading component `ParticipantAuthorityShape` parses — never
    /// the bearer authority itself. Used only to compare a restored W3-D1
    /// record against the currently verified participant; never sent
    /// anywhere and never usable on its own as a credential.
    private static func participantIdentifier(fromAuthority authority: String) -> String? {
        guard let separator = authority.firstIndex(of: ".") else { return nil }
        let identifier = String(authority[authority.startIndex..<separator])
        return identifier.isEmpty ? nil : identifier
    }

    private static let operationIdCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
    )

    /// Mirrors the backend's own `[A-Za-z0-9._-]{1,128}` operation-identity
    /// shape (`createRequestRoute.ts`) so a corrupted or foreign value in
    /// durable storage is never treated as recoverable.
    private static func isValidOperationId(_ value: String) -> Bool {
        (1...128).contains(value.count)
            && value.unicodeScalars.allSatisfy(operationIdCharacters.contains)
    }

    /// Whether a restored durable record is well-formed enough to reconcile
    /// at all — shape only, never a guess at what a malformed record "meant".
    private static func isValidRecord(_ record: PendingRequestOperationRecord) -> Bool {
        guard isValidOperationId(record.operationId),
              !record.participantIdentifier.isEmpty,
              !record.vendor.isEmpty,
              !record.food.isEmpty,
              !record.pickupName.isEmpty,
              (1...5).contains(record.mealSwipes) else {
            return false
        }
        switch record.timing {
        case .asap:
            return record.windowStart == nil
        case .scheduled:
            return record.windowStart != nil
        }
    }

    private static func payload(from record: PendingRequestOperationRecord) -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: record.vendor,
            food: record.food,
            pickupName: record.pickupName,
            timing: record.timing,
            windowStart: record.windowStart,
            mealSwipes: record.mealSwipes
        )
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
        let participantAuthority = participantAuthorityProvider()
        do {
            let outcome = try await service.claimRequest(
                id: requestID,
                participantAuthority: participantAuthority
            )
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
                    isExtensionAvailable: Self.extensionIsAvailable(
                        claimExpiresAt: outcome.claimExpiresAt,
                        claimExtendedAt: nil,
                        requestExpiresAt: outcome.request.expiresAt
                    )
                ),
                authorization: ActiveClaimAuthorization(
                    claimID: UUID(),
                    requestID: outcome.request.id,
                    claimToken: outcome.claimToken,
                    participantAuthority: nil
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
            applyParticipantVerdict(
                serviceError,
                presentedAuthority: participantAuthority
            )
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

    /// `GET /api/participant/active-reservation` (W3-H1 continuation).
    /// Reconstructs "do I have an active reservation, and which one" after a
    /// relaunch that did not go through `claim()` — process termination
    /// discards the in-memory claim (and the raw token was never persisted
    /// to begin with), but backend reservation truth outlives the process.
    ///
    /// A no-op whenever there is nothing to reconcile: a claim already held
    /// in this process (from `claim()` or an earlier continuation call), or
    /// no verified participant to ask on behalf of. Safe to call more than
    /// once and from more than one call site (`ContentView`'s launch-time
    /// `.task` and `ReservationWarningRouteDriver`, independently) — the
    /// first guard makes every call after the first a no-op.
    ///
    /// Never fabricates a reservation the backend does not currently confirm:
    /// transport/server/decode failure returns `.unknown` and leaves both
    /// `activeClaim` and existing warning state untouched. Cancellation still
    /// throws so a cold-launch routing attempt can leave its tap pending.
    func continueActiveReservationIfNeeded() async throws -> ActiveReservationContinuationOutcome {
        if let activeClaim {
            return .active(activeClaim)
        }
        guard let participantAuthority = participantAuthorityProvider() else {
            return .unknown
        }
        do {
            guard let reservation = try await service.fetchActiveReservation(
                participantAuthority: participantAuthority
            ) else {
                if let activeClaim {
                    return .active(activeClaim)
                }
                reservationWarningScheduler.cancelAllWarnings()
                return .none
            }
            // Re-checked after the `await`: a concurrent `claim()` (unlikely,
            // but not impossible if this races a fresh user-initiated claim)
            // must not be overwritten by a continuation read that started
            // before it.
            if let activeClaim {
                return .active(activeClaim)
            }
            let presentation = ActiveClaimPresentation(
                request: reservation.request,
                pickupName: reservation.pickupName,
                claimExpiresAt: reservation.claimExpiresAt,
                claimExtendedAt: reservation.claimExtendedAt,
                isExtensionAvailable: Self.extensionIsAvailable(
                    claimExpiresAt: reservation.claimExpiresAt,
                    claimExtendedAt: reservation.claimExtendedAt,
                    requestExpiresAt: reservation.request.expiresAt
                )
            )
            beginActiveClaim(
                presentation: presentation,
                authorization: ActiveClaimAuthorization(
                    claimID: UUID(),
                    requestID: reservation.request.id,
                    // The raw token was never persisted; continuation
                    // authorizes further actions on this claim (extend,
                    // release) with participant authority instead.
                    claimToken: nil,
                    // Capture the exact credential whose successful read
                    // established ownership. A later Change Email affects
                    // future participant actions, not this reservation.
                    participantAuthority: participantAuthority
                )
            )
            return .active(presentation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Backend truth could not be established (transport, timeout, a
            // server failure, or a decoding failure). Leaving `activeClaim`
            // nil and every existing warning untouched is the only truthful
            // answer here — never invent absence or active state.
            applyParticipantVerdict(
                Self.asServiceError(error),
                presentedAuthority: participantAuthority
            )
            return .unknown
        }
    }

    /// One presentation/action truth for explicit release. The destructive
    /// action is available only while this store would actually start the
    /// release operation: a matching, still-active claimed reservation exists
    /// and no release, extension, fulfillment, or ambiguity/recovery operation
    /// currently owns it.
    var canReleaseActiveClaim: Bool {
        guard !isReleasingClaim,
              activeClaimReleaseAttempt == nil,
              !isExtendingClaim,
              activeClaimExtensionAttempt == nil,
              fulfillmentAmbiguityContext == nil,
              !isFulfilling,
              activeFulfillmentAttempt == nil,
              let claim = activeClaim,
              claim.request.status == .claimed,
              claim.claimExpiresAt > Date(),
              let authorization = activeClaimAuthorization,
              authorization.requestID == claim.requestID else {
            return false
        }
        return true
    }

    /// `POST /api/request/:id/claim/release` (W3-H1). Atomically invalidates
    /// the caller's still-active reservation and restores the request to
    /// availability. Backend-confirmed before any local state clears: a
    /// failed or unconfirmed attempt leaves the claim exactly as it was, and
    /// — unlike claim/fulfill — is always safe to simply retry, because a
    /// release that already succeeded is refused cleanly rather than
    /// duplicated.
    func releaseActiveClaim() async {
        guard canReleaseActiveClaim,
              let claim = activeClaim,
              let authorization = activeClaimAuthorization,
              authorization.requestID == claim.requestID else {
            return
        }
        let attempt = ClaimReleaseAttempt(
            id: UUID(),
            claimID: authorization.claimID,
            requestID: authorization.requestID
        )
        activeClaimReleaseAttempt = attempt
        isReleasingClaim = true
        releaseClaimError = nil
        defer {
            if activeClaimReleaseAttempt == attempt {
                activeClaimReleaseAttempt = nil
                isReleasingClaim = false
            }
        }

        do {
            // The raw token, when still available, is preserved unchanged as
            // the primary authorization; participant authority is additive,
            // for the case a relaunch already discarded it.
            if let claimToken = authorization.claimToken {
                try await service.releaseClaim(id: authorization.requestID, claimToken: claimToken)
            } else {
                guard let participantAuthority = authorization.participantAuthority else {
                    return
                }
                try await service.releaseClaim(
                    id: authorization.requestID,
                    participantAuthority: participantAuthority
                )
            }
            guard activeClaimReleaseAttempt == attempt,
                  activeClaimAuthorization?.claimID == attempt.claimID,
                  activeClaim?.requestID == attempt.requestID else {
                return
            }
            clearActiveClaim()
            refreshRequestsAfterClaimConflict()
        } catch is CancellationError {
        } catch {
            guard activeClaimReleaseAttempt == attempt else {
                return
            }
            let serviceError = Self.asServiceError(error)
            releaseClaimError = serviceError
            applyParticipantVerdict(
                serviceError,
                presentedAuthority: authorization.participantAuthority
            )
        }
    }

    /// `POST /api/request/:id/claim/extend`, sending the active claim's raw
    /// token. Answering the prompt resolves it either way, so a failed or
    /// unconfirmed attempt cannot re-open the prompt into a retry loop, and
    /// the local expiration advances only on a confirmed backend response.
    var canExtendActiveClaim: Bool {
        guard !isExtendingClaim,
              activeClaimExtensionAttempt == nil,
              !isReleasingClaim,
              activeClaimReleaseAttempt == nil,
              fulfillmentAmbiguityContext == nil,
              !isFulfilling,
              activeFulfillmentAttempt == nil,
              let claim = activeClaim,
              claim.isExtensionAvailable,
              let authorization = activeClaimAuthorization,
              authorization.requestID == claim.requestID else {
            return false
        }
        return true
    }

    func extendActiveClaim() async {
        guard canExtendActiveClaim,
              let claim = activeClaim,
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
            // The raw token, when it is still available, is preserved
            // unchanged as the primary authorization. Participant authority
            // is additive, for the case a relaunch already discarded it
            // (W3-H1 continuation) — never the other way around.
            let outcome: ClaimExtensionOutcome
            if let claimToken = authorization.claimToken {
                outcome = try await service.extendClaim(
                    id: authorization.requestID,
                    claimToken: claimToken
                )
            } else {
                guard let participantAuthority = authorization.participantAuthority else {
                    // Continuation authorized this claim in the first place,
                    // so authority missing now means it was discarded (e.g. a
                    // rejected/revoked credential) after that. There is
                    // nothing to authorize this attempt with; `defer` above
                    // still resets the in-flight state normally.
                    return
                }
                outcome = try await service.extendClaim(
                    id: authorization.requestID,
                    participantAuthority: participantAuthority
                )
            }
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
            // The deadline moved: the W3-H1 warning is due again five minutes
            // before the new one, and the scheduled notification moves with
            // it.
            hasShownReservationWarning = false
            isShowingReservationWarning = false
            reservationWarningScheduler.scheduleWarning(
                requestID: attempt.requestID,
                fireAt: outcome.claimExpiresAt.addingTimeInterval(-Self.reservationWarningLead)
            )
            // The reservation moved, so the expiration timer is rescheduled
            // against the new backend deadline. No further prompt is possible.
            startClaimLifecycleTimer()
        } catch {
            guard extensionAttemptIsCurrent(attempt) else {
                return
            }
            let serviceError = Self.asServiceError(error)
            claimExtensionError = serviceError
            applyParticipantVerdict(
                serviceError,
                presentedAuthority: authorization.participantAuthority
            )
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

        reconcileExtensionAvailability()
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

    /// Reconciles the reservation-warning lifecycle with real SwiftUI scene
    /// visibility. Becoming visible also re-runs deadline/warning checks from
    /// the authoritative deadline. Becoming inactive/backgrounded while the
    /// due warning is currently owned by the in-app surface transfers that
    /// ownership back to the same request-keyed local notification path.
    func updateApplicationVisibility(isVisible: Bool, now: Date = Date()) {
        isApplicationVisible = isVisible
        if isVisible {
            revalidateActiveClaimExpiration(now: now)
            return
        }

        guard isShowingReservationWarning,
              let claim = activeClaim,
              let authorization = activeClaimAuthorization,
              authorization.requestID == claim.requestID,
              claim.claimExpiresAt > now,
              claim.claimExpiresAt.addingTimeInterval(-Self.reservationWarningLead) <= now else {
            return
        }

        // The app can no longer truthfully own a visible presentation. Retire
        // that ownership and make the already-due request-keyed notification
        // eligible immediately. Resetting the foreground latch lets an active
        // re-entry that wins before delivery cancel this local duplicate and
        // restore the in-app warning from the same authoritative deadline.
        isShowingReservationWarning = false
        hasShownReservationWarning = false
        reservationWarningScheduler.scheduleWarning(
            requestID: claim.requestID,
            fireAt: now
        )
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
        // A new claim — including one just restored by continuation — starts
        // its own W3-H1 warning cycle.
        hasShownReservationWarning = false
        isShowingReservationWarning = false
        invalidateActiveReleaseAttempt()
        releaseClaimError = nil
        reservationWarningScheduler.scheduleWarning(
            requestID: presentation.requestID,
            fireAt: presentation.claimExpiresAt.addingTimeInterval(-Self.reservationWarningLead)
        )
        // The attempt that was "already starting" has finished starting.
        clearPreflightClaimRefusal { error in
            if case .operationInProgress = error { return true }
            return false
        }
        startClaimLifecycleTimer()
    }

    private func clearActiveClaim() {
        let clearedClaimID = activeClaimAuthorization?.claimID
        let clearedRequestID = activeClaimAuthorization?.requestID ?? activeClaim?.requestID
        claimLifecycleTask?.cancel()
        claimLifecycleTask = nil
        invalidateActiveExtensionAttempt()
        invalidateActiveFulfillmentAttempt()
        invalidateActiveReleaseAttempt()
        activeClaim = nil
        activeClaimAuthorization = nil
        isShowingClaimExtensionPrompt = false
        hasResolvedClaimExtensionPrompt = false
        isShowingReservationWarning = false
        hasShownReservationWarning = false
        claimExtensionError = nil
        releaseClaimError = nil
        if let clearedRequestID {
            // Covers every path that ends a claim locally: release, confirmed
            // fulfillment, expiry, and a lost claim conflict. One hook, so
            // "canceled on release/fulfill/expiry/claim-end" cannot drift out
            // of sync as new end-of-claim paths are added.
            reservationWarningScheduler.cancelWarning(requestID: clearedRequestID)
        }
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

    private func invalidateActiveReleaseAttempt() {
        activeClaimReleaseAttempt = nil
        isReleasingClaim = false
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
        let warningMoment = expiration.addingTimeInterval(-Self.reservationWarningLead)
        let promptMoment = expiration.addingTimeInterval(-Self.claimExtensionPromptLead)

        claimLifecycleTask = Task { [weak self] in
            // T-5 always precedes T-3 (five minutes remaining comes before
            // three), so this step's own effect — resolving the T-3 prompt
            // once the warning has something to say about the same decision
            // — always lands before the T-3 step below can run.
            if let interval = Self.secondsUntil(warningMoment) {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.presentReservationWarningIfEligible(
                claimID: claimID,
                requestID: requestID,
                expiration: expiration
            )

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

    /// One presentation truth for every path that constructs or revalidates a
    /// reservation: the extension is unused and the complete fixed five
    /// minutes still fit before the request's authoritative expiry.
    static func extensionIsAvailable(
        claimExpiresAt: Date,
        claimExtendedAt: Date?,
        requestExpiresAt: Date
    ) -> Bool {
        claimExtendedAt == nil
            && claimExpiresAt.addingTimeInterval(Self.claimExtensionDuration) <= requestExpiresAt
    }

    private func reconcileExtensionAvailability() {
        guard var claim = activeClaim,
              claim.isExtensionAvailable,
              !Self.extensionIsAvailable(
                claimExpiresAt: claim.claimExpiresAt,
                claimExtendedAt: claim.claimExtendedAt,
                requestExpiresAt: claim.requestExpiresAt
              ) else {
            return
        }
        claim.isExtensionAvailable = false
        activeClaim = claim
    }

    /// The W3-H1 five-minute warning's foreground half. Fires once per warning
    /// cycle (`hasShownReservationWarning`), only while actual scene state is
    /// visible. A merely alive background process leaves the scheduled local
    /// notification untouched; the visible path cancels it here rather than
    /// let both surfaces interrupt for the same live moment.
    ///
    /// Also resolves the pre-existing T-3 "Still ordering?" prompt: the
    /// warning now carries the same `Add 5 minutes` / `Release reservation`
    /// actions the T-3 prompt exists to offer, so letting T-3 still interrupt
    /// two minutes later would ask the same question twice.
    private func presentReservationWarningIfEligible(
        claimID: UUID,
        requestID: String,
        expiration: Date
    ) {
        guard let claim = activeClaim,
              activeClaimAuthorization?.claimID == claimID,
              claim.requestID == requestID,
              claim.claimExpiresAt == expiration,
              isApplicationVisible,
              !hasShownReservationWarning else {
            return
        }
        hasShownReservationWarning = true
        isShowingReservationWarning = true
        hasResolvedClaimExtensionPrompt = true
        isShowingClaimExtensionPrompt = false
        reservationWarningScheduler.cancelWarning(requestID: requestID)
        reconcileExtensionAvailability()
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
              isApplicationVisible,
              claim.isExtensionAvailable,
              canExtendActiveClaim,
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

    /// Reports a helper new-request notification's tapped request as
    /// unavailable, reusing the same Active Requests recovery presentation a
    /// rejected claim attempt gets. There is no claim attempt behind a
    /// notification tap, so `operationID` is a fresh identity scoped only to
    /// this one notice rather than one correlated to an in-flight operation.
    func reportRequestUnavailableFromNotification(requestID: String) {
        reportClaimUnavailable(
            .noLongerAvailable,
            requestID: requestID,
            operationID: UUID(),
            backendCode: nil
        )
    }

    /// Reports a helper new-request notification's tapped request as not yet
    /// started, using the same Active Requests recovery presentation. Distinct
    /// from both neighbours: the backend gave settled truth, so this is not
    /// `reportRequestTemporarilyUnavailableFromNotification`, and the truth it
    /// gave was "not yet", so it is not
    /// `reportRequestUnavailableFromNotification` either.
    func reportRequestNotYetAvailableFromNotification(requestID: String) {
        reportClaimUnavailable(
            .notYetAvailable,
            requestID: requestID,
            operationID: UUID(),
            // `nil`, like both sibling notification reporters: the reason
            // already carries everything the recovery notice presents, and a
            // notification tap is not a claim attempt whose backend code
            // anything downstream correlates against.
            backendCode: nil
        )
    }

    /// Reports a helper new-request notification's tapped request as
    /// resolvable-truth-unknown right now, using the same Active Requests
    /// recovery presentation as a confirmed-unavailable tap. Distinct from
    /// `reportRequestUnavailableFromNotification`: this must never claim the
    /// request is gone, since backend truth could not be established.
    func reportRequestTemporarilyUnavailableFromNotification(requestID: String) {
        reportClaimUnavailable(
            .temporarilyUnavailable,
            requestID: requestID,
            operationID: UUID(),
            backendCode: nil
        )
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
        orderNumber: String,
        eta: String,
        contactMessage: String?,
        now: Date = Date()
    ) async throws {
        guard !isFulfilling else {
            throw RequestServiceError.operationInProgress
        }
        guard !isReleasingClaim, activeClaimReleaseAttempt == nil else {
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
              // Fulfillment now accepts the same additive participant-authority
              // path extend/release already do (W3-H1 MUST FIX 1): a claim
              // restored by continuation, with no raw token, can be fulfilled
              // from this process too, not only viewed, extended, and released.
              let fulfillmentAuthorization = resolveFulfillmentAuthorization(authorization) else {
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
            orderNumber: orderNumber,
            eta: eta,
            contactMessage: contactMessage
        )
        let attempt = FulfillmentAttempt(
            id: UUID(),
            claimID: authorization.claimID,
            requestID: requestID,
            submission: submission,
            authorization: fulfillmentAuthorization,
            originatingAmbiguityID: nil
        )
        try await performFulfillment(attempt: attempt)
    }

    /// Resolves how to authorize a fulfillment POST for the active claim
    /// (W3-H1 continuation): the raw token, preserved unchanged, when it is
    /// still available; verified participant authority, additive, for the
    /// case a relaunch already discarded it. `nil` only when neither is
    /// available — the credential store's own precondition failure, not a
    /// backend refusal.
    private func resolveFulfillmentAuthorization(
        _ authorization: ActiveClaimAuthorization
    ) -> FulfillmentAuthorization? {
        if let claimToken = authorization.claimToken, !claimToken.isEmpty {
            return .token(claimToken)
        }
        guard let participantAuthority = authorization.participantAuthority,
              !participantAuthority.isEmpty else {
            return nil
        }
        return .participant(participantAuthority)
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
        guard !isReleasingClaim, activeClaimReleaseAttempt == nil else {
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
              authorization.requestID == requestID else {
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
            authorization: context.authorization,
            originatingAmbiguityID: context.id
        )
        try await performFulfillment(attempt: attempt)
    }

    private func performFulfillment(attempt: FulfillmentAttempt) async throws {
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
            let outcome: FulfillOutcome
            switch attempt.authorization {
            case .token(let claimToken):
                outcome = try await service.fulfillRequest(
                    id: attempt.requestID,
                    claimToken: claimToken,
                    orderNumber: attempt.submission.orderNumber,
                    eta: attempt.submission.eta,
                    contactMessage: attempt.submission.contactMessage
                )
            case .participant(let participantAuthority):
                outcome = try await service.fulfillRequest(
                    id: attempt.requestID,
                    participantAuthority: participantAuthority,
                    orderNumber: attempt.submission.orderNumber,
                    eta: attempt.submission.eta,
                    contactMessage: attempt.submission.contactMessage
                )
            }
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
            applyParticipantVerdict(
                serviceError,
                presentedAuthority: attempt.authorization.participantAuthority
            )
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
              !isReleasingClaim,
              activeClaimReleaseAttempt == nil,
              activeClaimExtensionAttempt == nil,
              fulfillmentAmbiguityContext == nil,
              fulfillmentConfirmation?.requestID != requestID,
              let claim = activeClaim,
              claim.requestID == requestID,
              claim.claimExpiresAt > now,
              let authorization = activeClaimAuthorization,
              authorization.requestID == requestID,
              // A continuation-restored claim (no raw token) can now be
              // fulfilled too (W3-H1 MUST FIX 1), authorized by verified
              // participant authority instead.
              resolveFulfillmentAuthorization(authorization) != nil else {
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
                  existingContext.authorization == attempt.authorization,
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
                authorization: attempt.authorization,
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
