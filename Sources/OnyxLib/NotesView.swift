import SwiftUI

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

struct NotesView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var manager: NotesManager
    @State private var searchQuery = ""

    init(appState: AppState) {
        self.appState = appState
        self.manager = appState.notesManager
    }

    var filteredNotes: [Note] {
        if searchQuery.isEmpty { return manager.notes }
        return manager.notes.filter {
            $0.title.localizedCaseInsensitiveContains(searchQuery) ||
            $0.content.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Note list
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text("NOTES")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(appState.accentColor)
                        .tracking(3)
                    Spacer()
                    Button(action: { manager.createNote() }) {
                        Image(systemName: "plus")
                            .foregroundColor(appState.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)

                // Search
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundColor(.gray.opacity(0.4))
                    TextField("Search...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.04))

                Divider().background(Color.white.opacity(0.1))

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredNotes) { note in
                            NoteRow(note: note, isSelected: manager.selectedNoteID == note.id, accentColor: appState.accentColor)
                                .onTapGesture {
                                    manager.selectedNoteID = note.id
                                }
                                .contextMenu {
                                    Button("Delete", role: .destructive) {
                                        manager.deleteNote(note)
                                    }
                                }
                        }
                    }
                }

                // Delete hint
                if manager.selectedNoteID != nil {
                    Divider().background(Color.white.opacity(0.1))
                    Text("⌘⌫ delete")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.3))
                        .padding(8)
                }
            }
            .frame(width: 220)
            .background(Color.black.opacity(0.4))

            Divider().background(Color.white.opacity(0.1))

            // Editor
            if let noteID = manager.selectedNoteID,
               let index = manager.notes.firstIndex(where: { $0.id == noteID }) {
                NoteEditorView(note: $manager.notes[index], onSave: {
                    manager.saveNote(manager.notes[index])
                })
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Text("Select or create a note")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.5))
                    Text("⌘E to create")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.3))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: NSColor(white: 0.06, alpha: 0.95)))
        .onReceive(appState.$createNoteRequested) { requested in
            if requested {
                manager.createNote()
                appState.createNoteRequested = false
            }
        }
    }
}

struct NoteRow: View {
    let note: Note
    let isSelected: Bool
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(isSelected ? accentColor : .white.opacity(0.8))
                .lineLimit(1)

            if !note.content.isEmpty {
                Text(note.content.prefix(60).replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.5))
                    .lineLimit(1)
            }

            Text(note.modified, style: .relative)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.gray.opacity(0.3))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.white.opacity(0.08) : Color.clear)
    }
}

struct NoteEditorView: View {
    @Binding var note: Note
    let onSave: () -> Void

    var body: some View {
        TextEditor(text: $note.content)
            .font(.system(.body, design: .monospaced))
            .foregroundColor(.white.opacity(0.9))
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .padding(12)
            .onChange(of: note.content) { _, _ in
                onSave()
            }
    }
}
