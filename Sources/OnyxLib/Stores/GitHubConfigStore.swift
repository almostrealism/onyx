//
// GitHubConfigStore.swift
//
// Responsibility: Persists the user's GitHub personal-access token and
//                 the list of repo URLs they want the PR section to
//                 watch. Both live in UserDefaults — the token follows
//                 the same convention as TimingDataStore.apiToken.
// Scope: Shared singleton.
// Threading: UserDefaults is thread-safe; no extra locking.
//

import Foundation
import Combine

public final class GitHubConfigStore: ObservableObject {

    public static let shared = GitHubConfigStore()

    /// PAT for the GitHub API. Stored verbatim — same convention as
    /// TimingDataStore.apiToken. Empty string means "not configured".
    public var token: String {
        get { UserDefaults.standard.string(forKey: "github_token") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "github_token")
            objectWillChange.send()
        }
    }

    /// The raw URL strings the user pasted (one per line in settings).
    /// Persisted verbatim so the settings UI can round-trip the user's
    /// input rather than rewriting it into a canonical form.
    public var repoURLs: [String] {
        get {
            (UserDefaults.standard.array(forKey: "github_repos") as? [String]) ?? []
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "github_repos")
            objectWillChange.send()
        }
    }

    /// Parsed view of repoURLs — only the entries that look like a real
    /// owner/repo pair. Invalid lines (typos, blanks, comments) are
    /// silently filtered.
    public var parsedRepos: [GitHubRepoSpec] {
        repoURLs.compactMap(GitHubRepoSpec.parse)
    }

    /// Verbatim URLs the user has added for GitHub Actions pipeline
    /// tracking. Same UserDefaults convention as repoURLs.
    public var pipelineURLs: [String] {
        get { (UserDefaults.standard.array(forKey: "github_pipelines") as? [String]) ?? [] }
        set {
            UserDefaults.standard.set(newValue, forKey: "github_pipelines")
            objectWillChange.send()
        }
    }

    /// Parsed pipeline specs — invalid entries silently filtered.
    public var parsedPipelines: [PipelineSpec] {
        pipelineURLs.compactMap(PipelineSpec.parse)
    }

    /// Drop the first stored URL whose parsed spec matches `spec.id`.
    /// Matches by parsed id rather than raw string so equivalent URL
    /// variants (`?branch=foo` vs `?query=branch:foo`) collapse to the
    /// same entry.
    public func removePipeline(_ spec: PipelineSpec) {
        let idx = pipelineURLs.firstIndex { raw in
            PipelineSpec.parse(raw)?.id == spec.id
        }
        guard let i = idx else { return }
        var current = pipelineURLs
        current.remove(at: i)
        pipelineURLs = current
    }

    public var isConfigured: Bool { !token.isEmpty && !parsedRepos.isEmpty }

    private init() {}

    /// Test-only — wipes the persisted config so unit tests start clean.
    public func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: "github_token")
        UserDefaults.standard.removeObject(forKey: "github_repos")
        objectWillChange.send()
    }
}
