import Foundation
import XCTest
@testable import CommonPlateios

/// Week 3 Day 5 Slice 5B: the exact NYU allowlist applied to food-request
/// creation. Alert signup's own coverage stays in `AlertSignupTests`; this file
/// proves the requester form enforces the same rule, that an ineligible address
/// never reaches the network, and that nothing else about submission moved.
@MainActor
final class RequestEmailAllowlistTests: XCTestCase {
    private let nyuMessage =
        "Enter an NYU email address ending in @nyu.edu or @stern.nyu.edu."

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - The shared policy

    func testAllowlistIsExactlyTheTwoAcceptedDomains() {
        XCTAssertEqual(NYUEmailPolicy.allowedDomains, ["nyu.edu", "stern.nyu.edu"])
    }

    /// The request form and alert signup must not be able to disagree. This
    /// fails if either grows its own allowlist or its own sentence.
    func testRequestFormAndAlertSignupShareOnePolicy() {
        XCTAssertEqual(AlertSignupEmailValidator.allowedDomains, NYUEmailPolicy.allowedDomains)
        XCTAssertEqual(AlertSignupEmailValidator.invalidEmailMessage, NYUEmailPolicy.requiredMessage)
        XCTAssertEqual(RequestFoodFormError.invalidEmail.message, NYUEmailPolicy.requiredMessage)
        XCTAssertEqual(NYUEmailPolicy.requiredMessage, nyuMessage)

        for address in ["taylor@nyu.edu", "taylor@gmail.com", "taylor@law.nyu.edu", "taylor@"] {
            XCTAssertEqual(
                RequestFoodFormValidator.isAllowedRequesterEmail(address),
                AlertSignupEmailValidator.isAllowedNYUEmail(address),
                address
            )
        }
    }

    // MARK: - Field validation

    func testAllowedRequesterAddressesProduceNoEmailError() {
        for address in [
            "taylor@nyu.edu",
            "taylor@stern.nyu.edu",
            "TAYLOR@NYU.EDU",
            "  taylor@nyu.edu  ",
            "\tTaylor@Stern.NYU.EDU\n",
            "taylor+food@nyu.edu",
            "first.last+tag@stern.nyu.edu"
        ] {
            XCTAssertTrue(
                emailErrors(for: address).isEmpty,
                address
            )
        }
    }

    func testRejectedRequesterAddressesCarryTheNYUMessage() {
        for address in [
            // Malformed.
            "taylor@",
            "@nyu.edu",
            "taylor@@nyu.edu",
            "taylor @nyu.edu",
            "taylor@.",
            "nyu.edu",
            // Not allowlisted.
            "taylor@gmail.com",
            "taylor@example.edu",
            // Unlisted NYU subdomains are not implicitly allowed.
            "taylor@law.nyu.edu",
            "taylor@sps.nyu.edu",
            // Lookalikes a suffix or substring check would wrongly accept.
            "taylor@fake-nyu.edu",
            "taylor@nyu.edu.fake",
            "taylor@nyu.edu.example.com",
            "taylor@notnyu.edu",
            "taylor@nyu.education"
        ] {
            let errors = emailErrors(for: address)
            XCTAssertEqual(errors.map(\.error), [.invalidEmail], address)
            XCTAssertEqual(errors.first?.message, nyuMessage, address)
        }
    }

    /// An address that has not been typed yet is not an ineligible address, so
    /// the empty field keeps its own instruction.
    func testEmptyEmailKeepsItsOwnDistinctMessage() {
        for blank in ["", "   ", "\n"] {
            let errors = emailErrors(for: blank)
            XCTAssertEqual(errors.map(\.error), [.missingEmail], blank)
            XCTAssertEqual(errors.first?.message, "Enter your email address.", blank)
            XCTAssertNotEqual(errors.first?.message, nyuMessage, blank)
        }
    }

    // MARK: - Submission

    func testAllowedAddressSubmitsTheNormalizedPayloadOnce() async throws {
        var payloads: [CreateRequestPayload] = []
        let result = try await RequestFoodView.orchestrateSubmission(
            draft: draft(email: "  TAYLOR@Stern.NYU.EDU  "),
            now: try date("2026-07-28T16:00:00.000Z"),
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { payload in
            payloads.append(payload)
        }

        XCTAssertTrue(result.didSubmit)
        XCTAssertEqual(payloads.count, 1)
        // The form trims; the backend lowercases and stores the normalized form.
        XCTAssertEqual(payloads.first?.email, "TAYLOR@Stern.NYU.EDU")
    }

    func testIneligibleAddressBlocksSubmissionAndFocusesTheEmailField() async throws {
        var submissionCount = 0

        for address in ["taylor@gmail.com", "taylor@law.nyu.edu", "taylor@fake-nyu.edu", "taylor@"] {
            let submitted = draft(email: address)
            let result = try await RequestFoodView.orchestrateSubmission(
                draft: submitted,
                now: try date("2026-07-28T16:00:00.000Z"),
                calendar: utcCalendar,
                presentation: RequestFoodValidationPresentation()
            ) { _ in
                submissionCount += 1
            }

            XCTAssertFalse(result.didSubmit, address)
            XCTAssertEqual(result.firstInvalidTextField, .requesterEmail, address)
            XCTAssertEqual(
                result.presentation.visibleError(
                    for: .requesterEmail,
                    from: validationErrors(for: submitted)
                )?.message,
                nyuMessage,
                address
            )
        }

        XCTAssertEqual(submissionCount, 0)
    }

    /// The seam above proves the closure is not called. This proves the whole
    /// production path — store, service, `APIClient`, `URLSession` — issues no
    /// HTTP request at all for a locally refused address.
    func testIneligibleAddressIssuesNoNetworkRequest() async throws {
        let store = makeStore()

        let result = try await RequestFoodView.orchestrateSubmission(
            draft: draft(email: "taylor@gmail.com"),
            now: try date("2026-07-28T16:00:00.000Z"),
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { payload in
            try await store.createRequest(payload)
        }

        XCTAssertFalse(result.didSubmit)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        XCTAssertTrue(store.requests.isEmpty)
        // A refused address is a local correction, not an unreadable outcome:
        // it must never arm the process-lifetime create block.
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
    }

    func testAllowedAddressStillReachesTheNetworkAndCreates() async throws {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 201, data: createdResponse())
        )

        let result = try await RequestFoodView.orchestrateSubmission(
            draft: draft(email: "taylor@stern.nyu.edu"),
            now: try date("2026-07-28T16:00:00.000Z"),
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { payload in
            try await store.createRequest(payload)
        }

        XCTAssertTrue(result.didSubmit)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, ["/api/request"])
        XCTAssertEqual(store.requests.count, 1)
    }

    /// Every other value the requester typed survives an email rejection, so
    /// correcting the address is the only work left.
    func testRejectedEmailPreservesEveryOtherEnteredValue() async throws {
        let submitted = draft(email: "taylor@gmail.com", timing: .later)
        let original = submitted

        let result = try await RequestFoodView.orchestrateSubmission(
            draft: submitted,
            now: try date("2026-07-28T16:00:00.000Z"),
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { _ in
            XCTFail("An ineligible address must not reach submission")
        }

        XCTAssertFalse(result.didSubmit)
        XCTAssertEqual(submitted, original)
        XCTAssertEqual(submitted.selectedDiningSpot?.name, "Palladium")
        XCTAssertEqual(submitted.foodRequest, "Chicken bowl")
        XCTAssertEqual(submitted.pickupName, "Taylor")
        XCTAssertEqual(submitted.email, "taylor@gmail.com")
        XCTAssertEqual(submitted.timing, .later)
        XCTAssertEqual(submitted.preferredPickupTime, original.preferredPickupTime)
        // Only the email failed, so no other field was marked as presented.
        XCTAssertEqual(result.presentation.presentedFields, [.requesterEmail])
    }

    // MARK: - Pre-entry eligibility copy

    func testEmailEligibilityNoticeIsTheAcceptedSentence() {
        XCTAssertEqual(
            RequestFoodView.emailEligibilityNotice,
            "Use your @nyu.edu or @stern.nyu.edu email."
        )
    }

    /// The notice and the rule it describes must not drift apart. This fails if
    /// the allowlist gains, loses, or renames a domain without the copy moving.
    func testEmailEligibilityNoticeNamesEveryAllowedDomain() {
        for domain in NYUEmailPolicy.allowedDomains {
            XCTAssertTrue(
                RequestFoodView.emailEligibilityNotice.contains("@\(domain)"),
                domain
            )
        }

        // Every `@`-prefixed token in the sentence is an allowed domain, so the
        // copy cannot advertise a domain the validator would refuse.
        let advertised = RequestFoodView.emailEligibilityNotice
            .split(whereSeparator: { $0 == " " })
            .filter { $0.hasPrefix("@") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }
            .map { String($0.dropFirst()) }
        XCTAssertEqual(Set(advertised), NYUEmailPolicy.allowedDomains)
    }

    /// Standing help text, not an error and not the purpose notice. It has to
    /// stay distinguishable from both, since all three sit in one section.
    func testEmailEligibilityNoticeIsDistinctFromTheErrorAndThePurposeNotice() {
        XCTAssertNotEqual(RequestFoodView.emailEligibilityNotice, nyuMessage)
        XCTAssertNotEqual(
            RequestFoodView.emailEligibilityNotice,
            RequestFoodView.emailPurposeNotice
        )
        XCTAssertNotEqual(
            RequestFoodView.emailEligibilityNotice,
            RequestFoodFormError.missingEmail.message
        )
    }

    /// The notice is standing copy; the validator owns every message that
    /// depends on what was typed. If the validator ever emitted this sentence,
    /// the hint would have become an error and could suppress the real one.
    func testTheValidatorNeverEmitsTheEligibilityNotice() {
        for address in [
            "",
            "   ",
            "taylor@nyu.edu",
            "taylor@gmail.com",
            "taylor@law.nyu.edu",
            "taylor@"
        ] {
            XCTAssertFalse(
                emailErrors(for: address)
                    .map(\.message)
                    .contains(RequestFoodView.emailEligibilityNotice),
                address
            )
        }
    }

    /// A rejected address still produces its own error, so the standing notice
    /// cannot be read as having replaced it.
    func testEligibilityNoticeDoesNotSuppressTheValidationError() {
        let errors = emailErrors(for: "taylor@gmail.com")

        XCTAssertEqual(errors.map(\.error), [.invalidEmail])
        XCTAssertEqual(errors.first?.message, nyuMessage)
    }

    /// Same guarantee the purpose notice carries: persistence does not depend
    /// on requester email delivery, so no copy beside this field may promise a
    /// message.
    func testEmailEligibilityNoticePromisesNoDelivery() {
        let notice = RequestFoodView.emailEligibilityNotice.lowercased()

        for forbidden in [
            "we'll send",
            "we will send",
            "confirmation",
            "confirm",
            "notify",
            "inbox",
            "receipt",
            "check your",
            "verify"
        ] {
            XCTAssertFalse(notice.contains(forbidden), forbidden)
        }
    }

    // MARK: - Backend refusal

    func testBackendInvalidEmailReadsExactlyLikeTheLocalRefusal() {
        let mapped = RequestCreatePresentationError.map(
            RequestServiceError.serverError(code: "INVALID_EMAIL", message: "backend detail")
        )

        XCTAssertEqual(mapped, .invalidEmail)
        XCTAssertEqual(mapped.message, nyuMessage)
        XCTAssertEqual(mapped.message, RequestFoodFormError.invalidEmail.message)
        // The backend's own wording is never shown; one sentence owns this rule.
        XCTAssertFalse(mapped.message.contains("backend detail"))
    }

    /// The new code must not have disturbed the codes already mapped, and an
    /// unreadable outcome must still be ambiguous rather than an email problem.
    func testOtherCreateOutcomeMappingsAreUnchanged() {
        let expected: [(String, RequestCreatePresentationError)] = [
            ("INVALID_REQUEST", .invalidRequest),
            ("REQUEST_LIMIT_REACHED", .requestLimitReached),
            ("RATE_LIMITED", .rateLimited),
            ("PUBLIC_ACTIONS_PAUSED", .publicActionsPaused),
            ("REQUEST_CREATION_FAILED", .creationFailed),
            ("SOMETHING_NEW", .creationFailed)
        ]

        for (code, presentation) in expected {
            XCTAssertEqual(
                RequestCreatePresentationError.map(
                    RequestServiceError.serverError(code: code, message: "detail")
                ),
                presentation,
                code
            )
        }

        XCTAssertEqual(
            RequestCreatePresentationError.map(
                RequestServiceError.ambiguousCreateOutcome(underlying: URLError(.timedOut))
            ),
            .ambiguous
        )
        XCTAssertEqual(
            RequestCreatePresentationError.map(RequestServiceError.operationInProgress),
            .operationInProgress
        )
    }

    // MARK: - Unchanged submit-button and duplicate-submit behavior

    /// A malformed or ineligible non-empty address still leaves Submit enabled:
    /// completeness decides the button, validation decides the outcome. This is
    /// the accepted behavior for malformed addresses, and the allowlist did not
    /// change it.
    func testIneligibleNonEmptyAddressStillEnablesSubmit() {
        for address in ["taylor@gmail.com", "taylor@law.nyu.edu", "taylor@"] {
            XCTAssertTrue(
                RequestFoodView.isSubmissionEnabled(
                    draft: draft(email: address),
                    submissionError: nil,
                    isCreating: false
                ),
                address
            )
        }

        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
            draft: draft(email: ""),
            submissionError: nil,
            isCreating: false
        ))
    }

    func testDuplicateSubmitAndAmbiguityGuardsStillApplyToAnAllowedAddress() {
        let allowed = draft(email: "taylor@nyu.edu")

        XCTAssertTrue(RequestFoodView.isSubmissionEnabled(
            draft: allowed,
            submissionError: nil,
            isCreating: false
        ))
        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
            draft: allowed,
            submissionError: nil,
            isCreating: true
        ))
        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
            draft: allowed,
            submissionError: .ambiguous,
            isCreating: false
        ))
    }

    func testStoreStillRefusesASecondInFlightCreateForAnAllowedAddress() async throws {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 201, data: createdResponse(), delay: 0.05)
        )

        async let first: Void = store.createRequest(payload(email: "taylor@nyu.edu"))
        try await Task.sleep(nanoseconds: 10_000_000)

        do {
            try await store.createRequest(payload(email: "taylor@nyu.edu"))
            XCTFail("A second in-flight create must be refused")
        } catch RequestServiceError.operationInProgress {
            // Expected: refused before any second POST.
        } catch {
            XCTFail("Unexpected failure: \(error)")
        }

        try await first
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, ["/api/request"])
    }

    // MARK: - Fixtures

    private func emailErrors(for email: String) -> [RequestFoodFieldError] {
        validationErrors(for: draft(email: email))
            .filter { $0.field == .requesterEmail }
    }

    private func validationErrors(
        for draft: RequestFoodFormDraft
    ) -> [RequestFoodFieldError] {
        RequestFoodFormValidator.validate(
            selectedDiningSpot: draft.selectedDiningSpot,
            foodRequest: draft.foodRequest,
            pickupName: draft.pickupName,
            email: draft.email,
            timing: draft.timing,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
    }

    private func draft(
        email: String,
        timing: RequestTiming = .asap
    ) -> RequestFoodFormDraft {
        RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: "140 E 14th St"),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            email: email,
            timing: timing,
            preferredPickupTime: try! date("2026-07-28T17:00:00.000Z")
        )
    }

    private func payload(email: String) -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Palladium",
            food: "Chicken bowl",
            pickupName: "Taylor",
            email: email,
            timing: .asap,
            windowStart: nil
        )
    }

    private func createdResponse() -> Data {
        Data(#"""
        {"request":{
          "id": "64b000000000000000000001",
          "vendor": "Palladium",
          "food": "Chicken bowl",
          "pickupWindowText": "ASAP (available for the next 3 hours)",
          "windowStart": null,
          "windowEnd": null,
          "status": "open",
          "createdAt": "2026-07-28T16:00:00.000Z",
          "expiresAt": "2026-07-28T19:00:00.000Z"
        }}
        """#.utf8)
    }

    private func makeStore() -> RequestStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestStore(
            service: RequestService(client: client),
            installationCredentialProvider: { "test-installation-credential" }
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(formatter.date(from: value))
    }
}
