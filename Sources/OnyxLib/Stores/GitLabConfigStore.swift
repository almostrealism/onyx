//
// GitLabConfigStore.swift
//
// Responsibility: Persists the user's GitLab personal-access token, the
//                 list of project paths to watch for merge requests, the
//                 explicitly-tracked pipeline URLs, and the "only my MRs"
//                 preference. Mirrors GitHubConfigStore so the two
//                 providers configure the same way.
// Scope: Shared singleton.
// Threading: UserDefaults is thread-safe; no extra locking.
//
// Targets gitlab.com (API base https://gitlab.com/api/v4). A self-hosted
// host field could be added here later without touching callers.
//

import Foundation
import Combine

public final class GitLabConfigStore: ObservableObject {

    public static let shared = GitLabConfigStore()

    /// GitLab personal access token (scope: api / read_api). Empty = not
    /// configured. Sent as the `PRIVATE-TOKEN` header.
    public var token: String {
        get { UserDefaults.standard.string(forKey: "gitlab_token") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "gitlab_token")
            objectWillChange.send()
        }
    }

    /// Raw project URLs/paths the user pasted (one per line in settings).
    public var projectURLs: [String] {
        get { (UserDefaults.standard.array(forKey: "gitlab_projects") as? [String]) ?? [] }
        set {
            UserDefaults.standard.set(newValue, forKey: "gitlab_projects")
            objectWillChange.send()
        }
    }

    /// Parsed projects — invalid lines silently filtered.
    public var parsedProjects: [GitLabProjectSpec] {
        projectURLs.compactMap(GitLabProjectSpec.parse)
    }

    /// Explicitly-tracked GitLab pipeline URLs (one per line).
    public var pipelineURLs: [String] {
        get { (UserDefaults.standard.array(forKey: "gitlab_pipelines") as? [String]) ?? [] }
        set {
            UserDefaults.standard.set(newValue, forKey: "gitlab_pipelines")
            objectWillChange.send()
        }
    }

    /// Parsed pipeline specs — invalid entries filtered, GitLab-only.
    public var parsedPipelines: [PipelineSpec] {
        pipelineURLs.compactMap(PipelineSpec.parse).filter { $0.provider == .gitlab }
    }

    /// When true, only MRs authored by `username` are shown. On by
    /// default makes sense for busy GitLab projects, but we leave the
    /// default off and let the user opt in per provider.
    public var mineOnly: Bool {
        get { UserDefaults.standard.bool(forKey: "gitlab_mine_only") }
        set {
            UserDefaults.standard.set(newValue, forKey: "gitlab_mine_only")
            objectWillChange.send()
        }
    }

    /// Authenticated user's username, auto-detected from the token via
    /// `GET /user`. Empty until resolved. Feeds the `mineOnly` filter.
    public var username: String {
        get { UserDefaults.standard.string(forKey: "gitlab_username") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "gitlab_username")
            objectWillChange.send()
        }
    }

    public var isConfigured: Bool { !token.isEmpty && !parsedProjects.isEmpty }

    private init() {}

    /// Drop the first stored pipeline URL whose parsed spec matches
    /// `spec.id`. Mirrors GitHubConfigStore.removePipeline.
    public func removePipeline(_ spec: PipelineSpec) {
        let idx = pipelineURLs.firstIndex { raw in
            PipelineSpec.parse(raw)?.id == spec.id
        }
        guard let i = idx else { return }
        var current = pipelineURLs
        current.remove(at: i)
        pipelineURLs = current
    }

    /// Test-only — wipes the persisted config so unit tests start clean.
    public func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: "gitlab_token")
        UserDefaults.standard.removeObject(forKey: "gitlab_projects")
        UserDefaults.standard.removeObject(forKey: "gitlab_pipelines")
        UserDefaults.standard.removeObject(forKey: "gitlab_mine_only")
        UserDefaults.standard.removeObject(forKey: "gitlab_username")
        objectWillChange.send()
    }
}
