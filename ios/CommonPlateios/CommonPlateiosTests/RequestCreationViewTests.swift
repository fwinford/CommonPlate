import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class RequestCreationViewTests: XCTestCase {
    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Validation timing and presentation

    func testAllEmptyRequestDraftDisablesSubmission() {
        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
            draft: RequestFoodFormDraft(),
            submissionError: nil,
            isCreating: false
        ))
    }

    func testEachMissingRequiredRequestValueDisablesSubmission() throws {
        let complete = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            email: "taylor@nyu.edu",
            timing: .later,
            preferredPickupTime: try date("2026-07-28T17:00:00.000Z")
        )

        var missingDiningSpot = complete
        missingDiningSpot.selectedDiningSpot = nil
        var missingFood = complete
        missingFood.foodRequest = "  "
        var missingPickupName = complete
        missingPickupName.pickupName = "\n"
        var missingEmail = complete
        missingEmail.email = ""

        for draft in [missingDiningSpot, missingFood, missingPickupName, missingEmail] {
            XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
                draft: draft,
                submissionError: nil,
                isCreating: false
            ))
        }
    }

    func testCompletedRequestDraftEnablesSubmissionForBothTimingSelections() throws {
        var draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            email: "taylor@nyu.edu",
            timing: .asap,
            preferredPickupTime: try date("2026-07-28T17:00:00.000Z")
        )

        XCTAssertTrue(RequestFoodView.isSubmissionEnabled(
            draft: draft,
            submissionError: nil,
            isCreating: false
        ))

        draft.timing = .later
        XCTAssertTrue(RequestFoodView.isSubmissionEnabled(
            draft: draft,
            submissionError: nil,
            isCreating: false
        ))
    }

    func testMalformedNonemptyEmailDoesNotDisableRequestSubmission() {
        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            email: "taylor@",
            timing: .asap,
            preferredPickupTime: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(RequestFoodView.isSubmissionEnabled(
            draft: draft,
            submissionError: nil,
            isCreating: false
        ))
    }

    func testMalformedCompletedRequestRevealsEmailErrorAndInvokesNoSubmission() async throws {
        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            email: "taylor@",
            timing: .asap,
            preferredPickupTime: Date(timeIntervalSince1970: 0)
        )
        var submissionCount = 0

        XCTAssertTrue(RequestFoodView.isSubmissionEnabled(
            draft: draft,
            submissionError: nil,
            isCreating: false
        ))
        let result = try await RequestFoodView.orchestrateSubmission(
            draft: draft,
            now: Date(timeIntervalSince1970: 1_000),
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { _ in
            submissionCount += 1
        }
        let errors = RequestFoodFormValidator.validate(
            selectedDiningSpot: draft.selectedDiningSpot,
            foodRequest: draft.foodRequest,
            pickupName: draft.pickupName,
            email: draft.email,
            timing: draft.timing,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )

        XCTAssertEqual(submissionCount, 0)
        XCTAssertFalse(result.didSubmit)
        XCTAssertEqual(result.firstInvalidTextField, .requesterEmail)
        XCTAssertEqual(
            result.presentation.visibleError(for: .requesterEmail, from: errors)?.error,
            .invalidEmail
        )
    }

    func testInFlightAndExistingLifecycleBlockDisableRequestSubmission() {
        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            email: "taylor@nyu.edu",
            timing: .asap,
            preferredPickupTime: Date(timeIntervalSince1970: 0)
        )

        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
            draft: draft,
            submissionError: nil,
            isCreating: true
        ))
        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
            draft: draft,
            submissionError: .ambiguous,
            isCreating: false
        ))
    }

    func testMalformedEmailRemainsQuietDuringInitialTyping() {
        let errors = RequestFoodFormValidator.validate(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            email: "t",
            timing: .asap,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        let presentation = RequestFoodValidationPresentation()

        XCTAssertEqual(errors.map(\.error), [.invalidEmail])
        XCTAssertTrue(presentation.visibleErrors(from: errors).isEmpty)
    }

    func testEmptyAndMalformedEmailHaveDistinctCopy() {
        let empty = RequestFoodFormValidator.validate(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            email: "  ",
            timing: .asap,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        let malformed = RequestFoodFormValidator.validate(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            email: "taylor@",
            timing: .asap,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )

        XCTAssertEqual(empty.last?.message, "Enter your email address.")
        XCTAssertEqual(malformed.last?.message, "Enter a valid email address.")
    }

    func testProductionFocusTransitionRevealsOnlyTheExitedInvalidRequestField() {
        let errors = RequestFoodFormValidator.validate(
            selectedDiningSpot: nil,
            foodRequest: "",
            pickupName: "",
            email: "invalid",
            timing: .later,
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: true
        )
        var presentation = RequestFoodValidationPresentation()

        presentation.handleFocusTransition(
            from: .requesterEmail,
            to: .pickupName,
            errors: errors
        )

        XCTAssertEqual(
            presentation.visibleErrors(from: errors).map(\.field),
            [.requesterEmail]
        )
    }

    func testRequestSubmitRejectsEveryErrorWithoutInvokingSubmission() async throws {
        let draft = RequestFoodFormDraft(
            selectedDiningSpot: nil,
            foodRequest: "",
            pickupName: "",
            email: "",
            timing: .later,
            preferredPickupTime: try date("2026-07-28T15:00:00.000Z")
        )
        let now = try date("2026-07-28T16:00:00.000Z")
        var submissionCount = 0

        let result = try await RequestFoodView.orchestrateSubmission(
            draft: draft,
            now: now,
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { _ in
            submissionCount += 1
        }
        let errors = RequestFoodFormValidator.validate(
            selectedDiningSpot: draft.selectedDiningSpot,
            foodRequest: draft.foodRequest,
            pickupName: draft.pickupName,
            email: draft.email,
            timing: draft.timing,
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: true
        )
        let visible = result.presentation.visibleErrors(from: errors)

        XCTAssertEqual(submissionCount, 0)
        XCTAssertFalse(result.didSubmit)
        XCTAssertEqual(
            visible.map(\.field),
            [.diningSpot, .foodDescription, .pickupName, .pickupSchedule, .requesterEmail]
        )
        XCTAssertEqual(result.firstInvalidTextField, .foodDescription)
    }

    func testPresentedRequestErrorUpdatesLiveWhileNeverPresentedFieldsStayQuiet() {
        let initial = RequestFoodFormValidator.validate(
            selectedDiningSpot: nil,
            foodRequest: "",
            pickupName: "Taylor",
            email: "invalid",
            timing: .asap,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        var presentation = RequestFoodValidationPresentation()
        presentation.handleFocusTransition(
            from: .requesterEmail,
            to: nil,
            errors: initial
        )

        let corrected = RequestFoodFormValidator.validate(
            selectedDiningSpot: nil,
            foodRequest: "",
            pickupName: "Taylor",
            email: "taylor@nyu.edu",
            timing: .asap,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        XCTAssertTrue(presentation.visibleErrors(from: corrected).isEmpty)

        let invalidAgain = RequestFoodFormValidator.validate(
            selectedDiningSpot: nil,
            foodRequest: "",
            pickupName: "Taylor",
            email: "taylor@",
            timing: .asap,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        XCTAssertEqual(
            presentation.visibleErrors(from: invalidAgain).map(\.field),
            [.requesterEmail],
            "Dining spot and food never presented errors, so they must stay quiet"
        )

        let emptied = RequestFoodFormValidator.validate(
            selectedDiningSpot: nil,
            foodRequest: "",
            pickupName: "Taylor",
            email: "",
            timing: .asap,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        XCTAssertEqual(
            presentation.visibleError(for: .requesterEmail, from: emptied)?.message,
            "Enter your email address."
        )
    }

    func testPresentedDiningPickerErrorClearsAndReappearsWithSelection() {
        var draft = RequestFoodFormDraft(
            selectedDiningSpot: nil,
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            email: "taylor@nyu.edu",
            timing: .asap,
            preferredPickupTime: Date(timeIntervalSince1970: 0)
        )
        let initialErrors = RequestFoodFormValidator.validate(
            selectedDiningSpot: draft.selectedDiningSpot,
            foodRequest: draft.foodRequest,
            pickupName: draft.pickupName,
            email: draft.email,
            timing: draft.timing,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        var presentation = RequestFoodValidationPresentation()
        presentation.presentAll(initialErrors)
        XCTAssertNotNil(presentation.visibleError(for: .diningSpot, from: initialErrors))

        draft.selectedDiningSpot = DiningSpot(name: "Palladium", address: nil)
        let correctedErrors = RequestFoodFormValidator.validate(
            selectedDiningSpot: draft.selectedDiningSpot,
            foodRequest: draft.foodRequest,
            pickupName: draft.pickupName,
            email: draft.email,
            timing: draft.timing,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        XCTAssertNil(presentation.visibleError(for: .diningSpot, from: correctedErrors))

        draft.selectedDiningSpot = nil
        XCTAssertNotNil(presentation.visibleError(for: .diningSpot, from: initialErrors))
    }

    func testValidRequestSubmitInvokesSubmissionOnceWithNormalizedPayload() async throws {
        let now = try date("2026-07-28T16:00:00.000Z")
        let preferredTime = try date("2026-07-28T17:00:00.000Z")
        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "  Palladium  ", address: nil),
            foodRequest: "  Chicken bowl \n",
            pickupName: "  Taylor  ",
            email: "  taylor@nyu.edu  ",
            timing: .later,
            preferredPickupTime: preferredTime
        )
        var payloads: [CreateRequestPayload] = []

        let result = try await RequestFoodView.orchestrateSubmission(
            draft: draft,
            now: now,
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { payload in
            payloads.append(payload)
        }

        XCTAssertTrue(result.didSubmit)
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads.first?.vendor, "Palladium")
        XCTAssertEqual(payloads.first?.food, "Chicken bowl")
        XCTAssertEqual(payloads.first?.pickupName, "Taylor")
        XCTAssertEqual(payloads.first?.email, "taylor@nyu.edu")
        XCTAssertEqual(payloads.first?.timing.rawValue, "scheduled")
        XCTAssertEqual(payloads.first?.windowStart, preferredTime)
        XCTAssertEqual(payloads.first?.windowEnd, try date("2026-07-28T17:30:00.000Z"))
    }

    func testRequestBackendFailurePreservesActualDraftAndTimingSelection() async throws {
        enum SimulatedBackendFailure: Error { case rejected }

        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: "140 E 14th St"),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            email: "taylor@nyu.edu",
            timing: .later,
            preferredPickupTime: try date("2026-07-28T17:00:00.000Z")
        )
        let originalDraft = draft
        var submissionCount = 0

        do {
            _ = try await RequestFoodView.orchestrateSubmission(
                draft: draft,
                now: try date("2026-07-28T16:00:00.000Z"),
                calendar: utcCalendar,
                presentation: RequestFoodValidationPresentation()
            ) { _ in
                submissionCount += 1
                throw SimulatedBackendFailure.rejected
            }
            XCTFail("The simulated backend failure must escape the production seam")
        } catch {
            XCTAssertTrue(error is SimulatedBackendFailure)
        }
        _ = RequestCreatePresentationError.map(
            RequestServiceError.serverError(code: "INVALID_REQUEST", message: "backend detail")
        )

        XCTAssertEqual(submissionCount, 1)
        XCTAssertEqual(draft, originalDraft)
        XCTAssertEqual(draft.timing, .later)
        XCTAssertEqual(draft.preferredPickupTime, originalDraft.preferredPickupTime)
    }

    func testPresentedSchedulingErrorRemainsRenderableWhenSchedulingBecomesUnavailable() async throws {
        let availableNow = try date("2026-07-28T22:00:00.000Z")
        let unavailableNow = try date("2026-07-28T23:45:00.000Z")
        var draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            email: "taylor@nyu.edu",
            timing: .later,
            preferredPickupTime: try date("2026-07-28T23:00:00.000Z")
        )
        XCTAssertTrue(RequestFoodView.isScheduledTimingAvailable(
            now: availableNow,
            calendar: utcCalendar
        ))
        XCTAssertFalse(RequestFoodView.isScheduledTimingAvailable(
            now: unavailableNow,
            calendar: utcCalendar
        ))

        var submissionCount = 0
        let result = try await RequestFoodView.orchestrateSubmission(
            draft: draft,
            now: unavailableNow,
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { _ in
            submissionCount += 1
        }
        let unavailableErrors = RequestFoodFormValidator.validate(
            selectedDiningSpot: draft.selectedDiningSpot,
            foodRequest: draft.foodRequest,
            pickupName: draft.pickupName,
            email: draft.email,
            timing: draft.timing,
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: false
        )

        XCTAssertEqual(submissionCount, 0)
        XCTAssertEqual(
            result.presentation.visibleError(for: .pickupSchedule, from: unavailableErrors)?.error,
            .scheduledTimingUnavailable
        )

        draft.timing = .asap
        let asapErrors = RequestFoodFormValidator.validate(
            selectedDiningSpot: draft.selectedDiningSpot,
            foodRequest: draft.foodRequest,
            pickupName: draft.pickupName,
            email: draft.email,
            timing: draft.timing,
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: false
        )
        XCTAssertNil(result.presentation.visibleError(for: .pickupSchedule, from: asapErrors))

        draft.timing = .later
        XCTAssertEqual(
            result.presentation.visibleError(for: .pickupSchedule, from: unavailableErrors)?.error,
            .scheduledTimingUnavailable
        )
    }

    /// While scheduling is still open, a bad start is a bad start: the picker is
    /// on screen, so the instruction is to pick a different time.
    func testInvalidStartWhileSchedulingIsOpenKeepsTheChooseAPickupTimeMessage() throws {
        let now = try date("2026-07-28T22:00:00.000Z")
        XCTAssertTrue(RequestFoodView.isScheduledTimingAvailable(
            now: now,
            calendar: utcCalendar
        ))
        XCTAssertEqual(
            RequestFoodView.availableTimingOptions(now: now, calendar: utcCalendar),
            RequestTiming.allCases
        )

        let errors = RequestFoodFormValidator.validate(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            email: "taylor@nyu.edu",
            timing: .later,
            // A start in the past: correctable, because a valid one still exists.
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: true
        )

        XCTAssertEqual(errors.map(\.field), [.pickupSchedule])
        XCTAssertEqual(errors.first?.error, .invalidScheduledTime)
        XCTAssertEqual(
            errors.first?.message,
            "Choose a pickup time that leaves a full 30-minute window today."
        )
    }

    /// The lapsed selection itself. Nothing is rewritten for the requester —
    /// the draft still says Later — but the message stops pointing at a picker
    /// that no longer exists and names the one move left.
    func testLapsedLaterSelectionNamesASAPInsteadOfADepartedPicker() async throws {
        let unavailableNow = try date("2026-07-28T23:45:00.000Z")
        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            email: "taylor@nyu.edu",
            timing: .later,
            preferredPickupTime: try date("2026-07-28T23:00:00.000Z")
        )
        let originalDraft = draft

        XCTAssertFalse(RequestFoodView.isScheduledTimingAvailable(
            now: unavailableNow,
            calendar: utcCalendar
        ))
        // The picker is gone, and with it the only control this state could
        // have asked the requester to use.
        XCTAssertEqual(
            RequestFoodView.availableTimingOptions(now: unavailableNow, calendar: utcCalendar),
            [.asap]
        )

        var submissionCount = 0
        let result = try await RequestFoodView.orchestrateSubmission(
            draft: draft,
            now: unavailableNow,
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { _ in
            submissionCount += 1
        }

        XCTAssertEqual(submissionCount, 0)
        XCTAssertFalse(result.didSubmit)
        // Nothing was switched on their behalf.
        XCTAssertEqual(draft, originalDraft)
        XCTAssertEqual(draft.timing, .later)

        let errors = RequestFoodFormValidator.validate(
            selectedDiningSpot: draft.selectedDiningSpot,
            foodRequest: draft.foodRequest,
            pickupName: draft.pickupName,
            email: draft.email,
            timing: draft.timing,
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: false
        )
        let visible = try XCTUnwrap(
            result.presentation.visibleError(for: .pickupSchedule, from: errors)
        )
        XCTAssertEqual(visible.error, .scheduledTimingUnavailable)
        XCTAssertEqual(
            visible.message,
            "Scheduled pickups reopen tomorrow. Choose ASAP to post this request now."
        )
        XCTAssertNotEqual(visible.error, .invalidScheduledTime)
        XCTAssertFalse(
            visible.message.contains("Choose a pickup time that leaves a full 30-minute window today.")
        )

        // The completeness gate stays open: the draft is complete, just invalid,
        // and the requester has to be able to tap Submit to hear why.
        XCTAssertTrue(RequestFoodView.isSubmissionEnabled(
            draft: draft,
            submissionError: nil,
            isCreating: false
        ))

        // One statement about the closed window, not two.
        XCTAssertFalse(RequestFoodView.showsScheduledUnavailableNotice(
            isScheduledTimingAvailable: false,
            visibleScheduleError: .scheduledTimingUnavailable
        ))
        // An ASAP draft still gets the plain footnote: it is the only thing
        // explaining why Later is missing from the picker.
        XCTAssertTrue(RequestFoodView.showsScheduledUnavailableNotice(
            isScheduledTimingAvailable: false,
            visibleScheduleError: nil
        ))
        XCTAssertTrue(
            RequestFoodView.lapsedScheduledTimingNotice
                .hasPrefix(RequestFoodView.scheduledUnavailableNotice)
        )
    }

    /// A rejection with no text field to focus used to be silent. The tap now
    /// leaves something visible next to the button that was tapped.
    func testLocalRejectionWithNoFocusableFieldShowsTheSubmitAdjacentPointer() async throws {
        let unavailableNow = try date("2026-07-28T23:45:00.000Z")
        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            email: "taylor@nyu.edu",
            timing: .later,
            preferredPickupTime: try date("2026-07-28T23:00:00.000Z")
        )

        var submissionCount = 0
        let result = try await RequestFoodView.orchestrateSubmission(
            draft: draft,
            now: unavailableNow,
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { _ in
            submissionCount += 1
        }

        XCTAssertEqual(submissionCount, 0)
        XCTAssertFalse(result.didSubmit)
        XCTAssertNil(result.firstInvalidTextField)
        XCTAssertTrue(RequestFoodView.showsLocalRejectionPointer(for: result))
        XCTAssertTrue(RequestFoodView.showsLocalRejectionPointer(
            isPresenting: true,
            submissionError: nil
        ))
        XCTAssertEqual(
            RequestFoodView.localRejectionPointerNotice,
            "Check the highlighted fields above."
        )
        // It points at the adjacent errors; it never restates or replaces them.
        XCTAssertNil(RequestFoodView.submissionSectionPresentation(for: nil))
    }

    /// Focus is its own answer to the tap, so the generic pointer stays away
    /// from every rejection that can move it.
    func testFocusableRejectionFocusesTheFieldWithoutTheGenericPointer() async throws {
        let now = try date("2026-07-28T16:00:00.000Z")
        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            email: "not-an-email",
            timing: .asap,
            preferredPickupTime: now
        )

        var submissionCount = 0
        let result = try await RequestFoodView.orchestrateSubmission(
            draft: draft,
            now: now,
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { _ in
            submissionCount += 1
        }

        XCTAssertEqual(submissionCount, 0)
        XCTAssertEqual(result.firstInvalidTextField, .requesterEmail)
        XCTAssertFalse(RequestFoodView.showsLocalRejectionPointer(for: result))
        XCTAssertFalse(RequestFoodView.showsLocalRejectionPointer(
            isPresenting: false,
            submissionError: nil
        ))
    }

    /// Choosing ASAP is the correction the message asks for, so it has to be a
    /// real way out: the scheduling error goes, everything else the requester
    /// typed stays, and the submission proceeds normally.
    func testChoosingASAPClearsTheLapsedErrorAndPermitsSubmission() async throws {
        let unavailableNow = try date("2026-07-28T23:45:00.000Z")
        var draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            email: "taylor@nyu.edu",
            timing: .later,
            preferredPickupTime: try date("2026-07-28T23:00:00.000Z")
        )

        let rejected = try await RequestFoodView.orchestrateSubmission(
            draft: draft,
            now: unavailableNow,
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { _ in }
        XCTAssertTrue(RequestFoodView.showsLocalRejectionPointer(for: rejected))

        draft.timing = .asap

        let correctedErrors = RequestFoodFormValidator.validate(
            selectedDiningSpot: draft.selectedDiningSpot,
            foodRequest: draft.foodRequest,
            pickupName: draft.pickupName,
            email: draft.email,
            timing: draft.timing,
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: false
        )
        XCTAssertTrue(correctedErrors.isEmpty)
        // Presentation history is unchanged, and there is simply nothing left
        // for it to reveal.
        XCTAssertNil(
            rejected.presentation.visibleError(for: .pickupSchedule, from: correctedErrors)
        )

        // Only the timing moved.
        XCTAssertEqual(draft.selectedDiningSpot?.name, "Palladium")
        XCTAssertEqual(draft.foodRequest, "Chicken bowl")
        XCTAssertEqual(draft.pickupName, "Taylor")
        XCTAssertEqual(draft.email, "taylor@nyu.edu")
        XCTAssertEqual(draft.preferredPickupTime, try date("2026-07-28T23:00:00.000Z"))

        var submitted: CreateRequestPayload?
        let accepted = try await RequestFoodView.orchestrateSubmission(
            draft: draft,
            now: unavailableNow,
            calendar: utcCalendar,
            presentation: rejected.presentation
        ) { payload in
            submitted = payload
        }

        XCTAssertTrue(accepted.didSubmit)
        XCTAssertFalse(RequestFoodView.showsLocalRejectionPointer(for: accepted))
        XCTAssertEqual(submitted?.timing, .asap)
        XCTAssertNil(submitted?.windowStart)
        XCTAssertNil(submitted?.windowEnd)
    }

    /// The pointer is local-only. Anything the backend decided keeps the
    /// submission section to itself, including the ambiguous outcome that
    /// withdraws submission entirely.
    func testBackendAndAmbiguousErrorsKeepTheirOwnSubmitAdjacentMessages() {
        for error in [
            RequestCreatePresentationError.invalidRequest,
            .requestLimitReached,
            .publicActionsPaused,
            .creationFailed,
            .operationInProgress,
            .ambiguous
        ] {
            let presentation = RequestFoodView.submissionSectionPresentation(for: error)
            XCTAssertEqual(presentation?.message, error.message, "\(error)")
            XCTAssertNotEqual(
                presentation?.message,
                RequestFoodView.localRejectionPointerNotice,
                "\(error)"
            )
            // Even if a stale local rejection were still flagged, a backend
            // answer takes the section.
            XCTAssertFalse(
                RequestFoodView.showsLocalRejectionPointer(
                    isPresenting: true,
                    submissionError: error
                ),
                "\(error)"
            )
        }

        XCTAssertTrue(RequestFoodView.showsReturnHomeAction(for: .ambiguous))
        XCTAssertFalse(RequestFoodView.allowsSubmission(after: .ambiguous))
    }

    func testProgrammaticRequestFocusChangesCannotSubmitOrRevealSiblings() {
        let errors = RequestFoodFormValidator.validate(
            selectedDiningSpot: nil,
            foodRequest: "",
            pickupName: "",
            email: "invalid",
            timing: .asap,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        var presentation = RequestFoodValidationPresentation()
        let submissionCount = 0

        presentation.handleFocusTransition(from: nil, to: .requesterEmail, errors: errors)
        XCTAssertTrue(presentation.visibleErrors(from: errors).isEmpty)

        presentation.handleFocusTransition(from: .requesterEmail, to: nil, errors: errors)
        XCTAssertEqual(presentation.visibleErrors(from: errors).map(\.field), [.requesterEmail])
        XCTAssertEqual(submissionCount, 0)
    }

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

    func testStructuredBackendFailureUsesSubmitSectionPresentation() {
        let error = RequestCreatePresentationError.map(
            RequestServiceError.serverError(
                code: "REQUEST_CREATION_FAILED",
                message: "backend detail"
            )
        )
        let presentation = RequestFoodView.submissionSectionPresentation(for: error)

        XCTAssertEqual(presentation?.error, .creationFailed)
        XCTAssertEqual(
            presentation?.message,
            "We couldn’t post your request. Please try again in a moment."
        )
        XCTAssertFalse(presentation?.showsReturnHomeAction ?? true)
    }

    func testAmbiguousCreationUsesTheSameSubmitSectionPresentation() {
        let error = RequestCreatePresentationError.map(
            RequestServiceError.ambiguousCreateOutcome(
                underlying: URLError(.timedOut)
            )
        )
        let presentation = RequestFoodView.submissionSectionPresentation(for: error)

        XCTAssertEqual(presentation?.error, .ambiguous)
        XCTAssertEqual(
            presentation?.message,
            "We couldn’t confirm whether your request was posted. Check Active Requests before submitting again."
        )
        XCTAssertTrue(presentation?.showsReturnHomeAction ?? false)
    }

    func testSubmitSectionFailurePresentationPreservesDraftAndPickupSelection() async throws {
        enum SimulatedBackendFailure: Error { case rejected }

        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: "140 E 14th St"),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            email: "taylor@nyu.edu",
            timing: .later,
            preferredPickupTime: try date("2026-07-28T17:00:00.000Z")
        )
        let originalDraft = draft

        do {
            _ = try await RequestFoodView.orchestrateSubmission(
                draft: draft,
                now: try date("2026-07-28T16:00:00.000Z"),
                calendar: utcCalendar,
                presentation: RequestFoodValidationPresentation()
            ) { _ in
                throw SimulatedBackendFailure.rejected
            }
            XCTFail("The simulated backend failure must escape the production seam")
        } catch {
            XCTAssertTrue(error is SimulatedBackendFailure)
        }

        let sectionPresentation = RequestFoodView.submissionSectionPresentation(
            for: .creationFailed
        )
        XCTAssertNotNil(sectionPresentation)
        XCTAssertEqual(draft, originalDraft)
        XCTAssertEqual(draft.selectedDiningSpot, originalDraft.selectedDiningSpot)
        XCTAssertEqual(draft.timing, .later)
        XCTAssertEqual(draft.preferredPickupTime, originalDraft.preferredPickupTime)
    }

    func testLocalFieldErrorsDoNotEnterSubmitSectionPresentation() {
        let errors = RequestFoodFormValidator.validate(
            selectedDiningSpot: nil,
            foodRequest: "",
            pickupName: "",
            email: "invalid",
            timing: .later,
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: true
        )
        var validationPresentation = RequestFoodValidationPresentation()
        validationPresentation.presentAll(errors)

        XCTAssertEqual(
            validationPresentation.visibleErrors(from: errors).map(\.field),
            [.diningSpot, .foodDescription, .pickupName, .pickupSchedule, .requesterEmail]
        )
        XCTAssertNil(RequestFoodView.submissionSectionPresentation(for: nil))
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
        // At this `now` scheduling has already closed for the day, so the
        // refusal is the lapsed one — there is no pickup time left to offer.
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
            XCTAssertEqual(error as? RequestFoodFormError, .scheduledTimingUnavailable)
        }

        // The boundary rule itself is unchanged: while scheduling is still open,
        // a start that lands in tomorrow is refused as a correctable start.
        let openNow = try date("2026-07-28T16:00:00.000Z")
        XCTAssertTrue(RequestFoodView.isScheduledTimingAvailable(
            now: openNow,
            calendar: utcCalendar
        ))
        XCTAssertThrowsError(
            try RequestFoodView.makePayload(
                selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
                foodRequest: "Chicken bowl",
                pickupName: "Taylor",
                email: "taylor@nyu.edu",
                timing: .later,
                preferredPickupTime: tomorrowMorning,
                now: openNow,
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
            RequestFoodView.presentation(
                availability: .available,
                isCheckingAvailability: false,
                hasAttemptedAvailabilityCheck: true,
                didCreateRequest: false
            ),
            .form
        )
    }

    @MainActor
    func testPausedPostingHidesTheFormAndShowsTheLockedSentence() {
        let presentation = RequestFoodView.presentation(
            availability: .paused,
            isCheckingAvailability: false,
            hasAttemptedAvailabilityCheck: true,
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
            isCheckingAvailability: false,
            hasAttemptedAvailabilityCheck: true,
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
        for hasAttempted in [true, false] {
            XCTAssertEqual(
                RequestFoodView.presentation(
                    availability: .unknown,
                    isCheckingAvailability: true,
                    hasAttemptedAvailabilityCheck: hasAttempted,
                    didCreateRequest: false
                ),
                .checkingAvailability
            )
        }
    }

    /// Before the screen's own task has started anything there is nothing to
    /// retry, so the pending state is correct — and still withholds the form.
    @MainActor
    func testUnknownAvailabilityBeforeAnyProbeStaysPendingWithoutOfferingRetry() {
        XCTAssertEqual(
            RequestFoodView.presentation(
                availability: .unknown,
                isCheckingAvailability: false,
                hasAttemptedAvailabilityCheck: false,
                didCreateRequest: false
            ),
            .checkingAvailability
        )
    }

    /// The defect this rule exists for: a probe that ended without an answer.
    /// `.unknown` with nothing running is a finished attempt, not a pending
    /// one, and must never render as an indefinite spinner.
    @MainActor
    func testSettledUnknownAvailabilityOffersRetryInsteadOfAnIndefiniteSpinner() {
        let presentation = RequestFoodView.presentation(
            availability: .unknown,
            isCheckingAvailability: false,
            hasAttemptedAvailabilityCheck: true,
            didCreateRequest: false
        )

        XCTAssertEqual(
            presentation,
            .unavailable(
                message: RequestFoodView.availabilityUnknownNotice,
                retryable: true
            )
        )
        XCTAssertNotEqual(presentation, .checkingAvailability)
        XCTAssertNotEqual(presentation, .form)
        // It says CommonPlate could not find out — not that posting is off, not
        // that the network is at fault, and not that anything is retrying.
        XCTAssertEqual(
            RequestFoodView.availabilityUnknownNotice,
            "We couldn’t check whether posting is available right now. Please try again in a moment."
        )
        XCTAssertNotEqual(RequestFoodView.availabilityUnknownNotice, RequestFoodView.pauseNotice)
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
            for isChecking in [true, false] {
                XCTAssertEqual(
                    RequestFoodView.presentation(
                        availability: availability,
                        isCheckingAvailability: isChecking,
                        hasAttemptedAvailabilityCheck: true,
                        didCreateRequest: true
                    ),
                    .success
                )
            }
        }
    }

    // MARK: - Availability probe state machine

    /// Entry probes once, and the screen shows the checking state only while
    /// that probe is genuinely running.
    func testEntryStartsOneProbeAndShowsCheckingOnlyWhileItRuns() async {
        let store = makeAvailabilityStore()
        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: publicActionsResponse(paused: false),
            gate: gate
        ))

        let probe = Task { await store.refreshRequestCreationAvailability() }
        await waitUntil { gate.isWaiting }

        XCTAssertTrue(store.isCheckingRequestCreationAvailability)
        XCTAssertTrue(store.hasAttemptedRequestCreationAvailabilityCheck)
        XCTAssertEqual(store.requestCreationAvailability, .unknown)
        XCTAssertEqual(presentation(for: store), .checkingAvailability)

        gate.open()
        await probe.value

        XCTAssertFalse(store.isCheckingRequestCreationAvailability)
        XCTAssertEqual(store.requestCreationAvailability, .available)
        XCTAssertEqual(presentation(for: store), .form)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/public-actions"]
        )
    }

    /// The exact race: a probe is cancelled by a screen exit, a re-entry's call
    /// is dropped because the first is still marked in flight, and the first
    /// then resolves back to `.unknown`. That used to strand the screen on a
    /// spinner with nothing running behind it.
    func testCancelledProbeAndReentryCannotStrandAnIndefiniteSpinner() async {
        let store = makeAvailabilityStore()
        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: publicActionsResponse(paused: false),
            gate: gate
        ))

        let probe = Task { await store.refreshRequestCreationAvailability() }
        await waitUntil { gate.isWaiting }

        probe.cancel()
        // The re-entering screen's task, arriving before the cancelled probe
        // has settled: it must not open a second connection.
        await store.refreshRequestCreationAvailability()
        gate.open()
        await probe.value

        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/public-actions"],
            "A dropped concurrent call must not duplicate the network request"
        )
        // Cancellation is not a backend verdict, so the state stays `.unknown`…
        XCTAssertEqual(store.requestCreationAvailability, .unknown)
        XCTAssertNotEqual(store.requestCreationAvailability, .unavailable)
        // …but nothing is running, and the attempt is on record, so the screen
        // settles into a retryable state instead of a permanent spinner.
        XCTAssertFalse(store.isCheckingRequestCreationAvailability)
        XCTAssertTrue(store.hasAttemptedRequestCreationAvailabilityCheck)
        XCTAssertEqual(
            presentation(for: store),
            .unavailable(
                message: RequestFoodView.availabilityUnknownNotice,
                retryable: true
            )
        )
        XCTAssertNotEqual(presentation(for: store), .checkingAvailability)
        XCTAssertNotEqual(presentation(for: store), .form)
    }

    /// Retry is the only recovery, and it has to actually probe again.
    func testRetryAfterAnUnresolvedProbeStartsANewProbeAndCanRevealTheForm() async {
        let store = makeAvailabilityStore()
        RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.refreshRequestCreationAvailability()

        XCTAssertEqual(store.requestCreationAvailability, .unavailable)
        XCTAssertEqual(
            presentation(for: store),
            .unavailable(
                message: RequestFoodView.availabilityUnknownNotice,
                retryable: true
            )
        )

        RequestFetchingURLProtocol.enqueue(.response(data: publicActionsResponse(paused: false)))
        await store.refreshRequestCreationAvailability()

        XCTAssertEqual(store.requestCreationAvailability, .available)
        XCTAssertEqual(presentation(for: store), .form)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/public-actions", "/api/public-actions"]
        )
    }

    /// Structured refusals and transport loss both land on the same truthful
    /// retryable state, and neither is ever mistaken for a confirmed pause.
    func testStructuredAndTransportFailuresBothReachTheRetryableState() async {
        let failures: [(String, RequestFetchingURLProtocol.Stub)] = [
            ("transport", .failure(.notConnectedToInternet)),
            ("structured", .response(
                statusCode: 500,
                data: Data(#"{"error":{"code":"INTERNAL_FAILURE","message":"boom"}}"#.utf8)
            ))
        ]

        for (label, stub) in failures {
            RequestFetchingURLProtocol.reset()
            let store = makeAvailabilityStore()
            RequestFetchingURLProtocol.enqueue(stub)

            await store.refreshRequestCreationAvailability()

            XCTAssertEqual(store.requestCreationAvailability, .unavailable, label)
            XCTAssertFalse(store.isCheckingRequestCreationAvailability, label)
            XCTAssertEqual(
                presentation(for: store),
                .unavailable(
                    message: RequestFoodView.availabilityUnknownNotice,
                    retryable: true
                ),
                label
            )
            XCTAssertNotEqual(presentation(for: store), .form, label)
        }
    }

    /// A confirmed pause is unchanged: locked sentence, no retry, no fields.
    func testConfirmedPauseKeepsItsExistingUnavailableBehavior() async {
        let store = makeAvailabilityStore()
        RequestFetchingURLProtocol.enqueue(.response(data: publicActionsResponse(paused: true)))

        await store.refreshRequestCreationAvailability()

        XCTAssertEqual(store.requestCreationAvailability, .paused)
        XCTAssertEqual(
            presentation(for: store),
            .unavailable(message: RequestFoodView.pauseNotice, retryable: false)
        )
        XCTAssertFalse(
            RequestFetchingURLProtocol.capturedRequestedPaths.contains("/api/request")
        )
    }

    /// Whatever the availability path does, it may never reveal the fields on
    /// anything but a confirmed available answer.
    func testFormIsWithheldUntilAvailabilityIsAffirmativelyConfirmed() async {
        let stubs: [RequestFetchingURLProtocol.Stub] = [
            .response(data: publicActionsResponse(paused: true)),
            .failure(.notConnectedToInternet),
            .response(data: Data(#"{"paused":"maybe"}"#.utf8))
        ]

        for stub in stubs {
            RequestFetchingURLProtocol.reset()
            let store = makeAvailabilityStore()
            RequestFetchingURLProtocol.enqueue(stub)

            await store.refreshRequestCreationAvailability()

            XCTAssertNotEqual(presentation(for: store), .form)
        }
    }

    private func presentation(for store: RequestStore) -> RequestFormPresentation {
        RequestFoodView.presentation(
            availability: store.requestCreationAvailability,
            isCheckingAvailability: store.isCheckingRequestCreationAvailability,
            hasAttemptedAvailabilityCheck: store.hasAttemptedRequestCreationAvailabilityCheck,
            didCreateRequest: false
        )
    }

    private func makeAvailabilityStore() -> RequestStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestStore(service: RequestService(client: client))
    }

    private func publicActionsResponse(paused: Bool) -> Data {
        Data(#"{"paused":\#(paused)}"#.utf8)
    }

    private func waitUntil(
        timeoutIterations: Int = 100,
        condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for condition")
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
