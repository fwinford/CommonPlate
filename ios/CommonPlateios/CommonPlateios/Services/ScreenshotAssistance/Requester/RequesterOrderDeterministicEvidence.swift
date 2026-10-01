//
//  RequesterOrderDeterministicEvidence.swift
//  CommonPlateios
//
// W4-S3 Requester adapter: the on-device port of the accepted deterministic
// Requester Screenshot Assistance rules in `src/screenshotEligibility.ts` and
// `src/screenshotProposalValidation.ts`. Local analysis may not depend on an
// off-device validation call, so eligibility, meal-swipe corroboration,
// vendor grounding, and the current-cart Dining Dollars rule are evaluated
// here, against on-device Vision OCR text only — never against anything a
// provider (local or external) returned. Everything in this file is Requester
// policy (Grubhub cart/history categories, catalog vendors, meal swipes,
// Dining Dollars); the shared runtime knows none of it.
//
// This is a port, not a redesign: the backend rules stay authoritative for the
// external route and `shared/screenshot-conformance-vectors.json` is asserted
// by both suites (`src/screenshotConformanceVectors.test.ts`,
// `ScreenshotConformanceVectorTests.swift`) so neither side can drift silently.
// The helpers below deliberately reproduce JavaScript's text semantics
// (`\s`, `\w`, `\b`, `trim`, case-insensitive matching restricted to ASCII)
// rather than Swift's or ICU's defaults, because a divergence in how a
// boundary or whitespace character is treated would be a divergence in a
// fail-closed rule.
import Foundation

/// JavaScript text semantics the accepted rules were written against.
enum ScreenshotJSText {
    /// The exact code points ECMAScript's `\s` and `String.prototype.trim`
    /// treat as white space or line terminators.
    static let whitespaceScalars: Set<Unicode.Scalar> = {
        var scalars: Set<Unicode.Scalar> = [
            "\u{0009}", "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}", "\u{0020}",
            "\u{00A0}", "\u{1680}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}",
            "\u{3000}", "\u{FEFF}",
        ]
        for value in 0x2000...0x200A {
            scalars.insert(Unicode.Scalar(UInt32(value))!)
        }
        return scalars
    }()

    /// A regular-expression character-class body matching exactly
    /// `whitespaceScalars` (ICU's own `\s` differs, e.g. it includes U+0085).
    static let whitespaceClassBody =
        "\\t\\n\\x{0B}\\f\\r \\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}"

    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        whitespaceScalars.contains(scalar)
    }

    /// `text.replace(/\s+/g, "").length` — a UTF-16 code-unit count.
    static func nonWhitespaceLength(_ text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars where !isWhitespace(scalar) {
            count += scalar.value > 0xFFFF ? 2 : 1
        }
        return count
    }

    /// `text.replace(/\s+/g, " ").trim()`.
    static func collapsingWhitespace(_ text: String) -> String {
        var pieces: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isWhitespace(scalar) {
                if !current.isEmpty {
                    pieces.append(String(current))
                    current = String.UnicodeScalarView()
                }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { pieces.append(String(current)) }
        return pieces.joined(separator: " ")
    }

    /// `text.trim()`.
    static func trimmed(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, isWhitespace(last) { scalars.removeLast() }
        var start = 0
        while start < scalars.count, isWhitespace(scalars[start]) { start += 1 }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[start...])
        return String(view)
    }

    /// `text.toLowerCase().replace(/\s+/g, " ").trim()`.
    static func normalized(_ text: String) -> String {
        collapsingWhitespace(text.lowercased())
    }

    /// Lowercases only `A`–`Z`. A JavaScript `i`-flag pattern made of ASCII
    /// letters never matches a non-ASCII character (`ſ`, the Kelvin sign), but
    /// ICU's case-insensitive matching does — so case-insensitive rules here
    /// fold ASCII only and then match a lowercase pattern.
    static func asciiLowercased(_ text: String) -> String {
        var view = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x41 && scalar.value <= 0x5A {
                view.append(Unicode.Scalar(scalar.value + 0x20)!)
            } else {
                view.append(scalar)
            }
        }
        return String(view)
    }

    /// Exact UTF-16 code-unit substring test. Swift's `String.contains` and
    /// `==` apply canonical equivalence, JavaScript's `includes`/`===` do not.
    static func literalContains(_ haystack: String, _ needle: String) -> Bool {
        (haystack as NSString).range(of: needle, options: .literal).location != NSNotFound
    }

    static func literalEquals(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    static func makeRegex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            preconditionFailure("Invalid screenshot rule pattern \(pattern): \(error)")
        }
    }

    static func hasMatch(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func matches(_ regex: NSRegularExpression, in text: String) -> [[String?]] {
        let nsText = text as NSString
        return regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : nsText.substring(with: range)
            }
        }
    }
}

struct RequesterOrderEligibilityResult: Equatable {
    enum Category: String, Equatable {
        case cart
        case historical
    }

    let eligible: Bool
    let category: Category?
}

enum RequesterOrderDeterministicEvidence {
    private static let legibilityMinimumNonWhitespaceCharacters = 20

    // ASCII-only stand-ins for JavaScript's `\w`/`\b`/`\d` (see
    // `ScreenshotJSText`).
    private static let wordClass = "A-Za-z0-9_"
    private static let ws = "[\(ScreenshotJSText.whitespaceClassBody)]"

    /// `/(^|\s)(\d{1,2})\s?x?\s+[a-z][a-z'&()-]{2,}(\s+[a-z][a-z'&()-]+){0,6}/`
    /// evaluated on text whose white space is already collapsed to single
    /// spaces, so `\s` is a literal space here.
    private static let quantifiedItem = ScreenshotJSText.makeRegex(
        "(^| )([0-9]{1,2}) ?x? +[a-z][a-z'\\&()\\-]{2,}( +[a-z][a-z'\\&()\\-]+){0,6}"
    )
    /// `/\bview order\b(?! details)/`
    private static let viewOrder = ScreenshotJSText.makeRegex(
        "(?<![\(wordClass)])view order(?![\(wordClass)])(?! details)"
    )
    /// `/\border information\b/`
    private static let orderInformation = ScreenshotJSText.makeRegex(
        "(?<![\(wordClass)])order information(?![\(wordClass)])"
    )
    /// `/(?<![\w.])(\d{1,2})\s?M\b/g`
    private static let explicitMealSwipeTotal = ScreenshotJSText.makeRegex(
        "(?<![\(wordClass).])([0-9]{1,2})\(ws)?M(?![\(wordClass)])"
    )
    /// `/\b(?:your\s+(?:pickup\s+)?order|cart|checkout|continue\s+to\s+checkout)\b/i`
    /// on ASCII-lowercased text.
    private static let currentCartMarkers = ScreenshotJSText.makeRegex(
        "(?<![a-z0-9_])(?:your\(ws)+(?:pickup\(ws)+)?order|cart|checkout|continue\(ws)+to\(ws)+checkout)(?![a-z0-9_])"
    )
    /// `/\b(?:past\s+order|order\s+history|receipt|delivered|completed)\b/i`
    /// on ASCII-lowercased text.
    private static let pastOrderMarkers = ScreenshotJSText.makeRegex(
        "(?<![a-z0-9_])(?:past\(ws)+order|order\(ws)+history|receipt|delivered|completed)(?![a-z0-9_])"
    )
    /// `/(?<![\w.])(\d{1,2})\s?M\s*\+\s*\$(\d{1,2})(?:\.(\d{2}))?(?!\d)/g`
    private static let cartDollar = ScreenshotJSText.makeRegex(
        "(?<![\(wordClass).])([0-9]{1,2})\(ws)?M\(ws)*\\+\(ws)*\\$([0-9]{1,2})(?:\\.([0-9]{2}))?(?![0-9])"
    )

    /// Cart/bag chrome phrases (C1). Checkout-context phrasing is excluded
    /// even though it contains the cart phrase as a substring.
    private static let cartChromePhrases = [
        "your pickup order",
        "your delivery order",
        "order instructions",
        "cilantro on the side",
        "continue to checkout",
        "add more items",
        "empty bag",
        "items subtotal",
    ]

    private static func cartChromeCount(_ normalized: String) -> Int {
        var count = 0
        for phrase in cartChromePhrases {
            guard ScreenshotJSText.literalContains(normalized, phrase) else { continue }
            if phrase == "your pickup order",
               ScreenshotJSText.literalContains(normalized, "review your pickup order")
                || ScreenshotJSText.literalContains(normalized, "place your pickup order") {
                continue
            }
            if phrase == "your delivery order",
               ScreenshotJSText.literalContains(normalized, "review your delivery order")
                || ScreenshotJSText.literalContains(normalized, "place your delivery order") {
                continue
            }
            count += 1
        }
        return count
    }

    /// The accepted V1-C1-or-H5 rule, evaluated against literal on-device
    /// evidence text only. Eligibility is accident prevention, not
    /// authenticity verification (`docs/system-contract.md` section 12).
    static func evaluateEligibility(_ evidenceText: String) -> RequesterOrderEligibilityResult {
        guard ScreenshotJSText.nonWhitespaceLength(evidenceText) >= legibilityMinimumNonWhitespaceCharacters else {
            return RequesterOrderEligibilityResult(eligible: false, category: nil)
        }
        let normalized = ScreenshotJSText.normalized(evidenceText)
        if cartChromeCount(normalized) >= 1 {
            return RequesterOrderEligibilityResult(eligible: true, category: .cart)
        }
        let detailedHistoryCore =
            ScreenshotJSText.hasMatch(viewOrder, in: normalized)
            && ScreenshotJSText.hasMatch(orderInformation, in: normalized)
            && ScreenshotJSText.hasMatch(quantifiedItem, in: normalized)
        if detailedHistoryCore {
            return RequesterOrderEligibilityResult(eligible: true, category: .historical)
        }
        return RequesterOrderEligibilityResult(eligible: false, category: nil)
    }

    private static let minimumMealSwipeTotal = 1
    private static let maximumMealSwipeTotal = 5

    /// Explicit meal-swipe count from independent OCR evidence, or `nil` when
    /// the evidence is absent, conflicting, or outside the accepted 1...5
    /// bounds (fail closed).
    static func corroboratedMealSwipeCount(_ evidenceText: String) -> Int? {
        let observed = ScreenshotJSText.matches(explicitMealSwipeTotal, in: evidenceText)
            .compactMap { $0[1].flatMap { Int($0) } }
        guard !observed.isEmpty else { return nil }
        guard !observed.contains(where: { $0 < minimumMealSwipeTotal || $0 > maximumMealSwipeTotal }) else {
            return nil
        }
        let aggregateTotals = Set(observed.filter { $0 > 1 })
        if aggregateTotals.count > 1 { return nil }
        if let only = aggregateTotals.first { return only }
        return observed.count <= maximumMealSwipeTotal ? observed.count : nil
    }

    /// The deterministic, order-level current-cart Dining Dollars estimate:
    /// a literal aggregate `3M + $2.00` expression alongside current-cart
    /// chrome, never alongside past-order language. Derived only from
    /// on-device evidence; it is never provider authority.
    static func currentCartDiningDollarsCents(_ evidenceText: String) -> Int? {
        let folded = ScreenshotJSText.asciiLowercased(evidenceText)
        guard ScreenshotJSText.hasMatch(currentCartMarkers, in: folded),
              !ScreenshotJSText.hasMatch(pastOrderMarkers, in: folded) else {
            return nil
        }
        struct Candidate: Hashable {
            let swipes: Int
            let cents: Int
        }
        let candidates: [Candidate] = ScreenshotJSText.matches(cartDollar, in: evidenceText).compactMap { groups in
            guard let swipes = groups[1].flatMap({ Int($0) }),
                  let dollars = groups[2].flatMap({ Int($0) }) else { return nil }
            let cents = groups.count > 3 ? (groups[3].flatMap { Int($0) } ?? 0) : 0
            return Candidate(swipes: swipes, cents: dollars * 100 + cents)
        }
        guard let first = candidates.first, Set(candidates).count == 1 else { return nil }
        guard first.swipes >= 1, first.swipes <= 5, first.cents > 0, first.cents <= 2_500 else { return nil }
        return first.cents
    }

    // MARK: - Vendor grounding

    private static func matchesVendorText(_ normalized: String, _ vendor: DiningSpot) -> Bool {
        let full = vendor.name.lowercased()
        let base = ScreenshotJSText.trimmed(full.components(separatedBy: " - ").first ?? full)
        return ScreenshotJSText.literalEquals(normalized, full)
            || ScreenshotJSText.literalEquals(normalized, base)
            || ScreenshotJSText.literalContains(normalized, full)
    }

    /// Catalog entries named by `text`. A base label shared by two entries
    /// (the two current Upstein entries) matches both, which is what makes a
    /// bare shared label ambiguous rather than a match.
    static func groundedVendorMatches(_ text: String?, vendors: [DiningSpot]) -> [DiningSpot] {
        guard let text, !text.isEmpty else { return [] }
        let normalized = ScreenshotJSText.normalized(text)
        guard !normalized.isEmpty else { return [] }
        return vendors.filter { matchesVendorText(normalized, $0) }
    }

    /// The one catalog vendor grounded in independent evidence, or `nil`. A
    /// provider's own venue text can only veto a disagreement; it can never
    /// select a vendor by itself.
    static func resolveVendor(
        evidenceText: String,
        visibleVenueText: String?,
        vendors: [DiningSpot]
    ) -> DiningSpot? {
        let groundedMatches = groundedVendorMatches(evidenceText, vendors: vendors)
        let groundedNames = Set(groundedMatches.map(\.name))
        guard groundedNames.count == 1, let grounded = groundedMatches.first else { return nil }

        if let visibleVenueText, !visibleVenueText.isEmpty {
            let providerNames = Set(groundedVendorMatches(visibleVenueText, vendors: vendors).map(\.name))
            if !providerNames.isEmpty, !providerNames.contains(grounded.name) {
                return nil
            }
        }
        return grounded
    }
}
