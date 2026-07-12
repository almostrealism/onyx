//
// FlowtreeModels.swift
//
// Responsibility: Pure data types for the flowtree controller integration —
//                 connection config, the workstream summaries we list, and the
//                 job-submit result. No I/O, no ObservableObject.
// Scope: Model. Depends only on Foundation.
//
// The controller HTTP API (see ../common/flowtree): GET /api/workstreams lists
// workstreams; POST /api/submit creates a job. The controller itself is
// unauthenticated; the production instance sits behind Cloudflare Access, so
// requests carry CF-Access service-token headers when configured (optional for
// a local instance). See docs / ADR notes and FlowtreeClient.
//

import Foundation

/// Connection settings for a flowtree controller. `clientId`/`clientSecret`
/// are Cloudflare Access service-token credentials — sent as
/// `CF-Access-Client-Id` / `CF-Access-Client-Secret` headers when both are
/// present, and omitted for an unprotected local instance.
public struct FlowtreeConfig: Equatable {
    public var baseURL: String
    public var clientId: String
    public var clientSecret: String

    public init(baseURL: String, clientId: String = "", clientSecret: String = "") {
        self.baseURL = baseURL
        self.clientId = clientId
        self.clientSecret = clientSecret
    }

    /// True when both Cloudflare Access credentials are set.
    public var hasAccessToken: Bool {
        !clientId.trimmingCharacters(in: .whitespaces).isEmpty
            && !clientSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// A workstream as returned by `GET /api/workstreams`. Most fields are optional
/// — the controller omits absent ones (e.g. `archived` only appears when true).
public struct FlowtreeWorkstream: Codable, Identifiable, Hashable {
    public let workstreamId: String
    public let channelName: String?
    public let repoUrl: String?
    public let defaultBranch: String?
    public let githubOrg: String?
    public let archived: Bool?

    public var id: String { workstreamId }

    /// Human-friendly label for the picker.
    public var displayName: String {
        if let c = channelName, !c.isEmpty { return c }
        return workstreamId
    }

    /// Secondary line (repo · branch) when available.
    public var subtitle: String? {
        var parts: [String] = []
        if let repo = repoUrl, !repo.isEmpty {
            parts.append((repo as NSString).lastPathComponent)
        }
        if let branch = defaultBranch, !branch.isEmpty {
            parts.append(branch)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public var isArchived: Bool { archived == true }
}

/// Result of `POST /api/submit`. `{ "ok": true, "jobId": "..." }` on success,
/// `{ "ok": false, "error": "..." }` otherwise.
public struct FlowtreeSubmitResult: Codable {
    public let ok: Bool
    public let jobId: String?
    public let error: String?
}
