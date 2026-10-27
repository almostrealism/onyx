//
// PadToolViews.swift
//
// Responsibility: The iPad's side panel — the session's note, and the
//                 host's monitor, files and git — and the editor and diff
//                 sheets they open. Views over PadTools' managers, which
//                 are the Mac's.
// Scope: View.
//

import SwiftUI
import OnyxCore
import OnyxUI

struct PadToolsPanel: View {
    @ObservedObject var tools: PadTools
    let session: TmuxSession?
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Panel", selection: Binding(get: { tools.panel }, set: { tools.showPanel($0) })) {
                ForEach(PadTools.Panel.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 10)

            switch tools.panel {
            case .note:
                if let session { PadNoteEditor(session: session, accent: accent) }
            case .monitor:
                PadMonitorPanel(monitor: tools.monitor, host: tools.host, accent: accent)
            case .files:
                PadFilesPanel(tools: tools, files: tools.files, accent: accent)
            case .git:
                PadGitPanel(tools: tools, git: tools.git, accent: accent)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Monitor

struct PadMonitorPanel: View {
    @ObservedObject var monitor: MonitorManager
    let host: PadHost?
    let accent: Color

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text((host?.label ?? "No host").uppercased())
                    .monitorFont(size: 10, weight: .medium).foregroundColor(accent).tracking(1.5)
                if let sample = monitor.latestSample {
                    gauge("CPU", sample.cpuUsage, detail: nil, color: Color.onyxBlue)
                    sparkline(monitor.bucketedCPU(), color: Color.onyxBlue)
                    // The last reading that had memory in it: a poll can
                    // come back with CPU and no MEM section.
                    let mem = monitor.samples.last { $0.memUsed != nil && $0.memTotal != nil } ?? sample
                    gauge("MEM", memoryPercent(mem),
                          detail: memoryDetail(mem), color: Color.onyxAmber)
                    sparkline(monitor.bucketedMemory(), color: Color.onyxAmber)
                    if let gpu = sample.gpuUsage {
                        gauge("GPU", gpu, detail: sample.gpuName, color: Color.onyxPurple)
                        sparkline(monitor.bucketedGPU(), color: Color.onyxPurple)
                    }
                    if let os = sample.os {
                        Text(os).monitorFont(size: 10).foregroundColor(.gray)
                    }
                } else if let error = monitor.lastError {
                    Text(error).monitorFont(size: 11).foregroundColor(Color.onyxRed.opacity(0.85))
                } else {
                    Text("Reading \(host?.label ?? "the host")…").monitorFont(size: 11).foregroundColor(.gray)
                }
                if let skip = monitor.lastSkip {
                    Text(skip).monitorFont(size: 9).foregroundColor(.gray)
                }
            }
            .padding(12)
        }
    }

    private func memoryPercent(_ s: MonitorSample) -> Double? {
        guard let used = s.memUsed, let total = s.memTotal, total > 0 else { return nil }
        return used / total * 100
    }

    private func memoryDetail(_ s: MonitorSample) -> String? {
        guard let used = s.memUsed, let total = s.memTotal else { return nil }
        return String(format: "%.1f / %.1f GB", used / 1024, total / 1024)
    }

    private func gauge(_ title: String, _ value: Double?, detail: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).monitorFont(size: 11, weight: .medium).foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(value.map { String(format: "%.0f%%", $0) } ?? "—")
                    .monitorFont(size: 18, weight: .medium).foregroundColor(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.06))
                    Rectangle().fill(color.opacity(0.7))
                        .frame(width: geo.size.width * CGFloat(min(max(value ?? 0, 0), 100) / 100))
                }
            }
            .frame(height: 4)
            if let detail { Text(detail).monitorFont(size: 9).foregroundColor(.gray) }
        }
    }

    private func sparkline(_ values: [Double], color: Color) -> some View {
        GeometryReader { geo in
            Path { path in
                guard values.count > 1 else { return }
                let step = geo.size.width / CGFloat(values.count - 1)
                for (i, v) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(i) * step,
                                        y: geo.size.height * (1 - CGFloat(min(max(v, 0), 100) / 100)))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(color.opacity(0.8), lineWidth: 1.2)
        }
        .frame(height: 36)
        .background(Color.white.opacity(0.03))
    }
}

// MARK: - Files

struct PadFilesPanel: View {
    @ObservedObject var tools: PadTools
    @ObservedObject var files: FileBrowserManager
    let accent: Color
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button(action: { files.navigateBack() }) { Image(systemName: "chevron.left") }
                    .disabled(files.pathHistory.isEmpty)
                Button(action: { tools.openHome() }) { Image(systemName: "house") }
                Button(action: { files.listCurrentDirectory() }) { Image(systemName: "arrow.clockwise") }
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            Text(files.currentPath ?? "")
                .monitorFont(size: 10).foregroundColor(accent).lineLimit(2).truncationMode(.head)
                .padding(.horizontal, 12)
            if let error = files.error {
                Text(error).monitorFont(size: 10).foregroundColor(Color.onyxRed.opacity(0.85))
                    .padding(.horizontal, 12)
            }
            List(files.entries) { entry in
                Button(action: { open(entry) }) {
                    HStack(spacing: 8) {
                        Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                            .foregroundColor(entry.isDirectory ? accent : .gray)
                            .frame(width: 16)
                        Text(entry.name).monitorFont(size: 12).foregroundColor(.white.opacity(0.85))
                        Spacer()
                        if !entry.isDirectory {
                            Text(entry.size).monitorFont(size: 9).foregroundColor(.gray)
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .overlay { if files.isLoading { ProgressView() } }
        }
        .sheet(isPresented: $editing, onDismiss: { tools.editor.close() }) {
            PadEditorSheet(editor: tools.editor, accent: accent)
        }
    }

    private func open(_ entry: RemoteEntry) {
        guard let path = files.fullPath(of: entry) else { return }
        if entry.isDirectory {
            files.navigateTo(path)
        } else {
            tools.editor.open(path: path, host: tools.activeHost)
            editing = true
        }
    }
}

/// A remote file, edited in place: the Mac's FileEditorManager, which
/// refuses to save over a copy that changed on the host since it opened.
struct PadEditorSheet: View {
    @ObservedObject var editor: FileEditorManager
    let accent: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                switch editor.phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .refused(let why):
                    Text(why).monitorFont(size: 12).foregroundColor(.gray).padding()
                    Spacer()
                default:
                    if editor.phase == .conflict {
                        HStack {
                            Text("Changed on \(editor.hostLabel) since you opened it.")
                                .monitorFont(size: 11).foregroundColor(Color.onyxAmber)
                            Spacer()
                            Button("Reload") { editor.reload() }
                            Button("Overwrite") { editor.overwrite() }
                        }
                        .padding(10)
                    }
                    if let error = editor.saveError {
                        Text(error).monitorFont(size: 11).foregroundColor(Color.onyxRed).padding(10)
                    }
                    TextEditor(text: $editor.text)
                        .font(.system(size: 13, design: .monospaced))
                        .codeEntry()
                        .scrollContentBackground(.hidden)
                        .background(Color.black)
                }
            }
            .navigationTitle(editor.fileName)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editor.phase == .saving ? "Saving…" : "Save") { editor.save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!editor.isDirty || editor.phase == .saving)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Git

struct PadGitPanel: View {
    @ObservedObject var tools: PadTools
    @ObservedObject var git: GitManager
    let accent: Color
    @State private var showingDiff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = git.repoStatus, git.isGitRepo {
                HStack {
                    Image(systemName: "arrow.triangle.branch").foregroundColor(accent)
                    Text(status.branch).monitorFont(size: 12, weight: .medium)
                    Spacer()
                    Button("Diff") { git.fetchFullDiff(); showingDiff = true }
                        .buttonStyle(.borderless)
                    Button(git.showLog ? "Files" : "Log") {
                        if git.showLog { git.closeLog() } else { git.fetchLog() }
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                if git.showLog {
                    List(git.logEntries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message).monitorFont(size: 11).lineLimit(2)
                            Text("\(entry.hash) · \(entry.author) · \(entry.date)")
                                .monitorFont(size: 9).foregroundColor(.gray)
                        }
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                } else if status.changedFiles.isEmpty {
                    Text("Clean.").monitorFont(size: 11).foregroundColor(.gray).padding(.horizontal, 12)
                    Spacer()
                } else {
                    List(status.changedFiles) { file in
                        Button(action: { git.fetchFileDiff(file); showingDiff = true }) {
                            HStack(spacing: 8) {
                                Text(file.status.label).monitorFont(size: 11, weight: .medium)
                                    .foregroundColor(color(file.status)).frame(width: 14)
                                Text(file.path).monitorFont(size: 11).lineLimit(1).truncationMode(.head)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                }
            } else {
                Text(git.unavailableReason ?? (git.isLoading ? "Reading git status…"
                    : "\(tools.files.currentPath ?? "This folder") isn't in a git repository. Open one in Files."))
                    .monitorFont(size: 11).foregroundColor(.gray).padding(.horizontal, 12)
                Spacer()
            }
        }
        .sheet(isPresented: $showingDiff, onDismiss: { git.closeDiff() }) {
            PadDiffSheet(git: git)
        }
    }

    private func color(_ status: GitFileStatus) -> Color {
        switch status {
        case .added, .untracked: return Color.onyxGreen
        case .deleted: return Color.onyxRed
        case .unmerged: return Color.onyxPurple
        default: return Color.onyxAmber
        }
    }
}

struct PadDiffSheet: View {
    @ObservedObject var git: GitManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                if let diff = git.fileDiff {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diff.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(color(line))
                                .fixedSize()
                        }
                    }
                    .padding(12)
                } else {
                    ProgressView().padding(40)
                }
            }
            .navigationTitle(git.fileDiffTitle ?? "Diff")
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private func color(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .white.opacity(0.7) }
        if line.hasPrefix("+") { return Color.onyxGreen }
        if line.hasPrefix("-") { return Color.onyxRed }
        if line.hasPrefix("@@") { return Color.onyxBlue }
        return .white.opacity(0.8)
    }
}
