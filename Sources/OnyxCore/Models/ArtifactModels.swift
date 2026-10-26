import Foundation

// MARK: - Artifact Types

/// TextFormat.
public enum TextFormat: String, Codable {
    case plain, markdown, html
}

/// DiagramFormat.
public enum DiagramFormat: String, Codable {
    case mermaid, plantuml
}

/// ModelFormat.
public enum ModelFormat: String, Codable {
    case obj, usdz, stl
}

/// ArtifactContent.
public enum ArtifactContent: Equatable {
    case text(content: String, format: TextFormat, language: String?, wrap: Bool)
    case diagram(content: String, format: DiagramFormat)
    case model3D(data: Data, format: ModelFormat)

    /// Type label.
    public var typeLabel: String {
        switch self {
        case .text: return "text"
        case .diagram: return "diagram"
        case .model3D: return "3d_model"
        }
    }
}

/// Artifact.
public struct Artifact: Identifiable, Equatable {
    /// Id.
    public let id: UUID
    /// Title.
    public var title: String
    /// Content.
    public var content: ArtifactContent
    /// Created at.
    public var createdAt: Date
    /// Updated at.
    public var updatedAt: Date

    /// Create a new instance.
    public init(id: UUID = UUID(), title: String, content: ArtifactContent, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
