//
//  APIClient.swift
//  CommonPlateios
//
//  Created by faith on 7/13/26.
//
// Generic HTTP client foundation, per docs/system-contract.md. Owns
// endpoint URL construction, request/response encoding and decoding, ISO-8601
// date handling, HTTP status validation, and error-envelope decoding. It does
// not know about specific endpoints, DTO-to-domain mapping, or retries —
// those belong to RequestService/RequestStore.
import Foundation

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
}

/// Client-side representation of a failed request. Preserves the backend's
/// stable error code and readable fallback message where available; unknown
/// or malformed error bodies still produce a usable generic case.
enum APIClientError: Error {
    case invalidURL
    case transport(Error)
    case unexpectedStatus(Int)
    case encoding(Error)
    case decoding(Error)
    case apiError(code: String, message: String)
}

struct APIClient {
    let configuration: APIConfiguration
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(configuration: APIConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.iso8601Formatter.string(from: date))
        }
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = Self.iso8601Formatter.date(from: raw) {
                return date
            }
            if let date = Self.iso8601FormatterNoFractionalSeconds.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO-8601 date string, got \(raw)"
            )
        }
        self.decoder = decoder
    }

    /// Mongoose emits fractional-second ISO-8601 timestamps (e.g. `2026-07-13T12:00:00.000Z`).
    /// Foundation's built-in `.iso8601` decoding strategy rejects fractional seconds, so both
    /// formatters are tried, fractional first.
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601FormatterNoFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Sends a request with an encodable JSON body and decodes a JSON response.
    ///
    /// `headers` carries transport-level credentials the backend reads outside
    /// the payload — today, the participant authority credential (W3-I1). It is
    /// deliberately a header rather than a body field: two accepted request
    /// shapes are strict about their keys, and a person-identity credential has
    /// no business in a payload that can be echoed back in a validation error.
    /// `timeoutInterval` overrides `URLSession`'s default (60s) for one
    /// request. `nil` (every existing call site) leaves the session default
    /// unchanged; a caller that needs a tighter finite bound — e.g. W4-S1's
    /// screenshot analysis, which must resolve or fail well before that —
    /// passes an explicit value instead.
    func send<Body: Encodable, Response: Decodable>(
        path: String,
        method: HTTPMethod,
        body: Body,
        headers: [String: String] = [:],
        timeoutInterval: TimeInterval? = nil
    ) async throws -> Response {
        var request = try makeRequest(path: path, method: method, headers: headers)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        do {
            request.httpBody = try encoder.encode(body)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIClientError.encoding(error)
        }
        return try await execute(request)
    }

    /// Sends a request with no body and decodes a JSON response.
    func send<Response: Decodable>(
        path: String,
        method: HTTPMethod,
        headers: [String: String] = [:]
    ) async throws -> Response {
        let request = try makeRequest(path: path, method: method, headers: headers)
        return try await execute(request)
    }

    private func makeRequest(
        path: String,
        method: HTTPMethod,
        headers: [String: String] = [:]
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: configuration.baseURL) else {
            throw APIClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    private func execute<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        try Task.checkCancellation()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw APIClientError.transport(error)
        }

        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.transport(URLError(.badServerResponse))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorEnvelope = try? decoder.decode(APIErrorResponse.self, from: data) {
                throw APIClientError.apiError(
                    code: errorEnvelope.error.code,
                    message: errorEnvelope.error.message
                )
            }
            throw APIClientError.unexpectedStatus(httpResponse.statusCode)
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIClientError.decoding(error)
        }
    }
}
