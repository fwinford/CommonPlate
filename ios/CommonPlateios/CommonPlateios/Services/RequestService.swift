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
/// *envelope* shape (`{ error: { code, message } }`) but does not enumerate
/// concrete stable code strings for claim expiration, invalid token,
/// already-claimed/placed, etc. — those are explicitly pending backend
/// contract work (Day 5/6). Rather than guess likely names, this type maps
/// only what is unambiguous today and otherwise preserves the backend's own
/// code/message pair for later UI mapping once the real codes are locked.
enum RequestServiceError: Error {
    /// Unambiguous at the HTTP level (404) regardless of which stable code
    /// string the backend eventually adopts.
    case notFound
    /// A decoded `{ error: { code, message } }` whose `code` isn't yet
    /// mapped to a dedicated case. Carries the backend's own values as-is —
    /// this is not a guessed/invented code, just a passthrough.
    case serverError(code: String, message: String)
    /// Network/transport failure or a response that failed to decode.
    case transport(underlying: Error)
    /// A fulfillment POST failed at the transport layer after the request may
    /// have already been applied server-side; the outcome cannot be
    /// determined from this response alone. Callers must not retry
    /// automatically and should prompt a refresh instead.
    case ambiguousFulfillmentOutcome(underlying: Error)
    /// Client-side precondition failure, not a backend response: no local
    /// active claim exists for the request being fulfilled.
    case noActiveClaim
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
    func fetchRequests() async throws -> [FoodRequest] {
        do {
            let response: RequestListResponseDTO = try await client.send(
                path: "/api/requests",
                method: .get
            )
            return try response.requests.map(Self.mapPublicRequest)
        } catch {
            throw Self.translate(error)
        }
    }

    /// `POST /api/request`
    func createRequest(_ payload: CreateRequestPayload) async throws -> FoodRequest {
        do {
            let response: RequestDetailResponseDTO = try await client.send(
                path: "/api/request",
                method: .post,
                body: payload
            )
            return try Self.mapPublicRequest(response.request)
        } catch {
            throw Self.translate(error)
        }
    }

    /// `POST /api/request/:id/claim`
    func claimRequest(id: String) async throws -> ClaimOutcome {
        do {
            let response: ClaimResponseDTO = try await client.send(
                path: "/api/request/\(id)/claim",
                method: .post,
                body: EmptyBody()
            )
            let request = try Self.mapPublicRequest(response.request)
            return ClaimOutcome(
                request: request,
                pickupName: response.pickupName,
                claimToken: response.claimToken,
                claimExpiresAt: response.claimExpiresAt
            )
        } catch {
            throw Self.translate(error)
        }
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
        do {
            let response: FulfillResponseDTO = try await client.send(
                path: "/api/request/\(id)/fulfill",
                method: .post,
                body: payload
            )
            let request = try Self.mapPublicRequest(response.request)
            return FulfillOutcome(request: request, notificationStatus: response.notification.status)
        } catch let error as APIClientError {
            switch error {
            case .transport, .unexpectedStatus:
                // The POST may have already applied server-side; the caller
                // must not retry and should treat this as ambiguous.
                throw RequestServiceError.ambiguousFulfillmentOutcome(underlying: error)
            default:
                throw Self.translate(error)
            }
        } catch {
            throw Self.translate(error)
        }
    }

    // MARK: - Mapping

    /// Maps a public `RequestResponseDTO` (list/detail/create/claim/fulfill's
    /// embedded `request`) to the canonical domain model. Never fabricates
    /// requester-private fields (`pickupName`, `email`, `phoneNumber`) — the
    /// public wire shape never carries them, so they are left `nil` rather
    /// than defaulted to placeholders.
    ///
    /// An unrecognized wire status value throws (via `RequestStatusWire`'s
    /// `Decodable` conformance failing at decode time) rather than silently
    /// mapping to an incorrect lifecycle state.
    private static func mapPublicRequest(_ dto: RequestResponseDTO) throws -> FoodRequest {
        let hasStructuredWindow = dto.windowStart != nil || dto.windowEnd != nil
        return FoodRequest(
            id: dto.id,
            diningSpot: DiningSpot(name: dto.vendor, address: nil),
            foodDescription: dto.food,
            timing: hasStructuredWindow ? .later : .asap,
            preferredPickupTime: dto.windowStart ?? dto.windowEnd,
            createdAt: dto.createdAt,
            expiresAt: dto.expiresAt,
            status: dto.status.domainStatus
        )
    }

    /// Translates a client/transport failure into the product-safe error surface.
    /// Does not guess at unlocked backend error-code strings (see
    /// `RequestServiceError`'s doc comment) — a decoded error envelope is
    /// passed through as `.serverError(code:message:)` verbatim, and only the
    /// HTTP 404 status (unambiguous regardless of code string) maps to a
    /// dedicated case. Exact lifecycle-code mapping (claim expiry, invalid
    /// token, already-claimed/placed, ...) is deferred to the backend
    /// contract implementation day.
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
        case .decoding, .invalidURL:
            return .transport(underlying: clientError)
        case .transport(let underlying):
            return .transport(underlying: underlying)
        }
    }
}

/// Empty JSON body for POSTs (e.g. claim) that carry no request payload.
private struct EmptyBody: Encodable {}
