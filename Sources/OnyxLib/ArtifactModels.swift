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

// MARK: - Artifact Manager

public class ArtifactManager: ObservableObject {
    @Published public var slots: [Int: Artifact] = [:]
    @Published public var activeSlot: Int = 0
    public static let slotCount = 8

    public init() {}

    public func setSlot(_ index: Int, title: String, content: ArtifactContent) -> Bool {
        guard (0..<Self.slotCount).contains(index) else { return false }
        let now = Date()
        if var existing = slots[index] {
            existing.title = title
            existing.content = content
            existing.updatedAt = now
            slots[index] = existing
        } else {
            slots[index] = Artifact(title: title, content: content, createdAt: now, updatedAt: now)
        }
        return true
    }

    public func clearSlot(_ index: Int) -> Bool {
        guard (0..<Self.slotCount).contains(index) else { return false }
        slots.removeValue(forKey: index)
        // Move activeSlot if needed
        if activeSlot == index {
            activeSlot = slots.keys.sorted().first ?? 0
        }
        return true
    }

    public func clearAll() {
        slots.removeAll()
        activeSlot = 0
    }

    public func listSlots() -> [(slot: Int, title: String, type: String)] {
        (0..<Self.slotCount).compactMap { i in
            guard let artifact = slots[i] else { return nil }
            return (slot: i, title: artifact.title, type: artifact.content.typeLabel)
        }
    }

    public var occupiedSlotCount: Int {
        slots.count
    }

    public var hasArtifacts: Bool {
        !slots.isEmpty
    }
}
