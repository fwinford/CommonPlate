//
//  RequestService.swift
//  CommonPlateios
//
//  Created by faith on 7/13/26.
//
// Owns CommonPlate endpoint knowledge and DTO-to-domain mapping, per
// docs/week-2-integration-spec.md. Talks to the backend only through
// APIClient; never calls URLSession directly. Contains no SwiftUI state and
// no user-facing copy. Never retries POST operations automatically.
import Foundation

/// Product-safe, structured failure surface for the request domain.
///
/// The integration spec (`docs/week-2-integration-spec.md`) locks the error
/// *envelope* shape (`{ error: { code, message, fields } }`) and, for the Day 4
/// claim and extension routes, a set of stable codes. This type stays code-
/// agnostic anyway: a decoded envelope is preserved verbatim as
/// `.serverError(code:message:)`, and the deliberate mapping of those codes to
/// product behavior lives one layer up, where the copy and recovery for each
/// code belong. Endpoints outside the Day 4 routes still have endpoint-specific
/// error shapes, which the same passthrough handles without guessing names.
enum RequestServiceError: Error {
    /// Unambiguous at the HTTP level (404) regardless of which stable code
    /// string the backend eventually adopts.
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
    /// Store-level precondition failure: an operation of the same kind is
    /// already running, so no second service call was started.
    case operationInProgress
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
    func createRequest(_ payload: CreateRequestPayload) async throws -> FoodRequest {
        try Task.checkCancellation()

        let response: RequestDetailResponseDTO
        do {
            response = try await client.send(
                path: "/api/request",
                method: .post,
                body: payload
            )
        } catch is CancellationError {
            throw RequestServiceError.ambiguousCreateOutcome(underlying: CancellationError())
        } catch let error as APIClientError {
            switch error {
            case .transport, .decoding:
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
    func claimRequest(id: String) async throws -> ClaimOutcome {
        try Task.checkCancellation()

        let response: ClaimResponseDTO
        do {
            response = try await client.send(
                path: "/api/request/\(id)/claim",
                method: .post,
                body: EmptyBody()
            )
        } catch is CancellationError {
            throw RequestServiceError.ambiguousClaimOutcome(underlying: CancellationError())
        } catch let error as APIClientError {
            switch error {
            case .transport, .decoding:
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
            case .transport, .decoding:
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
    func fulfillRequest(
        id: String,
        claimToken: String,
        fulfillerEmail: String,
        orderNumber: String,
        eta: String,
        note: String?,
        contactMessage: String?
    ) async throws -> FulfillOutcome {
        let payload = FulfillRequestPayload(
            claimToken: claimToken,
            fulfillment: FulfillmentPayload(
                fulfillerEmail: fulfillerEmail,
                orderNumber: orderNumber,
                eta: eta,
                note: note,
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
            case .transport, .decoding:
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
