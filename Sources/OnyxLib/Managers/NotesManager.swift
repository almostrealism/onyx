//
// NotesManager.swift
//
// Responsibility: Loads, creates, saves, renames, and deletes plain-text /
//                 markdown notes from a single on-disk directory.
// Scope: Per-window (lives on AppState; directory itself is shared on disk).
// Threading: Main actor only — all file I/O is synchronous and called from
//            the main queue (notes are small, latency is negligible).
// Invariants:
//   - notes is always sorted by modification date, newest first
//   - selectedNoteID, when non-nil, references an existing note id
//   - Note ids are filenames (with .md or .txt extension)
//

import Foundation
import Combine

/// Note.
public struct Note: Identifiable, Comparable {
    /// Id.
    public let id: String // filename
    /// Title.
    public var title: String
    /// Content.
    public var content: String
    /// Modified.
    public var modified: Date

    /// Create a new instance.
    public init(id: String, title: String, content: String, modified: Date) {
        self.id = id
        self.title = title
        self.content = content
        self.modified = modified
    }

    /// .
    public static func < (lhs: Note, rhs: Note) -> Bool {
        lhs.modified > rhs.modified // newest first
    }
}

/// NotesManager.
public class NotesManager: ObservableObject {
    @Published public var notes: [Note] = []
    @Published public var selectedNoteID: String?
    /// Directory.
    public let directory: URL

    /// Create a new instance.
    public init(directory: URL) {
        self.directory = directory
        loadNotes()
    }

    /// Load notes.
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

    /// Create note.
    public func createNote() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "note-\(formatter.string(from: Date())).md"
        let url = directory.appendingPathComponent(filename)
        try? "".write(to: url, atomically: true, encoding: .utf8)
        loadNotes()
        selectedNoteID = filename
    }

    /// Save note.
    public func saveNote(_ note: Note) {
        let url = directory.appendingPathComponent(note.id)
        // Backstop: never persist macOS smart-quote/dash substitutions, even
        // if one arrived via paste before the editor could strip it.
        let clean = TextSanitizer.sanitize(note.content)
        try? clean.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Delete note.
    public func deleteNote(_ note: Note) {
        let url = directory.appendingPathComponent(note.id)
        try? FileManager.default.removeItem(at: url)
        if selectedNoteID == note.id {
            selectedNoteID = nil
        }
        loadNotes()
    }

    /// Result of an attempt to rename a note.
    public enum RenameResult: Equatable {
        /// File renamed; `newID` is the new filename and also the
        /// note's new identity in `notes`.
        case renamed(newID: String)
        /// Input sanitized to empty, or unchanged from the current
        /// title. No FS action taken.
        case unchanged
        /// A different note already uses that filename. Caller should
        /// surface this to the user; nothing on disk was changed.
        case conflict
        /// A filesystem error prevented the rename.
        case failed
    }

    /// Rename note. Sanitizes the input, strips any `.md`/`.txt` the user
    /// may have typed, refuses to silently overwrite an existing file, and
    /// reports the outcome. Selected-note tracking is updated only if the
    /// renamed note was the selected one.
    @discardableResult
    public func renameNote(_ note: Note, to newTitle: String) -> RenameResult {
        let sanitized = Self.sanitizedTitle(newTitle)
        let base = Self.strippingNoteExtension(sanitized)
        guard !base.isEmpty else { return .unchanged }

        let ext = (note.id as NSString).pathExtension
        let extPart = ext.isEmpty ? "md" : ext
        let newFilename = "\(base).\(extPart)"
        if newFilename == note.id { return .unchanged }

        let fm = FileManager.default
        let oldURL = directory.appendingPathComponent(note.id)
        let newURL = directory.appendingPathComponent(newFilename)
        if fm.fileExists(atPath: newURL.path) { return .conflict }

        do {
            try fm.moveItem(at: oldURL, to: newURL)
        } catch {
            return .failed
        }
        loadNotes()
        if selectedNoteID == note.id {
            selectedNoteID = newFilename
        }
        return .renamed(newID: newFilename)
    }

    /// Make a user-typed title safe for use as a filename:
    ///   - replace path separators and null bytes with `-`
    ///   - collapse internal whitespace runs to a single space
    ///   - strip leading dots so we don't accidentally create hidden files
    ///   - trim leading/trailing whitespace
    public static func sanitizedTitle(_ raw: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/:\\\0")
        var result = raw.components(separatedBy: unsafe).joined(separator: "-")
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        while result.hasPrefix(".") {
            result = String(result.dropFirst())
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// If the user typed a `.md`/`.txt` extension in their title, strip it
    /// so we don't end up with `my-notes.md.md`.
    public static func strippingNoteExtension(_ s: String) -> String {
        let ext = (s as NSString).pathExtension.lowercased()
        if ext == "md" || ext == "txt" {
            return (s as NSString).deletingPathExtension
        }
        return s
    }
}
