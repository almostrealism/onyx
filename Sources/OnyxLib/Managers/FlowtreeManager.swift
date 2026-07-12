//
// FlowtreeManager.swift
//
// Responsibility: Coordinates the flowtree integration for the UI — fetches
//                 the workstream list (for the reminder submit picker) and
//                 submits a reminder as a job. Publishes loading/error state
//                 and a transient submit status.
// Scope: Manager (shared singleton — flowtree config is global, not per-host).
//        Depends on Services (FlowtreeClient), Stores (FlowtreeConfigStore),
//        Models, and EventKit.
// Threading: plain ObservableObject; @Published mutations hop to the main actor.
//

import Foundation
import Combine
import EventKit

public final class FlowtreeManager: ObservableObject {

    public static let shared = FlowtreeManager()

    @Published public private(set) var workstreams: [FlowtreeWorkstream] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: String?
    /// One-line status shown briefly after a submit, then auto-cleared.
    @Published public private(set) var submitStatus: SubmitStatus?

    public struct SubmitStatus: Equatable {
        public let message: String
        public let isError: Bool
    }

    private var lastLoaded: Date?
    private var loadTask: Task<Void, Never>?
    private var statusGen = 0

    private init() {}

    private var client: FlowtreeClient { FlowtreeClient(config: FlowtreeConfigStore.shared.config) }
    public var isConfigured: Bool { FlowtreeConfigStore.shared.isConfigured }

    // MARK: - Workstreams

    /// Load the workstream list unless we fetched a non-empty one within the
    /// last minute. Called when the overlay appears / a submit menu opens so
    /// the picker is warm without polling the external service.
    public func ensureLoaded() {
        if let t = lastLoaded, Date().timeIntervalSince(t) < 60, !workstreams.isEmpty { return }
        refresh()
    }

    /// Force a refresh (fire-and-forget).
    public func refresh() {
        guard isConfigured else { return }
        loadTask?.cancel()
        loadTask = Task { await self.refreshWorkstreams() }
    }

    public func refreshWorkstreams() async {
        guard isConfigured else { return }
        await MainActor.run { self.isLoading = true; self.lastError = nil }
        do {
            let all = try await client.listWorkstreams()
            let visible = all
                .filter { !$0.isArchived }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            await MainActor.run {
                self.workstreams = visible
                self.isLoading = false
                self.lastLoaded = Date()
            }
        } catch {
            let msg = (error as? FlowtreeError)?.message ?? error.localizedDescription
            await MainActor.run { self.isLoading = false; self.lastError = msg }
        }
    }

    // MARK: - Submit

    /// Submit a reminder (title + notes + url) to `workstream` as a job.
    public func submit(reminder: EKReminder, to workstream: FlowtreeWorkstream) async {
        let title = (reminder.title?.isEmpty == false) ? reminder.title! : "Reminder"
        let prompt = Self.composePrompt(title: reminder.title,
                                        notes: reminder.notes,
                                        url: reminder.url?.absoluteString)
        do {
            let result = try await client.submit(workstreamId: workstream.workstreamId,
                                                 prompt: prompt, description: title)
            if result.ok {
                await showStatus("Submitted “\(title)” → \(workstream.displayName)", isError: false)
            } else {
                await showStatus("Submit failed: \(result.error ?? "unknown error")", isError: true)
            }
        } catch {
            let msg = (error as? FlowtreeError)?.message ?? error.localizedDescription
            await showStatus("Submit failed: \(msg)", isError: true)
        }
    }

    /// Compose the job prompt from a reminder's parts. Pure + testable.
    static func composePrompt(title: String?, notes: String?, url: String?) -> String {
        var parts: [String] = []
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { parts.append(t) }
        if let n = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { parts.append(n) }
        if let u = url?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty {
            parts.append("Reminder link: \(u)")
        }
        return parts.joined(separator: "\n\n")
    }

    @MainActor
    private func showStatus(_ message: String, isError: Bool) {
        statusGen += 1
        let gen = statusGen
        submitStatus = SubmitStatus(message: message, isError: isError)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if self.statusGen == gen { self.submitStatus = nil }
        }
    }
}
