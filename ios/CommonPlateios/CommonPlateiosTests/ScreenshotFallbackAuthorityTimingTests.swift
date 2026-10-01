//
//  ScreenshotFallbackAuthorityTimingTests.swift
//  CommonPlateiosTests
//
// W4-S3 ACTIVE / FIX, Finding 1: the external-AI popup may be offered only if
// the requester's participant authority is CURRENT at the moment the offer is
// decided — after evidence derivation (OCR) and the local attempt — not as it
// was when analysis started. Each case would otherwise offer the popup: the
// local attempt fails (or yields nothing), so an authorized requester sees it.
//
// Driven against the real `ScreenshotProposalStore` and shared runtime with
// synthetic evidence. Authority is a value a test changes while a stage is
// running; the store reads it through the provider `analyzeScreenshot` receives.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ScreenshotFallbackAuthorityTimingTests: XCTestCase {
    private let environment = testQualifiableEnvironment

    private struct Fixture {
        let store: ScreenshotProposalStore
        let external: StubExternalProvider
        let authority: AuthorityBox
    }

    private func makeFixture(
        local: (any ScreenshotLocalProvider<RequesterOrderWorkflow>)?,
        recognizer: any ScreenshotTextRecognizing = SyntheticTextRecognizer(),
        qualified: Bool = true,
        timeout: Duration = .seconds(5),
        authority: AuthorityBox? = nil
    ) -> Fixture {
        let authority = authority ?? AuthorityBox()
        let external = StubExternalProvider()
        let runtime = makeRequesterTestRuntime(
            local: local,
            external: external,
            qualification: qualified
                ? qualifiedRegistry(provider: local?.identity ?? StubLocalProvider.stubIdentity, environment: environment)
                : .production,
            environment: environment,
            timeout: timeout,
            recognizer: recognizer
        )
        return Fixture(store: makeStoreOver(runtime), external: external, authority: authority)
    }

    private func analyze(_ fixture: Fixture, token: ScreenshotSelectionToken) async -> ScreenshotProposalOutcome? {
        await fixture.store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input(ScreenshotTestEvidence.eligibleCartWithoutVendor)],
            participantAuthority: { fixture.authority.read() },
            token: token
        )
    }

    private func assertNoPopupAndNothingSent(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(fixture.store.isAwaitingExternalAIPermission, "no popup", file: file, line: line)
        XCTAssertNil(fixture.store.pendingExternalFallbackReason, file: file, line: line)
        XCTAssertEqual(fixture.external.analyzeCallCount, 0, "nothing is sent externally", file: file, line: line)
        XCTAssertNotEqual(fixture.store.notice, .verificationRequired, file: file, line: line)
        XCTAssertNotEqual(fixture.store.notice, .verificationExpired, file: file, line: line)
    }

    // MARK: - Present throughout → the popup is offered

    func testAuthorityPresentThroughoutOffersThePopupAndReadsAuthorityOnlyAtTheDecision() async {
        let authority = AuthorityBox()
        var readsWhileLocalAttemptRan: Int?
        let local = StubLocalProvider(behavior: .fail(StubLocalProvider.StubError()))
        local.onExtract = { readsWhileLocalAttemptRan = authority.readCount }
        let fixture = makeFixture(local: local, authority: authority)
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)

        XCTAssertNil(outcome)
        XCTAssertTrue(fixture.store.isAwaitingExternalAIPermission)
        XCTAssertEqual(fixture.store.pendingExternalFallbackReason, .localUnavailable)
        XCTAssertEqual(readsWhileLocalAttemptRan, 0, "authority is not read before the local attempt finishes")
        XCTAssertEqual(authority.readCount, 1, "authority is read once, at the offer decision")
        XCTAssertEqual(fixture.external.analyzeCallCount, 0)
    }

    func testAuthorityPresentThroughoutOffersThePopupForAnEmptyLocalResultToo() async {
        let local = StubLocalProvider(behavior: .output(emptyRequesterOutput))
        let fixture = makeFixture(local: local)
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)
        XCTAssertNil(outcome)

        XCTAssertTrue(fixture.store.isAwaitingExternalAIPermission)
        XCTAssertEqual(fixture.store.pendingExternalFallbackReason, .noUsefulExtraction)
    }

    // MARK: - Lost during evidence derivation (OCR)

    func testAuthorityLostDuringOCROffersNoPopupAndPresentsTheUnavailableTreatment() async {
        let authority = AuthorityBox()
        let recognizer = HookedTextRecognizer { authority.value = nil }
        let local = StubLocalProvider(behavior: .fail(StubLocalProvider.StubError()))
        let fixture = makeFixture(local: local, recognizer: recognizer, authority: authority)
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)

        XCTAssertNil(outcome)
        assertNoPopupAndNothingSent(fixture)
        XCTAssertEqual(fixture.store.notice, .unavailable, "the existing local outcome treatment is presented")
        XCTAssertEqual(local.extractCallCount, 1, "local analysis is unaffected by authority")
        XCTAssertTrue(fixture.store.isAIAssistanceEnabled)
    }

    func testAuthorityLostDuringOCRWithNoLocalModelOffersNoPopup() async {
        let authority = AuthorityBox()
        let recognizer = HookedTextRecognizer { authority.value = nil }
        let fixture = makeFixture(local: nil, recognizer: recognizer, authority: authority)
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)
        XCTAssertNil(outcome)

        assertNoPopupAndNothingSent(fixture)
        XCTAssertEqual(fixture.store.notice, .unavailable)
    }

    // MARK: - Lost during the local provider

    func testAuthorityLostDuringTheLocalProviderOffersNoPopupForAFailure() async {
        let authority = AuthorityBox()
        let local = StubLocalProvider(behavior: .fail(StubLocalProvider.StubError()))
        local.onExtract = { authority.value = nil }
        let fixture = makeFixture(local: local, authority: authority)
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)
        XCTAssertNil(outcome)

        assertNoPopupAndNothingSent(fixture)
        XCTAssertEqual(fixture.store.notice, .unavailable)
    }

    func testAuthorityLostDuringTheLocalProviderOffersNoPopupForAnEmptyResult() async {
        let authority = AuthorityBox()
        let local = StubLocalProvider(behavior: .output(emptyRequesterOutput))
        local.onExtract = { authority.value = nil }
        let fixture = makeFixture(local: local, authority: authority)
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)

        XCTAssertEqual(outcome?.eligible, true, "the ordinary eligible-but-empty outcome is handed to apply")
        XCTAssertEqual(outcome?.isEmpty, true)
        assertNoPopupAndNothingSent(fixture)
    }

    func testAuthorityLostDuringTheLocalProviderStillAppliesAUsefulLocalResult() async {
        let authority = AuthorityBox()
        let local = StubLocalProvider(behavior: .output(usefulRequesterOutput))
        local.onExtract = { authority.value = nil }
        let fixture = makeFixture(local: local, authority: authority)
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)

        XCTAssertEqual(outcome?.isEmpty, false, "local proposals never depended on authority")
        assertNoPopupAndNothingSent(fixture)
        XCTAssertEqual(authority.readCount, 0, "a useful local result never reaches the offer decision")
    }

    // MARK: - Stale attempt + loss

    func testAStaleAttemptWhoseAuthorityWasLostSurfacesNoFallbackAndNoNotice() async {
        let authority = AuthorityBox()
        var storeRef: ScreenshotProposalStore?
        let local = StubLocalProvider(behavior: .fail(StubLocalProvider.StubError()))
        local.onExtract = {
            // The attempt is retired AND authority disappears while it runs.
            authority.value = nil
            storeRef?.invalidateCurrentSelection()
        }
        let fixture = makeFixture(local: local, authority: authority)
        storeRef = fixture.store
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)

        XCTAssertNil(outcome)
        assertNoPopupAndNothingSent(fixture)
        XCTAssertNil(fixture.store.notice, "a retired attempt presents nothing")
        XCTAssertEqual(authority.readCount, 0, "a stale attempt never reaches the offer decision")
    }

    func testAnAttemptSupersededByANewSelectionCannotLaterSurfaceAFallback() async {
        let authority = AuthorityBox()
        var storeRef: ScreenshotProposalStore?
        let local = StubLocalProvider(behavior: .fail(StubLocalProvider.StubError()))
        local.onExtract = {
            authority.value = nil
            if let store = storeRef { _ = beginAttempt(store) }
        }
        let fixture = makeFixture(local: local, authority: authority)
        storeRef = fixture.store
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)
        XCTAssertNil(outcome)

        assertNoPopupAndNothingSent(fixture)
        XCTAssertFalse(fixture.store.isCurrent(token))
    }

    // MARK: - Timeout followed by fallback re-reads current authority

    func testAfterATimeoutTheFallbackDecisionReadsCurrentAuthorityAndOffersThePopup() async {
        let authority = AuthorityBox()
        let provider = NonCooperativeLocalProvider(output: usefulRequesterOutput)
        let fixture = makeFixture(local: provider, timeout: .milliseconds(50), authority: authority)
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)

        XCTAssertNil(outcome)
        XCTAssertTrue(provider.isRunning, "the provider is still running: control returned at the deadline")
        XCTAssertEqual(authority.readCount, 1, "authority was read once, after the timeout")
        XCTAssertTrue(fixture.store.isAwaitingExternalAIPermission)
        XCTAssertEqual(fixture.store.pendingExternalFallbackReason, .localUnavailable)
        provider.release()
    }

    func testAuthorityLostWhileALocalAttemptRanToItsTimeoutOffersNoPopup() async {
        let authority = AuthorityBox()
        let provider = NonCooperativeLocalProvider(output: usefulRequesterOutput)
        let fixture = makeFixture(local: provider, timeout: .milliseconds(50), authority: authority)
        let token = beginAttempt(fixture.store)
        let attempt = Task { await analyze(fixture, token: token) }

        await waitUntil("the provider started") { provider.isRunning }
        authority.value = nil // lost while the provider is still running
        let outcome = await attempt.value

        XCTAssertNil(outcome)
        assertNoPopupAndNothingSent(fixture)
        XCTAssertEqual(fixture.store.notice, .unavailable)
        XCTAssertEqual(authority.readCount, 1, "the value read at the decision — after the timeout — was the lost one")
        provider.release()
        await letScheduledWorkSettle()
        assertNoPopupAndNothingSent(fixture)
    }

    // MARK: - The tap still re-checks authority

    func testTheTapStillReChecksAuthorityAfterThePopupWasOffered() async {
        let fixture = makeFixture(local: StubLocalProvider(behavior: .fail(StubLocalProvider.StubError())))
        let token = beginAttempt(fixture.store)
        let outcome = await analyze(fixture, token: token)
        XCTAssertNil(outcome)
        XCTAssertTrue(fixture.store.isAwaitingExternalAIPermission)

        let resolved = await fixture.store.useExternalAI(participantAuthority: { nil })

        XCTAssertNil(resolved)
        XCTAssertEqual(fixture.external.analyzeCallCount, 0)
        XCTAssertEqual(fixture.store.notice, .unavailable)
    }

    // MARK: - View wiring (source inspection; no rendered-view proof here)

    func testTheViewSuppliesAuthorityAsAProviderAndTheStoreReadsItOnlyAtTheOfferDecision() throws {
        let view = try ScreenshotBoundarySource.read(
            "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift",
            from: #filePath
        )
        XCTAssertTrue(view.contains("participantAuthority: { identityStore.currentAuthority() }"))
        XCTAssertFalse(
            view.contains("participantAuthority: identityStore.currentAuthority(),"),
            "authority must not be captured when analysis starts"
        )
        // The external tap supplies a provider too, so the runtime can read it
        // again at the transfer boundary.
        let tap = try XCTUnwrap(view.range(of: "await screenshotProposalStore.useExternalAI("))
        XCTAssertTrue(String(view[tap.lowerBound...].prefix(160)).contains("participantAuthority: { identityStore.currentAuthority() }"))

        let store = ScreenshotBoundarySource.codeLines(try ScreenshotBoundarySource.read(
            "ios/CommonPlateios/CommonPlateios/Stores/ScreenshotProposalStore.swift",
            from: #filePath
        ))
        // On the analysis path the provider is only ever invoked inside
        // `resolveExternalFallback`; the only other read is the tap-time check in
        // `useExternalAI` (the runtime reads it again at the transfer boundary).
        XCTAssertEqual(store.components(separatedBy: "participantAuthority()").count - 1, 2)
        let resolve = try XCTUnwrap(store.range(of: "private func resolveExternalFallback("))
        let useExternal = try XCTUnwrap(store.range(of: "func useExternalAI("))
        let reads = store.ranges(of: "participantAuthority()").map(\.lowerBound)
        XCTAssertEqual(reads.count, 2)
        XCTAssertGreaterThan(reads[0], resolve.lowerBound)
        XCTAssertLessThan(reads[0], useExternal.lowerBound)
        XCTAssertGreaterThan(reads[1], useExternal.lowerBound)
    }
}
