//
//  AlertSignupFormValidation.swift
//  CommonPlateios
//

import Foundation

/// Locally knowable alert-signup rules. The backend remains authoritative and
/// enforces the identical allowlist; this validator exists only to keep an
/// obviously unusable address beside its field instead of spending a request
/// on it.
enum AlertSignupEmailValidator {
    /// The exact accepted domains. Membership is tested against the whole
    /// normalized domain after the final `@` — never by suffix or substring,
    /// either of which would accept `fake-nyu.edu`, `nyu.edu.example.com`, and
    /// every unlisted subdomain such as `law.nyu.edu`.
    static let allowedDomains: Set<String> = ["nyu.edu", "stern.nyu.edu"]

    static let invalidEmailMessage =
        "Enter an NYU email address ending in @nyu.edu or @stern.nyu.edu."

    /// Trims surrounding whitespace and lowercases, matching what the backend
    /// compares and stores.
    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The exact normalized domain, or `nil` when there is no usable one. A
    /// value with no local part has no address to allow, so it yields `nil`
    /// rather than a bare domain.
    static func domain(of value: String) -> String? {
        let normalized = normalize(value)
        guard let separator = normalized.lastIndex(of: "@"),
              separator != normalized.startIndex else {
            return nil
        }
        let domain = String(normalized[normalized.index(after: separator)...])
        return domain.isEmpty ? nil : domain
    }

    /// Whether this address is worth sending. Shape is checked with the app's
    /// one existing email pattern so signup cannot drift into a second,
    /// slightly different idea of a valid address.
    static func isAllowedNYUEmail(_ value: String) -> Bool {
        let normalized = normalize(value)
        guard FulfillmentFormValidator.isValidEmail(normalized),
              let domain = domain(of: normalized) else {
            return false
        }
        return allowedDomains.contains(domain)
    }
}
