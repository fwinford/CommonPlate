//
//  RequestStore.swift
//  CommonPlateios
//
//  Created by faith on 7/13/26.
//
// Coordinates RequestService calls and updates local state only after
// confirmed backend responses, per docs/week-2-integration-spec.md. Owns no
// SwiftUI screen; no view is connected to this store as part of this task.
import Combine
import Foundation

/// In-memory-only record of the helper's own active claim. Never written to
/// UserDefaults, Keychain, disk, or logs, and never exposed on the public
/// `FoodRequest` model. Discarded naturally on app restart (nothing persists
/// it) and invalidated explicitly after confirmed fulfillment. Week 2 does
/// not implement durable claim recovery.
struct ActiveClaim {
    let requestID: String
    let pickupName: String
    let claimToken: String
    let claimExpiresAt: Date
}

@MainActor
final class RequestStore: ObservableObject {
    @Published private(set) var requests: [FoodRequest] = []

    @Published private(set) var isFetching = false
    @Published private(set) var fetchError: RequestServiceError?

    @Published private(set) var isCreating = false
    @Published private(set) var createError: RequestServiceError?

    @Published private(set) var isClaiming = false
    @Published private(set) var claimError: RequestServiceError?

    @Published private(set) var isFulfilling = false
    @Published private(set) var fulfillError: RequestServiceError?
    @Published private(set) var confirmedFulfillmentOutcome: FulfillOutcome?

    /// The helper's active claim, if any. Memory-only; see `ActiveClaim`.
    @Published private(set) var activeClaim: ActiveClaim?

    private let service: RequestService
    private var fetchGeneration = 0

    init(service: RequestService) {
        self.service = service
    }

    /// `GET /api/requests`. Preserves existing `requests` on failure so a
    /// transient refresh error doesn't blank the list.
    func fetchRequests() async {
        fetchGeneration += 1
        let generation = fetchGeneration
        isFetching = true
        fetchError = nil
        defer {
            if generation == fetchGeneration {
                isFetching = false
            }
        }
        do {
            let fetchedRequests = try await service.fetchRequests()
            guard generation == fetchGeneration else { return }
            requests = fetchedRequests
        } catch is CancellationError {
            return
        } catch {
            guard generation == fetchGeneration else { return }
            fetchError = Self.asServiceError(error)
        }
    }

    /// `POST /api/request`. Not automatically retried on failure, including
    /// when the service reports an ambiguous create outcome.
    func createRequest(_ payload: CreateRequestPayload) async throws {
        guard !isCreating else { return }
        isCreating = true
        createError = nil
        defer { isCreating = false }
        do {
            let created = try await service.createRequest(payload)
            invalidateCurrentFetch()
            requests.append(created)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            createError = Self.asServiceError(error)
        }
    }

    /// `POST /api/request/:id/claim`. Local list state and the in-memory
    /// active claim are updated only after the backend confirms the claim.
    /// An ambiguous response never fabricates claim credentials.
    func claim(requestID: String) async throws {
        guard !isClaiming else { return }
        isClaiming = true
        claimError = nil
        defer { isClaiming = false }
        do {
            let outcome = try await service.claimRequest(id: requestID)
            invalidateCurrentFetch()
            applyConfirmed(outcome.request)
            activeClaim = ActiveClaim(
                requestID: outcome.request.id,
                pickupName: outcome.pickupName,
                claimToken: outcome.claimToken,
                claimExpiresAt: outcome.claimExpiresAt
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            claimError = Self.asServiceError(error)
        }
    }

    /// `POST /api/request/:id/fulfill`. Requires the in-memory active claim
    /// for `requestID`; not automatically retried on failure, including when
    /// the outcome is ambiguous (`RequestServiceError.ambiguousFulfillmentOutcome`).
    func fulfill(
        requestID: String,
        fulfillerEmail: String,
        orderNumber: String,
        eta: String,
        note: String?,
        contactMessage: String?
    ) async throws {
        guard !isFulfilling else { return }
        confirmedFulfillmentOutcome = nil
        guard let activeClaim, activeClaim.requestID == requestID else {
            fulfillError = .noActiveClaim
            return
        }

        isFulfilling = true
        fulfillError = nil
        defer { isFulfilling = false }
        do {
            let outcome = try await service.fulfillRequest(
                id: requestID,
                claimToken: activeClaim.claimToken,
                fulfillerEmail: fulfillerEmail,
                orderNumber: orderNumber,
                eta: eta,
                note: note,
                contactMessage: contactMessage
            )
            invalidateCurrentFetch()
            applyConfirmed(outcome.request)
            confirmedFulfillmentOutcome = outcome
            if self.activeClaim?.requestID == requestID,
               self.activeClaim?.claimToken == activeClaim.claimToken {
                self.activeClaim = nil
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            fulfillError = Self.asServiceError(error)
        }
    }

    private func invalidateCurrentFetch() {
        guard isFetching else { return }
        fetchGeneration += 1
        isFetching = false
    }

    private func applyConfirmed(_ request: FoodRequest) {
        if let index = requests.firstIndex(where: { $0.id == request.id }) {
            requests[index] = request
        } else {
            requests.append(request)
        }
    }

    private static func asServiceError(_ error: Error) -> RequestServiceError {
        (error as? RequestServiceError) ?? .transport(underlying: error)
    }
}
