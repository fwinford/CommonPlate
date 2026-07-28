import Foundation
import XCTest
@testable import CommonPlateios

final class RequestCreationViewTests: XCTestCase {
    func testASAPPayloadTrimsValuesAndOmitsWindowFields() throws {
        let payload = try RequestFoodView.makePayload(
            selectedDiningSpot: DiningSpot(name: "  Palladium  ", address: nil),
            foodRequest: "  Chicken bowl \n",
            pickupName: "  Taylor  ",
            email: "  taylor@nyu.edu  ",
            timing: .asap,
            preferredPickupTime: Date(timeIntervalSince1970: 0),
            now: Date(timeIntervalSince1970: 1_000),
            calendar: utcCalendar
        )

        XCTAssertEqual(payload.vendor, "Palladium")
        XCTAssertEqual(payload.food, "Chicken bowl")
        XCTAssertEqual(payload.pickupName, "Taylor")
        XCTAssertEqual(payload.email, "taylor@nyu.edu")
        XCTAssertEqual(payload.timing.rawValue, "asap")
        XCTAssertNil(payload.windowStart)
        XCTAssertNil(payload.windowEnd)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        XCTAssertFalse(json.keys.contains("windowStart"))
        XCTAssertFalse(json.keys.contains("windowEnd"))
    }

    func testScheduledPayloadUsesOnePreferredTimeAsThirtyMinuteWindow() throws {
        let now = try date("2026-07-28T16:00:00.000Z")
        let preferredTime = try date("2026-07-28T17:00:00.000Z")

        let payload = try RequestFoodView.makePayload(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            email: "taylor@nyu.edu",
            timing: .later,
            preferredPickupTime: preferredTime,
            now: now,
            calendar: utcCalendar
        )

        XCTAssertEqual(payload.timing.rawValue, "scheduled")
        XCTAssertEqual(payload.windowStart, preferredTime)
        XCTAssertEqual(payload.windowEnd, try date("2026-07-28T17:30:00.000Z"))
    }

    func testLatestScheduledStartKeepsDerivedEndAtDayBoundary() throws {
        let now = try date("2026-07-28T16:00:00.000Z")
        let latestStart = try XCTUnwrap(
            RequestFoodView.latestScheduledStart(on: now, calendar: utcCalendar)
        )
        let dayEnd = try XCTUnwrap(
            RequestFoodView.endOfDay(containing: now, calendar: utcCalendar)
        )
        let derivedEnd = try XCTUnwrap(
            utcCalendar.date(byAdding: .minute, value: 30, to: latestStart)
        )

        XCTAssertEqual(latestStart, try date("2026-07-28T23:30:00.000Z"))
        XCTAssertEqual(derivedEnd, dayEnd)
        XCTAssertTrue(
            RequestFoodView.isValidScheduledWindow(
                startingAt: latestStart,
                now: now,
                calendar: utcCalendar
            )
        )
    }

    func testScheduledWindowPastLatestStartIsRejected() throws {
        let now = try date("2026-07-28T16:00:00.000Z")

        XCTAssertThrowsError(
            try RequestFoodView.makePayload(
                selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
                foodRequest: "Chicken bowl",
                pickupName: "Taylor",
                email: "taylor@nyu.edu",
                timing: .later,
                preferredPickupTime: try date("2026-07-28T23:31:00.000Z"),
                now: now,
                calendar: utcCalendar
            )
        ) { error in
            XCTAssertEqual(error as? RequestFoodFormError, .invalidScheduledTime)
        }
    }

    func testKnownBackendErrorsMapToStudentFacingStates() {
        XCTAssertEqual(
            RequestCreatePresentationError.map(
                RequestServiceError.serverError(code: "INVALID_REQUEST", message: "backend detail")
            ),
            .invalidRequest
        )
        XCTAssertEqual(
            RequestCreatePresentationError.map(
                RequestServiceError.serverError(code: "REQUEST_LIMIT_REACHED", message: "backend detail")
            ),
            .requestLimitReached
        )
        XCTAssertEqual(
            RequestCreatePresentationError.map(
                RequestServiceError.serverError(code: "PUBLIC_ACTIONS_PAUSED", message: "backend detail")
            ),
            .publicActionsPaused
        )
        XCTAssertEqual(
            RequestCreatePresentationError.map(
                RequestServiceError.serverError(code: "REQUEST_CREATION_FAILED", message: "backend detail")
            ),
            .creationFailed
        )
        XCTAssertEqual(
            RequestCreatePresentationError.map(
                RequestServiceError.ambiguousCreateOutcome(
                    underlying: URLError(.networkConnectionLost)
                )
            ),
            .ambiguous
        )
    }

    /// The web form asserts this same sentence against
    /// `REQUEST_POSTING_PAUSED_MESSAGE` (`src/client/new-request.test.ts`).
    /// Both halves must exist, or the two clients can drift apart unnoticed —
    /// which is exactly what happened when the iOS pause tests were removed.
    @MainActor
    func testPausedCreateUsesTheLockedSentenceSharedWithTheWebForm() {
        XCTAssertEqual(
            RequestFoodView.pauseNotice,
            "Posting a meal request is temporarily unavailable."
        )
        XCTAssertEqual(
            RequestCreatePresentationError.publicActionsPaused.message,
            "Posting a meal request is temporarily unavailable."
        )
    }

    /// The web form asserts this same sentence against its email hint in
    /// `public/new-request.html` (`src/client/new-request.test.ts`). Both
    /// halves must exist, or the two requester forms can explain the same
    /// required field differently.
    @MainActor
    func testEmailPurposeNoticeIsSharedVerbatimWithTheWebForm() {
        XCTAssertEqual(
            RequestFoodView.emailPurposeNotice,
            "We use your email to coordinate updates about your request. Helpers never see it."
        )
    }

    /// Persistence succeeds independently of requester email delivery, so the
    /// purpose notice must explain the use without promising a message.
    @MainActor
    func testEmailPurposeNoticePromisesNoDelivery() {
        let notice = RequestFoodView.emailPurposeNotice.lowercased()

        for forbidden in [
            "we'll send",
            "we will send",
            "confirmation",
            "confirm",
            "notify",
            "inbox",
            "receipt",
            "check your"
        ] {
            XCTAssertFalse(
                notice.contains(forbidden),
                "email purpose notice must not promise delivery: \(forbidden)"
            )
        }
    }

    // MARK: - Expiration copy

    /// The backend writes `expiresAt` explicitly at creation
    /// (`src/createRequestRoute.ts`): ASAP is five hours after backend
    /// creation, scheduled is the validated `windowEnd`. The success screen
    /// must state exactly that.
    @MainActor
    func testSuccessExpirationCopyMatchesTheBackendContract() {
        XCTAssertEqual(
            RequestFoodView.expirationNotice(for: .asap),
            "Your request is now visible to helpers. It will expire in 5 hours if it is not fulfilled."
        )
        XCTAssertEqual(
            RequestFoodView.expirationNotice(for: .later),
            "Your request is now visible to helpers. It will expire when the pickup window ends if it is not fulfilled."
        )
    }

    /// A `201` proves the request was persisted, not that anyone will take it.
    @MainActor
    func testExpirationCopyPromisesNoFulfillment() {
        for timing in RequestTiming.allCases {
            for notice in [
                RequestFoodView.expirationNotice(for: timing),
                RequestFoodView.formExpirationNotice(for: timing)
            ] {
                let lowercased = notice.lowercased()
                for forbidden in [
                    "will be fulfilled",
                    "someone will",
                    "a helper will",
                    "guarantee"
                ] {
                    XCTAssertFalse(
                        lowercased.contains(forbidden),
                        "expiration copy must not promise fulfillment: \(forbidden)"
                    )
                }
            }
        }
    }

    /// The old form sentence — "Requests expire after a few hours" — matched
    /// neither backend rule and must not come back in any timing state.
    @MainActor
    func testNoVagueExpirationCopyRemains() {
        for timing in RequestTiming.allCases {
            for notice in [
                RequestFoodView.expirationNotice(for: timing),
                RequestFoodView.formExpirationNotice(for: timing)
            ] {
                let lowercased = notice.lowercased()
                XCTAssertFalse(lowercased.contains("a few hours"))
                XCTAssertFalse(lowercased.contains("automatically"))
            }
        }
    }

    @MainActor
    func testFormExpirationCopyDistinguishesTheTwoBackendRules() {
        XCTAssertTrue(
            RequestFoodView.formExpirationNotice(for: .asap).contains("5 hours")
        )
        XCTAssertTrue(
            RequestFoodView.formExpirationNotice(for: .later)
                .contains("pickup window ends")
        )
        XCTAssertNotEqual(
            RequestFoodView.formExpirationNotice(for: .asap),
            RequestFoodView.formExpirationNotice(for: .later)
        )
    }

    // MARK: - Ambiguous-create escape

    /// The POST may already have succeeded, so submission must stay disabled
    /// and the only offered action must be leaving the screen.
    @MainActor
    func testAmbiguousOutcomeKeepsSubmissionDisabledAndOffersOnlyAnExit() {
        XCTAssertFalse(RequestFoodView.allowsSubmission(after: .ambiguous))
        XCTAssertTrue(RequestFoodView.showsReturnHomeAction(for: .ambiguous))
    }

    /// A confirmed backend rejection is recoverable in place: the student can
    /// correct the form and submit again, so it must not be given the exit
    /// action or have submission taken away.
    @MainActor
    func testOrdinaryRejectionsKeepSubmissionAndReceiveNoExitAction() {
        for error: RequestCreatePresentationError in [
            .invalidRequest,
            .requestLimitReached,
            .publicActionsPaused,
            .creationFailed,
            .operationInProgress
        ] {
            XCTAssertTrue(
                RequestFoodView.allowsSubmission(after: error),
                "\(error) must not disable submission"
            )
            XCTAssertFalse(
                RequestFoodView.showsReturnHomeAction(for: error),
                "\(error) must not receive the ambiguous exit action"
            )
        }

        XCTAssertTrue(RequestFoodView.allowsSubmission(after: nil))
        XCTAssertFalse(RequestFoodView.showsReturnHomeAction(for: nil))
    }

    /// The escape must not become a retry: the copy still sends the student to
    /// Active Requests to check before submitting anything else.
    @MainActor
    func testAmbiguousCopyStillDirectsTheStudentToActiveRequests() {
        let message = RequestCreatePresentationError.ambiguous.message

        XCTAssertEqual(
            message,
            "We couldn’t confirm whether your request was posted. Check Active Requests before submitting again."
        )
        XCTAssertFalse(message.lowercased().contains("submit again"))
        XCTAssertFalse(message.lowercased().contains("try again"))
    }

    // MARK: - Derived scheduled window

    @MainActor
    func testScheduledWindowHelperSentenceIsExact() {
        XCTAssertEqual(
            RequestFoodView.scheduledWindowNotice,
            "Helpers will see a 30-minute pickup window starting at this time."
        )
    }

    // MARK: - Late-night scheduling

    @MainActor
    func testLaterRemainsAvailableWhileAFullWindowStillFits() throws {
        for value in [
            "2026-07-28T16:00:00.000Z",
            "2026-07-28T23:29:00.000Z",
            "2026-07-28T23:30:00.000Z"
        ] {
            let now = try date(value)

            XCTAssertTrue(
                RequestFoodView.isScheduledTimingAvailable(
                    now: now,
                    calendar: utcCalendar
                ),
                "a full 30-minute window still fits at \(value)"
            )
            XCTAssertEqual(
                RequestFoodView.availableTimingOptions(
                    now: now,
                    calendar: utcCalendar
                ),
                RequestTiming.allCases
            )
        }
    }

    /// Past the latest possible start, no 30-minute window can end before the
    /// next calendar day, so "Later" — and the date picker it would reveal —
    /// must be withheld rather than shown in an unusable state.
    @MainActor
    func testLaterIsWithheldWhenFewerThanThirtyMinutesRemainToday() throws {
        for value in [
            "2026-07-28T23:31:00.000Z",
            "2026-07-28T23:59:59.000Z"
        ] {
            let now = try date(value)

            XCTAssertFalse(
                RequestFoodView.isScheduledTimingAvailable(
                    now: now,
                    calendar: utcCalendar
                ),
                "no 30-minute window fits at \(value)"
            )
            XCTAssertEqual(
                RequestFoodView.availableTimingOptions(
                    now: now,
                    calendar: utcCalendar
                ),
                [.asap],
                "ASAP must remain available at \(value)"
            )
        }
    }

    @MainActor
    func testWithheldSchedulingExplainsItselfWithoutOfferingTomorrow() {
        XCTAssertEqual(
            RequestFoodView.scheduledUnavailableNotice,
            "Scheduled pickups reopen tomorrow."
        )
    }

    /// Nothing may schedule into tomorrow: the latest allowed start plus the
    /// derived 30 minutes lands exactly on the day boundary, and a start past
    /// it is rejected even when the picker is somehow still showing.
    @MainActor
    func testNoScheduledWindowCrossesIntoTomorrow() throws {
        let now = try date("2026-07-28T23:31:00.000Z")
        let tomorrowMorning = try date("2026-07-29T09:00:00.000Z")

        XCTAssertFalse(
            RequestFoodView.isValidScheduledWindow(
                startingAt: tomorrowMorning,
                now: now,
                calendar: utcCalendar
            )
        )
        XCTAssertThrowsError(
            try RequestFoodView.makePayload(
                selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
                foodRequest: "Chicken bowl",
                pickupName: "Taylor",
                email: "taylor@nyu.edu",
                timing: .later,
                preferredPickupTime: tomorrowMorning,
                now: now,
                calendar: utcCalendar
            )
        ) { error in
            XCTAssertEqual(error as? RequestFoodFormError, .invalidScheduledTime)
        }
    }

    // MARK: - Availability gating

    @MainActor
    func testAvailablePostingShowsTheForm() {
        XCTAssertEqual(
            RequestFoodView.presentation(availability: .available, didCreateRequest: false),
            .form
        )
    }

    @MainActor
    func testPausedPostingHidesTheFormAndShowsTheLockedSentence() {
        let presentation = RequestFoodView.presentation(
            availability: .paused,
            didCreateRequest: false
        )

        XCTAssertEqual(
            presentation,
            .unavailable(
                message: "Posting a meal request is temporarily unavailable.",
                retryable: false
            )
        )
        XCTAssertNotEqual(presentation, .form)
    }

    /// Fail-closed: a probe that could not be completed or decoded must not
    /// reveal the fields, and must not claim posting is paused when the app
    /// only failed to find out.
    @MainActor
    func testFailedAvailabilityCheckHidesTheFormWithoutClaimingItIsPaused() {
        let presentation = RequestFoodView.presentation(
            availability: .unavailable,
            didCreateRequest: false
        )

        XCTAssertEqual(
            presentation,
            .unavailable(
                message: RequestFoodView.availabilityUnknownNotice,
                retryable: true
            )
        )
        XCTAssertNotEqual(presentation, .form)
        XCTAssertNotEqual(RequestFoodView.availabilityUnknownNotice, RequestFoodView.pauseNotice)
    }

    /// No form may render while the answer is pending, so the private fields
    /// cannot flash into view before availability is known.
    @MainActor
    func testUnknownAvailabilityShowsNeitherFormNorAnUnavailableClaim() {
        XCTAssertEqual(
            RequestFoodView.presentation(availability: .unknown, didCreateRequest: false),
            .checkingAvailability
        )
    }

    /// A confirmed create keeps its success screen regardless of what the
    /// availability probe last reported.
    @MainActor
    func testConfirmedCreateShowsSuccessInEveryAvailabilityState() {
        for availability in [
            RequestCreationAvailability.unknown,
            .available,
            .paused,
            .unavailable
        ] {
            XCTAssertEqual(
                RequestFoodView.presentation(
                    availability: availability,
                    didCreateRequest: true
                ),
                .success
            )
        }
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
