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

/// Wire-level timing value accepted by `POST /api/request`. `Codable` (not
/// just `Encodable`) so it can round-trip through the W3-D1 durable
/// pending-operation record (`PendingRequestOperationStorage.swift`); nothing
/// about outbound encoding changes.
enum RequestTimingWire: String, Codable {
    case asap
    case scheduled
}

// MARK: - Public request

/// W4-R4 menu path. Exactly one of these describes how a request is paid
/// for. An unrecognized value fails decoding rather than being mapped to a
/// guessed path, matching `RequestStatusWire`.
enum RequestMenuPathWire: String, Codable {
    case mealExchange = "meal-exchange"
    case diningDollars = "dining-dollars"

    var domainMenuPath: RequestMenuPath {
        switch self {
        case .mealExchange: return .mealExchange
        case .diningDollars: return .diningDollars
        }
    }

    init(_ menuPath: RequestMenuPath) {
        switch menuPath {
        case .mealExchange: self = .mealExchange
        case .diningDollars: self = .diningDollars
        }
    }
}

/// Public request shape returned by list/detail/create/claim/fulfill.
/// Must never include requester email, claim token/hash, claim expiration, or
/// internal Mongo fields. Pickup name is not merely excluded here — since
/// W4-R4 it does not exist anywhere in the request contract.
struct RequestResponseDTO: Decodable {
    let id: String
    let vendor: String
    /// The backend-derived single-line summary of the structured fields
    /// below. Retained because every already-accepted helper surface renders
    /// it; it is never composed on this side.
    let food: String
    let pickupWindowText: String
    /// V1 meal-swipe requirement (W3-C1), widened to 0-5 by W4-R4 so a
    /// Dining-Dollars-only request can state that it needs none. Every shape
    /// `POST /api/request` accepts, including the legacy web one, has
    /// required an integer since that slice, so the backend always returns
    /// it; decoding fails on a response that omits it rather than this app
    /// fabricating a value.
    let mealSwipes: Int
    /// W4-R4 structured representation. Required for the same reason
    /// `mealSwipes` is: every accepted create shape supplies it, so a
    /// response omitting it is a malformed/pre-R4 stored row rather than a
    /// supported outcome, and this app must not invent a path for it.
    let menuPath: RequestMenuPathWire
    /// One entry per selected swipe on the Meal Exchange path; empty on a
    /// Dining-Dollars-only request.
    let mealItems: [MealItem]
    /// The single structured order-details value on a Dining-Dollars-only
    /// request; `nil` on a Meal Exchange one.
    let orderDetails: String?
    /// The requester's Dining Dollar estimate in exact cents — never a
    /// floating-point amount. `nil` means the requester needed none, which is
    /// deliberately distinct from `0`.
    let estimatedDiningDollarsCents: Int?
    let windowStart: Date?
    let windowEnd: Date?
    let status: RequestStatusWire
    let createdAt: Date
    let expiresAt: Date
    /// W4-H2 participant-scoped ownership projection. Present and `true` only
    /// on a list fetch made with a verified participant credential, on
    /// exactly that participant's own request; absent for every other
    /// request and every other caller, including anonymous browsing —
    /// matching `alreadyParticipated`'s existing affirmative-only shape.
    /// `nil` for every response shape that never carries it (detail, create,
    /// claim, fulfill), which `decodeIfPresent` tolerates.
    let isOwnRequest: Bool?
}

// MARK: - Response wrappers

struct RequestListResponseDTO: Decodable {
    let requests: [RequestResponseDTO]
}

/// Shared shape for single-request responses: detail fetch and create both
/// return `{ request: {...} }`. `alreadyParticipated` (W3-H2 stale detail
/// Reserve truth) is present and `true` only on a detail fetch made with a
/// verified participant credential that already holds a durable
/// one-successful-participation record for this exact request; absent for
/// every other caller, including anonymous browsing and `POST /api/request`'s
/// own reuse of this same wrapper shape, which `decodeIfPresent` tolerates.
struct RequestDetailResponseDTO: Decodable {
    let request: RequestResponseDTO
    let alreadyParticipated: Bool?
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
/// W4-R4 additions:
///
/// There is deliberately no `food` and no `pickupName`. The backend derives
/// the single-line summary from the structured fields below, and pickup name
/// was removed from the V1 request contract entirely; the create schemas are
/// `.strict()`, so sending either would be refused.
///
/// `Codable` rather than only `Encodable` (W4-R4) so the complete submitted
/// payload can be frozen verbatim into the W3-D1 durable recovery record and
/// decoded back for replay. That makes exact-payload identity structural: a
/// field added here is carried through recovery automatically, and no
/// separate mirror type can drift out of sync with the payload it is supposed
/// to reproduce.
struct CreateRequestPayload: Codable, Equatable {
    let vendor: String
    let timing: RequestTimingWire
    let windowStart: Date?
    /// W4-R4 menu path. Requester-owned truth: Screenshot Assistance's
    /// deterministic proposal (W4-R4.1) only ever switches the form's selector,
    /// never this payload, and the requester can change it first.
    let menuPath: RequestMenuPathWire
    /// V1 meal-swipe requirement (W3-C1), widened to 0-5 by W4-R4: an exact
    /// integer chosen from `RequestFoodView`'s bounded control, 1 through 5
    /// on the Meal Exchange path and exactly 0 on the Dining-Dollars-only
    /// one. Always sent — the backend's canonical iOS schemas require it — so
    /// this app can never construct a value outside that bounded set.
    let mealSwipes: Int
    /// Exactly one entry per selected swipe, in the requester's own order.
    /// A meal field hidden by lowering the swipe count is excluded here by
    /// construction (`RequestFoodView.makePayload`), never sent and then
    /// filtered server-side.
    let mealItems: [MealItem]
    /// Required on the Dining-Dollars-only path, absent on Meal Exchange.
    let orderDetails: String?
    /// Exact cents, never a `Double`: optional on Meal Exchange (absent means
    /// the requester needs none, never a fabricated `$0.00`) and required on
    /// the Dining-Dollars-only path.
    let estimatedDiningDollarsCents: Int?
    /// Store-owned installation identity, filled in by
    /// `RequestStore.createRequest` immediately before sending. Deliberately
    /// excluded from the durable recovery record (see
    /// `PendingRequestOperationRecord`), which is why it is `var` and
    /// defaulted rather than part of the frozen request content.
    var installationCredential: String? = nil
}

// MARK: - Claim

/// Claimant-private half of a successful `POST /api/request/:id/claim`.
/// Deliberately a separate type from `RequestResponseDTO`: these fields exist
/// only in the winning claimant's response and must never be added to the
/// public request DTO, the list DTO, or `FoodRequest`.
///
/// W4-R4 removed `pickupName` from the V1 request contract, so what remains
/// here is the claim authorization itself.
struct ClaimDetailsDTO: Decodable {
    let claimToken: String
    let claimExpiresAt: Date
}

/// Response for `POST /api/request/:id/claim`:
/// `{ request: {...}, claim: { claimToken, claimExpiresAt } }`.
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

// MARK: - Reservation release/continuation (W3-H1)

/// Response for `POST /api/request/:id/claim/release` → `{ released: true }`.
/// Nothing else is returned: the caller already holds the public request
/// state and clears its own claimant-private state locally on success.
struct ReleaseResponseDTO: Decodable {
    let released: Bool
}

/// The claimant-private half of `GET /api/participant/active-reservation`.
/// Deliberately carries no claim token: the raw token is never persisted, so
/// continuation cannot recover it — only participant authority, which
/// `extendClaim`/`releaseClaim` accept as an additive authorization path.
struct ActiveReservationDetailsDTO: Decodable {
    let request: RequestResponseDTO
    let claimExpiresAt: Date
    let claimExtendedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case request
        case claimExpiresAt
        case claimExtendedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let request = try container.decode(RequestResponseDTO.self, forKey: .request)
        guard request.status == .claimed else {
            throw DecodingError.dataCorruptedError(
                forKey: .request,
                in: container,
                debugDescription: "A non-null active reservation must embed a claimed request"
            )
        }

        self.request = request
        claimExpiresAt = try container.decode(Date.self, forKey: .claimExpiresAt)
        claimExtendedAt = try container.decodeIfPresent(Date.self, forKey: .claimExtendedAt)
    }
}

/// The claimant-private half of a W3-H2 fulfillment re-entry read: a request
/// this participant most recently placed, still existing within its
/// retention horizon. `notification` is `nil` when the outcome never settled
/// (mirrors `notificationStatus == nil` in `RequestStore.applyConfirmedFulfillment`)
/// — never guessed as sent or failed.
struct PlacedReservationDetailsDTO: Decodable {
    let request: RequestResponseDTO
    let notification: NotificationStatusDTO?

    private enum CodingKeys: String, CodingKey {
        case request
        case notification
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let request = try container.decode(RequestResponseDTO.self, forKey: .request)
        guard request.status == .placed else {
            throw DecodingError.dataCorruptedError(
                forKey: .request,
                in: container,
                debugDescription: "A placement re-entry read must embed a placed request"
            )
        }

        self.request = request
        notification = try container.decodeIfPresent(NotificationStatusDTO.self, forKey: .notification)
    }
}

/// `{ reservation: null, placement: null }` when the verified participant
/// holds neither an active reservation nor a still-existing placement.
/// `placement` is only meaningful when `reservation` is `nil` — a held
/// reservation always takes priority — and is absent from every response
/// this app sent before W3-H2, which `decodeIfPresent` tolerates.
struct ActiveReservationResponseDTO: Decodable {
    let reservation: ActiveReservationDetailsDTO?
    let placement: PlacedReservationDetailsDTO?
}

// MARK: - Request creation eligibility (W4-Q1)

/// The exact two successful values `GET /api/participant/request-eligibility`
/// answers with. An unrecognized value fails decoding rather than being
/// mapped to a guessed state, matching `RequestStatusWire` above — never
/// silently coerced to `eligible`.
enum RequestEligibilityWire: String, Decodable {
    case eligible
    case exhausted
}

struct RequestEligibilityResponseDTO: Decodable {
    let eligibility: RequestEligibilityWire
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

/// Payload for `POST /api/request/:id/fulfill` when authorizing with verified
/// participant authority instead of the raw claim token (W3-H1 continuation).
/// The backend distinguishes this shape from `FulfillRequestPayload` by the
/// absence of the `claimToken` key, exactly as it already does for
/// `ClaimExtensionPayload` versus the empty-body release/extend continuation
/// requests — so this is a distinct type rather than an optional field on the
/// one above.
struct FulfillContinuationRequestPayload: Encodable {
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
