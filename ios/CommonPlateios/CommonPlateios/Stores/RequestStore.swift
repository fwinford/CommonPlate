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

    /// False until `GET /api/requests` has returned successfully at least once.
    /// This remains false after an initial failure, but becomes true for a
    /// successful empty response.
    @Published private(set) var hasSuccessfullyFetchedRequests = false
    @Published private(set) var isLoadingInitialRequests = false
    @Published private(set) var isRefreshingRequests = false
    @Published private(set) var initialFetchError: RequestServiceError?
    @Published private(set) var refreshError: RequestServiceError?

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

    var isFetching: Bool {
        isLoadingInitialRequests || isRefreshingRequests
    }

    /// `GET /api/requests`. Before the first successful response this is an
    /// initial load (including retries after an initial failure). Later calls
    /// are refreshes that preserve the current collection until success.
    func fetchRequests() async {
        fetchGeneration += 1
        let generation = fetchGeneration
        let isRefresh = hasSuccessfullyFetchedRequests

        if isRefresh {
            isRefreshingRequests = true
            refreshError = nil
        } else {
            isLoadingInitialRequests = true
            initialFetchError = nil
        }

        defer {
            if generation == fetchGeneration {
                if isRefresh {
                    isRefreshingRequests = false
                } else {
                    isLoadingInitialRequests = false
                }
            }
        }

        do {
            let fetchedRequests = try await service.fetchActiveRequests()
            guard generation == fetchGeneration else { return }
            requests = fetchedRequests
            hasSuccessfullyFetchedRequests = true
            if isRefresh {
                refreshError = nil
            } else {
                initialFetchError = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == fetchGeneration else { return }
            if isRefresh {
                refreshError = Self.asServiceError(error)
            } else {
                initialFetchError = Self.asServiceError(error)
            }
        }
    }

    /// `POST /api/request`. Not automatically retried on failure, including
    /// when the service reports an ambiguous create outcome. Returns normally
    /// only after the confirmed request has been added to local state.
    func createRequest(_ payload: CreateRequestPayload) async throws {
        guard !isCreating else {
            throw RequestServiceError.operationInProgress
        }
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
            let serviceError = Self.asServiceError(error)
            createError = serviceError
            throw serviceError
        }
    }

    /// `POST /api/request/:id/claim`. Local list state and the in-memory
    /// active claim are updated only after the backend confirms the claim.
    /// An ambiguous response never fabricates claim credentials. Returns
    /// normally only after both confirmed request and claim state are updated.
    func claim(requestID: String) async throws {
        guard !isClaiming else {
            throw RequestServiceError.operationInProgress
        }
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
            let serviceError = Self.asServiceError(error)
            claimError = serviceError
            throw serviceError
        }
    }

    /// `POST /api/request/:id/fulfill`. Requires the in-memory active claim
    /// for `requestID`; not automatically retried on failure, including when
    /// the outcome is ambiguous (`RequestServiceError.ambiguousFulfillmentOutcome`).
    /// Returns normally only after confirmed request/notification state is applied.
    func fulfill(
        requestID: String,
        fulfillerEmail: String,
        orderNumber: String,
        eta: String,
        note: String?,
        contactMessage: String?
    ) async throws {
        guard !isFulfilling else {
            throw RequestServiceError.operationInProgress
        }
        confirmedFulfillmentOutcome = nil
        guard let activeClaim, activeClaim.requestID == requestID else {
            fulfillError = .noActiveClaim
            throw RequestServiceError.noActiveClaim
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
            let serviceError = Self.asServiceError(error)
            fulfillError = serviceError
            throw serviceError
        }
    }

    private func invalidateCurrentFetch() {
        guard isFetching else { return }
        fetchGeneration += 1
        isLoadingInitialRequests = false
        isRefreshingRequests = false
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
