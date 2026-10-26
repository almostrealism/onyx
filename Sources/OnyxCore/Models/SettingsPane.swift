//
// SettingsPane.swift
//
// Responsibility: The categories Settings is divided into — a list on the
//                 left, the chosen category's settings on the right, the
//                 way macOS's own System Settings is laid out.
// Scope: Pure data. Which sections live in which pane is decided by
//        SettingsView; this only names the panes and fixes their order.
//
// A Model rather than a View type because AppState remembers the last pane
// (reopening Settings goes back to where you were), and AppState can't
// depend on Views.
//

public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general
    case appearance
    case hosts
    case monitor
    case reminders
    case pullRequests
    case pageWatches
    case alerts
    case claudeCode
    case sharedState
    case files
    case flowtree

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .hosts: return "Hosts"
        case .monitor: return "Monitor"
        case .reminders: return "Reminders"
        case .pullRequests: return "Pull Requests"
        case .pageWatches: return "Page Watches"
        case .alerts: return "Alerts"
        case .claudeCode: return "Claude Code"
        case .sharedState: return "Shared State"
        case .files: return "Files"
        case .flowtree: return "Flowtree"
        }
    }

    /// SF Symbol shown beside the title.
    public var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .hosts: return "server.rack"
        case .monitor: return "gauge.with.dots.needle.33percent"
        case .reminders: return "checklist"
        case .pullRequests: return "arrow.triangle.branch"
        case .pageWatches: return "eye"
        case .alerts: return "bell.badge"
        case .claudeCode: return "terminal"
        case .sharedState: return "arrow.triangle.2.circlepath"
        case .files: return "doc.text.magnifyingglass"
        case .flowtree: return "point.3.connected.trianglepath.dotted"
        }
    }
}
