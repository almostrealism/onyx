//
// SharedSettings.swift
//
// Responsibility: Which settings follow the user between devices through
//                 the shared state, and how each is read from and written
//                 to AppearanceConfig.
// Scope: Model. Most are AppearanceConfig fields (pure functions over it);
//        the services' non-secret settings live in their stores, which this
//        reads and writes through their own properties so they notice.
//
// A setting is local unless it is listed here (docs/ios-plan.md, "What goes
// where"). The ones listed shape the Today page — what the iPhone shows —
// and are choices about the work rather than the desk. Anything about one
// machine (window layout, opacity, where alerts go: `externalDelivery` is
// per machine by rule) stays off this list; `SharedSettingsTests` names
// every member so adding one is a decision someone made.
//

import Foundation

public enum SharedSetting: String, CaseIterable, Codable {
    // In AppearanceConfig.
    case prDraftFilter
    case remindersLists
    case remindersDueSoonOnly
    case agendaPane
    case extraTimezones
    case use12HourClock
    /// Whether an agent's permission prompt waits for Onyx (the Mac's
    /// banner, the iPad's sheet) — one choice, because the prompt goes to
    /// whichever Onyx the host's agents reach.
    case claudeHooksGatePermissions
    // The services', in their stores. Without them a phone would have the
    // tokens and nothing to ask for: no repos, so no PRs.
    case githubRepos
    case githubUsername
    case githubMineOnly
    case gitlabProjects
    case gitlabUsername
    case gitlabMineOnly
    case flowtreeURL
    case flowtreeClientID
    /// The first window's Timing projects: the phone's tiles show the same.
    case timingProjects

    /// Posted when a synced setting changed the first window's Timing
    /// projects, which TimingManager reads straight from UserDefaults.
    public static let timingProjectsChanged = Notification.Name("OnyxSharedTimingProjectsChanged")
    static let timingProjectsKey = "timing_filters_0"

    /// The setting's value, as JSON: from `config`, or from its store.
    public func value(in config: AppearanceConfig) -> JSONValue? {
        switch self {
        case .prDraftFilter:        return .from(config.prDraftFilter)
        case .remindersLists:       return .from(config.remindersLists)
        case .remindersDueSoonOnly: return .from(config.remindersDueSoonOnly)
        case .agendaPane:           return .from(config.agendaPane)
        case .extraTimezones:       return .from(config.extraTimezones)
        case .use12HourClock:       return .from(config.use12HourClock)
        case .claudeHooksGatePermissions: return .from(config.claudeHooksGatePermissions)
        case .githubRepos:          return .from(GitHubConfigStore.shared.repoURLs)
        case .githubUsername:       return .from(GitHubConfigStore.shared.username)
        case .githubMineOnly:       return .from(GitHubConfigStore.shared.mineOnly)
        case .gitlabProjects:       return .from(GitLabConfigStore.shared.projectURLs)
        case .gitlabUsername:       return .from(GitLabConfigStore.shared.username)
        case .gitlabMineOnly:       return .from(GitLabConfigStore.shared.mineOnly)
        case .flowtreeURL:          return .from(FlowtreeConfigStore.shared.controllerURL)
        case .flowtreeClientID:     return .from(FlowtreeConfigStore.shared.clientId)
        case .timingProjects:
            return .from(UserDefaults.standard.stringArray(forKey: Self.timingProjectsKey) ?? [])
        }
    }

    /// Write `value` into `config`, or into its store — only when it
    /// differs, so an unchanged setting doesn't make the store announce a
    /// change (and refresh everything that watches it). A value of the
    /// wrong shape (a newer Onyx's idea of the setting) is ignored rather
    /// than guessed at.
    public func apply(_ value: JSONValue, to config: inout AppearanceConfig) {
        if value == self.value(in: config) { return }
        switch self {
        case .prDraftFilter:        if let v = value.decoded(as: PRDraftFilter.self) { config.prDraftFilter = v }
        case .remindersLists:       if let v = value.decoded(as: [String].self) { config.remindersLists = v }
        case .remindersDueSoonOnly: if let v = value.decoded(as: Bool.self) { config.remindersDueSoonOnly = v }
        case .agendaPane:           if let v = value.decoded(as: AgendaPane.self) { config.agendaPane = v }
        case .extraTimezones:       if let v = value.decoded(as: [String].self) { config.extraTimezones = v }
        case .use12HourClock:       if let v = value.decoded(as: Bool.self) { config.use12HourClock = v }
        case .claudeHooksGatePermissions:
            if let v = value.decoded(as: Bool.self) { config.claudeHooksGatePermissions = v }
        case .githubRepos:          if let v = value.decoded(as: [String].self) { GitHubConfigStore.shared.repoURLs = v }
        case .githubUsername:       if let v = value.decoded(as: String.self) { GitHubConfigStore.shared.username = v }
        case .githubMineOnly:       if let v = value.decoded(as: Bool.self) { GitHubConfigStore.shared.mineOnly = v }
        case .gitlabProjects:       if let v = value.decoded(as: [String].self) { GitLabConfigStore.shared.projectURLs = v }
        case .gitlabUsername:       if let v = value.decoded(as: String.self) { GitLabConfigStore.shared.username = v }
        case .gitlabMineOnly:       if let v = value.decoded(as: Bool.self) { GitLabConfigStore.shared.mineOnly = v }
        case .flowtreeURL:          if let v = value.decoded(as: String.self) { FlowtreeConfigStore.shared.controllerURL = v }
        case .flowtreeClientID:     if let v = value.decoded(as: String.self) { FlowtreeConfigStore.shared.clientId = v }
        case .timingProjects:
            if let v = value.decoded(as: [String].self) {
                UserDefaults.standard.set(v, forKey: Self.timingProjectsKey)
                NotificationCenter.default.post(name: Self.timingProjectsChanged, object: nil)
            }
        }
    }

    /// Settings kept in a store rather than in AppearanceConfig.
    public var livesInAStore: Bool {
        switch self {
        case .prDraftFilter, .remindersLists, .remindersDueSoonOnly, .agendaPane,
             .extraTimezones, .use12HourClock, .claudeHooksGatePermissions:
            return false
        default:
            return true
        }
    }

    /// Every shared setting's value in `config`, keyed by name.
    public static func snapshot(of config: AppearanceConfig) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for setting in allCases {
            if let v = setting.value(in: config) { out[setting.rawValue] = v }
        }
        return out
    }

    /// `config` with the shared settings in `values` written into it.
    /// Names this build doesn't know are left alone (they stay in the
    /// shared state for the Onyx that does).
    public static func applying(_ values: [String: JSONValue], to config: AppearanceConfig) -> AppearanceConfig {
        var next = config
        for (name, value) in values {
            SharedSetting(rawValue: name)?.apply(value, to: &next)
        }
        return next
    }
}
