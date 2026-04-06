import Foundation

// MARK: - Artifact Types

public enum TextFormat: String, Codable {
    case plain, markdown, html
}

public enum DiagramFormat: String, Codable {
    case mermaid, plantuml
}

public enum ModelFormat: String, Codable {
    case obj, usdz, stl
}

public enum ArtifactContent: Equatable {
    case text(content: String, format: TextFormat, language: String?, wrap: Bool)
    case diagram(content: String, format: DiagramFormat)
    case model3D(data: Data, format: ModelFormat)

    public var typeLabel: String {
        switch self {
        case .text: return "text"
        case .diagram: return "diagram"
        case .model3D: return "3d_model"
        }
    }
}

public struct Artifact: Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public var content: ArtifactContent
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, content: ArtifactContent, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
