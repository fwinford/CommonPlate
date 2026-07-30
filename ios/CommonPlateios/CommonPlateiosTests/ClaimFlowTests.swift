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
        } catch RequestServiceError.operationInProgress {
            // Expected: refused before any request is built.
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
        } catch RequestServiceError.operationInProgress {
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

        // A duplicate attempt is still refused by the store, with copy that
        // explains itself rather than a silently dead control.
        do {
            try await store.claim(requestID: requestB)
            XCTFail("The store mutex must still refuse a concurrent claim")
        } catch {
            XCTAssertEqual(ClaimPresentationError.map(error), .operationInProgress)
        }
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.count, 1)

        claimGate.open()
        try await claimA.value

        XCTAssertFalse(store.isClaiming(requestID: requestID))
        XCTAssertFalse(store.isClaiming(requestID: requestB))
    }

    // MARK: - Notice presentation

    /// Active Requests arms the alert on appearance, not the moment the store
    /// publishes. A notice raised while a detail screen is still up waits on
    /// the store and is presented once the list is visible.
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

        // The list becomes visible: `onAppear` arms the alert with notice A.
        presented = ActiveRequestsView.noticeToPresent(
            presented: presented,
            storeNotice: store.claimUnavailableNotice
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
