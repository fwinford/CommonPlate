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
            RequestCreatePresentationError.publicActionsPaused.message,
            "Posting a meal request is temporarily unavailable."
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
