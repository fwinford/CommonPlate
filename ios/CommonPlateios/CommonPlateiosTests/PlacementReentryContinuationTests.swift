//
//  PlacementReentryContinuationTests.swift
//  CommonPlateiosTests
//
// Focused coverage for W3-H2 fulfillment re-entry: a helper who placed an
// external order but lost the confirming response before acknowledging it
// (Got It) must recover truthful already-placed presentation on relaunch,
// from `RequestStore.continueActiveReservationIfNeeded()` reading the same
// `GET /api/participant/active-reservation` W3-H1 continuation already uses.
// This must never recreate reservation authority and must never reopen a
// path to Place Order for the same request.
import Foundation
import XCTest
@testable import CommonPlateios

/// Its own transport double, matching the one-file-one-double convention
/// (`ClaimFlowURLProtocol`, `ReservationContinuationURLProtocol`).
final class PlacementReentryURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data

        static func response(statusCode: Int = 200, data: Data) -> Stub {
            Stub(statusCode: statusCode, data: data)
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [Stub] = []
    private nonisolated(unsafe) static var capturedPaths: [String] = []

    static func enqueue(_ stub: Stub) {
        lock.lock()
        stubs.append(stub)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        stubs.removeAll()
        capturedPaths.removeAll()
        lock.unlock()
    }

    static var requestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return capturedPaths
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
        Self.capturedPaths.append(request.url?.path ?? "")
        Self.lock.unlock()

        guard let stub = Self.dequeue(),
              let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.statusCode,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class PlacementReentryContinuationTests: XCTestCase {
    override func tearDown() {
        PlacementReentryURLProtocol.reset()
        super.tearDown()
    }

    func testRestoresGotItPresentationWithASettledSentNotificationOutcome() async throws {
        let store = makeStore()
        PlacementReentryURLProtocol.enqueue(.response(
            data: placementResponse(notificationStatus: "sent")
        ))

        let outcome = try await store.continueActiveReservationIfNeeded()

        guard case .none = outcome else {
            return XCTFail("placement re-entry never restores reservation authority")
        }
        XCTAssertNil(store.activeClaim, "must never recreate reservation authority for the request")
        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertEqual(confirmation.requestID, "placed-reentry-target")
        XCTAssertEqual(confirmation.vendor, "Crave NYU")
        XCTAssertEqual(confirmation.foodDescription, "Rice bowl")
        XCTAssertEqual(confirmation.kind, .notificationSent)
        XCTAssertEqual(store.confirmedFulfillmentOutcome?.notificationStatus, .sent)
    }

    func testRestoresGotItPresentationWithASettledFailedNotificationOutcome() async throws {
        let store = makeStore()
        PlacementReentryURLProtocol.enqueue(.response(
            data: placementResponse(notificationStatus: "failed")
        ))

        _ = try await store.continueActiveReservationIfNeeded()

        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertEqual(confirmation.kind, .notificationFailed)
        XCTAssertEqual(store.confirmedFulfillmentOutcome?.notificationStatus, .failed)
    }

    /// The outcome never settled server-side (e.g. the process ended before
    /// recording it). This must read as unknown, never guessed as sent.
    func testRestoresGotItPresentationWithAnUnknownNotificationOutcomeRatherThanGuessing() async throws {
        let store = makeStore()
        PlacementReentryURLProtocol.enqueue(.response(
            data: placementResponse(notificationStatus: nil)
        ))

        _ = try await store.continueActiveReservationIfNeeded()

        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertEqual(confirmation.kind, .emailStatusUnknown)
        XCTAssertNil(store.confirmedFulfillmentOutcome)
    }

    /// Neither an active reservation nor a still-existing placement: ordinary
    /// W3-H1 absence, unaffected by the W3-H2 extension.
    func testNoReservationAndNoPlacementRestoresNothing() async throws {
        let store = makeStore()
        PlacementReentryURLProtocol.enqueue(.response(
            data: Data(#"{"reservation":null,"placement":null}"#.utf8)
        ))

        let outcome = try await store.continueActiveReservationIfNeeded()

        guard case .none = outcome else {
            return XCTFail("expected authoritative absence")
        }
        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentConfirmation)
    }

    /// A restored Got It confirmation blocks a new claim exactly like an
    /// in-process one already does (`RequestStore.claim`'s existing
    /// unacknowledged-placement guard) — proving the restoration actually
    /// feeds the same gate rather than being purely cosmetic.
    func testARestoredConfirmationBlocksStartingANewClaimUntilAcknowledged() async throws {
        let store = makeStore()
        PlacementReentryURLProtocol.enqueue(.response(
            data: placementResponse(notificationStatus: "sent")
        ))
        _ = try await store.continueActiveReservationIfNeeded()
        XCTAssertNotNil(store.fulfillmentConfirmation)

        do {
            try await store.claim(requestID: "some-other-request")
            XCTFail("an unacknowledged restored placement must block a new claim")
        } catch RequestServiceError.unacknowledgedPlacement {
            // Expected.
        }
    }

    /// A second continuation call (e.g. a second launch-time call site) must
    /// never clobber a confirmation this process already restored or
    /// produced — only acknowledgement may clear it.
    func testASecondContinuationCallNeverOverwritesAnAlreadyRestoredConfirmation() async throws {
        let store = makeStore()
        PlacementReentryURLProtocol.enqueue(.response(
            data: placementResponse(requestID: "first-placement", notificationStatus: "sent")
        ))
        _ = try await store.continueActiveReservationIfNeeded()
        let firstConfirmation = try XCTUnwrap(store.fulfillmentConfirmation)

        PlacementReentryURLProtocol.enqueue(.response(
            data: placementResponse(requestID: "second-placement", notificationStatus: "failed")
        ))
        _ = try await store.continueActiveReservationIfNeeded()

        XCTAssertEqual(store.fulfillmentConfirmation?.id, firstConfirmation.id)
        XCTAssertEqual(store.fulfillmentConfirmation?.requestID, "first-placement")
    }

    /// An active reservation always takes priority; placement re-entry must
    /// never run or restore anything alongside it.
    func testAnActiveReservationTakesPriorityOverAnyPlacementField() async throws {
        let store = makeStore()
        let claimExpiresAt = Date().addingTimeInterval(9 * 60)
        PlacementReentryURLProtocol.enqueue(.response(
            data: activeReservationResponse(claimExpiresAt: claimExpiresAt)
        ))

        let outcome = try await store.continueActiveReservationIfNeeded()

        guard case .active(let claim) = outcome else {
            return XCTFail("expected the active reservation to be restored")
        }
        XCTAssertEqual(claim.requestID, "active-reservation-target")
        XCTAssertNil(store.fulfillmentConfirmation)
    }

    // MARK: - Helpers

    private func makeStore() -> RequestStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlacementReentryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestStore(
            service: RequestService(client: client),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { "64c0000000000000000000a1.1.credential" },
            participantAuthorityRejected: {}
        )
    }

    private func placementResponse(
        requestID: String = "placed-reentry-target",
        notificationStatus: String?
    ) -> Data {
        let notificationField = notificationStatus.map { #"{"status":"\#($0)"}"# } ?? "null"
        return Data("""
        {
          "reservation": null,
          "placement": {
            "request": {
              "id": "\(requestID)",
              "vendor": "Crave NYU",
              "food": "Rice bowl",
              "pickupWindowText": "ASAP",
              "mealSwipes": 2,
              "windowStart": null,
              "windowEnd": null,
              "status": "placed",
              "createdAt": "2026-08-10T15:00:00.000Z",
              "expiresAt": "2026-08-10T20:00:00.000Z"
            },
            "notification": \(notificationField)
          }
        }
        """.utf8)
    }

    private func activeReservationResponse(claimExpiresAt: Date) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Data("""
        {
          "reservation": {
            "request": {
              "id": "active-reservation-target",
              "vendor": "Crave NYU",
              "food": "Rice bowl",
              "pickupWindowText": "ASAP",
              "mealSwipes": 2,
              "windowStart": null,
              "windowEnd": null,
              "status": "claimed",
              "createdAt": "2026-08-10T15:00:00.000Z",
              "expiresAt": "2026-08-10T20:00:00.000Z"
            },
            "pickupName": "Reentry Pickup",
            "claimExpiresAt": "\(formatter.string(from: claimExpiresAt))",
            "claimExtendedAt": null
          }
        }
        """.utf8)
    }
}
