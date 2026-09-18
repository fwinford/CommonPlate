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
/// that a full five-minute extension cannot fit and never offer an extension
/// that could only fail.
struct ActiveClaimPresentation {
    /// The confirmed public request this claim reserves, exactly as the claim
    /// response returned it. Held so the claimant flow can be re-entered from
    /// Active Requests after the detail screen that started the claim is gone —
    /// including a claim that confirmed late — without re-fetching, re-claiming,
    /// or depending on the request still appearing in the public collection.
    let request: FoodRequest
    fileprivate(set) var claimExpiresAt: Date
    fileprivate(set) var claimExtendedAt: Date?
    fileprivate(set) var isExtensionAvailable: Bool

    var requestID: String {
        request.id
    }

    var requestExpiresAt: Date {
        request.expiresAt
    }

    /// The one permitted extension has been granted, so no further extension
    /// request may be made.
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

/// W4-R4: marks an `unresolvedCreateError` armed because durable storage
/// holds a pending-operation record whose recovery identity this build cannot
/// read (W4-D2 identity-unavailable). Something was
/// persisted, so an operation may exist server-side; the block fails closed
/// rather than treating the record as absent and letting a second logical
/// create begin.
private struct PendingRequestOperationUnreadable: Error {}

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
    /// W4-H1: the request is not open and continuation truth confirms it is
    /// this helper's own active reservation. Never produced by
    /// `resolveHelperNotificationRequest(id:)` alone — the request's status
    /// cannot establish who holds it — only by combining that `.unavailable`
    /// answer with `resolveHeldRequestForNotification(requestID:)`. Carries
    /// the active claim's own request.
    case heldByCurrentHelper(FoodRequest)
}

/// W4-H1: whether a not-open notification request is this helper's own
/// active reservation, from the same continuation authority the
/// reservation-warning tap uses (`docs/system-contract.md` section 8.4).
enum HeldRequestNotificationTruth: Equatable {
    /// Confirmed: this helper's active reservation is for exactly this
    /// request. Carries the active claim's own request.
    case held(FoodRequest)
    /// Confirmed: no active reservation, or one for a different request.
    case notHeld
    /// Continuation truth could not be established. Never absence.
    case unknown
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
    /// W4-D2 terminal NO-CREATE on `POST /api/request`: this exact identity
    /// was terminalized and can never create.
    static let operationNotCreated = "OPERATION_NOT_CREATED"

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
    ///
    /// W4-D2: this classification is only for the single transmission of a
    /// freshly minted identity, where a received pre-write rejection proves
    /// that attempt created nothing. Recovery of an already-issued operation
    /// uses `isTerminalOperationRetirement`/`isPostLookupRefusal` instead,
    /// because there an earlier transmission may still be in flight.
    static func isDefinitiveNonCreate(_ code: String) -> Bool {
        code == invalidOperationId
            || code == operationUnauthorized
            || code == operationExpired
            || code == operationNotCreated
            || code == invalidVendor
            || code == participantPrincipalMismatch
            || code == invalidRequest
            || code == requestLimitReached
            || code == rateLimited
    }

    /// W4-D2 recovery: operation-identity answers that retire an issued
    /// operation because it can never create again — it already created and
    /// has expired, the identity belongs to someone else, or the identity is
    /// one no create could ever accept. Terminal NO-CREATE is handled
    /// separately because the requester is told about it.
    static func isTerminalOperationRetirement(_ code: String) -> Bool {
        code == invalidOperationId
            || code == operationUnauthorized
            || code == operationExpired
    }

    /// W4-D2 recovery: refusals `createRequestRoute.ts` returns only after the
    /// identity lookup found nothing. "Nothing yet" is not terminal — an
    /// earlier transmission can still commit — so these are never retirement
    /// on their own; they send recovery to exact terminal reconciliation.
    static func isPostLookupRefusal(_ code: String) -> Bool {
        code == invalidVendor
            || code == participantPrincipalMismatch
            || code == invalidRequest
            || code == requestLimitReached
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

    /// W4-D2 ledger-authority refusals (`requestOperationAuthority.ts`),
    /// returned before the ledger is read or written. A mismatch means the
    /// backend answering is not the ledger the operation was recorded
    /// against; unavailable means it could not tell.
    static let operationAuthorityMismatch = "OPERATION_AUTHORITY_MISMATCH"
    static let operationAuthorityUnavailable = "OPERATION_AUTHORITY_UNAVAILABLE"
    static let publicActionsPaused = "PUBLIC_ACTIONS_PAUSED"

    /// W4-D2: refusals produced before the create handler reaches the
    /// operation ledger at all — the pause guard, the participant gate, and
    /// the ledger-authority check. For the single transmission of a freshly
    /// minted identity they prove, exactly like `isDefinitiveNonCreate`, that
    /// the attempt created nothing, so that attempt's durable record is
    /// retired rather than left to be replayed later beside a newer
    /// submission. During recovery they prove nothing about an earlier
    /// transmission and keep the operation pending.
    static func isPreLedgerRefusal(_ code: String) -> Bool {
        code == publicActionsPaused
            || code == ParticipantErrorCode.verificationRequired
            || code == ParticipantErrorCode.authorityInvalid
            || code == ParticipantErrorCode.verificationUnavailable
            || code == operationAuthorityMismatch
            || code == operationAuthorityUnavailable
    }
}

/// W4-D2: what the requester is told about W3-D1 create recovery. Store-owned;
/// the recovery identity and payload themselves never leave the store.
enum RequestCreateRecoveryPresentation: Equatable {
    case none
    /// An issued operation's exact recovery identity is known but its outcome
    /// is not. `canCheckAgain` is true only when another exact reconciliation
    /// from this installation can change the answer — never for a record
    /// whose recorded authority does not match (or predates recording one).
    case unresolved(canCheckAgain: Bool)
    /// Something is persisted but its recovery identity cannot be read.
    /// Nothing can be checked or cleared.
    case identityUnavailable
    /// Backend authority established terminal NO-CREATE for the operation.
    /// Informational until acknowledged; it blocks nothing.
    ///
    /// W4-D2 2026-09-17 Path A/B split, FIX 2026-09-18 (independent-review
    /// MUST FIX 1): the exact ambiguity-recovery payload remains private to
    /// `RequestStore` — this presentation carries only which terminal
    /// NO-CREATE case applies, never the frozen `CreateRequestPayload`
    /// itself. `.notCreatedRecoverable` is Path A: the payload was actually
    /// readable at the moment NO-CREATE was established, and
    /// `consumeRecoverableDraftForReturnToRequest()` is the one store-owned
    /// way to act on it. `.notCreatedUnavailable` is Path B: NO-CREATE was
    /// reached with an unreadable payload (matrix row 2), so
    /// `Start a new request` opens an empty form.
    case notCreatedRecoverable
    case notCreatedUnavailable
}

/// Stable backend claim and extension error codes, centralized so handling
/// cannot drift into scattered string literals.
enum ClaimErrorCode {
    static let invalidRequestID = "INVALID_REQUEST_ID"
    static let requestNotFound = "REQUEST_NOT_FOUND"
    static let requestAlreadyClaimed = "REQUEST_ALREADY_CLAIMED"
    static let requestAlreadyPlaced = "REQUEST_ALREADY_PLACED"
    /// W3-H2: this verified participant already successfully held this exact
    /// request once before and can never reacquire it, even though the
    /// request itself may currently be open again for other helpers.
    static let requestAlreadyParticipated = "REQUEST_ALREADY_PARTICIPATED"
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

/// W4-D2 Success→Home continuity state.
///
/// Deliberately not a bare `FoodRequest?`: a plain optional carries no
/// evidence of *which* operation produced it or *whose* it is, so a value
/// left behind by an interrupted earlier operation is indistinguishable from
/// a live one and can be presented for a later, unrelated create. Every field
/// here exists to make that reuse structurally impossible:
///
/// - `id` is the presentation identity. Retirement is addressed to it, so a
///   late callback from a superseded presentation can only ever retire its
///   own.
/// - `operationId` binds the presentation to the exact request-create
///   operation backend authority confirmed CREATED.
/// - `participantAuthority` is the authority current at that confirmation,
///   so an authority change can retire it without guessing.
/// - `request` is the ownership-resolved requester-owned request itself, as
///   `applyConfirmed` resolved it under that same authority — the actual
///   Home card, never a synthetic or approximate one.
struct RequestCreationContinuity: Identifiable, Equatable {
    let id: UUID
    let operationId: String
    let participantAuthority: String
    let request: FoodRequest

    init(
        id: UUID = UUID(),
        operationId: String,
        participantAuthority: String,
        request: FoodRequest
    ) {
        self.id = id
        self.operationId = operationId
        self.participantAuthority = participantAuthority
        self.request = request
    }
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

    /// True once an initial (never-yet-succeeded) fetch has actually finished
    /// and failed at least one time. `initialFetchError` alone cannot signal
    /// this to a view: `fetchRequests()` clears it back to `nil` the instant a
    /// retry begins, at the same synchronous point that also sets
    /// `hasAttemptedRequestFetch = true` and `isLoadingInitialRequests = true`
    /// — so a first-ever attempt in flight and a retry-after-failure in
    /// flight publish an otherwise identical snapshot of every other property
    /// above. `HomeExchangeView` needs to tell those apart so a retry stays
    /// on the already-resolved Exchange Unavailable presentation instead of
    /// regressing to the bare initial-loading one. Reset to `false` only by a
    /// later success, matching `hasSuccessfullyFetchedRequests`'s own
    /// one-directional shape; harmless to leave `true` after success since
    /// callers only ever consult it while `hasSuccessfullyFetchedRequests`
    /// is still `false`.
    @Published private(set) var hasFailedInitialFetchAtLeastOnce = false

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
    /// logical operation. W4-D2: derived by `refreshPendingCreateState()`
    /// from the durable entries and the participant current now, so it
    /// follows participant changes; an operation leaves it only through an
    /// authoritative backend outcome for that exact operation: created
    /// (`201`/reconciled `200`), terminal NO-CREATE, `OPERATION_EXPIRED`,
    /// `INVALID_OPERATION_ID`, or `OPERATION_UNAUTHORIZED`. It is never
    /// cleared just because an operation could not be reconciled this
    /// attempt.
    @Published private(set) var unresolvedCreateError: RequestServiceError?

    /// Read-only projection of the process-lifetime create block, for views
    /// that need to render it but have no use for the underlying error.
    var hasUnresolvedCreateAmbiguity: Bool {
        unresolvedCreateError != nil
    }

    /// W4-D2: which recovery state Request Food presents. Derived with
    /// `unresolvedCreateError`: `.unresolved`/`.identityUnavailable` exactly
    /// while the block is armed, `.notCreated` only after authoritative
    /// terminal NO-CREATE retired an operation and nothing else blocks.
    @Published private(set) var createRecoveryPresentation: RequestCreateRecoveryPresentation = .none

    /// W4-D2 Success→Home continuity: the one live continuity presentation,
    /// scoped to the exact operation just authoritatively confirmed CREATED
    /// for the authority current at that confirmation. Never a bare
    /// "last created request" — see `RequestCreationContinuity` for why the
    /// identity is what makes stale reuse structurally impossible.
    ///
    /// Published only by the two create-confirmation sites
    /// (`createRequest(_:)` and `reconcilePendingCreateOperationIfNeeded()`),
    /// and only when `applyConfirmed`'s own single still-current-authority
    /// read actually resolved the created request as this participant's own
    /// and inserted it. An authority that changed mid-flight therefore
    /// publishes nothing at all, so no surface can present a fabricated or
    /// stale actual-card continuity for it.
    ///
    /// Retired by `retireCreationContinuity(id:)` on every path that ends the
    /// presentation or supersedes it: the landing itself, the presenting
    /// view's disappearance/cancellation, a later create attempt, a later
    /// reconciliation pass, and any participant/authority change observed by
    /// `refreshPendingCreateState()`.
    @Published private(set) var createdRequestContinuity: RequestCreationContinuity?

    /// Retires the continuity presentation identified by `id`, and only that
    /// one. Taking the identity rather than clearing unconditionally is the
    /// point: a late callback from a superseded presentation (a cancelled
    /// Success task, a disappearing view) can never retire the continuity of
    /// an operation confirmed after it. Idempotent, and a no-op for an
    /// identity that is no longer current.
    func retireCreationContinuity(id: UUID) {
        guard createdRequestContinuity?.id == id else { return }
        createdRequestContinuity = nil
    }

    /// Publishes continuity for one authoritatively confirmed CREATED
    /// operation. Any earlier continuity is superseded in the same step, so
    /// two can never be live at once.
    private func publishCreationContinuity(
        operationId: String,
        participantAuthority: String,
        request: FoodRequest
    ) {
        createdRequestContinuity = RequestCreationContinuity(
            operationId: operationId,
            participantAuthority: participantAuthority,
            request: request
        )
    }

    /// Retires any live continuity whose authority is no longer the one
    /// current now — a participant verified, replaced, removed, or discarded
    /// mid-presentation. Called from `refreshPendingCreateState()`, which is
    /// already the one place participant change is re-derived locally, so no
    /// surface has to re-derive authority for itself.
    private func retireCreationContinuityIfAuthorityChanged() {
        guard let continuity = createdRequestContinuity else { return }
        guard participantAuthorityProvider() == continuity.participantAuthority else {
            createdRequestContinuity = nil
            return
        }
    }

    /// W4-D2 in-process recovery bookkeeping. The durable entries themselves
    /// are the recovery state; these only refine how it is presented.
    ///
    /// - `unrecordedCreateAmbiguity`: an ambiguous create that has no durable
    ///   entry (no participant identity, or storage refused it). Nothing can
    ///   reconcile it, so it blocks for the rest of the process.
    /// - `pendingCreateErrors`: the latest in-process error per recorded
    ///   operation, presented while that operation blocks.
    /// - `authorityMismatchedOperations`: operations a different ledger
    ///   answered for this process; no check from here can resolve them.
    /// - `inFlightCreateOperationId`: the fresh create being posted right
    ///   now, whose own entry is not yet a block.
    /// - `hasNotCreatedNotice`: terminal NO-CREATE retired an operation and
    ///   the requester has not yet chosen `Return to request`/`Start a new
    ///   request`.
    /// - `notCreatedRecoverablePayload`: the frozen payload behind that
    ///   notice, exactly as `reconcilePendingCreateOperationIfNeeded()`
    ///   established it (Path A) — `nil` when the payload was unreadable at
    ///   that moment (Path B). Meaningful only while `hasNotCreatedNotice`.
    private var unrecordedCreateAmbiguity: RequestServiceError?
    private var pendingCreateErrors: [String: RequestServiceError] = [:]
    private var authorityMismatchedOperations: Set<String> = []
    private var inFlightCreateOperationId: String?
    private var hasNotCreatedNotice = false
    private var notCreatedRecoverablePayload: CreateRequestPayload?

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

    // W4-H1 removes the pre-H1 T−3 extension prompt (`Need more time?`) and
    // its published state entirely. The Helping page's always-visible
    // `+ Add 5 minutes` control is the one place the single extension is
    // offered; `ActiveClaimPresentation.isExtensionAvailable` alone carries
    // whether that offer still stands.

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

    /// W3-I4: whether this process has established, from backend truth or a
    /// definitively-known in-process transition, whether an H1
    /// reservation/fulfillment-continuation exists that Remove Email must
    /// not strand. Starts `false` (fail closed) at cold/relaunch, before
    /// `continueActiveReservationIfNeeded()` has run. A relaunch read that
    /// comes back inconclusive (transport/server failure, cancellation,
    /// contradictory backend state) leaves this `false` for the rest of the
    /// process rather than guessing safety — matching `activeClaim` itself
    /// never fabricating absence. A fresh `claim()` or a definitive
    /// continuation result each establish it directly; nothing ever resets
    /// it back to `false`, since once known, this process's own live state
    /// changes keep it accurate on their own.
    @Published private(set) var hasResolvedReservationStateForRemoval = false

    /// W3-I4: the same fail-closed readiness, for W3-D1's durable
    /// request-create recovery. Starts `false` at cold/relaunch, before
    /// `reconcilePendingCreateOperationIfNeeded()` has run; a fresh
    /// `createRequest()` also establishes it directly. Never reset once
    /// `true`.
    @Published private(set) var hasResolvedPendingCreateStateForRemoval = false

    /// W3-I4: combined fail-closed readiness gate for Remove Email. `false`
    /// until this process has established both halves of the accepted
    /// removal-safety matrix from backend truth — never merely from the
    /// relaunch-reconciliation calls having returned, since an inconclusive
    /// outcome must not be treated as safe.
    var hasEstablishedRemovalSafety: Bool {
        hasResolvedReservationStateForRemoval && hasResolvedPendingCreateStateForRemoval
    }

    /// W4-R2 2026-09-06 sync (overlap-safety correction, same-day rereview):
    /// presentation-only in-flight count distinguishing "at least one
    /// `continueActiveReservationIfNeeded()` read is actively in flight" from
    /// "every such read has ended, at least one inconclusively, and this
    /// process will not resolve removal safety further on its own."
    /// `hasResolvedReservationStateForRemoval` alone cannot express that
    /// distinction — an inconclusive outcome leaves it `false` forever,
    /// identically to before any read ever started. A plain Boolean set
    /// before the read and cleared in `defer` is unsafe under overlapping
    /// calls (`ContentView`'s launch `.task` and
    /// `ReservationWarningRouteDriver` can each call this): call A finishing
    /// would clear the flag while call B is still in flight, which the
    /// Settings presentation would misread as "settled" while a check is
    /// genuinely still running. A count balanced on every exit (success,
    /// inconclusive error, cancellation) stays accurate under any number of
    /// overlapping callers. This grants no removal-eligibility authority of
    /// its own: it only brackets the one network read inside
    /// `continueActiveReservationIfNeeded()` that can leave removal safety
    /// unresolved, so a view can stop showing a spinner only once no such
    /// read remains in flight.
    @Published private(set) var reservationStateResolutionCount = 0

    /// The externally observed presentation signal: `true` while at least
    /// one relevant read is in flight, `false` only once the last one has
    /// exited. Never itself removal-eligibility authority — see
    /// `reservationStateResolutionCount`'s own documentation.
    var isResolvingReservationStateForRemoval: Bool {
        reservationStateResolutionCount > 0
    }

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
    /// The participant authority whose caller-relative ownership the current
    /// `requests` collection carries (W4-H2). `nil` means no current-authority
    /// ownership evidence backs the collection, so every entry is
    /// `.unresolved` and fails closed.
    private var ownershipAuthority: String?
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
    /// discover the warning moment or the expiration moment.
    private var claimLifecycleTask: Task<Void, Never>?

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
        // W4-D2: a discarded identity can no longer reconcile anything, and
        // whose pending operation remains is no longer established.
        refreshPendingCreateState()
    }

    var isFetching: Bool {
        isLoadingInitialRequests || isRefreshingRequests
    }

    /// Re-resolves one request's caller-relative ownership against the
    /// participant authority that is current *now* (W4-H2).
    ///
    /// A `FoodRequest` carried by navigation holds whatever ownership was
    /// resolved when it was materialized — possibly under an anonymous
    /// session, or under a participant since replaced. Before any helper
    /// mutation may proceed on the strength of "not your request", that
    /// conclusion has to be re-established for whoever is current.
    ///
    /// Fails closed: any transport, decode, or authority failure returns
    /// `.unresolved` rather than a guess, and a participant change during the
    /// read invalidates the answer it was about to give.
    func resolveOwnership(requestID: String) async -> RequestOwnership {
        let requestingAuthority = participantAuthorityProvider()
        do {
            let request = try await service.fetchRequest(
                id: requestID,
                participantAuthority: requestingAuthority
            )
            guard participantAuthorityProvider() == requestingAuthority else {
                return .unresolved
            }
            return request.ownership
        } catch {
            return .unresolved
        }
    }

    /// Invalidates caller-relative ownership the instant the current
    /// participant authority stops matching the one that produced it, then
    /// reloads through the one authoritative path (W4-H2).
    ///
    /// This runs *before* the reload rather than relying on the reload to
    /// repair the window: between a successful verification, Change Email, or
    /// Remove Email and the arrival of replacement truth, the previous
    /// participant's `own`/`notOwn` conclusions are not the new participant's.
    /// Public request data is preserved — the board does not blank — but
    /// helper actionability fails closed until ownership resolves for whoever
    /// is current now.
    ///
    /// Creates no second request-list truth owner: it only downgrades an
    /// ownership field and delegates the reload to `fetchRequests()`.
    func reconcileOwnershipForCurrentAuthority() async {
        if participantAuthorityProvider() != ownershipAuthority {
            ownershipAuthority = nil
            requests = requests.map { $0.withOwnership(.unresolved) }
        }
        await fetchRequests()
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

        // W4-H2: caller-relative ownership is meaningful only for the exact
        // authority that produced it, so the authority is captured here and
        // re-checked below rather than only being read at send time. Without
        // this, an anonymous or participant-A list result that lands after
        // verification or a successful Change Email would install A-relative
        // ownership as B's truth — labelling B's own request helpable, or
        // suppressing Reserve on a request B may legitimately help.
        let requestingAuthority = participantAuthorityProvider()
        do {
            let fetchedRequests = try await service.fetchActiveRequests(
                participantAuthority: requestingAuthority
            )
            guard generation == fetchGeneration,
                  startingCollectionRevision == collectionRevision else {
                return
            }
            guard participantAuthorityProvider() == requestingAuthority else {
                // The participant changed while this was in flight. The public
                // request data is still usable, but its caller-relative
                // ownership belongs to a principal who is no longer current,
                // so it is applied only in the fail-closed `.unresolved`
                // state. The identity change itself triggers a fresh fetch
                // (see `reconcileOwnershipForCurrentAuthority`), which is what
                // establishes ownership for the new participant.
                requests = fetchedRequests.map { $0.withOwnership(.unresolved) }
                ownershipAuthority = nil
                hasSuccessfullyFetchedRequests = true
                hasFailedInitialFetchAtLeastOnce = false
                return
            }
            requests = fetchedRequests
            ownershipAuthority = requestingAuthority
            hasSuccessfullyFetchedRequests = true
            hasFailedInitialFetchAtLeastOnce = false
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
                hasFailedInitialFetchAtLeastOnce = true
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
        // W4-H2: the detail route derives caller-relative ownership for the
        // authority presented here, so that answer is authoritative only
        // while the same authority is current. A participant change mid-flight
        // makes the returned `own`/`notOwn` a conclusion about someone else.
        let requestingAuthority = participantAuthorityProvider()
        do {
            let request = try await service.fetchRequest(
                id: id,
                participantAuthority: requestingAuthority
            )
            let resolved = participantAuthorityProvider() == requestingAuthority
                ? request
                : request.withOwnership(.unresolved)
            return resolved.status == .open ? .available(resolved) : .unavailable
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

    /// W4-H1: resolves whether a helper new-request tap for a not-open request
    /// names this helper's own active reservation. An in-process claim
    /// answers directly. With no participant authority no reservation can
    /// exist for this app to hold — claiming and continuation both require
    /// one — so that is confirmed absence, preserving the accepted
    /// `no longer available` outcome for an unverified helper. Otherwise the
    /// accepted continuation read decides; its `.unknown` stays unknown.
    /// Rethrows only cancellation.
    func resolveHeldRequestForNotification(
        requestID: String
    ) async throws -> HeldRequestNotificationTruth {
        if let activeClaim {
            return activeClaim.requestID == requestID ? .held(activeClaim.request) : .notHeld
        }
        guard participantAuthorityProvider() != nil else {
            return .notHeld
        }
        switch try await continueActiveReservationIfNeeded() {
        case .active(let activeClaim):
            return activeClaim.requestID == requestID ? .held(activeClaim.request) : .notHeld
        case .none:
            return .notHeld
        case .unknown:
            return .unknown
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
    /// termination. W4-D2: the record names the ledger authority that will
    /// receive the create, read from the backend first and sent with the
    /// create, so no other ledger can accept it.
    ///
    /// Every outcome either retires this attempt's record or keeps it as a
    /// blocking unresolved operation; a record is never left behind silently.
    /// Retired: success, and every received refusal that proves this single
    /// transmission created nothing — the operation-identity, validation,
    /// quota, and rate-limit codes (`isDefinitiveNonCreate`), a bare 404, and
    /// the pause, participant-gate, and ledger-authority refusals
    /// (`isPreLedgerRefusal`). Kept and blocking: `ambiguousCreateOutcome`,
    /// `REQUEST_CREATION_FAILED`, and any other decoded answer, since none of
    /// them proves no write occurred.
    func createRequest(_ payload: CreateRequestPayload) async throws {
        // A fresh, in-process create attempt is starting: whatever this call
        // ultimately does (succeed, fail definitively, or arm
        // `unresolvedCreateError`) fully determines this process's D1 state
        // from here on, so W3-I4 removal-safety readiness no longer depends
        // on relaunch reconciliation for it.
        hasResolvedPendingCreateStateForRemoval = true
        // W4-D2: the block is re-derived from durable storage and the
        // participant current *now*, immediately before a fresh logical
        // create — so a participant verified or restored since launch can
        // never create past its own unresolved operation.
        refreshPendingCreateState()
        if let unresolvedCreateError {
            createError = unresolvedCreateError
            throw unresolvedCreateError
        }
        guard !isCreating else {
            throw RequestServiceError.operationInProgress
        }
        isCreating = true
        createError = nil
        // W4-D2 continuity supersession: a later intentional create retires
        // any continuity still live from an earlier one, whatever happened to
        // that presentation (its dwell was cut short, its screen went away,
        // its task was cancelled). A previous request's card can therefore
        // never be shown as the outcome of this create — this attempt either
        // publishes its own continuity on authoritative CREATED, or there is
        // none.
        createdRequestContinuity = nil
        // A new intentional submission supersedes a NO-CREATE notice about an
        // older, already-retired operation. W4-D2 FIX (rereview MUST FIX 1):
        // this must retire the notice and its private payload together —
        // `retireNotCreatedNotice()` is the one coupled primitive for that,
        // so a fresh create can never leave the old payload allocated behind
        // a now-hidden notice.
        if hasNotCreatedNotice {
            retireNotCreatedNotice()
            refreshPendingCreateState()
        }
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
        var recordedOperationId: String?
        var operationLedger: String?
        // Its own record is not a block while it is being posted.
        inFlightCreateOperationId = operationId
        defer { inFlightCreateOperationId = nil }
        if let participantAuthority,
           let participantIdentifier = ParticipantAuthorityShape.participantIdentifier(ofAuthority: participantAuthority) {
            // W4-D2: nothing is recorded or transmitted until the ledger that
            // will receive this create is known. A failure here sent nothing.
            let ledger: String
            do {
                ledger = try await service.fetchOperationLedger()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let serviceError = Self.asServiceError(error)
                createError = serviceError
                throw serviceError
            }
            // The exact request content about to be transmitted, frozen
            // whole (W4-R4). `installationCredential` is cleared rather than
            // persisted: it is store-owned installation identity, not request
            // content, and replay re-supplies it from the live provider. What
            // is written to disk is therefore precisely the structured
            // request the requester composed — every meal entry and the exact
            // Dining Dollar cents — and nothing credential-shaped.
            var frozenPayload = payload
            frozenPayload.installationCredential = nil
            let didRecord = operationStorage.save(
                PendingRequestOperationRecord(
                    operationId: operationId,
                    participantIdentifier: participantIdentifier,
                    operationAuthority: RequestOperationAuthorityIdentity(
                        origin: service.operationAuthorityOrigin,
                        ledger: ledger
                    ),
                    payload: frozenPayload
                )
            )
            guard didRecord else {
                // W4-D2 FIX (2026-09-18, independent-review MUST FIX): the
                // exact-operation recovery record must be durable *before*
                // transmission, not merely attempted. If persistence itself
                // failed, nothing has been sent — and nothing may be: sending
                // now would risk a backend commit with no durable recovery
                // identity to reconcile it against on relaunch. This is a
                // pre-transmission local failure, not an ambiguous write, so
                // it retires nothing (there is no record to retire), arms no
                // unresolved-create block, and never reaches
                // `service.createRequest`.
                let serviceError = RequestServiceError.durablePersistenceFailed
                createError = serviceError
                throw serviceError
            }
            recordedOperationId = operationId
            operationLedger = ledger
        }
        do {
            let created = try await service.createRequest(
                submittedPayload,
                operationId: operationId,
                participantAuthority: participantAuthority,
                operationLedger: operationLedger
            )
            inFlightCreateOperationId = nil
            retirePendingCreate(operationId: operationId)
            advanceCollectionRevision()
            // W4-D2 Success→Home continuity (narrowly supersedes the W4-R2
            // 2026-09-05 "no R2-authored Home insertion" note this replaces,
            // for the still-current-authority case only): the accepted
            // Success→Home continuity sequence requires the requester-owned
            // Home card to already exist, in its correct newest-first slot,
            // the instant Home is revealed — it cannot depend on H4's own
            // authoritative fetch completing first, which is unbounded and
            // can race the reveal. `applyConfirmed` inserts only when this
            // exact authority is still current at its own one read of
            // `participantAuthorityProvider()` (the same read that resolves
            // ownership) — an authority that changed mid-flight keeps the
            // original "never insert" behavior unchanged, and its return
            // value's `isOwnRequest` reports that same single-read answer, so
            // `justCreatedOwnRequest` cannot disagree with it via a separate,
            // possibly-stale re-read. H4's own ownership partition/newest-
            // first ordering (`HomeExchangeView.partitionByOwnership`) still
            // owns where it lands, and a later authoritative fetch simply
            // reconciles the same entry in place.
            let confirmedOwnRequest = applyConfirmed(
                created,
                createdUnderAuthority: participantAuthority,
                insertIfMissing: true
            )
            // `isOwnRequest` here is exactly `applyConfirmed`'s own single
            // still-current-authority read: true only when this authority is
            // still current and the card was actually inserted into the
            // collection Home renders. Continuity is therefore published only
            // for a request that genuinely has a current-authority Home slot
            // to land in; an authority that changed mid-flight publishes
            // nothing, and the Success presentation is not entered at all.
            if confirmedOwnRequest.isOwnRequest, let participantAuthority {
                publishCreationContinuity(
                    operationId: operationId,
                    participantAuthority: participantAuthority,
                    request: confirmedOwnRequest
                )
            }
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
            inFlightCreateOperationId = nil
            retirePendingCreate(operationId: operationId)
            throw CancellationError()
        } catch {
            inFlightCreateOperationId = nil
            let serviceError = Self.asServiceError(error)
            createError = serviceError
            switch serviceError {
            case .notFound:
                // This service case is reserved for a route-level HTTP 404:
                // no create handler ran, so this exact operation did not
                // create anything and must not survive for relaunch replay.
                retirePendingCreate(operationId: operationId)
            case .serverError(let code, _)
                where RequestOperationErrorCode.isDefinitiveNonCreate(code)
                    || RequestOperationErrorCode.isPreLedgerRefusal(code):
                retirePendingCreate(operationId: operationId)
            default:
                // `ambiguousCreateOutcome`, a readable
                // `REQUEST_CREATION_FAILED` (which `createRequestRoute.ts` can
                // return from a path that follows a write attempt), and any
                // answer this build cannot classify: the write result is not
                // proven, so the operation stays durable and blocks a
                // replacement until authoritative reconciliation resolves it.
                armUnresolvedCreate(serviceError, recordedOperationId: recordedOperationId)
            }
            applyParticipantVerdict(
                serviceError,
                presentedAuthority: participantAuthority
            )
            throw serviceError
        }
    }

    /// W4-D2: re-derives the create block and recovery presentation from
    /// durable storage and the participant current now. Synchronous and
    /// local — it never reconciles, retries, or clears anything, so calling it
    /// whenever participant identity changes is always safe.
    ///
    /// - Any entry whose identity is unreadable: blocked, identity
    ///   unavailable. It could be anyone's on this installation.
    /// - Restored entries but no usable current participant: blocked with no
    ///   check. Whose operation it is cannot be established, so it is never
    ///   treated as unrelated.
    /// - Entries for the current participant: blocked, with `Check again`
    ///   only while one of them can be exactly reconciled from here.
    /// - Only entries for a different, confirmed participant: not blocked,
    ///   and left untouched.
    func refreshPendingCreateState() {
        // W4-D2 continuity lifetime: this is already the one local re-derivation
        // of "whose operations are these, for the participant current now",
        // called on every participant/identity change, so it is also where a
        // continuity presentation belonging to a superseded authority retires.
        retireCreationContinuityIfAuthorityChanged()
        let entries = operationStorage.restoreAll()
        let restored = entries.compactMap { entry -> RestoredPendingRequestOperation? in
            guard case .restored(let operation) = entry,
                  operation.identity.operationId != inFlightCreateOperationId else { return nil }
            return operation
        }
        let currentIdentifier = participantAuthorityProvider()
            .flatMap(ParticipantAuthorityShape.participantIdentifier(ofAuthority:))

        if entries.contains(.identityUnavailable) {
            setCreateBlock(
                unresolvedCreateError ?? .ambiguousCreateOutcome(underlying: PendingRequestOperationUnreadable()),
                presentation: .identityUnavailable
            )
            return
        }
        guard !restored.isEmpty else {
            if let unrecordedCreateAmbiguity {
                setCreateBlock(unrecordedCreateAmbiguity, presentation: .unresolved(canCheckAgain: false))
            } else {
                clearCreateBlock()
            }
            return
        }
        guard let currentIdentifier else {
            setCreateBlock(
                unrecordedCreateAmbiguity
                    ?? unresolvedCreateError
                    ?? .ambiguousCreateOutcome(underlying: PendingRequestOperationRestored()),
                presentation: .unresolved(canCheckAgain: false)
            )
            return
        }
        let current = restored.filter { $0.identity.participantIdentifier == currentIdentifier }
        guard !current.isEmpty else {
            if let unrecordedCreateAmbiguity {
                setCreateBlock(unrecordedCreateAmbiguity, presentation: .unresolved(canCheckAgain: false))
            } else {
                clearCreateBlock()
            }
            return
        }
        let error = current.lazy.compactMap { self.pendingCreateErrors[$0.identity.operationId] }.first
            ?? unrecordedCreateAmbiguity
            ?? unresolvedCreateError
            ?? .ambiguousCreateOutcome(underlying: PendingRequestOperationRestored())
        setCreateBlock(
            error,
            presentation: .unresolved(canCheckAgain: current.contains(where: isExactlyReconcilable))
        )
    }

    /// W4-D2 FIX (rereview MUST FIX 1): the one store-owned way to retire the
    /// terminal NO-CREATE notice and the private payload behind it together.
    /// `hasNotCreatedNotice` and `notCreatedRecoverablePayload` share one
    /// lifetime by construction — every path that hides, supersedes, or
    /// consumes the notice must go through this rather than clearing either
    /// flag on its own, so a payload can never outlive the notice it belongs
    /// to or survive into a later, unrelated operation.
    private func retireNotCreatedNotice() {
        hasNotCreatedNotice = false
        notCreatedRecoverablePayload = nil
    }

    private func setCreateBlock(
        _ error: RequestServiceError,
        presentation: RequestCreateRecoveryPresentation
    ) {
        // A block supersedes any NO-CREATE notice about an older operation.
        retireNotCreatedNotice()
        unresolvedCreateError = error
        if createRecoveryPresentation != presentation {
            createRecoveryPresentation = presentation
        }
    }

    private func clearCreateBlock() {
        if unresolvedCreateError != nil {
            unresolvedCreateError = nil
        }
        let presentation: RequestCreateRecoveryPresentation
        if hasNotCreatedNotice {
            presentation = notCreatedRecoverablePayload != nil
                ? .notCreatedRecoverable
                : .notCreatedUnavailable
        } else {
            presentation = .none
        }
        if createRecoveryPresentation != presentation {
            createRecoveryPresentation = presentation
        }
    }

    /// Whether an exact reconciliation of `operation` can be attempted from
    /// this installation right now: it recorded a ledger authority, was sent
    /// to the origin this build is configured for, and has not already been
    /// answered by a different ledger this process. The ledger itself is
    /// re-checked against the backend before anything is sent.
    private func isExactlyReconcilable(_ operation: RestoredPendingRequestOperation) -> Bool {
        guard let authority = operation.identity.operationAuthority else { return false }
        return authority.origin == service.operationAuthorityOrigin
            && !authorityMismatchedOperations.contains(operation.identity.operationId)
    }

    private func armUnresolvedCreate(
        _ error: RequestServiceError,
        recordedOperationId: String?
    ) {
        if let recordedOperationId {
            pendingCreateErrors[recordedOperationId] = error
        } else {
            // Nothing durable names this operation (no participant identity,
            // or storage refused the record), so nothing can ever reconcile
            // it: the block lasts for the rest of this process.
            unrecordedCreateAmbiguity = error
        }
        refreshPendingCreateState()
    }

    /// Retires exactly one operation — its durable entry and its in-process
    /// bookkeeping — and nothing else.
    private func retirePendingCreate(operationId: String) {
        operationStorage.clear(operationId: operationId)
        pendingCreateErrors[operationId] = nil
        authorityMismatchedOperations.remove(operationId)
        refreshPendingCreateState()
    }

    /// W3-D1 relaunch reconciliation, with W4-D2 exact terminal authority.
    /// Reconciles the current participant's durable unresolved request-create
    /// operations against authoritative backend truth under their exact same
    /// operation identities — never a newly minted identity and never a
    /// re-derived or reconstructed payload.
    ///
    /// The W4-D2 recovery matrix, per operation:
    ///
    /// - identity unreadable: fail closed — never sent, never cleared, and
    ///   the create block stays armed (`.identityUnavailable`);
    /// - no usable current participant: nothing is sent; the block stays
    ///   armed with no check action;
    /// - bound to a different confirmed participant: left untouched,
    ///   unexposed, and non-blocking;
    /// - recorded ledger authority absent (pre-D2), sent to a different
    ///   origin, or not the ledger the backend now reports: nothing further is
    ///   sent — neither replay nor terminalization may cross authorities — and
    ///   the block stays armed with no check action;
    /// - payload readable and valid: the exact D1 replay; a received
    ///   post-lookup refusal or an unacceptable success body then converges
    ///   through exact terminal reconciliation;
    /// - payload unreadable or invalid: exact terminal reconciliation only;
    /// - created / NO-CREATE / expired / unauthorized / invalid identity:
    ///   retire that operation only;
    /// - anything else (rate limit, pause, 404, participant or ledger
    ///   authority unavailable, transport, write-uncertain failure): keep it
    ///   and the block, with `Check again` available.
    ///
    /// Safe to call more than once — a no-op once nothing the current
    /// participant can reconcile remains, and a no-op while a create is
    /// already in flight. Returns `true` only once a restored operation has
    /// been confirmed created.
    @discardableResult
    func reconcilePendingCreateOperationIfNeeded() async -> Bool {
        // Removal-safety readiness for D1 comes from durable storage itself,
        // which the refresh below reads synchronously; an inconclusive
        // network answer never makes a blocked state look safe.
        hasResolvedPendingCreateStateForRemoval = true
        refreshPendingCreateState()
        guard !isCreating else {
            return false
        }
        guard let participantAuthority = participantAuthorityProvider(),
              let currentIdentifier = ParticipantAuthorityShape.participantIdentifier(ofAuthority: participantAuthority) else {
            return false
        }
        let operations = operationStorage.restoreAll().compactMap { entry -> RestoredPendingRequestOperation? in
            guard case .restored(let operation) = entry,
                  operation.identity.participantIdentifier == currentIdentifier,
                  isExactlyReconcilable(operation) else {
                return nil
            }
            return operation
        }
        guard !operations.isEmpty else {
            return false
        }

        isCreating = true
        createError = nil
        // Same supersession rule as a fresh create: a reconciliation pass
        // that is about to establish its own terminal outcomes must not leave
        // an earlier operation's continuity live behind it.
        createdRequestContinuity = nil
        defer {
            isCreating = false
            refreshPendingCreateState()
        }

        var didCreate = false
        for operation in operations {
            // A participant replaced or discarded mid-recovery ends it: the
            // remaining operations are not this authority's to act on.
            guard participantAuthorityProvider() == participantAuthority else { break }
            let operationId = operation.identity.operationId
            switch await reconcilePendingCreate(operation, participantAuthority: participantAuthority) {
            case .created(let created):
                retirePendingCreate(operationId: operationId)
                advanceCollectionRevision()
                // W4-H2: a reconciled D1 create is the same authenticated
                // knowledge as a fresh one — this exact authority created this
                // request — so it is confirmed `.owned` under that authority.
                // W4-D2 Success→Home continuity: `Check again`'s reconciled
                // CREATED outcome enters the same Success→Home continuity
                // screen as a fresh create (see `RequestFormPresentation`),
                // so it needs the same immediate, correctly-ordered Home
                // presence — see `applyConfirmed`'s own doc comment for why
                // its single internal authority read (not a separate re-read
                // here) governs both ownership and insertion together.
                let confirmedOwnRequest = applyConfirmed(
                    created,
                    createdUnderAuthority: participantAuthority,
                    insertIfMissing: true
                )
                // Identical rule to the fresh-create site above: a reconciled
                // CREATED publishes continuity only when this authority is
                // still current and the card was actually inserted, so
                // reconciliation can never present a card the current
                // participant does not own.
                if confirmedOwnRequest.isOwnRequest {
                    publishCreationContinuity(
                        operationId: operationId,
                        participantAuthority: participantAuthority,
                        request: confirmedOwnRequest
                    )
                }
                didCreate = true
            case .notCreated(let recoverablePayload):
                // Authoritative and permanent: the old operation can never
                // create. Nothing is submitted in its place; a later
                // intentional submission mints a fresh identity under
                // ordinary rules. `recoverablePayload` is Path A/B: the
                // frozen payload when it was actually readable, `nil` when
                // NO-CREATE was reached through matrix row 2 instead.
                retirePendingCreate(operationId: operationId)
                hasNotCreatedNotice = true
                notCreatedRecoverablePayload = recoverablePayload
            case .retired:
                retirePendingCreate(operationId: operationId)
            case .authorityMismatch:
                // W4-D2 matrix row 8: this backend is not the ledger the
                // create was recorded against. Nothing it answers can resolve
                // the operation, and no check from here can change that.
                authorityMismatchedOperations.insert(operationId)
            case .unresolved(let error):
                // W4-D2 matrix row 6: the durable record and the block stay
                // exactly as armed, so a later exact reconciliation can still
                // resolve this same operation.
                if let error {
                    pendingCreateErrors[operationId] = error
                }
            }
        }
        return didCreate
    }

    /// Dismisses the terminal NO-CREATE notice after `Return to request` or
    /// `Start a new request`. Changes nothing else: the old operation is
    /// already retired, and a new submission still goes through
    /// `createRequest` with a fresh identity — never the terminalized one.
    func acknowledgeCreateNotPosted() {
        guard hasNotCreatedNotice else { return }
        retireNotCreatedNotice()
        refreshPendingCreateState()
    }

    /// W4-D2 FIX 2026-09-18 (independent-review MUST FIX 1): Path A's one
    /// store-owned restoration operation. The raw `CreateRequestPayload`
    /// behind a terminal NO-CREATE notice never leaves this store; this is
    /// the only way a caller may act on it. Verifies the current terminal
    /// recovery state is still the exact recoverable NO-CREATE notice this
    /// operation established, then atomically consumes and retires it —
    /// exactly like `acknowledgeCreateNotPosted()` — before returning a
    /// restoration-ready `RequestFoodFormDraft` built from the payload.
    /// Because the payload is cleared in the same step it is read, it can
    /// never be consumed twice, and a later, unrelated NO-CREATE can never
    /// inherit it.
    ///
    /// Returns `nil` when there is no recoverable notice to consume —
    /// already consumed, acknowledged, superseded by a fresh submission, or
    /// this is actually a Path B (unavailable) notice — so a caller can
    /// never restore a stale, repeated, or nonexistent payload.
    func consumeRecoverableDraftForReturnToRequest() -> RequestFoodFormDraft? {
        guard hasNotCreatedNotice, let payload = notCreatedRecoverablePayload else {
            return nil
        }
        retireNotCreatedNotice()
        refreshPendingCreateState()
        return RequestFoodFormDraft(restoring: payload)
    }

    private enum PendingCreateRecoveryOutcome {
        case created(FoodRequest)
        /// W4-D2 2026-09-17 Path A/B: the frozen payload when it was actually
        /// readable at this reconciliation (Path A), `nil` when NO-CREATE was
        /// reached with an unreadable payload (matrix row 2, Path B).
        case notCreated(recoverablePayload: CreateRequestPayload?)
        /// Retired without a requester-facing notice: expired, unauthorized,
        /// or an identity no create could ever accept.
        case retired
        /// The backend answering is not the recorded ledger authority.
        case authorityMismatch
        /// Inconclusive; `nil` means cancellation, which changes nothing.
        case unresolved(RequestServiceError?)
    }

    /// One operation's exact reconciliation, only against its recorded
    /// ledger: the ledger the backend reports now is compared first, and the
    /// same ledger is named on every request so the backend enforces it too.
    private func reconcilePendingCreate(
        _ operation: RestoredPendingRequestOperation,
        participantAuthority: String
    ) async -> PendingCreateRecoveryOutcome {
        let identity = operation.identity
        guard let recorded = identity.operationAuthority else {
            return .authorityMismatch
        }
        let currentLedger: String
        do {
            currentLedger = try await service.fetchOperationLedger()
        } catch is CancellationError {
            return .unresolved(nil)
        } catch {
            return .unresolved(.ambiguousCreateOutcome(underlying: Self.asServiceError(error)))
        }
        guard currentLedger == recorded.ledger else {
            return .authorityMismatch
        }

        switch operation.payload {
        case .current(let payload) where Self.isValidPayload(payload):
            return await replayPendingCreate(
                payload,
                operationId: identity.operationId,
                participantAuthority: participantAuthority,
                operationLedger: recorded.ledger
            )
        case .current, .legacy, .unreadable:
            // W4-D2 matrix row 2: the exact payload is not available to
            // resend (unreadable, malformed, or a pre-R4 body — which only a
            // pre-D2 record carries, and those record no ledger), so the
            // operation is resolved by identity alone. Nothing is repaired,
            // reconstructed, or partially resent.
            return await terminalizePendingCreate(
                operationId: identity.operationId,
                participantAuthority: participantAuthority,
                operationLedger: recorded.ledger
            )
        }
    }

    /// The exact D1 replay, classified for recovery (W4-D2): only an
    /// authoritative operation answer resolves the operation. Refusals that
    /// follow a not-found lookup, and a success body this build cannot
    /// accept, converge through exact terminal reconciliation instead of
    /// being taken as proof on their own.
    private func replayPendingCreate(
        _ payload: CreateRequestPayload,
        operationId: String,
        participantAuthority: String,
        operationLedger: String
    ) async -> PendingCreateRecoveryOutcome {
        // Re-read here, immediately before sending, exactly like the fresh
        // path: the record itself never carries this — it is store-owned
        // installation identity, not part of the operation's durable
        // identity — so a recovered create restores the *current*
        // association rather than reconstructing a stale one.
        var recoveredPayload = payload
        recoveredPayload.installationCredential = installationCredentialProvider()
        do {
            let created = try await service.createRequest(
                recoveredPayload,
                operationId: operationId,
                participantAuthority: participantAuthority,
                operationLedger: operationLedger
            )
            return .created(created)
        } catch is CancellationError {
            return .unresolved(nil)
        } catch {
            let serviceError = Self.asServiceError(error)
            applyParticipantVerdict(serviceError, presentedAuthority: participantAuthority)
            switch serviceError {
            case .serverError(let code, _) where code == RequestOperationErrorCode.operationNotCreated:
                // The exact payload just replayed is known and readable —
                // Path A.
                return .notCreated(recoverablePayload: payload)
            case .serverError(let code, _) where RequestOperationErrorCode.isTerminalOperationRetirement(code):
                return .retired
            case .serverError(let code, _) where code == RequestOperationErrorCode.operationAuthorityMismatch:
                return .authorityMismatch
            case .serverError(let code, _) where RequestOperationErrorCode.isPostLookupRefusal(code):
                break
            case .ambiguousCreateOutcome(let underlying) where Self.isUnacceptableSuccessResponse(underlying):
                break
            default:
                // Rate limiting, pause, a bare 404, participant or ledger
                // authority unavailable, `REQUEST_CREATION_FAILED`, transport
                // loss, timeout: none of these ran the identity lookup to a
                // terminal answer.
                return .unresolved(serviceError)
            }
            // A participant rejected by that answer cannot reconcile now.
            guard participantAuthorityProvider() == participantAuthority else {
                return .unresolved(serviceError)
            }
            // The exact payload just replayed is known and readable here too
            // — a NO-CREATE reached through this post-lookup-refusal
            // terminalization is still Path A, not Path B.
            let outcome = await terminalizePendingCreate(
                operationId: operationId,
                participantAuthority: participantAuthority,
                operationLedger: operationLedger
            )
            if case .notCreated = outcome {
                return .notCreated(recoverablePayload: payload)
            }
            return outcome
        }
    }

    /// W4-D2 exact terminal reconciliation for one issued operation.
    private func terminalizePendingCreate(
        operationId: String,
        participantAuthority: String,
        operationLedger: String
    ) async -> PendingCreateRecoveryOutcome {
        do {
            switch try await service.reconcileRequestOperationTerminal(
                operationId: operationId,
                participantAuthority: participantAuthority,
                operationLedger: operationLedger
            ) {
            case .created(let created):
                return .created(created)
            case .notCreated:
                // Called with no payload in hand (matrix row 2 direct path)
                // — Path B. A caller that does have the payload (the
                // post-lookup-refusal fallback in `replayPendingCreate`)
                // re-attaches it itself.
                return .notCreated(recoverablePayload: nil)
            }
        } catch is CancellationError {
            return .unresolved(nil)
        } catch {
            let serviceError = Self.asServiceError(error)
            applyParticipantVerdict(serviceError, presentedAuthority: participantAuthority)
            if case .serverError(let code, _) = serviceError {
                if RequestOperationErrorCode.isTerminalOperationRetirement(code) {
                    return .retired
                }
                if code == RequestOperationErrorCode.operationAuthorityMismatch {
                    return .authorityMismatch
                }
            }
            // Keep the store's existing write-uncertain presentation of the
            // block rather than replacing it with a transport-shaped error.
            return .unresolved(.ambiguousCreateOutcome(underlying: serviceError))
        }
    }

    /// A create response that reached iOS with a success status but could not
    /// be accepted (undecodable, or not the shape a fresh create returns).
    /// The backend answered, so backend authority can settle it exactly;
    /// transport loss, timeouts, and unreadable error statuses are not this.
    private static func isUnacceptableSuccessResponse(_ underlying: Error) -> Bool {
        if case APIClientError.decoding = underlying {
            return true
        }
        return false
    }

    /// Structural validity of a restored current payload before it may be
    /// replayed. A payload that fails is never repaired: recovery resolves
    /// that operation by identity alone (W4-D2).
    private static func isValidPayload(_ payload: CreateRequestPayload) -> Bool {

        // W4-R4 structural validity of the frozen payload. Still shape only,
        // never a guess at what a malformed record "meant": a record that
        // does not describe exactly one coherent menu path is never repaired
        // into one; it is reconciled by identity alone instead.
        guard !payload.vendor.isEmpty else { return false }

        switch payload.menuPath {
        case .mealExchange:
            guard (1...RequestFoodFormDraft.maxMealSwipes).contains(payload.mealSwipes),
                  payload.mealItems.count == payload.mealSwipes,
                  payload.mealItems.allSatisfy({ !$0.isEmpty }),
                  payload.orderDetails == nil else {
                return false
            }
            if let cents = payload.estimatedDiningDollarsCents {
                guard cents > 0,
                      cents <= RequestFoodFormDraft.mealExchangeDiningDollarsCeilingCents else {
                    return false
                }
            }
        case .diningDollars:
            guard payload.mealSwipes == 0,
                  payload.mealItems.isEmpty,
                  let orderDetails = payload.orderDetails,
                  !orderDetails.isEmpty,
                  let cents = payload.estimatedDiningDollarsCents,
                  cents > 0,
                  cents <= RequestFoodFormDraft.diningDollarsOnlyCeilingCents else {
                return false
            }
        }

        switch payload.timing {
        case .asap:
            return payload.windowStart == nil
        case .scheduled:
            return payload.windowStart != nil
        }
    }

    /// Publishes the pickup name and stores the raw token only after a confirmed
    /// claim response. Duplicate or second-request claims are refused before
    /// POST so the single active claim, token, and lifecycle timer cannot be
    /// overwritten.
    func claim(requestID: String) async throws {
        // W4-H1: `fulfillmentConfirmation` deliberately does NOT appear in this
        // preflight. Once fulfillment is authoritatively confirmed successful,
        // `applyConfirmedFulfillment` has already cleared the active claim and
        // the helper relationship is complete, so the surviving confirmation is
        // presentation only. Nothing here — and nothing anywhere else in this
        // store — may read success presentation, its dismissal, its dwell, or
        // any derived local flag as claim authority. Unresolved or ambiguous
        // fulfillment is a different thing entirely: it keeps `activeClaim`
        // alive, so it is still refused by the `existingActiveClaim` guard
        // immediately below.
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
            // No credential to ask on behalf of at all — vacuously nothing
            // for this process to discover, so removal-safety readiness is
            // already established (moot in practice: Remove Email is only
            // ever offered while `identity != nil`, which implies authority
            // is present too).
            hasResolvedReservationStateForRemoval = true
            return .unknown
        }
        reservationStateResolutionCount += 1
        defer { reservationStateResolutionCount -= 1 }
        do {
            let state = try await service.fetchParticipantReservationState(
                participantAuthority: participantAuthority
            )
            // Re-checked after the `await`: a concurrent `claim()` (unlikely,
            // but not impossible if this races a fresh user-initiated claim)
            // must not be overwritten by a continuation read that started
            // before it.
            if let activeClaim {
                return .active(activeClaim)
            }
            switch state {
            case .reservation(let reservation):
                let presentation = ActiveClaimPresentation(
                    request: reservation.request,
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
            case .placed:
                // W4-H1: the backend authoritatively reports no active
                // reservation and a settled placement by this participant.
                // That is confirmed success, which completes the helper
                // relationship — so this reconciles to exactly the same
                // normal helper-available state as `.none` below and
                // deliberately reconstructs no success/acknowledgement
                // presentation. Superseding W3-H2's placed re-entry restore
                // is the point: rebuilding a stale confirmation here would
                // recreate the acknowledgement gate H1 removes, and the
                // success screen is not durable domain state. Nothing is
                // fabricated in either direction — no reservation authority,
                // no raw token, and no claim to know what the helper has
                // already seen. Unresolved fulfillment never reaches this
                // branch: it leaves the request `claimed`, which the
                // `.reservation` case above reconstructs instead.
                reservationWarningScheduler.cancelAllWarnings()
                hasResolvedReservationStateForRemoval = true
                return .none
            case .none:
                reservationWarningScheduler.cancelAllWarnings()
                hasResolvedReservationStateForRemoval = true
                return .none
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Backend truth could not be established (transport, timeout, a
            // server failure, a decoding failure, or contradictory backend
            // state). Leaving `activeClaim` nil and every existing warning
            // untouched is the only truthful answer here — never invent
            // absence or active state — and W3-I4 removal-safety readiness
            // stays unresolved for the same reason: an inconclusive read
            // must not be treated as "safe to forget identity".
            applyParticipantVerdict(
                Self.asServiceError(error),
                presentedAuthority: participantAuthority
            )
            return .unknown
        }
    }

    /// W3-H2 stale detail Reserve truth. Deliberately three states, not a
    /// `Bool`: `.unresolved` covers both "still finding out" and "could not
    /// find out" (a failed/unreadable read is never treated as authoritative
    /// permission to Reserve), so a caller only ever offers Reserve for the
    /// single state that actually confirms it — never by defaulting an
    /// unknown to permissive.
    enum StaleParticipationEligibility: Equatable {
        /// Not yet known, or the read that would have resolved it failed or
        /// was itself superseded by a newer authoritative identity. Never
        /// actionable.
        case unresolved
        /// Confirmed: this exact verified participant has never held this
        /// request. Reserve may render, subject to every other existing rule
        /// (H1 continuation, verification gate, pause, etc).
        case eligible
        /// Confirmed: this exact verified participant already successfully
        /// held this request once. Reserve must never render.
        case alreadyParticipated
    }

    /// Resolves `StaleParticipationEligibility` for `requestID` against
    /// current backend truth — never fabricated from local state, and never
    /// cached across calls, so a caller that needs a fresh answer for a
    /// changed identity gets one.
    ///
    /// No participant identity presented at all (browsing stays open to
    /// anyone, W3-I1) resolves immediately to `.eligible`: there is no
    /// participation history to ask about yet, and this is the same
    /// permissive answer this screen gave before W3-H2 existed.
    ///
    /// Stale-response guard: the participant authority in effect *before*
    /// this read is captured and compared against the authority in effect
    /// *after* it completes. If they differ — a Change Email completed while
    /// this read was in flight — the result belongs to a principal that is
    /// no longer authoritative and is discarded as `.unresolved` rather than
    /// silently authorizing the replacement identity. `claimRequest`'s own
    /// conditional grant remains the real backstop regardless of this read.
    func resolveStaleParticipationEligibility(
        for requestID: String
    ) async -> StaleParticipationEligibility {
        guard let participantAuthority = participantAuthorityProvider() else {
            return .eligible
        }
        do {
            let alreadyParticipated = try await service.fetchAlreadyParticipated(
                id: requestID,
                participantAuthority: participantAuthority
            )
            guard participantAuthorityProvider() == participantAuthority else {
                return .unresolved
            }
            return alreadyParticipated ? .alreadyParticipated : .eligible
        } catch {
            return .unresolved
        }
    }

    /// W4-Q1 bounded participant-authorized read of whether the currently
    /// verified participant may presently attempt another request under the
    /// existing best-effort three-per-NYU-campus-day quota.
    /// `RequestFoodEntryView`'s early-boundary consumption (W4-R2 item 20) is
    /// this authority's one requester-entry consumer; it never reimplements
    /// or overrides this result.
    enum RequestCreationEligibility: Equatable {
        /// Not yet read, unreadable, missing authority, or resolved under a
        /// participant authority the read's own stale-response guard could
        /// not confirm still current. Never treated as permission to
        /// proceed; a future R2 consumer must fail closed on this case.
        case unknown
        case eligible
        case exhausted
    }

    /// Resolves `RequestCreationEligibility` against current backend truth —
    /// never fabricated from local state, Home request counts, or a cached
    /// prior result, and never persisted: each call performs a fresh read.
    ///
    /// No participant identity presented at all resolves immediately to
    /// `.unknown` rather than issuing a call — this read exists to gate a
    /// requester-authorized action, so there is nothing to ask about yet.
    ///
    /// Stale-response guard: the participant authority in effect *before*
    /// this read is captured and compared against the authority in effect
    /// *after* it completes, matching `resolveStaleParticipationEligibility`
    /// above. If they differ — a Change Email completed while this read was
    /// in flight — the result belongs to a principal that is no longer
    /// authoritative and is discarded as `.unknown`. The result is advisory
    /// and current only as of this read: `POST /api/request` remains the
    /// sole authoritative create-time quota enforcement regardless of what
    /// this call returns.
    func resolveRequestCreationEligibility() async -> RequestCreationEligibility {
        guard let participantAuthority = participantAuthorityProvider() else {
            return .unknown
        }
        do {
            let wire = try await service.fetchRequestCreationEligibility(
                participantAuthority: participantAuthority
            )
            guard participantAuthorityProvider() == participantAuthority else {
                return .unknown
            }
            switch wire {
            case .eligible: return .eligible
            case .exhausted: return .exhausted
            }
        } catch {
            // W4-Q1 review fix: a current `PARTICIPANT_AUTHORITY_INVALID`
            // refusal must feed the same authority-retirement lifecycle every
            // other participant-gated read/mutation already uses, rather than
            // silently discarding it as an unmapped `.unknown`.
            // `applyParticipantVerdict` carries its own stale-response fence
            // (it only retires the credential this exact call presented, and
            // only while that credential is still current), so a rejection
            // for an authority a newer Change Email has already replaced
            // cannot retire the replacement — and every non-authority-invalid
            // failure (transport, decoding, cancellation, an unrelated server
            // error) is a no-op here, exactly as it is at every other call
            // site of this method.
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
    /// token. Starting an attempt consumes the one offer either way, so a
    /// failed or unconfirmed attempt cannot re-open the control into a retry
    /// loop, and the local expiration advances only on a confirmed backend
    /// response.
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
        consumeExtensionOffer()
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
        // A fresh claim or a definitive continuation restore each fully
        // determine this process's H1 state going forward (H1 never allows
        // holding two simultaneous claims), so W3-I4's removal-safety
        // readiness is established here regardless of which path called in.
        hasResolvedReservationStateForRemoval = true
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
        // W4-H1: it exists only to drive the brief in-process success
        // presentation, which retires it itself after its automatic Home
        // return. It gates nothing; reaching this line at all already proves a
        // new claim was allowed while a confirmation was live.
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

    /// Schedules the warning moment and the expiration moment from the backend's
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

        claimLifecycleTask = Task { [weak self] in
            // W4-H1: the five-minute warning is the only timed reservation
            // presentation. The legacy T−3 prompt step no longer exists.
            if let interval = Self.secondsUntil(warningMoment) {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.presentReservationWarningIfEligible(
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
    /// W4-H1: presenting the warning creates no controls or decision of its
    /// own. It only draws attention back to the Helping page, whose existing
    /// `+ Add 5 minutes` / `× Stop helping` controls remain the one place the
    /// helper acts on the reservation.
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
        reservationWarningScheduler.cancelWarning(requestID: requestID)
        reconcileExtensionAvailability()
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

    /// Retires the single extension offer the moment an attempt begins, so
    /// no outcome — confirmed, refused, or ambiguous — can offer a second one.
    private func consumeExtensionOffer() {
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
            // current reservation still stands and the offer stays consumed.
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
                 ClaimErrorCode.requestNotFound,
                 // W3-H2: a stale Reserve tap on a request this participant
                 // already successfully held once before. Grouped with the
                 // others rather than given a new presentation — the next
                 // step is identical (leave and return to a refreshed
                 // list), and the accepted marketplace-presentation
                 // contract permits reusing this exact refused-reservation
                 // pattern instead of new explanatory copy.
                 ClaimErrorCode.requestAlreadyParticipated:
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
    /// The confirmation check is request-scoped on purpose, and stays that way
    /// under W4-H1. A confirmed placement blocks resubmitting *that* request —
    /// which is what keeps a second CommonPlate submission, and any suggestion
    /// of a second external order, off the table — while a still-displayed
    /// confirmation says nothing about a different reservation and must not
    /// disable it.
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

    /// Retires one success presentation, matched by exact ID so a newer
    /// result is never dropped by a retirement meant for an older one. Called
    /// only by the automatic W4-H1 success presentation once it has returned
    /// the helper to Home — there is no user-facing acknowledgement control.
    ///
    /// Presentation only, with no lifecycle authority. The active helper
    /// relationship already ended when placement was authoritatively
    /// confirmed (`applyConfirmedFulfillment` → `clearActiveClaim`); calling
    /// this, not calling this, or calling it late changes nothing about what
    /// the helper may claim next.
    func dismissFulfillmentConfirmation(id: UUID) {
        guard fulfillmentConfirmation?.id == id else { return }
        fulfillmentConfirmation = nil
        confirmedFulfillmentOutcome = nil
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
        // no-longer-claimed response; `canExtendActiveClaim` already refuses
        // while `fulfillmentAmbiguityContext` is set.

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

    /// Ingests a request confirmed by a POST whose response shape carries no
    /// caller-relative ownership, so `request.ownership` arrives
    /// `.unresolved`.
    ///
    /// `createdUnderAuthority` is the participant authority that performed
    /// the authenticated create. When it is still current, this is not a
    /// heuristic: `POST /api/request` refuses an unverified caller and binds
    /// `requesterParticipantId` to exactly that principal, so a success
    /// returned to that same still-current authority is direct knowledge
    /// that the request is theirs. That lets Home label it `YOUR REQUEST`
    /// and withhold Reserve immediately, instead of presenting the
    /// requester's own brand-new request as helpable until the next list
    /// fetch happens to re-derive ownership.
    ///
    /// If the authority changed while the create was in flight, the
    /// A-relative conclusion is not applied for B — ownership stays
    /// `.unresolved` and fails closed until B's own read resolves it.
    /// `insertIfMissing` defaults to `true`, preserving this function's
    /// original behavior for every call site not concerned with
    /// `createdUnderAuthority` at all — in particular claim confirmation
    /// (`applyConfirmed(outcome.request)`), which always hits the
    /// update-in-place branch anyway, since a claimable request must already
    /// exist in Home's fetched collection.
    ///
    /// W4-D2 Success→Home continuity: when `createdUnderAuthority` is given,
    /// `insertIfMissing` is additionally gated by that *same* still-current-
    /// authority read this function already performs for ownership — a
    /// second, independent re-read at the call site would not necessarily
    /// observe the same answer (an authority provider can advance between
    /// two separate calls), which would let insertion and ownership resolve
    /// inconsistently. An authority that changed mid-flight therefore never
    /// inserts here at all, matching the superseded W4-R2 2026-09-05 sync
    /// item 5 "never insert" behavior for that case exactly; only the
    /// still-current-authority case inserts, per the W4-D2 Success→Home
    /// continuity contract.
    ///
    /// `@discardableResult` so every existing call site not concerned with
    /// the confirmed, ownership-resolved value (e.g. claim confirmation)
    /// stays exactly as it was; the W4-D2 create-confirmation sites use the
    /// return value to drive `justCreatedOwnRequest` below.
    @discardableResult
    private func applyConfirmed(
        _ request: FoodRequest,
        createdUnderAuthority: String? = nil,
        insertIfMissing: Bool = true
    ) -> FoodRequest {
        var confirmed = request
        var resolvedInsertIfMissing = insertIfMissing
        if let createdUnderAuthority {
            let isStillCurrentAuthority = participantAuthorityProvider() == createdUnderAuthority
            if isStillCurrentAuthority {
                confirmed = request.withOwnership(.own)
            }
            resolvedInsertIfMissing = insertIfMissing && isStillCurrentAuthority
        }
        if let index = requests.firstIndex(where: { $0.id == confirmed.id }) {
            requests[index] = confirmed
        } else if resolvedInsertIfMissing {
            requests.append(confirmed)
        }
        return confirmed
    }

    private static func asServiceError(_ error: Error) -> RequestServiceError {
        (error as? RequestServiceError) ?? .transport(underlying: error)
    }
}
