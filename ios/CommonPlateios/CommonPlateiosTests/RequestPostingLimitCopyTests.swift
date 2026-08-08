//
//  RequestPostingLimitCopyTests.swift
//  CommonPlateiosTests
//
//  W3-R1: the two accepted posting-limit sentences on the request-facing
//  surface. The backend rule they describe — three requests per normalized
//  email per NYU/New York calendar day, counted before the write, best-effort
//  rather than transactional, failing closed when the count cannot be read —
//  is unchanged by these cases. What they pin is that the student is told the
//  rule before submitting and told the real reset after being refused.
//

import XCTest
@testable import CommonPlateios

final class RequestPostingLimitCopyTests: XCTestCase {

    // MARK: - The accepted sentences

    func testStandingPolicyWordingIsExact() {
        XCTAssertEqual(
            RequestFoodView.postingLimitPolicyNotice,
            "CommonPlate attempts to limit each email to 3 meal requests per day (New York time)."
        )
    }

    func testLimitStateWordingIsExact() {
        XCTAssertEqual(
            RequestFoodView.postingLimitReachedNotice,
            "Daily request limit reached. Try again after midnight Eastern Time."
        )
    }

    /// The refusal the backend actually sends must render as the accepted
    /// limit-state sentence, not as the presentation enum's own description or
    /// the backend's internal message.
    func testBackendLimitRefusalRendersTheAcceptedLimitStateSentence() {
        let mapped = RequestCreatePresentationError.map(
            RequestServiceError.serverError(
                code: "REQUEST_LIMIT_REACHED",
                message: "You have reached the daily limit of 3 meal requests"
            )
        )

        XCTAssertEqual(mapped, .requestLimitReached)
        XCTAssertEqual(mapped.message, RequestFoodView.postingLimitReachedNotice)
    }

    // MARK: - The two are separate, and both are honest

    /// Standing policy and limit state are different jobs. The policy is shown
    /// before anything is typed; the limit state is only reachable after a
    /// refusal. Collapsing them would mean either teaching the rule only to
    /// students who have already broken it, or repeating the reset time on a
    /// form nobody has submitted.
    func testThePolicyAndTheLimitStateAreDistinctSentences() {
        XCTAssertNotEqual(
            RequestFoodView.postingLimitPolicyNotice,
            RequestFoodView.postingLimitReachedNotice
        )
    }

    /// Enforcement is a best-effort count taken before the write, not a
    /// transactional quota, so the standing sentence hedges — and must keep
    /// hedging, because a promise the runtime does not make is the kind of copy
    /// that quietly becomes false under concurrency.
    func testTheStandingPolicyDoesNotPromiseGuaranteedEnforcement() {
        let policy = RequestFoodView.postingLimitPolicyNotice

        XCTAssertTrue(policy.contains("attempts to limit"))
        XCTAssertTrue(policy.contains("3 meal requests per day"))
        // The count resets on the campus calendar day, not the device's.
        XCTAssertTrue(policy.contains("(New York time)"))
    }

    /// "Tomorrow" was ambiguous for a student posting at 11 PM Pacific, whose
    /// allowance had already reset. The reset is a New York midnight, and the
    /// limit-state sentence now says so.
    func testTheLimitStateNamesTheRealResetRatherThanTomorrow() {
        let limitState = RequestFoodView.postingLimitReachedNotice

        XCTAssertTrue(limitState.contains("after midnight Eastern Time"))
        XCTAssertFalse(limitState.lowercased().contains("tomorrow"))
    }

    // MARK: - No API vocabulary reaches a student

    /// A meal-request allowance is a product rule. Describing it in API terms
    /// tells a student nothing they can act on and misnames what happened — the
    /// short per-IP throttle is a different refusal with different copy.
    func testNoPostingLimitCopyUsesAPIVocabulary() {
        let sentences = [
            RequestFoodView.postingLimitPolicyNotice,
            RequestFoodView.postingLimitReachedNotice,
            RequestCreatePresentationError.requestLimitReached.message,
            RequestCreatePresentationError.rateLimited.message,
        ]

        for sentence in sentences {
            let lowercased = sentence.lowercased()
            for phrase in ["api limit", "rate limit", "quota", "429", "endpoint"] {
                XCTAssertFalse(
                    lowercased.contains(phrase),
                    "\(sentence) uses the API term \"\(phrase)\""
                )
            }
        }
    }

    /// The daily allowance and the per-IP throttle are separate refusals with
    /// separate corrections — wait a minute, versus wait until midnight — so
    /// they must not share a sentence.
    func testTheDailyLimitAndThePerIPThrottleStaySeparate() {
        XCTAssertNotEqual(
            RequestCreatePresentationError.requestLimitReached.message,
            RequestCreatePresentationError.rateLimited.message
        )
    }

    // MARK: - The policy is actually on screen

    /// A standing sentence that exists only as a constant is not a standing
    /// sentence. The form renders it unconditionally, beside the submit action
    /// it constrains, with its own identifier — the same arrangement the email
    /// eligibility rule uses, so a refusal never replaces the rule it broke.
    func testTheStandingPolicyIsRenderedUnconditionallyOnTheForm() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Text(Self.postingLimitPolicyNotice)"))
        XCTAssertTrue(
            source.contains(#".accessibilityIdentifier("request-posting-limit-policy")"#)
        )
    }

    /// Superseded wording, in one place so it cannot quietly return.
    func testSupersededPostingLimitWordingIsGone() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("three meal requests a day"))
        XCTAssertFalse(source.contains("Please try again tomorrow."))
    }

    // MARK: - Helpers

    /// Walks up from this file to the repository root, so the source-text
    /// assertions above read the real tracked file rather than a copy.
    private func repositoryFile(_ relativePath: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
        let url = root.appendingPathComponent(relativePath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "expected \(relativePath) at \(url.path)"
        )
        return url
    }
}
