import Foundation
import Combine

public struct Note: Identifiable, Comparable {
    public let id: String // filename
    public var title: String
    public var content: String
    public var modified: Date

    public init(id: String, title: String, content: String, modified: Date) {
        self.id = id
        self.title = title
        self.content = content
        self.modified = modified
    }

    public static func < (lhs: Note, rhs: Note) -> Bool {
        lhs.modified > rhs.modified // newest first
    }
}

public class NotesManager: ObservableObject {
    @Published public var notes: [Note] = []
    @Published public var selectedNoteID: String?
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        loadNotes()
    }

    public func loadNotes() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        notes = files.compactMap { url -> Note? in
            guard url.pathExtension == "md" || url.pathExtension == "txt" else { return nil }
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let modified = (attrs?[.modificationDate] as? Date) ?? Date()
            let title = url.deletingPathExtension().lastPathComponent
            return Note(id: url.lastPathComponent, title: title, content: content, modified: modified)
        }.sorted()
    }

    public func createNote() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "note-\(formatter.string(from: Date())).md"
        let url = directory.appendingPathComponent(filename)
        try? "".write(to: url, atomically: true, encoding: .utf8)
        loadNotes()
        selectedNoteID = filename
    }

    public func saveNote(_ note: Note) {
        let url = directory.appendingPathComponent(note.id)
        try? note.content.write(to: url, atomically: true, encoding: .utf8)
    }

    public func deleteNote(_ note: Note) {
        let url = directory.appendingPathComponent(note.id)
        try? FileManager.default.removeItem(at: url)
        if selectedNoteID == note.id {
            selectedNoteID = nil
        }
        loadNotes()
    }

    public func renameNote(_ note: Note, to newTitle: String) {
        let oldURL = directory.appendingPathComponent(note.id)
        let ext = (note.id as NSString).pathExtension
        let newFilename = "\(newTitle).\(ext)"
        let newURL = directory.appendingPathComponent(newFilename)
        try? FileManager.default.moveItem(at: oldURL, to: newURL)
        loadNotes()
        selectedNoteID = newFilename
    }
}
