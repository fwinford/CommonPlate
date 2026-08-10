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
            timing: .later,
            preferredPickupTime: try date("2026-07-28T17:00:00.000Z")
        )

        var missingDiningSpot = complete
        missingDiningSpot.selectedDiningSpot = nil
        var missingFood = complete
        missingFood.foodRequest = "  "
        var missingPickupName = complete
        missingPickupName.pickupName = "\n"

        for draft in [missingDiningSpot, missingFood, missingPickupName] {
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
            timing: .asap,
            preferredPickupTime: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(RequestFoodView.isSubmissionEnabled(
            draft: draft,
            submissionError: nil,
            isCreating: false
        ))
    }

    func testInFlightAndExistingLifecycleBlockDisableRequestSubmission() {
        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
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

    func testInvalidFieldRemainsQuietDuringInitialTyping() {
        let errors = RequestFoodFormValidator.validate(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "",
            pickupName: "Taylor",
            timing: .asap,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        let presentation = RequestFoodValidationPresentation()

        XCTAssertEqual(errors.map(\.error), [.missingFood])
        XCTAssertTrue(presentation.visibleErrors(from: errors).isEmpty)
    }

    func testProductionFocusTransitionRevealsOnlyTheExitedInvalidRequestField() {
        let errors = RequestFoodFormValidator.validate(
            selectedDiningSpot: nil,
            foodRequest: "",
            pickupName: "",
            timing: .later,
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: true
        )
        var presentation = RequestFoodValidationPresentation()

        presentation.handleFocusTransition(
            from: .pickupName,
            to: .foodDescription,
            errors: errors
        )

        XCTAssertEqual(
            presentation.visibleErrors(from: errors).map(\.field),
            [.pickupName]
        )
    }

    func testRequestSubmitRejectsEveryErrorWithoutInvokingSubmission() async throws {
        let draft = RequestFoodFormDraft(
            selectedDiningSpot: nil,
            foodRequest: "",
            pickupName: "",
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
            timing: draft.timing,
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: true
        )
        let visible = result.presentation.visibleErrors(from: errors)

        XCTAssertEqual(submissionCount, 0)
        XCTAssertFalse(result.didSubmit)
        XCTAssertEqual(
            visible.map(\.field),
            [.diningSpot, .foodDescription, .pickupName, .pickupSchedule]
        )
        XCTAssertEqual(result.firstInvalidTextField, .foodDescription)
    }

    func testPresentedRequestErrorUpdatesLiveWhileNeverPresentedFieldsStayQuiet() {
        let initial = RequestFoodFormValidator.validate(
            selectedDiningSpot: nil,
            foodRequest: "",
            pickupName: "Taylor",
            timing: .asap,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        var presentation = RequestFoodValidationPresentation()
        presentation.handleFocusTransition(
            from: .foodDescription,
            to: nil,
            errors: initial
        )

        let corrected = RequestFoodFormValidator.validate(
            selectedDiningSpot: nil,
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            timing: .asap,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        XCTAssertTrue(presentation.visibleErrors(from: corrected).isEmpty)

        let invalidAgain = RequestFoodFormValidator.validate(
            selectedDiningSpot: nil,
            foodRequest: "",
            pickupName: "Taylor",
            timing: .asap,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        XCTAssertEqual(
            presentation.visibleErrors(from: invalidAgain).map(\.field),
            [.foodDescription],
            "Dining spot never presented an error, so it must stay quiet"
        )

        let emptied = RequestFoodFormValidator.validate(
            selectedDiningSpot: nil,
            foodRequest: "",
            pickupName: "Taylor",
            timing: .asap,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        XCTAssertEqual(
            presentation.visibleError(for: .foodDescription, from: emptied)?.message,
            "Tell us what food you need."
        )
    }

    func testPresentedDiningPickerErrorClearsAndReappearsWithSelection() {
        var draft = RequestFoodFormDraft(
            selectedDiningSpot: nil,
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            timing: .asap,
            preferredPickupTime: Date(timeIntervalSince1970: 0)
        )
        let initialErrors = RequestFoodFormValidator.validate(
            selectedDiningSpot: draft.selectedDiningSpot,
            foodRequest: draft.foodRequest,
            pickupName: draft.pickupName,
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
        XCTAssertEqual(payloads.first?.timing.rawValue, "scheduled")
        XCTAssertEqual(payloads.first?.windowStart, preferredTime)
    }

    func testRequestBackendFailurePreservesActualDraftAndTimingSelection() async throws {
        enum SimulatedBackendFailure: Error { case rejected }

        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: "140 E 14th St"),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
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
            timing: .later,
            // A start in the past: correctable, because a valid one still exists.
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: true
        )

        XCTAssertEqual(errors.map(\.field), [.pickupSchedule])
        XCTAssertEqual(errors.first?.error, .invalidScheduledTime)
        XCTAssertEqual(
            errors.first?.message,
            "Choose a pickup time later today."
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
            visible.message.contains("Choose a pickup time later today.")
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
            // The one remaining focusable rejection on this form.
            foodRequest: "   ",
            pickupName: "Taylor",
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
        XCTAssertEqual(result.firstInvalidTextField, .foodDescription)
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
            timing: .asap,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        var presentation = RequestFoodValidationPresentation()
        let submissionCount = 0

        presentation.handleFocusTransition(from: nil, to: .foodDescription, errors: errors)
        XCTAssertTrue(presentation.visibleErrors(from: errors).isEmpty)

        presentation.handleFocusTransition(from: .foodDescription, to: nil, errors: errors)
        XCTAssertEqual(presentation.visibleErrors(from: errors).map(\.field), [.foodDescription])
        XCTAssertEqual(submissionCount, 0)
    }

    func testASAPPayloadTrimsValuesAndOmitsWindowFields() throws {
        let payload = try RequestFoodView.makePayload(
            selectedDiningSpot: DiningSpot(name: "  Palladium  ", address: nil),
            foodRequest: "  Chicken bowl \n",
            pickupName: "  Taylor  ",
            timing: .asap,
            preferredPickupTime: Date(timeIntervalSince1970: 0),
            now: Date(timeIntervalSince1970: 1_000),
            calendar: utcCalendar
        )

        XCTAssertEqual(payload.vendor, "Palladium")
        XCTAssertEqual(payload.food, "Chicken bowl")
        XCTAssertEqual(payload.pickupName, "Taylor")
        XCTAssertEqual(payload.timing.rawValue, "asap")
        XCTAssertNil(payload.windowStart)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        XCTAssertFalse(json.keys.contains("windowStart"))
        XCTAssertFalse(json.keys.contains("windowEnd"))
    }

    /// The requester picks a start and nothing else. The backend derives the
    /// end from it, so the payload must carry no end at all — the create shape
    /// is strict and refuses one.
    func testScheduledPayloadSendsOnlyTheSelectedStart() throws {
        let now = try date("2026-07-28T16:00:00.000Z")
        let preferredTime = try date("2026-07-28T17:00:00.000Z")

        let payload = try RequestFoodView.makePayload(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            timing: .later,
            preferredPickupTime: preferredTime,
            now: now,
            calendar: utcCalendar
        )

        XCTAssertEqual(payload.timing.rawValue, "scheduled")
        XCTAssertEqual(payload.windowStart, preferredTime)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        XCTAssertTrue(json.keys.contains("windowStart"))
        XCTAssertFalse(json.keys.contains("windowEnd"))
    }

    func testLatestScheduledStartSitsAtTheDayBoundaryCutoff() throws {
        let now = try date("2026-07-28T16:00:00.000Z")
        let latestStart = try XCTUnwrap(
            RequestFoodView.latestScheduledStart(on: now, calendar: utcCalendar)
        )
        let dayEnd = try XCTUnwrap(
            RequestFoodView.endOfDay(containing: now, calendar: utcCalendar)
        )

        XCTAssertEqual(latestStart, try date("2026-07-28T23:30:00.000Z"))
        XCTAssertEqual(
            utcCalendar.dateComponents([.minute], from: latestStart, to: dayEnd).minute,
            RequestFoodView.scheduledStartCutoffMinutesBeforeDayEnd
        )
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
            timing: .later,
            isScheduledWindowValid: false,
            isScheduledTimingAvailable: true
        )
        var validationPresentation = RequestFoodValidationPresentation()
        validationPresentation.presentAll(errors)

        XCTAssertEqual(
            validationPresentation.visibleErrors(from: errors).map(\.field),
            [.diningSpot, .foodDescription, .pickupName, .pickupSchedule]
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

    // MARK: - Expiration copy

    /// Under the revised W3-R1 presentation contract the three-hour rule is
    /// explained once, at the timing choice
    /// (`RequestFoodView.formExpirationNotice`); the post-submit success
    /// screen no longer restates it under any name. Scoped to the
    /// `successView` declaration itself — not a whole-file symbol-name ban —
    /// so this guards the actual success-state presentation rather than a
    /// particular former property or function name, and would still catch a
    /// differently-named reintroduction of the same policy text.
    @MainActor
    func testSuccessViewDoesNotReintroduceTheExpirationPolicy() throws {
        let successViewSource = try successViewDeclarationSource()

        // The confirmation state itself is unchanged.
        XCTAssertTrue(successViewSource.contains(#"Text("Request posted")"#))
        XCTAssertTrue(successViewSource.contains(#"Button("Back to Home")"#))

        // No duration or expiration wording of any kind belongs on this
        // screen; that explanation lives solely at the timing choice.
        let lowercased = successViewSource.lowercased()
        for forbidden in ["hour", "expir", "visible to helpers"] {
            XCTAssertFalse(
                lowercased.contains(forbidden),
                "success view must not restate timing/expiration policy: found \"\(forbidden)\""
            )
        }
    }

    /// Extracts the `successView` computed property's own source text — from
    /// its declaration up to (not including) the next declaration,
    /// `requestForm` — so assertions about the success state cannot be
    /// satisfied or defeated by unrelated content elsewhere in the file.
    private func successViewDeclarationSource() throws -> String {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )

        let startMarker = "private var successView: some View {"
        let endMarker = "private var requestForm: some View {"

        guard let startRange = source.range(of: startMarker) else {
            XCTFail("expected to find \(startMarker)")
            return ""
        }
        guard let endRange = source.range(of: endMarker, range: startRange.upperBound..<source.endIndex) else {
            XCTFail("expected to find \(endMarker) after successView")
            return ""
        }

        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    /// A `201` proves the request was persisted, not that anyone will take it.
    @MainActor
    func testExpirationCopyPromisesNoFulfillment() {
        for timing in RequestTiming.allCases {
            let notice = RequestFoodView.formExpirationNotice(for: timing)
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

    /// The old form sentence — "Requests expire after a few hours" — matched
    /// neither backend rule and must not come back in any timing state.
    @MainActor
    func testNoVagueExpirationCopyRemains() {
        for timing in RequestTiming.allCases {
            let notice = RequestFoodView.formExpirationNotice(for: timing)
            let lowercased = notice.lowercased()
            XCTAssertFalse(lowercased.contains("a few hours"))
            XCTAssertFalse(lowercased.contains("automatically"))
        }
    }

    @MainActor
    func testFormExpirationCopyDistinguishesTheTwoBackendRules() {
        XCTAssertTrue(
            RequestFoodView.formExpirationNotice(for: .asap).contains("3 hours")
        )
        XCTAssertTrue(
            RequestFoodView.formExpirationNotice(for: .later)
                .contains("3 hours after the time you choose")
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
            .rateLimited,
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
            "Helpers will start seeing this request at this time, and for 3 hours after it."
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
                "a start is still selectable at \(value)"
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

    /// Past the latest possible start, no start remains before the
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
                "no start remains at \(value)"
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
                hasUnresolvedCreateAmbiguity: false,
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
            hasUnresolvedCreateAmbiguity: false,
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
            hasUnresolvedCreateAmbiguity: false,
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
                    hasUnresolvedCreateAmbiguity: false,
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
                hasUnresolvedCreateAmbiguity: false,
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
            hasUnresolvedCreateAmbiguity: false,
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
                        hasUnresolvedCreateAmbiguity: false,
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

    // MARK: - Process-lifetime ambiguous-create lock

    /// The lock exists because `POST /api/request` is not idempotent and
    /// carries no operation identity: once iOS cannot read the outcome, it can
    /// never learn whether the record exists, so no further create is safe.
    @MainActor
    func testIndeterminateCreateArmsTheProcessLifetimeGuard() async {
        let store = makeStore()
        enqueueIndeterminateCreateFailure()

        await assertCreateThrowsAmbiguity(store)

        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
        XCTAssertNotNil(store.unresolvedCreateError)
    }

    /// The defect this closes: `submissionError` is `@State`, so a form rebuilt
    /// after the ambiguous create came back with a nil error, a live Submit
    /// button, and no warning — even though the store would refuse the tap.
    @MainActor
    func testReopeningTheFormRestoresTheBlockingAmbiguityPresentation() async throws {
        let store = makeStore()
        enqueueIndeterminateCreateFailure()
        await assertCreateThrowsAmbiguity(store)

        // A brand-new view instance: no local error survived the teardown.
        let rebuiltViewError = RequestFoodView.effectiveSubmissionError(
            hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity,
            submissionError: nil
        )

        XCTAssertEqual(rebuiltViewError, .ambiguous)

        let presentation = try XCTUnwrap(
            RequestFoodView.submissionSectionPresentation(for: rebuiltViewError)
        )
        XCTAssertEqual(presentation.error, .ambiguous)
        XCTAssertEqual(
            presentation.message,
            "We couldn’t confirm whether your request was posted. Check Active Requests before submitting again."
        )
        // The only offered move is leaving, never a retry.
        XCTAssertTrue(presentation.showsReturnHomeAction)
    }

    @MainActor
    func testSubmitStaysDisabledForACompleteDraftWhileTheGuardExists() async throws {
        let store = makeStore()
        enqueueIndeterminateCreateFailure()
        await assertCreateThrowsAmbiguity(store)

        let completeDraft = try completeRequestDraft()
        // Without the guard this draft is submittable, so the assertion below
        // is about the guard rather than about missing input.
        XCTAssertTrue(RequestFoodView.isSubmissionEnabled(
            draft: completeDraft,
            submissionError: nil,
            isCreating: false
        ))

        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
            draft: completeDraft,
            submissionError: RequestFoodView.effectiveSubmissionError(
                hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity,
                submissionError: nil
            ),
            isCreating: false
        ))
    }

    /// The guard is a real refusal, not only a disabled button: even a caller
    /// that reaches the store directly sends nothing.
    @MainActor
    func testGuardedCreateSendsNoSecondPOST() async {
        let store = makeStore()
        enqueueIndeterminateCreateFailure()
        await assertCreateThrowsAmbiguity(store)

        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/request"]
        )

        // A stub that would confirm a create if the guard ever let one through.
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: createdRequestObject(id: "second"))
        ))

        await assertCreateThrowsAmbiguity(store)

        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/request"],
            "A guarded create must not reach the network at all"
        )
        XCTAssertTrue(store.requests.isEmpty)
    }

    /// Editing the draft or rebuilding the screen are ordinary local actions.
    /// Neither can resolve a question only the backend could answer.
    @MainActor
    func testDraftEditsAndViewRecreationDoNotClearTheGuard() async throws {
        let store = makeStore()
        enqueueIndeterminateCreateFailure()
        await assertCreateThrowsAmbiguity(store)

        var editedDraft = try completeRequestDraft()
        editedDraft.foodRequest = "A completely different meal"
        editedDraft.pickupName = "Someone Else"

        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(
            RequestFoodView.effectiveSubmissionError(
                hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity,
                submissionError: nil
            ),
            .ambiguous,
            "The guard is not scoped to the payload that raised it"
        )
        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
            draft: editedDraft,
            submissionError: RequestFoodView.effectiveSubmissionError(
                hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity,
                submissionError: nil
            ),
            isCreating: false
        ))
    }

    /// Deliberate limitation, recorded so it cannot be mistaken for a fix: the
    /// guard lives in this store only. A relaunch loses it. Durable
    /// reconciliation is Week 3 work and is a release blocker before external
    /// testing.
    @MainActor
    func testGuardIsProcessLocalAndIsNotPersisted() async {
        let store = makeStore()
        enqueueIndeterminateCreateFailure()
        await assertCreateThrowsAmbiguity(store)

        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
        XCTAssertFalse(
            makeStore().hasUnresolvedCreateAmbiguity,
            "Nothing persists the guard; a fresh store starts unguarded"
        )
    }

    // MARK: - Ambiguity outranks availability

    /// Every availability answer is a smaller fact than "your request may
    /// already exist". None of them changes what this student can do next, so
    /// none of them may take the screen.
    @MainActor
    func testBlockedPresentationWinsOverEveryAvailabilityState() {
        let availabilityStates: [(String, RequestCreationAvailability, Bool, Bool)] = [
            // label, availability, isChecking, hasAttempted
            ("unknown before any probe", .unknown, false, false),
            ("probe in flight", .unknown, true, true),
            ("settled unknown", .unknown, false, true),
            ("confirmed unavailable", .unavailable, false, true),
            ("paused", .paused, false, true),
            ("available", .available, false, true)
        ]

        for (label, availability, isChecking, hasAttempted) in availabilityStates {
            XCTAssertEqual(
                RequestFoodView.presentation(
                    hasUnresolvedCreateAmbiguity: true,
                    availability: availability,
                    isCheckingAvailability: isChecking,
                    hasAttemptedAvailabilityCheck: hasAttempted,
                    didCreateRequest: false
                ),
                .blockedByUnresolvedCreateAmbiguity,
                "\(label) must not replace the ambiguity warning"
            )
        }
    }

    /// The blocked screen is not the form with a message on it. There is
    /// nothing to correct and nothing to resend, so no field or submit control
    /// may exist to suggest otherwise.
    @MainActor
    func testBlockedStateNeverExposesTheRequestForm() async {
        let store = makeStore()

        // Reach the one availability answer that normally reveals the form,
        // through the real probe, *before* arming the guard — so the block is
        // demonstrably overriding `.available` rather than an absent answer.
        RequestFetchingURLProtocol.enqueue(.response(
            data: publicActionsResponse(paused: false)
        ))
        await store.refreshRequestCreationAvailability()
        XCTAssertEqual(presentation(for: store), .form)

        enqueueIndeterminateCreateFailure()
        await assertCreateThrowsAmbiguity(store)

        XCTAssertEqual(store.requestCreationAvailability, .available)
        XCTAssertEqual(
            presentation(for: store),
            .blockedByUnresolvedCreateAmbiguity
        )
        XCTAssertNotEqual(presentation(for: store), .form)
    }

    /// The blocked screen takes its words and its one action from the same seam
    /// the in-form error row uses, so a change to either cannot leave them
    /// describing one situation two ways.
    @MainActor
    func testBlockedPresentationReusesTheOriginalAmbiguityCopyAndAction() throws {
        let presentation = try XCTUnwrap(
            RequestFoodView.submissionSectionPresentation(for: .ambiguous)
        )

        XCTAssertEqual(presentation.error, .ambiguous)
        XCTAssertEqual(
            presentation.message,
            "We couldn’t confirm whether your request was posted. Check Active Requests before submitting again."
        )
        XCTAssertTrue(presentation.showsReturnHomeAction)
    }

    /// Re-entry must not spend a request on an answer the screen cannot use.
    /// This drives the production `.task` decision rather than restating it.
    @MainActor
    func testBlockedReentryStartsNoAvailabilityProbe() async {
        let store = makeStore()
        enqueueIndeterminateCreateFailure()
        await assertCreateThrowsAmbiguity(store)

        XCTAssertFalse(RequestFoodView.shouldProbeAvailability(
            hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity
        ))

        // The body of the screen's `.task`, run exactly as production does.
        if RequestFoodView.shouldProbeAvailability(
            hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity
        ) {
            await store.refreshRequestCreationAvailability()
        }

        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/request"],
            "A blocked screen must not probe availability"
        )
        XCTAssertFalse(
            RequestFetchingURLProtocol.capturedRequestedPaths
                .contains("/api/public-actions")
        )
    }

    /// The block is the only thing suppressed here. A store that never saw an
    /// ambiguous create keeps the whole normal availability flow, probe
    /// included.
    @MainActor
    func testUnguardedStoreKeepsTheNormalAvailabilityFlow() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(
            data: publicActionsResponse(paused: false)
        ))

        XCTAssertTrue(RequestFoodView.shouldProbeAvailability(
            hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity
        ))

        if RequestFoodView.shouldProbeAvailability(
            hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity
        ) {
            await store.refreshRequestCreationAvailability()
        }

        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/public-actions"]
        )
        XCTAssertEqual(presentation(for: store), .form)
    }

    /// Blocked means blocked: no create POST escapes through the new screen.
    @MainActor
    func testBlockedScreenSendsNoSecondCreatePOST() async {
        let store = makeStore()
        enqueueIndeterminateCreateFailure()
        await assertCreateThrowsAmbiguity(store)

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: createdRequestObject(id: "escaped"))
        ))
        await assertCreateThrowsAmbiguity(store)

        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/request"]
        )
        XCTAssertTrue(store.requests.isEmpty)
    }

    /// Still deliberately not durable. A destroyed store starts clean and runs
    /// the ordinary availability flow — see the Week 3 reconciliation deferral.
    @MainActor
    func testDestroyingTheStoreLosesTheBlockWithoutPersistence() async {
        let store = makeStore()
        enqueueIndeterminateCreateFailure()
        await assertCreateThrowsAmbiguity(store)
        XCTAssertEqual(presentation(for: store), .blockedByUnresolvedCreateAmbiguity)

        let replacement = makeStore()

        XCTAssertFalse(replacement.hasUnresolvedCreateAmbiguity)
        XCTAssertNotEqual(
            presentation(for: replacement),
            .blockedByUnresolvedCreateAmbiguity
        )
        XCTAssertTrue(RequestFoodView.shouldProbeAvailability(
            hasUnresolvedCreateAmbiguity: replacement.hasUnresolvedCreateAmbiguity
        ))
    }

    // MARK: - Definitive create refusals never arm the guard

    /// The throttle refuses ahead of validation, the write, and every side
    /// effect, so it proves nothing was created. Reporting it as ambiguous
    /// would turn a sixth tap inside one minute into a permanent lockout.
    @MainActor
    func testRateLimitedCreateIsDefinitiveAndLeavesTheGuardUnset() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 429,
            data: Data(#"""
            {"error":{"code":"RATE_LIMITED","message":"Too many attempts. Please wait a moment and try again.","fields":null}}
            """#.utf8)
        ))

        do {
            try await store.createRequest(makeCreatePayload())
            XCTFail("A throttled create must be refused")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, "RATE_LIMITED")
        } catch {
            XCTFail("Unexpected create error: \(error)")
        }

        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertNil(store.unresolvedCreateError)

        let presented = RequestCreatePresentationError.map(
            RequestServiceError.serverError(code: "RATE_LIMITED", message: "Too many attempts.")
        )
        XCTAssertEqual(presented, .rateLimited)
        XCTAssertEqual(
            presented.message,
            "Too many attempts. Please wait a moment and try again."
        )
        // Recoverable in place: the student waits and submits the same request.
        XCTAssertTrue(RequestFoodView.allowsSubmission(after: presented))
        XCTAssertFalse(RequestFoodView.showsReturnHomeAction(for: presented))
    }

    /// A bare 404 means this route does not exist at this base URL — a
    /// misconfigured host or an unmounted route. Nothing was created, so it must
    /// not claim the request may already exist.
    @MainActor
    func testBareNotFoundIsDefinitiveAndPermitsAnotherAttempt() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 404,
            data: Data("<html>Cannot POST /api/request</html>".utf8)
        ))

        do {
            try await store.createRequest(makeCreatePayload())
            XCTFail("A 404 create must be refused")
        } catch RequestServiceError.notFound {
            // Expected.
        } catch {
            XCTFail("Unexpected create error: \(error)")
        }

        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertNil(store.unresolvedCreateError)

        let presented = RequestCreatePresentationError.map(RequestServiceError.notFound)
        XCTAssertNotEqual(presented, .ambiguous)
        XCTAssertTrue(RequestFoodView.allowsSubmission(after: presented))

        // Unblocked: the next attempt genuinely reaches the network, and this
        // one is confirmed rather than retried automatically.
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: createdRequestObject(id: "after-404"))
        ))
        try? await store.createRequest(makeCreatePayload())

        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/request", "/api/request"]
        )
        XCTAssertEqual(store.requests.map(\.id), ["after-404"])
    }

    // MARK: - Genuine indeterminacy stays ambiguous

    /// Being an error is not proof of a rollback. Each of these leaves the
    /// backend's write status genuinely unknown, so each arms the guard — and
    /// each sends exactly one POST.
    @MainActor
    func testIndeterminateFailuresStayAmbiguousWithExactlyOnePOST() async {
        let cases: [(String, RequestFetchingURLProtocol.Stub)] = [
            ("timeout", .failure(.timedOut)),
            ("transport loss", .failure(.networkConnectionLost)),
            (
                "undecodable 5xx",
                .response(statusCode: 502, data: Data("Bad Gateway".utf8))
            ),
            (
                "undecodable success body",
                .response(statusCode: 201, data: Data("{".utf8))
            )
        ]

        for (label, stub) in cases {
            RequestFetchingURLProtocol.reset()
            let store = makeStore()
            RequestFetchingURLProtocol.enqueue(stub)

            do {
                try await store.createRequest(makeCreatePayload())
                XCTFail("\(label) cannot confirm creation")
            } catch RequestServiceError.ambiguousCreateOutcome {
                // Expected.
            } catch {
                XCTFail("Unexpected error for \(label): \(error)")
            }

            XCTAssertTrue(
                store.hasUnresolvedCreateAmbiguity,
                "\(label) must arm the process-lifetime guard"
            )
            XCTAssertEqual(
                RequestFetchingURLProtocol.capturedRequestedPaths,
                ["/api/request"],
                "\(label) must send exactly one POST and never retry"
            )
            XCTAssertTrue(store.requests.isEmpty)
        }
    }

    // MARK: - ASAP wording

    /// Under the revised W3-R1 presentation contract the backend's concise
    /// `"ASAP"` label carries no duration of its own — the three-hour rule is
    /// explained once, at the timing choice, not restated on every surface
    /// that renders the label. This proves iOS preserves whatever backend
    /// value it is given verbatim, and that the superseded phrasings — "within
    /// the next hour" and "within the next 5 hours" — do not reappear.
    @MainActor
    func testASAPWindowTextPreservesTheBackendProvidedLabel() async throws {
        let asapWindowText = "ASAP"

        let request = try await decodedCreatedRequest(
            createResponse(requestObject: createdRequestObject(
                id: "asap",
                pickupWindowText: asapWindowText
            ))
        )
        XCTAssertEqual(request.pickupWindowText, asapWindowText)
        XCTAssertFalse(request.pickupWindowText.contains("within the next hour"))
        XCTAssertFalse(request.pickupWindowText.contains("within the next 5 hours"))

        // The timing-choice form still explains the same three-hour rule the
        // backend enforces; the helper-facing label itself no longer needs to
        // restate it.
        XCTAssertTrue(
            RequestFoodView.formExpirationNotice(for: .asap).contains("3 hours")
        )
    }

    // MARK: - Ambiguity helpers

    private func enqueueIndeterminateCreateFailure() {
        RequestFetchingURLProtocol.enqueue(.failure(.timedOut))
    }

    @MainActor
    private func assertCreateThrowsAmbiguity(
        _ store: RequestStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await store.createRequest(makeCreatePayload())
            XCTFail("Expected an ambiguous create refusal", file: file, line: line)
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        } catch {
            XCTFail("Unexpected create error: \(error)", file: file, line: line)
        }
    }

    private func completeRequestDraft() throws -> RequestFoodFormDraft {
        RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "Chicken bowl",
            pickupName: "Taylor",
            timing: .asap,
            preferredPickupTime: try date("2026-07-28T17:00:00.000Z")
        )
    }

    private func makeCreatePayload() -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Palladium",
            food: "Chicken bowl",
            pickupName: "Taylor",
            timing: .asap,
            windowStart: nil
        )
    }

    private func createResponse(requestObject: String) -> Data {
        Data(#"{"request":\#(requestObject)}"#.utf8)
    }

    private func createdRequestObject(
        id: String,
        pickupWindowText: String = "ASAP"
    ) -> String {
        """
        {
          "id": "\(id)",
          "vendor": "Palladium",
          "food": "Chicken bowl",
          "pickupWindowText": "\(pickupWindowText)",
          "windowStart": null,
          "windowEnd": null,
          "status": "open",
          "createdAt": "2026-07-28T16:00:00.000Z",
          "expiresAt": "2026-07-28T19:00:00.000Z"
        }
        """
    }

    @MainActor
    private func decodedCreatedRequest(_ data: Data) async throws -> FoodRequest {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 201, data: data))
        try await store.createRequest(makeCreatePayload())
        return try XCTUnwrap(store.requests.first)
    }

    /// Mirrors the production call exactly, guard included, so the availability
    /// tests exercise the same precedence the screen applies.
    private func presentation(for store: RequestStore) -> RequestFormPresentation {
        RequestFoodView.presentation(
            hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity,
            availability: store.requestCreationAvailability,
            isCheckingAvailability: store.isCheckingRequestCreationAvailability,
            hasAttemptedAvailabilityCheck: store.hasAttemptedRequestCreationAvailabilityCheck,
            didCreateRequest: false
        )
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
            installationCredentialProvider: { "test-installation-credential" },
            // W3-I1: a verified participant, unless a case says otherwise.
            participantAuthorityProvider: { "64c0000000000000000000a1.1.test-credential" },
            participantAuthorityRejected: {}
        )
    }

    private func makeAvailabilityStore() -> RequestStore {
        makeStore()
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
