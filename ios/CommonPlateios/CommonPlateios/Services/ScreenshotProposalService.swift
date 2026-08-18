//
//  ScreenshotProposalService.swift
//  CommonPlateios
//
// Owns `POST /api/request/screenshot-proposal` endpoint knowledge (W4-S1),
// per `src/screenshotProposalRoute.ts`. Talks to the backend only through
// `APIClient`. Deliberately its own service, distinct vocabulary from
// `RequestService`: this can never call `createRequest`, and nothing it
// returns is itself a `Request` or a `CreateRequestPayload`.
import Foundation

enum ScreenshotProposalErrorCode {
    static let verificationRequired = "PARTICIPANT_VERIFICATION_REQUIRED"
    static let authorityInvalid = "PARTICIPANT_AUTHORITY_INVALID"
    static let verificationUnavailable = "PARTICIPANT_VERIFICATION_UNAVAILABLE"
    static let invalidImage = "INVALID_IMAGE"
    static let publicActionsPaused = "PUBLIC_ACTIONS_PAUSED"
    static let rateLimited = "RATE_LIMITED"
}

/// Product-safe, structured failure surface. Every case still leaves the
/// requester's manual form fully usable — none of these ever blocks or
/// mutates request creation.
enum ScreenshotProposalServiceError: Error {
    case verificationRequired
    case authorityInvalid
    case invalidImage
    /// Every other outcome — provider/network failure, timeout, malformed
    /// response, pause, rate limit, transport/decoding failure. All degrade
    /// identically for the requester: analysis is unavailable right now.
    case unavailable(underlying: Error)
}

private struct ScreenshotProposalRequestPayload: Encodable {
    let imageBase64: String
    let mimeType: String
    /// On-device Apple Vision OCR transcription of the same image
    /// (`ScreenshotLocalTextRecognizer`) — a different engine than the
    /// OpenAI provider the backend calls. The backend's sole eligibility and
    /// meal-swipe-corroboration evidence source; this app never asks the
    /// provider to produce or confirm its own evidence.
    let localEvidenceText: String
}

private struct ScreenshotProposalLocationDTO: Decodable {
    let name: String
    let address: String
}

private struct ScreenshotProposalFieldsDTO: Decodable {
    let selectedDiningSpot: ScreenshotProposalLocationDTO?
    let foodRequest: String?
    let mealSwipes: Int?
}

private struct ScreenshotProposalResponseDTO: Decodable {
    let eligible: Bool
    let proposal: ScreenshotProposalFieldsDTO
}

struct ScreenshotProposalService {
    let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    static let routePath = "/api/request/screenshot-proposal"

    /// Finite bound tighter than `URLSession`'s 60s default: an analysis
    /// attempt must resolve or fail well inside the requester's patience, and
    /// the backend's own bound (`PROVIDER_TIMEOUT_MS`,
    /// `screenshotProposalRoute.ts`) is shorter still.
    static let requestTimeoutInterval: TimeInterval = 25

    /// Sends exactly one normalized screenshot. `imageData` and `mimeType`
    /// are whatever local normalization already produced
    /// (`ScreenshotImageNormalizer`) — this call performs no further
    /// transformation. Nothing here retries: a failed attempt is reported as
    /// such, never silently resent.
    func requestProposal(
        imageData: Data,
        mimeType: String,
        localEvidenceText: String,
        authority: String
    ) async throws -> ScreenshotProposalOutcome {
        try Task.checkCancellation()

        do {
            let response: ScreenshotProposalResponseDTO = try await client.send(
                path: Self.routePath,
                method: .post,
                body: ScreenshotProposalRequestPayload(
                    imageBase64: imageData.base64EncodedString(),
                    mimeType: mimeType,
                    localEvidenceText: localEvidenceText
                ),
                headers: [RequestService.participantAuthorityHeader: authority],
                timeoutInterval: Self.requestTimeoutInterval
            )
            return ScreenshotProposalOutcome(
                eligible: response.eligible,
                proposal: Self.mapProposal(response.proposal)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIClientError {
            throw Self.translate(error)
        } catch {
            throw ScreenshotProposalServiceError.unavailable(underlying: error)
        }
    }

    /// A wire-proposed location is only ever applied by name lookup against
    /// the bundled catalog (`SupportedVendorCatalog.diningSpots`) — never
    /// trusted as an ad hoc `DiningSpot` value — so an applied proposal can
    /// only ever be one of the same catalog entries the picker itself offers.
    private static func mapProposal(_ dto: ScreenshotProposalFieldsDTO) -> ScreenshotProposal {
        let spot = dto.selectedDiningSpot.flatMap { locationDTO in
            SupportedVendorCatalog.diningSpots.first { $0.name == locationDTO.name }
        }
        return ScreenshotProposal(
            selectedDiningSpot: spot,
            foodRequest: dto.foodRequest,
            mealSwipes: dto.mealSwipes
        )
    }

    private static func translate(_ error: APIClientError) -> ScreenshotProposalServiceError {
        switch error {
        case .apiError(let code, _):
            switch code {
            case ScreenshotProposalErrorCode.verificationRequired:
                return .verificationRequired
            case ScreenshotProposalErrorCode.authorityInvalid:
                return .authorityInvalid
            case ScreenshotProposalErrorCode.invalidImage:
                return .invalidImage
            default:
                return .unavailable(underlying: error)
            }
        case .unexpectedStatus, .transport, .decoding, .encoding, .invalidURL:
            return .unavailable(underlying: error)
        }
    }
}
