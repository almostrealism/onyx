import Foundation
import Combine

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
