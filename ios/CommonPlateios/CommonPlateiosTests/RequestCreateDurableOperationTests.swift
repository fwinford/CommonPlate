//
//  RequestCreateDurableOperationTests.swift
//  CommonPlateiosTests
//
// Focused W3-D1 Pass 2 coverage: the exact logical request-create operation
// identity, its durable recovery record, and relaunch reconciliation. Reuses
// `RequestFetchingURLProtocol` from `RequestFetchingTests.swift` — the same
// stubbed-transport double every other request-flow test file already uses —
// rather than inventing a second one.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class RequestCreateDurableOperationTests: XCTestCase {
    /// Two distinct verified participants. Only the leading (participant-ID)
    /// segment before the first "." matters to `RequestStore`'s binding
    /// check; the remainder is shape filler.
    private let authorityA = "64c0000000000000000000a1.1." + String(repeating: "A", count: 42) + "A"
    private let authorityB = "64c0000000000000000000b2.1." + String(repeating: "B", count: 42) + "A"
    private let participantIdentifierA = "64c0000000000000000000a1"

    /// A fresh `UserDefaults` suite per test, removed in `tearDown` — matching
    /// `PushInstallationStorageTests`/`AlertSignupPresentationTests`: nothing
    /// here can read or write the developer's real preferences (required
    /// proof: persistence isolated in tests).
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        suiteName = "RequestCreateDurableOperationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Ordinary success retires durable state (proofs 1, 2, 3)

    func testOrdinarySuccessfulCreateSendsOneValidOperationHeaderAndRetiresDurableState() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(food: "Fresh create food"))
        ))

        try await store.createRequest(asapPayload(food: "Fresh create food"))

        let headers = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedHeaders)
        let sentOperationId = try XCTUnwrap(headers[RequestService.operationIdentityHeader])
        XCTAssertTrue(Self.looksLikeAValidOperationId(sentOperationId))
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(store.requests.map(\.foodDescription), ["Fresh create food"])
    }

    // MARK: - Ambiguous transport persists the exact operation and blocks a
    // second ordinary create (proofs 5, 10, 14)

    func testAmbiguousTransportPersistsExactOperationAndBlocksSecondCreate() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))

        do {
            try await store.createRequest(asapPayload(food: "Ambiguous distinct food", mealSwipes: 4))
            XCTFail("Transport loss after submission should be ambiguous")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }

        let headers = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedHeaders)
        let sentOperationId = try XCTUnwrap(headers[RequestService.operationIdentityHeader])
        XCTAssertTrue(Self.looksLikeAValidOperationId(sentOperationId))

        let record = try XCTUnwrap(storage.load())
        XCTAssertEqual(record, PendingRequestOperationRecord(
            operationId: sentOperationId,
            participantIdentifier: participantIdentifierA,
            vendor: "Palladium",
            food: "Ambiguous distinct food",
            pickupName: "Taylor",
            timing: .asap,
            windowStart: nil,
            mealSwipes: 4
        ))
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)

        // A second ordinary submission — including one whose transport would
        // have succeeded — must never reach the network while the durable
        // operation is unresolved.
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(food: "Would-be second request"))
        ))
        do {
            try await store.createRequest(asapPayload(food: "Would-be second request"))
            XCTFail("A second create must be blocked while the operation is unresolved")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected: the store republishes the same unresolved ambiguity.
        }
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == "/api/request" }.count,
            1
        )
    }

    // MARK: - Relaunch reconciliation (proofs 6, 7, 8, 9, 17)

    func testRelaunchReconciliationReusesExactOperationIdentityAndPayload() async throws {
        let windowStart = try iso8601Date("2026-08-10T19:00:00.000Z")
        let sharedStorage = UserDefaultsPendingRequestOperationStorage(defaults: defaults)

        // "First process": an intentional scheduled submission whose response
        // is lost.
        let storeBeforeTermination = makeStore(authority: authorityA, operationStorage: sharedStorage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))
        do {
            try await storeBeforeTermination.createRequest(
                scheduledPayload(food: "Later distinct food", windowStart: windowStart, mealSwipes: 5)
            )
            XCTFail("Expected an ambiguous outcome")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }
        let firstAttemptHeaders = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedHeaders)
        let originalOperationId = try XCTUnwrap(firstAttemptHeaders[RequestService.operationIdentityHeader])

        // "Relaunch": a brand-new store, reading the same durable storage —
        // in-memory state from the terminated process is gone, but the
        // durable record survives the round trip through real UserDefaults
        // JSON encoding/decoding.
        let storeAfterRelaunch = makeStore(
            authority: authorityA,
            operationStorage: UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        )
        XCTAssertFalse(storeAfterRelaunch.hasUnresolvedCreateAmbiguity)

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 200,
            data: createResponse(requestObject: requestObject(
                id: "reconciled-request",
                food: "Later distinct food",
                pickupWindowText: "7:00 PM",
                mealSwipes: 5,
                windowStart: "2026-08-10T19:00:00.000Z",
                windowEnd: "2026-08-10T22:00:00.000Z"
            ))
        ))
        let didCreate = await storeAfterRelaunch.reconcilePendingCreateOperationIfNeeded()

        XCTAssertTrue(didCreate)
        let secondAttemptHeaders = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedHeaders)
        XCTAssertEqual(
            secondAttemptHeaders[RequestService.operationIdentityHeader],
            originalOperationId,
            "Reconciliation must reuse the exact original operation identity, never mint a new one"
        )

        let secondBody = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: secondBody) as? [String: Any])
        XCTAssertEqual(json["food"] as? String, "Later distinct food")
        XCTAssertEqual(json["vendor"] as? String, "Palladium")
        XCTAssertEqual(json["pickupName"] as? String, "Taylor")
        XCTAssertEqual(json["mealSwipes"] as? Int, 5)
        XCTAssertEqual(json["timing"] as? String, "scheduled")
        XCTAssertNotNil(json["windowStart"])

        XCTAssertFalse(storeAfterRelaunch.hasUnresolvedCreateAmbiguity)
        XCTAssertNil(sharedStorage.load())
        XCTAssertEqual(storeAfterRelaunch.requests.map(\.id), ["reconciled-request"])
    }

    func testReconciliationWithNothingDurableIsANoOp() async {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
    }

    func testRepeatedReconciliationCannotProduceMultipleLogicalOperations() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))
        do {
            try await store.createRequest(asapPayload(food: "Racing recovery food"))
            XCTFail("Expected an ambiguous outcome")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }

        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 200,
            data: createResponse(requestObject: requestObject(food: "Racing recovery food")),
            gate: gate
        ))

        let inFlightReconciliation = Task {
            await store.reconcilePendingCreateOperationIfNeeded()
        }
        await waitUntil { gate.isWaiting }

        // A second reconciliation attempt while the first is still in flight
        // must not start its own network call.
        let concurrentResult = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertFalse(concurrentResult)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == "/api/request" }.count,
            2 // the original ambiguous attempt, plus the one in-flight reconciliation
        )

        gate.open()
        let firstResult = await inFlightReconciliation.value
        XCTAssertTrue(firstResult)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == "/api/request" }.count,
            2
        )
    }

    // MARK: - Terminal expiry (proofs 11, 12)

    func testOperationExpiredRetiresTheOperationAndCreatesNothing() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))
        do {
            try await store.createRequest(asapPayload(food: "Will expire"))
            XCTFail("Expected an ambiguous outcome")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 410,
            data: errorResponse(code: RequestOperationErrorCode.operationExpired)
        ))
        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertTrue(store.requests.isEmpty)
    }

    func testLaterIntentionalSubmissionAfterExpiryMintsADifferentOperationIdentityAndSucceeds() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))
        do {
            try await store.createRequest(asapPayload(food: "Will expire"))
            XCTFail("Expected an ambiguous outcome")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }
        let originalOperationId = try XCTUnwrap(
            RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.operationIdentityHeader]
        )

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 410,
            data: errorResponse(code: RequestOperationErrorCode.operationExpired)
        ))
        _ = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(
                id: "fresh-after-expiry",
                food: "A brand new request"
            ))
        ))
        try await store.createRequest(asapPayload(food: "A brand new request"))

        let newOperationId = try XCTUnwrap(
            RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.operationIdentityHeader]
        )
        XCTAssertNotEqual(newOperationId, originalOperationId)
        XCTAssertEqual(store.requests.map(\.id), ["fresh-after-expiry"])
    }

    // MARK: - Invalid operation identity (proof 13)

    func test400InvalidOperationIdIsDefinitiveNonCreateAndRetiresDurableState() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 400,
            data: errorResponse(code: RequestOperationErrorCode.invalidOperationId)
        ))

        do {
            try await store.createRequest(asapPayload(food: "Malformed identity"))
            XCTFail("Expected a definitive INVALID_OPERATION_ID refusal")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, RequestOperationErrorCode.invalidOperationId)
        }

        // Definitive, not ambiguous: nothing is left durable, and the block
        // is never armed.
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
    }

    // MARK: - Unauthorized (proof 15)

    func test403OperationUnauthorizedCannotLeakStateOrAutoRetryAndRetiresOperation() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))
        do {
            try await store.createRequest(asapPayload(food: "Later refused"))
            XCTFail("Expected an ambiguous outcome")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 403,
            data: errorResponse(code: RequestOperationErrorCode.operationUnauthorized)
        ))
        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertTrue(store.requests.isEmpty)

        // No automatic follow-up: with nothing durable left, a later
        // reconciliation call is a pure no-op.
        let requestCountAfterUnauthorized = RequestFetchingURLProtocol.capturedRequestedPaths
            .filter { $0 == "/api/request" }.count
        let secondAttempt = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertFalse(secondAttempt)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == "/api/request" }.count,
            requestCountAfterUnauthorized
        )
    }

    // MARK: - Wrong-participant restoration (proof 16)

    func testRestoredRecordCannotBeReconciledUnderADifferentParticipant() async throws {
        let sharedStorage = UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        let storeForA = makeStore(authority: authorityA, operationStorage: sharedStorage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))
        do {
            try await storeForA.createRequest(asapPayload(food: "Belongs to participant A"))
            XCTFail("Expected an ambiguous outcome")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == "/api/request" }.count,
            1
        )

        // A different verified participant on the same installation (however
        // that came to be) must not be able to reconcile, discover, or act
        // on participant A's still-unresolved operation.
        let storeForB = makeStore(authority: authorityB, operationStorage: sharedStorage)
        let didCreate = await storeForB.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertFalse(storeForB.hasUnresolvedCreateAmbiguity)
        XCTAssertTrue(storeForB.requests.isEmpty)
        // No network call was made on B's behalf against A's operation.
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == "/api/request" }.count,
            1
        )
        // A's durable record is left exactly as it was — not deleted, not
        // exposed, not folded into a fresh create.
        XCTAssertNotNil(sharedStorage.load())

        // Participant B, meanwhile, is not blocked from an ordinary create of
        // their own.
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(
                id: "participant-b-request",
                food: "Belongs to participant B"
            ))
        ))
        try await storeForB.createRequest(asapPayload(food: "Belongs to participant B"))
        XCTAssertEqual(storeForB.requests.map(\.id), ["participant-b-request"])
    }

    // MARK: - Ordinary pre-write rejections are also definitive non-create
    // (independent-review MUST FIX 1)

    /// The daily-limit refusal — the most easily reachable ordinary rejection
    /// in real use — must retire durable state exactly like the three
    /// operation-identity-specific codes do, so a quota-refused attempt
    /// cannot resurface as an unintended creation once quota resets, nor
    /// permanently block later intentional submissions.
    func testQuotaRejectionOnFreshCreateRetiresDurableStateAndDoesNotBlockLaterCreate() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 429,
            data: errorResponse(code: RequestOperationErrorCode.requestLimitReached)
        ))

        do {
            try await store.createRequest(asapPayload(food: "Over quota"))
            XCTFail("Expected a definitive REQUEST_LIMIT_REACHED refusal")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, RequestOperationErrorCode.requestLimitReached)
        }

        // Definitive, not ambiguous: nothing is left durable that a later
        // relaunch could replay as an unintended, quota-refused-then-forgotten
        // creation, and the requester is not blocked from a real next attempt.
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(
                id: "after-quota-refusal",
                food: "A different request"
            ))
        ))
        try await store.createRequest(asapPayload(food: "A different request"))
        XCTAssertEqual(store.requests.map(\.id), ["after-quota-refusal"])
    }

    /// The same property for the remaining pre-write ordinary rejections
    /// `createRequestRoute.ts` can return before any write: an unsupported
    /// vendor, a generic shape failure, and a submitted address that does not
    /// match the verified principal. `PARTICIPANT_PRINCIPAL_MISMATCH` and
    /// `INVALID_REQUEST`/`INVALID_VENDOR` are not reachable through this
    /// app's own payload construction, but the classifier must still resolve
    /// them correctly if the backend ever returns one — for example against
    /// an older installed build with a stale vendor list.
    func testRemainingOrdinaryPreWriteRejectionsAreDefinitiveNonCreate() async throws {
        for code in [
            RequestOperationErrorCode.invalidVendor,
            RequestOperationErrorCode.invalidRequest,
            RequestOperationErrorCode.participantPrincipalMismatch,
        ] {
            let storage = InMemoryPendingRequestOperationStorage()
            let store = makeStore(authority: authorityA, operationStorage: storage)
            RequestFetchingURLProtocol.enqueue(.response(
                statusCode: 400,
                data: errorResponse(code: code)
            ))

            do {
                try await store.createRequest(asapPayload(food: "Refused: \(code)"))
                XCTFail("Expected a definitive \(code) refusal")
            } catch RequestServiceError.serverError(let receivedCode, _) {
                XCTAssertEqual(receivedCode, code)
            }

            XCTAssertNil(storage.load())
            XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        }
    }

    // MARK: - Route-level definitive pre-write refusals

    func testRateLimitedRetiresDurableStateAndCannotReplayAfterRelaunch() async throws {
        try await assertRouteLevelDefinitiveNonCreate(
            label: "RATE_LIMITED",
            firstResponse: .response(
                statusCode: 429,
                data: errorResponse(code: RequestOperationErrorCode.rateLimited)
            ),
            matchesExpectedError: { error in
                guard case RequestServiceError.serverError(let code, _) = error else { return false }
                return code == RequestOperationErrorCode.rateLimited
            }
        )
    }

    func testBareNotFoundRetiresDurableStateAndCannotReplayAfterRelaunch() async throws {
        try await assertRouteLevelDefinitiveNonCreate(
            label: "bare 404",
            firstResponse: .response(
                statusCode: 404,
                data: Data("Cannot POST /api/request".utf8)
            ),
            matchesExpectedError: { error in
                guard case RequestServiceError.notFound = error else { return false }
                return true
            }
        )
    }

    func testRouteLevelDefinitiveRefusalsDuringReconciliationRetireDurableState() async {
        let cases: [(String, RequestFetchingURLProtocol.Stub)] = [
            (
                "RATE_LIMITED",
                .response(
                    statusCode: 429,
                    data: errorResponse(code: RequestOperationErrorCode.rateLimited)
                )
            ),
            (
                "bare 404",
                .response(statusCode: 404, data: Data("Cannot POST /api/request".utf8))
            ),
        ]

        for (label, response) in cases {
            RequestFetchingURLProtocol.reset()
            let storage = InMemoryPendingRequestOperationStorage()
            storage.save(PendingRequestOperationRecord(
                operationId: "reconcile-\(label.replacingOccurrences(of: " ", with: "-"))",
                participantIdentifier: participantIdentifierA,
                vendor: "Palladium",
                food: "Previously unresolved \(label)",
                pickupName: "Taylor",
                timing: .asap,
                windowStart: nil,
                mealSwipes: 2
            ))
            let store = makeStore(authority: authorityA, operationStorage: storage)
            RequestFetchingURLProtocol.enqueue(response)

            let didCreate = await store.reconcilePendingCreateOperationIfNeeded()
            XCTAssertFalse(didCreate)
            XCTAssertNil(storage.load(), "\(label) must retire the restored operation")
            XCTAssertFalse(store.hasUnresolvedCreateAmbiguity, "\(label) must not leave a create block")
        }
    }

    /// `REQUEST_CREATION_FAILED` must never be treated as definitive-non-create:
    /// `createRequestRoute.ts` returns that same code from the outer catch
    /// wrapping the write itself, so a client that received it cannot prove
    /// no write occurred. `RequestService.createRequest` decodes a readable
    /// error envelope here as `.serverError` — pre-existing, accepted
    /// behavior this fix must not touch (`RequestFetchingTests.swift`'s
    /// `testCreatePreservesStructuredBackendErrorCodes` already pins it, and
    /// `RequestCreationViewTests.swift` already pins the resulting
    /// "please try again" presentation) — so the *presented* error is
    /// unchanged. But because the write outcome remains unproven, D1 requires
    /// more than record preservation: the exact operation X this attempt
    /// began must stay unresolved and blocking, exactly like an ambiguous
    /// transport outcome, so a same-session retry cannot mint a replacement
    /// operation Y that silently overwrites X's only durable recovery state
    /// (independent-review MUST FIX: received `REQUEST_CREATION_FAILED`).
    func testGenericCreationFailureDoesNotRetireTheDurableRecordAndBlocksASecondCreate() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 500,
            data: errorResponse(code: "REQUEST_CREATION_FAILED")
        ))

        do {
            try await store.createRequest(asapPayload(food: "Uncertain outcome X"))
            XCTFail("Expected REQUEST_CREATION_FAILED to surface as a server error")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, "REQUEST_CREATION_FAILED")
        }

        // Not classified as definitive-non-create, so the record this
        // attempt (X) wrote is preserved rather than discarded — a relaunch
        // can still reconcile it if the write this response could not rule
        // out actually happened.
        let recordForX = try XCTUnwrap(storage.load())
        XCTAssertEqual(recordForX.food, "Uncertain outcome X")

        // The write result is unproven, so this must block exactly like an
        // in-process ambiguous transport outcome does.
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)

        // A second intentional submission (Y) must never reach the network,
        // and must never overwrite X's durable record, while X remains
        // unresolved. Deliberately nothing enqueued for it: if it were ever
        // transmitted, `RequestFetchingURLProtocol` would fail the test on
        // an unconfigured request rather than let it silently succeed.
        do {
            try await store.createRequest(asapPayload(food: "Would-be second request Y"))
            XCTFail("A second create must be blocked while operation X is unresolved")
        } catch RequestServiceError.serverError(let code, _) {
            // The store republishes the same unresolved error rather than
            // attempting Y.
            XCTAssertEqual(code, "REQUEST_CREATION_FAILED")
        }
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == "/api/request" }.count,
            1,
            "Y must never be transmitted while X is unresolved"
        )

        // X's exact durable record — operation identity and payload — must
        // be untouched by the blocked attempt at Y.
        XCTAssertEqual(storage.load(), recordForX)

        // Authoritative reconciliation can still resolve X, exactly as any
        // other unresolved operation would be recovered — proven generally
        // by `testRelaunchReconciliationReusesExactOperationIdentityAndPayload`
        // and `testRepeatedReconciliationCannotProduceMultipleLogicalOperations`;
        // confirmed directly here for this exact code path.
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(
                id: "recovered-x",
                food: "Uncertain outcome X"
            ))
        ))
        let didRecoverX = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertTrue(didRecoverX)
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(store.requests.map(\.id), ["recovered-x"])
    }

    /// The identical property during relaunch reconciliation: an ordinary
    /// pre-write rejection encountered on replay must retire the durable
    /// record and the block, not leave the requester stuck.
    func testQuotaRejectionDuringReconciliationRetiresDurableState() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))
        do {
            try await store.createRequest(asapPayload(food: "Will be over quota on relaunch"))
            XCTFail("Expected an ambiguous outcome")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 429,
            data: errorResponse(code: RequestOperationErrorCode.requestLimitReached)
        ))
        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
    }

    // MARK: - Pre-transmission cancellation (independent-review MUST FIX 2)

    /// `RequestService.createRequest`'s own leading `Task.checkCancellation()`
    /// is the only point that lets a raw `CancellationError` reach
    /// `RequestStore`; every later cancellation is wrapped as
    /// `.ambiguousCreateOutcome`. Cancelling before the task's synchronous
    /// prefix (mint id, persist record) has a chance to run guarantees this
    /// exact pre-transmission boundary, since the newly created unstructured
    /// `Task` cannot begin running until this synchronous test method
    /// suspends.
    func testCancellationBeforeTransmissionRetiresTheJustSavedRecordAndSendsNothing() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        // Deliberately nothing enqueued: if this ever reached the network,
        // `RequestFetchingURLProtocol` would fail the test on an unconfigured
        // request rather than let it silently succeed.

        let task = Task { @MainActor in
            try await store.createRequest(asapPayload(food: "Cancelled before it could be sent"))
        }
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)

        // Nothing was left behind to interfere with a real later submission.
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(
                id: "after-cancelled-attempt",
                food: "The real submission"
            ))
        ))
        try await store.createRequest(asapPayload(food: "The real submission"))
        XCTAssertEqual(store.requests.map(\.id), ["after-cancelled-attempt"])
    }

    /// Reconciliation's own cancellation handling is unchanged: a record that
    /// predates the recovery attempt (restored from a previous process) must
    /// survive cancellation of that attempt untouched, so a later relaunch or
    /// retry can still reconcile the exact same operation.
    func testCancellationDuringReconciliationLeavesThePredatingRecordUntouched() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        storage.save(PendingRequestOperationRecord(
            operationId: "predates-this-reconciliation-attempt",
            participantIdentifier: participantIdentifierA,
            vendor: "Palladium",
            food: "Still recoverable",
            pickupName: "Taylor",
            timing: .asap,
            windowStart: nil,
            mealSwipes: 2
        ))
        let store = makeStore(authority: authorityA, operationStorage: storage)

        let task = Task { @MainActor in
            await store.reconcilePendingCreateOperationIfNeeded()
        }
        task.cancel()
        let didCreate = await task.value

        XCTAssertFalse(didCreate)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        // Unchanged from before the attempt: still present, still armed.
        XCTAssertEqual(storage.load()?.operationId, "predates-this-reconciliation-attempt")
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
    }

    // MARK: - Replay preserves the current installation association
    // (independent-review SHOULD FIX 3)

    func testReconciliationReplaySendsTheCurrentInstallationCredential() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        storage.save(PendingRequestOperationRecord(
            operationId: "needs-installation-association",
            participantIdentifier: participantIdentifierA,
            vendor: "Palladium",
            food: "Never actually transmitted originally",
            pickupName: "Taylor",
            timing: .asap,
            windowStart: nil,
            mealSwipes: 2
        ))
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(
                id: "recovered-with-installation",
                food: "Never actually transmitted originally"
            ))
        ))

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertTrue(didCreate)
        let body = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(
            json["installationCredential"] as? String,
            "test-installation-credential",
            "Reconciliation must re-attach the current installation credential, exactly like a fresh create"
        )
    }

    // MARK: - Malformed restored state fails safely

    func testMalformedDurableRecordIsRetiredRatherThanReconciled() async {
        let storage = InMemoryPendingRequestOperationStorage()
        // A scheduled record with no window start can never have been
        // produced by `createRequest` itself — simulates corrupted or
        // otherwise unusable restored state.
        storage.save(PendingRequestOperationRecord(
            operationId: "not-a-real-operation-id",
            participantIdentifier: participantIdentifierA,
            vendor: "Palladium",
            food: "Corrupted",
            pickupName: "Taylor",
            timing: .scheduled,
            windowStart: nil,
            mealSwipes: 2
        ))
        let store = makeStore(authority: authorityA, operationStorage: storage)

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
    }

    // MARK: - Helpers

    private func makeStore(
        authority: String?,
        operationStorage: PendingRequestOperationStorage
    ) -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { authority },
            participantAuthorityRejected: {},
            operationStorage: operationStorage
        )
    }

    private func assertRouteLevelDefinitiveNonCreate(
        label: String,
        firstResponse: RequestFetchingURLProtocol.Stub,
        matchesExpectedError: (Error) -> Bool
    ) async throws {
        let storage = RecordingPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(firstResponse)

        do {
            try await store.createRequest(asapPayload(food: "Refused operation X: \(label)"))
            XCTFail("Expected \(label) to refuse operation X")
        } catch {
            XCTAssertTrue(matchesExpectedError(error), "Unexpected \(label) error: \(error)")
        }

        // X was durably saved before its POST, then retired because the
        // received response proves no create handler write could have begun.
        let operationX = try XCTUnwrap(storage.savedRecords.last)
        XCTAssertEqual(storage.savedRecords.count, 1)
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)

        // A reconstructed store has nothing to reconcile, so X cannot be
        // replayed after termination/relaunch.
        let relaunchedStore = makeStore(authority: authorityA, operationStorage: storage)
        let didReplayX = await relaunchedStore.reconcilePendingCreateOperationIfNeeded()
        XCTAssertFalse(didReplayX)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == "/api/request" }.count,
            1
        )

        // A later intentional submission is a new logical operation.
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(
                id: "after-\(label)",
                food: "Later operation Y: \(label)"
            ))
        ))
        try await store.createRequest(asapPayload(food: "Later operation Y: \(label)"))
        let operationY = try XCTUnwrap(
            RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.operationIdentityHeader]
        )
        XCTAssertNotEqual(operationY, operationX.operationId)
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestService(client: client)
    }

    private func asapPayload(food: String, mealSwipes: Int = 2) -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Palladium",
            food: food,
            pickupName: "Taylor",
            timing: .asap,
            windowStart: nil,
            mealSwipes: mealSwipes
        )
    }

    private func scheduledPayload(
        food: String,
        windowStart: Date,
        mealSwipes: Int = 3
    ) -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Palladium",
            food: food,
            pickupName: "Taylor",
            timing: .scheduled,
            windowStart: windowStart,
            mealSwipes: mealSwipes
        )
    }

    private func requestObject(
        id: String = "64b0000000000000000000a1",
        vendor: String = "Palladium",
        food: String = "Chicken bowl",
        pickupWindowText: String = "ASAP",
        mealSwipes: Int = 2,
        windowStart: String? = nil,
        windowEnd: String? = nil,
        status: String = "open",
        createdAt: String = "2026-08-09T17:00:00.000Z",
        expiresAt: String = "2026-08-09T20:00:00.000Z"
    ) -> String {
        let windowStartJSON = windowStart.map { "\"\($0)\"" } ?? "null"
        let windowEndJSON = windowEnd.map { "\"\($0)\"" } ?? "null"
        return """
        {
          "id": "\(id)",
          "vendor": "\(vendor)",
          "food": "\(food)",
          "pickupWindowText": "\(pickupWindowText)",
          "mealSwipes": \(mealSwipes),
          "windowStart": \(windowStartJSON),
          "windowEnd": \(windowEndJSON),
          "status": "\(status)",
          "createdAt": "\(createdAt)",
          "expiresAt": "\(expiresAt)"
        }
        """
    }

    private func createResponse(requestObject: String) -> Data {
        Data(#"{"request":\#(requestObject)}"#.utf8)
    }

    private func errorResponse(code: String, message: String = "backend detail") -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)"}}"#.utf8)
    }

    private func iso8601Date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(formatter.date(from: value))
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

    private static func looksLikeAValidOperationId(_ value: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return (1...128).contains(value.count) && value.allSatisfy { allowed.contains($0) }
    }
}

private final class RecordingPendingRequestOperationStorage: PendingRequestOperationStorage {
    private var record: PendingRequestOperationRecord?
    private(set) var savedRecords: [PendingRequestOperationRecord] = []

    func load() -> PendingRequestOperationRecord? {
        record
    }

    func save(_ record: PendingRequestOperationRecord) -> Bool {
        self.record = record
        savedRecords.append(record)
        return true
    }

    func clear() {
        record = nil
    }
}
