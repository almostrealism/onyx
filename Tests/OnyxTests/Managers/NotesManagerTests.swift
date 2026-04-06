import XCTest
@testable import OnyxLib

final class NoteTests: XCTestCase {

    func testNoteSortOrder() {
        let older = Note(id: "a.md", title: "A", content: "", modified: Date(timeIntervalSince1970: 1000))
        let newer = Note(id: "b.md", title: "B", content: "", modified: Date(timeIntervalSince1970: 2000))

        // Note's < puts newest first, so newer < older should be true
        XCTAssertTrue(newer < older)
        XCTAssertFalse(older < newer)
    }

    func testNotesManagerCreateAndDelete() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manager = NotesManager(directory: tmpDir)
        XCTAssertTrue(manager.notes.isEmpty)

        manager.createNote()
        XCTAssertEqual(manager.notes.count, 1)
        XCTAssertNotNil(manager.selectedNoteID)

        let note = manager.notes[0]
        manager.deleteNote(note)
        XCTAssertTrue(manager.notes.isEmpty)
        XCTAssertNil(manager.selectedNoteID)
    }

    func testNotesManagerSaveAndReload() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manager = NotesManager(directory: tmpDir)
        manager.createNote()

        var note = manager.notes[0]
        note.content = "Hello, World!"
        manager.saveNote(note)

        // Reload and verify
        let manager2 = NotesManager(directory: tmpDir)
        XCTAssertEqual(manager2.notes.count, 1)
        XCTAssertEqual(manager2.notes[0].content, "Hello, World!")
    }
}

