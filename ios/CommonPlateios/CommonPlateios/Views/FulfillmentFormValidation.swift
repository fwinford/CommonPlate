//
//  FulfillmentFormValidation.swift
//  CommonPlateios
//

import Foundation

/// The reservation form's locally-checkable fields, listed in the order they
/// appear on screen — which is also the order the first invalid one is focused
/// in after a rejected submit.
///
/// Ready time is deliberately absent: it is a picker over a fixed set of
/// choices, so it cannot hold an invalid value and has nothing to say about one.
enum FulfillmentFormField: Hashable, CaseIterable {
    case fulfillerEmail
    case orderNumber
}

/// One local validation failure, carrying the field it belongs to so the message
/// can be rendered against that field instead of arriving as a form-level
/// failure the helper has to decode.
struct FulfillmentFieldError: Equatable, Identifiable {
    let field: FulfillmentFormField
    let message: String

    var id: FulfillmentFormField { field }
}

/// Client-side mirrors of the backend's own accepted rules for
/// `POST /api/request/:id/fulfill`. Nothing here is a new rule: `fulfillerEmail`
/// is the trimmed address the payload schema already requires, and
/// `orderNumber` uses the backend's exact `^[0-9]{1,50}$` pattern.
///
/// Mirroring rather than inventing is the whole point. The backend answers a bad
/// payload with one opaque `INVALID_FULFILLMENT_PAYLOAD` and `fields: null`, so
/// nothing in the response can say *which* field was wrong. Checking the same
/// rules here is what lets the failure be named on the field — and, more
/// importantly, lets it be caught before a helper who has already paid for a
/// real Grubhub order sees anything that reads like a system failure.
enum FulfillmentFormValidator {
    static let emptyEmailMessage = "Enter your email address."
    static let invalidEmailMessage =
        "Enter a valid email address, like name@example.com."
    static let emptyOrderNumberMessage = "Enter the Grubhub order number."
    static let nonNumericOrderNumberMessage = "Use numbers only."
    static let longOrderNumberMessage = "Use 50 digits or fewer."

    /// Backend: `orderNumber: z.string().trim().min(1).regex(/^[0-9]{1,50}$/)`.
    /// Split into its two halves here so each failure can be named separately —
    /// the backend answers both with one opaque code, but "too long" and "not a
    /// number" are different mistakes and need different corrections.
    private static let orderNumberDigitsPattern = "^[0-9]+$"
    static let orderNumberMaximumLength = 50

    /// Structural rather than clever: one `@`, something before it, and a dotted
    /// domain after it, with no whitespace anywhere. It exists to catch the
    /// mistakes a helper actually makes on a phone keyboard — a missing `@`, a
    /// missing domain, a stray space — not to out-guess the backend, which stays
    /// authoritative for anything this accepts.
    private static let emailPattern = "^[^\\s@]+@[^\\s@]+\\.[^\\s@]{2,}$"

    /// Every local failure, in field order. Empty means the submit may proceed
    /// as far as the network; the store's own gates still decide from there.
    static func validate(
        fulfillerEmail: String,
        orderNumber: String
    ) -> [FulfillmentFieldError] {
        var errors: [FulfillmentFieldError] = []
        if let message = emailError(fulfillerEmail) {
            errors.append(
                FulfillmentFieldError(field: .fulfillerEmail, message: message)
            )
        }
        if let message = orderNumberError(orderNumber) {
            errors.append(
                FulfillmentFieldError(field: .orderNumber, message: message)
            )
        }
        return errors
    }

    static func emailError(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return emptyEmailMessage
        }
        return matches(trimmed, emailPattern) ? nil : invalidEmailMessage
    }

    /// Precedence is empty, then too long, then non-numeric. A value that breaks
    /// both the length and the digits rule is reported as too long: shortening
    /// it is the correction that has to happen first, and a helper told "use
    /// numbers only" about a 60-character entry would fix the characters and be
    /// refused again.
    static func orderNumberError(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return emptyOrderNumberMessage
        }
        if trimmed.count > orderNumberMaximumLength {
            return longOrderNumberMessage
        }
        return matches(trimmed, orderNumberDigitsPattern) ? nil : nonNumericOrderNumberMessage
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
