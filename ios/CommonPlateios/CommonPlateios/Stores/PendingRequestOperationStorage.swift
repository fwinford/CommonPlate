//
//  PendingRequestOperationStorage.swift
//  CommonPlateios
//
// Durable installation-local memory of at most one unresolved W3-D1
// request-create operation. This is an identity tombstone, not request
// history or a generalized offline queue: it exists only so the exact
// logical create begun before app/process termination can be resumed and
// reconciled against authoritative backend truth after relaunch, and it is
// retired the moment that operation authoritatively resolves.
import Foundation

/// The exact durable state W3-D1 needs to resume one unresolved create after
/// app/process termination — nothing more.
///
/// `participantIdentifier` binds this record to the requester participant
/// without persisting a credential: it is the participant-identity segment of
/// the verified authority credential (the leading component
/// `ParticipantAuthorityShape` also parses), never the bearer authority
/// itself. It authenticates nothing on its own and cannot be replayed as a
/// credential; it only lets a restored record be compared for exact
/// participant equality at reconciliation time.
///
/// The remaining fields are exactly the create fields the backend's canonical
/// schemas accept (`createRequestRoute.ts`) — enough to resubmit the identical
/// payload under the same `operationId` if the original transmission never
/// reached the backend at all. No unrelated request history, no raw
/// credential, no claim token.
struct PendingRequestOperationRecord: Codable, Equatable {
    let operationId: String
    let participantIdentifier: String
    let vendor: String
    let food: String
    let pickupName: String
    let timing: RequestTimingWire
    let windowStart: Date?
    let mealSwipes: Int
}

protocol PendingRequestOperationStorage: AnyObject {
    func load() -> PendingRequestOperationRecord?
    @discardableResult func save(_ record: PendingRequestOperationRecord) -> Bool
    func clear()
}

/// The app's real durable storage. UserDefaults, matching the existing
/// non-secret-marker pattern (`UserDefaultsParticipantIdentityStorage`,
/// `UserDefaultsPushInstallationStorage`): nothing persisted here is a
/// credential — `participantIdentifier` is a non-secret identity segment, and
/// every other field is ordinary request content the requester themselves
/// entered and is about to send.
final class UserDefaultsPendingRequestOperationStorage: PendingRequestOperationStorage {
    static let key = "com.commonplate.request.pending-create-operation"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func load() -> PendingRequestOperationRecord? {
        guard let data = defaults.data(forKey: Self.key),
              let record = try? Self.decoder.decode(PendingRequestOperationRecord.self, from: data) else {
            return nil
        }
        return record
    }

    @discardableResult
    func save(_ record: PendingRequestOperationRecord) -> Bool {
        guard let data = try? Self.encoder.encode(record) else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// Process-lifetime default for `RequestStore.init`, matching the existing
/// `reservationWarningScheduler` precedent of a safe no-op default rather than
/// requiring every existing call site (including every pre-D1 test) to supply
/// one. Real durability across process termination requires the caller —
/// `ContentView`, for the real app — to pass
/// `UserDefaultsPendingRequestOperationStorage` explicitly.
final class InMemoryPendingRequestOperationStorage: PendingRequestOperationStorage {
    private var record: PendingRequestOperationRecord?

    func load() -> PendingRequestOperationRecord? {
        record
    }

    @discardableResult
    func save(_ record: PendingRequestOperationRecord) -> Bool {
        self.record = record
        return true
    }

    func clear() {
        record = nil
    }
}
