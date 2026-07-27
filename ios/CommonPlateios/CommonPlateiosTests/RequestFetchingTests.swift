import Foundation
import XCTest
@testable import CommonPlateios

final class RequestFetchingURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data
        let errorCode: URLError.Code?
        let delay: TimeInterval

        static func response(
            statusCode: Int = 200,
            data: Data,
            delay: TimeInterval = 0
        ) -> Stub {
            Stub(statusCode: statusCode, data: data, errorCode: nil, delay: delay)
        }

        static func failure(
            _ errorCode: URLError.Code,
            delay: TimeInterval = 0
        ) -> Stub {
            Stub(statusCode: 0, data: Data(), errorCode: errorCode, delay: delay)
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [Stub] = []

    static func enqueue(_ stub: Stub) {
        lock.lock()
        stubs.append(stub)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        stubs.removeAll()
        lock.unlock()
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

        if stub.delay > 0 {
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
