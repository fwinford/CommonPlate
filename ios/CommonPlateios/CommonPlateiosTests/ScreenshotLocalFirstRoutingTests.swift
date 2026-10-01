//
//  ScreenshotLocalFirstRoutingTests.swift
//  CommonPlateiosTests
//
// W4-S3 requester routing, per-attempt permission, and privacy proof against
// the real `ScreenshotProposalStore`: the local-first routing matrix, the three
// accepted external-AI popup triggers (and every case that must NOT show it),
// zero external transfer before `Use external AI`, `Continue manually`, the
// per-selection/per-attempt nature of permission, Settings ON/OFF semantics,
// the inert legacy consent flag, external-attempt terminality, and stale-result
// fencing. All evidence is synthetic.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ScreenshotLocalFirstRoutingTests: XCTestCase {
    override func tearDown() {
        ScreenshotProposalURLProtocol.reset()
        super.tearDown()
    }

    private let environment = testQualifiableEnvironment
    private let noManualEdits = ScreenshotFieldManualEditState()

    // MARK: - Fixtures

    private func makeService() -> ScreenshotProposalService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScreenshotProposalURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        return ScreenshotProposalService(client: client)
    }

    /// Store wired to the injected qualified local path and a counting external
    /// stub — for behavior that needs to observe provider calls.
    private func makeStore(
        local: StubLocalProvider?,
        external providedExternal: StubExternalProvider? = nil,
        qualified: Bool = true,
        preferences: ScreenshotProposalPreferencesStoring = InMemoryScreenshotProposalPreferencesStorage(),
        timeout: Duration = .seconds(5)
    ) -> ScreenshotProposalStore {
        let external = providedExternal ?? StubExternalProvider()
        let runtime = makeRequesterTestRuntime(
            local: local,
            external: external,
            qualification: qualified ? qualifiedRegistry(environment: environment) : .production,
            environment: environment,
            timeout: timeout
        )
        return ScreenshotProposalStore(service: makeService(), preferences: preferences, runtime: runtime)
    }

    /// Store wired exactly like production wiring (real Apple provider factory,
    /// production qualification, real network-backed external provider) but on
    /// a stubbed transport, so any external byte is observable.
    private func makeProductionWiredStore(
        preferences: ScreenshotProposalPreferencesStoring = InMemoryScreenshotProposalPreferencesStorage()
    ) -> ScreenshotProposalStore {
        makeProductionWiredRequesterStore(service: makeService(), preferences: preferences)
    }

    private func begin(_ store: ScreenshotProposalStore) -> (ScreenshotSelectionToken, RequestFoodFormDraft) {
        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        return (token, draft)
    }

    private func usefulOutput(swipes: Int? = nil) -> RequesterOrderRawOutput {
        RequesterOrderRawOutput(
            visibleVenueText: "Palladium",
            foodItems: [.init(name: "Bowl", quantity: 1, modifiers: [])],
            mealSwipes: swipes
        )
    }

    private var emptyOutput: RequesterOrderRawOutput {
        RequesterOrderRawOutput(visibleVenueText: nil, foodItems: [], mealSwipes: nil)
    }

    private func eligibleExternalStub() -> ScreenshotProposalURLProtocol.Stub {
        let body: [String: Any] = [
            "eligible": true,
            "proposal": ["mealItems": [["name": "1 Bowl"]]],
        ]
        return .response(data: try! JSONSerialization.data(withJSONObject: body))
    }

    // MARK: - Routing matrix: success and ineligible never show the popup

    func testUsefulPartialLocalResultIsSuccessWithNoPopupAndNoExternalCall() async {
        let local = StubLocalProvider(behavior: .output(usefulOutput()))
        let external = StubExternalProvider()
        let store = makeStore(local: local, external: external)
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        // Partial: a location and an item, no swipe count. Still a success.
        XCTAssertEqual(outcome?.proposal.selectedDiningSpot?.name, "Palladium")
        XCTAssertEqual(outcome?.proposal.mealItems, [MealItem(name: "1 Bowl")])
        XCTAssertNil(outcome?.proposal.mealSwipes)
        XCTAssertFalse(store.isAwaitingExternalAIPermission, "a useful partial local result must not offer external AI")
        XCTAssertEqual(external.analyzeCallCount, 0)
        XCTAssertNil(store.notice)
    }

    func testPolicyIneligibleSelectionGetsTheExistingIneligibleTreatmentAndNoPopup() async {
        let local = StubLocalProvider(behavior: .output(usefulOutput()))
        let external = StubExternalProvider()
        let store = makeStore(local: local, external: external)
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input(ScreenshotTestEvidence.ineligible)],
            participantAuthority: { "an-authority" },
            token: token
        )

        XCTAssertEqual(outcome, ScreenshotProposalOutcome(eligible: false, proposal: .empty))
        XCTAssertFalse(store.isAwaitingExternalAIPermission, "policy-ineligible evidence never gets the popup")
        XCTAssertEqual(local.extractCallCount, 0, "no provider of either class sees ineligible evidence")
        XCTAssertEqual(external.analyzeCallCount, 0)

        var draft = RequestFoodFormDraft()
        store.apply(outcome!, manualEdits: noManualEdits, to: &draft)
        XCTAssertEqual(store.notice, .unsupportedScreenshot)
    }

    func testOnlyEligibleScreenshotsReachTheLocalProvider() async {
        let local = StubLocalProvider(behavior: .output(usefulOutput()))
        let store = makeStore(local: local)
        let (token, _) = begin(store)

        _ = await store.analyzeScreenshot(
            images: [
                ScreenshotTestEvidence.input(ScreenshotTestEvidence.ineligible, byte: 1),
                ScreenshotTestEvidence.input("Your Pickup Order eligible one", byte: 2),
            ],
            participantAuthority: { "an-authority" },
            token: token
        )

        XCTAssertEqual(local.lastEvidenceTexts, ["Your Pickup Order eligible one"])
    }

    // MARK: - Routing matrix: the three popup triggers

    func testUnavailableLocalModelOffersThePopupAndSendsNothing() async {
        let local = StubLocalProvider(availability: .unavailable(.appleIntelligenceNotEnabledForTest), behavior: .output(usefulOutput()))
        let external = StubExternalProvider()
        let store = makeStore(local: local, external: external)
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertNil(outcome)
        XCTAssertTrue(store.isAwaitingExternalAIPermission)
        XCTAssertEqual(local.extractCallCount, 0)
        XCTAssertEqual(external.analyzeCallCount, 0, "offering the popup transfers nothing")
    }

    func testUnqualifiedLocalCombinationOffersThePopupWithoutRunningTheModel() async {
        let local = StubLocalProvider(behavior: .output(usefulOutput()))
        let external = StubExternalProvider()
        let store = makeStore(local: local, external: external, qualified: false)
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertNil(outcome)
        XCTAssertTrue(store.isAwaitingExternalAIPermission)
        XCTAssertEqual(local.extractCallCount, 0, "an available but unqualified model is not used")
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    func testLocalFailureOffersThePopup() async {
        let local = StubLocalProvider(behavior: .fail(StubLocalProvider.StubError()))
        let external = StubExternalProvider()
        let store = makeStore(local: local, external: external)
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertNil(outcome)
        XCTAssertTrue(store.isAwaitingExternalAIPermission)
        XCTAssertEqual(external.analyzeCallCount, 0, "a local failure never silently falls back to external AI")
        XCTAssertNil(store.notice, "the popup, not a notice, is the treatment for a local failure")
    }

    func testLocalTimeoutOffersThePopup() async {
        let local = StubLocalProvider(behavior: .hang)
        let store = makeStore(local: local, timeout: .milliseconds(80))
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertNil(outcome)
        XCTAssertTrue(store.isAwaitingExternalAIPermission)
    }

    func testLocalResultWithZeroUsableValidFieldsOffersThePopup() async {
        let local = StubLocalProvider(behavior: .output(emptyOutput))
        let store = makeStore(local: local)
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input(ScreenshotTestEvidence.eligibleCartWithoutVendor)],
            participantAuthority: { "an-authority" },
            token: token
        )

        XCTAssertNil(outcome)
        XCTAssertTrue(store.isAwaitingExternalAIPermission)
    }

    /// A vendor grounded in the independent OCR evidence is itself a valid
    /// proposal field even when the model returns nothing, so such a result is a
    /// (partial) success rather than a popup trigger.
    func testEvidenceGroundedVendorAloneIsAUsefulLocalResult() async {
        let store = makeStore(local: StubLocalProvider(behavior: .output(emptyOutput)))
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertEqual(outcome?.proposal.selectedDiningSpot?.name, "Palladium")
        XCTAssertFalse(store.isAwaitingExternalAIPermission)
    }

    /// Output that only looked useful before validation counts as zero usable
    /// fields once the on-device validator has dropped what evidence doesn't
    /// support.
    func testLocalOutputThatValidationEmptiesOffersThePopup() async {
        let ungrounded = RequesterOrderRawOutput(visibleVenueText: "Cafe 370", foodItems: [], mealSwipes: 3)
        let store = makeStore(local: StubLocalProvider(behavior: .output(ungrounded)))
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input(ScreenshotTestEvidence.eligibleCartWithoutVendor)],
            participantAuthority: { "an-authority" },
            token: token
        )

        XCTAssertNil(outcome)
        XCTAssertTrue(store.isAwaitingExternalAIPermission)
    }

    /// The production wiring has no qualified combination, so every eligible
    /// attempt reaches the popup — proven with a real network-backed external
    /// provider so any leaked byte would be captured.
    func testProductionWiringIsLocalNotQualifiedAndSendsNothingBeforeTheTap() async {
        let store = makeProductionWiredStore()
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertNil(outcome)
        XCTAssertTrue(store.isAwaitingExternalAIPermission)
        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 0)
    }

    // MARK: - Not shown for cancelled / stale / superseded attempts

    func testCancelledLocalAttemptShowsNoPopup() async {
        let local = StubLocalProvider(behavior: .delayed(.milliseconds(300), usefulOutput()))
        let store = makeStore(local: local)
        let (token, _) = begin(store)
        let task = Task { await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token) }
        try? await Task.sleep(for: .milliseconds(30))

        store.invalidateCurrentSelection()

        let outcome = await task.value
        XCTAssertNil(outcome)
        XCTAssertFalse(store.isAwaitingExternalAIPermission)
    }

    func testSupersededLocalAttemptShowsNoPopupAndCannotApply() async {
        let slowFailing = StubLocalProvider(behavior: .fail(StubLocalProvider.StubError()))
        let external = StubExternalProvider()
        let store = makeStore(local: slowFailing, external: external)
        var draft = RequestFoodFormDraft()
        let older = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let olderTask = Task { await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: older) }

        // A newer selection begins before the older attempt's failure lands.
        let newer = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let outcome = await olderTask.value

        XCTAssertNil(outcome)
        XCTAssertFalse(store.isCurrent(older))
        XCTAssertTrue(store.isCurrent(newer))
        XCTAssertFalse(store.isAwaitingExternalAIPermission, "a superseded attempt must not raise a popup for the newer selection")
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    func testAttemptStartedWhileAssistanceIsOffShowsNoPopup() async {
        let store = makeStore(local: StubLocalProvider(behavior: .fail(StubLocalProvider.StubError())))
        let (token, _) = begin(store)
        store.setAIAssistanceEnabled(false)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertNil(outcome)
        XCTAssertFalse(store.isAwaitingExternalAIPermission)
    }

    // MARK: - No external transfer before `Use external AI`; Continue manually

    func testPendingPopupTransfersNothingUntilTheRequesterTapsUseExternalAI() async {
        let external = StubExternalProvider(result: .success(ScreenshotProposalOutcome(eligible: true, proposal: .empty)))
        let store = makeStore(local: nil, external: external)
        let (token, _) = begin(store)
        _ = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)
        XCTAssertTrue(store.isAwaitingExternalAIPermission)

        // Time passes with the popup open; nothing moves.
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(external.analyzeCallCount, 0)
        XCTAssertTrue(store.isAwaitingExternalAIPermission)

        let resolved = await store.useExternalAI(participantAuthority: { "an-authority" })

        XCTAssertNotNil(resolved)
        XCTAssertEqual(external.analyzeCallCount, 1)
        XCTAssertFalse(store.isAwaitingExternalAIPermission)
    }

    func testContinueManuallySendsNothingDismissesThePopupAndKeepsAssistanceOn() async {
        let external = StubExternalProvider()
        let preferences = InMemoryScreenshotProposalPreferencesStorage()
        let store = makeStore(local: nil, external: external, preferences: preferences)
        let (token, _) = begin(store)
        _ = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)
        XCTAssertTrue(store.isAwaitingExternalAIPermission)

        store.continueManually()

        XCTAssertFalse(store.isAwaitingExternalAIPermission)
        XCTAssertEqual(external.analyzeCallCount, 0)
        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 0)
        XCTAssertTrue(store.isAIAssistanceEnabled, "Continue manually does not turn Screenshot Assistance Off")
        XCTAssertTrue(preferences.isAIAssistanceEnabled)
        XCTAssertNil(store.notice)

        // The retired popup's permission cannot be used afterwards.
        let late = await store.useExternalAI(participantAuthority: { "an-authority" })
        XCTAssertNil(late)
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    func testRealTransportSeesZeroRequestsForLocalSuccessPopupAndContinueManually() async {
        // Real network-backed external provider on a capturing transport, with
        // a qualified local stub so the local path genuinely runs.
        let runtime = ScreenshotAssistanceRuntime(
            workflow: RequesterOrderWorkflow(recognizer: SyntheticTextRecognizer()),
            localProvider: StubLocalProvider(behavior: .output(usefulOutput())),
            externalProvider: RequesterOpenAIExternalProvider(service: makeService()),
            qualification: qualifiedRegistry(environment: environment),
            environment: environment
        )
        let store = ScreenshotProposalStore(
            service: makeService(),
            preferences: InMemoryScreenshotProposalPreferencesStorage(),
            runtime: runtime
        )
        let (token, _) = begin(store)
        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)
        XCTAssertNotNil(outcome)
        XCTAssertEqual(
            ScreenshotProposalURLProtocol.capturedRequests.count, 0,
            "selecting and locally analyzing screenshots must not send them off-device"
        )
    }

    // MARK: - Permission is per attempt and per selection

    func testUseExternalAIIsSingleUse() async {
        let external = StubExternalProvider()
        let store = makeStore(local: nil, external: external)
        let (token, _) = begin(store)
        _ = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        let first = await store.useExternalAI(participantAuthority: { "an-authority" })
        let second = await store.useExternalAI(participantAuthority: { "an-authority" })

        XCTAssertNotNil(first)
        XCTAssertNil(second, "a second tap has no permission to spend")
        XCTAssertEqual(external.analyzeCallCount, 1)
    }

    func testEveryNewSelectionNeedsANewExternalPermissionTap() async {
        let external = StubExternalProvider()
        let store = makeStore(local: nil, external: external)
        var draft = RequestFoodFormDraft()

        let first = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        _ = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: first)
        _ = await store.useExternalAI(participantAuthority: { "an-authority" })
        XCTAssertEqual(external.analyzeCallCount, 1)

        // A new selection: the earlier tap grants nothing. Nothing is sent
        // until the requester encounters the popup and taps again.
        let second = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input(byte: 2)], participantAuthority: { "an-authority" }, token: second)
        XCTAssertNil(outcome)
        XCTAssertTrue(store.isAwaitingExternalAIPermission)
        XCTAssertEqual(external.analyzeCallCount, 1, "no transfer without a fresh tap")

        _ = await store.useExternalAI(participantAuthority: { "an-authority" })
        XCTAssertEqual(external.analyzeCallCount, 2)
    }

    func testANewSelectionRetiresThePreviousPopupAndItsPermission() async {
        let external = StubExternalProvider()
        let store = makeStore(local: nil, external: external)
        var draft = RequestFoodFormDraft()
        let first = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        _ = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: first)
        XCTAssertTrue(store.isAwaitingExternalAIPermission)

        let second = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)

        XCTAssertFalse(store.isAwaitingExternalAIPermission)
        XCTAssertFalse(store.isCurrent(first))
        XCTAssertTrue(store.isCurrent(second))
        let stale = await store.useExternalAI(participantAuthority: { "an-authority" })
        XCTAssertNil(stale, "a replaced selection cannot reuse the previous permission")
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    func testLeavingTheScreenRetiresThePopupAndReleasesTheSelection() async {
        let external = StubExternalProvider()
        let store = makeStore(local: nil, external: external)
        let (token, _) = begin(store)
        _ = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)
        XCTAssertTrue(store.isAwaitingExternalAIPermission)

        store.invalidateCurrentSelection()

        XCTAssertFalse(store.isAwaitingExternalAIPermission)
        let retired = await store.useExternalAI(participantAuthority: { "an-authority" })
        XCTAssertNil(retired)
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    // MARK: - Settings ON / OFF

    /// ON enables Screenshot Assistance and may allow the offer; it never
    /// authorizes a transfer by itself.
    func testSettingsOnAloneAuthorizesNoTransfer() async {
        let external = StubExternalProvider()
        let preferences = InMemoryScreenshotProposalPreferencesStorage()
        preferences.isAIAssistanceEnabled = false
        let store = makeStore(local: nil, external: external, preferences: preferences)

        store.setAIAssistanceEnabled(true)

        XCTAssertFalse(store.isAwaitingExternalAIPermission)
        let retired = await store.useExternalAI(participantAuthority: { "an-authority" })
        XCTAssertNil(retired)
        XCTAssertEqual(external.analyzeCallCount, 0)
        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 0)
    }

    func testSettingsOffRetiresThePendingPopupAndTurningOnDoesNotReviveIt() async {
        let external = StubExternalProvider()
        let store = makeStore(local: nil, external: external)
        let (token, _) = begin(store)
        _ = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)
        XCTAssertTrue(store.isAwaitingExternalAIPermission)

        store.setAIAssistanceEnabled(false)
        XCTAssertFalse(store.isAwaitingExternalAIPermission)
        XCTAssertFalse(store.isCurrent(token))

        store.setAIAssistanceEnabled(true)
        XCTAssertFalse(store.isAwaitingExternalAIPermission, "On does not revive a retired popup")
        let retired = await store.useExternalAI(participantAuthority: { "an-authority" })
        XCTAssertNil(retired)
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    func testSettingsOffDiscardsALateExternalResult() async {
        let external = StubExternalProvider(result: .success(ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(mealItems: [MealItem(name: "Bowl")])
        )))
        external.delay = .milliseconds(300)
        let store = makeStore(local: nil, external: external)
        let (token, _) = begin(store)
        _ = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)
        let task = Task { await store.useExternalAI(participantAuthority: { "an-authority" }) }
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(external.analyzeCallCount, 1, "the transfer had already begun")

        store.setAIAssistanceEnabled(false)

        let resolved = await task.value
        XCTAssertNil(resolved, "a retired attempt's late result can never apply")
        XCTAssertFalse(store.isApplying)
    }

    func testSettingsOffWhileALocalAttemptRunsRetiresItWithoutAPopup() async {
        let local = StubLocalProvider(behavior: .delayed(.milliseconds(300), usefulOutput()))
        let store = makeStore(local: local)
        let (token, _) = begin(store)
        let task = Task { await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token) }
        try? await Task.sleep(for: .milliseconds(30))

        store.setAIAssistanceEnabled(false)

        let cancelled = await task.value
        XCTAssertNil(cancelled)
        XCTAssertFalse(store.isAwaitingExternalAIPermission)
    }

    // MARK: - Legacy consent grants no authority

    func testPreS3RecordedConsentGrantsNoTransferAuthority() async throws {
        let suiteName = "commonplate.tests.s3.legacyConsent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // A build from before S3 recorded this flag when the requester tapped
        // Continue on the old disclosure.
        defaults.set(true, forKey: "commonplate.screenshotProposal.thirdPartyConsentRecorded")

        let store = makeProductionWiredStore(
            preferences: UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults)
        )
        let (token, _) = begin(store)
        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertNil(outcome)
        XCTAssertTrue(store.isAwaitingExternalAIPermission, "old consent neither skips nor pre-answers the popup")
        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 0, "old consent authorizes no transfer")

        store.continueManually()
        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 0)
    }

    func testNoPersistedRemotePermissionExists() throws {
        let suiteName = "commonplate.tests.s3.noPersisted.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ScreenshotProposalStore(
            service: makeService(),
            preferences: UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults),
            runtime: nil
        )
        store.setAIAssistanceEnabled(true)
        store.recordScreenshotHelpCompleted()
        let keys = Set(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("commonplate.screenshotProposal") })
        XCTAssertEqual(keys, [
            "commonplate.screenshotProposal.aiAssistanceEnabled",
            "commonplate.screenshotProposal.helpCompleted",
        ])
    }

    // MARK: - External attempt is one terminal attempt

    func testExternalFailureUsesTheExistingNoticeAndOffersNoSecondPopup() async {
        let external = StubExternalProvider(result: .failure(ScreenshotProposalServiceError.unavailable(underlying: StubLocalProvider.StubError())))
        let store = makeStore(local: nil, external: external)
        let (token, _) = begin(store)
        _ = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        let resolved = await store.useExternalAI(participantAuthority: { "an-authority" })

        XCTAssertNil(resolved)
        XCTAssertEqual(store.notice, .unavailable)
        XCTAssertFalse(store.isAwaitingExternalAIPermission, "no second external-AI offer for the same selection")
        XCTAssertEqual(external.analyzeCallCount, 1)
    }

    func testExternalResultWithNoUsefulFieldsIsTheExistingTreatmentNotASecondPopup() async {
        let external = StubExternalProvider(result: .success(ScreenshotProposalOutcome(eligible: true, proposal: .empty)))
        let store = makeStore(local: nil, external: external)
        let (token, _) = begin(store)
        _ = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        let resolved = await store.useExternalAI(participantAuthority: { "an-authority" })
        let outcome = try? XCTUnwrap(resolved?.outcome)

        XCTAssertEqual(outcome?.isEmpty, true)
        XCTAssertFalse(store.isAwaitingExternalAIPermission)
        var draft = RequestFoodFormDraft()
        store.apply(outcome!, manualEdits: noManualEdits, to: &draft)
        XCTAssertEqual(store.notice, .noUsefulExtraction)
        XCTAssertFalse(store.isAwaitingExternalAIPermission)
    }

    func testExternalIneligibleResultUsesTheUnsupportedTreatmentNotASecondPopup() async {
        let external = StubExternalProvider(result: .success(ScreenshotProposalOutcome(eligible: false, proposal: .empty)))
        let store = makeStore(local: nil, external: external)
        let (token, _) = begin(store)
        _ = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        let resolved = await store.useExternalAI(participantAuthority: { "an-authority" })

        XCTAssertEqual(resolved?.outcome.eligible, false)
        XCTAssertFalse(store.isAwaitingExternalAIPermission)
    }

    /// Authority lost between the popup being offered and its tap: nothing is
    /// sent and Screenshot Assistance surfaces no verification notice.
    func testExternalAttemptWithoutParticipantAuthoritySendsNothingAndPresentsTheLocalOutcomeInsteadOfVerification() async {
        let external = StubExternalProvider()
        let store = makeStore(local: nil, external: external)
        let (token, _) = begin(store)
        _ = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        let resolved = await store.useExternalAI(participantAuthority: { nil })

        XCTAssertNil(resolved)
        XCTAssertEqual(store.notice, .unavailable, "the original local outcome, not a verification notice")
        XCTAssertEqual(external.analyzeCallCount, 0)
        XCTAssertFalse(store.isAwaitingExternalAIPermission, "the tap spent this attempt's permission")
    }

    /// One logical attempt uses one provider class: an external attempt neither
    /// sees nor merges anything a local attempt produced.
    func testExternalAttemptSendsOnlyEligibleScreenshotsAndMergesNoLocalProposal() async {
        let local = StubLocalProvider(behavior: .output(emptyOutput))
        let external = StubExternalProvider(result: .success(ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(mealItems: [MealItem(name: "External Item")])
        )))
        let store = makeStore(local: local, external: external)
        let (token, _) = begin(store)
        _ = await store.analyzeScreenshot(
            images: [
                ScreenshotTestEvidence.input(ScreenshotTestEvidence.ineligible, byte: 1),
                ScreenshotTestEvidence.input(ScreenshotTestEvidence.eligibleCartWithoutVendor, byte: 2),
            ],
            participantAuthority: { "an-authority" },
            token: token
        )
        XCTAssertEqual(local.extractCallCount, 1)

        let resolved = await store.useExternalAI(participantAuthority: { "an-authority" })

        XCTAssertEqual(external.lastImages.map { $0.data.first }, [2], "an ineligible screenshot is never sent")
        XCTAssertEqual(resolved?.outcome.proposal.mealItems, [MealItem(name: "External Item")])
        XCTAssertNil(resolved?.outcome.proposal.selectedDiningSpot)
    }

    // MARK: - Real transport: what an external attempt actually sends

    func testExternalAttemptTransmitsOnlyAfterTheTapAndCarriesEligibleEvidence() async throws {
        ScreenshotProposalURLProtocol.enqueue(eligibleExternalStub())
        let store = makeProductionWiredStore()
        let (token, _) = begin(store)
        _ = await store.analyzeScreenshot(
            images: [
                ScreenshotTestEvidence.input("Your Pickup Order first", byte: 1),
                ScreenshotTestEvidence.input(ScreenshotTestEvidence.ineligible, byte: 2),
            ],
            participantAuthority: { "an-authority" },
            token: token
        )
        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 0)

        let resolved = await store.useExternalAI(participantAuthority: { "an-authority" })

        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 1)
        let body = try XCTUnwrap(ScreenshotProposalURLProtocol.capturedRequests.first?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let images = try XCTUnwrap(json["images"] as? [[String: Any]])
        XCTAssertEqual(images.compactMap { $0["localEvidenceText"] as? String }, ["Your Pickup Order first"])
        XCTAssertEqual(resolved?.outcome.proposal.mealItems, [MealItem(name: "1 Bowl")])
    }

    // MARK: - 1–5 screenshots and concurrency

    func testOneThroughFiveScreenshotsAreAnalyzedLocallyAsOneOrder() async {
        for count in 1...ScreenshotProposalStore.maxScreenshotSelection {
            let local = StubLocalProvider(behavior: .output(usefulOutput()))
            let store = makeStore(local: local)
            let (token, _) = begin(store)
            let texts = (1...count).map { "Your Pickup Order screenshot \($0)" }

            let outcome = await store.analyzeScreenshot(
                images: texts.enumerated().map { ScreenshotTestEvidence.input($0.element, byte: UInt8($0.offset + 1)) },
                participantAuthority: { "an-authority" },
                token: token
            )

            XCTAssertNotNil(outcome, "\(count) screenshots")
            XCTAssertEqual(local.extractCallCount, 1, "one attempt for the whole set, never one per screenshot")
            XCTAssertEqual(local.lastEvidenceTexts, texts)
        }
    }

    func testMoreThanFiveScreenshotsAreRefusedBeforeAnyProvider() async {
        let local = StubLocalProvider(behavior: .output(usefulOutput()))
        let store = makeStore(local: local)
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(
            images: ScreenshotTestEvidence.inputs(6),
            participantAuthority: { "an-authority" },
            token: token
        )

        XCTAssertNil(outcome)
        XCTAssertEqual(local.extractCallCount, 0)
        XCTAssertFalse(store.isAwaitingExternalAIPermission)
    }

    func testANewerSelectionWinsOverAnOlderSlowLocalAttempt() async {
        let local = StubLocalProvider(behavior: .delayed(.milliseconds(200), usefulOutput()))
        let store = makeStore(local: local)
        var draft = RequestFoodFormDraft()
        let older = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let olderTask = Task { await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: older) }
        try? await Task.sleep(for: .milliseconds(20))

        let newer = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        local.behavior = .output(usefulOutput())
        let newerOutcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input(byte: 2)], participantAuthority: { "an-authority" }, token: newer)

        let olderOutcome = await olderTask.value
        XCTAssertNil(olderOutcome, "the older attempt must be dropped even though it was already running")
        XCTAssertNotNil(newerOutcome)
        XCTAssertFalse(store.isApplying)
    }

    func testIsApplyingCoversTheLocalAttemptAndClearsWhenItEnds() async {
        let local = StubLocalProvider(behavior: .delayed(.milliseconds(150), usefulOutput()))
        let store = makeStore(local: local)
        let (token, _) = begin(store)
        let task = Task { await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token) }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(store.isApplying)

        _ = await task.value
        XCTAssertFalse(store.isApplying)
    }
}

private extension ScreenshotLocalUnavailableReason {
    /// Readable name for the reason the popup tests use.
    static var appleIntelligenceNotEnabledForTest: ScreenshotLocalUnavailableReason { .modelNotEnabled }
}
