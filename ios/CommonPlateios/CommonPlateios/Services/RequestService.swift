//
//  RequestService.swift
//  CommonPlateios
//
//  Created by faith on 7/13/26.
//
// Owns CommonPlate endpoint knowledge and DTO-to-domain mapping, per
// docs/system-contract.md. Talks to the backend only through
// APIClient; never calls URLSession directly. Contains no SwiftUI state and
// no user-facing copy. Never retries POST operations automatically.
import Foundation

/// Product-safe, structured failure surface for the request domain.
///
/// Decoded error envelopes remain code-agnostic here and are preserved as
/// `.serverError(code:message:)`; presentation layers map stable codes to
/// recovery and copy.
enum RequestServiceError: Error {
    /// A non-envelope HTTP 404, indicating that the route is absent at the
    /// configured base URL.
    case notFound
    /// A decoded `{ error: { code, message } }` whose `code` isn't yet
    /// mapped to a dedicated case. Carries the backend's own values as-is —
    /// this is not a guessed/invented code, just a passthrough.
    case serverError(code: String, message: String)
    /// A failure known not to represent an uncertain POST outcome.
    case transport(underlying: Error)
    /// Store-level precondition failure (W4-D2 FIX): the exact-operation
    /// recovery record could not be durably persisted before transmission.
    /// No create POST was sent — this is a pre-transmission local failure,
    /// never an uncertain write.
    case durablePersistenceFailed
    /// A create POST may have been applied server-side, but iOS did not
    /// receive and validate a usable success response.
    case ambiguousCreateOutcome(underlying: Error)
    /// A claim POST may have succeeded server-side, but iOS did not receive
    /// and validate the one-time claim credentials.
    case ambiguousClaimOutcome(underlying: Error)
    /// An extension POST may have been applied server-side, but iOS did not
    /// receive and validate the new expiration. Because only one extension is
    /// ever granted, the caller must neither retry nor advance its local
    /// expiration on this outcome.
    case ambiguousExtensionOutcome(underlying: Error)
    /// A fulfillment POST may have been applied server-side, but iOS did not
    /// receive and validate a usable success response.
    case ambiguousFulfillmentOutcome(underlying: Error)
    /// Client-side precondition failure, not a backend response: no local
    /// active claim exists for the request being fulfilled.
    case noActiveClaim
    /// Client-side precondition failure: the backend-provided claim deadline
    /// has passed, so iOS refused to start a fulfillment POST.
    case claimExpired
    /// A prior fulfillment POST is unresolved. The raw token and claimant
    /// context stay in memory, but another POST is forbidden.
    case unresolvedFulfillment
    /// Store-level precondition failure: an operation of the same kind is
    /// already running, so no second service call was started.
    case operationInProgress
    /// Store-level precondition failure: a claim for a *different* request is
    /// mid-flight. Kept distinct from `operationInProgress` because that case
    /// describes the request in front of the helper as already starting, which
    /// would be untrue here — nothing has been started for this one, and the
    /// wait is short rather than a commitment made elsewhere.
    case otherClaimInProgress
    // W4-H1 deliberately removes the former `unacknowledgedPlacement` case.
    // Authoritatively confirmed fulfillment completes the helper relationship
    // immediately, so no client-side acknowledgement of a placement result may
    // refuse a later claim. The case is not renamed or replaced: there is no
    // remaining store-level precondition that reads confirmation presentation
    // as claim authority.
    /// Store-level precondition failure: a confirmed claim on a *different*
    /// request is already held, so this one cannot be claimed. Kept distinct
    /// from `operationInProgress` because the helper's situation and next step
    /// are different — nothing is in flight, they are already committed
    /// elsewhere — and one message cannot honestly describe both.
    case existingActiveClaim
}

/// Result of a successful claim, mirroring the backend's claim response shape.
/// `claimToken`/`claimExpiresAt` are claim-private and are not folded into the
/// public `FoodRequest` mapping. W4-R4 removed `pickupName` from the request
/// contract, so the claim response no longer carries one either.
struct ClaimOutcome {
    let request: FoodRequest
    let claimToken: String
    let claimExpiresAt: Date
}

/// Result of the one permitted claim extension. The backend returns no request
/// object here, so there is nothing to validate against the path ID and nothing
/// to apply to the public collection — only the authoritative claim deadline.
struct ClaimExtensionOutcome {
    let claimExpiresAt: Date
    let claimExtendedAt: Date
}

/// `GET /api/participant/active-reservation`'s answer for the current verified
/// participant (W3-H1 continuation). Carries no claim token — it was never
/// persisted, so continuation cannot recover it.
struct ActiveReservationOutcome {
    let request: FoodRequest
    let claimExpiresAt: Date
    let claimExtendedAt: Date?
}

/// The claimant-private fulfillment re-entry truth for a verified participant
/// who holds no active claimed reservation (W3-H2): a request they most
/// recently placed, still existing within its retention horizon.
/// `notificationStatus` is `nil` when the outcome never settled — never
/// guessed as sent or failed.
struct PlacedReservationOutcome {
    let request: FoodRequest
    let notificationStatus: NotificationDeliveryStatus?
}

/// Backend truth for `GET /api/participant/active-reservation` (W3-H1
/// continuation, extended by W3-H2 fulfillment re-entry): a verified
/// participant may currently hold an active claimed reservation, may hold
/// none but have most recently placed a still-existing request, or may hold
/// neither.
enum ParticipantReservationState {
    case reservation(ActiveReservationOutcome)
    case placed(PlacedReservationOutcome)
    case none
}

/// Result of a successful fulfillment, mirroring the backend's fulfill response shape.
/// Core placement success (`request`) is independent of notification delivery.
struct FulfillOutcome {
    let request: FoodRequest
    let notificationStatus: NotificationDeliveryStatus
}

struct RequestService {
    let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    /// The header the backend reads participant authority from (W3-I1). It has
    /// to match `PARTICIPANT_AUTHORITY_HEADER` in
    /// `src/participantAuthorityGate.ts`.
    static let participantAuthorityHeader = "x-commonplate-participant"

    /// The header the backend reads the W3-D1 request-create operation
    /// identity from. It has to match `OPERATION_IDENTITY_HEADER` in
    /// `src/createRequestRoute.ts`.
    static let operationIdentityHeader = "x-commonplate-operation-id"
    /// W4-D2: the ledger authority a create operation was recorded against.
    /// The backend serves such a request only from that ledger.
    static let operationAuthorityHeader = "x-commonplate-operation-authority"

    /// Builds the credential header, or none at all.
    ///
    /// An absent credential deliberately sends *no* header rather than an empty
    /// one: "this caller has not verified" and "this caller presented something
    /// unusable" are different backend answers, and only the first is true
    /// here. Conflating them would tell an unverified student their stored
    /// identity had been rejected.
    private static func participantHeaders(_ authority: String?) -> [String: String] {
        guard let authority, !authority.isEmpty else { return [:] }
        return [participantAuthorityHeader: authority]
    }

    /// `GET /api/requests`
    ///
    /// Browsing stays open to anyone (W3-I1), so `participantAuthority` is
    /// optional and sent only when this device already holds one. When
    /// present, the backend additionally removes any request this verified
    /// participant has ever successfully held from their own list (W3-H2
    /// marketplace presentation) — every other caller's list is unaffected.
    func fetchActiveRequests(participantAuthority: String? = nil) async throws -> [FoodRequest] {
        do {
            let response: RequestListResponseDTO = try await client.send(
                path: "/api/requests",
                method: .get,
                headers: Self.participantHeaders(participantAuthority)
            )
            // `GET /api/requests` derives caller-relative ownership for the
            // authority this call presented, so its answer is authoritative
            // for that authority — including the affirmative-signal-absent
            // case, which means "not this caller's own request".
            return try response.requests.map {
                try Self.mapPublicRequest(
                    $0,
                    ownership: Self.resolvedOwnership($0, presentedAuthority: participantAuthority)
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// Privacy-safe `GET /api/request/:id`. The backend reports effective
    /// availability here (a claim-expired request reads back as `open`), not
    /// raw persisted status; it never authorizes fulfillment. Used once after
    /// an ambiguous fulfillment POST to see whether placement can be
    /// confirmed, and by helper new-request notification tap-routing to
    /// resolve whether the tapped request is still available.
    ///
    /// `participantAuthority` is optional and, like `fetchActiveRequests`,
    /// sent only when this device already holds one — so the mapped
    /// `FoodRequest.isOwnRequest` reflects the resolving caller's own
    /// current identity for the notification-tap-routing caller (the only
    /// one that renders it), rather than always defaulting to "not own" the
    /// way an unconditionally anonymous call would.
    func fetchRequest(id: String, participantAuthority: String? = nil) async throws -> FoodRequest {
        do {
            let response: RequestDetailResponseDTO = try await client.send(
                path: "/api/request/\(id)",
                method: .get,
                headers: Self.participantHeaders(participantAuthority)
            )
            try Self.validateResponseRequestID(response.request.id, expected: id)
            // `GET /api/request/:id` now derives the same caller-relative
            // ownership the list does (W4-H2 detail projection), so a detail
            // read is authoritative for the authority it presented.
            return try Self.mapPublicRequest(
                response.request,
                ownership: Self.resolvedOwnership(
                    response.request,
                    presentedAuthority: participantAuthority
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// Participant-aware `GET /api/request/:id` (W3-H2 stale detail Reserve
    /// truth). Reports whether the verified participant behind
    /// `participantAuthority` already holds a durable one-successful-
    /// participation record for this exact request, so a detail screen
    /// reached through stale navigation can withdraw its Reserve affordance
    /// instead of only discovering the refusal after a tap.
    ///
    /// Deliberately separate from `fetchRequest` above: that method's two
    /// existing callers (ambiguous-fulfillment confirmation and helper
    /// notification tap-routing) need no participation truth, and must not
    /// gain a dependency on this field's presence or decoding.
    func fetchAlreadyParticipated(
        id: String,
        participantAuthority: String
    ) async throws -> Bool {
        do {
            let response: RequestDetailResponseDTO = try await client.send(
                path: "/api/request/\(id)",
                method: .get,
                headers: Self.participantHeaders(participantAuthority)
            )
            try Self.validateResponseRequestID(response.request.id, expected: id)
            return response.alreadyParticipated ?? false
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `GET /api/public-actions`
    ///
    /// Returns the backend's pause decision for public mutations. Read-only
    /// and ungated, so it is safe to call before the requester has entered
    /// anything. This method does not decide the fail-closed policy — it
    /// reports success or throws, and the caller treats any failure as
    /// "posting unavailable".
    func fetchPublicActionsPaused() async throws -> Bool {
        do {
            let response: PublicActionsStateDTO = try await client.send(
                path: "/api/public-actions",
                method: .get
            )
            return response.paused
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `POST /api/request`
    ///
    /// The requester is the verified participant behind `participantAuthority`,
    /// not the payload: the backend derives and binds identity from the
    /// credential and ignores any address the payload happens to carry.
    ///
    /// `operationId`, when present, is the W3-D1 exact logical-operation
    /// identity (`RequestStore` mints and reuses it across every recovery
    /// attempt for one intentional submission). `nil` sends no identity header
    /// at all and gets the exact pre-D1, non-idempotent create behavior — this
    /// default exists so a caller with no operation concept (a direct
    /// `RequestService` test) does not have to invent one.
    ///
    /// Generic over the body only so W3-D1 recovery can replay a pre-R4
    /// pending operation with its exact original body
    /// (`LegacyCreateRequestPayload`); every new create sends
    /// `CreateRequestPayload`.
    ///
    /// `operationLedger` (W4-D2) is the ledger authority the pending operation
    /// recorded. When present, only a backend holding exactly that ledger will
    /// read or create under `operationId`; any other answers
    /// `OPERATION_AUTHORITY_MISMATCH` before touching its ledger.
    func createRequest<Payload: Encodable>(
        _ payload: Payload,
        operationId: String? = nil,
        participantAuthority: String? = nil,
        operationLedger: String? = nil
    ) async throws -> FoodRequest {
        try Task.checkCancellation()

        var headers = Self.participantHeaders(participantAuthority)
        if let operationId {
            headers[Self.operationIdentityHeader] = operationId
        }
        if let operationLedger {
            headers[Self.operationAuthorityHeader] = operationLedger
        }

        let response: RequestDetailResponseDTO
        do {
            response = try await client.send(
                path: "/api/request",
                method: .post,
                body: payload,
                headers: headers
            )
        } catch is CancellationError {
            throw RequestServiceError.ambiguousCreateOutcome(underlying: CancellationError())
        } catch let error as APIClientError {
            switch error {
            // A 404 is definitive at the HTTP level: this route does not exist
            // at this base URL, so nothing was created. Classifying it as
            // ambiguous would lock request creation for the rest of the
            // process over a misconfigured host or an unmounted route.
            case .unexpectedStatus(404):
                throw RequestServiceError.notFound
            // Everything else that reaches here is genuinely indeterminate:
            // transport loss or a timeout after the body may already have been
            // sent, an undecodable success body, or a status whose response
            // does not prove that no write occurred. An unreadable 5xx stays
            // ambiguous — being an error is not proof of a rollback.
            case .transport, .decoding, .unexpectedStatus:
                throw RequestServiceError.ambiguousCreateOutcome(underlying: error)
            default:
                throw Self.translate(error)
            }
        } catch {
            throw Self.translate(error)
        }

        do {
            let request = try Self.mapPublicRequest(response.request, ownership: .unresolved)
            try Self.validateResponseStatus(request.status, expected: .open)
            return request
        } catch {
            throw RequestServiceError.ambiguousCreateOutcome(underlying: error)
        }
    }

    /// W4-D2: where this service sends request-create operations — the
    /// normalized configured base URL (scheme, host, effective port, and path;
    /// never credentials, query, or fragment). Only half of an operation
    /// authority: the same origin can front a reset or replaced ledger, which
    /// `fetchOperationLedger()` distinguishes.
    var operationAuthorityOrigin: String {
        Self.operationAuthorityOrigin(for: client.configuration.baseURL)
    }

    static func operationAuthorityOrigin(for baseURL: URL) -> String {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            // Not a usable network origin; this still never matches a
            // well-formed origin recorded by another configuration.
            return baseURL.absoluteString
        }
        let port = components.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        let renderedHost = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(renderedHost):\(port)\(path)"
    }

    /// `GET /api/request-operation/authority` (W4-D2).
    ///
    /// The identity of the operation ledger behind this service right now. A
    /// create records it before transmission and sends it with the create;
    /// recovery compares it with what was recorded. Anything but a
    /// well-formed identity throws: no ledger is ever assumed.
    func fetchOperationLedger() async throws -> String {
        do {
            let response: RequestOperationAuthorityResponseDTO = try await client.send(
                path: "/api/request-operation/authority",
                method: .get
            )
            guard RequestOperationAuthorityIdentity.isValidLedger(response.operationAuthority) else {
                throw APIClientError.decoding(
                    DecodingError.dataCorrupted(
                        .init(codingPath: [], debugDescription: "Malformed operation ledger identity")
                    )
                )
            }
            return response.operationAuthority
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `POST /api/request-operation/terminal` (W4-D2).
    ///
    /// Asks backend authority for the one terminal outcome of the exact
    /// operation `operationId`, establishing terminal NO-CREATE when nothing
    /// has created it — only in the ledger `operationLedger` names, which the
    /// backend enforces. Sends no request content. Every thrown error means the
    /// outcome was not established by this call: a decoded envelope stays a
    /// `.serverError` for the caller to classify, and everything else —
    /// transport loss, an unreadable or unrecognized answer, a bare 404 — is
    /// inconclusive. Never retried here.
    func reconcileRequestOperationTerminal(
        operationId: String,
        participantAuthority: String,
        operationLedger: String
    ) async throws -> RequestOperationTerminalOutcome {
        var headers = Self.participantHeaders(participantAuthority)
        headers[Self.operationIdentityHeader] = operationId
        headers[Self.operationAuthorityHeader] = operationLedger
        do {
            let response: RequestOperationTerminalResponseDTO = try await client.send(
                path: "/api/request-operation/terminal",
                method: .post,
                headers: headers
            )
            switch response.outcome {
            case .notCreated:
                guard response.request == nil else {
                    throw APIClientError.decoding(
                        DecodingError.dataCorrupted(
                            .init(codingPath: [], debugDescription: "A not-created outcome carried a request")
                        )
                    )
                }
                return .notCreated
            case .created:
                guard let dto = response.request else {
                    throw APIClientError.decoding(
                        DecodingError.dataCorrupted(
                            .init(codingPath: [], debugDescription: "A created outcome carried no request")
                        )
                    )
                }
                // Any current lifecycle status is authoritative here: the
                // explicit outcome, not the request's present status, says
                // this operation created it.
                return .created(try Self.mapPublicRequest(dto, ownership: .unresolved))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `POST /api/request/:id/claim`
    ///
    /// The reservation is bound to the verified participant behind
    /// `participantAuthority`, and fulfillment later reuses that binding rather
    /// than asking for a helper address.
    func claimRequest(
        id: String,
        participantAuthority: String? = nil
    ) async throws -> ClaimOutcome {
        try Task.checkCancellation()

        let response: ClaimResponseDTO
        do {
            response = try await client.send(
                path: "/api/request/\(id)/claim",
                method: .post,
                body: EmptyBody(),
                headers: Self.participantHeaders(participantAuthority)
            )
        } catch is CancellationError {
            throw RequestServiceError.ambiguousClaimOutcome(underlying: CancellationError())
        } catch let error as APIClientError {
            switch error {
            // A readable claim INTERNAL_FAILURE does not prove the conditional
            // mutation was rejected: MongoDB may have applied it before the
            // driver lost its acknowledgement. The one-time credentials then
            // cannot be reconstructed, so preserve the existing no-retry
            // ambiguous-claim recovery rather than inviting another claim.
            case .apiError(let code, _) where code == ClaimErrorCode.internalFailure:
                throw RequestServiceError.ambiguousClaimOutcome(underlying: error)
            case .transport, .decoding, .unexpectedStatus:
                throw RequestServiceError.ambiguousClaimOutcome(underlying: error)
            default:
                throw Self.translate(error)
            }
        } catch {
            throw Self.translate(error)
        }

        do {
            try Self.validateResponseRequestID(response.request.id, expected: id)
            let request = try Self.mapPublicRequest(response.request, ownership: .unresolved)
            try Self.validateResponseStatus(request.status, expected: .claimed)
            guard !response.claim.claimToken.isEmpty else {
                throw APIClientError.decoding(
                    DecodingError.dataCorrupted(
                        .init(codingPath: [], debugDescription: "Claim response did not include usable authorization")
                    )
                )
            }
            return ClaimOutcome(
                request: request,
                claimToken: response.claim.claimToken,
                claimExpiresAt: response.claim.claimExpiresAt
            )
        } catch {
            throw RequestServiceError.ambiguousClaimOutcome(underlying: error)
        }
    }

    /// `POST /api/request/:id/claim/extend`
    ///
    /// Proves claim ownership by submitting the raw token the winning claim
    /// returned. Only one extension is ever granted, so a failed or
    /// unconfirmed attempt is never retried here — an outcome iOS cannot
    /// validate is reported as `ambiguousExtensionOutcome` so the caller keeps
    /// its current expiration rather than assuming five more minutes.
    func extendClaim(id: String, claimToken: String) async throws -> ClaimExtensionOutcome {
        try Task.checkCancellation()

        let response: ClaimExtensionResponseDTO
        do {
            response = try await client.send(
                path: "/api/request/\(id)/claim/extend",
                method: .post,
                body: ClaimExtensionPayload(claimToken: claimToken)
            )
        } catch is CancellationError {
            throw RequestServiceError.ambiguousExtensionOutcome(underlying: CancellationError())
        } catch let error as APIClientError {
            switch error {
            case .transport, .decoding, .unexpectedStatus:
                throw RequestServiceError.ambiguousExtensionOutcome(underlying: error)
            default:
                throw Self.translate(error)
            }
        } catch {
            throw Self.translate(error)
        }

        return ClaimExtensionOutcome(
            claimExpiresAt: response.claim.claimExpiresAt,
            claimExtendedAt: response.claim.claimExtendedAt
        )
    }

    /// `POST /api/request/:id/claim/extend`, authorizing with verified
    /// participant authority instead of the raw claim token (W3-H1
    /// continuation) — for the case the raw token is gone after termination
    /// and relaunch. An empty JSON object body plus the credential header is
    /// the accepted second request shape the backend authorizes.
    func extendClaim(id: String, participantAuthority: String) async throws -> ClaimExtensionOutcome {
        try Task.checkCancellation()

        let response: ClaimExtensionResponseDTO
        do {
            response = try await client.send(
                path: "/api/request/\(id)/claim/extend",
                method: .post,
                body: EmptyBody(),
                headers: Self.participantHeaders(participantAuthority)
            )
        } catch is CancellationError {
            throw RequestServiceError.ambiguousExtensionOutcome(underlying: CancellationError())
        } catch let error as APIClientError {
            switch error {
            case .transport, .decoding, .unexpectedStatus:
                throw RequestServiceError.ambiguousExtensionOutcome(underlying: error)
            default:
                throw Self.translate(error)
            }
        } catch {
            throw Self.translate(error)
        }

        return ClaimExtensionOutcome(
            claimExpiresAt: response.claim.claimExpiresAt,
            claimExtendedAt: response.claim.claimExtendedAt
        )
    }

    /// `POST /api/request/:id/claim/release` (W3-H1), authorizing with the raw
    /// claim token. Safe to retry: a repeated release of an already-released
    /// or otherwise-ended claim is refused, never duplicated, so an outcome
    /// iOS cannot confirm needs no ambiguity recovery of its own — the caller
    /// simply leaves its local claim state untouched and may try again.
    func releaseClaim(id: String, claimToken: String) async throws {
        try Task.checkCancellation()
        do {
            let response: ReleaseResponseDTO = try await client.send(
                path: "/api/request/\(id)/claim/release",
                method: .post,
                body: ClaimExtensionPayload(claimToken: claimToken)
            )
            try Self.validateConfirmedRelease(response)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `POST /api/request/:id/claim/release`, authorizing with verified
    /// participant authority instead of the raw claim token (W3-H1
    /// continuation).
    func releaseClaim(id: String, participantAuthority: String) async throws {
        try Task.checkCancellation()
        do {
            let response: ReleaseResponseDTO = try await client.send(
                path: "/api/request/\(id)/claim/release",
                method: .post,
                body: EmptyBody(),
                headers: Self.participantHeaders(participantAuthority)
            )
            try Self.validateConfirmedRelease(response)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `GET /api/participant/active-reservation` (W3-H1 continuation,
    /// extended by W3-H2 fulfillment re-entry).
    ///
    /// Resolves the verified participant's current active reservation from
    /// backend truth; when they hold none, the same read additionally
    /// resolves whether they most recently placed a still-existing request.
    /// W4-H1 uses that placed answer as a safety read only: a relaunched
    /// client reconciles it to helper-available state and reconstructs no
    /// success presentation. Never fabricates either from local
    /// state — only a confirmed backend answer, or a thrown error the caller
    /// must treat as "truth not established", is returned.
    func fetchParticipantReservationState(
        participantAuthority: String
    ) async throws -> ParticipantReservationState {
        try Task.checkCancellation()

        let response: ActiveReservationResponseDTO
        do {
            response = try await client.send(
                path: "/api/participant/active-reservation",
                method: .get,
                headers: Self.participantHeaders(participantAuthority)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }

        if let reservation = response.reservation {
            let request = try Self.mapPublicRequest(reservation.request, ownership: .unresolved)
            return .reservation(ActiveReservationOutcome(
                request: request,
                claimExpiresAt: reservation.claimExpiresAt,
                claimExtendedAt: reservation.claimExtendedAt
            ))
        }
        if let placement = response.placement {
            let request = try Self.mapPublicRequest(placement.request, ownership: .unresolved)
            return .placed(PlacedReservationOutcome(
                request: request,
                notificationStatus: placement.notification?.status
            ))
        }
        return .none
    }

    /// `GET /api/participant/request-eligibility` (W4-Q1).
    ///
    /// Bounded participant-authorized prerequisite for a future
    /// requester-entry eligibility check (R2 UI is not implemented here).
    /// Reports whether the verified participant behind `participantAuthority`
    /// is presently `eligible` or `exhausted` under the existing best-effort
    /// three-per-NYU-campus-day quota — the same shared authority
    /// `POST /api/request` uses as its own final create-time check
    /// (`src/requestDailyQuota.ts`). Advisory and current-as-of-read only: an
    /// `eligible` result never reserves quota and never guarantees a later
    /// `POST /api/request` will succeed.
    func fetchRequestCreationEligibility(
        participantAuthority: String
    ) async throws -> RequestEligibilityWire {
        try Task.checkCancellation()
        do {
            let response: RequestEligibilityResponseDTO = try await client.send(
                path: "/api/participant/request-eligibility",
                method: .get,
                headers: Self.participantHeaders(participantAuthority)
            )
            return response.eligibility
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `POST /api/request/:id/fulfill`
    /// The helper is whoever the claim is bound to, so this deliberately takes
    /// no address: the backend derives it from the reservation and refuses a
    /// payload that carries one.
    func fulfillRequest(
        id: String,
        claimToken: String,
        orderNumber: String,
        eta: String,
        contactMessage: String?
    ) async throws -> FulfillOutcome {
        let payload = FulfillRequestPayload(
            claimToken: claimToken,
            fulfillment: FulfillmentPayload(
                orderNumber: orderNumber,
                eta: eta,
                contactMessage: contactMessage
            )
        )
        try Task.checkCancellation()

        let response: FulfillResponseDTO
        do {
            response = try await client.send(
                path: "/api/request/\(id)/fulfill",
                method: .post,
                body: payload
            )
        } catch is CancellationError {
            throw RequestServiceError.ambiguousFulfillmentOutcome(underlying: CancellationError())
        } catch let error as APIClientError {
            switch error {
            // A readable fulfillment INTERNAL_FAILURE can follow a committed
            // transaction whose acknowledgement was lost. It is therefore not
            // a definitive ordinary failure: retain the original payload for
            // the existing one-read, one-resend ambiguity recovery flow.
            case .apiError(let code, _) where code == ClaimErrorCode.internalFailure:
                throw RequestServiceError.ambiguousFulfillmentOutcome(underlying: error)
            case .transport, .decoding, .unexpectedStatus:
                throw RequestServiceError.ambiguousFulfillmentOutcome(underlying: error)
            default:
                throw Self.translate(error)
            }
        } catch {
            throw Self.translate(error)
        }

        do {
            try Self.validateResponseRequestID(response.request.id, expected: id)
            let request = try Self.mapPublicRequest(response.request, ownership: .unresolved)
            try Self.validateResponseStatus(request.status, expected: .placed)
            return FulfillOutcome(request: request, notificationStatus: response.notification.status)
        } catch {
            throw RequestServiceError.ambiguousFulfillmentOutcome(underlying: error)
        }
    }

    /// `POST /api/request/:id/fulfill`, authorizing with verified participant
    /// authority instead of the raw claim token (W3-H1 continuation) — for a
    /// reservation restored by `fetchActiveReservation` after the raw token
    /// was already lost to process termination. The backend accepts this as
    /// an additive authorization path and never persists the (never sent)
    /// raw token; see `fulfillRequest(id:claimToken:...)` above for the
    /// still-unchanged in-process path.
    func fulfillRequest(
        id: String,
        participantAuthority: String,
        orderNumber: String,
        eta: String,
        contactMessage: String?
    ) async throws -> FulfillOutcome {
        let payload = FulfillContinuationRequestPayload(
            fulfillment: FulfillmentPayload(
                orderNumber: orderNumber,
                eta: eta,
                contactMessage: contactMessage
            )
        )
        try Task.checkCancellation()

        let response: FulfillResponseDTO
        do {
            response = try await client.send(
                path: "/api/request/\(id)/fulfill",
                method: .post,
                body: payload,
                headers: Self.participantHeaders(participantAuthority)
            )
        } catch is CancellationError {
            throw RequestServiceError.ambiguousFulfillmentOutcome(underlying: CancellationError())
        } catch let error as APIClientError {
            switch error {
            case .apiError(let code, _) where code == ClaimErrorCode.internalFailure:
                throw RequestServiceError.ambiguousFulfillmentOutcome(underlying: error)
            case .transport, .decoding, .unexpectedStatus:
                throw RequestServiceError.ambiguousFulfillmentOutcome(underlying: error)
            default:
                throw Self.translate(error)
            }
        } catch {
            throw Self.translate(error)
        }

        do {
            try Self.validateResponseRequestID(response.request.id, expected: id)
            let request = try Self.mapPublicRequest(response.request, ownership: .unresolved)
            try Self.validateResponseStatus(request.status, expected: .placed)
            return FulfillOutcome(request: request, notificationStatus: response.notification.status)
        } catch {
            throw RequestServiceError.ambiguousFulfillmentOutcome(underlying: error)
        }
    }

    // MARK: - Mapping

    private static func validateResponseRequestID(_ responseID: String, expected requestID: String) throws {
        guard responseID == requestID else {
            throw APIClientError.decoding(
                DecodingError.dataCorrupted(
                    .init(
                        codingPath: [],
                        debugDescription: "Response request ID does not match the requested resource"
                    )
                )
            )
        }
    }

    /// A decoded 2xx body is not itself release truth. Only the backend's
    /// explicit affirmative result permits `RequestStore` to retire the local
    /// reservation; `false` follows the existing ordinary release-failure path.
    private static func validateConfirmedRelease(_ response: ReleaseResponseDTO) throws {
        guard response.released else {
            throw APIClientError.decoding(
                DecodingError.dataCorrupted(
                    .init(
                        codingPath: [],
                        debugDescription: "Release response did not confirm release"
                    )
                )
            )
        }
    }

    private static func validateResponseStatus(_ status: RequestStatus, expected: RequestStatus) throws {
        guard status.rawValue == expected.rawValue else {
            throw APIClientError.decoding(
                DecodingError.dataCorrupted(
                    .init(
                        codingPath: [],
                        debugDescription: "Response lifecycle status \(status.rawValue) does not match expected status \(expected.rawValue)"
                    )
                )
            )
        }
    }

    /// Maps a public `RequestResponseDTO` (list/detail/create/claim/fulfill's
    /// embedded `request`) to the canonical domain model. Never fabricates
    /// requester-private fields (`email`, `phoneNumber`) — the public wire
    /// shape never carries them, and `FoodRequest` has no properties in which
    /// to store them. Pickup name is not among them because W4-R4 removed it
    /// from the request contract entirely.
    ///
    /// An unrecognized wire status value throws (via `RequestStatusWire`'s
    /// `Decodable` conformance failing at decode time) rather than silently
    /// mapping to an incorrect lifecycle state.
    /// `ownership` is required rather than defaulted (W4-H2): only a caller
    /// that knows the response actually carries current-authority
    /// caller-relative ownership may claim a resolved answer. Every other
    /// endpoint must pass `.unresolved`, so an absent `isOwnRequest` on a
    /// response shape that never derives ownership can no longer become an
    /// actionable "not own".
    private static func mapPublicRequest(
        _ dto: RequestResponseDTO,
        ownership: RequestOwnership
    ) throws -> FoodRequest {
        return FoodRequest(
            id: dto.id,
            diningSpot: DiningSpot(name: dto.vendor, address: nil),
            foodDescription: dto.food,
            pickupWindowText: dto.pickupWindowText,
            mealSwipes: dto.mealSwipes,
            // W4-R4: the structured representation exactly as the backend
            // projected it. Passed explicitly at this one mapping site — the
            // sole production decode path — so no surface ever sees the
            // `.unspecified` placeholder `FoodRequest.init` defaults to.
            resource: RequestResource(
                menuPath: dto.menuPath.domainMenuPath,
                mealItems: dto.mealItems,
                orderDetails: dto.orderDetails,
                estimatedDiningDollarsCents: dto.estimatedDiningDollarsCents
            ),
            windowStart: dto.windowStart,
            windowEnd: dto.windowEnd,
            createdAt: dto.createdAt,
            expiresAt: dto.expiresAt,
            status: dto.status.domainStatus,
            ownership: ownership
        )
    }

    /// Ownership as answered by a route that genuinely derives it
    /// (`GET /api/requests`, `GET /api/request/:id`).
    ///
    /// Deliberately *not* `dto.isOwnRequest ?? false`. Field absence is not
    /// one fact, and which fact it is depends on something only this client
    /// knows: whether it presented a participant credential at all.
    ///
    /// - No credential presented → the caller is browsing anonymously.
    ///   Creating a request requires participant authority
    ///   (`createRequestRoute.ts` refuses an unverified caller outright), so
    ///   an anonymous session owns nothing, and `.notOwn` is correct *for as
    ///   long as the caller stays anonymous*. That conclusion must not
    ///   survive into a verified authority — `RequestDetailView` invalidates
    ///   it on any identity transition.
    /// - Credential presented, field `true`/`false` → the server resolved it
    ///   and stated the answer.
    /// - Credential presented, field absent → the server could not resolve
    ///   the presented authority. Ownership is unknown; fail closed.
    private static func resolvedOwnership(
        _ dto: RequestResponseDTO,
        presentedAuthority: String?
    ) -> RequestOwnership {
        guard presentedAuthority?.isEmpty == false else {
            // Anonymous. A server that nonetheless affirms ownership is
            // contradicting the contract (it cannot know whose request this
            // is without a credential), so that is treated as unknown rather
            // than believed.
            return dto.isOwnRequest == true ? .unresolved : .notOwn
        }
        switch dto.isOwnRequest {
        case .some(true): return .own
        case .some(false): return .notOwn
        case .none: return .unresolved
        }
    }

    /// Translates a client/transport failure into the product-safe error surface.
    /// A decoded error envelope is passed through as `.serverError(code:message:)`
    /// verbatim, and only a non-envelope HTTP 404 (unambiguous regardless of code
    /// string) maps to a dedicated case. Mapping stable codes to copy and
    /// recovery is the presentation layer's job, not this one's.
    private static func translate(_ error: Error) -> RequestServiceError {
        guard let clientError = error as? APIClientError else {
            return .transport(underlying: error)
        }

        switch clientError {
        case .apiError(let code, let message):
            return .serverError(code: code, message: message)
        case .unexpectedStatus(let statusCode):
            if statusCode == 404 {
                return .notFound
            }
            return .transport(underlying: clientError)
        case .encoding, .decoding, .invalidURL:
            return .transport(underlying: clientError)
        case .transport(let underlying):
            return .transport(underlying: underlying)
        }
    }
}

/// Empty JSON body for POSTs (e.g. claim) that carry no request payload.
private struct EmptyBody: Encodable {}
