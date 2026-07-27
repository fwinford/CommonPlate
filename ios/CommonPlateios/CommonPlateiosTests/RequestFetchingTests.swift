import Foundation
import XCTest
@testable import CommonPlateios

final class RequestFetchingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (() -> Void)?
    private var isOpen = false

    var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completion != nil
    }

    func wait(_ completion: @escaping () -> Void) {
        lock.lock()
        if isOpen {
            lock.unlock()
            completion()
        } else {
            self.completion = completion
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let completion = completion
        self.completion = nil
        lock.unlock()
        completion?()
    }
}

final class RequestFetchingURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data
        let errorCode: URLError.Code?
        let delay: TimeInterval
        let gate: RequestFetchingGate?

        static func response(
            statusCode: Int = 200,
            data: Data,
            delay: TimeInterval = 0,
            gate: RequestFetchingGate? = nil
        ) -> Stub {
            Stub(
                statusCode: statusCode,
                data: data,
                errorCode: nil,
                delay: delay,
                gate: gate
            )
        }

        static func failure(
            _ errorCode: URLError.Code,
            delay: TimeInterval = 0,
            gate: RequestFetchingGate? = nil
        ) -> Stub {
            Stub(
                statusCode: 0,
                data: Data(),
                errorCode: errorCode,
                delay: delay,
                gate: gate
            )
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [Stub] = []
    private nonisolated(unsafe) static var requestedPaths: [String] = []

    static func enqueue(_ stub: Stub) {
        lock.lock()
        stubs.append(stub)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        stubs.removeAll()
        requestedPaths.removeAll()
        lock.unlock()
    }

    static var capturedRequestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestedPaths
    }

    private static func dequeue() -> Stub? {
        lock.lock()
        defer { lock.unlock() }
        guard !stubs.isEmpty else { return nil }
        return stubs.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.requestedPaths.append(request.url?.path ?? "")
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
        } else if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(
                deadline: .now() + stub.delay,
                execute: completeRequest
            )
        } else {
            completeRequest()
        }
    }

    override func stopLoading() {}
}

@MainActor
final class RequestFetchingTests: XCTestCase {
    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    func testFinalizedListWrapperDecodesAndMapsPublicRequest() async throws {
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(
                id: "server-request-id",
                vendor: "Palladium",
                food: "Chicken bowl",
                pickupWindowText: "Around 7:00 PM",
                windowStart: "2026-07-20T19:00:00.000Z",
                windowEnd: "2026-07-20T19:30:00.000Z",
                status: "requested",
                createdAt: "2026-07-20T18:30:00.123Z",
                expiresAt: "2026-07-20T23:30:00.000Z"
            )
        ])))

        let requests = try await makeService().fetchActiveRequests()
        let request = try XCTUnwrap(requests.first)

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.id, "server-request-id")
        XCTAssertEqual(request.diningSpot.name, "Palladium")
        XCTAssertNil(request.diningSpot.address)
        XCTAssertEqual(request.foodDescription, "Chicken bowl")
        XCTAssertEqual(request.pickupWindowText, "Around 7:00 PM")
        XCTAssertEqual(request.windowStart, try iso8601Date("2026-07-20T19:00:00.000Z"))
        XCTAssertEqual(request.windowEnd, try iso8601Date("2026-07-20T19:30:00.000Z"))
        XCTAssertEqual(request.status, .open)
        XCTAssertEqual(request.createdAt, try iso8601Date("2026-07-20T18:30:00.123Z"))
        XCTAssertEqual(request.expiresAt, try iso8601Date("2026-07-20T23:30:00.000Z"))
    }

    func testInitialFetchSuccessOwnsCollectionAndLaterSuccessReplacesIt() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "first")
        ])))

        await store.fetchRequests()

        XCTAssertTrue(store.hasSuccessfullyFetchedRequests)
        XCTAssertEqual(store.requests.map(\.id), ["first"])
        XCTAssertNil(store.initialFetchError)

        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "replacement-a"),
            requestObject(id: "replacement-b")
        ])))

        await store.fetchRequests()

        XCTAssertEqual(store.requests.map(\.id), ["replacement-a", "replacement-b"])
        XCTAssertNil(store.refreshError)
    }

    func testSuccessfulEmptyInitialResponseIsDistinctFromInitialFailure() async {
        let emptyStore = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([])))

        await emptyStore.fetchRequests()

        XCTAssertTrue(emptyStore.hasSuccessfullyFetchedRequests)
        XCTAssertTrue(emptyStore.requests.isEmpty)
        XCTAssertNil(emptyStore.initialFetchError)

        let failedStore = makeStore()
        RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))

        await failedStore.fetchRequests()

        XCTAssertFalse(failedStore.hasSuccessfullyFetchedRequests)
        XCTAssertTrue(failedStore.requests.isEmpty)
        XCTAssertNotNil(failedStore.initialFetchError)
        XCTAssertNil(failedStore.refreshError)
    }

    func testRetryAfterInitialFailureUsesTheSameFetchPath() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))

        await store.fetchRequests()

        XCTAssertFalse(store.hasSuccessfullyFetchedRequests)
        XCTAssertNotNil(store.initialFetchError)

        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "loaded-on-retry")
        ])))

        await store.fetchRequests()

        XCTAssertTrue(store.hasSuccessfullyFetchedRequests)
        XCTAssertEqual(store.requests.map(\.id), ["loaded-on-retry"])
        XCTAssertNil(store.initialFetchError)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/requests", "/api/requests"]
        )
    }

    /// An initial fetch whose snapshot is invalidated by a confirmed mutation
    /// publishes no error, so `initialFetchError` alone cannot tell the view
    /// whether to offer recovery. The store must still report that a fetch was
    /// attempted and has finished, which is what `ActiveRequestsView` uses to
    /// show "Try Again" instead of an endless `ProgressView`.
    func testInitialFetchInvalidatedByConfirmedMutationEndsInRetryableState() async throws {
        let store = makeStore()
        XCTAssertFalse(store.hasAttemptedRequestFetch)

        let initialFetchGate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: "never-applied")]),
            gate: initialFetchGate
        ))
        let initialFetch = Task {
            await store.fetchRequests()
        }
        await waitUntil { initialFetchGate.isWaiting }

        XCTAssertTrue(store.hasAttemptedRequestFetch)
        XCTAssertTrue(store.isLoadingInitialRequests)

        RequestFetchingURLProtocol.enqueue(.response(data: claimResponse(
            requestObject: requestObject(id: "meal-a", status: "claimed")
        )))
        try await store.claim(requestID: "meal-a")

        initialFetchGate.open()
        await initialFetch.value

        // The confirmed mutation still owns the collection.
        XCTAssertEqual(store.requests.map(\.id), ["meal-a"])
        XCTAssertEqual(store.requests.first?.status, .claimed)

        // Loading ended, no successful fetch was recorded, and no error exists...
        XCTAssertFalse(store.isFetching)
        XCTAssertFalse(store.isLoadingInitialRequests)
        XCTAssertFalse(store.isRefreshingRequests)
        XCTAssertFalse(store.hasSuccessfullyFetchedRequests)
        XCTAssertNil(store.initialFetchError)
        XCTAssertNil(store.refreshError)

        // ...but the attempt is recorded, so recovery is offered.
        XCTAssertTrue(store.hasAttemptedRequestFetch)
    }

    /// Same terminal shape, reached by cancelling the initial fetch instead.
    func testCancelledInitialFetchEndsInRetryableState() async {
        let store = makeStore()
        let cancelledFetchGate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: "never-applied")]),
            gate: cancelledFetchGate
        ))

        let initialFetch = Task {
            await store.fetchRequests()
        }
        await waitUntil { cancelledFetchGate.isWaiting }

        initialFetch.cancel()
        cancelledFetchGate.open()
        await initialFetch.value

        XCTAssertFalse(store.isFetching)
        XCTAssertFalse(store.hasSuccessfullyFetchedRequests)
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertNil(store.initialFetchError)
        XCTAssertTrue(store.hasAttemptedRequestFetch)
    }

    func testRefreshFailurePreservesLoadedRequestsWhileRefreshingAndAfterFailure() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "still-visible")
        ])))
        await store.fetchRequests()

        RequestFetchingURLProtocol.enqueue(
            .failure(.timedOut, delay: 0.15)
        )
        let refreshTask = Task {
            await store.fetchRequests()
        }

        await waitUntil { store.isRefreshingRequests }

        XCTAssertFalse(store.isLoadingInitialRequests)
        XCTAssertTrue(store.isRefreshingRequests)
        XCTAssertEqual(store.requests.map(\.id), ["still-visible"])

        await refreshTask.value

        XCTAssertTrue(store.hasSuccessfullyFetchedRequests)
        XCTAssertFalse(store.isRefreshingRequests)
        XCTAssertEqual(store.requests.map(\.id), ["still-visible"])
        XCTAssertNotNil(store.refreshError)
        XCTAssertNil(store.initialFetchError)
    }

    func testNewestFetchWinsWhenOlderFetchCompletesLast() async {
        let store = makeStore()
        let olderFetchGate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: "older")]),
            gate: olderFetchGate
        ))

        let olderFetch = Task {
            await store.fetchRequests()
        }
        await waitUntil { olderFetchGate.isWaiting }

        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "newer")
        ])))
        let newerFetch = Task {
            await store.fetchRequests()
        }
        await newerFetch.value

        XCTAssertEqual(store.requests.map(\.id), ["newer"])
        XCTAssertFalse(store.isLoadingInitialRequests)

        olderFetchGate.open()
        await olderFetch.value

        XCTAssertEqual(store.requests.map(\.id), ["newer"])
        XCTAssertTrue(store.hasSuccessfullyFetchedRequests)
        XCTAssertFalse(store.isLoadingInitialRequests)
        XCTAssertFalse(store.isRefreshingRequests)
    }

    func testConfirmedClaimInvalidatesOlderFetchSnapshot() async throws {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "meal-a")
        ])))
        await store.fetchRequests()

        let olderRefreshGate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: "meal-a", status: "requested")]),
            gate: olderRefreshGate
        ))
        let olderRefresh = Task {
            await store.fetchRequests()
        }
        await waitUntil { olderRefreshGate.isWaiting }

        RequestFetchingURLProtocol.enqueue(.response(data: claimResponse(
            requestObject: requestObject(id: "meal-a", status: "claimed")
        )))
        try await store.claim(requestID: "meal-a")

        XCTAssertEqual(store.requests.first?.status, .claimed)
        XCTAssertTrue(store.isRefreshingRequests)

        olderRefreshGate.open()
        await olderRefresh.value

        XCTAssertEqual(store.requests.map(\.id), ["meal-a"])
        XCTAssertEqual(store.requests.first?.status, .claimed)
        XCTAssertFalse(store.isRefreshingRequests)
        XCTAssertNil(store.refreshError)
    }

    func testFetchStartedAfterConfirmedMutationCanReplaceCollection() async throws {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "meal-a")
        ])))
        await store.fetchRequests()

        RequestFetchingURLProtocol.enqueue(.response(data: claimResponse(
            requestObject: requestObject(id: "meal-a", status: "claimed")
        )))
        try await store.claim(requestID: "meal-a")
        XCTAssertEqual(store.requests.first?.status, .claimed)

        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "currently-available")
        ])))
        await store.fetchRequests()

        XCTAssertEqual(store.requests.map(\.id), ["currently-available"])
        XCTAssertEqual(store.requests.first?.status, .open)
        XCTAssertNil(store.refreshError)
    }

    func testConfirmedMutationMakesOlderFetchFailureSilentAndCleansRefreshState() async throws {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "meal-a")
        ])))
        await store.fetchRequests()

        let olderRefreshGate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.failure(
            .timedOut,
            gate: olderRefreshGate
        ))
        let olderRefresh = Task {
            await store.fetchRequests()
        }
        await waitUntil { olderRefreshGate.isWaiting }

        RequestFetchingURLProtocol.enqueue(.response(data: claimResponse(
            requestObject: requestObject(id: "meal-a", status: "claimed")
        )))
        try await store.claim(requestID: "meal-a")

        XCTAssertEqual(store.requests.first?.status, .claimed)
        XCTAssertTrue(store.isRefreshingRequests)

        olderRefreshGate.open()
        await olderRefresh.value

        XCTAssertEqual(store.requests.first?.status, .claimed)
        XCTAssertNil(store.refreshError)
        XCTAssertFalse(store.isLoadingInitialRequests)
        XCTAssertFalse(store.isRefreshingRequests)
    }

    func testIgnoredStaleResponsesPreserveNewerErrorAndDoNotPublishStaleError() async {
        let storeWithNewerError = makeStore()
        let staleSuccessGate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: "stale-success")]),
            gate: staleSuccessGate
        ))
        let staleSuccess = Task {
            await storeWithNewerError.fetchRequests()
        }
        await waitUntil { staleSuccessGate.isWaiting }

        RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await storeWithNewerError.fetchRequests()

        XCTAssertNotNil(storeWithNewerError.initialFetchError)
        XCTAssertFalse(storeWithNewerError.isLoadingInitialRequests)

        staleSuccessGate.open()
        await staleSuccess.value

        XCTAssertNotNil(storeWithNewerError.initialFetchError)
        XCTAssertFalse(storeWithNewerError.hasSuccessfullyFetchedRequests)
        XCTAssertTrue(storeWithNewerError.requests.isEmpty)
        XCTAssertFalse(storeWithNewerError.isLoadingInitialRequests)

        let storeWithNewerSuccess = makeStore()
        let staleFailureGate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.failure(
            .timedOut,
            gate: staleFailureGate
        ))
        let staleFailure = Task {
            await storeWithNewerSuccess.fetchRequests()
        }
        await waitUntil { staleFailureGate.isWaiting }

        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "newer-success")
        ])))
        await storeWithNewerSuccess.fetchRequests()

        staleFailureGate.open()
        await staleFailure.value

        XCTAssertEqual(storeWithNewerSuccess.requests.map(\.id), ["newer-success"])
        XCTAssertNil(storeWithNewerSuccess.initialFetchError)
        XCTAssertNil(storeWithNewerSuccess.refreshError)
        XCTAssertFalse(storeWithNewerSuccess.isLoadingInitialRequests)
        XCTAssertFalse(storeWithNewerSuccess.isRefreshingRequests)
    }

    private func makeStore() -> RequestStore {
        RequestStore(service: makeService())
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

    private func listResponse(_ requestObjects: [String]) -> Data {
        Data(#"{"requests":[\#(requestObjects.joined(separator: ","))]}"#.utf8)
    }

    private func claimResponse(requestObject: String) -> Data {
        Data("""
        {
          "request": \(requestObject),
          "pickupName": "Taylor",
          "claimToken": "claim-token",
          "claimExpiresAt": "2026-07-20T19:15:00.000Z"
        }
        """.utf8)
    }

    private func requestObject(
        id: String,
        vendor: String = "Crave NYU",
        food: String = "Rice bowl",
        pickupWindowText: String = "ASAP",
        windowStart: String? = nil,
        windowEnd: String? = nil,
        status: String = "requested",
        createdAt: String = "2026-07-20T18:30:00.000Z",
        expiresAt: String = "2026-07-20T23:30:00.000Z"
    ) -> String {
        let windowStartJSON = windowStart.map { "\"\($0)\"" } ?? "null"
        let windowEndJSON = windowEnd.map { "\"\($0)\"" } ?? "null"

        return """
        {
          "id": "\(id)",
          "vendor": "\(vendor)",
          "food": "\(food)",
          "pickupWindowText": "\(pickupWindowText)",
          "windowStart": \(windowStartJSON),
          "windowEnd": \(windowEndJSON),
          "status": "\(status)",
          "createdAt": "\(createdAt)",
          "expiresAt": "\(expiresAt)"
        }
        """
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
}
