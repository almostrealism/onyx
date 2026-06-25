import SwiftUI
import Foundation

struct NotesView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var manager: NotesManager

    init(appState: AppState) {
        self.appState = appState
        self.manager = appState.notesManager
    }

    var body: some View {
        VStack(spacing: 0) {
            // All notes as a grid up top (alphabetical), mirroring the file
            // browser's favorites grid — the full width is then free for the
            // editor below.
            NotesGridSection(appState: appState, manager: manager)

            Divider().background(Color.white.opacity(0.1))

            // Editor — full width.
            editorArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Recently-edited notes along the bottom.
            RecentNotesBar(appState: appState, manager: manager)
        }
        .background(Color(nsColor: NSColor(white: 0.06, alpha: 0.95)))
        .onReceive(appState.$createNoteRequested) { requested in
            if requested {
                manager.createNote()
                appState.createNoteRequested = false
            }
        }
    }

    @ViewBuilder
    private var editorArea: some View {
        if let noteID = manager.selectedNoteID,
           let index = manager.notes.firstIndex(where: { $0.id == noteID }) {
            NoteEditorView(manager: manager, note: $manager.notes[index], onSave: {
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
}

/// Grid of all notes across the top of the notes panel — alphabetical by
/// title, searchable. Recency lives in RecentNotesBar at the bottom, so the
/// grid stays a stable A–Z index you can scan.
struct NotesGridSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject var manager: NotesManager
    @State private var searchQuery = ""

    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 6)]

    private var gridNotes: [Note] {
        let sorted = manager.notes.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        guard !searchQuery.isEmpty else { return sorted }
        return sorted.filter {
            $0.title.localizedCaseInsensitiveContains(searchQuery) ||
            $0.content.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("NOTES")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(appState.accentColor)
                    .tracking(2)
                Spacer()
                Button(action: { manager.createNote() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .foregroundColor(appState.accentColor)
                }
                .buttonStyle(.plain)
                .help("New note")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

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

            if gridNotes.isEmpty {
                Text(manager.notes.isEmpty ? "No notes yet — tap + to create one" : "No matches")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.4))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                        ForEach(gridNotes) { note in
                            noteCell(note)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 170)   // a few rows, then scroll
            }
        }
        .background(Color.black.opacity(0.25))
    }

    private func noteCell(_ note: Note) -> some View {
        let selected = manager.selectedNoteID == note.id
        return Button(action: { manager.selectedNoteID = note.id }) {
            HStack(spacing: 5) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundColor(selected ? appState.accentColor : .gray.opacity(0.5))
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(selected ? appState.accentColor : .white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? appState.accentColor.opacity(0.15) : Color.white.opacity(0.05))
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .help(notePreview(note))
        .contextMenu {
            Button("Delete", role: .destructive) { manager.deleteNote(note) }
        }
    }

    private func notePreview(_ note: Note) -> String {
        let body = note.content.prefix(80).replacingOccurrences(of: "\n", with: " ")
        return body.isEmpty ? note.title : "\(note.title) — \(body)"
    }
}

/// Recently-edited notes as a horizontal strip along the bottom — quick
/// access to whatever you were just working on. `manager.notes` is already
/// sorted modified-newest-first.
struct RecentNotesBar: View {
    @ObservedObject var appState: AppState
    @ObservedObject var manager: NotesManager

    var body: some View {
        let recent = Array(manager.notes.prefix(12))
        if !recent.isEmpty {
            VStack(spacing: 0) {
                Divider().background(Color.white.opacity(0.1))
                HStack(spacing: 8) {
                    Text("RECENT")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.4))
                        .tracking(1)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(recent) { note in
                                Button(action: { manager.selectedNoteID = note.id }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.text")
                                            .font(.system(size: 9))
                                            .foregroundColor(.gray.opacity(0.4))
                                        Text(note.title.isEmpty ? "Untitled" : note.title)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(manager.selectedNoteID == note.id
                                                             ? appState.accentColor : .white.opacity(0.75))
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.05))
                                    .cornerRadius(4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.25))
            }
        }
    }
}

struct NoteEditorView: View {
    @ObservedObject var manager: NotesManager
    @Binding var note: Note
    let onSave: () -> Void

    // Staged title text — typing doesn't fight the user. Commit on
    // Enter or focus loss (see commitTitle). Re-seeded from the model
    // when the selected note switches.
    @State private var titleText: String = ""
    @State private var titleError: String?
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Untitled", text: $titleText.sanitizingStylizedText())
                    .focused($titleFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .onSubmit { commitTitle() }
                    .onChange(of: titleFocused) { _, isFocused in
                        if !isFocused { commitTitle() }
                    }
                if let titleError = titleError {
                    Text(titleError)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(hex: "FF6B6B").opacity(0.8))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().background(Color.white.opacity(0.08))

            TextEditor(text: $note.content.sanitizingStylizedText())
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(12)
                .onChange(of: note.content) { _, _ in
                    onSave()
                }
        }
        .onAppear { titleText = note.title }
        .onChange(of: note.id) { _, _ in
            // Selected note switched — seed the field with the new
            // note's title and clear any prior error.
            titleText = note.title
            titleError = nil
        }
    }

    private func commitTitle() {
        switch manager.renameNote(note, to: titleText) {
        case .renamed:
            titleError = nil
            // The model now points at the renamed note; selectedNoteID
            // and titleText converge on the next render via note.id
            // observation.
        case .unchanged:
            // Empty or same as before — reset display to the current
            // title so the field shows what's actually on disk.
            titleText = note.title
            titleError = nil
        case .conflict:
            titleText = note.title
            titleError = "A note with that name already exists."
        case .failed:
            titleText = note.title
            titleError = "Couldn't rename — check filesystem permissions."
        }
    }
}
