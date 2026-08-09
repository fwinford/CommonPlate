//
//  ParticipantIdentityStorage.swift
//  CommonPlateios
//
// Installation-local memory of verified participant authority (W3-I1).
import Foundation
import Security

/// The complete identity the store consumes. The bearer authority exists in
/// this value only at the storage/store boundary and is never published.
struct ParticipantIdentityRecord: Codable, Equatable {
    let principal: String
    let authority: String
    let verifiedAt: Date
}

/// Canonical text shape of the backend's V1 authority credential. This is only
/// local shape validation: it does not and cannot authenticate the signature.
/// Participant existence, version, and signature validity remain backend truth.
enum ParticipantAuthorityShape {
    static func isCanonical(_ candidate: String) -> Bool {
        let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }

        let participantID = String(parts[0])
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        guard participantID.count == 24,
              participantID.unicodeScalars.allSatisfy(lowercaseHex.contains) else {
            return false
        }

        let versionText = String(parts[1])
        let asciiDigits = CharacterSet(charactersIn: "0123456789")
        guard !versionText.isEmpty,
              versionText.first != "0",
              versionText.unicodeScalars.allSatisfy(asciiDigits.contains),
              let version = Int(versionText),
              (1...1_000_000).contains(version),
              String(version) == versionText else {
            return false
        }

        let signature = String(parts[2])
        let base64URLCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )
        // A SHA-256 digest is 32 bytes. Its unpadded base64url spelling is 43
        // characters, and the final character contains four data bits plus two
        // unused zero bits. Restricting that final character rejects alternate
        // non-canonical spellings of the same bytes without authenticating the
        // signature itself.
        let canonicalFinalCharacters = CharacterSet(charactersIn: "AEIMQUYcgkosw048")
        guard signature.count == 43,
              signature.unicodeScalars.allSatisfy(base64URLCharacters.contains),
              let finalScalar = signature.unicodeScalars.last else {
            return false
        }
        return canonicalFinalCharacters.contains(finalScalar)
    }
}

protocol ParticipantIdentityStorage {
    func loadValidIdentity() -> ParticipantIdentityRecord?
    @discardableResult func save(_ record: ParticipantIdentityRecord) -> Bool
    func clear()
}

/// The Keychain half: the normalized principal, a random installation binding,
/// and the raw bearer.
/// Keeping the binding beside the credential prevents a surviving Keychain
/// item from being consumed by a later installation's new UserDefaults marker.
/// Keeping the principal here also prevents an editable UserDefaults marker
/// from relabeling valid bearer authority as a different participant.
struct StoredParticipantAuthority: Codable, Equatable {
    let principal: String
    let installationBinding: String
    let authority: String
}

protocol ParticipantAuthorityStorage {
    func load() -> StoredParticipantAuthority?
    @discardableResult func save(_ record: StoredParticipantAuthority) -> Bool
    func clear()
}

/// Raw authority storage. `AfterFirstUnlockThisDeviceOnly` keeps ordinary
/// launches usable while excluding backup/restore and device migration.
struct KeychainParticipantAuthorityStorage: ParticipantAuthorityStorage {
    private static let service = "org.commonplatenyu.participant"
    private static let account = "verified-participant-authority-v1"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    func load() -> StoredParticipantAuthority? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let record = try? JSONDecoder().decode(StoredParticipantAuthority.self, from: data) else {
            return nil
        }
        return record
    }

    @discardableResult
    func save(_ record: StoredParticipantAuthority) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var insertion = baseQuery
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// Non-secret installation marker. UserDefaults is intentionally the other
/// half: it survives ordinary launches but is removed by uninstall. Restoration
/// requires this marker and the ThisDeviceOnly Keychain record to both exist and
/// carry the same random binding.
private struct ParticipantInstallationMarker: Codable, Equatable {
    let principal: String
    let installationBinding: String
    let verifiedAt: Date
}

struct UserDefaultsParticipantIdentityStorage: ParticipantIdentityStorage {
    static let key = "com.commonplate.participant.identity-binding"

    private let defaults: UserDefaults
    private let authorityStorage: ParticipantAuthorityStorage

    init(
        defaults: UserDefaults,
        authorityStorage: ParticipantAuthorityStorage = KeychainParticipantAuthorityStorage()
    ) {
        self.defaults = defaults
        self.authorityStorage = authorityStorage
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

    func loadValidIdentity() -> ParticipantIdentityRecord? {
        guard defaults.object(forKey: Self.key) != nil else {
            // Expected after uninstall: a ThisDeviceOnly Keychain item may
            // survive locally, but without this installation's marker it is an
            // orphan and can never become authority for the new install.
            authorityStorage.clear()
            return nil
        }

        guard let markerData = defaults.data(forKey: Self.key),
              let marker = try? Self.decoder.decode(
                ParticipantInstallationMarker.self,
                from: markerData
              ),
              UUID(uuidString: marker.installationBinding)?.uuidString
                == marker.installationBinding,
              NYUEmailPolicy.normalize(marker.principal) == marker.principal,
              NYUEmailPolicy.isAllowed(marker.principal),
              let secured = authorityStorage.load(),
              secured.installationBinding == marker.installationBinding,
              secured.principal == marker.principal,
              ParticipantAuthorityShape.isCanonical(secured.authority) else {
            clear()
            return nil
        }

        return ParticipantIdentityRecord(
            principal: NYUEmailPolicy.normalize(marker.principal),
            authority: secured.authority,
            verifiedAt: marker.verifiedAt
        )
    }

    @discardableResult
    func save(_ record: ParticipantIdentityRecord) -> Bool {
        let principal = NYUEmailPolicy.normalize(record.principal)
        guard NYUEmailPolicy.isAllowed(principal),
              ParticipantAuthorityShape.isCanonical(record.authority) else {
            clear()
            return false
        }

        let binding = UUID().uuidString
        let secured = StoredParticipantAuthority(
            principal: principal,
            installationBinding: binding,
            authority: record.authority
        )
        guard authorityStorage.save(secured) else {
            clear()
            return false
        }

        let marker = ParticipantInstallationMarker(
            principal: principal,
            installationBinding: binding,
            verifiedAt: record.verifiedAt
        )
        guard let markerData = try? Self.encoder.encode(marker) else {
            clear()
            return false
        }
        defaults.set(markerData, forKey: Self.key)
        return true
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
        authorityStorage.clear()
    }
}
