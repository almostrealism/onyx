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

    // MARK: - rename

    private func makeManagerWithOneNote() throws -> (NotesManager, URL) {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let manager = NotesManager(directory: tmpDir)
        manager.createNote()
        return (manager, tmpDir)
    }

    func testRenameNote_succeeds_andUpdatesSelectedID() throws {
        let (manager, tmpDir) = try makeManagerWithOneNote()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let note = manager.notes[0]
        let result = manager.renameNote(note, to: "Project plans")
        XCTAssertEqual(result, .renamed(newID: "Project plans.md"))
        XCTAssertEqual(manager.notes.count, 1)
        XCTAssertEqual(manager.notes[0].id, "Project plans.md")
        XCTAssertEqual(manager.notes[0].title, "Project plans")
        XCTAssertEqual(manager.selectedNoteID, "Project plans.md")
    }

    func testRenameNote_returnsUnchanged_forEmptyOrSameTitle() throws {
        let (manager, tmpDir) = try makeManagerWithOneNote()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let note = manager.notes[0]
        XCTAssertEqual(manager.renameNote(note, to: ""), .unchanged)
        XCTAssertEqual(manager.renameNote(note, to: "   "), .unchanged)
        XCTAssertEqual(manager.renameNote(note, to: note.title), .unchanged)
        XCTAssertEqual(manager.notes[0].id, note.id, "no rename, id unchanged")
    }

    func testRenameNote_returnsConflict_andDoesNotOverwrite() throws {
        let (manager, tmpDir) = try makeManagerWithOneNote()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        // Drop a second note file directly (createNote()'s second-precision
        // timestamp filenames would collide if invoked twice in the same
        // second — we're not testing createNote here).
        let secondURL = tmpDir.appendingPathComponent("another.md")
        try "second".write(to: secondURL, atomically: true, encoding: .utf8)
        manager.loadNotes()
        XCTAssertEqual(manager.notes.count, 2)
        let other = manager.notes.first { $0.id != "another.md" }!
        let result = manager.renameNote(other, to: "another")
        XCTAssertEqual(result, .conflict)
        // Both files still exist with their original names.
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertEqual(manager.notes.count, 2)
    }

    func testRenameNote_stripsTypedExtension() throws {
        // User types "report.md" — we shouldn't end up with "report.md.md".
        let (manager, tmpDir) = try makeManagerWithOneNote()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let note = manager.notes[0]
        let result = manager.renameNote(note, to: "report.md")
        XCTAssertEqual(result, .renamed(newID: "report.md"))
        XCTAssertEqual(manager.notes[0].id, "report.md")
    }

    func testRenameNote_doesNotChangeSelectionForUnrelatedNote() throws {
        let (manager, tmpDir) = try makeManagerWithOneNote()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        // Drop a second note directly (sidestep createNote's
        // second-precision filename collision).
        try "x".write(to: tmpDir.appendingPathComponent("sideline.md"),
                      atomically: true, encoding: .utf8)
        manager.loadNotes()
        let selected = manager.selectedNoteID
        XCTAssertNotNil(selected)
        let other = manager.notes.first { $0.id != selected }!
        _ = manager.renameNote(other, to: "Sideways")
        XCTAssertEqual(manager.selectedNoteID, selected,
                       "renaming a non-selected note must not steal selection")
    }

    // MARK: - sanitizedTitle

    func testSanitizedTitle_replacesPathSeparators() {
        XCTAssertEqual(NotesManager.sanitizedTitle("foo/bar"), "foo-bar")
        XCTAssertEqual(NotesManager.sanitizedTitle("a/b/c"), "a-b-c")
        XCTAssertEqual(NotesManager.sanitizedTitle("colon:in:name"), "colon-in-name")
        XCTAssertEqual(NotesManager.sanitizedTitle("back\\slash"), "back-slash")
    }

    func testSanitizedTitle_stripsLeadingDots() {
        // Don't accidentally create hidden files.
        XCTAssertEqual(NotesManager.sanitizedTitle(".hidden"), "hidden")
        XCTAssertEqual(NotesManager.sanitizedTitle("...foo"), "foo")
    }

    func testSanitizedTitle_collapsesInternalWhitespace() {
        XCTAssertEqual(NotesManager.sanitizedTitle("foo    bar"), "foo bar")
        XCTAssertEqual(NotesManager.sanitizedTitle("a  b  c"), "a b c")
    }

    func testSanitizedTitle_trimsOuterWhitespace() {
        XCTAssertEqual(NotesManager.sanitizedTitle("  foo  "), "foo")
        XCTAssertEqual(NotesManager.sanitizedTitle("\tbar\n"), "bar")
    }

    func testStrippingNoteExtension_dropsRecognizedExtensions() {
        XCTAssertEqual(NotesManager.strippingNoteExtension("notes.md"), "notes")
        XCTAssertEqual(NotesManager.strippingNoteExtension("plan.txt"), "plan")
        XCTAssertEqual(NotesManager.strippingNoteExtension("notes.MD"), "notes")
        XCTAssertEqual(NotesManager.strippingNoteExtension("notes.TXT"), "notes")
    }

    func testStrippingNoteExtension_keepsUnrelatedExtensions() {
        // A note title that ends in something like ".swift" or ".io" is
        // probably intentional; don't strip it.
        XCTAssertEqual(NotesManager.strippingNoteExtension("plan.swift"), "plan.swift")
        XCTAssertEqual(NotesManager.strippingNoteExtension("setup.io"), "setup.io")
        XCTAssertEqual(NotesManager.strippingNoteExtension("no-extension"), "no-extension")
    }
}
