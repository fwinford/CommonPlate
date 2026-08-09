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
    /// Store-level precondition failure: a confirmed placement result is still
    /// waiting to be acknowledged. Week 2 holds one confirmation at a time, so
    /// starting another claim would eventually overwrite and lose a real sent /
    /// failed / unknown-email outcome. Acknowledgement is the gate.
    case unacknowledgedPlacement
    /// Store-level precondition failure: a confirmed claim on a *different*
    /// request is already held, so this one cannot be claimed. Kept distinct
    /// from `operationInProgress` because the helper's situation and next step
    /// are different — nothing is in flight, they are already committed
    /// elsewhere — and one message cannot honestly describe both.
    case existingActiveClaim
}

/// Result of a successful claim, mirroring the backend's claim response shape.
/// `pickupName`/`claimToken`/`claimExpiresAt` are claim-private and are not
/// folded into the public `FoodRequest` mapping.
struct ClaimOutcome {
    let request: FoodRequest
    let pickupName: String
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
    func fetchActiveRequests() async throws -> [FoodRequest] {
        do {
            let response: RequestListResponseDTO = try await client.send(
                path: "/api/requests",
                method: .get
            )
            return try response.requests.map(Self.mapPublicRequest)
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
    func fetchRequest(id: String) async throws -> FoodRequest {
        do {
            let response: RequestDetailResponseDTO = try await client.send(
                path: "/api/request/\(id)",
                method: .get
            )
            try Self.validateResponseRequestID(response.request.id, expected: id)
            return try Self.mapPublicRequest(response.request)
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
    func createRequest(
        _ payload: CreateRequestPayload,
        participantAuthority: String? = nil
    ) async throws -> FoodRequest {
        try Task.checkCancellation()

        let response: RequestDetailResponseDTO
        do {
            response = try await client.send(
                path: "/api/request",
                method: .post,
                body: payload,
                headers: Self.participantHeaders(participantAuthority)
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
            let request = try Self.mapPublicRequest(response.request)
            try Self.validateResponseStatus(request.status, expected: .open)
            return request
        } catch {
            throw RequestServiceError.ambiguousCreateOutcome(underlying: error)
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
            let request = try Self.mapPublicRequest(response.request)
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
                pickupName: response.claim.pickupName,
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
            let request = try Self.mapPublicRequest(response.request)
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
    /// requester-private fields (`pickupName`, `email`, `phoneNumber`) — the
    /// public wire shape never carries them, and `FoodRequest` has no properties
    /// in which to store them.
    ///
    /// An unrecognized wire status value throws (via `RequestStatusWire`'s
    /// `Decodable` conformance failing at decode time) rather than silently
    /// mapping to an incorrect lifecycle state.
    private static func mapPublicRequest(_ dto: RequestResponseDTO) throws -> FoodRequest {
        return FoodRequest(
            id: dto.id,
            diningSpot: DiningSpot(name: dto.vendor, address: nil),
            foodDescription: dto.food,
            pickupWindowText: dto.pickupWindowText,
            windowStart: dto.windowStart,
            windowEnd: dto.windowEnd,
            createdAt: dto.createdAt,
            expiresAt: dto.expiresAt,
            status: dto.status.domainStatus
        )
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
