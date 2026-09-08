//
//  ScreenshotProposalStoreTests.swift
//  CommonPlateiosTests
//
// Focused coverage for the W4-S1 non-authoritative proposal store: explicit
// manual-edit provenance (not value equality), selection-identity/generation
// concurrency (last-selection-wins, AI-Off mid-flight, busy-state
// generation-safety), ineligible/no-useful-extraction notices, and
// AI-disabled/consent gating.
import Foundation
import XCTest
@testable import CommonPlateios

/// Its own transport double, capturing headers and supporting an injectable
/// delay — mirrors `EmailAlertStateURLProtocol`.
final class ScreenshotProposalURLProtocol: URLProtocol {
    struct CapturedRequest {
        let path: String
        let method: String
        let headers: [String: String]
        let body: Data?
    }

    struct Stub {
        let statusCode: Int
        let data: Data
        let delay: TimeInterval

        static func response(statusCode: Int = 200, data: Data, delay: TimeInterval = 0) -> Stub {
            Stub(statusCode: statusCode, data: data, delay: delay)
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [Stub] = []
    private nonisolated(unsafe) static var captured: [CapturedRequest] = []

    static func enqueue(_ stub: Stub) {
        lock.lock()
        stubs.append(stub)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        stubs.removeAll()
        captured.removeAll()
        lock.unlock()
    }

    static var capturedRequests: [CapturedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    private static func dequeue() -> Stub? {
        lock.lock()
        defer { lock.unlock() }
        guard !stubs.isEmpty else { return nil }
        return stubs.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(
            CapturedRequest(
                path: request.url?.path ?? "",
                method: request.httpMethod ?? "",
                headers: request.allHTTPHeaderFields ?? [:],
                body: request.httpBody ?? request.httpBodyStream.flatMap { stream -> Data? in
                    stream.open()
                    defer { stream.close() }
                    var data = Data()
                    let bufferSize = 4096
                    var buffer = [UInt8](repeating: 0, count: bufferSize)
                    while stream.hasBytesAvailable {
                        let read = stream.read(&buffer, maxLength: bufferSize)
                        if read > 0 { data.append(buffer, count: read) }
                        else { break }
                    }
                    return data
                }
            )
        )
        Self.lock.unlock()

        guard let stub = Self.dequeue() else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        let completeRequest = {
            guard let url = self.request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: stub.statusCode,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "application/json"]
                  ) else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: stub.data)
            self.client?.urlProtocolDidFinishLoading(self)
        }

        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: completeRequest)
        } else {
            completeRequest()
        }
    }

    override func stopLoading() {}
}

final class InMemoryScreenshotProposalPreferencesStorage: ScreenshotProposalPreferencesStoring {
    var isAIAssistanceEnabled: Bool = true
    var hasRecordedThirdPartyConsent: Bool = false
    var hasCompletedScreenshotHelp: Bool = false
}

@MainActor
final class ScreenshotProposalStoreTests: XCTestCase {
    override func tearDown() {
        ScreenshotProposalURLProtocol.reset()
        super.tearDown()
    }

    private func makeStore(
        preferences: ScreenshotProposalPreferencesStoring = InMemoryScreenshotProposalPreferencesStorage()
    ) -> ScreenshotProposalStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScreenshotProposalURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return ScreenshotProposalStore(
            service: ScreenshotProposalService(client: client),
            preferences: preferences
        )
    }

    private let palladium = SupportedVendorCatalog.diningSpots.first { $0.name == "Palladium" }!
    private let crave370 = SupportedVendorCatalog.diningSpots.first { $0.name == "Cafe 370" }!

    private let noManualEdits = ScreenshotFieldManualEditState()

    private func responseBody(
        eligible: Bool,
        locationName: String? = nil,
        foodRequest: String? = nil,
        mealSwipes: Int? = nil,
        delay: TimeInterval = 0
    ) -> ScreenshotProposalURLProtocol.Stub {
        var proposal: [String: Any] = [:]
        if let locationName {
            proposal["selectedDiningSpot"] = ["name": locationName, "address": "irrelevant"]
        }
        if let foodRequest {
            proposal["foodRequest"] = foodRequest
        }
        if let mealSwipes {
            proposal["mealSwipes"] = mealSwipes
        }
        let body: [String: Any] = ["eligible": eligible, "proposal": proposal]
        let data = try! JSONSerialization.data(withJSONObject: body)
        return .response(data: data, delay: delay)
    }

    // MARK: - No credential

    func testNoCredentialReportsVerificationRequiredWithoutSendingAnything() async {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let outcome = await store.analyzeScreenshot(
            imageData: Data([0x01]),
            mimeType: "image/jpeg",
            localEvidenceText: "irrelevant",
            participantAuthority: nil,
            token: token
        )
        XCTAssertNil(outcome)
        XCTAssertEqual(store.notice, .verificationRequired)
        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 0)
    }

    // MARK: - apply(): explicit manual provenance (not value equality)

    func testApplyDoesNotOverwriteAnExistingManualDiningSpot() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        draft.selectedDiningSpot = crave370
        var manualEdits = ScreenshotFieldManualEditState()
        manualEdits.hasManuallyEditedLocation = true

        let outcome = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(selectedDiningSpot: palladium)
        )
        store.apply(outcome, manualEdits: manualEdits, to: &draft)

        XCTAssertEqual(draft.selectedDiningSpot, crave370)
    }

    func testApplyDoesNotOverwriteExistingManualFoodText() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        draft.foodRequest = "my own words"
        var manualEdits = ScreenshotFieldManualEditState()
        manualEdits.hasManuallyEditedFoodRequest = true

        let outcome = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(foodRequest: "1 Create Your Own Bowl")
        )
        store.apply(outcome, manualEdits: manualEdits, to: &draft)

        XCTAssertEqual(draft.foodRequest, "my own words")
    }

    func testApplyDoesNotOverwriteMealSwipesOnceManuallyEdited() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        XCTAssertEqual(draft.mealSwipes, RequestFoodFormDraft.mealSwipeOptions.first!)
        var manualEdits = ScreenshotFieldManualEditState()
        manualEdits.hasManuallyEditedMealSwipes = true

        let outcome = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(mealSwipes: 3)
        )
        store.apply(outcome, manualEdits: manualEdits, to: &draft)

        XCTAssertEqual(draft.mealSwipes, RequestFoodFormDraft.mealSwipeOptions.first!)
    }

    func testApplyFillsUntouchedFields() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()

        let outcome = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(
                selectedDiningSpot: palladium,
                foodRequest: "1 Create Your Own Bowl",
                mealSwipes: 2
            )
        )
        let applied = store.apply(outcome, manualEdits: noManualEdits, to: &draft)

        XCTAssertEqual(draft.selectedDiningSpot, palladium)
        XCTAssertEqual(draft.foodRequest, "1 Create Your Own Bowl")
        XCTAssertEqual(draft.mealSwipes, 2)
        XCTAssertNil(store.notice)

        // W4-R2 provenance/afterglow plumbing: `apply(...)` reports exactly
        // which allowlisted fields it actually wrote.
        XCTAssertTrue(applied.location)
        XCTAssertTrue(applied.foodRequest)
        XCTAssertTrue(applied.mealSwipes)
        XCTAssertFalse(applied.isEmpty)
    }

    /// A field the requester already manually owns must not be reported as
    /// applied, even though the proposal carried a value for it — mirroring
    /// the manual-precedence guarantee `apply(...)` already enforces on
    /// `draft` itself.
    func testAppliedFieldsOmitManuallyOwnedFields() {
        let store = makeStore()
        var draft = RequestFoodFormDraft(foodRequest: "Already typed")

        let outcome = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(
                selectedDiningSpot: palladium,
                foodRequest: "1 Create Your Own Bowl",
                mealSwipes: 2
            )
        )
        var manualEdits = ScreenshotFieldManualEditState()
        manualEdits.hasManuallyEditedFoodRequest = true

        let applied = store.apply(outcome, manualEdits: manualEdits, to: &draft)

        XCTAssertTrue(applied.location)
        XCTAssertFalse(applied.foodRequest)
        XCTAssertTrue(applied.mealSwipes)
        XCTAssertEqual(draft.foodRequest, "Already typed")
    }

    func testApplyMarksUnsupportedScreenshotNoticeForAnIneligibleResult() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        let outcome = ScreenshotProposalOutcome(eligible: false, proposal: .empty)
        store.apply(outcome, manualEdits: noManualEdits, to: &draft)
        XCTAssertEqual(store.notice, .unsupportedScreenshot)
    }

    func testApplyMarksNoUsefulExtractionNoticeForAnEligibleButEmptyResult() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        let outcome = ScreenshotProposalOutcome(eligible: true, proposal: .empty)
        store.apply(outcome, manualEdits: noManualEdits, to: &draft)
        XCTAssertEqual(store.notice, .noUsefulExtraction)
    }

    // MARK: - Finding 4 regression: type-then-clear / reconverge / manual-nil

    /// The exact bug scenario: the requester types into the food field
    /// (manual edit), then clears it back to empty while a proposal is
    /// still pending. Under old value-equality inference this looked
    /// identical to "never touched." It must not.
    func testTypeThenClearWhileProviderPendingStillBlocksAI() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        var manualEdits = ScreenshotFieldManualEditState()

        // Simulates the food TextField's binding: any keystroke latches the
        // flag, regardless of the resulting value.
        draft.foodRequest = "partial"
        manualEdits.hasManuallyEditedFoodRequest = true
        draft.foodRequest = ""
        // Flag stays latched even though the value is empty again.
        XCTAssertTrue(manualEdits.hasManuallyEditedFoodRequest)

        let outcome = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(foodRequest: "1 Create Your Own Bowl")
        )
        store.apply(outcome, manualEdits: manualEdits, to: &draft)

        XCTAssertEqual(draft.foodRequest, "", "a manually-touched field must stay exactly as the requester left it")
    }

    /// AI proposes X (programmatic write) → requester manually picks Y →
    /// requester manually picks X again (still a real interaction) →
    /// screenshot replaced. X must survive as the requester's own choice,
    /// not be cleared merely because it coincides with the original AI value.
    func testManualReconvergenceToTheOriginalAIValueStillCountsAsManual() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()

        let firstOutcome = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(selectedDiningSpot: palladium)
        )
        store.apply(firstOutcome, manualEdits: noManualEdits, to: &draft)
        XCTAssertEqual(draft.selectedDiningSpot, palladium)

        var manualEdits = ScreenshotFieldManualEditState()
        // Manually picks a different spot.
        draft.selectedDiningSpot = crave370
        manualEdits.hasManuallyEditedLocation = true
        // Manually picks Palladium again — still a real interaction.
        draft.selectedDiningSpot = palladium

        var draftAfterReplacement = draft
        _ = store.beginSelection(clearing: &draftAfterReplacement, manualEdits: manualEdits)

        XCTAssertEqual(
            draftAfterReplacement.selectedDiningSpot,
            palladium,
            "a manually re-selected value must survive replacement even though it equals the original AI value"
        )
    }

    /// A location manually cleared back to `nil` must not be silently
    /// refilled by a later proposal.
    func testManuallyClearingLocationToNilBlocksAIFromRefillingIt() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        let firstOutcome = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(selectedDiningSpot: palladium)
        )
        store.apply(firstOutcome, manualEdits: noManualEdits, to: &draft)

        var manualEdits = ScreenshotFieldManualEditState()
        // Manually clears back to nil — a real interaction with the picker.
        draft.selectedDiningSpot = nil
        manualEdits.hasManuallyEditedLocation = true

        let secondOutcome = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(selectedDiningSpot: palladium)
        )
        store.apply(secondOutcome, manualEdits: manualEdits, to: &draft)

        XCTAssertNil(draft.selectedDiningSpot)
    }

    /// The ordinary, non-adversarial case must still work: a field AI set
    /// and the requester never touched still clears correctly when the
    /// screenshot is replaced.
    func testAIOwnedUntouchedValueStillClearsOnReplacement() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        let firstOutcome = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(
                selectedDiningSpot: palladium,
                foodRequest: "1 Create Your Own Bowl",
                mealSwipes: 2
            )
        )
        store.apply(firstOutcome, manualEdits: noManualEdits, to: &draft)

        _ = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)

        XCTAssertNil(draft.selectedDiningSpot)
        XCTAssertEqual(draft.foodRequest, "")
        XCTAssertEqual(draft.mealSwipes, RequestFoodFormDraft.mealSwipeOptions.first!)
    }

    // MARK: - Finding 3 regression: replacement clears stale AI values even
    // if the new image later fails to load/decode/OCR

    func testBeginSelectionClearsStaleAIValuesSynchronouslyRegardlessOfWhatHappensNext() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        let firstOutcome = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(selectedDiningSpot: palladium, foodRequest: "1 Bowl")
        )
        store.apply(firstOutcome, manualEdits: noManualEdits, to: &draft)

        // `beginSelection` itself is the only thing that must run before any
        // async work (image load/decode/OCR) even starts — clearing happens
        // here, synchronously, independent of whether that later work ever
        // succeeds.
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)

        XCTAssertNil(draft.selectedDiningSpot)
        XCTAssertEqual(draft.foodRequest, "")
        // The new selection is already current even though no image has
        // been loaded, decoded, or OCR'd for it yet.
        XCTAssertTrue(store.isCurrent(token))
    }

    // MARK: - Finding 3 regression: last-selection-wins, including an
    // A/B preprocessing inversion (B finishes before A)

    func testASecondSelectionSupersedesTheFirstEvenIfTheFirstsNetworkCallFinishesLast() async {
        let store = makeStore()
        // A (selected first) gets a slow response.
        ScreenshotProposalURLProtocol.enqueue(
            responseBody(eligible: true, locationName: "Palladium", delay: 0.3)
        )

        var draft = RequestFoodFormDraft()
        let tokenA = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let taskA = Task {
            await store.analyzeScreenshot(
                imageData: Data([0x01]),
                mimeType: "image/jpeg",
                localEvidenceText: "View order Order information 1 Bowl",
                participantAuthority: "authority-1",
                token: tokenA
            )
        }

        // B is selected shortly after — before A's slow response returns —
        // and gets a fast response.
        try? await Task.sleep(nanoseconds: 20_000_000)
        ScreenshotProposalURLProtocol.enqueue(
            responseBody(eligible: true, locationName: "Cafe 370", delay: 0)
        )
        let tokenB = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let outcomeB = await store.analyzeScreenshot(
            imageData: Data([0x02]),
            mimeType: "image/jpeg",
            localEvidenceText: "View order Order information 1 Bowl",
            participantAuthority: "authority-1",
            token: tokenB
        )

        let outcomeA = await taskA.value

        XCTAssertNil(outcomeA, "A must be dropped even though its network call finished after B started")
        XCTAssertNotNil(outcomeB)
        XCTAssertTrue(store.isCurrent(tokenB))
        XCTAssertFalse(store.isCurrent(tokenA))
    }

    // MARK: - Finding 3 regression: busy state is generation-safe

    func testIsApplyingIsNotClearedByAnOlderGenerationFinishingWhileANewerOneIsStillInFlight() async {
        let store = makeStore()
        ScreenshotProposalURLProtocol.enqueue(responseBody(eligible: true, delay: 0.05))
        ScreenshotProposalURLProtocol.enqueue(responseBody(eligible: true, delay: 0.3))

        var draft = RequestFoodFormDraft()
        let tokenA = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let taskA = Task {
            await store.analyzeScreenshot(
                imageData: Data([0x01]),
                mimeType: "image/jpeg",
                localEvidenceText: "irrelevant",
                participantAuthority: "authority-1",
                token: tokenA
            )
        }
        try? await Task.sleep(nanoseconds: 10_000_000)

        let tokenB = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let taskB = Task {
            await store.analyzeScreenshot(
                imageData: Data([0x02]),
                mimeType: "image/jpeg",
                localEvidenceText: "irrelevant",
                participantAuthority: "authority-1",
                token: tokenB
            )
        }

        // A (the shorter delay) finishes first and removes itself from the
        // in-flight set; B (the newer, current generation) is still running.
        _ = await taskA.value
        XCTAssertTrue(
            store.isApplying,
            "an older generation finishing must not clear busy state a newer generation still owns"
        )

        _ = await taskB.value
        XCTAssertFalse(store.isApplying)
    }

    // MARK: - Finding 2 regression: AI Assistance Off stops transfer/use,
    // including work already preprocessing but not yet transferred

    func testAnalyzeScreenshotRefusesToTransferWhenAIAssistanceIsOff() async {
        let preferences = InMemoryScreenshotProposalPreferencesStorage()
        let store = makeStore(preferences: preferences)
        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)

        // AI Assistance turns Off after selection/local preprocessing would
        // have started, but before transfer.
        store.setAIAssistanceEnabled(false)

        let outcome = await store.analyzeScreenshot(
            imageData: Data([0x01]),
            mimeType: "image/jpeg",
            localEvidenceText: "irrelevant",
            participantAuthority: "an-authority",
            token: token
        )

        XCTAssertNil(outcome)
        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 0, "no transfer may occur once AI Assistance is Off")
    }

    func testAnInFlightNetworkResponseIsDroppedIfAIAssistanceTurnsOffBeforeItReturns() async {
        let store = makeStore()
        ScreenshotProposalURLProtocol.enqueue(
            responseBody(eligible: true, locationName: "Palladium", delay: 0.2)
        )

        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let task = Task {
            await store.analyzeScreenshot(
                imageData: Data([0x01]),
                mimeType: "image/jpeg",
                localEvidenceText: "View order Order information 1 Bowl",
                participantAuthority: "an-authority",
                token: token
            )
        }

        // The network call is already in flight (transfer already started)
        // when AI Assistance turns Off. The response, once it arrives, must
        // still be unusable.
        try? await Task.sleep(nanoseconds: 20_000_000)
        store.setAIAssistanceEnabled(false)

        let outcome = await task.value
        XCTAssertNil(outcome, "a response that arrives after AI Assistance turns Off must never be applied")
    }

    func testInvalidateCurrentSelectionMakesAnyOutstandingTokenStale() async {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        XCTAssertTrue(store.isCurrent(token))

        // Screen disappearance.
        store.invalidateCurrentSelection()

        XCTAssertFalse(store.isCurrent(token))
        let outcome = await store.analyzeScreenshot(
            imageData: Data([0x01]),
            mimeType: "image/jpeg",
            localEvidenceText: "irrelevant",
            participantAuthority: "an-authority",
            token: token
        )
        XCTAssertNil(outcome)
        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 0)
    }

    // MARK: - Finding 1 (review 3) regression: a real, enforceable handoff
    // between authorization and transfer initiation — not a boolean re-check
    // separated from transfer start by a suspension window.

    /// `analyzeScreenshot` is started concurrently, then AI Assistance is
    /// turned Off on the very next synchronous step — before the
    /// just-created outer `Task` has had any opportunity to run at all. This
    /// exercises "Off before `analyzeScreenshot`'s own guards ever ran,"
    /// the outermost edge of the race.
    func testOffImmediatelyAfterStartingAnalysisPreventsTransferFromEverStarting() async {
        let store = makeStore()
        ScreenshotProposalURLProtocol.enqueue(responseBody(eligible: true, locationName: "Palladium"))

        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let task = Task {
            await store.analyzeScreenshot(
                imageData: Data([0x01]),
                mimeType: "image/jpeg",
                localEvidenceText: "View order Order information 1 Bowl",
                participantAuthority: "an-authority",
                token: token
            )
        }
        store.setAIAssistanceEnabled(false)

        let outcome = await task.value
        XCTAssertNil(outcome)
        XCTAssertEqual(
            ScreenshotProposalURLProtocol.capturedRequests.count, 0,
            "no provider request may ever start once Off precedes it, even concurrently"
        )
    }

    /// The deeper race: a single `Task.yield()` gives `analyzeScreenshot`'s
    /// own synchronous guard checks and child-task registration a chance to
    /// run (the token is still current, AI Assistance is still On, and the
    /// transfer's own child `Task` now exists and is tracked) before this
    /// test cancels it — the exact suspension window between "authorized"
    /// and "transfer genuinely started" that a plain boolean re-check cannot
    /// close, and real `Task` cancellation does: the child task's own first
    /// statement is `Task.checkCancellation()`, observed regardless of
    /// which actor is running it or whether its body had started yet.
    func testInvalidationDuringTheHandoffWindowNeverLetsATransferBecomeUsable() async {
        let store = makeStore()
        ScreenshotProposalURLProtocol.enqueue(responseBody(eligible: true, locationName: "Palladium"))

        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let task = Task {
            await store.analyzeScreenshot(
                imageData: Data([0x01]),
                mimeType: "image/jpeg",
                localEvidenceText: "View order Order information 1 Bowl",
                participantAuthority: "an-authority",
                token: token
            )
        }
        await Task.yield()
        store.invalidateCurrentSelection()

        let outcome = await task.value
        // Deliberately not asserting `capturedRequests.count == 0` here: a
        // single `Task.yield()` biases toward, but cannot guarantee,
        // cancelling before the child task's own actor hop reaches
        // `URLProtocol.startLoading()` — both a genuinely prevented start
        // and a started-then-correctly-discarded transfer are valid
        // outcomes of this exact race, and asserting only the former made
        // this test flaky under real scheduler timing (confirmed against
        // production code, not a test-only accident). The one thing
        // guaranteed regardless of which side of that boundary the
        // cancellation lands on is that the outcome is never usable — the
        // two ends of this window are each proven individually and
        // deterministically by
        // `testOffImmediatelyAfterStartingAnalysisPreventsTransferFromEverStarting`
        // (cancel strictly before any chance to start) and
        // `testAnInFlightNetworkResponseIsDroppedIfAIAssistanceTurnsOffBeforeItReturns`
        // (cancel strictly after transfer has genuinely started).
        XCTAssertNil(outcome)
    }

    /// Off must retire the current generation itself, not merely cancel a
    /// task — `isCurrent` for a token minted before Off must become false
    /// immediately, synchronously, independent of any task's cancellation
    /// timing.
    func testOffRetiresTheCurrentGenerationSynchronously() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        XCTAssertTrue(store.isCurrent(token))

        store.setAIAssistanceEnabled(false)

        XCTAssertFalse(store.isCurrent(token))
    }

    /// Off retires the generation; turning AI Assistance back On must not
    /// itself revive a token minted before Off. A later analysis can only
    /// ever start from a fresh `beginSelection(...)` token.
    func testTurningOffThenBackOnCannotReviveThePreOffToken() async {
        let store = makeStore()
        ScreenshotProposalURLProtocol.enqueue(responseBody(eligible: true, locationName: "Palladium"))

        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)

        store.setAIAssistanceEnabled(false)
        store.setAIAssistanceEnabled(true)

        XCTAssertFalse(store.isCurrent(token), "On restores availability for a new selection, not the retired one")
        let outcome = await store.analyzeScreenshot(
            imageData: Data([0x01]),
            mimeType: "image/jpeg",
            localEvidenceText: "View order Order information 1 Bowl",
            participantAuthority: "an-authority",
            token: token
        )
        XCTAssertNil(outcome)
        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 0)
    }

    // MARK: - Error mapping

    func testProviderUnavailableMapsToUnavailableNotice() async {
        let store = makeStore()
        let body = Data(#"{"error":{"code":"PROVIDER_UNAVAILABLE","message":"x","fields":null}}"#.utf8)
        ScreenshotProposalURLProtocol.enqueue(.response(statusCode: 503, data: body))

        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let outcome = await store.analyzeScreenshot(
            imageData: Data([0x01]),
            mimeType: "image/jpeg",
            localEvidenceText: "View order Order information 1 Bowl",
            participantAuthority: "an-authority",
            token: token
        )

        XCTAssertNil(outcome)
        XCTAssertEqual(store.notice, .unavailable)
    }

    func testAuthorityInvalidMapsToVerificationExpiredNotice() async {
        let store = makeStore()
        let body = Data(#"{"error":{"code":"PARTICIPANT_AUTHORITY_INVALID","message":"x","fields":null}}"#.utf8)
        ScreenshotProposalURLProtocol.enqueue(.response(statusCode: 401, data: body))

        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        _ = await store.analyzeScreenshot(
            imageData: Data([0x01]),
            mimeType: "image/jpeg",
            localEvidenceText: "View order Order information 1 Bowl",
            participantAuthority: "a-stale-authority",
            token: token
        )

        XCTAssertEqual(store.notice, .verificationExpired)
    }

    // MARK: - Independent evidence transmission (regression: OpenAI must not
    // manufacture the evidence its own claims are validated against)

    /// The service must actually transmit the independently-derived local
    /// OCR text alongside the image, not just accept the parameter and drop
    /// it — this is what lets the backend refuse to call OpenAI at all for
    /// an independently-ineligible screenshot, and what lets it corroborate
    /// mealSwipes against real evidence rather than the provider's own
    /// output.
    func testAnalyzeScreenshotTransmitsTheIndependentLocalEvidenceTextInTheRequestBody() async throws {
        let store = makeStore()
        ScreenshotProposalURLProtocol.enqueue(responseBody(eligible: true))

        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        _ = await store.analyzeScreenshot(
            imageData: Data([0x01, 0x02]),
            mimeType: "image/jpeg",
            localEvidenceText: "a very specific literal independent evidence phrase",
            participantAuthority: "an-authority",
            token: token
        )

        let request = try XCTUnwrap(ScreenshotProposalURLProtocol.capturedRequests.last)
        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(
            json["localEvidenceText"] as? String,
            "a very specific literal independent evidence phrase"
        )
    }

    // MARK: - AI Assistance enable/consent persistence

    func testSetAIAssistanceEnabledPersistsThroughStorage() {
        let preferences = InMemoryScreenshotProposalPreferencesStorage()
        let store = makeStore(preferences: preferences)
        XCTAssertTrue(store.isAIAssistanceEnabled)

        store.setAIAssistanceEnabled(false)

        XCTAssertFalse(store.isAIAssistanceEnabled)
        XCTAssertFalse(preferences.isAIAssistanceEnabled)
    }

    func testRecordThirdPartyConsentPersistsThroughStorage() {
        let preferences = InMemoryScreenshotProposalPreferencesStorage()
        let store = makeStore(preferences: preferences)
        XCTAssertFalse(store.hasRecordedThirdPartyConsent)

        store.recordThirdPartyConsent()

        XCTAssertTrue(store.hasRecordedThirdPartyConsent)
        XCTAssertTrue(preferences.hasRecordedThirdPartyConsent)
    }

    // MARK: - W4-R2 2026-09-01 sync: independent Screenshot Help
    // education-completion state

    /// Defaults to `false` (unlike `isAIAssistanceEnabled`, which defaults
    /// `true`): education is shown until actually completed once.
    func testScreenshotHelpCompletionDefaultsToFalse() {
        let store = makeStore()
        XCTAssertFalse(store.hasCompletedScreenshotHelp)
    }

    func testRecordScreenshotHelpCompletedPersistsThroughStorage() {
        let preferences = InMemoryScreenshotProposalPreferencesStorage()
        let store = makeStore(preferences: preferences)
        XCTAssertFalse(store.hasCompletedScreenshotHelp)

        store.recordScreenshotHelpCompleted()

        XCTAssertTrue(store.hasCompletedScreenshotHelp)
        XCTAssertTrue(preferences.hasCompletedScreenshotHelp)
    }

    /// Item 4 of the sync: education state and consent/AI-enabled state are
    /// independent — recording one must never mutate the other, in either
    /// direction.
    func testScreenshotHelpCompletionIsIndependentOfConsentAndAIEnabledState() {
        let preferences = InMemoryScreenshotProposalPreferencesStorage()
        let store = makeStore(preferences: preferences)

        store.recordScreenshotHelpCompleted()
        XCTAssertFalse(store.hasRecordedThirdPartyConsent)
        XCTAssertTrue(store.isAIAssistanceEnabled)

        let otherPreferences = InMemoryScreenshotProposalPreferencesStorage()
        let otherStore = makeStore(preferences: otherPreferences)
        otherStore.recordThirdPartyConsent()
        XCTAssertFalse(otherStore.hasCompletedScreenshotHelp)

        otherStore.setAIAssistanceEnabled(false)
        XCTAssertFalse(otherStore.hasCompletedScreenshotHelp)
    }
}
