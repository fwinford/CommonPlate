//
//  RequestDTOs.swift
//  CommonPlateios
//
//  Created by faith on 7/13/26.
//
// Wire-level types for the request domain, per docs/week-2-integration-spec.md.
// These decode/encode exactly what the backend contracts define. DTO-to-domain
// mapping (RequestResponseDTO -> FoodRequest) belongs to RequestService, not here.
import Foundation

// MARK: - Wire status

/// Backend-persisted status vocabulary. See `domainStatus` for the iOS lifecycle mapping.
enum RequestStatusWire: String, Decodable {
    case requested
    case claimed
    case placed

    var domainStatus: RequestStatus {
        switch self {
        case .requested: return .open
        case .claimed: return .claimed
        case .placed: return .placed
        }
    }
}

/// Wire-level timing value accepted by `POST /api/request`.
enum RequestTimingWire: String, Encodable {
    case asap
    case scheduled
}

// MARK: - Public request

/// Public request shape returned by list/detail/create/claim/fulfill.
/// Must never include requester email, pickup name, claim token/hash,
/// claim expiration, or internal Mongo fields.
struct RequestResponseDTO: Decodable {
    let id: String
    let vendor: String
    let food: String
    let pickupWindowText: String
    let windowStart: Date?
    let windowEnd: Date?
    let status: RequestStatusWire
    let createdAt: Date
    let expiresAt: Date
}

// MARK: - Response wrappers

struct RequestListResponseDTO: Decodable {
    let requests: [RequestResponseDTO]
}

/// Shared shape for single-request responses: detail fetch and create both
/// return `{ request: {...} }`.
struct RequestDetailResponseDTO: Decodable {
    let request: RequestResponseDTO
}

// MARK: - Create

/// Payload for `POST /api/request`. Must never include backend-owned
/// lifecycle fields (id, status, createdAt, expiresAt, claim/fulfillment fields).
struct CreateRequestPayload: Encodable {
    let vendor: String
    let food: String
    let pickupName: String
    let email: String
    let timing: RequestTimingWire
    let windowStart: Date?
    let windowEnd: Date?
}

// MARK: - Claim

/// Response for `POST /api/request/:id/claim`. Only a successful claim response
/// may reveal pickup name, the raw claim token, and claim expiration.
struct ClaimResponseDTO: Decodable {
    let request: RequestResponseDTO
    let pickupName: String
    let claimToken: String
    let claimExpiresAt: Date
}

// MARK: - Fulfillment

/// Fields currently accepted by `POST /api/request/:id/fulfill` (app.ts: `orderNumber`,
/// `eta`, `note`, `fulfillerEmail`, `contactMessage`). `note` and `contactMessage` are
/// kept distinct and both optional: whether they remain separate or are consolidated
/// is an open Day 5 question, not decided here. `eta` matches the currently accepted
/// wire key; do not rename to `etaText` (that is a persisted `Request` field, not the
/// request-body key) unless the endpoint's accepted contract changes.
struct FulfillmentPayload: Encodable {
    let fulfillerEmail: String
    let orderNumber: String
    let eta: String
    let note: String?
    let contactMessage: String?
}

/// Payload for `POST /api/request/:id/fulfill`.
struct FulfillRequestPayload: Encodable {
    let claimToken: String
    let fulfillment: FulfillmentPayload
}

enum NotificationDeliveryStatus: String, Decodable {
    case sent
    case pendingRetry = "pending_retry"
    case failed
}

struct NotificationStatusDTO: Decodable {
    let status: NotificationDeliveryStatus
}

/// Response for `POST /api/request/:id/fulfill`. Core placement success
/// (`request`) is independent of notification success (`notification`).
struct FulfillResponseDTO: Decodable {
    let request: RequestResponseDTO
    let notification: NotificationStatusDTO
}

// MARK: - Errors

struct APIErrorDetail: Decodable {
    let code: String
    let message: String
}

/// Standard error envelope: `{ "error": { "code", "message" } }`.
struct APIErrorResponse: Decodable {
    let error: APIErrorDetail
}
