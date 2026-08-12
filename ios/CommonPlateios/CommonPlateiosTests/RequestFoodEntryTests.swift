import Foundation
import XCTest
@testable import CommonPlateios

/// W3-I2 requester verification entry: `AppRoute.requestFood` decides
/// verification-first vs. direct-to-form before any Request Food form exists,
/// consuming W3-I1's identity, flow, and continuation machinery unchanged.
@MainActor
final class RequestFoodEntryTests: XCTestCase {
    private let principal = "entry@nyu.edu"

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Presentation

    func testCleanNoIdentityEntryRoutesToVerificationNotTheForm() {
        XCTAssertEqual(
            RequestFoodEntryView.presentation(isVerified: false),
            .verification
        )
    }

    func testVerifiedIdentityEntryRoutesDirectlyToTheForm() {
        XCTAssertEqual(
            RequestFoodEntryView.presentation(isVerified: true),
            .form
        )
    }

    // MARK: - Fresh entry opens a usable verification experience

    func testFreshEntryOpensTheExistingVerificationExperienceAtEmailEntry() {
        let store = makeIdentityStore()
        XCTAssertEqual(
            RequestFoodEntryView.presentation(isVerified: store.isVerified),
            .verification
        )

        store.beginVerificationIfNeeded()

        XCTAssertEqual(store.flow?.purpose, .firstVerification)
        XCTAssertEqual(store.flow?.stage, .enteringEmail)
        // The usable start action itself: an eligible address may send a code.
        XCTAssertTrue(
            ParticipantVerificationView.canSendCode(email: principal, isRequesting: false)
        )
    }

    /// The same idempotence `beginVerificationIfNeeded` already guarantees at
    /// the store level, exercised through this screen's own entry point so a
    /// second appearance (e.g. returning from backgrounding mid-code) does not
    /// restart progress.
    func testReenteringWhileAFlowIsRunningDoesNotRestartIt() async {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        await store.requestCode(for: principal)
        let stageBefore = store.flow?.stage

        store.beginVerificationIfNeeded()

        XCTAssertEqual(store.flow?.stage, stageBefore)
    }

    // MARK: - Successful verification continues into the form

    func testSuccessfulVerificationMakesTheFormReachable() async {
        let store = makeIdentityStore()
        XCTAssertEqual(RequestFoodEntryView.presentation(isVerified: store.isVerified), .verification)

        store.beginVerificationIfNeeded()
        await completeVerification(store)

        XCTAssertTrue(store.isVerified)
        XCTAssertEqual(RequestFoodEntryView.presentation(isVerified: store.isVerified), .form)
        // The flow that gated entry is over; nothing is left presenting it.
        XCTAssertNil(store.flow)
    }

    /// Successful verification switches the one Home-owned presentation from
    /// verification to the form; it must not invoke the Cancel exit callback.
    func testSuccessfulVerificationDoesNotInvokeTheCancelExitPath() async {
        let store = makeIdentityStore()

        store.beginVerificationIfNeeded()
        await completeVerification(store)
        let hasEnteredForm = RequestFoodEntryView.nextHasEnteredForm(
            previousHasEnteredForm: false,
            isVerified: store.isVerified
        )
        XCTAssertTrue(hasEnteredForm)
        XCTAssertEqual(
            RequestFoodEntryView.presentation(isVerified: store.isVerified, hasEnteredForm: hasEnteredForm),
            .form
        )
    }

    // MARK: - Failed / cancelled / abandoned verification does not

    func testFailedVerificationDoesNotReachTheForm() async {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 400, data: errorResponse(code: "VERIFICATION_CODE_INVALID"))
        )
        await store.requestCode(for: principal)

        let verified = await store.submitCode("000000")

        XCTAssertFalse(verified)
        XCTAssertFalse(store.isVerified)
        XCTAssertEqual(RequestFoodEntryView.presentation(isVerified: store.isVerified), .verification)
    }

    func testCancelledVerificationDoesNotReachTheFormAndRetiresTheFlow() {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()

        store.cancelVerification()

        XCTAssertFalse(store.isVerified)
        XCTAssertNil(store.flow)
        XCTAssertEqual(RequestFoodEntryView.presentation(isVerified: store.isVerified), .verification)
    }

    func testCancellingEntryVerificationRetiresTheFlowAndRequestsHomeOwnedDismissal() {
        let store = makeIdentityStore()
        var exitRequests = 0
        store.beginVerificationIfNeeded()

        RequestFoodEntryView.cancelEntryVerification(identityStore: store) {
            exitRequests += 1
        }

        XCTAssertNil(store.flow)
        XCTAssertEqual(exitRequests, 1)
        XCTAssertEqual(AppRoute.appending(.requestFood, to: []), [.requestFood])
    }

    // MARK: - Already-verified and restored identity enter directly

    /// Already verified in the same session (e.g. a request posted earlier and
    /// the installation never lost identity) — distinct from restoration
    /// below, which is what a fresh launch produces.
    func testAlreadyVerifiedIdentityEntersDirectlyWithoutReopeningVerification() async {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()
        await completeVerification(store)
        XCTAssertTrue(store.isVerified)

        XCTAssertEqual(RequestFoodEntryView.presentation(isVerified: store.isVerified), .form)
        store.beginVerificationIfNeeded()
        XCTAssertNil(store.flow)
        XCTAssertEqual(RequestFoodEntryView.presentation(isVerified: store.isVerified), .form)
    }

    func testRestoredVerifiedIdentityEntersDirectlyOnTheNextLaunch() {
        let storage = InMemoryParticipantIdentityStorage(
            stored: ParticipantIdentityRecord(
                principal: principal,
                authority: canonicalParticipantAuthorityFixture,
                verifiedAt: Date(timeIntervalSince1970: 1_000)
            )
        )

        // A fresh store is what a relaunch produces.
        let store = makeIdentityStore(storage: storage)

        XCTAssertTrue(store.isVerified)
        XCTAssertEqual(RequestFoodEntryView.presentation(isVerified: store.isVerified), .form)

        // Re-running the entry gate on an already-restored identity must not
        // reopen verification.
        store.beginVerificationIfNeeded()
        XCTAssertNil(store.flow)
        XCTAssertEqual(RequestFoodEntryView.presentation(isVerified: store.isVerified), .form)
    }

    // MARK: - Mid-form authority loss does not tear the admitted form down

    /// The latch `RequestFoodEntryView` applies to its own `onChange`: sticky
    /// once verified is ever seen true, unaffected by a later `false`.
    func testLatchStaysSetOnceVerifiedRegardlessOfLaterLoss() {
        XCTAssertFalse(
            RequestFoodEntryView.nextHasEnteredForm(previousHasEnteredForm: false, isVerified: false)
        )
        XCTAssertTrue(
            RequestFoodEntryView.nextHasEnteredForm(previousHasEnteredForm: false, isVerified: true)
        )
        // The exact regression: a legitimately admitted session losing
        // authority afterward must not clear the latch.
        XCTAssertTrue(
            RequestFoodEntryView.nextHasEnteredForm(previousHasEnteredForm: true, isVerified: false)
        )
        XCTAssertTrue(
            RequestFoodEntryView.nextHasEnteredForm(previousHasEnteredForm: true, isVerified: true)
        )
    }

    /// The full regression this MUST-FIX finding describes: a verified
    /// requester legitimately enters Request Food, fills a draft, submission
    /// receives a real `PARTICIPANT_AUTHORITY_INVALID`, the identity store
    /// discards the rejected identity through the exact production callback
    /// `RequestStore` invokes — and the entry screen's own presentation logic,
    /// now latched, keeps returning `.form` rather than reverting to
    /// `.verification` and destroying the mounted `RequestFoodView`'s draft.
    func testAuthorityInvalidAfterLegitimateFormAdmissionKeepsTheFormMounted() async throws {
        let identityStore = makeIdentityStore()
        let coordinator = ParticipantActionVerificationCoordinator(identityStore: identityStore)
        let requestStore = RequestStore(
            service: RequestService(client: client()),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { identityStore.currentAuthority() },
            participantAuthorityRejected: { identityStore.discardRejectedIdentity() }
        )

        // Legitimate admission: verify, then latch the way the view's own
        // `onChange` does.
        identityStore.beginVerificationIfNeeded()
        await completeVerification(identityStore)
        var hasEnteredForm = RequestFoodEntryView.nextHasEnteredForm(
            previousHasEnteredForm: false,
            isVerified: identityStore.isVerified
        )
        XCTAssertTrue(hasEnteredForm)
        XCTAssertEqual(
            RequestFoodEntryView.presentation(isVerified: identityStore.isVerified, hasEnteredForm: hasEnteredForm),
            .form
        )

        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "The exact filled draft",
            pickupName: "Taylor",
            timing: .asap,
            preferredPickupTime: Date(timeIntervalSince1970: 1_754_755_800)
        )

        // The real backend refusal `RequestFoodView.submit()` would receive
        // mid-form, driving the identity store's discard through the exact
        // callback `RequestStore` was constructed with above — not a manual
        // `discardRejectedIdentity()` call from the test.
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 403, data: errorResponse(code: ParticipantErrorCode.authorityInvalid))
        )
        do {
            try await requestStore.createRequest(CreateRequestPayload(
                vendor: draft.selectedDiningSpot!.name,
                food: draft.foodRequest,
                pickupName: draft.pickupName,
                timing: .asap,
                windowStart: nil,
                mealSwipes: 2
            ))
            XCTFail("expected the rejected authority to surface as an error")
        } catch {
            // Expected: the create itself fails.
        }

        XCTAssertFalse(identityStore.isVerified)

        // The regression: applying the same latch rule to this real loss must
        // not revert presentation to `.verification`.
        hasEnteredForm = RequestFoodEntryView.nextHasEnteredForm(
            previousHasEnteredForm: hasEnteredForm,
            isVerified: identityStore.isVerified
        )
        XCTAssertTrue(hasEnteredForm)
        XCTAssertEqual(
            RequestFoodEntryView.presentation(isVerified: identityStore.isVerified, hasEnteredForm: hasEnteredForm),
            .form
        )

        // Recovery is `RequestFoodView.submit()`'s own existing gate — it
        // checks `!identityStore.isVerified` and opens the in-form
        // continuation with this exact draft, never fabricating authority.
        XCTAssertTrue(coordinator.beginRequestCreation(draft: draft, path: [.requestFood]))
        let continuation = try XCTUnwrap(coordinator.pendingContinuation)

        // Cancellation/failure submits nothing.
        coordinator.requesterCancelled()
        XCTAssertNil(coordinator.pendingContinuation)
        XCTAssertNil(identityStore.pendingContinuation)
        XCTAssertFalse(identityStore.consumeContinuation(continuation))
        XCTAssertEqual(capturedRequestCount(path: "/api/request"), 1)

        // Successful reverification resumes only this exact draft, through
        // the same coordinator entry point `RequestFoodView` already uses.
        XCTAssertTrue(coordinator.beginRequestCreation(draft: draft, path: [.requestFood]))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: verifiedResponse()))
        await identityStore.requestCode(for: principal)
        let reverified = await identityStore.submitCode("424242")
        XCTAssertTrue(reverified)
        let newIdentity = try XCTUnwrap(identityStore.identity)
        let resume = coordinator.requesterIdentityDidChange(
            from: nil,
            to: newIdentity,
            path: [.requestFood]
        )
        guard case .requestCreation(let resumedDraft)? = resume else {
            return XCTFail("expected the exact requester continuation to resume")
        }
        XCTAssertEqual(resumedDraft, draft)
        XCTAssertEqual(capturedRequestCount(path: "/api/request"), 1)
    }

    /// The rereview finding: a repeat appearance of `RequestFoodEntryView`
    /// after admission — e.g. returning from backgrounding once a mid-form
    /// `PARTICIPANT_AUTHORITY_INVALID` cleared identity — must not let
    /// `onAppear` start another entry-owned `.firstVerification` flow. Doing
    /// so would occupy `identityStore.flow`, and
    /// `ParticipantIdentityStore.beginVerification(for:)` refuses to replace
    /// an existing flow, so `RequestFoodView`'s own coordinator-owned
    /// recovery could never start. This proves the repeat-appearance
    /// ownership boundary itself, not merely the latch predicate.
    func testRepeatAppearanceAfterAdmissionDoesNotStartAnEntryOwnedVerificationFlow() async throws {
        let identityStore = makeIdentityStore()
        let coordinator = ParticipantActionVerificationCoordinator(identityStore: identityStore)
        let requestStore = RequestStore(
            service: RequestService(client: client()),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { identityStore.currentAuthority() },
            participantAuthorityRejected: { identityStore.discardRejectedIdentity() }
        )

        // Legitimate admission, exactly as the entry view's own onAppear +
        // onChange would produce it.
        XCTAssertTrue(
            RequestFoodEntryView.shouldBeginEntryVerificationOnAppear(hasEnteredForm: false)
        )
        identityStore.beginVerificationIfNeeded()
        await completeVerification(identityStore)
        let hasEnteredForm = RequestFoodEntryView.nextHasEnteredForm(
            previousHasEnteredForm: false,
            isVerified: identityStore.isVerified
        )
        XCTAssertTrue(hasEnteredForm)

        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Palladium", address: nil),
            foodRequest: "The retained draft",
            pickupName: "Taylor",
            timing: .asap,
            preferredPickupTime: Date(timeIntervalSince1970: 1_754_755_800)
        )

        // A real mid-form authority-invalid response clears identity through
        // the exact production callback, not a manual call.
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 403, data: errorResponse(code: ParticipantErrorCode.authorityInvalid))
        )
        do {
            try await requestStore.createRequest(CreateRequestPayload(
                vendor: draft.selectedDiningSpot!.name,
                food: draft.foodRequest,
                pickupName: draft.pickupName,
                timing: .asap,
                windowStart: nil,
                mealSwipes: 2
            ))
            XCTFail("expected the rejected authority to surface as an error")
        } catch {
            // Expected.
        }
        XCTAssertFalse(identityStore.isVerified)

        // The repeat appearance: `hasEnteredForm` is still `true`, so
        // `onAppear`'s own guard must refuse to start another entry flow —
        // this is the exact call `RequestFoodEntryView.body`'s `.onAppear`
        // makes.
        XCTAssertFalse(
            RequestFoodEntryView.shouldBeginEntryVerificationOnAppear(hasEnteredForm: hasEnteredForm)
        )
        // Simulates the appearance itself calling the guarded onAppear body:
        // because the guard above is false, `beginVerificationIfNeeded()` is
        // never invoked, so no hidden `.firstVerification` flow is created.
        XCTAssertNil(identityStore.flow)

        // Presentation still resolves to the admitted form.
        XCTAssertEqual(
            RequestFoodEntryView.presentation(isVerified: identityStore.isVerified, hasEnteredForm: hasEnteredForm),
            .form
        )

        // Because no entry-owned flow occupied `identityStore.flow`,
        // `RequestFoodView`'s own coordinator-owned recovery can actually
        // start — the exact thing the bug silently prevented.
        XCTAssertTrue(coordinator.beginRequestCreation(draft: draft, path: [.requestFood]))
        let continuation = try XCTUnwrap(coordinator.pendingContinuation)

        // Cancellation/failure submits nothing further.
        coordinator.requesterCancelled()
        XCTAssertNil(coordinator.pendingContinuation)
        XCTAssertNil(identityStore.pendingContinuation)
        XCTAssertFalse(identityStore.consumeContinuation(continuation))
        XCTAssertEqual(capturedRequestCount(path: "/api/request"), 1)

        // Successful reverification resumes only this exact retained draft.
        XCTAssertTrue(coordinator.beginRequestCreation(draft: draft, path: [.requestFood]))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: verifiedResponse()))
        await identityStore.requestCode(for: principal)
        let reverified = await identityStore.submitCode("424242")
        XCTAssertTrue(reverified)
        let newIdentity = try XCTUnwrap(identityStore.identity)
        let resume = coordinator.requesterIdentityDidChange(
            from: nil,
            to: newIdentity,
            path: [.requestFood]
        )
        guard case .requestCreation(let resumedDraft)? = resume else {
            return XCTFail("expected the exact requester continuation to resume")
        }
        XCTAssertEqual(resumedDraft, draft)
        XCTAssertEqual(capturedRequestCount(path: "/api/request"), 1)
    }

    // MARK: - No second free-form participant-email field

    /// `RequestFoodEntryView` renders either the existing verification screen
    /// or `RequestFoodView` — never both, and never any email field of its
    /// own — so this screen cannot introduce a second identity source.
    func testEntryViewDeclaresNoEmailFieldOfItsOwn() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodEntryView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("TextField"))
    }

    // MARK: - Submission still uses verified participant authority

    /// Entry no longer gates Submit — it gates seeing the form at all — but
    /// the credential a create actually carries still comes from
    /// `ParticipantIdentityStore.currentAuthority()`, established by this same
    /// entry verification, not from anything the form collects.
    func testFormSubmissionCarriesTheAuthorityEntryVerificationEstablished() async throws {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()
        await completeVerification(store)
        XCTAssertEqual(RequestFoodEntryView.presentation(isVerified: store.isVerified), .form)

        let requestStore = RequestStore(
            service: RequestService(client: client()),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { store.currentAuthority() },
            participantAuthorityRejected: { store.discardRejectedIdentity() }
        )
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 201, data: createdResponse())
        )

        try await requestStore.createRequest(CreateRequestPayload(
            vendor: "Palladium",
            food: "Chicken bowl",
            pickupName: "Taylor",
            timing: .asap,
            windowStart: nil,
            mealSwipes: 2
        ))

        let headers = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedHeaders)
        XCTAssertEqual(headers["x-commonplate-participant"], canonicalParticipantAuthorityFixture)
    }

    // MARK: - Fixtures

    private func makeIdentityStore(
        storage: ParticipantIdentityStorage = InMemoryParticipantIdentityStorage()
    ) -> ParticipantIdentityStore {
        ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client()),
            storage: storage
        )
    }

    private func completeVerification(_ store: ParticipantIdentityStore) async {
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: verifiedResponse()))
        await store.requestCode(for: principal)
        let verified = await store.submitCode("424242")
        XCTAssertTrue(verified)
    }

    private func client() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        return APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
    }

    private func challengeResponse() -> Data {
        Data(#"{"verification":{"expiresAt":"2026-08-09T17:10:00.000Z","resendAvailableAt":"2026-08-09T17:01:00.000Z"}}"#.utf8)
    }

    private func verifiedResponse() -> Data {
        Data(#"{"participant":{"email":"\#(principal)"},"authority":"\#(canonicalParticipantAuthorityFixture)"}"#.utf8)
    }

    private func errorResponse(code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"detail","fields":null}}"#.utf8)
    }

    private func capturedRequestCount(path: String) -> Int {
        RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == path }.count
    }

    private func createdResponse() -> Data {
        Data(#"{"request":{"id":"64b0000000000000000000a1","vendor":"Palladium","food":"Chicken bowl","pickupWindowText":"ASAP","mealSwipes":2,"windowStart":null,"windowEnd":null,"status":"open","createdAt":"2026-08-09T17:00:00.000Z","expiresAt":"2026-08-09T20:00:00.000Z"}}"#.utf8)
    }

    /// Walks up from this file to the repository root, matching the pattern
    /// used elsewhere for source-text assertions against the real tracked file.
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
