import Foundation

/// Which forge a PR/MR or pipeline lives on. The monitor overlay merges
/// items from both into single lists, tagging each row with the provider
/// so their provenance stays clear.
public enum GitProvider: String, Codable, Equatable, Hashable {
    case github
    case gitlab

    /// Two-letter badge shown on merged rows.
    public var badge: String {
        switch self {
        case .github: return "GH"
        case .gitlab: return "GL"
        }
    }

    /// Brand-ish accent for the badge. GitHub stays neutral; GitLab uses
    /// its orange so the two are instantly distinguishable.
    public var badgeHex: String {
        switch self {
        case .github: return "9E9E9E"
        case .gitlab: return "FC6D26"
        }
    }
}
