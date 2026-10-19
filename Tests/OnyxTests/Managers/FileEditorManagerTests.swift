import XCTest
@testable import OnyxLib

/// The editor end to end, against files on this Mac (the local host path
/// uses the same open / conflict / save logic as a remote one).
final class FileEditorManagerTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        AppearanceStore.shared.reset()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("onyx-editor-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func waitFor(_ what: String, _ condition: @escaping () -> Bool) {
        let done = expectation(description: what)
        func poll() {
            if condition() { done.fulfill() } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
            }
        }
        poll()
        wait(for: [done], timeout: 5)
    }

    private func file(_ name: String, _ contents: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testEditAndSave() throws {
        let url = try file("a.txt", "one\r\ntwo\n")
        let editor = FileEditorManager(appState: AppState())
        editor.open(path: url.path, host: nil)
        waitFor("loaded") { editor.phase == .editing }
        XCTAssertEqual(editor.text, "one\r\ntwo\n")
        XCTAssertFalse(editor.isDirty)

        editor.text = "one\r\ntwo\nthree\n"
        XCTAssertTrue(editor.isDirty)
        editor.save()
        waitFor("saved") { editor.lastSaved != nil }
        XCTAssertEqual(try String(contentsOf: url), "one\r\ntwo\nthree\n")
        XCTAssertFalse(editor.isDirty)
    }

    func testAChangeOnDiskIsNotOverwrittenWithoutAsking() throws {
        let url = try file("b.txt", "mine")
        let editor = FileEditorManager(appState: AppState())
        editor.open(path: url.path, host: nil)
        waitFor("loaded") { editor.phase == .editing }

        try Data("theirs".utf8).write(to: url)
        editor.text = "mine, edited"
        editor.save()
        waitFor("conflict") { editor.phase == .conflict }
        XCTAssertEqual(try String(contentsOf: url), "theirs", "untouched")

        editor.overwrite()
        waitFor("overwritten") { editor.lastSaved != nil }
        XCTAssertEqual(try String(contentsOf: url), "mine, edited")
    }

    func testReloadTakesTheirs() throws {
        let url = try file("c.txt", "v1")
        let editor = FileEditorManager(appState: AppState())
        editor.open(path: url.path, host: nil)
        waitFor("loaded") { editor.phase == .editing }
        try Data("v2".utf8).write(to: url)
        editor.text = "mine"
        editor.reload()
        waitFor("reloaded") { editor.phase == .editing && editor.text == "v2" }
        XCTAssertFalse(editor.isDirty)
    }

    func testBinaryIsRefused() throws {
        let url = dir.appendingPathComponent("d.bin")
        try Data([0x00, 0xff, 0xfe, 0x80]).write(to: url)
        let editor = FileEditorManager(appState: AppState())
        editor.open(path: url.path, host: nil)
        waitFor("refused") { if case .refused = editor.phase { return true }; return false }
    }

    func testClosingWithEditsAsksFirst() throws {
        let url = try file("e.txt", "x")
        let app = AppState()
        app.openFileEditor(path: url.path)
        waitFor("loaded") { app.fileEditor.phase == .editing }
        app.fileEditor.text = "y"
        app.closeFileEditor()
        XCTAssertTrue(app.showFileEditor, "still open")
        XCTAssertTrue(app.fileEditor.confirmingDiscard)
        app.closeFileEditor(force: true)
        XCTAssertFalse(app.showFileEditor)
        XCTAssertEqual(try String(contentsOf: url), "x", "discarded, not saved")
    }
}
