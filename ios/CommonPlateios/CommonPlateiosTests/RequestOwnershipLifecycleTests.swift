//
//  RequestOwnershipLifecycleTests.swift
//  CommonPlateiosTests
//
// Focused W4-H2 coverage for the participant-authority *lifecycle* around
// caller-relative request ownership — the boundary `RequestOwnershipTests`
// (wire decoding) does not reach.
//
// Caller-relative ownership is only ever true relative to one exact
// participant authority. These cases prove that a result produced under one
// authority can never become ownership truth for another, that ownership with
// no current-authority evidence behind it fails closed instead of reading as
// an actionable "not own", and that a request this app just created under a
// still-current authenticated authority is recognised as the caller's own
// immediately.
//
// Behavioural throughout: every case drives the real
// `RequestStore`/`RequestService` path over a stubbed transport, rather than
// asserting on source text.
import Foundation
import XCTest
@testable import CommonPlateios

/// A participant-authority provider whose value changes *between* the point a
/// store operation captures it and the point that operation re-checks it —
/// which is exactly what a successful verification, Change Email, or Remove
/// Email does while a request is in flight.
private final class ScriptedAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?]
    private var index = 0

    init(_ values: [String?]) {
        self.values = values
    }

    /// Returns each scripted value in turn, then repeats the last one — so a
    /// single change stays changed for every later read.
    func next() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}

@MainActor
final class RequestOwnershipLifecycleTests: XCTestCase {
    private let authorityA = "64c0000000000000000000a1.1.credential"
    private let authorityB = "64c0000000000000000000b2.1.credential"

    override func tearDown() {
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - List authority races

    /// Anonymous fetch starts → verification succeeds → the anonymous
    /// response lands. The anonymous result knows nothing about the verified
    /// participant, so it must not establish helper actionability for them.
    func testAnonymousListResultLandingAfterVerificationDoesNotEstablishOwnership() async {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: nil)
        ])))
        let store = makeStore(ScriptedAuthority([nil, authorityB]))

        await store.fetchRequests()

        let request = store.requests.first
        XCTAssertEqual(request?.ownership, .unresolved)
        XCTAssertFalse(request?.allowsHelperAction ?? true)
        XCTAssertFalse(request?.isOwnRequest ?? true)
    }

    /// Participant A fetch starts → Change Email to B succeeds → A's response
    /// lands carrying `isOwnRequest: true`. That is A's ownership, not B's.
    func testParticipantAListResultLandingAfterChangeEmailDoesNotBecomeBOwnership() async {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: true)
        ])))
        let store = makeStore(ScriptedAuthority([authorityA, authorityB]))

        await store.fetchRequests()

        XCTAssertEqual(store.requests.first?.ownership, .unresolved)
        XCTAssertFalse(store.requests.first?.isOwnRequest ?? true)
    }

    /// The mirror case: A saw a request as *not* own. That must not become
    /// permission for B to help, because B may well be its owner.
    func testParticipantANotOwnResultLandingAfterChangeEmailDoesNotAuthorizeB() async {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: nil)
        ])))
        let store = makeStore(ScriptedAuthority([authorityA, authorityB]))

        await store.fetchRequests()

        XCTAssertEqual(store.requests.first?.ownership, .unresolved)
        XCTAssertFalse(store.requests.first?.allowsHelperAction ?? true)
    }

    /// A stable authority is the ordinary case and must still resolve fully —
    /// the fence above must not degrade every normal fetch to `.unresolved`.
    func testStableAuthorityResolvesOwnershipNormally() async {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: true),
            requestObject(id: "b", isOwnRequest: false),
        ])))
        let store = makeStore(ScriptedAuthority([authorityA]))

        await store.fetchRequests()

        XCTAssertEqual(store.requests.first { $0.id == "a" }?.ownership, .own)
        XCTAssertEqual(store.requests.first { $0.id == "b" }?.ownership, .notOwn)
        XCTAssertTrue(store.requests.first { $0.id == "b" }?.allowsHelperAction ?? false)
    }

    /// The cached-collection window: A's collection is already resolved, then
    /// B becomes current. Before replacement truth arrives, the previously
    /// resolved ownership must stop being authoritative — while the public
    /// request data itself is preserved rather than blanking the board.
    func testCachedCollectionIsNotHelperActionableImmediatelyAfterAuthorityChange() async {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: true),
            requestObject(id: "b", isOwnRequest: nil),
        ])))
        // Reads 1-2 resolve the first fetch under A; read 3 onwards is B,
        // i.e. Change Email succeeded after that collection was established.
        let store = makeStore(ScriptedAuthority([authorityA, authorityA, authorityB]))
        await store.fetchRequests()
        XCTAssertEqual(store.requests.first { $0.id == "a" }?.ownership, .own)

        // B is current now, and B's reconciling reload cannot complete.
        ClaimFlowURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.reconcileOwnershipForCurrentAuthority()

        XCTAssertEqual(store.requests.map(\.id), ["a", "b"], "public request data is preserved")
        XCTAssertTrue(
            store.requests.allSatisfy { $0.ownership == .unresolved },
            "A-relative ownership must not survive as B's truth"
        )
        XCTAssertTrue(store.requests.allSatisfy { !$0.allowsHelperAction })
    }

    /// Once B's own read resolves, B-relative ownership applies normally.
    func testReconciliationEstablishesOwnershipForTheNewParticipant() async {
        let store = makeStore(ScriptedAuthority([authorityB]))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: false),
            requestObject(id: "b", isOwnRequest: true),
        ])))

        await store.reconcileOwnershipForCurrentAuthority()

        XCTAssertEqual(store.requests.first { $0.id == "a" }?.ownership, .notOwn)
        XCTAssertEqual(store.requests.first { $0.id == "b" }?.ownership, .own)
    }

    // MARK: - Post-create ingestion

    /// A create performed under a still-current authenticated authority is
    /// direct knowledge that the new request belongs to this participant —
    /// `POST /api/request` refuses an unverified caller and binds the request
    /// to exactly that principal. It must read as own immediately, without
    /// waiting for the next list fetch.
    func testCreatedRequestIsOwnImmediatelyAndNeverHelperActionable() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: createResponse(id: "new-1")))
        let store = makeStore(ScriptedAuthority([authorityA]))

        try await store.createRequest(payload())

        let created = try XCTUnwrap(store.requests.first { $0.id == "new-1" })
        XCTAssertEqual(created.ownership, .own)
        XCTAssertTrue(created.isOwnRequest)
        XCTAssertFalse(created.allowsHelperAction, "the requester can never help their own request")
    }

    /// If the authority changes while the create is in flight, A's conclusion
    /// is not applied as B's truth — it fails closed instead.
    func testCreatedRequestOwnershipIsUnresolvedWhenAuthorityChangedMidFlight() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: createResponse(id: "new-2")))
        // Read once when the create captures its authority, then changed by
        // the time the confirmed result is applied.
        let store = makeStore(ScriptedAuthority([authorityA, authorityB]))

        try await store.createRequest(payload())

        let created = try XCTUnwrap(store.requests.first { $0.id == "new-2" })
        XCTAssertEqual(created.ownership, .unresolved)
        XCTAssertFalse(created.isOwnRequest)
        XCTAssertFalse(created.allowsHelperAction)
    }

    // MARK: - D1 create reconciliation

    /// A recovered D1 create carries the same authenticated knowledge as a
    /// fresh one: this authority created this request. It must become own
    /// immediately, not sit at `.unresolved` until some later list fetch.
    func testReconciledCreateUnderCurrentAuthorityBecomesOwn() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        storage.save(pendingRecord(operationId: "recover-own"))
        ClaimFlowURLProtocol.enqueue(.response(data: createResponse(id: "recovered-1")))
        let store = makeStore(ScriptedAuthority([authorityA]), operationStorage: storage)

        let reconciled = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertTrue(reconciled)
        let request = try XCTUnwrap(store.requests.first { $0.id == "recovered-1" })
        XCTAssertEqual(request.ownership, .own)
        XCTAssertFalse(request.allowsHelperAction)
    }

    /// If the authority changed while reconciliation was in flight, A's
    /// conclusion is not B's. Ownership is never inferred from the request id.
    func testReconciledCreateAfterAuthorityChangeStaysUnresolved() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        storage.save(pendingRecord(operationId: "recover-changed"))
        ClaimFlowURLProtocol.enqueue(.response(data: createResponse(id: "recovered-2")))
        let store = makeStore(
            ScriptedAuthority([authorityA, authorityB]),
            operationStorage: storage
        )

        _ = await store.reconcilePendingCreateOperationIfNeeded()

        let request = try XCTUnwrap(store.requests.first { $0.id == "recovered-2" })
        XCTAssertEqual(request.ownership, .unresolved)
        XCTAssertFalse(request.allowsHelperAction)
    }

    // MARK: - Notification-driven detail

    /// The production notification path resolves through the real detail
    /// route, which now derives caller-relative ownership.
    func testNotificationDetailResolvesOwnershipForCurrentAuthority() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(id: "d1", isOwnRequest: true)))
        let store = makeStore(ScriptedAuthority([authorityA]))

        let resolution = try await store.resolveHelperNotificationRequest(id: "d1")

        guard case .available(let request) = resolution else {
            return XCTFail("expected an available resolution, got \(resolution)")
        }
        XCTAssertEqual(request.ownership, .own)
        XCTAssertFalse(request.allowsHelperAction)
    }

    /// A participant change during the detail read makes the returned
    /// ownership a conclusion about someone else.
    func testNotificationDetailOwnershipIsUnresolvedWhenAuthorityChangesMidFlight() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(id: "d2", isOwnRequest: nil)))
        let store = makeStore(ScriptedAuthority([authorityA, authorityB]))

        let resolution = try await store.resolveHelperNotificationRequest(id: "d2")

        guard case .available(let request) = resolution else {
            return XCTFail("expected an available resolution, got \(resolution)")
        }
        XCTAssertEqual(request.ownership, .unresolved)
        XCTAssertFalse(request.allowsHelperAction)
    }

    /// The detail route genuinely answers "not yours" for a non-owner, so a
    /// resolved detail read may expose helper behaviour subject to the other
    /// eligibility gates.
    func testNotificationDetailForNonOwnerResolvesNotOwn() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(id: "d3", isOwnRequest: false)))
        let store = makeStore(ScriptedAuthority([authorityA]))

        let resolution = try await store.resolveHelperNotificationRequest(id: "d3")

        guard case .available(let request) = resolution else {
            return XCTFail("expected an available resolution, got \(resolution)")
        }
        XCTAssertEqual(request.ownership, .notOwn)
        XCTAssertTrue(request.allowsHelperAction)
    }

    // MARK: - Response shapes that derive no ownership at all

    /// A claim response embeds a request, but that shape never carries
    /// caller-relative ownership. Absent metadata there must map to
    /// `.unresolved`, not to an actionable `.notOwn`.
    func testClaimEmbeddedRequestOwnershipIsUnresolved() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(id: "c1")))
        let service = makeService()

        let outcome = try await service.claimRequest(
            id: "c1",
            participantAuthority: authorityA
        )

        XCTAssertEqual(outcome.request.ownership, .unresolved)
    }

    // MARK: - Privacy

    /// No request-identity material may reach the domain model from any of
    /// these paths — the wire carries only the caller-relative boolean.
    func testOwnershipCarriesNoParticipantIdentityMaterial() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: true)
        ])))
        let store = makeStore(ScriptedAuthority([authorityA]))

        await store.fetchRequests()

        let mirror = Mirror(reflecting: try XCTUnwrap(store.requests.first))
        let fields = mirror.children.compactMap(\.label)
        XCTAssertFalse(fields.contains("requesterParticipantId"))
        XCTAssertFalse(fields.contains("participantId"))
        XCTAssertFalse(fields.contains("email"))
        XCTAssertEqual(store.requests.first?.ownership, .own)
    }

    // MARK: - Fixtures

    private func makeStore(
        _ authority: ScriptedAuthority,
        operationStorage: PendingRequestOperationStorage = InMemoryPendingRequestOperationStorage()
    ) -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { authority.next() },
            participantAuthorityRejected: {},
            operationStorage: operationStorage
        )
    }

    /// The durable D1 record, bound to participant A's identifier — the same
    /// principal `authorityA` resolves to.
    private func pendingRecord(operationId: String) -> PendingRequestOperationRecord {
        PendingRequestOperationRecord(
            operationId: operationId,
            participantIdentifier: "64c0000000000000000000a1",
            vendor: "Crave NYU",
            food: "Rice bowl",
            pickupName: "Alex",
            timing: .asap,
            windowStart: nil,
            mealSwipes: 2
        )
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

    private func payload() -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Crave NYU",
            food: "Rice bowl",
            pickupName: "Alex",
            timing: .asap,
            windowStart: nil,
            mealSwipes: 2
        )
    }

    private func listResponse(_ objects: [String]) -> Data {
        Data(#"{"requests":[\#(objects.joined(separator: ","))]}"#.utf8)
    }

    private func detailResponse(id: String, isOwnRequest: Bool?) -> Data {
        Data(#"{"request":\#(requestObject(id: id, isOwnRequest: isOwnRequest))}"#.utf8)
    }

    private func createResponse(id: String) -> Data {
        // The create response shape carries no `isOwnRequest`.
        Data(#"{"request":\#(requestObject(id: id, isOwnRequest: nil))}"#.utf8)
    }

    private func claimResponse(id: String) -> Data {
        Data(#"""
        {
          "request": \#(requestObject(id: id, isOwnRequest: nil, status: "claimed")),
          "claim": {
            "pickupName": "Alex",
            "claimToken": "token-\#(id)",
            "claimExpiresAt": "2026-07-20T19:30:00.000Z"
          }
        }
        """#.utf8)
    }

    private func requestObject(
        id: String,
        isOwnRequest: Bool?,
        status: String = "open"
    ) -> String {
        let ownField = isOwnRequest.map { ",\n  \"isOwnRequest\": \($0)" } ?? ""
        return """
        {
          "id": "\(id)",
          "vendor": "Crave NYU",
          "food": "Rice bowl",
          "pickupWindowText": "ASAP",
          "mealSwipes": 2,
          "windowStart": null,
          "windowEnd": null,
          "status": "\(status)",
          "createdAt": "2026-07-20T18:30:00.000Z",
          "expiresAt": "2026-07-20T23:30:00.000Z"\(ownField)
        }
        """
    }
}
