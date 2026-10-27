//
// PadRoot.swift
//
// Responsibility: Onyx on an iPad — a sidebar of Today and every shared
//                 host's tmux sessions, the open terminals as tabs, a
//                 session's note beside it, and ⌘K to get anywhere.
// Scope: One per window (scene); the PadModel behind it is the app's.
//
// docs/ios-plan.md, phase 5. Keys, for a hardware keyboard:
//   ⌘K   the palette          ⌘0  Today
//   ⌘W   close the tab        ⌘⇧] ⌘⇧[  next / previous tab
//   ⌘⇧N  the session's note   ⌘R  list the sessions again
//   ⌘⇧M ⌘⇧F ⌘⇧G  the host's monitor, files, git
//   ⌘.   Esc, in a terminal
//

import SwiftUI
import OnyxCore
import OnyxUI
import OnyxToday

public struct PadRoot: View {
    @ObservedObject var model: PadModel
    @StateObject private var workspace = PadWorkspace()

    public init(model: PadModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if model.phone.home == nil {
                PairingView(model: model.phone)
            } else {
                PadWindow(model: model, workspace: workspace)
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear { workspace.closeAll() }
    }
}

struct PadWindow: View {
    @ObservedObject var model: PadModel
    @ObservedObject var workspace: PadWorkspace
    @StateObject private var tools: PadTools
    @ObservedObject private var notes = SessionNotesStore.shared
    @State private var showingPalette = false
    @State private var showingNote = false
    @State private var columns: NavigationSplitViewVisibility = .all

    init(model: PadModel, workspace: PadWorkspace) {
        self.model = model
        self.workspace = workspace
        _tools = StateObject(wrappedValue: PadTools(transport: model.phone.transport,
                                                    foldersURL: PadModel.supportURL("pad-folders.json")))
    }

    private var accent: Color { model.phone.today.accentColor }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            PadSidebar(model: model, workspace: workspace, accent: accent)
                .navigationTitle("Onyx")
        } detail: {
            VStack(spacing: 0) {
                if !workspace.terminals.isEmpty || !workspace.webTabs.isEmpty { PadTabStrip(workspace: workspace, accent: accent) }
                detail
            }
            .background(Color.black)
            .inspector(isPresented: noteShown) {
                PadToolsPanel(tools: tools, session: workspace.current?.session, accent: accent)
                    .inspectorColumnWidth(min: 260, ideal: 340, max: 480)
            }
            .toolbar { toolbar }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .tint(accent)
        // A terminal gets the whole width; the sidebar is a swipe or the
        // toolbar button away.
        .onChange(of: workspace.selection) { _, selection in
            if selection != .today { columns = .detailOnly }
            tools.follow(workspace.current?.host)
        }
        .sheet(isPresented: $showingPalette) {
            PadPalette(model: model, accent: accent) { pick($0) }
        }
        .background(shortcuts)
        #if DEBUG
        // For the simulator, which nobody can tap: open a session by name
        // once it's listed (`SIMCTL_CHILD_ONYX_PAD_OPEN=build/main`).
        .onReceive(model.$listings) { _ in openFromEnvironment() }
        #endif
    }

    #if DEBUG
    private func openFromEnvironment() {
        if workspace.webTabs.isEmpty, let web = ProcessInfo.processInfo.environment["ONYX_PAD_WEB"],
           let url = PadWebTab.url(from: web) {
            workspace.openWeb(url)
            return
        }
        guard workspace.terminals.isEmpty,
              let wanted = ProcessInfo.processInfo.environment["ONYX_PAD_OPEN"] else { return }
        let parts = wanted.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let found = model.allSessions.first(where: { $0.host.label == parts[0] && $0.session.name == parts[1] })
        else { return }
        workspace.open(found.session, on: found.host, using: model.phone.transport)
        tools.follow(found.host)
        if let path = ProcessInfo.processInfo.environment["ONYX_PAD_PATH"] { tools.files.navigateTo(path) }
        if let which = ProcessInfo.processInfo.environment["ONYX_PAD_PANEL"].flatMap(PadTools.Panel.init(rawValue:)) {
            panel(which)
        } else if ProcessInfo.processInfo.environment["ONYX_PAD_NOTE"] != nil {
            panel(.note)
        }
    }
    #endif

    @ViewBuilder private var detail: some View {
        if let terminal = workspace.current {
            PadTerminalScreen(terminal: terminal, accent: accent) {
                terminal.start(using: model.phone.transport)
            }
            .id(terminal.id)
        } else if let web = workspace.currentWeb {
            PadWebScreen(tab: web).id(web.id)
        } else {
            TodayPage(model: model.phone)
        }
    }

    private var noteShown: Binding<Bool> {
        Binding(get: { showingNote && workspace.current != nil }, set: { showingNote = $0 })
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { showingPalette = true }) {
                Label("Go to…", systemImage: "magnifyingglass")
            }
            if let terminal = workspace.current {
                Button(action: { showingNote.toggle() }) {
                    Label("Panel", systemImage: "sidebar.right")
                }
            }
        }
    }

    /// The keys, as hidden buttons: SwiftUI routes a hardware keyboard's
    /// chords to them from anywhere in the window, the terminal included.
    private var shortcuts: some View {
        VStack {
            Button("Go to…") { showingPalette = true }.keyboardShortcut("k", modifiers: .command)
            Button("Today") { workspace.selection = .today }.keyboardShortcut("0", modifiers: .command)
            Button("Close tab") {
                if let t = workspace.current { workspace.close(t) }
                else if let w = workspace.currentWeb { workspace.close(w) }
            }
                .keyboardShortcut("w", modifiers: .command)
            Button("Next tab") { workspace.cycle(by: 1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous tab") { workspace.cycle(by: -1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Note") { panel(.note) }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Monitor") { panel(.monitor) }.keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Files") { panel(.files) }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Git") { panel(.git) }.keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Refresh") { model.refreshAll() }.keyboardShortcut("r", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Show a panel; the same chord again hides it.
    private func panel(_ which: PadTools.Panel) {
        if showingNote && tools.panel == which {
            showingNote = false
        } else {
            tools.showPanel(which)
            showingNote = true
        }
    }

    private func pick(_ item: PaletteItem) {
        showingPalette = false
        switch item {
        case .today:
            workspace.selection = .today
        case .web(let url):
            workspace.openWeb(url)
        case .session(let session, let host), .newSession(let session, let host):
            workspace.open(session, on: host, using: model.phone.transport)
            if case .newSession = item {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.refresh(host) }
            }
        }
    }
}

// MARK: - Sidebar

struct PadSidebar: View {
    @ObservedObject var model: PadModel
    @ObservedObject var workspace: PadWorkspace
    @ObservedObject private var notes = SessionNotesStore.shared
    let accent: Color
    @State private var newSessionHost: PadHost?
    @State private var newSessionName = ""

    var body: some View {
        List {
            Section {
                row(title: "Today", detail: model.phone.syncStatusLine, symbol: "sun.max",
                    selected: workspace.selection == .today) {
                    workspace.selection = .today
                }
            }
            ForEach(model.hosts) { host in
                Section {
                    hostContent(host)
                } header: {
                    HStack {
                        Text(host.label.uppercased()).monitorFont(size: 10, weight: .medium)
                        Spacer()
                        if host.route != nil {
                            Button(action: { newSessionName = ""; newSessionHost = host }) {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("New session on \(host.label)")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .refreshable { model.refreshAll() }
        .alert("New session", isPresented: Binding(get: { newSessionHost != nil },
                                                    set: { if !$0 { newSessionHost = nil } })) {
            TextField("name", text: $newSessionName)
            Button("Open") {
                if let host = newSessionHost, let session = model.newSession(named: newSessionName, on: host) {
                    workspace.open(session, on: host, using: model.phone.transport)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.refresh(host) }
                }
                newSessionHost = nil
            }
            Button("Cancel", role: .cancel) { newSessionHost = nil }
        } message: {
            Text("A tmux session on \(newSessionHost?.label ?? "the host"). Letters, digits, - and _.")
        }
    }

    @ViewBuilder private func hostContent(_ host: PadHost) -> some View {
        switch model.listings[host.id] ?? .unknown {
        case .unknown, .loading:
            Text("Listing sessions…").monitorFont(size: 11).foregroundColor(.gray)
        case .notSetUp:
            Text("Not set up for iPad. On your Mac: Settings → Shared state → Set up every host for iPad.")
                .monitorFont(size: 10).foregroundColor(Color.onyxAmber.opacity(0.8))
        case .failed(let why):
            Button(action: { model.refresh(host) }) {
                Text("Can't list sessions: \(why). Tap to try again.")
                    .monitorFont(size: 10).foregroundColor(Color.onyxRed.opacity(0.85))
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
        case .listed(let sessions):
            if sessions.isEmpty {
                Text("No tmux sessions. + starts one.").monitorFont(size: 11).foregroundColor(.gray)
            }
            ForEach(sessions) { session in
                row(title: session.name, detail: detail(for: session), symbol: "terminal",
                    selected: workspace.current?.session.id == session.id) {
                    workspace.open(session, on: host, using: model.phone.transport)
                }
            }
        }
    }

    private func detail(for session: TmuxSession) -> String? {
        if let note = notes.note(for: session.id)?.text, !note.isEmpty {
            return note.components(separatedBy: "\n").first
        }
        guard let when = model.activity[session.id] else { return nil }
        return "active " + RelativeDateTimeFormatter().localizedString(for: when, relativeTo: Date())
    }

    private func row(title: String, detail: String?, symbol: String, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .foregroundColor(selected ? accent : .gray)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).monitorFont(size: 13, weight: selected ? .medium : .regular)
                        .foregroundColor(.white.opacity(selected ? 1 : 0.85))
                    if let detail {
                        Text(detail).monitorFont(size: 10).foregroundColor(.gray).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? accent.opacity(0.15) : Color.clear)
    }
}

// MARK: - Tabs

struct PadTabStrip: View {
    @ObservedObject var workspace: PadWorkspace
    let accent: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tab(title: "Today", selected: workspace.selection == .today, close: nil) {
                    workspace.selection = .today
                }
                ForEach(workspace.terminals) { terminal in
                    PadTab(terminal: terminal, selected: workspace.selection == .terminal(terminal.id),
                           accent: accent,
                           select: { workspace.selection = .terminal(terminal.id) },
                           close: { workspace.close(terminal) })
                }
                ForEach(workspace.webTabs) { tab in
                    PadWebTabLabel(tab: tab, selected: workspace.selection == .web(tab.id), accent: accent,
                                   select: { workspace.selection = .web(tab.id) },
                                   close: { workspace.close(tab) })
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color.white.opacity(0.04))
    }

    private func tab(title: String, selected: Bool, close: (() -> Void)?, select: @escaping () -> Void) -> some View {
        Button(action: select) {
            Text(title).monitorFont(size: 11, weight: selected ? .medium : .regular)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? accent.opacity(0.2) : Color.white.opacity(0.05))
                .foregroundColor(selected ? .white : .gray)
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }
}

struct PadTab: View {
    @ObservedObject var terminal: PadTerminal
    let selected: Bool
    let accent: Color
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text("\(terminal.session.name) · \(terminal.host.label)")
                .monitorFont(size: 11, weight: selected ? .medium : .regular)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(terminal.session.name)")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(selected ? accent.opacity(0.2) : Color.white.opacity(0.05))
        .foregroundColor(selected ? .white : .gray)
        .cornerRadius(5)
        .onTapGesture(perform: select)
    }

    private var dot: Color {
        switch terminal.state {
        case .connecting: return Color.onyxAmber
        case .live: return Color.onyxGreen
        case .ended: return Color.gray
        }
    }
}

struct PadWebTabLabel: View {
    @ObservedObject var tab: PadWebTab
    let selected: Bool
    let accent: Color
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe").font(.system(size: 9))
            Text(tab.label).monitorFont(size: 11, weight: selected ? .medium : .regular).lineLimit(1)
                .frame(maxWidth: 180)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(tab.label)")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(selected ? accent.opacity(0.2) : Color.white.opacity(0.05))
        .foregroundColor(selected ? .white : .gray)
        .cornerRadius(5)
        .onTapGesture(perform: select)
    }
}

// MARK: - The terminal

struct PadTerminalScreen: View {
    @ObservedObject var terminal: PadTerminal
    let accent: Color
    let reconnect: () -> Void

    var body: some View {
        ZStack {
            Color.black
            PadTerminalView(terminal: terminal, fontSize: 13)
            if terminal.state == .connecting {
                Text("Attaching to \(terminal.session.name) on \(terminal.host.label)…")
                    .monitorFont(size: 12).foregroundColor(.gray)
                    .allowsHitTesting(false)
            }
            if case .ended(let why) = terminal.state {
                VStack(spacing: 12) {
                    Text(why).monitorFont(size: 12).foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                    Button("Reattach", action: reconnect)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(20)
                .background(Color.black.opacity(0.85))
                .cornerRadius(10)
                .frame(maxWidth: 460)
            }
        }
    }
}

// MARK: - The note

/// The session's note, the same one the Macs show (SessionNotesStore,
/// shared through the home host).
struct PadNoteEditor: View {
    let session: TmuxSession
    let accent: Color
    @State private var text = ""
    @State private var loadedFor: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTE — \(session.name.uppercased())")
                .monitorFont(size: 10, weight: .medium)
                .foregroundColor(accent)
                .tracking(1.5)
            TextEditor(text: $text)
                .monitorFont(size: 12)
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.05))
                .cornerRadius(6)
            Text("Shared with your Macs through the home host.")
                .monitorFont(size: 9).foregroundColor(.gray)
        }
        .padding(12)
        .onAppear(perform: load)
        .onChange(of: session.id) { _, _ in load() }
        .onChange(of: text) { _, next in
            guard loadedFor == session.id else { return }
            SessionNotesStore.shared.setNote(next, for: session.id)
        }
    }

    private func load() {
        loadedFor = nil
        text = SessionNotesStore.shared.note(for: session.id)?.text ?? ""
        DispatchQueue.main.async { loadedFor = session.id }
    }
}

// MARK: - ⌘K

struct PadPalette: View {
    @ObservedObject var model: PadModel
    let accent: Color
    let pick: (PaletteItem) -> Void
    @State private var query = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var items: [PaletteItem] { model.paletteItems(query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Go to a session, name a new one, or type an address", text: $query)
                .monitorFont(size: 14)
                .focused($focused)
                .onSubmit { if let first = items.first { pick(first) } }
                .padding(14)
                .codeEntry()
            Divider()
            List(items) { item in
                Button(action: { pick(item) }) {
                    HStack {
                        Image(systemName: symbol(item)).foregroundColor(accent).frame(width: 18)
                        Text(item.title).monitorFont(size: 12)
                        Spacer()
                        if item == items.first {
                            Text("↩").monitorFont(size: 11).foregroundColor(.gray)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .onAppear { focused = true }
        .presentationDetents([.medium, .large])
        .background(shortcuts)
    }

    private var shortcuts: some View {
        Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
    }

    private func symbol(_ item: PaletteItem) -> String {
        switch item {
        case .today: return "sun.max"
        case .session: return "terminal"
        case .newSession: return "plus.rectangle"
        case .web: return "globe"
        }
    }
}
