//
// FlowtreeClient.swift
//
// Responsibility: Stateless async HTTP client for the flowtree controller API.
//                 Lists workstreams, submits jobs, checks health. Builds each
//                 URLRequest from a FlowtreeConfig, attaching Cloudflare Access
//                 service-token headers when configured.
// Scope: Service. Depends on Models (FlowtreeConfig/…) and Foundation.
//        `makeRequest` is a pure static so request-building is unit-testable
//        without hitting the network.
//

import Foundation

public enum FlowtreeError: Error, Equatable {
    case notConfigured
    case badURL
    case http(status: Int, body: String)
    case transport(String)
    case decode(String)

    public var message: String {
        switch self {
        case .notConfigured: return "No flowtree controller configured."
        case .badURL: return "The controller URL isn't valid."
        case .http(let status, let body):
            let detail = body.isEmpty ? "" : " — \(body.prefix(160))"
            return "Controller returned HTTP \(status)\(detail)"
        case .transport(let m): return "Couldn't reach the controller: \(m)"
        case .decode(let m): return "Unexpected response: \(m)"
        }
    }
}

public struct FlowtreeClient {
    let config: FlowtreeConfig
    let session: URLSession

    public init(config: FlowtreeConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - Request building (pure, testable)

    /// Build a request for `path` (e.g. "/api/workstreams"). Attaches CF-Access
    /// headers when both credentials are present; sets JSON content-type + body
    /// for POSTs. Returns nil if the base URL is empty/invalid.
    static func makeRequest(config: FlowtreeConfig,
                            path: String,
                            method: String,
                            jsonBody: [String: Any]? = nil) -> URLRequest? {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        if config.hasAccessToken {
            req.setValue(config.clientId, forHTTPHeaderField: "CF-Access-Client-Id")
            req.setValue(config.clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody)
        }
        return req
    }

    // MARK: - API calls

    /// `GET /api/workstreams` — the available workstreams (archived excluded).
    public func listWorkstreams() async throws -> [FlowtreeWorkstream] {
        let data = try await perform(path: "/api/workstreams", method: "GET")
        do {
            return try JSONDecoder().decode([FlowtreeWorkstream].self, from: data)
        } catch {
            throw FlowtreeError.decode(error.localizedDescription)
        }
    }

    /// `POST /api/submit` — create a job in `workstreamId` with `prompt`.
    public func submit(workstreamId: String,
                       prompt: String,
                       description: String?) async throws -> FlowtreeSubmitResult {
        var body: [String: Any] = ["workstreamId": workstreamId, "prompt": prompt]
        if let description, !description.isEmpty { body["description"] = description }
        let data = try await perform(path: "/api/submit", method: "POST", jsonBody: body)
        do {
            return try JSONDecoder().decode(FlowtreeSubmitResult.self, from: data)
        } catch {
            throw FlowtreeError.decode(error.localizedDescription)
        }
    }

    /// `GET /api/health` — true if the controller is reachable and healthy.
    public func health() async throws -> Bool {
        _ = try await perform(path: "/api/health", method: "GET")
        return true
    }

    // MARK: - Transport

    private func perform(path: String, method: String, jsonBody: [String: Any]? = nil) async throws -> Data {
        guard !config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FlowtreeError.notConfigured
        }
        guard let request = Self.makeRequest(config: config, path: path, method: method, jsonBody: jsonBody) else {
            throw FlowtreeError.badURL
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FlowtreeError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw FlowtreeError.transport("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FlowtreeError.http(status: http.statusCode, body: body)
        }
        return data
    }
}
