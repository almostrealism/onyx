//
// ArtifactManager.swift
//
// Responsibility: Owns up to 8 numbered artifact slots (text/data payloads)
//                 produced by tools or pasted by the user, plus the active slot.
// Scope: Per-window (lives on AppState).
// Threading: Main actor only — all mutations occur from UI/MCP server callbacks
//            already dispatched onto the main queue.
// Invariants:
//   - slot index is always in 0..<slotCount (8)
//   - activeSlot points to an existing key in `slots`, or 0 if empty
//   - clearing the active slot reassigns activeSlot to the next occupied slot
//

import Foundation
import Combine

// MARK: - Artifact Manager

/// ArtifactManager.
public class ArtifactManager: ObservableObject {
    @Published public var slots: [Int: Artifact] = [:]
    @Published public var activeSlot: Int = 0
    /// Slot count.
    public static let slotCount = 8

    /// Create a new instance.
    public init() {}

    /// Set slot.
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

    /// Clear slot.
    public func clearSlot(_ index: Int) -> Bool {
        guard (0..<Self.slotCount).contains(index) else { return false }
        slots.removeValue(forKey: index)
        // Move activeSlot if needed
        if activeSlot == index {
            activeSlot = slots.keys.sorted().first ?? 0
        }
        return true
    }

    /// Clear all.
    public func clearAll() {
        slots.removeAll()
        activeSlot = 0
    }

    /// List slots.
    public func listSlots() -> [(slot: Int, title: String, type: String)] {
        (0..<Self.slotCount).compactMap { i in
            guard let artifact = slots[i] else { return nil }
            return (slot: i, title: artifact.title, type: artifact.content.typeLabel)
        }
    }

    /// Occupied slot count.
    public var occupiedSlotCount: Int {
        slots.count
    }

    /// Has artifacts.
    public var hasArtifacts: Bool {
        !slots.isEmpty
    }
}
