import Foundation
import XCTest
@testable import CommonPlateios

/// Stub transport for the Day 4 claim and extension slice. It keeps its own
/// queue and captured requests rather than sharing `RequestFetchingURLProtocol`'s
/// statics, so neither suite can consume the other's stubs.
final class ClaimFlowURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data
        let errorCode: URLError.Code?
        let gate: RequestFetchingGate?

        static func response(
            statusCode: Int = 200,
            data: Data,
            gate: RequestFetchingGate? = nil
        ) -> Stub {
            Stub(statusCode: statusCode, data: data, errorCode: nil, gate: gate)
        }

        static func failure(_ errorCode: URLError.Code, gate: RequestFetchingGate? = nil) -> Stub {
            Stub(statusCode: 0, data: Data(), errorCode: errorCode, gate: gate)
        }
    }

    struct CapturedRequest {
        let path: String
        let method: String
        let body: Data?

        var bodyObject: [String: Any]? {
            guard let body else { return nil }
            return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
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

    static var capturedPaths: [String] {
        capturedRequests.map(\.path)
    }

    private static func dequeue() -> Stub? {
        lock.lock()
        defer { lock.unlock() }
        guard !stubs.isEmpty else { return nil }
        return stubs.removeFirst()
    }

    /// `URLProtocol` receives the body as a stream once the request has been
    /// handed to the loading system, so `httpBody` alone would silently capture
    /// nothing for the extension POST.
    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1_024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(
            CapturedRequest(
                path: request.url?.path ?? "",
                method: request.httpMethod ?? "",
                body: Self.readBody(from: request)
            )
        )
        Self.lock.unlock()

        guard let stub = Self.dequeue() else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        let completeRequest = {
            if let errorCode = stub.errorCode {
                self.client?.urlProtocol(self, didFailWithError: URLError(errorCode))
                return
            }
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

        if let gate = stub.gate {
            gate.wait(completeRequest)
        } else {
            completeRequest()
        }
    }

    override func stopLoading() {}
}

@MainActor
final class ClaimFlowTests: XCTestCase {
    private let requestID = "meal-a"

    /// The one sentence that stops a second real-world order. It is reproduced
    /// verbatim — never paraphrased — in every state where another Grubhub
    /// order would cost a student money, so it is asserted from one constant.
    static let safetySentence = "Don’t place another Grubhub order."

    /// Re-submitting to CommonPlate is safe wherever the backend would answer a
    /// repeat with REQUEST_ALREADY_PLACED. Where that retry is offered, the copy
    /// must separate it from ordering again.
    static let inAppRetryDisclaimer =
        "Trying again here only updates CommonPlate. It does not place another Grubhub order."

    override func tearDown() {
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Status vocabulary

    func testCurrentBackendListVocabularyDecodesAsOpen() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", status: "open"),
            requestObject(id: "b", status: "open")
        ])))

        let requests = try await makeService().fetchActiveRequests()

        XCTAssertEqual(requests.map(\.id), ["a", "b"])
        XCTAssertEqual(requests.map(\.status), [.open, .open])
    }

    func testClaimedAndPlacedWireValuesStillDecode() throws {
        XCTAssertEqual(try decodeStatus("open"), .open)
        XCTAssertEqual(try decodeStatus("claimed"), .claimed)
        XCTAssertEqual(try decodeStatus("placed"), .placed)
    }

    /// The superseded value is no longer part of the contract. It must fail to
    /// decode rather than quietly mapping to `.open`, which would let a stale
    /// backend look healthy.
    func testSupersededRequestedWireValueIsRejected() {
        XCTAssertThrowsError(try decodeStatus("requested"))
    }

    func testListFetchWithCurrentVocabularyDoesNotPublishAnError() async {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", status: "open")
        ])))

        await store.fetchRequests()

        XCTAssertTrue(store.hasSuccessfullyFetchedRequests)
        XCTAssertNil(store.initialFetchError)
        XCTAssertEqual(store.requests.map(\.status), [.open])
    }

    // MARK: - Starting a claim

    func testTappingHelpSendsExactlyOneClaimRequest() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))

        try await store.claim(requestID: requestID)

        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedRequests.map(\.path),
            ["/api/request/\(requestID)/claim"]
        )
        XCTAssertEqual(ClaimFlowURLProtocol.capturedRequests.map(\.method), ["POST"])
    }

    func testRepeatedTapsWhileClaimingDoNotSendDuplicateClaims() async throws {
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(), gate: claimGate))

        let firstClaim = Task { try await store.claim(requestID: requestID) }
        await waitUntil { claimGate.isWaiting }
        XCTAssertTrue(store.isClaiming)

        for _ in 0..<3 {
            do {
                try await store.claim(requestID: requestID)
                XCTFail("A duplicate claim should not start")
            } catch RequestServiceError.operationInProgress {
                // Expected: rejected before any request is built.
            } catch {
                XCTFail("Unexpected duplicate-claim error: \(error)")
            }
        }

        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.count, 1)

        claimGate.open()
        try await firstClaim.value

        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.count, 1)
        XCTAssertFalse(store.isClaiming)
    }

    func testNoNavigationAndNoPickupNameBeforeConfirmedSuccess() async throws {
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(), gate: claimGate))

        let claim = Task { try await store.claim(requestID: requestID) }
        await waitUntil { claimGate.isWaiting }

        // In flight: loading is visible, but nothing claimant-private exists yet.
        XCTAssertTrue(store.isClaiming)
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(
            RequestDetailView.opensClaimedFlow(
                activeClaim: store.activeClaim,
                requestID: requestID
            )
        )

        claimGate.open()
        try await claim.value

        XCTAssertTrue(
            RequestDetailView.opensClaimedFlow(
                activeClaim: store.activeClaim,
                requestID: requestID
            )
        )
    }

    func testConfirmedClaimRevealsPickupNameAndOpensTheFulfillmentFlow() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(pickupName: "Taylor")))

        try await store.claim(requestID: requestID)

        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(claim.requestID, requestID)
        XCTAssertEqual(claim.pickupName, "Taylor")
        XCTAssertEqual(store.requests.first?.status, .claimed)
        XCTAssertTrue(
            RequestDetailView.opensClaimedFlow(activeClaim: claim, requestID: requestID)
        )
        // A different request's screen must not open on someone else's claim.
        XCTAssertFalse(
            RequestDetailView.opensClaimedFlow(activeClaim: claim, requestID: "other-meal")
        )
    }

    func testAmbiguousClaimCreatesNoClaimAndOpensNothing() async {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))

        do {
            try await store.claim(requestID: requestID)
            XCTFail("Transport loss after submission should be ambiguous")
        } catch RequestServiceError.ambiguousClaimOutcome {
            // Expected.
        } catch {
            XCTFail("Unexpected ambiguous-claim error: \(error)")
        }

        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.claimUnavailableNotice)
        XCTAssertEqual(
            ClaimPresentationError.map(try XCTUnwrap(store.claimError(for: requestID))),
            .ambiguous
        )
        // No automatic retry of a non-idempotent POST.
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.count, 1)
        // The action is withdrawn rather than offered again.
        XCTAssertFalse(RequestDetailView.showsClaimAction(for: .ambiguous))
    }

    func testMismatchedClaimResponseIDIsAmbiguous() async {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            responseRequestID: "different-request"
        )))

        do {
            try await store.claim(requestID: requestID)
            XCTFail("A mismatched response ID must not activate a claim")
        } catch RequestServiceError.ambiguousClaimOutcome {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(
            ClaimPresentationError.map(store.claimError(for: requestID)!),
            .ambiguous
        )
    }

    func testSuccessfulClaimResponseWithOpenStatusIsAmbiguous() async {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            responseStatus: "open"
        )))

        do {
            try await store.claim(requestID: requestID)
            XCTFail("A claim response must confirm claimed status")
        } catch RequestServiceError.ambiguousClaimOutcome {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(
            ClaimPresentationError.map(store.claimError(for: requestID)!),
            .ambiguous
        )
    }

    // MARK: - One active claim at a time

    /// A second confirmed claim would replace the first claim's presentation,
    /// its private token, and its lifecycle timer, leaving that request
    /// reserved on the backend with no local claimant state. Week 2 has no
    /// release endpoint, so the second claim must never start.
    func testSecondClaimIsRejectedWhileAnotherClaimIsActive() async throws {
        let requestB = "meal-b"
        let store = makeStore()
        let claimExpiresAt = Date().addingTimeInterval(10 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimToken: "token-for-a",
            claimExpiresAt: claimExpiresAt
        )))
        try await store.claim(requestID: requestID)

        let pathsAfterFirstClaim = ClaimFlowURLProtocol.capturedPaths

        do {
            try await store.claim(requestID: requestB)
            XCTFail("A second claim must not start while one is already held")
        } catch RequestServiceError.existingActiveClaim {
            // Expected: refused before any request is built, and reported as
            // "you already hold another reservation" rather than "this one is
            // already starting".
        } catch {
            XCTFail("Unexpected second-claim error: \(error)")
        }

        // Rejected before the network: no claim POST for B was ever sent.
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsAfterFirstClaim)
        XCTAssertFalse(
            ClaimFlowURLProtocol.capturedPaths.contains("/api/request/\(requestB)/claim")
        )

        // A's presentation and deadline are untouched.
        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(claim.requestID, requestID)
        XCTAssertEqual(claim.pickupName, "Taylor")
        XCTAssertEqual(
            claim.claimExpiresAt.timeIntervalSince1970,
            claimExpiresAt.timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertTrue(claim.isExtensionAvailable)
        XCTAssertNil(claim.claimExtendedAt)

        // B never opens a claimant flow; A's still does.
        XCTAssertFalse(
            RequestDetailView.opensClaimedFlow(activeClaim: store.activeClaim, requestID: requestB)
        )
        XCTAssertTrue(
            RequestDetailView.opensClaimedFlow(activeClaim: store.activeClaim, requestID: requestID)
        )

        // A still owns its lifecycle: its private token is the one that
        // extends, on A's endpoint, and the extension is still unused.
        ClaimFlowURLProtocol.enqueue(.response(data: extensionResponse(
            claimExpiresAt: claimExpiresAt.addingTimeInterval(5 * 60),
            claimExtendedAt: Date()
        )))
        await store.extendActiveClaim()

        let extensionRequest = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.last)
        XCTAssertEqual(extensionRequest.path, "/api/request/\(requestID)/claim/extend")
        XCTAssertEqual(
            try XCTUnwrap(extensionRequest.bodyObject)["claimToken"] as? String,
            "token-for-a"
        )
    }

    /// The helper starts a claim and leaves the detail screen before it
    /// resolves. The confirmed claim still becomes the one active claim, and it
    /// cannot be displaced by a claim on whatever request they opened next.
    func testDelayedClaimSuccessBecomesTheSingleActiveClaimAndBlocksAnother() async throws {
        let requestB = "meal-b"
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(claimToken: "token-for-a"),
            gate: claimGate
        ))

        let claimA = Task { try await store.claim(requestID: requestID) }
        await waitUntil { claimGate.isWaiting }

        // A's detail screen is no longer current: nothing claimant-private
        // exists yet, and no screen — A's or B's — opens a flow.
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(
            RequestDetailView.opensClaimedFlow(activeClaim: store.activeClaim, requestID: requestID)
        )
        XCTAssertFalse(
            RequestDetailView.opensClaimedFlow(activeClaim: store.activeClaim, requestID: requestB)
        )

        claimGate.open()
        try await claimA.value

        // The delayed success is still applied, as the single active claim.
        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(claim.requestID, requestID)
        XCTAssertFalse(store.isClaiming)

        let pathsAfterDelayedSuccess = ClaimFlowURLProtocol.capturedPaths
        do {
            try await store.claim(requestID: requestB)
            XCTFail("A delayed confirmed claim must still block a second claim")
        } catch RequestServiceError.existingActiveClaim {
            // Expected.
        } catch {
            XCTFail("Unexpected second-claim error: \(error)")
        }

        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsAfterDelayedSuccess)
        XCTAssertEqual(try XCTUnwrap(store.activeClaim).requestID, requestID)
        XCTAssertEqual(try XCTUnwrap(store.activeClaim).pickupName, claim.pickupName)
    }

    /// Leaving the flow releases the local slot, so the helper can go on to
    /// help with something else. The guard blocks replacement, not all claiming.
    func testClaimingIsAvailableAgainAfterLeavingTheActiveClaimFlow() async throws {
        let requestB = "meal-b"
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.leaveActiveClaimFlow()
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            responseRequestID: requestB
        )))
        try await store.claim(requestID: requestB)

        XCTAssertEqual(try XCTUnwrap(store.activeClaim).requestID, requestB)
    }

    // MARK: - Request-scoped claim state

    /// The detail screen's claim action reads `isClaiming(requestID:)`, not the
    /// unscoped mutex, so an in-flight claim on A cannot silently grey out B's
    /// action while B is still perfectly claimable.
    func testInFlightClaimOnOneRequestLeavesAnotherRequestsStateUnaffected() async throws {
        let requestB = "meal-b"
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(), gate: claimGate))

        let claimA = Task { try await store.claim(requestID: requestID) }
        await waitUntil { claimGate.isWaiting }

        // The store-wide mutex is engaged...
        XCTAssertTrue(store.isClaiming)
        // ...but only A is presented as claiming.
        XCTAssertTrue(store.isClaiming(requestID: requestID))
        XCTAssertFalse(store.isClaiming(requestID: requestB))

        // B shows no error and keeps its action on screen.
        XCTAssertNil(store.claimError(for: requestB))
        XCTAssertTrue(RequestDetailView.showsClaimAction(for: nil))

        // A concurrent attempt is still refused by the store, with copy that
        // explains itself rather than a silently dead control. B is not the
        // request that is already starting, so it gets its own sentence.
        do {
            try await store.claim(requestID: requestB)
            XCTFail("The store mutex must still refuse a concurrent claim")
        } catch {
            XCTAssertEqual(ClaimPresentationError.map(error), .otherClaimInProgress)
        }
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.count, 1)

        claimGate.open()
        try await claimA.value

        XCTAssertFalse(store.isClaiming(requestID: requestID))
        XCTAssertFalse(store.isClaiming(requestID: requestB))
    }

    // MARK: - Notice presentation

    /// Store publication is observed even when Active Requests was already on
    /// screen. This is the path used when a preserved reservation expires while
    /// the helper is looking at the list rather than returning from a detail.
    func testNoticePublishedWhileActiveRequestsIsVisibleIsPresentedImmediately() async throws {
        let store = makeStore()
        var presented: ClaimUnavailableNotice? = nil

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(0.2)
        )))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        try await store.claim(requestID: requestID)
        XCTAssertNil(store.claimUnavailableNotice)

        await waitUntil { store.claimUnavailableNotice?.reason == .claimExpired }

        let published = try XCTUnwrap(store.claimUnavailableNotice)
        presented = ActiveRequestsView.noticeToPresent(
            presented: nil,
            storeNotice: store.claimUnavailableNotice,
            isViewVisible: true
        )

        XCTAssertEqual(presented?.id, published.id)
        XCTAssertEqual(presented?.reason, .claimExpired)
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    /// A notice raised while a detail screen covers Active Requests waits on the
    /// store and is presented once the list is visible again.
    func testNoticeRaisedBehindADetailScreenIsPresentedOnceTheListAppears() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(
                code: "REQUEST_ALREADY_CLAIMED",
                message: "Someone else just started helping with this request."
            )
        ))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        try? await store.claim(requestID: requestID)
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }

        let noticeA = try XCTUnwrap(store.claimUnavailableNotice)

        // While the detail screen is still up nothing is presented, and the
        // notice is not consumed — it survives on the store.
        var presented: ClaimUnavailableNotice? = nil
        XCTAssertNotNil(store.claimUnavailableNotice)
        presented = ActiveRequestsView.noticeToPresent(
            presented: presented,
            storeNotice: store.claimUnavailableNotice,
            isViewVisible: false
        )
        XCTAssertNil(presented)

        // The list becomes visible: `onAppear` arms the alert with notice A.
        presented = ActiveRequestsView.noticeToPresent(
            presented: presented,
            storeNotice: store.claimUnavailableNotice,
            isViewVisible: true
        )
        XCTAssertEqual(presented?.id, noticeA.id)

        // A newer notice B arrives while A is on screen. A is not swapped out.
        let requestB = "meal-b"
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 410,
            data: errorResponse(code: "REQUEST_EXPIRED", message: "No longer available.")
        ))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        try? await store.claim(requestID: requestB)
        await waitUntil {
            ClaimFlowURLProtocol.capturedPaths.filter { $0 == "/api/requests" }.count == 2
        }
        await waitUntil { !store.isFetching }

        let noticeB = try XCTUnwrap(store.claimUnavailableNotice)
        XCTAssertNotEqual(noticeB.id, noticeA.id)
        presented = ActiveRequestsView.noticeToPresent(
            presented: presented,
            storeNotice: store.claimUnavailableNotice
        )
        XCTAssertEqual(presented?.id, noticeA.id, "An alert on screen is never swapped")

        // Acknowledging A by its exact ID cannot clear B.
        store.acknowledgeClaimUnavailableNotice(id: noticeA.id)
        XCTAssertEqual(store.claimUnavailableNotice?.id, noticeB.id)
        XCTAssertEqual(store.claimUnavailableNotice?.requestID, requestB)

        // Once A is dismissed, the queued notice B is presented next.
        presented = nil
        presented = ActiveRequestsView.noticeToPresent(
            presented: presented,
            storeNotice: store.claimUnavailableNotice
        )
        XCTAssertEqual(presented?.id, noticeB.id)

        // And acknowledging B by ID finally empties the queue.
        store.acknowledgeClaimUnavailableNotice(id: noticeB.id)
        XCTAssertNil(store.claimUnavailableNotice)
        XCTAssertNil(
            ActiveRequestsView.noticeToPresent(presented: nil, storeNotice: store.claimUnavailableNotice)
        )
    }

    /// A failed refresh must not swallow the safety notice the helper still
    /// needs to see.
    func testFailedRefreshDoesNotEraseThePendingNotice() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(
                code: "REQUEST_ALREADY_CLAIMED",
                message: "Someone else just started helping with this request."
            )
        ))
        // The refresh the conflict triggers fails.
        ClaimFlowURLProtocol.enqueue(.failure(.notConnectedToInternet))
        try? await store.claim(requestID: requestID)

        let notice = try XCTUnwrap(store.claimUnavailableNotice)
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }

        XCTAssertEqual(store.claimUnavailableNotice?.id, notice.id)
        XCTAssertEqual(
            ActiveRequestsView.noticeToPresent(
                presented: nil,
                storeNotice: store.claimUnavailableNotice
            )?.id,
            notice.id
        )
    }

    // MARK: - Token stays in memory

    func testConfirmedClaimKeepsTheRawTokenPrivateToTheStore() async throws {
        let token = "raw-claim-token-value"
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: token)))

        try await store.claim(requestID: requestID)

        let presentation = try XCTUnwrap(store.activeClaim)
        let presentationLabels = Set(
            Mirror(reflecting: presentation).children.compactMap(\.label)
        )
        XCTAssertFalse(presentationLabels.contains("claimToken"))
        XCTAssertFalse(presentationLabels.contains("token"))

        // The known fixture token was not copied into process-wide preferences.
        for value in UserDefaults.standard.dictionaryRepresentation().values {
            XCTAssertFalse(String(describing: value).contains(token))
        }

        // Not on the public request model that the list and detail screens read.
        let claimedRequest = try XCTUnwrap(store.requests.first)
        for child in Mirror(reflecting: claimedRequest).children {
            XCTAssertFalse(String(describing: child.value).contains(token))
        }

        // Dropped entirely when the flow ends; nothing outlives the session.
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.leaveActiveClaimFlow()
        XCTAssertNil(store.activeClaim)
        await store.extendActiveClaim()
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/claim/extend") }.count,
            0
        )
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    /// The public model and the list DTO must stay free of claimant-only fields
    /// even when a response carries them alongside the public projection.
    func testPublicRequestModelNeverReceivesClaimantOnlyFields() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", status: "open")
        ])))
        let listed = try await makeService().fetchActiveRequests()

        let claimantOnlyNames = ["pickupname", "claimtoken", "claimexpiresat", "email", "phone"]
        for child in Mirror(reflecting: try XCTUnwrap(listed.first)).children {
            let label = (child.label ?? "").lowercased()
            for name in claimantOnlyNames {
                XCTAssertNotEqual(label, name, "FoodRequest must not carry \(name)")
            }
        }

        // Inspect a real DTO instance rather than reflecting the metatype, which
        // has no stored-property children regardless of the DTO definition.
        let dto = RequestResponseDTO(
            id: "dto-a",
            vendor: "Crave NYU",
            food: "Rice bowl",
            pickupWindowText: "ASAP",
            windowStart: nil,
            windowEnd: nil,
            status: .open,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(60)
        )
        let dtoLabels = Set(Mirror(reflecting: dto).children.compactMap(\.label))
        XCTAssertEqual(
            dtoLabels,
            Set([
                "id", "vendor", "food", "pickupWindowText", "windowStart",
                "windowEnd", "status", "createdAt", "expiresAt"
            ])
        )
    }

    // MARK: - Lost claim

    func testAlreadyClaimedShowsLockedCopyRefreshesAndReturnsToActiveRequests() async {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: requestID, status: "open")
        ])))
        await store.fetchRequests()

        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(
                code: "REQUEST_ALREADY_CLAIMED",
                message: "Someone else just started helping with this request."
            )
        ))
        // The refresh the conflict triggers.
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        do {
            try await store.claim(requestID: requestID)
            XCTFail("A lost claim must not succeed")
        } catch {
            XCTAssertEqual(ClaimPresentationError.map(error), .alreadyClaimed)
        }

        // Locked copy, verbatim.
        XCTAssertEqual(
            ClaimPresentationError.alreadyClaimed.message,
            "Someone else just started helping with this request."
        )
        XCTAssertEqual(
            ActiveRequestsView.claimUnavailableTitle(for: .alreadyClaimed),
            "Someone else just started helping with this request."
        )

        // No claim, no navigation, and the helper is sent back.
        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .alreadyClaimed)
        XCTAssertFalse(
            RequestDetailView.opensClaimedFlow(
                activeClaim: store.activeClaim,
                requestID: requestID
            )
        )

        // Backend truth replaces the stale row rather than the screen keeping it.
        await waitUntil { store.requests.isEmpty }
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.suffix(1),
            ["/api/requests"]
        )

        let noticeID = try? XCTUnwrap(store.claimUnavailableNotice?.id)
        if let noticeID {
            store.acknowledgeClaimUnavailableNotice(id: noticeID)
        }
        XCTAssertNil(store.claimUnavailableNotice)
    }

    func testConfirmedUnavailableCodesDoNotOpenFulfillmentAndReturnToActiveRequests() async {
        let unavailableCodes: [(code: String, status: Int)] = [
            ("REQUEST_EXPIRED", 410),
            ("REQUEST_INSUFFICIENT_TIME", 409),
            ("REQUEST_ALREADY_PLACED", 409),
            ("REQUEST_NOT_FOUND", 404)
        ]

        for entry in unavailableCodes {
            ClaimFlowURLProtocol.reset()
            let store = makeStore()
            ClaimFlowURLProtocol.enqueue(.response(
                statusCode: entry.status,
                data: errorResponse(code: entry.code, message: "backend detail")
            ))
            ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

            do {
                try await store.claim(requestID: requestID)
                XCTFail("\(entry.code) must not succeed")
            } catch {
                // The stable code survives to the store for diagnosis...
                guard case .serverError(let code, _)? = store.claimError(for: requestID) else {
                    XCTFail("Expected a serverError for \(entry.code)")
                    continue
                }
                XCTAssertEqual(code, entry.code)
                // ...while the copy groups them into one calm message.
                XCTAssertEqual(ClaimPresentationError.map(error), .noLongerAvailable)
            }

            XCTAssertNil(store.activeClaim, "\(entry.code) must not create a claim")
            XCTAssertEqual(store.claimUnavailableNotice?.reason, .noLongerAvailable)
            XCTAssertFalse(
                RequestDetailView.opensClaimedFlow(
                    activeClaim: store.activeClaim,
                    requestID: requestID
                )
            )
            await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
            await waitUntil { !store.isFetching }
        }
    }

    /// A paused or rate-limited backend is not "this request is gone", so the
    /// helper stays where they are instead of being bounced to the list.
    func testPausedAndRateLimitedClaimsKeepTheHelperOnTheDetailScreen() async {
        let cases: [(code: String, status: Int, expected: ClaimPresentationError)] = [
            ("PUBLIC_ACTIONS_PAUSED", 503, .publicActionsPaused),
            ("RATE_LIMITED", 429, .rateLimited),
            ("INTERNAL_FAILURE", 500, .couldNotStart)
        ]

        for entry in cases {
            ClaimFlowURLProtocol.reset()
            let store = makeStore()
            ClaimFlowURLProtocol.enqueue(.response(
                statusCode: entry.status,
                data: errorResponse(code: entry.code, message: "backend detail")
            ))

            do {
                try await store.claim(requestID: requestID)
                XCTFail("\(entry.code) must not succeed")
            } catch {
                XCTAssertEqual(ClaimPresentationError.map(error), entry.expected)
            }

            XCTAssertNil(store.activeClaim)
            XCTAssertNil(
                store.claimUnavailableNotice,
                "\(entry.code) is not a confirmed-unavailable outcome"
            )
            XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, ["/api/request/\(requestID)/claim"])
        }

        // Locked Day 2 helper-pause sentence, and no claim action offered.
        XCTAssertEqual(
            ClaimPresentationError.publicActionsPaused.message,
            "Helping with this meal is temporarily unavailable."
        )
        XCTAssertFalse(RequestDetailView.showsClaimAction(for: .publicActionsPaused))
        XCTAssertTrue(RequestDetailView.showsClaimAction(for: .rateLimited))
    }

    func testDelayedUnavailableFailureForRequestADoesNotAffectRequestBDetail() async {
        let requestB = "meal-b"
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(
                code: "REQUEST_ALREADY_CLAIMED",
                message: "Someone else just started helping with this request."
            ),
            gate: claimGate
        ))
        let claimA = Task {
            try await store.claim(requestID: requestID)
        }
        await waitUntil { claimGate.isWaiting }

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        claimGate.open()
        do {
            try await claimA.value
            XCTFail("Request A should be unavailable")
        } catch {
            XCTAssertEqual(ClaimPresentationError.map(error), .alreadyClaimed)
        }

        XCTAssertNil(store.claimError(for: requestB))
        XCTAssertFalse(
            RequestDetailView.shouldDismiss(
                for: store.claimUnavailableNotice,
                requestID: requestB
            )
        )
        XCTAssertTrue(RequestDetailView.showsClaimAction(for: nil))
        XCTAssertFalse(store.isClaiming(requestID: requestB))
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    func testAcknowledgingOldNoticeCannotClearNewerNotice() async {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(
                code: "REQUEST_ALREADY_CLAIMED",
                message: "Someone else just started helping with this request."
            )
        ))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        try? await store.claim(requestID: requestID)
        let noticeA = try? XCTUnwrap(store.claimUnavailableNotice)
        await waitUntil {
            ClaimFlowURLProtocol.capturedPaths.filter { $0 == "/api/requests" }.count == 1
        }
        await waitUntil { !store.isFetching }

        let requestB = "meal-b"
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 410,
            data: errorResponse(
                code: "REQUEST_EXPIRED",
                message: "This request is no longer available."
            )
        ))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        try? await store.claim(requestID: requestB)
        let noticeB = try? XCTUnwrap(store.claimUnavailableNotice)
        await waitUntil {
            ClaimFlowURLProtocol.capturedPaths.filter { $0 == "/api/requests" }.count == 2
        }
        await waitUntil { !store.isFetching }

        if let noticeA {
            store.acknowledgeClaimUnavailableNotice(id: noticeA.id)
        }

        XCTAssertEqual(store.claimUnavailableNotice?.id, noticeB?.id)
        XCTAssertEqual(store.claimUnavailableNotice?.requestID, requestB)
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .noLongerAvailable)
    }

    // MARK: - Extension

    func testExtensionSendsTheActiveRawTokenAndAppliesTheBackendExpiration() async throws {
        let token = "raw-token-for-extension"
        let store = makeStore()
        let originalExpiration = Date().addingTimeInterval(10 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimToken: token,
            claimExpiresAt: originalExpiration
        )))
        try await store.claim(requestID: requestID)

        let extendedExpiration = originalExpiration.addingTimeInterval(5 * 60)
        let extendedAt = Date()
        ClaimFlowURLProtocol.enqueue(.response(data: extensionResponse(
            claimExpiresAt: extendedExpiration,
            claimExtendedAt: extendedAt
        )))

        await store.extendActiveClaim()

        let extensionRequest = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.last)
        XCTAssertEqual(extensionRequest.path, "/api/request/\(requestID)/claim/extend")
        XCTAssertEqual(extensionRequest.method, "POST")

        let body = try XCTUnwrap(extensionRequest.bodyObject)
        XCTAssertEqual(body["claimToken"] as? String, token)
        // The backend rejects any body carrying more than the token.
        XCTAssertEqual(body.count, 1)

        // The backend's timestamps are authoritative, not a local +5 minutes.
        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(
            claim.claimExpiresAt.timeIntervalSince1970,
            extendedExpiration.timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertTrue(claim.hasUsedExtension)
        XCTAssertEqual(
            try XCTUnwrap(claim.claimExtendedAt).timeIntervalSince1970,
            extendedAt.timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertNil(store.claimExtensionError)
    }

    func testPendingExtensionSurvivesOriginalDeadlineThenAcceptsBackendSuccess() async throws {
        let store = makeStore()
        let originalExpiration = Date().addingTimeInterval(0.2)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: originalExpiration
        )))
        try await store.claim(requestID: requestID)

        let extensionGate = RequestFetchingGate()
        let extendedExpiration = Date().addingTimeInterval(2)
        ClaimFlowURLProtocol.enqueue(.response(
            data: extensionResponse(
                claimExpiresAt: extendedExpiration,
                claimExtendedAt: Date()
            ),
            gate: extensionGate
        ))

        let extensionTask = Task {
            await store.extendActiveClaim()
        }
        await waitUntil { extensionGate.isWaiting }

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(store.activeClaim)
        XCTAssertTrue(store.isExtendingClaim)
        XCTAssertNil(store.claimUnavailableNotice)

        extensionGate.open()
        await extensionTask.value

        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(
            claim.claimExpiresAt.timeIntervalSince1970,
            extendedExpiration.timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertNotNil(claim.claimExtendedAt)
        XCTAssertFalse(store.isExtendingClaim)

        // The cancelled timer for the original deadline has already woken and
        // cannot clear the extended claim.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(store.activeClaim)
        XCTAssertNil(store.claimUnavailableNotice)
    }

    func testPendingRejectedExtensionPastOriginalDeadlineEndsTheFlow() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(0.2)
        )))
        try await store.claim(requestID: requestID)

        let extensionGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 429,
            data: errorResponse(code: "RATE_LIMITED", message: "Wait."),
            gate: extensionGate
        ))
        let extensionTask = Task {
            await store.extendActiveClaim()
        }
        await waitUntil { extensionGate.isWaiting }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(store.activeClaim)

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        extensionGate.open()
        await extensionTask.value

        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .claimExpired)
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    func testPendingAmbiguousExtensionPastOriginalDeadlineEndsTheFlow() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(0.2)
        )))
        try await store.claim(requestID: requestID)

        let extensionGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost, gate: extensionGate))
        let extensionTask = Task {
            await store.extendActiveClaim()
        }
        await waitUntil { extensionGate.isWaiting }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(store.activeClaim)

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        extensionGate.open()
        await extensionTask.value

        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .claimExpired)
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    func testExtensionIsOfferedOnceAndNeverReappears() async throws {
        let store = makeStore()
        // Expires just past the three-minute prompt lead, so the local timer
        // reaches the prompt moment almost immediately.
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(
                RequestStore.claimExtensionPromptLead + 0.2
            ),
            requestExpiresAt: Date().addingTimeInterval(60 * 60)
        )))
        try await store.claim(requestID: requestID)

        XCTAssertFalse(store.isShowingClaimExtensionPrompt)
        await waitUntil { store.isShowingClaimExtensionPrompt }

        store.dismissClaimExtensionPrompt()
        XCTAssertFalse(store.isShowingClaimExtensionPrompt)
        XCTAssertTrue(store.hasResolvedClaimExtensionPrompt)

        // The prompt moment has passed and cannot come back around.
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(store.isShowingClaimExtensionPrompt)

        // A declined prompt sends nothing.
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, ["/api/request/\(requestID)/claim"])
    }

    func testSuccessfulExtensionRetiresThePromptAndBlocksASecondAttempt() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(
                RequestStore.claimExtensionPromptLead + 0.2
            ),
            requestExpiresAt: Date().addingTimeInterval(60 * 60)
        )))
        try await store.claim(requestID: requestID)
        await waitUntil { store.isShowingClaimExtensionPrompt }

        ClaimFlowURLProtocol.enqueue(.response(data: extensionResponse(
            claimExpiresAt: Date().addingTimeInterval(60 * 8),
            claimExtendedAt: Date()
        )))
        await store.extendActiveClaim()

        XCTAssertFalse(store.isShowingClaimExtensionPrompt)
        XCTAssertTrue(store.hasResolvedClaimExtensionPrompt)
        XCTAssertTrue(try XCTUnwrap(store.activeClaim).hasUsedExtension)

        // A second call is refused locally: only one extension exists.
        let pathsAfterFirstExtension = ClaimFlowURLProtocol.capturedPaths
        await store.extendActiveClaim()
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsAfterFirstExtension)
    }

    /// The prompt is withheld when the backend could only refuse it, because a
    /// full five minutes does not fit inside the request's own expiration.
    func testPromptIsWithheldWhenAFullExtensionCannotFit() async throws {
        let store = makeStore()
        let claimExpiresAt = Date().addingTimeInterval(RequestStore.claimExtensionPromptLead + 0.2)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: claimExpiresAt,
            requestExpiresAt: claimExpiresAt.addingTimeInterval(60)
        )))
        try await store.claim(requestID: requestID)

        await waitUntil { store.hasResolvedClaimExtensionPrompt }
        XCTAssertFalse(store.isShowingClaimExtensionPrompt)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, ["/api/request/\(requestID)/claim"])
    }

    func testFailedExtensionNeverAdvancesTheLocalExpiration() async throws {
        let failures: [(code: String, status: Int, expected: ClaimExtensionPresentationError)] = [
            ("CLAIM_EXTENSION_INSUFFICIENT_TIME", 409, .insufficientTime),
            ("PUBLIC_ACTIONS_PAUSED", 503, .publicActionsPaused),
            ("RATE_LIMITED", 429, .rateLimited),
            ("INTERNAL_FAILURE", 500, .couldNotExtend)
        ]

        for failure in failures {
            ClaimFlowURLProtocol.reset()
            let store = makeStore()
            let claimExpiresAt = Date().addingTimeInterval(10 * 60)
            ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
                claimExpiresAt: claimExpiresAt
            )))
            try await store.claim(requestID: requestID)

            ClaimFlowURLProtocol.enqueue(.response(
                statusCode: failure.status,
                data: errorResponse(code: failure.code, message: "backend detail")
            ))
            await store.extendActiveClaim()

            let claim = try XCTUnwrap(store.activeClaim, "\(failure.code) must keep the claim")
            XCTAssertEqual(
                claim.claimExpiresAt.timeIntervalSince1970,
                claimExpiresAt.timeIntervalSince1970,
                accuracy: 0.01,
                "\(failure.code) must not move the deadline"
            )
            XCTAssertEqual(
                ClaimExtensionPresentationError.map(store.claimExtensionError),
                failure.expected
            )
            XCTAssertFalse(store.isShowingClaimExtensionPrompt)
            XCTAssertTrue(store.hasResolvedClaimExtensionPrompt)
        }
    }

    func testAlreadyUsedExtensionStopsFurtherAttemptsWithoutInventingTime() async throws {
        let store = makeStore()
        let claimExpiresAt = Date().addingTimeInterval(10 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimExpiresAt: claimExpiresAt)))
        try await store.claim(requestID: requestID)

        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(
                code: "CLAIM_EXTENSION_ALREADY_USED",
                message: "This claim has already been extended."
            )
        ))
        await store.extendActiveClaim()

        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertFalse(claim.hasUsedExtension)
        XCTAssertNil(claim.claimExtendedAt)
        XCTAssertFalse(claim.isExtensionAvailable)
        XCTAssertTrue(store.hasResolvedClaimExtensionPrompt)
        XCTAssertFalse(store.isShowingClaimExtensionPrompt)
        XCTAssertEqual(
            claim.claimExpiresAt.timeIntervalSince1970,
            claimExpiresAt.timeIntervalSince1970,
            accuracy: 0.01
        )

        let pathsAfterFailure = ClaimFlowURLProtocol.capturedPaths
        await store.extendActiveClaim()
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsAfterFailure)
    }

    func testAmbiguousExtensionKeepsTheKnownDeadlineAndDoesNotRetry() async throws {
        let store = makeStore()
        let claimExpiresAt = Date().addingTimeInterval(10 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimExpiresAt: claimExpiresAt)))
        try await store.claim(requestID: requestID)

        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        await store.extendActiveClaim()

        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(
            claim.claimExpiresAt.timeIntervalSince1970,
            claimExpiresAt.timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertFalse(claim.hasUsedExtension)
        XCTAssertEqual(
            ClaimExtensionPresentationError.map(store.claimExtensionError),
            .ambiguous
        )
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/claim/extend") }.count,
            1
        )
    }

    func testOldExtensionSuccessCannotAlterReclaimedSameRequestOrNewLoadingState() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimToken: "old-token",
            claimExpiresAt: Date().addingTimeInterval(10 * 60)
        )))
        try await store.claim(requestID: requestID)

        let oldExtensionGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: extensionResponse(
                claimExpiresAt: Date().addingTimeInterval(20 * 60),
                claimExtendedAt: Date()
            ),
            gate: oldExtensionGate
        ))
        let oldExtension = Task {
            await store.extendActiveClaim()
        }
        await waitUntil { oldExtensionGate.isWaiting }

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.leaveActiveClaimFlow()
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }

        let newOriginalExpiration = Date().addingTimeInterval(12 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimToken: "new-token",
            claimExpiresAt: newOriginalExpiration
        )))
        try await store.claim(requestID: requestID)

        let newExtensionGate = RequestFetchingGate()
        let newExtendedExpiration = Date().addingTimeInterval(17 * 60)
        ClaimFlowURLProtocol.enqueue(.response(
            data: extensionResponse(
                claimExpiresAt: newExtendedExpiration,
                claimExtendedAt: Date()
            ),
            gate: newExtensionGate
        ))
        let newExtension = Task {
            await store.extendActiveClaim()
        }
        await waitUntil { newExtensionGate.isWaiting }
        XCTAssertTrue(store.isExtendingClaim)

        oldExtensionGate.open()
        await oldExtension.value

        XCTAssertTrue(store.isExtendingClaim)
        XCTAssertNil(store.claimExtensionError)
        XCTAssertEqual(
            try XCTUnwrap(store.activeClaim).claimExpiresAt.timeIntervalSince1970,
            newOriginalExpiration.timeIntervalSince1970,
            accuracy: 0.01
        )

        newExtensionGate.open()
        await newExtension.value
        XCTAssertFalse(store.isExtendingClaim)
        XCTAssertEqual(
            try XCTUnwrap(store.activeClaim).claimExpiresAt.timeIntervalSince1970,
            newExtendedExpiration.timeIntervalSince1970,
            accuracy: 0.01
        )
    }

    func testOldExtensionFailureCannotPublishIntoReclaimedSameRequest() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimToken: "old-token"
        )))
        try await store.claim(requestID: requestID)

        let oldExtensionGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 500,
            data: errorResponse(code: "INTERNAL_FAILURE", message: "Old failure."),
            gate: oldExtensionGate
        ))
        let oldExtension = Task {
            await store.extendActiveClaim()
        }
        await waitUntil { oldExtensionGate.isWaiting }

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.leaveActiveClaimFlow()
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimToken: "new-token"
        )))
        try await store.claim(requestID: requestID)

        let newExtensionGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: extensionResponse(
                claimExpiresAt: Date().addingTimeInterval(20 * 60),
                claimExtendedAt: Date()
            ),
            gate: newExtensionGate
        ))
        let newExtension = Task {
            await store.extendActiveClaim()
        }
        await waitUntil { newExtensionGate.isWaiting }

        oldExtensionGate.open()
        await oldExtension.value

        XCTAssertTrue(store.isExtendingClaim)
        XCTAssertNil(store.claimExtensionError)
        XCTAssertNotNil(store.activeClaim)

        newExtensionGate.open()
        await newExtension.value
        XCTAssertFalse(store.isExtendingClaim)
        XCTAssertNil(store.claimExtensionError)
    }

    // MARK: - Claim expiration

    func testClaimExpirationEndsTheFlowAndReturnsToRefreshedRequests() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(0.2)
        )))
        // The refresh the expiration triggers.
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        try await store.claim(requestID: requestID)
        XCTAssertNotNil(store.activeClaim)

        await waitUntil { store.claimUnavailableNotice?.reason == .claimExpired }

        // The flow is closed: no claim, no token, and no way back into it.
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(
            RequestDetailView.opensClaimedFlow(
                activeClaim: store.activeClaim,
                requestID: requestID
            )
        )
        XCTAssertFalse(store.isShowingClaimExtensionPrompt)

        // The helper is told what happened and warned off placing an order.
        XCTAssertEqual(
            ActiveRequestsView.claimUnavailableTitle(for: .claimExpired),
            "Your reservation expired."
        )
        let detail = try XCTUnwrap(
            ActiveRequestsView.claimUnavailableDetail(for: .claimExpired)
        )
        XCTAssertTrue(detail.contains("don’t place an order"))

        // ...on a list refreshed from backend truth.
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    func testExpiredClaimReportedByTheExtensionEndpointEndsTheFlowToo() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(10 * 60)
        )))
        try await store.claim(requestID: requestID)

        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(code: "CLAIM_EXPIRED", message: "This claim has expired.")
        ))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        await store.extendActiveClaim()

        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .claimExpired)
        // Handled by ending the flow, so no inline extension copy is shown.
        XCTAssertNil(ClaimExtensionPresentationError.map(store.claimExtensionError))
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    func testLeavingTheClaimFlowDropsTheClaimAndRefreshes() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        store.leaveActiveClaimFlow()

        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(store.isShowingClaimExtensionPrompt)
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    // MARK: - Day 4 product-safety copy

    /// The tap is the commitment, so its consequence has to be on screen before
    /// it — and viewing a request still claims nothing.
    func testClaimConsequenceIsExplainedBeforeTheTapAndViewingClaimsNothing() async throws {
        let notice = RequestDetailView.claimConsequenceNotice
        XCTAssertEqual(
            notice,
            "This holds the meal for you for a few minutes so no one else orders it. You place the Grubhub order, then save the order details here."
        )
        // Both halves of the commitment: the hold, and who actually pays for
        // and places the order.
        XCTAssertTrue(notice.localizedCaseInsensitiveContains("holds the meal"))
        XCTAssertTrue(notice.localizedCaseInsensitiveContains("no one else"))
        XCTAssertTrue(notice.localizedCaseInsensitiveContains("you place the grubhub order"))
        // Never promise a duration the backend caps at the request's own
        // expiration, and never imply the tap itself notifies anyone.
        XCTAssertFalse(notice.contains("15"))
        XCTAssertFalse(notice.localizedCaseInsensitiveContains("notif"))
        // Reserving is not ordering: nothing here may read as an order that
        // already happened.
        XCTAssertFalse(notice.localizedCaseInsensitiveContains("placed"))

        // The notice ships with the action it explains.
        XCTAssertTrue(RequestDetailView.showsClaimAction(for: nil))

        // Opening a request sends nothing; only the explicit tap does.
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: requestID, status: "open")
        ])))
        await store.fetchRequests()
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, ["/api/requests"])

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths,
            ["/api/requests", "/api/request/\(requestID)/claim"]
        )
    }

    func testHomeScreenDescribesTheConnectedPlacementAndEmailAttemptTruthfully() {
        let steps = ContentView.howItWorksSteps

        XCTAssertFalse(steps.contains("3. They place the order and enter pickup details."))
        XCTAssertTrue(steps[2].localizedCaseInsensitiveContains("grubhub order"))
        XCTAssertTrue(steps[2].localizedCaseInsensitiveContains("then records"))
        XCTAssertTrue(steps[3].localizedCaseInsensitiveContains("attempts to email"))
        XCTAssertFalse(steps[3].localizedCaseInsensitiveContains("delivered"))
        XCTAssertFalse(steps[3].localizedCaseInsensitiveContains("read"))
        // One vocabulary across every surface: no engineering or role nouns.
        for step in steps {
            XCTAssertFalse(step.localizedCaseInsensitiveContains("external order"), step)
            XCTAssertFalse(step.localizedCaseInsensitiveContains("requester"), step)
        }
    }

    func testExtensionPromptUsesReservationFocusedCopy() {
        XCTAssertEqual(FulfillRequestView.extensionPromptTitle, "Need more time?")
        XCTAssertEqual(FulfillRequestView.extensionAcceptTitle, "Give me 5 more minutes")
        XCTAssertEqual(FulfillRequestView.extensionDeclineTitle, "Keep my current time")

        // The prompt asks about the reservation, not about an activity this
        // build tells the helper not to start...
        for copy in [
            FulfillRequestView.extensionPromptTitle,
            FulfillRequestView.extensionAcceptTitle,
            FulfillRequestView.extensionDeclineTitle
        ] {
            XCTAssertFalse(
                copy.localizedCaseInsensitiveContains("ordering"),
                "Extension copy must not ask about ordering: \(copy)"
            )
        }

        // ...and declining must not read as handing the request back, which the
        // app cannot do.
        for word in ["cancel", "release", "give up", "stop"] {
            XCTAssertFalse(
                FulfillRequestView.extensionDeclineTitle.localizedCaseInsensitiveContains(word),
                "Declining must not suggest releasing the claim: \(word)"
            )
        }
    }

    /// High-priority safety copy. Locked: do not weaken.
    func testLockedExpirationCopyIsUnchanged() {
        XCTAssertEqual(
            ActiveRequestsView.claimUnavailableTitle(for: .claimExpired),
            "Your reservation expired."
        )
        XCTAssertEqual(
            ActiveRequestsView.claimUnavailableDetail(for: .claimExpired),
            "Please don’t place an order for that request. Someone else may already be helping."
        )
        // The locked race-conflict sentence is likewise untouched.
        XCTAssertEqual(
            ActiveRequestsView.claimUnavailableTitle(for: .alreadyClaimed),
            "Someone else just started helping with this request."
        )
        XCTAssertEqual(
            ActiveRequestsView.claimUnavailableTitle(for: .noLongerAvailable),
            "This request is no longer available."
        )
    }

    // MARK: - Pinned active reservation

    func testConfirmedClaimProducesOnePinnedReservationItem() async throws {
        let store = makeStore()
        let claimExpiresAt = Date().addingTimeInterval(12 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimExpiresAt: claimExpiresAt)))
        try await store.claim(requestID: requestID)

        // The pinned item renders entirely from confirmed claim state, so it
        // survives the request leaving the public collection.
        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(claim.request.id, requestID)
        XCTAssertEqual(claim.request.diningSpot.name, "Crave NYU")
        XCTAssertEqual(claim.request.foodDescription, "Rice bowl")
        XCTAssertEqual(
            ActiveRequestsView.reservedUntilText(claim.claimExpiresAt),
            "Reserved until \(claimExpiresAt.formatted(date: .omitted, time: .shortened))"
        )
        XCTAssertEqual(
            ActiveRequestsView.activeReservationTitle,
            "You’re helping with a request"
        )

        // It is not a second copy of the public row: the claimed request is
        // withheld from the available list while it is held.
        XCTAssertEqual(store.requests.map(\.id), [requestID])
        XCTAssertTrue(
            ActiveRequestsView.availableRequests(
                store.requests,
                activeClaimRequestID: claim.requestID
            ).isEmpty
        )
        // ...and nothing is filtered when no claim is held.
        XCTAssertEqual(
            ActiveRequestsView.availableRequests(store.requests, activeClaimRequestID: nil)
                .map(\.id),
            [requestID]
        )
    }

    /// The claim confirms after its detail screen is gone and the backend has
    /// stopped advertising the request. Without a pinned entry point that is a
    /// live reservation with no route to it anywhere in the app.
    func testDelayedClaimSuccessIsReachableThroughThePinnedItem() async throws {
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(), gate: claimGate))

        let claimTask = Task { try await store.claim(requestID: requestID) }
        await waitUntil { claimGate.isWaiting }
        // The detail screen is dismissed while the claim is still in flight.
        XCTAssertNil(store.activeClaim)

        claimGate.open()
        try await claimTask.value

        // The public list no longer carries the request — it is actively claimed.
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        await store.fetchRequests()
        XCTAssertTrue(store.requests.isEmpty)

        // The reservation is still reachable, with everything the pinned item
        // needs to identify and re-enter it.
        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(claim.requestID, requestID)
        XCTAssertEqual(claim.pickupName, "Taylor")
        XCTAssertEqual(claim.request.foodDescription, "Rice bowl")
    }

    func testReenteringFromThePinnedItemSendsNoSecondClaim() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)

        let pathsAfterClaim = ClaimFlowURLProtocol.capturedPaths
        XCTAssertEqual(pathsAfterClaim, ["/api/request/\(requestID)/claim"])

        // Re-entry reads existing store state. Nothing re-fetches, and the flow
        // opens for exactly the claimed request.
        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertTrue(
            RequestDetailView.opensClaimedFlow(activeClaim: claim, requestID: requestID)
        )
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsAfterClaim)

        // A claim call on the same request would be refused before the network,
        // so re-entry can never become a second reservation.
        do {
            try await store.claim(requestID: requestID)
            XCTFail("Re-entry must not start a second claim")
        } catch RequestServiceError.operationInProgress {
            // Expected: the same request, already held.
        } catch {
            XCTFail("Unexpected re-entry error: \(error)")
        }
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsAfterClaim)
    }

    // MARK: - Non-destructive Back

    /// Back is navigation, not a decision to give up a reservation the backend
    /// still holds. Nothing in the store is cleared by leaving the screen, so
    /// the claim, its private token, its deadline, and its lifecycle timer all
    /// survive and the helper can re-enter. (The gesture itself is verified on
    /// device; this pins the store behavior it now depends on.)
    func testBackingOutOfTheClaimantFlowPreservesTheClaimAndAllowsReentry() async throws {
        let store = makeStore()
        let claimExpiresAt = Date().addingTimeInterval(10 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimToken: "token-for-a",
            claimExpiresAt: claimExpiresAt
        )))
        try await store.claim(requestID: requestID)

        let pathsAfterClaim = ClaimFlowURLProtocol.capturedPaths

        // Dismissing the claimant screen performs no store mutation at all.
        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(claim.requestID, requestID)
        XCTAssertEqual(claim.pickupName, "Taylor")
        XCTAssertEqual(
            claim.claimExpiresAt.timeIntervalSince1970,
            claimExpiresAt.timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertTrue(claim.isExtensionAvailable)
        XCTAssertFalse(claim.hasUsedExtension)
        // No release request exists, and Back must not invent one.
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsAfterClaim)

        // Re-entry is offered for this request...
        XCTAssertTrue(
            RequestDetailView.opensClaimedFlow(activeClaim: store.activeClaim, requestID: requestID)
        )

        // ...and token ownership survived, so the reservation is still fully
        // operable rather than a presentation with nothing behind it.
        ClaimFlowURLProtocol.enqueue(.response(data: extensionResponse(
            claimExpiresAt: claimExpiresAt.addingTimeInterval(5 * 60),
            claimExtendedAt: Date()
        )))
        await store.extendActiveClaim()

        let extensionRequest = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.last)
        XCTAssertEqual(extensionRequest.path, "/api/request/\(requestID)/claim/extend")
        XCTAssertEqual(
            try XCTUnwrap(extensionRequest.bodyObject)["claimToken"] as? String,
            "token-for-a"
        )
        XCTAssertTrue(try XCTUnwrap(store.activeClaim).hasUsedExtension)
    }

    /// Expiration remains the thing that ends a claim — the pinned item and every
    /// claimant-private value go with it.
    func testExpirationClearsThePinnedItemAndPrivateClaimState() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(0.2)
        )))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        try await store.claim(requestID: requestID)
        XCTAssertNotNil(store.activeClaim)

        await waitUntil { store.claimUnavailableNotice?.reason == .claimExpired }

        // No claim means no pinned item, no pickup name, and no re-entry.
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(
            RequestDetailView.opensClaimedFlow(
                activeClaim: store.activeClaim,
                requestID: requestID
            )
        )
        XCTAssertFalse(store.isShowingClaimExtensionPrompt)
        // Nothing is filtered out of the public list any more either.
        XCTAssertEqual(
            ActiveRequestsView.availableRequests(
                store.requests,
                activeClaimRequestID: store.activeClaim?.requestID
            ).count,
            store.requests.count
        )

        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    // MARK: - Distinct claim-blocking messages

    func testInFlightDuplicateAndExistingClaimProduceDistinctMessages() async throws {
        let requestB = "meal-b"
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(), gate: claimGate))

        // In flight on this request: nothing is held yet, the tap is simply
        // already running.
        let claimTask = Task { try await store.claim(requestID: requestID) }
        await waitUntil { claimGate.isWaiting }
        do {
            try await store.claim(requestID: requestID)
            XCTFail("A duplicate in-flight claim must be refused")
        } catch {
            XCTAssertEqual(ClaimPresentationError.map(error), .operationInProgress)
        }

        claimGate.open()
        try await claimTask.value

        // A confirmed reservation elsewhere is a different situation and gets a
        // different sentence.
        do {
            try await store.claim(requestID: requestB)
            XCTFail("A claim must be refused while another reservation is held")
        } catch {
            XCTAssertEqual(ClaimPresentationError.map(error), .existingActiveClaim)
        }

        XCTAssertNotEqual(
            ClaimPresentationError.operationInProgress.message,
            ClaimPresentationError.existingActiveClaim.message
        )
        XCTAssertEqual(
            ClaimPresentationError.existingActiveClaim.message,
            "You’re already helping with another request. Finish that one or wait for its reservation to end."
        )
        // The action is withdrawn rather than left to be tapped into the same
        // refusal; the screen offers a way back to the held reservation instead.
        XCTAssertFalse(RequestDetailView.showsClaimAction(for: .existingActiveClaim))
        XCTAssertTrue(RequestDetailView.showsClaimAction(for: .operationInProgress))
        XCTAssertEqual(try XCTUnwrap(store.activeClaim).requestID, requestID)
    }

    // MARK: - Declining an extension

    func testDecliningTheExtensionKeepsTheCurrentReservationActive() async throws {
        let store = makeStore()
        let claimExpiresAt = Date().addingTimeInterval(
            RequestStore.claimExtensionPromptLead + 0.2
        )
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: claimExpiresAt,
            requestExpiresAt: Date().addingTimeInterval(60 * 60)
        )))
        try await store.claim(requestID: requestID)
        await waitUntil { store.isShowingClaimExtensionPrompt }

        store.dismissClaimExtensionPrompt()

        // Declining retires the prompt only. The reservation, its deadline, and
        // its private state are untouched — it is not a release.
        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(claim.requestID, requestID)
        XCTAssertEqual(claim.pickupName, "Taylor")
        XCTAssertEqual(
            claim.claimExpiresAt.timeIntervalSince1970,
            claimExpiresAt.timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertFalse(store.isShowingClaimExtensionPrompt)
        XCTAssertTrue(store.hasResolvedClaimExtensionPrompt)
        XCTAssertNil(store.claimExtensionError)
        // Declining sends nothing at all.
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, ["/api/request/\(requestID)/claim"])
    }

    // MARK: - Day 5 fulfillment

    func testFulfillmentEncodesTheExactAcceptedPayloadWithoutNoteOrPhone() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-active-token")))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(notificationStatus: "sent")))

        try await store.fulfill(
            requestID: requestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: "Meet by the entrance"
        )

        let request = try XCTUnwrap(
            ClaimFlowURLProtocol.capturedRequests.first { $0.path.hasSuffix("/fulfill") }
        )
        let body = try XCTUnwrap(request.bodyObject)
        XCTAssertEqual(Set(body.keys), ["claimToken", "fulfillment"])
        XCTAssertEqual(body["claimToken"] as? String, "raw-active-token")
        let fulfillment = try XCTUnwrap(body["fulfillment"] as? [String: Any])
        XCTAssertEqual(
            Set(fulfillment.keys),
            ["fulfillerEmail", "orderNumber", "eta", "contactMessage"]
        )
        XCTAssertEqual(fulfillment["fulfillerEmail"] as? String, "helper@example.edu")
        XCTAssertEqual(fulfillment["orderNumber"] as? String, "70154321")
        XCTAssertEqual(fulfillment["eta"] as? String, "15 minutes")
        XCTAssertEqual(fulfillment["contactMessage"] as? String, "Meet by the entrance")
        XCTAssertNil(fulfillment["note"])
        XCTAssertNil(fulfillment["helperPhone"])
        XCTAssertNil(fulfillment["helperPhoneNumber"])
        XCTAssertNil(body["status"])
        XCTAssertNil(body["placedAt"])
    }

    func testOmittedContactMessageIsTheOnlyOptionalFulfillmentField() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(notificationStatus: "sent")))

        try await store.fulfill(
            requestID: requestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        let request = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.last)
        let fulfillment = try XCTUnwrap(request.bodyObject?["fulfillment"] as? [String: Any])
        XCTAssertEqual(Set(fulfillment.keys), ["fulfillerEmail", "orderNumber", "eta"])
    }

    func testEmptyClaimTokenNeverCreatesSubmittableClaimState() async {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "")))

        do {
            try await store.claim(requestID: requestID)
            XCTFail("An unusable raw token must not activate fulfillment")
        } catch RequestServiceError.ambiguousClaimOutcome {
            // A malformed success cannot safely expose a claimant flow.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertFalse(ClaimFlowURLProtocol.capturedPaths.contains { $0.hasSuffix("/fulfill") })
    }

    func testRequiredFulfillmentFieldsAndActiveClaimGateSubmission() async throws {
        XCTAssertFalse(FulfillRequestView.requiredFieldsArePresent(
            fulfillerEmail: "", orderNumber: "70154321", eta: "15 minutes"
        ))
        XCTAssertFalse(FulfillRequestView.requiredFieldsArePresent(
            fulfillerEmail: "helper@example.edu", orderNumber: "  ", eta: "15 minutes"
        ))
        XCTAssertFalse(FulfillRequestView.requiredFieldsArePresent(
            fulfillerEmail: "helper@example.edu", orderNumber: "70154321", eta: "\n"
        ))
        XCTAssertTrue(FulfillRequestView.requiredFieldsArePresent(
            fulfillerEmail: "helper@example.edu", orderNumber: "70154321", eta: "15 minutes"
        ))

        let store = makeStore()
        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID))
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertFalse(store.canSubmitFulfillment(requestID: "different-request"))
    }

    /// Renaming the submit control changes what it says, not when it is
    /// available: the same four gates decide, in the same order.
    func testSubmitButtonIsRenamedButGatedIdentically() async throws {
        XCTAssertEqual(FulfillRequestView.submitTitle, "I placed this order")

        let store = makeStore()
        // No claim.
        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID))

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))

        // Incomplete fields still disable it independently of store state.
        for (email, number, eta) in [
            ("", "70154321", "15 minutes"),
            ("helper@example.edu", " ", "15 minutes"),
            ("helper@example.edu", "70154321", "")
        ] {
            XCTAssertFalse(
                FulfillRequestView.requiredFieldsArePresent(
                    fulfillerEmail: email, orderNumber: number, eta: eta
                ),
                "Missing required field must keep “\(FulfillRequestView.submitTitle)” disabled"
            )
        }

        // Wrong request, and a past deadline, still close it.
        XCTAssertFalse(store.canSubmitFulfillment(requestID: "different-request"))
        XCTAssertFalse(store.canSubmitFulfillment(
            requestID: requestID,
            now: Date().addingTimeInterval(60 * 60)
        ))
    }

    /// The settled unresolved state gained an exit. It has to be an exit and
    /// nothing more: the reservation stays held and blocked, the ambiguity
    /// stays unresolved, and no request leaves the device.
    func testUnresolvedAmbiguityReturnActionOnlyNavigates() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))

        try? await store.fulfill(
            requestID: requestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        let ambiguity = try XCTUnwrap(store.fulfillmentAmbiguity)
        XCTAssertFalse(ambiguity.isCheckingStatus)
        XCTAssertTrue(FulfillRequestView.showsAmbiguityReturnAction(isCheckingStatus: false))
        let pathsBefore = ClaimFlowURLProtocol.capturedPaths

        var navigated = 0
        FulfillRequestView.returnToActiveRequests(from: store) { navigated += 1 }

        XCTAssertEqual(navigated, 1, "The action's only job is to navigate")
        // Nothing resolved, nothing cleared, nothing unblocked, nothing sent.
        XCTAssertEqual(store.fulfillmentAmbiguity?.id, ambiguity.id)
        XCTAssertEqual(store.fulfillmentAmbiguity?.isCheckingStatus, false)
        XCTAssertNotNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsBefore)

        // And a further submission attempt is still refused, unchanged.
        do {
            try await store.fulfill(
                requestID: requestID,
                fulfillerEmail: "helper@example.edu",
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("Leaving must not reopen submission")
        } catch RequestServiceError.unresolvedFulfillment {
            // Expected: the block survives the navigation.
        }
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsBefore)
    }

    /// The Active Requests card is the last surviving surface for a result, and
    /// by then the claim and the list row are both gone — so the confirmation
    /// has to carry the meal's public identity itself.
    func testConfirmationCarriesVendorAndFoodThroughBothConfirmationPaths() async throws {
        // Path 1: a decoded placement response.
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(notificationStatus: "sent")))
        try await store.fulfill(
            requestID: requestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        let confirmed = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertEqual(confirmed.vendor, "Crave NYU")
        XCTAssertEqual(confirmed.foodDescription, "Rice bowl")
        XCTAssertEqual(confirmed.kind, .notificationSent)
        // Identity only: no claimant-private value may ride along.
        XCTAssertFalse(confirmed.vendor.contains("Taylor"))
        XCTAssertFalse(confirmed.foodDescription.contains("claim-token"))
        // Acknowledgement is unchanged: by exact ID, clearing only this one.
        store.acknowledgeFulfillmentConfirmation(id: UUID())
        XCTAssertNotNil(store.fulfillmentConfirmation)
        store.acknowledgeFulfillmentConfirmation(id: confirmed.id)
        XCTAssertNil(store.fulfillmentConfirmation)

        // Path 2: an ambiguous POST resolved by the single placed detail read.
        ClaimFlowURLProtocol.reset()
        let resolved = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await resolved.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "placed")))
        try await resolved.fulfill(
            requestID: requestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        let fromDetail = try XCTUnwrap(resolved.fulfillmentConfirmation)
        XCTAssertEqual(fromDetail.vendor, "Crave NYU")
        XCTAssertEqual(fromDetail.foodDescription, "Rice bowl")
        XCTAssertEqual(fromDetail.kind, .emailStatusUnknown)
        XCTAssertEqual(ActiveRequestsView.confirmationAcknowledgeTitle, "Got it")
    }

    func testDuplicateFulfillmentTapIsBlockedAndNothingIsRemovedOptimistically() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: fulfillmentResponse(notificationStatus: "sent"),
            gate: gate
        ))

        let first = Task {
            try await store.fulfill(
                requestID: requestID,
                fulfillerEmail: "helper@example.edu",
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
        }
        await waitUntil { gate.isWaiting }

        XCTAssertTrue(store.isFulfilling)
        XCTAssertNotNil(store.activeClaim)
        XCTAssertEqual(store.requests.map(\.id), [requestID])
        do {
            try await store.fulfill(
                requestID: requestID,
                fulfillerEmail: "helper@example.edu",
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("A duplicate fulfillment must be refused")
        } catch RequestServiceError.operationInProgress {
            // Refused before a second POST.
        } catch {
            XCTFail("Unexpected duplicate error: \(error)")
        }
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count, 1)

        gate.open()
        try await first.value
        XCTAssertNil(store.activeClaim)
        XCTAssertTrue(store.requests.isEmpty)
    }

    func testClaimDeadlinePassingDuringFulfillmentDoesNotClearBeforeTerminalResponse() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(0.2)
        )))
        try await store.claim(requestID: requestID)
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: fulfillmentResponse(notificationStatus: "sent"),
            gate: gate
        ))

        let fulfillment = Task {
            try await store.fulfill(
                requestID: requestID,
                fulfillerEmail: "helper@example.edu",
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
        }
        await waitUntil { gate.isWaiting }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertNotNil(store.activeClaim)
        XCTAssertTrue(store.isFulfilling)
        XCTAssertNil(store.claimUnavailableNotice)

        gate.open()
        try await fulfillment.value
        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(store.fulfillmentConfirmation?.kind, .notificationSent)
        XCTAssertTrue(store.requests.isEmpty)
    }

    func testSentAndFailedNotificationBothConfirmPlacementAndRemoveOnlyAfterResponse() async throws {
        for (status, kind) in [
            ("sent", FulfillmentConfirmationKind.notificationSent),
            ("failed", FulfillmentConfirmationKind.notificationFailed)
        ] {
            ClaimFlowURLProtocol.reset()
            let store = makeStore()
            ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
            try await store.claim(requestID: requestID)
            ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(notificationStatus: status)))

            try await store.fulfill(
                requestID: requestID,
                fulfillerEmail: "helper@example.edu",
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )

            XCTAssertEqual(store.fulfillmentConfirmation?.kind, kind)
            XCTAssertEqual(store.confirmedFulfillmentOutcome?.request.status, .placed)
            XCTAssertNil(store.activeClaim)
            XCTAssertTrue(store.requests.isEmpty)
        }
    }

    func testConfirmedPlacementCopySeparatesEmailOutcomes() {
        XCTAssertEqual(FulfillRequestView.confirmationTitle, "Order recorded")
        XCTAssertEqual(
            FulfillRequestView.confirmationDetail(for: .notificationSent),
            "We sent the order details to the student’s email. They’ll pick up the food themselves—you’re done. If they reply, it goes to the address you entered."
        )
        XCTAssertEqual(
            FulfillRequestView.confirmationDetail(for: .notificationFailed),
            "Your order is recorded, but we couldn’t email the student. They may not know their food is waiting. Don’t place another Grubhub order."
        )
        XCTAssertEqual(
            FulfillRequestView.confirmationDetail(for: .emailStatusUnknown),
            "Your order is recorded. We couldn’t tell whether the student’s email went out, so they may not know their food is waiting. Don’t place another Grubhub order."
        )

        // Three outcomes, three distinct sentences. Sent must not promise
        // delivery; both non-sent outcomes must say the student may not know.
        let details = [
            FulfillRequestView.confirmationDetail(for: .notificationSent),
            FulfillRequestView.confirmationDetail(for: .notificationFailed),
            FulfillRequestView.confirmationDetail(for: .emailStatusUnknown)
        ]
        XCTAssertEqual(Set(details).count, 3, "Email outcomes must stay distinguishable")
        XCTAssertFalse(details[0].localizedCaseInsensitiveContains("delivered"))
        for detail in details.dropFirst() {
            XCTAssertTrue(detail.localizedCaseInsensitiveContains("may not know"), detail)
            XCTAssertTrue(detail.contains(Self.safetySentence), detail)
        }
        XCTAssertTrue(FulfillRequestView.keepsClaimedFlowPresented(
            activeRequestID: nil,
            confirmationRequestID: requestID,
            requestID: requestID
        ))
        XCTAssertFalse(FulfillRequestView.keepsClaimedFlowPresented(
            activeRequestID: nil,
            confirmationRequestID: nil,
            requestID: requestID
        ))
    }

    func testExpiredClaimIsBlockedBeforeFulfillmentAndForegroundReturnClearsIt() async throws {
        let store = makeStore()
        let expiration = Date().addingTimeInterval(10 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimExpiresAt: expiration)))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        XCTAssertFalse(store.canSubmitFulfillment(
            requestID: requestID,
            now: expiration.addingTimeInterval(1)
        ))
        store.revalidateActiveClaimExpiration(now: expiration.addingTimeInterval(1))

        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .claimExpired)
        XCTAssertFalse(ClaimFlowURLProtocol.capturedPaths.contains { $0.hasSuffix("/fulfill") })
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
    }

    func testExpiredClaimAtSubmissionSendsNoPostAndUsesFulfillmentSafetyWarning() async throws {
        let store = makeStore()
        let expiration = Date().addingTimeInterval(10 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimExpiresAt: expiration)))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        do {
            try await store.fulfill(
                requestID: requestID,
                fulfillerEmail: "helper@example.edu",
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil,
                now: expiration.addingTimeInterval(1)
            )
            XCTFail("An expired claim must be blocked before the POST")
        } catch RequestServiceError.claimExpired {
            // Local precondition failure.
        } catch {
            XCTFail("Unexpected expiration error: \(error)")
        }

        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .fulfillmentClaimExpired)
        XCTAssertFalse(ClaimFlowURLProtocol.capturedPaths.contains { $0.hasSuffix("/fulfill") })
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
    }

    func testConfirmedFulfillmentConflictsClearOnlyTheMatchingClaimAndRefresh() async throws {
        let cases: [(String, Int, ClaimUnavailableReason)] = [
            (ClaimErrorCode.claimExpired, 409, .fulfillmentClaimExpired),
            (ClaimErrorCode.invalidClaimToken, 403, .reservationNoLongerValid),
            (ClaimErrorCode.requestNotClaimed, 409, .reservationNoLongerValid),
            (ClaimErrorCode.requestAlreadyPlaced, 409, .fulfillmentAlreadyPlaced),
            (ClaimErrorCode.requestNotFound, 404, .fulfillmentRequestNotFound)
        ]

        for (code, status, reason) in cases {
            ClaimFlowURLProtocol.reset()
            let store = makeStore()
            ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
            try await store.claim(requestID: requestID)
            ClaimFlowURLProtocol.enqueue(.response(
                statusCode: status,
                data: errorResponse(code: code, message: "Confirmed conflict")
            ))
            ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

            do {
                try await store.fulfill(
                    requestID: requestID,
                    fulfillerEmail: "helper@example.edu",
                    orderNumber: "70154321",
                    eta: "15 minutes",
                    contactMessage: nil
                )
                XCTFail("\(code) should be a confirmed rejection")
            } catch RequestServiceError.serverError(let returnedCode, _) {
                XCTAssertEqual(returnedCode, code)
            } catch {
                XCTFail("Unexpected \(code) error: \(error)")
            }

            XCTAssertNil(store.activeClaim, code)
            XCTAssertEqual(store.claimUnavailableNotice?.reason, reason, code)
            await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
            await waitUntil { !store.isFetching }
        }
    }

    func testNonterminalStructuredFulfillmentFailureKeepsClaimAndAllowsNoAutomaticRetry() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 500,
            data: errorResponse(code: ClaimErrorCode.internalFailure, message: "Could not persist")
        ))

        do {
            try await store.fulfill(
                requestID: requestID,
                fulfillerEmail: "helper@example.edu",
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("A structured failure must not be success")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, ClaimErrorCode.internalFailure)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNotNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentAmbiguity)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count, 1)

        // INTERNAL_FAILURE can accompany a placement that may in fact have
        // committed, so the copy must not assert that nothing was recorded, and
        // must separate re-sending these CommonPlate details from placing a
        // second Grubhub order.
        XCTAssertEqual(FulfillmentPresentationError.map(store.fulfillError), .couldNotRecord)
        let message = FulfillmentPresentationError.couldNotRecord.message
        XCTAssertEqual(
            message,
            "CommonPlate may not have saved your order. Tap “I placed this order” again. Trying again here only updates CommonPlate. It does not place another Grubhub order."
        )
        XCTAssertTrue(message.localizedCaseInsensitiveContains("may not have saved"))
        // The retry it offers is the in-app one, named by the button it means.
        XCTAssertTrue(message.contains(FulfillRequestView.submitTitle))
        XCTAssertTrue(message.contains(Self.inAppRetryDisclaimer))
        XCTAssertFalse(message.contains("We couldn’t record the order."))

        // Nonterminal means the helper may still record manually. Proving the
        // resubmission actually goes through also proves nothing retried it
        // automatically in the meantime: this is the second fulfill POST.
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(notificationStatus: "sent")))
        try await store.fulfill(
            requestID: requestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count, 2)
        XCTAssertEqual(store.fulfillmentConfirmation?.kind, .notificationSent)
    }

    func testAmbiguousTransportPerformsOneReadAndBlocksEveryFurtherPost() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))

        do {
            try await store.fulfill(
                requestID: requestID,
                fulfillerEmail: "helper@example.edu",
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("Claimed detail remains inconclusive")
        } catch RequestServiceError.ambiguousFulfillmentOutcome {
            // Expected after the one read-only check.
        } catch {
            XCTFail("Unexpected ambiguity error: \(error)")
        }

        XCTAssertNotNil(store.activeClaim)
        XCTAssertNotNil(store.fulfillmentAmbiguity)
        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, [
            "/api/request/\(requestID)/claim",
            "/api/request/\(requestID)/fulfill",
            "/api/request/\(requestID)"
        ])

        do {
            try await store.fulfill(
                requestID: requestID,
                fulfillerEmail: "helper@example.edu",
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("An unresolved POST must block another submission")
        } catch RequestServiceError.unresolvedFulfillment {
            // No second POST or GET.
        } catch {
            XCTFail("Unexpected blocked-state error: \(error)")
        }
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count, 1)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0 == "/api/request/\(requestID)" }.count, 1)

        let pathsBeforeExtension = ClaimFlowURLProtocol.capturedPaths
        await store.extendActiveClaim()
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsBeforeExtension)
    }

    func testMismatchedOrNonPlacedFulfillmentSuccessIsAmbiguousNotConfirmed() async throws {
        for response in [
            fulfillmentResponse(
                notificationStatus: "sent",
                responseRequestID: "different-request"
            ),
            fulfillmentResponse(
                notificationStatus: "sent",
                responseStatus: "claimed"
            )
        ] {
            ClaimFlowURLProtocol.reset()
            let store = makeStore()
            ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
            try await store.claim(requestID: requestID)
            ClaimFlowURLProtocol.enqueue(.response(data: response))
            ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))

            do {
                try await store.fulfill(
                    requestID: requestID,
                    fulfillerEmail: "helper@example.edu",
                    orderNumber: "70154321",
                    eta: "15 minutes",
                    contactMessage: nil
                )
                XCTFail("An untrusted success response must remain ambiguous")
            } catch RequestServiceError.ambiguousFulfillmentOutcome {
                // The one detail read did not positively confirm placement.
            } catch {
                XCTFail("Unexpected validation error: \(error)")
            }

            XCTAssertNotNil(store.activeClaim)
            XCTAssertNotNil(store.fulfillmentAmbiguity)
            XCTAssertNil(store.fulfillmentConfirmation)
            XCTAssertEqual(store.requests.first?.status, .claimed)
        }
    }

    func testUnstructuredServerResponseIsAmbiguousButStructuredServerErrorIsNot() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(statusCode: 500, data: Data("oops".utf8)))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "open")))

        do {
            try await store.fulfill(
                requestID: requestID,
                fulfillerEmail: "helper@example.edu",
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("An unstructured POST response cannot be trusted")
        } catch RequestServiceError.ambiguousFulfillmentOutcome {
            // Expected; the earlier structured-error test pins the opposite.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNotNil(store.fulfillmentAmbiguity)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count, 1)
    }

    func testOpenClaimed404AndFailedAmbiguityReadsRemainInconclusive() async throws {
        enum ReadResult {
            case status(String)
            case notFound
            case decodingFailure
            case failure
        }
        let results: [ReadResult] = [
            .status("open"), .status("claimed"), .notFound, .decodingFailure, .failure
        ]

        for result in results {
            ClaimFlowURLProtocol.reset()
            let store = makeStore()
            ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
            try await store.claim(requestID: requestID)
            ClaimFlowURLProtocol.enqueue(.failure(.timedOut))
            switch result {
            case .status(let status):
                ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: status)))
            case .notFound:
                ClaimFlowURLProtocol.enqueue(.response(
                    statusCode: 404,
                    data: errorResponse(code: ClaimErrorCode.requestNotFound, message: "Missing")
                ))
            case .decodingFailure:
                ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"request":{}}"#.utf8)))
            case .failure:
                ClaimFlowURLProtocol.enqueue(.failure(.notConnectedToInternet))
            }

            try? await store.fulfill(
                requestID: requestID,
                fulfillerEmail: "helper@example.edu",
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )

            XCTAssertNotNil(store.activeClaim)
            XCTAssertNotNil(store.fulfillmentAmbiguity)
            XCTAssertNil(store.fulfillmentConfirmation)
            XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count, 1)
            XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0 == "/api/request/\(requestID)" }.count, 1)
        }
    }

    func testPlacedDetailResolvesAmbiguityWithEmailUnknownConfirmation() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "placed")))

        try await store.fulfill(
            requestID: requestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentAmbiguity)
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertEqual(store.fulfillmentConfirmation?.kind, .emailStatusUnknown)
        XCTAssertEqual(
            FulfillRequestView.confirmationDetail(for: .emailStatusUnknown),
            "Your order is recorded. We couldn’t tell whether the student’s email went out, so they may not know their food is waiting. Don’t place another Grubhub order."
        )
    }

    func testAmbiguousSafetyCopyNeverInvitesAnotherOrderOrSubmission() {
        XCTAssertEqual(
            FulfillRequestView.ambiguousTitle(isCheckingStatus: true),
            "We’re checking your order"
        )
        XCTAssertEqual(
            FulfillRequestView.ambiguousTitle(isCheckingStatus: false),
            "We’re not sure your order was saved"
        )
        XCTAssertEqual(
            FulfillRequestView.ambiguousCheckingDetail,
            "Your order may already be saved. Don’t tap again or place another Grubhub order while we check."
        )
        XCTAssertEqual(
            FulfillRequestView.ambiguousUnresolvedDetail,
            "We lost the connection while saving and still can’t tell whether it went through. Don’t place another Grubhub order. The student may not have received an email. You can’t help with another request until this reservation expires."
        )
        // Neither ambiguous state may invite a second tap or a second order,
        // and neither may offer the in-app retry the store is refusing.
        for detail in [
            FulfillRequestView.ambiguousCheckingDetail,
            FulfillRequestView.ambiguousUnresolvedDetail
        ] {
            XCTAssertTrue(detail.localizedCaseInsensitiveContains("grubhub order"), detail)
            XCTAssertFalse(detail.contains(Self.inAppRetryDisclaimer), detail)
        }
        XCTAssertTrue(
            FulfillRequestView.ambiguousUnresolvedDetail.contains(Self.safetySentence)
        )
        for reason in [
            ClaimUnavailableReason.fulfillmentClaimExpired,
            .reservationNoLongerValid,
            .fulfillmentAlreadyPlaced,
            .fulfillmentRequestNotFound
        ] {
            let detail = ActiveRequestsView.claimUnavailableDetail(for: reason) ?? ""
            XCTAssertTrue(
                detail.localizedCaseInsensitiveContains("grubhub order"),
                "Missing order warning for \(reason)"
            )
        }
    }

    /// One sentence, reproduced exactly, wherever a second real-world order
    /// would cost a student money. Paraphrase is the failure this locks out.
    func testEverySafetyStateUsesTheOneGrubhubOrderSentence() {
        let mustCarryTheSentence: [String] = [
            FulfillmentPresentationError.invalidDetails.message,
            FulfillmentPresentationError.rateLimited.message,
            FulfillmentPresentationError.temporarilyUnavailable.message,
            FulfillRequestView.ambiguousUnresolvedDetail,
            FulfillRequestView.confirmationDetail(for: .notificationFailed),
            FulfillRequestView.confirmationDetail(for: .emailStatusUnknown),
            ActiveRequestsView.claimUnavailableDetail(for: .fulfillmentAlreadyPlaced) ?? "",
            ActiveRequestsView.claimUnavailableDetail(for: .reservationNoLongerValid) ?? "",
            ActiveRequestsView.claimUnavailableDetail(for: .fulfillmentRequestNotFound) ?? ""
        ]
        for copy in mustCarryTheSentence {
            XCTAssertTrue(
                copy.contains(Self.safetySentence),
                "Safety sentence missing or paraphrased: \(copy)"
            )
        }

        // The two states that must warn without that exact sentence — one is
        // mid-check, the other is the locked Day 4 pre-order expiration — still
        // have to forbid a real order in their own words.
        XCTAssertTrue(
            FulfillRequestView.ambiguousCheckingDetail
                .contains("Don’t tap again or place another Grubhub order while we check.")
        )
        let expiredAfterAttempt = ActiveRequestsView
            .claimUnavailableDetail(for: .fulfillmentClaimExpired) ?? ""
        XCTAssertTrue(expiredAfterAttempt.contains("don’t place it again"))
        XCTAssertTrue(expiredAfterAttempt.contains("do not start now"))

        // Retired vocabulary must not creep back into any of it.
        let everySafetyString = mustCarryTheSentence + [
            FulfillmentPresentationError.couldNotRecord.message,
            FulfillRequestView.ambiguousCheckingDetail,
            expiredAfterAttempt,
            FulfillRequestView.completedOrderNotice,
            FulfillRequestView.helperEmailNotice,
            RequestDetailView.claimConsequenceNotice,
            ClaimPresentationError.ambiguous.message,
            ClaimPresentationError.pendingPlacementAcknowledgement.message,
            ClaimPresentationError.otherClaimInProgress.message
        ]
        for copy in everySafetyString {
            for retired in ["external order", "requester", "placement result", "marked placed"] {
                XCTAssertFalse(
                    copy.localizedCaseInsensitiveContains(retired),
                    "Retired term “\(retired)” in: \(copy)"
                )
            }
        }
    }

    /// A structured failure the helper can genuinely retry must say that the
    /// retry is in-app. An ambiguous one, which the store refuses, must not.
    func testRetryableFailuresSeparateInAppRetryFromAnotherGrubhubOrder() {
        XCTAssertTrue(
            FulfillmentPresentationError.couldNotRecord.message
                .contains(Self.inAppRetryDisclaimer)
        )
        // The other structured failures point at the same button without
        // implying the order itself needs repeating.
        XCTAssertTrue(
            FulfillmentPresentationError.rateLimited.message
                .contains("then tap “I placed this order” again")
        )
        XCTAssertTrue(
            FulfillmentPresentationError.temporarilyUnavailable.message
                .contains("Stay on this screen and try again in a moment.")
        )
        // Field-blind by design now: the specific rule that failed is named on
        // the field, so the fallback points at the highlights instead of
        // guessing which field was wrong.
        XCTAssertTrue(
            FulfillmentPresentationError.invalidDetails.message
                .contains("Check the highlighted fields and try again.")
        )
        for error in [
            FulfillmentPresentationError.invalidDetails,
            .rateLimited,
            .temporarilyUnavailable,
            .couldNotRecord
        ] {
            XCTAssertFalse(
                error.message.localizedCaseInsensitiveContains("order again"),
                "Retry copy must never read as ordering again: \(error.message)"
            )
        }
    }

    func testStaleFulfillmentResponseCannotMutateAReplacementClaim() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "old-token")))
        try await store.claim(requestID: requestID)
        let oldGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: fulfillmentResponse(notificationStatus: "sent"),
            gate: oldGate
        ))
        let oldFulfillment = Task {
            try await store.fulfill(
                requestID: requestID,
                fulfillerEmail: "old@example.edu",
                orderNumber: "70150001",
                eta: "10 minutes",
                contactMessage: nil
            )
        }
        await waitUntil { oldGate.isWaiting }

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.leaveActiveClaimFlow()
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "new-token")))
        try await store.claim(requestID: requestID)

        oldGate.open()
        try await oldFulfillment.value

        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertEqual(store.requests.first?.status, .claimed)
    }

    func testStaleAmbiguityReadCannotMutateAReplacementClaim() async throws {
        let store = makeStore()
        let oldExpiration = Date().addingTimeInterval(10 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimToken: "old-token",
            claimExpiresAt: oldExpiration
        )))
        try await store.claim(requestID: requestID)
        let readGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "placed"), gate: readGate))
        let oldFulfillment = Task {
            try? await store.fulfill(
                requestID: requestID,
                fulfillerEmail: "old@example.edu",
                orderNumber: "70150001",
                eta: "10 minutes",
                contactMessage: nil
            )
        }
        await waitUntil { readGate.isWaiting }

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.revalidateActiveClaimExpiration(now: oldExpiration.addingTimeInterval(1))
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "new-token")))
        try await store.claim(requestID: requestID)

        readGate.open()
        await oldFulfillment.value

        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertNil(store.fulfillmentAmbiguity)
        XCTAssertEqual(store.requests.first?.status, .claimed)
    }

    func testBackNavigationGuaranteeStillPreservesPreSubmissionClaim() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "still-private")))
        try await store.claim(requestID: requestID)
        let paths = ClaimFlowURLProtocol.capturedPaths

        XCTAssertTrue(RequestDetailView.opensClaimedFlow(
            activeClaim: store.activeClaim,
            requestID: requestID
        ))
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, paths)
        XCTAssertNil(store.fulfillmentAmbiguity)
    }

    // MARK: - Day 5 confirmation reachability

    /// The claim is cleared and the request is removed the moment placement is
    /// confirmed, so once the claimant screen is gone neither the pinned
    /// reservation nor the list can carry the result. The confirmation itself
    /// has to survive that, or the helper never learns the order was recorded
    /// and can never acknowledge it.
    func testConfirmedPlacementArrivingAfterThePresentingViewIsGoneStaysReachable() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: fulfillmentResponse(notificationStatus: "failed"),
            gate: gate
        ))

        let submission = Task {
            try await store.fulfill(
                requestID: requestID,
                fulfillerEmail: "helper@example.edu",
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
        }
        await waitUntil { gate.isWaiting }
        gate.open()
        try await submission.value

        // Every claimant-screen anchor is gone: this is exactly the state a
        // helper who navigated Back mid-POST lands in.
        XCTAssertNil(store.activeClaim)
        XCTAssertTrue(store.requests.isEmpty)

        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertEqual(confirmation.requestID, requestID)
        XCTAssertEqual(confirmation.kind, .notificationFailed)
        XCTAssertEqual(
            FulfillRequestView.confirmationDetail(for: confirmation.kind),
            "Your order is recorded, but we couldn’t email the student. They may not know their food is waiting. Don’t place another Grubhub order."
        )
        // The card that carries it must still be able to name the meal.
        XCTAssertEqual(confirmation.vendor, "Crave NYU")
        XCTAssertEqual(confirmation.foodDescription, "Rice bowl")

        store.acknowledgeFulfillmentConfirmation(id: confirmation.id)
        XCTAssertNil(store.fulfillmentConfirmation)
    }

    /// Week 2 holds one confirmation. The only thing that can protect an
    /// unacknowledged result from being overwritten is refusing to start the
    /// claim that would eventually replace it.
    func testUnacknowledgedConfirmationBlocksAnotherClaimUntilAcknowledged() async throws {
        let otherRequestID = "meal-b"
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(notificationStatus: "failed")))
        try await store.fulfill(
            requestID: requestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )
        let original = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertEqual(original.requestID, requestID)
        XCTAssertEqual(original.kind, .notificationFailed)
        let pathsAfterPlacement = ClaimFlowURLProtocol.capturedPaths

        // Deliberately not acknowledged.
        do {
            try await store.claim(requestID: otherRequestID)
            XCTFail("An unacknowledged placement result must gate the next claim")
        } catch RequestServiceError.unacknowledgedPlacement {
            // Refused before any request was built.
        } catch {
            XCTFail("Unexpected gate error: \(error)")
        }

        // No second claim POST, so no second placement can overwrite the first.
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsAfterPlacement)
        let held = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertEqual(held.id, original.id)
        XCTAssertEqual(held.requestID, requestID)
        XCTAssertEqual(held.kind, .notificationFailed)
        let recorded = try XCTUnwrap(store.claimError(for: otherRequestID))
        XCTAssertEqual(ClaimPresentationError.map(recorded), .pendingPlacementAcknowledgement)

        store.acknowledgeFulfillmentConfirmation(id: original.id)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertNil(store.claimError(for: otherRequestID), "The obsolete refusal must clear too")

        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(responseRequestID: otherRequestID)
        ))
        try await store.claim(requestID: otherRequestID)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: otherRequestID))

        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(
            notificationStatus: "sent",
            responseRequestID: otherRequestID
        )))
        try await store.fulfill(
            requestID: otherRequestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "70159876",
            eta: "20 minutes",
            contactMessage: nil
        )
        XCTAssertEqual(store.fulfillmentConfirmation?.requestID, otherRequestID)
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") },
            ["/api/request/\(requestID)/fulfill", "/api/request/\(otherRequestID)/fulfill"]
        )
    }

    func testPendingAcknowledgementIsExplainedAndWithdrawsTheClaimAction() async throws {
        XCTAssertEqual(
            ClaimPresentationError.map(RequestServiceError.unacknowledgedPlacement),
            .pendingPlacementAcknowledgement
        )
        XCTAssertEqual(RequestDetailView.pendingPlacementTitle, "Check your last order first")
        XCTAssertEqual(
            RequestDetailView.pendingPlacementNotice,
            "Go back to Active Requests and tap “Got it” on your last order. Then you can help with another request."
        )
        let message = ClaimPresentationError.pendingPlacementAcknowledgement.message
        XCTAssertTrue(message.contains(RequestDetailView.pendingPlacementTitle))
        XCTAssertTrue(message.contains(RequestDetailView.pendingPlacementNotice))
        // The gate names the exact control that clears it, on the screen that
        // has it — otherwise the block has no visible remedy.
        XCTAssertTrue(message.contains(ActiveRequestsView.confirmationAcknowledgeTitle))
        XCTAssertTrue(message.contains("Active Requests"))
        XCTAssertFalse(RequestDetailView.showsClaimAction(for: .pendingPlacementAcknowledgement))
    }

    func testAcknowledgementClearsOnlyThatConfirmationAndUnblocksTheNextClaim() async throws {
        let otherRequestID = "meal-b"
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(notificationStatus: "sent")))
        try await store.fulfill(
            requestID: requestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        store.acknowledgeFulfillmentConfirmation(id: UUID())
        XCTAssertNotNil(store.fulfillmentConfirmation, "A mismatched ID must not clear it")

        store.acknowledgeFulfillmentConfirmation(id: confirmation.id)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertNil(store.confirmedFulfillmentOutcome)

        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(responseRequestID: otherRequestID)
        ))
        try await store.claim(requestID: otherRequestID)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: otherRequestID))

        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(
            notificationStatus: "sent",
            responseRequestID: otherRequestID
        )))
        try await store.fulfill(
            requestID: otherRequestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "70159876",
            eta: "20 minutes",
            contactMessage: nil
        )
        XCTAssertEqual(store.fulfillmentConfirmation?.requestID, otherRequestID)
    }

    /// A fetch that started before the placement carries a pre-placement
    /// snapshot. `collectionRevision` must discard it rather than let it put the
    /// placed request back on the list behind the confirmation.
    func testPlacedRequestIsNotReinsertedByAFetchStartedBeforeConfirmation() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        XCTAssertEqual(store.requests.map(\.id), [requestID])

        let staleFetchGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: requestID, status: "open")]),
            gate: staleFetchGate
        ))
        let staleFetch = Task { await store.fetchRequests() }
        await waitUntil { staleFetchGate.isWaiting }

        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(notificationStatus: "sent")))
        try await store.fulfill(
            requestID: requestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )
        XCTAssertTrue(store.requests.isEmpty)

        staleFetchGate.open()
        await staleFetch.value

        XCTAssertTrue(store.requests.isEmpty, "A pre-placement snapshot must not reinsert it")
        XCTAssertEqual(store.fulfillmentConfirmation?.requestID, requestID)
    }

    // MARK: - Day 5 expiration and ambiguity presentation

    /// Drives the real lifecycle timer rather than the foreground seam: the
    /// warning must not depend on which path happens to notice the deadline.
    func testLifecycleTimerExpiryDuringUnresolvedAmbiguityUsesTheFulfillmentWarning() async throws {
        let store = makeStore()
        // Long enough that the stubbed POST and the one read finish well inside
        // it, so the post-attempt resume cannot pre-empt the timer and quietly
        // turn this into a test of the other path.
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(2)
        )))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        try? await store.fulfill(
            requestID: requestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        // The post-attempt resume must not have expired it yet, or this would be
        // testing that path instead of the timer.
        XCTAssertNotNil(store.activeClaim)
        XCTAssertNotNil(store.fulfillmentAmbiguity)
        XCTAssertNil(store.claimUnavailableNotice)

        await waitUntil(timeoutIterations: 800) { store.claimUnavailableNotice != nil }

        XCTAssertEqual(store.claimUnavailableNotice?.reason, .fulfillmentClaimExpired)
        XCTAssertEqual(
            ActiveRequestsView.claimUnavailableTitle(for: .fulfillmentClaimExpired),
            "Your reservation ran out"
        )
        XCTAssertEqual(
            ActiveRequestsView.claimUnavailableDetail(for: .fulfillmentClaimExpired),
            "If you already completed the Grubhub order, don’t place it again. CommonPlate may not have saved the details, so the student may not have been emailed. If you had not ordered yet, do not start now."
        )
        // The warning has to outlive the state it was derived from.
        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentAmbiguity)
        XCTAssertNotNil(store.claimUnavailableNotice)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count, 1)
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    func testAmbiguityDistinguishesActiveCheckingFromSettledUncertainty() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let readGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(
            data: detailResponse(status: "claimed"),
            gate: readGate
        ))

        let submission = Task {
            try? await store.fulfill(
                requestID: requestID,
                fulfillerEmail: "helper@example.edu",
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
        }
        await waitUntil { readGate.isWaiting }

        XCTAssertEqual(store.fulfillmentAmbiguity?.isCheckingStatus, true)
        let checking = FulfillRequestView.ambiguousDetail(isCheckingStatus: true)
        XCTAssertEqual(checking, FulfillRequestView.ambiguousCheckingDetail)
        XCTAssertTrue(checking.contains("while we check"))

        readGate.open()
        await submission.value

        XCTAssertEqual(store.fulfillmentAmbiguity?.isCheckingStatus, false)
        let settled = FulfillRequestView.ambiguousDetail(isCheckingStatus: false)
        XCTAssertEqual(settled, FulfillRequestView.ambiguousUnresolvedDetail)
        XCTAssertFalse(settled.contains("while we check"))
        XCTAssertTrue(settled.contains("still can’t tell whether it went through"))
        XCTAssertTrue(settled.contains("until this reservation expires"))
        // The state stops claiming a check is running, in its title too.
        XCTAssertEqual(
            FulfillRequestView.ambiguousTitle(isCheckingStatus: false),
            FulfillRequestView.ambiguousUnresolvedTitle
        )
        // It names an exit, so it has to offer one — and only the settled state
        // does, because the checking state is about to answer itself.
        XCTAssertTrue(FulfillRequestView.showsAmbiguityReturnAction(isCheckingStatus: false))
        XCTAssertFalse(FulfillRequestView.showsAmbiguityReturnAction(isCheckingStatus: true))
        XCTAssertEqual(FulfillRequestView.returnTitle, "Back to Active Requests")

        // Settling performs no further work of any kind.
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, [
            "/api/request/\(requestID)/claim",
            "/api/request/\(requestID)/fulfill",
            "/api/request/\(requestID)"
        ])
        XCTAssertNotNil(store.activeClaim)
        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID))
    }

    /// The replacement reuses the same request ID, so only the per-claim
    /// identity separates it from the attempt whose response is still arriving.
    func testTerminalResponseFromAnOldAttemptCannotClearAReplacementClaim() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "old-token")))
        try await store.claim(requestID: requestID)

        let conflictGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(
                code: ClaimErrorCode.requestAlreadyPlaced,
                message: "Already placed"
            ),
            gate: conflictGate
        ))
        let oldAttempt = Task {
            try? await store.fulfill(
                requestID: requestID,
                fulfillerEmail: "old@example.edu",
                orderNumber: "70150001",
                eta: "10 minutes",
                contactMessage: nil
            )
        }
        await waitUntil { conflictGate.isWaiting }

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.leaveActiveClaimFlow()
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "new-token")))
        try await store.claim(requestID: requestID)
        let replacementExpiration = store.activeClaim?.claimExpiresAt

        conflictGate.open()
        await oldAttempt.value

        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertEqual(store.activeClaim?.claimExpiresAt, replacementExpiration)
        XCTAssertNil(store.claimUnavailableNotice, "An old conflict must not end the replacement")
        XCTAssertNil(store.fulfillError)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertEqual(store.requests.first?.status, .claimed)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))
    }

    // MARK: - Pre-flight claim refusals

    /// The refusal is decided before any attempt exists, and `startClaim()`
    /// discards the thrown error, so only a published event can carry the
    /// accepted copy to the screen.
    func testClaimingWhileHoldingAnotherReservationPublishesTheRefusal() async throws {
        let requestB = "meal-b"
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "token-for-a")))
        try await store.claim(requestID: requestID)
        let pathsAfterFirstClaim = ClaimFlowURLProtocol.capturedPaths

        do {
            try await store.claim(requestID: requestB)
            XCTFail("A second claim must not start while one is held")
        } catch RequestServiceError.existingActiveClaim {
            // Expected.
        } catch {
            XCTFail("Unexpected refusal: \(error)")
        }

        let recorded = try XCTUnwrap(
            store.claimError(for: requestB),
            "The refusal must reach the screen the helper tapped"
        )
        XCTAssertEqual(ClaimPresentationError.map(recorded), .existingActiveClaim)
        XCTAssertEqual(
            ClaimPresentationError.existingActiveClaim.message,
            "You’re already helping with another request. Finish that one or wait for its reservation to end."
        )
        XCTAssertFalse(RequestDetailView.showsClaimAction(for: .existingActiveClaim))

        // Request-scoped: unrelated details stay clean.
        XCTAssertNil(store.claimError(for: requestID))
        XCTAssertNil(store.claimError(for: "meal-c"))

        // No POST for B, and A is untouched and still re-enterable.
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsAfterFirstClaim)
        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(claim.requestID, requestID)
        XCTAssertEqual(claim.pickupName, "Taylor")
        XCTAssertTrue(RequestDetailView.opensClaimedFlow(
            activeClaim: store.activeClaim,
            requestID: requestID
        ))

        // The blocker going away retires the refusal it produced.
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.leaveActiveClaimFlow()
        XCTAssertNil(store.claimError(for: requestB))
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    func testDuplicateTapWhileAClaimIsInFlightPublishesOperationInProgress() async throws {
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(), gate: claimGate))

        let firstClaim = Task { try await store.claim(requestID: requestID) }
        await waitUntil { claimGate.isWaiting }
        XCTAssertTrue(store.isClaiming(requestID: requestID))

        do {
            try await store.claim(requestID: requestID)
            XCTFail("A duplicate tap must not start a second claim")
        } catch RequestServiceError.operationInProgress {
            // Expected.
        } catch {
            XCTFail("Unexpected duplicate error: \(error)")
        }

        let recorded = try XCTUnwrap(store.claimError(for: requestID))
        XCTAssertEqual(ClaimPresentationError.map(recorded), .operationInProgress)
        XCTAssertEqual(
            ClaimPresentationError.operationInProgress.message,
            "You’re already starting to help with this request."
        )
        XCTAssertNil(store.claimError(for: "meal-b"), "The refusal is request-scoped")
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/claim") }.count,
            1,
            "Exactly one claim POST"
        )

        claimGate.open()
        try await firstClaim.value
        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertNil(
            store.claimError(for: requestID),
            "The attempt finished starting, so the refusal is retired"
        )
    }

    /// The other request is not "already starting", so borrowing the
    /// same-request sentence would misdescribe the screen the helper is on.
    func testInFlightClaimOnAnotherRequestPublishesItsOwnHonestRefusal() async throws {
        let requestB = "meal-b"
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(), gate: claimGate))

        let claimA = Task { try await store.claim(requestID: requestID) }
        await waitUntil { claimGate.isWaiting }

        do {
            try await store.claim(requestID: requestB)
            XCTFail("A concurrent claim must be refused")
        } catch RequestServiceError.otherClaimInProgress {
            // Expected: distinct from the same-request duplicate.
        } catch {
            XCTFail("Unexpected concurrent-claim error: \(error)")
        }

        let recorded = try XCTUnwrap(
            store.claimError(for: requestB),
            "The refusal must reach the screen the helper tapped"
        )
        XCTAssertEqual(ClaimPresentationError.map(recorded), .otherClaimInProgress)
        XCTAssertEqual(RequestDetailView.otherClaimInProgressTitle, "Please wait")
        XCTAssertEqual(
            RequestDetailView.otherClaimInProgressNotice,
            "We’re still reserving another request. Try this one again in a moment."
        )
        // A moment's wait, not "go finish that whole order first" — which is
        // what the existing-reservation refusal means.
        XCTAssertFalse(
            RequestDetailView.otherClaimInProgressNotice
                .localizedCaseInsensitiveContains("finish")
        )
        let message = ClaimPresentationError.otherClaimInProgress.message
        XCTAssertTrue(message.contains(RequestDetailView.otherClaimInProgressTitle))
        XCTAssertTrue(message.contains(RequestDetailView.otherClaimInProgressNotice))
        XCTAssertFalse(
            message.contains("this request."),
            "It must not claim that *this* request is already starting"
        )
        XCTAssertNotEqual(message, ClaimPresentationError.operationInProgress.message)
        // A short wait, not a commitment elsewhere: the action stays offered.
        XCTAssertTrue(RequestDetailView.showsClaimAction(for: .otherClaimInProgress))

        // Scoped to B only, and A's attempt is untouched.
        XCTAssertNil(store.claimError(for: requestID))
        XCTAssertNil(store.claimError(for: "meal-c"))
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/claim") }.count,
            1,
            "Exactly one claim POST"
        )
        XCTAssertTrue(store.isClaiming(requestID: requestID))
        XCTAssertFalse(store.isClaiming(requestID: requestB))

        claimGate.open()
        try await claimA.value

        // A completed normally and the refusal it caused is retired.
        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertEqual(store.activeClaim?.pickupName, "Taylor")
        XCTAssertNil(
            store.claimError(for: requestB),
            "The blocker resolved, so the wait notice must go"
        )
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/claim") }.count,
            1
        )
    }

    /// Same request, same moment: this one really is already starting, and its
    /// existing sentence must not have been swapped for the new one.
    func testSameRequestDuplicateTapStillUsesTheOperationInProgressCopy() async throws {
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(), gate: claimGate))

        let claimA = Task { try await store.claim(requestID: requestID) }
        await waitUntil { claimGate.isWaiting }

        do {
            try await store.claim(requestID: requestID)
            XCTFail("A duplicate tap must be refused")
        } catch RequestServiceError.operationInProgress {
            // Expected: unchanged from Day 4.
        } catch {
            XCTFail("Unexpected duplicate error: \(error)")
        }

        let recorded = try XCTUnwrap(store.claimError(for: requestID))
        XCTAssertEqual(ClaimPresentationError.map(recorded), .operationInProgress)
        XCTAssertEqual(
            ClaimPresentationError.operationInProgress.message,
            "You’re already starting to help with this request."
        )

        claimGate.open()
        try await claimA.value
        XCTAssertEqual(store.activeClaim?.requestID, requestID)
    }

    /// The gate added for unacknowledged placements shares the same event
    /// mechanism, so it has to keep working once the other refusals use it too.
    func testPreflightRefusalsCoexistWithTheUnacknowledgedPlacementGate() async throws {
        let requestB = "meal-b"
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(notificationStatus: "sent")))
        try await store.fulfill(
            requestID: requestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )
        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        let pathsAfterPlacement = ClaimFlowURLProtocol.capturedPaths

        // No active claim any more, so the gate — not `existingActiveClaim` —
        // is what refuses, and it reports its own copy.
        do {
            try await store.claim(requestID: requestB)
            XCTFail("The acknowledgement gate must still refuse")
        } catch RequestServiceError.unacknowledgedPlacement {
            // Expected.
        } catch {
            XCTFail("Unexpected gate error: \(error)")
        }
        let gated = try XCTUnwrap(store.claimError(for: requestB))
        XCTAssertEqual(ClaimPresentationError.map(gated), .pendingPlacementAcknowledgement)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsAfterPlacement)

        store.acknowledgeFulfillmentConfirmation(id: confirmation.id)
        XCTAssertNil(store.claimError(for: requestB))

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(responseRequestID: requestB)))
        try await store.claim(requestID: requestB)
        XCTAssertEqual(store.activeClaim?.requestID, requestB)
        XCTAssertNil(store.claimError(for: requestB))
    }

    // MARK: - Day 5 extension expiry

    func testExtensionExpiryWithoutAFulfillmentAttemptKeepsTheDay4Warning() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(code: ClaimErrorCode.claimExpired, message: "Claim expired")
        ))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        await store.extendActiveClaim()

        XCTAssertEqual(store.claimUnavailableNotice?.reason, .claimExpired)
        XCTAssertEqual(
            ActiveRequestsView.claimUnavailableDetail(for: .claimExpired),
            "Please don’t place an order for that request. Someone else may already be helping."
        )
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(ClaimFlowURLProtocol.capturedPaths.contains { $0.hasSuffix("/fulfill") })
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    /// A nonterminal fulfillment failure leaves the claim alive and the helper
    /// holding a real external order. If the backend then expires the claim on
    /// the extension call, that is the same situation the timer announces and
    /// must not be described as though nothing had been ordered.
    func testExtensionExpiryAfterAFulfillmentAttemptUsesTheFulfillmentWarning() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 500,
            data: errorResponse(code: ClaimErrorCode.internalFailure, message: "Could not persist")
        ))
        try? await store.fulfill(
            requestID: requestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )
        XCTAssertNotNil(store.activeClaim, "A nonterminal failure keeps the reservation")

        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(code: ClaimErrorCode.claimExpired, message: "Claim expired")
        ))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        await store.extendActiveClaim()

        XCTAssertEqual(store.claimUnavailableNotice?.reason, .fulfillmentClaimExpired)
        XCTAssertEqual(
            ActiveRequestsView.claimUnavailableDetail(for: .fulfillmentClaimExpired),
            "If you already completed the Grubhub order, don’t place it again. CommonPlate may not have saved the details, so the student may not have been emailed. If you had not ordered yet, do not start now."
        )
        // The warning has to outlive the claimant state it was derived from.
        XCTAssertNil(store.activeClaim)
        XCTAssertNotNil(store.claimUnavailableNotice)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count, 1)
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    func testStaleExtensionFailureCannotMutateAReplacementClaim() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "old-token")))
        try await store.claim(requestID: requestID)

        let extensionGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(code: ClaimErrorCode.claimExpired, message: "Claim expired"),
            gate: extensionGate
        ))
        let staleExtension = Task { await store.extendActiveClaim() }
        await waitUntil { extensionGate.isWaiting }

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.leaveActiveClaimFlow()
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "new-token")))
        try await store.claim(requestID: requestID)
        let replacementExpiration = store.activeClaim?.claimExpiresAt

        extensionGate.open()
        await staleExtension.value

        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertEqual(store.activeClaim?.claimExpiresAt, replacementExpiration)
        XCTAssertNil(store.claimUnavailableNotice, "An old expiry must not end the replacement")
        XCTAssertNil(store.claimExtensionError)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))
    }

    // MARK: - Helpers

    private func decodeStatus(_ value: String) throws -> RequestStatus {
        struct Wrapper: Decodable {
            let status: RequestStatusWire
        }
        let decoded = try JSONDecoder().decode(
            Wrapper.self,
            from: Data(#"{"status":"\#(value)"}"#.utf8)
        )
        return decoded.status.domainStatus
    }

    // MARK: - Leaving a confirmed placement

    /// The walkthrough path: Active Requests → request detail → claim →
    /// claimant screen. "Back to Active Requests" has to land on the list, not
    /// on an emptied reservation screen sitting above two dead destinations.
    func testConfirmedPlacementReturnsToActiveRequestsFromTheDetailEntryPath() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let claimed = try XCTUnwrap(store.activeClaim?.request)

        // The stack this entry path actually builds.
        var path: [AppRoute] = [.activeRequests]
        path = AppRoute.appending(.requestDetail(claimed), to: path)
        path = AppRoute.appending(.fulfillment(claimed), to: path)
        XCTAssertEqual(path, [.activeRequests, .requestDetail(claimed), .fulfillment(claimed)])

        ClaimFlowURLProtocol.enqueue(
            .response(data: fulfillmentResponse(notificationStatus: "sent"))
        )
        try await store.fulfill(
            requestID: requestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "70154321",
            eta: FulfillmentReadyTime.asap.etaValue,
            contactMessage: nil
        )

        // Placement clears the claim immediately; the unacknowledged
        // confirmation is the only thing keeping the screen alive.
        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertNil(store.activeClaim)
        XCTAssertTrue(FulfillRequestView.keepsClaimedFlowPresented(
            activeRequestID: store.activeClaim?.requestID,
            confirmationRequestID: confirmation.requestID,
            requestID: requestID
        ))

        // "Back to Active Requests".
        store.acknowledgeFulfillmentConfirmation(id: confirmation.id)
        path = AppRoute.returningToActiveRequests(from: path)

        XCTAssertEqual(path, [.activeRequests])
        XCTAssertFalse(AppRoute.containsHelperDestination(in: path, requestID: requestID))
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(store.requests.contains { $0.id == requestID })
        // With neither a claim nor a confirmation the claimant screen renders
        // nothing at all — the blank "Your reservation" screen. It must be off
        // the stack, not merely emptied.
        XCTAssertFalse(FulfillRequestView.hasPresentableContent(
            hasClaim: store.activeClaim != nil,
            hasConfirmation: store.fulfillmentConfirmation != nil
        ))
    }

    /// The second supported entry: reopening the reservation from the pinned
    /// item, with no request detail underneath. Same landing.
    func testConfirmedPlacementReturnsToActiveRequestsFromThePinnedEntryPath() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let claimed = try XCTUnwrap(store.activeClaim?.request)

        var path: [AppRoute] = AppRoute.appending(
            .fulfillment(claimed),
            to: [.activeRequests]
        )
        XCTAssertEqual(path, [.activeRequests, .fulfillment(claimed)])

        ClaimFlowURLProtocol.enqueue(
            .response(data: fulfillmentResponse(notificationStatus: "failed"))
        )
        try await store.fulfill(
            requestID: requestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "70154321",
            eta: FulfillmentReadyTime.thirtyMinutes.etaValue,
            contactMessage: nil
        )

        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertEqual(confirmation.kind, .notificationFailed)

        store.acknowledgeFulfillmentConfirmation(id: confirmation.id)
        path = AppRoute.returningToActiveRequests(from: path)

        XCTAssertEqual(path, [.activeRequests])
        XCTAssertFalse(AppRoute.containsHelperDestination(in: path, requestID: requestID))
        XCTAssertNil(store.fulfillmentConfirmation)
    }

    /// Whatever the helper flow stacked up, leaving it leaves nothing behind
    /// that Back could reach — including the detail for a *different* request
    /// that the blocked-claim shortcut pushes a reservation on top of.
    func testReturningNeverLeavesAHelperDestinationBackCouldReach() {
        let placed = foodRequest(id: requestID)
        let other = foodRequest(id: "meal-b")

        let stacks: [[AppRoute]] = [
            [.activeRequests, .requestDetail(placed), .fulfillment(placed)],
            [.activeRequests, .fulfillment(placed)],
            [.activeRequests, .requestDetail(other), .fulfillment(placed)]
        ]

        for stack in stacks {
            let returned = AppRoute.returningToActiveRequests(from: stack)
            XCTAssertEqual(returned, [.activeRequests], "\(stack)")
            XCTAssertEqual(returned.last, .activeRequests)
            XCTAssertFalse(
                AppRoute.containsHelperDestination(in: returned, requestID: requestID)
            )
            XCTAssertFalse(
                AppRoute.containsHelperDestination(in: returned, requestID: "meal-b")
            )
        }
    }

    /// Only a confirmed claim or an unacknowledged confirmation for *this*
    /// request keeps the claimant screen. When neither holds, the detail
    /// underneath is just as stale, so the whole flow unwinds rather than one
    /// level — otherwise the backend's verdict lands on a screen for a request
    /// the helper no longer holds.
    func testClaimEndingUnwindsTheDetailUnderneathToo() {
        let request = foodRequest(id: requestID)
        let path: [AppRoute] = [
            .activeRequests, .requestDetail(request), .fulfillment(request)
        ]

        XCTAssertFalse(FulfillRequestView.keepsClaimedFlowPresented(
            activeRequestID: nil, confirmationRequestID: nil, requestID: requestID
        ))
        XCTAssertFalse(FulfillRequestView.keepsClaimedFlowPresented(
            activeRequestID: "meal-b", confirmationRequestID: nil, requestID: requestID
        ))
        XCTAssertTrue(FulfillRequestView.keepsClaimedFlowPresented(
            activeRequestID: requestID, confirmationRequestID: nil, requestID: requestID
        ))
        XCTAssertEqual(AppRoute.returningToActiveRequests(from: path), [.activeRequests])
    }

    /// Entering is driven by republishable store state, so the push has to be
    /// idempotent: one claim must never stack two identical destinations.
    func testConfirmedClaimPushesTheClaimantRouteOnlyOnce() {
        let request = foodRequest(id: requestID)
        let base: [AppRoute] = [.activeRequests, .requestDetail(request)]

        let opened = AppRoute.appending(.fulfillment(request), to: base)
        XCTAssertEqual(
            opened,
            [.activeRequests, .requestDetail(request), .fulfillment(request)]
        )
        XCTAssertEqual(AppRoute.appending(.fulfillment(request), to: opened), opened)
    }

    /// The action names a destination, so it always produces one.
    func testReturnFallsBackToActiveRequestsWhenItIsNotOnThePath() {
        XCTAssertEqual(AppRoute.returningToActiveRequests(from: []), [.activeRequests])
        XCTAssertEqual(
            AppRoute.returningToActiveRequests(from: [.requestFood]),
            [.activeRequests]
        )
    }

    func testEmptiedReservationScreenHasNothingToRender() {
        XCTAssertTrue(
            FulfillRequestView.hasPresentableContent(hasClaim: true, hasConfirmation: false)
        )
        XCTAssertTrue(
            FulfillRequestView.hasPresentableContent(hasClaim: false, hasConfirmation: true)
        )
        XCTAssertFalse(
            FulfillRequestView.hasPresentableContent(hasClaim: false, hasConfirmation: false)
        )
        XCTAssertEqual(FulfillRequestView.navigationTitle, "Your reservation")
    }

    // MARK: - When will it be ready?

    func testReadyTimeChoicesEncodeIntoTheUnchangedEtaField() {
        XCTAssertEqual(
            FulfillmentReadyTime.allCases.map(\.label),
            ["ASAP", "15 minutes", "30 minutes", "45 minutes", "60 minutes"]
        )

        for option in FulfillmentReadyTime.allCases {
            // What the helper picked is what the student is told: the visible
            // choice and the encoded `eta` string are the same text.
            XCTAssertEqual(option.etaValue, option.label)
            XCTAssertEqual(FulfillmentReadyTime.option(forETA: option.etaValue), option)
            // Every choice satisfies the unchanged required-field rule, so the
            // control can never leave submission gated on an empty ETA.
            XCTAssertTrue(FulfillRequestView.requiredFieldsArePresent(
                fulfillerEmail: "helper@example.edu",
                orderNumber: "70154321",
                eta: option.etaValue
            ))
        }

        XCTAssertEqual(FulfillRequestView.readyTimeQuestion, "When will it be ready?")
    }

    func testReadyTimeDefaultsToASAPUnlessDraftStateHoldsAnotherValidChoice() {
        XCTAssertEqual(FulfillmentReadyTime.initialSelection(draftETA: nil), .asap)
        XCTAssertEqual(FulfillmentReadyTime.initialSelection(draftETA: ""), .asap)
        XCTAssertEqual(FulfillmentReadyTime.initialSelection(draftETA: "   "), .asap)
        XCTAssertEqual(
            FulfillmentReadyTime.initialSelection(draftETA: "30 minutes"),
            .thirtyMinutes
        )
        XCTAssertEqual(
            FulfillmentReadyTime.initialSelection(draftETA: " 45 MINUTES "),
            .fortyFiveMinutes
        )
        // Free text that predates this control is not one of the choices, so it
        // is not silently rewritten into one.
        XCTAssertNil(FulfillmentReadyTime.option(forETA: "20 minutes"))
        XCTAssertEqual(FulfillmentReadyTime.initialSelection(draftETA: "in a bit"), .asap)
    }

    /// The control is presentation only. The request body is byte-for-byte the
    /// already-accepted shape, with the selection carried in `eta`.
    func testPickedReadyTimeStillSendsTheExactAcceptedPayload() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(
            .response(data: fulfillmentResponse(notificationStatus: "sent"))
        )

        try await store.fulfill(
            requestID: requestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "70154321",
            eta: FulfillmentReadyTime.asap.etaValue,
            contactMessage: nil
        )

        let sent = try XCTUnwrap(
            ClaimFlowURLProtocol.capturedRequests.first { $0.path.hasSuffix("/fulfill") }
        )
        let body = try XCTUnwrap(sent.bodyObject)
        XCTAssertEqual(Set(body.keys), ["claimToken", "fulfillment"])
        let fulfillment = try XCTUnwrap(body["fulfillment"] as? [String: Any])
        XCTAssertEqual(Set(fulfillment.keys), ["fulfillerEmail", "orderNumber", "eta"])
        XCTAssertEqual(fulfillment["eta"] as? String, "ASAP")
        // The control's own vocabulary never reaches the wire.
        XCTAssertNil(fulfillment["readyTime"])
        XCTAssertNil(fulfillment["etaText"])
        XCTAssertNil(fulfillment["etaMinutes"])
    }

    // MARK: - Reservation form comprehension

    func testReservationFormReadsAsTwoStepsWithoutTheRetiredHeadingOrFreeTextETA() {
        XCTAssertEqual(
            FulfillRequestView.completedOrderNotice,
            "Place the Grubhub order first. Then save the details here."
        )
        XCTAssertEqual(
            FulfillRequestView.helperEmailNotice,
            "The student will see this email and can reply."
        )
        XCTAssertEqual(
            FulfillRequestView.orderNumberNotice,
            "From your Grubhub confirmation."
        )
        XCTAssertEqual(FulfillRequestView.readyTimeQuestion, "When will it be ready?")
        XCTAssertEqual(FulfillRequestView.submitTitle, "I placed this order")

        let visibleFormCopy = [
            FulfillRequestView.completedOrderNotice,
            FulfillRequestView.helperEmailNotice,
            FulfillRequestView.orderNumberNotice,
            FulfillRequestView.readyTimeQuestion
        ]
        for copy in visibleFormCopy {
            XCTAssertFalse(copy.contains("After you’ve ordered"), copy)
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("Ready in"), copy)
            for retired in ["external order", "requester"] {
                XCTAssertFalse(copy.localizedCaseInsensitiveContains(retired), copy)
            }
        }
    }

    /// One direct instruction beside the revealed name — not a tutorial — and
    /// the name still goes nowhere but the claimant screen.
    func testPickupNameInstructionNamesTheRevealedNameOnce() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(pickupName: "Taylor")))
        try await store.claim(requestID: requestID)

        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(claim.pickupName, "Taylor")

        let instruction = FulfillRequestView.pickupNameInstruction(
            pickupName: claim.pickupName
        )
        XCTAssertEqual(instruction, "Use “Taylor” as the pickup name in Grubhub.")
        XCTAssertEqual(instruction.filter { $0 == "." }.count, 1)

        ClaimFlowURLProtocol.enqueue(
            .response(data: fulfillmentResponse(notificationStatus: "sent"))
        )
        try await store.fulfill(
            requestID: requestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "70154321",
            eta: FulfillmentReadyTime.asap.etaValue,
            contactMessage: nil
        )

        // The confirmation outlives the claim and carries public identity only.
        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(confirmation.vendor.contains("Taylor"))
        XCTAssertFalse(confirmation.foodDescription.contains("Taylor"))
    }

    // MARK: - Field-specific local validation

    func testEmailFailuresAreNamedOnTheEmailField() {
        XCTAssertEqual(
            FulfillmentFormValidator.emailError(""),
            "Enter your email address."
        )
        XCTAssertEqual(
            FulfillmentFormValidator.emailError("   "),
            "Enter your email address."
        )
        // Faith's entry: a plausible-looking address the backend refuses.
        for invalid in [
            "helper.example.edu",
            "helper@",
            "@example.edu",
            "helper@example",
            "helper @example.edu",
            "helper@exam ple.edu"
        ] {
            XCTAssertEqual(
                FulfillmentFormValidator.emailError(invalid),
                "Enter a valid email address, like name@example.com.",
                invalid
            )
        }
        for valid in [
            "helper@example.edu",
            "  helper@example.edu  ",
            "first.last+tag@nyu.edu"
        ] {
            XCTAssertNil(FulfillmentFormValidator.emailError(valid), valid)
        }
    }

    func testEmptyOrderNumberIsNamedOnItsOwnField() {
        XCTAssertEqual(
            FulfillmentFormValidator.orderNumberError(""),
            "Enter the Grubhub order number."
        )
        XCTAssertEqual(
            FulfillmentFormValidator.orderNumberError("  "),
            "Enter the Grubhub order number."
        )
        XCTAssertEqual(
            FulfillmentFormValidator.orderNumberError("\n\t"),
            "Enter the Grubhub order number."
        )
    }

    func testDigitsOnlyOrderNumbersAreAccepted() {
        for valid in ["1", "70154321", "  70154321  ", String(repeating: "7", count: 50)] {
            XCTAssertNil(FulfillmentFormValidator.orderNumberError(valid), valid)
        }
    }

    /// The reason this stays a string end to end. A numeric type would drop the
    /// zeroes and the value would no longer match the helper's confirmation.
    func testLeadingZeroOrderNumbersSurviveValidationExactly() {
        for withZeroes in ["0", "007", "00070154321", "0000000000"] {
            XCTAssertNil(FulfillmentFormValidator.orderNumberError(withZeroes), withZeroes)
        }
        XCTAssertTrue(FulfillRequestView.requiredFieldsArePresent(
            fulfillerEmail: "helper@example.edu",
            orderNumber: "00070154321",
            eta: FulfillmentReadyTime.asap.etaValue
        ))
    }

    func testAnythingOtherThanDigitsIsRejectedWithUseNumbersOnly() {
        let nonNumeric = [
            "7015432A",       // one letter
            "A70154321",
            "7015 4321",      // space
            " 70 154 321 ",   // interior spaces survive trimming
            "7015-4321",      // dash
            "7015_4321",      // underscore
            "7015.4321",      // decimal point
            "+70154321",      // sign
            "-70154321",
            "70154321!",      // punctuation
            "ORDER123"        // the old contract's shape
        ]
        for invalid in nonNumeric {
            XCTAssertEqual(
                FulfillmentFormValidator.orderNumberError(invalid),
                "Use numbers only.",
                invalid
            )
        }
    }

    func testFiftyDigitsAreAcceptedAndFiftyOneAreNot() {
        XCTAssertNil(
            FulfillmentFormValidator.orderNumberError(String(repeating: "7", count: 50))
        )
        XCTAssertEqual(
            FulfillmentFormValidator.orderNumberError(String(repeating: "7", count: 51)),
            "Use 50 digits or fewer."
        )
    }

    /// Precedence: shortening has to happen first, so a value that breaks both
    /// rules is told it is too long rather than sent round the loop twice.
    func testLengthErrorTakesPrecedenceOverTheNumericError() {
        let tooLongAndNotNumeric = String(repeating: "7", count: 50) + "A"
        XCTAssertEqual(tooLongAndNotNumeric.count, 51)
        XCTAssertEqual(
            FulfillmentFormValidator.orderNumberError(tooLongAndNotNumeric),
            "Use 50 digits or fewer."
        )

        let letterFirst = "A" + String(repeating: "7", count: 50)
        XCTAssertEqual(
            FulfillmentFormValidator.orderNumberError(letterFirst),
            "Use 50 digits or fewer."
        )

        // At exactly 50 the length rule is satisfied, so the numeric rule is the
        // one that answers.
        XCTAssertEqual(
            FulfillmentFormValidator.orderNumberError(
                String(repeating: "7", count: 49) + "A"
            ),
            "Use numbers only."
        )
    }

    /// Every rule here is the backend's own, so a payload iOS accepts is one the
    /// backend's schema accepts too — which is what keeps the generic fallback
    /// genuinely reserved for rejections that carry no field attribution.
    func testLocalRulesMirrorTheBackendSchemaRatherThanInventingNewOnes() {
        // `orderNumber: /^[0-9]{1,50}$/`
        XCTAssertEqual(FulfillmentFormValidator.orderNumberMaximumLength, 50)
        XCTAssertNil(
            FulfillmentFormValidator.orderNumberError(String(repeating: "0", count: 50))
        )
        XCTAssertNotNil(
            FulfillmentFormValidator.orderNumberError(String(repeating: "0", count: 51))
        )
        // Ready time is a fixed-choice picker, so it has no local failure mode
        // and therefore no message of its own.
        XCTAssertEqual(FulfillmentFormField.allCases, [.fulfillerEmail, .orderNumber])
    }

    /// Both fields report at once, in screen order, so the first invalid one is
    /// also the one focused.
    func testValidationReportsEveryInvalidFieldInScreenOrder() {
        let errors = FulfillmentFormValidator.validate(
            fulfillerEmail: "not-an-email",
            orderNumber: "7015 4321"
        )
        XCTAssertEqual(errors.map(\.field), [.fulfillerEmail, .orderNumber])
        XCTAssertEqual(errors.first?.field, .fulfillerEmail)
        XCTAssertEqual(
            errors.map(\.message),
            [
                "Enter a valid email address, like name@example.com.",
                "Use numbers only."
            ]
        )

        XCTAssertEqual(
            FulfillmentFormValidator.validate(
                fulfillerEmail: "helper@example.edu",
                orderNumber: "7015 4321"
            ).map(\.field),
            [.orderNumber]
        )
        XCTAssertTrue(
            FulfillmentFormValidator.validate(
                fulfillerEmail: "helper@example.edu",
                orderNumber: "70154321"
            ).isEmpty
        )
    }

    /// The point of validating locally: a formatting mistake never reaches the
    /// network, so nothing about a real Grubhub order is put at risk by it.
    func testLocallyInvalidDetailsSendNoFulfillmentPost() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)

        let email = "helper.example.edu"
        let orderNumber = "70154321"
        let errors = FulfillmentFormValidator.validate(
            fulfillerEmail: email,
            orderNumber: orderNumber
        )
        XCTAssertFalse(errors.isEmpty)

        // The submit path returns on a non-empty result before building a
        // request, so the only captured call is still the claim.
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths,
            ["/api/request/\(requestID)/claim"]
        )
        XCTAssertFalse(ClaimFlowURLProtocol.capturedPaths.contains { $0.hasSuffix("/fulfill") })

        // Nothing about the reservation is disturbed by the rejection: the
        // claim is intact and a corrected submission is still permitted.
        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertNil(store.fulfillError)
        XCTAssertNil(store.fulfillmentConfirmation)
    }

    /// A rejected submit reports, it does not reset. Correcting only the field
    /// that was named leaves every other entry — including the ready time — as
    /// the helper left it, and clears the message.
    func testCorrectingTheNamedFieldPreservesEveryOtherEntry() {
        let orderNumber = "70154321"
        let readyTime = FulfillmentReadyTime.thirtyMinutes

        let rejected = FulfillmentFormValidator.validate(
            fulfillerEmail: "helper.example.edu",
            orderNumber: orderNumber
        )
        XCTAssertEqual(rejected.map(\.field), [.fulfillerEmail])

        let corrected = FulfillmentFormValidator.validate(
            fulfillerEmail: "helper@example.edu",
            orderNumber: orderNumber
        )
        XCTAssertTrue(corrected.isEmpty)
        XCTAssertEqual(readyTime.etaValue, "30 minutes")
        XCTAssertTrue(FulfillRequestView.requiredFieldsArePresent(
            fulfillerEmail: "helper@example.edu",
            orderNumber: orderNumber,
            eta: readyTime.etaValue
        ))
    }

    /// The generic message is the fallback, never the first answer, and the
    /// sentence that made a formatting mistake look like a system failure is
    /// gone from the flow entirely.
    func testGenericFallbackIsReservedAndTheOldBlanketSentenceIsRetired() {
        XCTAssertEqual(
            FulfillmentPresentationError.invalidDetails.message,
            "We couldn’t save these details. Check the highlighted fields and try again. Don’t place another Grubhub order."
        )
        // The locked safety sentence still applies to this state.
        XCTAssertTrue(
            FulfillmentPresentationError.invalidDetails.message.contains(Self.safetySentence)
        )

        let everyFulfillmentFlowString = [
            FulfillmentPresentationError.invalidDetails.message,
            FulfillmentPresentationError.rateLimited.message,
            FulfillmentPresentationError.temporarilyUnavailable.message,
            FulfillmentPresentationError.couldNotRecord.message,
            FulfillmentFormValidator.emptyEmailMessage,
            FulfillmentFormValidator.invalidEmailMessage,
            FulfillmentFormValidator.emptyOrderNumberMessage,
            FulfillmentFormValidator.nonNumericOrderNumberMessage,
            FulfillmentFormValidator.longOrderNumberMessage,
            FulfillRequestView.completedOrderNotice,
            FulfillRequestView.helperEmailNotice,
            FulfillRequestView.orderNumberNotice,
            FulfillRequestView.readyTimeQuestion,
            FulfillRequestView.submitTitle,
            FulfillRequestView.ambiguousCheckingDetail,
            FulfillRequestView.ambiguousUnresolvedDetail,
            FulfillRequestView.confirmationDetail(for: .notificationSent),
            FulfillRequestView.confirmationDetail(for: .notificationFailed),
            FulfillRequestView.confirmationDetail(for: .emailStatusUnknown)
        ]
        for copy in everyFulfillmentFlowString {
            XCTAssertFalse(
                copy.localizedCaseInsensitiveContains("Something here wasn’t accepted"),
                copy
            )
        }

        // Each field message names its own field's rule rather than deferring.
        for message in [
            FulfillmentFormValidator.emptyEmailMessage,
            FulfillmentFormValidator.invalidEmailMessage,
            FulfillmentFormValidator.emptyOrderNumberMessage,
            FulfillmentFormValidator.nonNumericOrderNumberMessage,
            FulfillmentFormValidator.longOrderNumberMessage
        ] {
            XCTAssertFalse(
                message.localizedCaseInsensitiveContains("highlighted fields"),
                message
            )
        }
    }

    /// The contract is digits-only, but the wire type is still a string. A
    /// leading-zero value proves both halves at once: it survives to the JSON
    /// unchanged, and it is quoted rather than emitted as a number.
    func testOrderNumberIsSentAsAStringWithLeadingZeroesIntact() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(
            .response(data: fulfillmentResponse(notificationStatus: "sent"))
        )

        try await store.fulfill(
            requestID: requestID,
            fulfillerEmail: "helper@example.edu",
            orderNumber: "00070154321",
            eta: FulfillmentReadyTime.asap.etaValue,
            contactMessage: nil
        )

        let sent = try XCTUnwrap(
            ClaimFlowURLProtocol.capturedRequests.first { $0.path.hasSuffix("/fulfill") }
        )
        let body = try XCTUnwrap(sent.bodyObject)
        let fulfillment = try XCTUnwrap(body["fulfillment"] as? [String: Any])

        // Decoded as a String, not an NSNumber, and byte-identical to the entry.
        XCTAssertEqual(fulfillment["orderNumber"] as? String, "00070154321")
        XCTAssertNil(fulfillment["orderNumber"] as? Int)
        XCTAssertNil(fulfillment["orderNumber"] as? Double)

        // And quoted on the wire, so no consumer can re-read it as a number.
        let rawJSON = try XCTUnwrap(String(data: try XCTUnwrap(sent.body), encoding: .utf8))
        XCTAssertTrue(rawJSON.contains("\"orderNumber\":\"00070154321\""), rawJSON)

        // The structure itself is untouched by the format change.
        XCTAssertEqual(Set(body.keys), ["claimToken", "fulfillment"])
        XCTAssertEqual(Set(fulfillment.keys), ["fulfillerEmail", "orderNumber", "eta"])
    }

    /// A non-numeric order number is refused locally, so a helper who has
    /// already paid for a real Grubhub order never spends a round trip on it.
    func testNonNumericOrderNumberSendsNoFulfillmentPost() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)

        for rejected in ["7015-4321", "ORDER123", String(repeating: "7", count: 51)] {
            XCTAssertFalse(
                FulfillmentFormValidator.validate(
                    fulfillerEmail: "helper@example.edu",
                    orderNumber: rejected
                ).isEmpty,
                rejected
            )
        }

        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths,
            ["/api/request/\(requestID)/claim"]
        )
        XCTAssertFalse(ClaimFlowURLProtocol.capturedPaths.contains { $0.hasSuffix("/fulfill") })

        // The reservation is untouched, so the corrected value can still be sent.
        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertNil(store.fulfillError)
    }

    /// A public request value for navigation-path assertions. Route identity is
    /// what is under test, so the rest only has to be stable.
    private func foodRequest(id: String) -> FoodRequest {
        FoodRequest(
            id: id,
            diningSpot: DiningSpot(name: "Crave NYU", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            windowStart: nil,
            windowEnd: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 3_600),
            status: .open
        )
    }

    private func makeStore() -> RequestStore {
        RequestStore(service: makeService())
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaimFlowURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestService(client: client)
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func listResponse(_ requestObjects: [String]) -> Data {
        Data(#"{"requests":[\#(requestObjects.joined(separator: ","))]}"#.utf8)
    }

    private func errorResponse(code: String, message: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)","fields":null}}"#.utf8)
    }

    private func claimResponse(
        pickupName: String = "Taylor",
        claimToken: String = "claim-token",
        claimExpiresAt: Date = Date().addingTimeInterval(15 * 60),
        requestExpiresAt: Date = Date().addingTimeInterval(5 * 60 * 60),
        responseRequestID: String? = nil,
        responseStatus: String = "claimed"
    ) -> Data {
        Data("""
        {
          "request": \(requestObject(
            id: responseRequestID ?? requestID,
            status: responseStatus,
            expiresAt: iso8601String(requestExpiresAt)
          )),
          "claim": {
            "pickupName": "\(pickupName)",
            "claimToken": "\(claimToken)",
            "claimExpiresAt": "\(iso8601String(claimExpiresAt))"
          }
        }
        """.utf8)
    }

    private func extensionResponse(claimExpiresAt: Date, claimExtendedAt: Date) -> Data {
        Data("""
        {
          "claim": {
            "claimExpiresAt": "\(iso8601String(claimExpiresAt))",
            "claimExtendedAt": "\(iso8601String(claimExtendedAt))"
          }
        }
        """.utf8)
    }

    private func fulfillmentResponse(
        notificationStatus: String,
        responseRequestID: String? = nil,
        responseStatus: String = "placed"
    ) -> Data {
        Data("""
        {
          "request": \(requestObject(
            id: responseRequestID ?? requestID,
            status: responseStatus,
            expiresAt: iso8601String(Date().addingTimeInterval(5 * 60 * 60))
          )),
          "notification": { "status": "\(notificationStatus)" }
        }
        """.utf8)
    }

    private func detailResponse(status: String, responseRequestID: String? = nil) -> Data {
        Data("""
        {
          "request": \(requestObject(
            id: responseRequestID ?? requestID,
            status: status,
            expiresAt: iso8601String(Date().addingTimeInterval(5 * 60 * 60))
          ))
        }
        """.utf8)
    }

    private func requestObject(
        id: String,
        vendor: String = "Crave NYU",
        food: String = "Rice bowl",
        pickupWindowText: String = "ASAP",
        status: String = "open",
        createdAt: String = "2026-07-20T18:30:00.000Z",
        expiresAt: String = "2026-07-20T23:30:00.000Z"
    ) -> String {
        """
        {
          "id": "\(id)",
          "vendor": "\(vendor)",
          "food": "\(food)",
          "pickupWindowText": "\(pickupWindowText)",
          "windowStart": null,
          "windowEnd": null,
          "status": "\(status)",
          "createdAt": "\(createdAt)",
          "expiresAt": "\(expiresAt)"
        }
        """
    }

    private func waitUntil(
        timeoutIterations: Int = 200,
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
}
