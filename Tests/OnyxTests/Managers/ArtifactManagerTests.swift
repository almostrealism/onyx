import XCTest
@testable import OnyxLib

// MARK: - ArtifactManager Tests

final class ArtifactManagerTests: XCTestCase {

    func testSetSlot_validSlot() {
        let manager = ArtifactManager()
        let result = manager.setSlot(0, title: "Test", content: .text(content: "Hello", format: .plain, language: nil, wrap: true))
        XCTAssertTrue(result)
        XCTAssertEqual(manager.slots.count, 1)
        XCTAssertEqual(manager.slots[0]?.title, "Test")
    }

    func testSetSlot_invalidSlotNegative() {
        let manager = ArtifactManager()
        XCTAssertFalse(manager.setSlot(-1, title: "Bad", content: .text(content: "", format: .plain, language: nil, wrap: true)))
        XCTAssertTrue(manager.slots.isEmpty)
    }

    func testSetSlot_invalidSlotTooHigh() {
        let manager = ArtifactManager()
        XCTAssertFalse(manager.setSlot(8, title: "Bad", content: .text(content: "", format: .plain, language: nil, wrap: true)))
        XCTAssertTrue(manager.slots.isEmpty)
    }

    func testSetSlot_allValidSlots() {
        let manager = ArtifactManager()
        for i in 0..<8 {
            XCTAssertTrue(manager.setSlot(i, title: "Slot \(i)", content: .text(content: "Content \(i)", format: .plain, language: nil, wrap: true)))
        }
        XCTAssertEqual(manager.slots.count, 8)
    }

    func testSetSlot_updatesExisting() {
        let manager = ArtifactManager()
        _ = manager.setSlot(0, title: "First", content: .text(content: "v1", format: .plain, language: nil, wrap: true))
        let firstID = manager.slots[0]!.id
        _ = manager.setSlot(0, title: "Updated", content: .text(content: "v2", format: .markdown, language: nil, wrap: true))
        XCTAssertEqual(manager.slots[0]?.title, "Updated")
        XCTAssertEqual(manager.slots[0]?.content, .text(content: "v2", format: .markdown, language: nil, wrap: true))
        XCTAssertEqual(manager.slots[0]?.id, firstID) // same artifact, just updated
    }

    func testClearSlot_valid() {
        let manager = ArtifactManager()
        _ = manager.setSlot(3, title: "Test", content: .text(content: "", format: .plain, language: nil, wrap: true))
        XCTAssertTrue(manager.clearSlot(3))
        XCTAssertNil(manager.slots[3])
    }

    func testClearSlot_invalid() {
        let manager = ArtifactManager()
        XCTAssertFalse(manager.clearSlot(-1))
        XCTAssertFalse(manager.clearSlot(8))
    }

    func testClearSlot_adjustsActiveSlot() {
        let manager = ArtifactManager()
        _ = manager.setSlot(2, title: "A", content: .text(content: "", format: .plain, language: nil, wrap: true))
        _ = manager.setSlot(5, title: "B", content: .text(content: "", format: .plain, language: nil, wrap: true))
        manager.activeSlot = 2
        _ = manager.clearSlot(2)
        XCTAssertEqual(manager.activeSlot, 5) // moves to next occupied slot
    }

    func testClearAll() {
        let manager = ArtifactManager()
        _ = manager.setSlot(0, title: "A", content: .text(content: "", format: .plain, language: nil, wrap: true))
        _ = manager.setSlot(7, title: "B", content: .diagram(content: "graph TD", format: .mermaid))
        manager.activeSlot = 7
        manager.clearAll()
        XCTAssertTrue(manager.slots.isEmpty)
        XCTAssertEqual(manager.activeSlot, 0)
    }

    func testListSlots_empty() {
        let manager = ArtifactManager()
        XCTAssertTrue(manager.listSlots().isEmpty)
    }

    func testListSlots_ordered() {
        let manager = ArtifactManager()
        _ = manager.setSlot(5, title: "Five", content: .diagram(content: "graph", format: .mermaid))
        _ = manager.setSlot(1, title: "One", content: .text(content: "hello", format: .plain, language: nil, wrap: true))
        let list = manager.listSlots()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].slot, 1)
        XCTAssertEqual(list[0].title, "One")
        XCTAssertEqual(list[0].type, "text")
        XCTAssertEqual(list[1].slot, 5)
        XCTAssertEqual(list[1].title, "Five")
        XCTAssertEqual(list[1].type, "diagram")
    }

    func testHasArtifacts() {
        let manager = ArtifactManager()
        XCTAssertFalse(manager.hasArtifacts)
        _ = manager.setSlot(0, title: "X", content: .text(content: "", format: .plain, language: nil, wrap: true))
        XCTAssertTrue(manager.hasArtifacts)
    }

    func testOccupiedSlotCount() {
        let manager = ArtifactManager()
        XCTAssertEqual(manager.occupiedSlotCount, 0)
        _ = manager.setSlot(0, title: "A", content: .text(content: "", format: .plain, language: nil, wrap: true))
        _ = manager.setSlot(3, title: "B", content: .text(content: "", format: .plain, language: nil, wrap: true))
        XCTAssertEqual(manager.occupiedSlotCount, 2)
    }

    func testArtifactContent_typeLabel() {
        XCTAssertEqual(ArtifactContent.text(content: "", format: .plain, language: nil, wrap: true).typeLabel, "text")
        XCTAssertEqual(ArtifactContent.diagram(content: "", format: .mermaid).typeLabel, "diagram")
        XCTAssertEqual(ArtifactContent.model3D(data: Data(), format: .obj).typeLabel, "3d_model")
    }

    func testArtifactContent_equality() {
        let a = ArtifactContent.text(content: "hello", format: .markdown, language: nil, wrap: true)
        let b = ArtifactContent.text(content: "hello", format: .markdown, language: nil, wrap: true)
        let c = ArtifactContent.text(content: "hello", format: .plain, language: nil, wrap: true)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testDiagramContent() {
        let manager = ArtifactManager()
        let mermaid = "graph TD\n    A-->B"
        _ = manager.setSlot(0, title: "Flow", content: .diagram(content: mermaid, format: .mermaid))
        XCTAssertEqual(manager.slots[0]?.content, .diagram(content: mermaid, format: .mermaid))
    }

    func testModel3DContent() {
        let manager = ArtifactManager()
        let data = Data([0x01, 0x02, 0x03])
        _ = manager.setSlot(0, title: "Cube", content: .model3D(data: data, format: .obj))
        XCTAssertEqual(manager.slots[0]?.content, .model3D(data: data, format: .obj))
    }
}

