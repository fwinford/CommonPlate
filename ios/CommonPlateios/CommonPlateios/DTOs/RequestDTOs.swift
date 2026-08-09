//
//  RequestDTOs.swift
//  CommonPlateios
//
//  Created by faith on 7/13/26.
//
// Wire-level types for the request domain, per docs/system-contract.md.
// These decode/encode exactly what the backend contracts define. DTO-to-domain
// mapping (RequestResponseDTO -> FoodRequest) belongs to RequestService, not here.
import Foundation

// MARK: - Wire status

/// Persisted lifecycle vocabulary. Unknown values fail decoding rather than
/// being mapped to a guessed state.
enum RequestStatusWire: String, Decodable {
    case open
    case claimed
    case placed

    var domainStatus: RequestStatus {
        switch self {
        case .open: return .open
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

/// `GET /api/public-actions` → `{ "paused": boolean }`. Read-only and ungated.
/// It carries the pause decision and no configuration detail beyond it.
struct PublicActionsStateDTO: Decodable {
    let paused: Bool
}

// MARK: - Create

/// Payload for `POST /api/request`. Must never include backend-owned
/// lifecycle fields (id, status, createdAt, expiresAt, claim/fulfillment fields).
///
/// `installationCredential` (Week 3 Day 6 Slice 6E) is the app's existing,
/// stable installation credential — the same value `InstallationPushService`
/// sends — carried so the backend can resolve/establish the originating
/// installation for a later best-effort requester-fulfillment push. It is
/// notification-routing identity only, never push permission or push state,
/// and `RequestFoodView.makePayload` never sets it: `RequestStore.createRequest`
/// fills it in from the store's own installation-credential provider
/// immediately before sending, so this field defaults to absent for every
/// existing caller and test that constructs a payload directly.
/// `windowStart` is the only timing value this app sends, and only on a
/// scheduled request: it is the instant helpers begin seeing the request, and
/// the backend derives the expiration from it. There is deliberately no
/// `windowEnd` — the create shape is strict and would refuse one, because an
/// end the requester did not choose is not theirs to state.
///
/// There is also deliberately no `email` (W3-I1). The requester is the verified
/// participant behind the credential `RequestStore` attaches, the backend binds
/// the request to that principal, and an address here could only either repeat
/// it or contradict it.
struct CreateRequestPayload: Encodable {
    let vendor: String
    let food: String
    let pickupName: String
    let timing: RequestTimingWire
    let windowStart: Date?
    var installationCredential: String? = nil
}

// MARK: - Claim

/// Claimant-private half of a successful `POST /api/request/:id/claim`.
/// Deliberately a separate type from `RequestResponseDTO`: these three fields
/// exist only in the winning claimant's response and must never be added to the
/// public request DTO, the list DTO, or `FoodRequest`.
struct ClaimDetailsDTO: Decodable {
    let pickupName: String
    let claimToken: String
    let claimExpiresAt: Date
}

/// Response for `POST /api/request/:id/claim`:
/// `{ request: {...}, claim: { pickupName, claimToken, claimExpiresAt } }`.
/// The public projection and the private claim object stay separate all the way
/// through the DTO layer.
struct ClaimResponseDTO: Decodable {
    let request: RequestResponseDTO
    let claim: ClaimDetailsDTO
}

// MARK: - Claim extension

/// Payload for `POST /api/request/:id/claim/extend`. The backend rejects any
/// body with more than this one key, so no other field may be added here.
struct ClaimExtensionPayload: Encodable {
    let claimToken: String
}

/// Claim state after the one permitted extension. The response deliberately
/// repeats neither the raw token, the pickup name, nor the request.
struct ClaimExtensionDetailsDTO: Decodable {
    let claimExpiresAt: Date
    let claimExtendedAt: Date
}

/// Response for `POST /api/request/:id/claim/extend` → `{ claim: {...} }`.
struct ClaimExtensionResponseDTO: Decodable {
    let claim: ClaimExtensionDetailsDTO
}

// MARK: - Fulfillment

/// Strict nested fields accepted by `POST /api/request/:id/fulfill`.
/// `eta` is the request-body key; `etaText` is backend persistence vocabulary
/// and must not be sent by iOS. `contactMessage` is the only optional field.
///
/// There is deliberately no `fulfillerEmail` (W3-I1): the helper is the
/// verified participant the claim is already bound to, the backend reads that
/// binding, and the strict schema refuses an address here — which is what stops
/// the requester's coordination email from naming anyone else.
struct FulfillmentPayload: Encodable {
    let orderNumber: String
    let eta: String
    let contactMessage: String?
}

/// Payload for `POST /api/request/:id/fulfill`.
struct FulfillRequestPayload: Encodable {
    let claimToken: String
    let fulfillment: FulfillmentPayload
}

enum NotificationDeliveryStatus: String, Decodable {
    case sent
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
