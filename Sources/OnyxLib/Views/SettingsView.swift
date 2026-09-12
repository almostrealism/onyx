import SwiftUI
import AppKit
import EventKit

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @FocusState private var focusedField: Field?
    @StateObject private var remindersManager = RemindersManager()
    @State private var editingHostID: UUID?

    // Numeric font-size inputs are staged in local @State so the
    // TextField text is never rewritten *while* the user is typing.
    // The model is updated (and clamped) only on Save — so deleting a
    // digit en route to a new value doesn't snap to the minimum
    // mid-edit. Initialized on appear and reset on save.
    @State private var terminalFontSizeText: String = ""
    @State private var uiFontSizeText: String = ""

    enum Field: Hashable {
        case host, user, port, tmux, identity, label, fontSize, opacity, windowTitle
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture {
                    appState.showSettings = false
                }

            VStack(spacing: 24) {
                Text("SETTINGS")
                    .font(.system(size: 24, weight: .ultraLight, design: .monospaced))
                    .foregroundColor(Color.onyxBlue)
                    .tracking(8)

                ScrollView {
                    VStack(spacing: 20) {
                        // Hosts section
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                SectionHeader(title: "HOSTS")
                                Spacer()
                                Button(action: addHost) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 9))
                                        Text("Add Host")
                                            .font(.system(size: 10, design: .monospaced))
                                    }
                                    .foregroundColor(appState.accentColor)
                                }
                                .buttonStyle(.plain)
                            }

                            ForEach(appState.hosts) { host in
                                HostRow(
                                    host: host,
                                    appState: appState,
                                    isEditing: editingHostID == host.id,
                                    onToggleEdit: {
                                        editingHostID = editingHostID == host.id ? nil : host.id
                                    },
                                    onDelete: {
                                        appState.removeHost(host.id)
                                        if editingHostID == host.id { editingHostID = nil }
                                    }
                                )
                            }
                        }

                        // Appearance section
                        VStack(alignment: .leading, spacing: 4) {
                            SectionHeader(title: "APPEARANCE")

                            VStack(spacing: 10) {
                                OnyxTextField(label: "Window title", text: $appState.appearance.windowTitle, placeholder: "Onyx")
                                    .focused($focusedField, equals: .windowTitle)

                                // Terminal font
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("TERMINAL FONT")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundColor(Color.onyxBlue.opacity(0.7))
                                        .tracking(2)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 6) {
                                            ForEach(availableMonoFonts, id: \.self) { fontName in
                                                let selected = appState.appearance.terminalFontName == fontName
                                                Button(action: { appState.appearance.terminalFontName = fontName }) {
                                                    Text(fontName)
                                                        .font(.system(size: 11, design: .monospaced))
                                                        .foregroundColor(selected ? .white : .gray.opacity(0.5))
                                                        .padding(.horizontal, 10)
                                                        .padding(.vertical, 4)
                                                        .background(selected ? Color(hex: appState.appearance.accentHex).opacity(0.3) : Color.white.opacity(0.06))
                                                        .cornerRadius(4)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }

                                HStack(spacing: 12) {
                                    OnyxTextField(label: "Terminal font size", text: $terminalFontSizeText, placeholder: "13")
                                        .focused($focusedField, equals: .fontSize)
                                        .frame(width: 130)

                                    OnyxTextField(label: "UI font size", text: $uiFontSizeText, placeholder: "12")
                                        .frame(width: 130)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("WINDOW OPACITY")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundColor(Color.onyxBlue.opacity(0.7))
                                        .tracking(2)

                                    HStack(spacing: 12) {
                                        Slider(value: $appState.appearance.windowOpacity, in: 0.3...1.0, step: 0.05)
                                            .tint(Color.onyxBlue)

                                        Text("\(Int(appState.appearance.windowOpacity * 100))%")
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(.gray)
                                            .frame(width: 40)
                                    }
                                }

                                // Accent color picker
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("DEFAULT ACCENT")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundColor(Color.onyxBlue.opacity(0.7))
                                        .tracking(2)

                                    HStack(spacing: 8) {
                                        ForEach(AppearanceConfig.accentOptions, id: \.self) { hex in
                                            Circle()
                                                .fill(Color(hex: hex))
                                                .frame(width: 24, height: 24)
                                                .overlay(
                                                    Circle()
                                                        .stroke(Color.white, lineWidth: appState.appearance.accentHex == hex ? 2 : 0)
                                                )
                                                .onTapGesture {
                                                    appState.appearance.accentHex = hex
                                                }
                                        }
                                    }
                                }

                                // Per-window accent color
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("WINDOW \(appState.windowIndex + 1) ACCENT")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundColor(Color.onyxBlue.opacity(0.7))
                                        .tracking(2)

                                    HStack(spacing: 8) {
                                        // "Default" option — removes per-window override
                                        Circle()
                                            .fill(Color(hex: appState.appearance.accentHex))
                                            .frame(width: 24, height: 24)
                                            .overlay(
                                                Circle()
                                                    .stroke(Color.white, lineWidth: appState.appearance.windowAccents[appState.windowIndex] == nil ? 2 : 0)
                                            )
                                            .overlay(
                                                Text("D")
                                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                                    .foregroundColor(.white.opacity(0.7))
                                            )
                                            .onTapGesture {
                                                appState.appearance.windowAccents.removeValue(forKey: appState.windowIndex)
                                            }

                                        ForEach(AppearanceConfig.accentOptions, id: \.self) { hex in
                                            Circle()
                                                .fill(Color(hex: hex))
                                                .frame(width: 24, height: 24)
                                                .overlay(
                                                    Circle()
                                                        .stroke(Color.white, lineWidth: appState.appearance.windowAccents[appState.windowIndex] == hex ? 2 : 0)
                                                )
                                                .onTapGesture {
                                                    appState.appearance.windowAccents[appState.windowIndex] = hex
                                                }
                                        }
                                    }
                                }

                                // Extra timezone clocks
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("EXTRA CLOCKS")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundColor(Color.onyxBlue.opacity(0.7))
                                        .tracking(2)

                                    ForEach(0..<3, id: \.self) { i in
                                        TimezoneField(
                                            index: i,
                                            appState: appState,
                                            accentColor: Color(hex: appState.appearance.accentHex)
                                        )
                                    }

                                    Toggle(isOn: Binding(
                                        get: { appState.appearance.use12HourClock },
                                        set: {
                                            appState.appearance.use12HourClock = $0
                                            appState.saveAppearance()
                                        }
                                    )) {
                                        Text("12-hour clock (AM/PM)")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.8))
                                    }
                                    .toggleStyle(.switch)

                                    Text("UTC always stays 24-hour. Also on P in the monitor overlay.")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.gray.opacity(0.4))
                                }

                                // Monitor: container visibility
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("MONITOR")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundColor(Color.onyxBlue.opacity(0.7))
                                        .tracking(2)

                                    Toggle(isOn: Binding(
                                        get: { appState.appearance.showAllContainers },
                                        set: {
                                            appState.appearance.showAllContainers = $0
                                            appState.saveAppearance()
                                        }
                                    )) {
                                        Text("Show every docker container")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.8))
                                    }
                                    .toggleStyle(.switch)

                                    Text("Off, the monitor lists only containers that have used CPU in the last five minutes, so a host running thirty idle containers stays readable. Also on C in the monitor overlay.")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.gray.opacity(0.4))
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                // Menu bar item
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("MENU BAR")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundColor(Color.onyxBlue.opacity(0.7))
                                        .tracking(2)

                                    Toggle(isOn: Binding(
                                        get: { appState.appearance.showMenuBarItem },
                                        set: {
                                            appState.appearance.showMenuBarItem = $0
                                            appState.saveAppearance()
                                            MenuBarController.shared.setEnabled($0)
                                        }
                                    )) {
                                        Text("Show sessions in the menu bar")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.8))
                                    }
                                    .toggleStyle(.switch)

                                    Text("Lists the sessions that have notes and shows which of them an agent has alerted you about, with the alert text right in the menu. This is how you find out which session is bouncing the dock without switching to Onyx.")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.gray.opacity(0.4))
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                // Claude Code permission gating
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("CLAUDE CODE HOOKS")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundColor(Color.onyxBlue.opacity(0.7))
                                        .tracking(2)

                                    Toggle(isOn: Binding(
                                        get: { appState.appearance.claudeHooksGatePermissions },
                                        set: {
                                            appState.appearance.claudeHooksGatePermissions = $0
                                            appState.syncClaudeGatePermissions()
                                        }
                                    )) {
                                        Text("Approve tool calls in Onyx UI")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.8))
                                    }
                                    .toggleStyle(.switch)

                                    Text("When on, Claude shows a banner in Onyx instead of the terminal prompt when it needs permission for a tool call. Only tools that your Claude settings require approval for are affected — auto-allowed tools pass through untouched. Requires the bridge installed via ⌘K → 'Install Onyx MCP'.")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.gray.opacity(0.4))
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                // Debug: focus outline visualization
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("DEBUG")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundColor(Color.onyxBlue.opacity(0.7))
                                        .tracking(2)

                                    Toggle(isOn: Binding(
                                        get: { appState.appearance.showFocusOutline },
                                        set: { appState.appearance.showFocusOutline = $0 }
                                    )) {
                                        Text("Show keyboard focus outline")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.8))
                                    }
                                    .toggleStyle(.switch)

                                    Text("Draws an orange outline around whichever component currently holds keyboard focus (terminal, right panel, overlay). Useful when investigating focus-routing issues; leave off otherwise.")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.gray.opacity(0.4))
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                // Reminders list picker
                                if remindersManager.accessGranted {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("REMINDERS LISTS")
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            .foregroundColor(Color.onyxBlue.opacity(0.7))
                                            .tracking(2)

                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 6) {
                                                let isToday = appState.appearance.remindersLists.isEmpty
                                                Button(action: { appState.appearance.remindersLists = [] }) {
                                                    Text("Today")
                                                        .font(.system(size: 11, design: .monospaced))
                                                        .foregroundColor(isToday ? .white : .gray.opacity(0.5))
                                                        .padding(.horizontal, 10)
                                                        .padding(.vertical, 4)
                                                        .background(isToday ? Color(hex: appState.appearance.accentHex).opacity(0.3) : Color.white.opacity(0.06))
                                                        .cornerRadius(4)
                                                }
                                                .buttonStyle(.plain)

                                                ForEach(remindersManager.availableLists, id: \.self) { list in
                                                    let selected = appState.appearance.remindersLists.contains(list)
                                                    Button(action: {
                                                        if selected {
                                                            appState.appearance.remindersLists.removeAll { $0 == list }
                                                        } else {
                                                            appState.appearance.remindersLists.append(list)
                                                        }
                                                    }) {
                                                        Text(list)
                                                            .font(.system(size: 11, design: .monospaced))
                                                            .foregroundColor(selected ? .white : .gray.opacity(0.5))
                                                            .padding(.horizontal, 10)
                                                            .padding(.vertical, 4)
                                                            .background(selected ? Color(hex: appState.appearance.accentHex).opacity(0.3) : Color.white.opacity(0.06))
                                                            .cornerRadius(4)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                                // Timing.app API token
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("TIMING.APP")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundColor(Color.onyxBlue.opacity(0.7))
                                        .tracking(2)

                                    HStack(spacing: 8) {
                                        SecureField("API token from web.timingapp.com", text: Binding(
                                            get: { appState.timing.apiToken },
                                            set: { appState.timing.apiToken = $0 }
                                        ))
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.8))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.white.opacity(0.06))
                                        .cornerRadius(3)

                                        if appState.timing.isConfigured {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 12))
                                                .foregroundColor(Color.onyxGreen)
                                        }
                                    }

                                    Text("Get token at web.timingapp.com/integrations/tokens")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.gray.opacity(0.3))

                                    // Project filter
                                    if appState.timing.isConfigured && !appState.timing.availableProjects.isEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("FILTER PROJECT")
                                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                                .foregroundColor(.gray.opacity(0.5))
                                                .tracking(1)

                                            ScrollView(.horizontal, showsIndicators: false) {
                                                HStack(spacing: 6) {
                                                    // "All" option
                                                    let isAll = appState.timing.filterProjectID.isEmpty
                                                    Button(action: { appState.timing.filterProjectID = "" }) {
                                                        Text("All")
                                                            .font(.system(size: 10, design: .monospaced))
                                                            .foregroundColor(isAll ? .white : .gray.opacity(0.5))
                                                            .padding(.horizontal, 8)
                                                            .padding(.vertical, 3)
                                                            .background(isAll ? Color(hex: appState.appearance.accentHex).opacity(0.3) : Color.white.opacity(0.06))
                                                            .cornerRadius(3)
                                                    }
                                                    .buttonStyle(.plain)

                                                    // Top-level projects only
                                                    ForEach(appState.timing.availableProjects.filter { $0.depth == 0 }) { proj in
                                                        let selected = appState.timing.filterProjectID == proj.id
                                                        Button(action: { appState.timing.filterProjectID = proj.id }) {
                                                            HStack(spacing: 3) {
                                                                Circle()
                                                                    .fill(Color(hex: proj.color))
                                                                    .frame(width: 6, height: 6)
                                                                Text(proj.title)
                                                                    .font(.system(size: 10, design: .monospaced))
                                                            }
                                                            .foregroundColor(selected ? .white : .gray.opacity(0.5))
                                                            .padding(.horizontal, 8)
                                                            .padding(.vertical, 3)
                                                            .background(selected ? Color(hex: appState.appearance.accentHex).opacity(0.3) : Color.white.opacity(0.06))
                                                            .cornerRadius(3)
                                                        }
                                                        .buttonStyle(.plain)
                                                    }
                                                }
                                            }
                                        }
                                        .padding(.top, 4)
                                    }
                                }
                        }

                        SharedStateSettingsSection(appState: appState)

                        SearchFilterSettingsSection(appState: appState)

                        // Applies to the merged GitHub + GitLab list, so
                        // it sits above both rather than inside either.
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PULL REQUESTS")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(Color.onyxBlue.opacity(0.7))
                                .tracking(2)

                            Picker("", selection: Binding(
                                get: { appState.appearance.prDraftFilter },
                                set: {
                                    appState.appearance.prDraftFilter = $0
                                    appState.saveAppearance()
                                }
                            )) {
                                ForEach(PRDraftFilter.allCases, id: \.self) { f in
                                    Text(f.label).tag(f)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Text("A PR counts as a draft if the forge says so, or if its title starts with \"Draft:\", \"WIP:\" or \"[draft]\" — some teams mark drafts by convention on a PR the API considers ready.")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.gray.opacity(0.4))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        GitHubSettingsSection()
                        GitLabSettingsSection()
                        FlowtreeSettingsSection()
                        PageWatchSettingsSection()
                    }
                }
                .frame(maxHeight: 500)

                HStack(spacing: 12) {
                    Button(action: { appState.showSettings = false }) {
                        Text("Cancel")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.gray)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])

                    Button(action: save) {
                        Text("Save")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                            .background(Color(hex: appState.appearance.accentHex))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(40)
            .frame(maxWidth: 500)
            .background(Color(nsColor: NSColor(white: 0.06, alpha: 0.98)))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30)
        }
        .onAppear { loadFontSizeText() }
    }

    /// Seed local font-size text from the model. Called on view appear so
    /// re-opening Settings shows the current saved values.
    fileprivate func loadFontSizeText() {
        terminalFontSizeText = String(Int(appState.appearance.effectiveTerminalFontSize))
        uiFontSizeText = String(Int(appState.appearance.uiFontSize))
    }

    /// Parse a font-size text field, clamping to a sensible range. Returns
    /// nil if the input doesn't parse — caller keeps the existing value.
    /// Range is [8, 64]: 8 matches the prior minimum; 64 is a high cap so a
    /// fat-finger on `144` doesn't blow up the UI.
    static func parsedFontSize(_ text: String) -> Double? {
        guard let n = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Double(min(64, max(8, n)))
    }

    /// Monospaced fonts that are actually installed on this system
    private var availableMonoFonts: [String] {
        AppearanceConfig.terminalFontOptions.filter { name in
            NSFont(name: name, size: 13) != nil
        }
    }

    private func addHost() {
        let newHost = HostConfig(label: "New Host", ssh: SSHConfig(host: "", user: "", port: 22, tmuxSession: "onyx"))
        appState.addHost(newHost)
        editingHostID = newHost.id
    }

    private func save() {
        // Commit staged font-size text now (clamped). Empty/garbage input
        // silently keeps the existing value rather than fighting the user
        // mid-edit.
        if let size = Self.parsedFontSize(terminalFontSizeText) {
            appState.appearance.terminalFontSize = size
        }
        if let size = Self.parsedFontSize(uiFontSizeText) {
            appState.appearance.uiFontSize = size
        }
        appState.saveHosts()
        appState.saveAppearance()
        appState.showSettings = false
        // Re-enumerate sessions so new/changed hosts are probed for key setup
        appState.refreshSessionList = true
    }
}

// MARK: - Host Row

private struct HostRow: View {
    let host: HostConfig
    @ObservedObject var appState: AppState
    let isEditing: Bool
    let onToggleEdit: () -> Void
    let onDelete: () -> Void

    @State private var label: String = ""
    @State private var sshHost: String = ""
    @State private var user: String = ""
    @State private var port: String = ""
    @State private var tmuxSession: String = ""
    @State private var identityFile: String = ""
    @State private var codeIntelEnabled: Bool = true
    @State private var jdtlsPath: String = ""
    @State private var heapMB: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Summary row
            HStack(spacing: 8) {
                Image(systemName: host.isLocal ? "desktopcomputer" : "network")
                    .font(.system(size: 11))
                    .foregroundColor(appState.accentColor.opacity(0.6))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(host.label)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(host.paused ? 0.5 : 0.9))

                        if host.paused {
                            Text("PAUSED")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(Color.onyxAmber)
                                .tracking(1)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.onyxAmber.opacity(0.15))
                                .cornerRadius(3)
                        }
                    }

                    if host.id != HostConfig.localhostID {
                        let display = host.ssh.user.isEmpty ? host.ssh.host : "\(host.ssh.user)@\(host.ssh.host)"
                        Text(display.isEmpty ? "not configured" : display)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.4))
                    }
                }

                Spacer()

                // Pause / resume. Deliberately on the summary row, not
                // buried in the edit form — it's the control you reach for
                // when a host is misbehaving right now.
                if host.id != HostConfig.localhostID {
                    Button(action: { appState.setHostPaused(host.id, paused: !host.paused) }) {
                        Image(systemName: host.paused ? "play.circle" : "pause.circle")
                            .font(.system(size: 14))
                            .foregroundColor(host.paused ? Color.onyxAmber : .gray.opacity(0.5))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(host.paused
                          ? "Resume \(host.label) — Onyx will reconnect"
                          : "Pause \(host.label) — stop all connection attempts, keep everything else")
                }

                if host.id != HostConfig.localhostID {
                    Button(action: onToggleEdit) {
                        Image(systemName: isEditing ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                            .foregroundColor(.gray.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                if host.id != HostConfig.localhostID { onToggleEdit() }
            }

            // Expanded edit form
            if isEditing && host.id != HostConfig.localhostID {
                VStack(spacing: 8) {
                    OnyxTextField(label: "Label", text: $label, placeholder: "My Server")
                    OnyxTextField(label: "Host", text: $sshHost, placeholder: "192.168.1.100")
                    OnyxTextField(label: "User", text: $user, placeholder: "root")

                    HStack(spacing: 12) {
                        OnyxTextField(label: "Port", text: $port, placeholder: "22")
                            .frame(width: 80)
                        OnyxTextField(label: "tmux session", text: $tmuxSession, placeholder: "onyx")
                    }

                    OnyxTextField(label: "Identity file", text: $identityFile, placeholder: "~/.ssh/id_ed25519")

                    codeIntelFields

                    HStack {
                        Spacer()
                        Button(action: onDelete) {
                            Text("Remove")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color.onyxRed)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .onAppear {
                    label = host.label
                    sshHost = host.ssh.host
                    user = host.ssh.user
                    port = String(host.ssh.port)
                    tmuxSession = host.ssh.tmuxSession
                    identityFile = host.ssh.identityFile
                    codeIntelEnabled = host.codeIntel.enabled
                    jdtlsPath = host.codeIntel.jdtlsPath
                    heapMB = String(host.codeIntel.heapMB)
                }
                .onChange(of: label) { _, v in updateHost { $0.label = v } }
                .onChange(of: sshHost) { _, v in updateHost { $0.ssh.host = v } }
                .onChange(of: user) { _, v in updateHost { $0.ssh.user = v } }
                .onChange(of: port) { _, v in updateHost { $0.ssh.port = Int(v) ?? 22 } }
                .onChange(of: tmuxSession) { _, v in updateHost { $0.ssh.tmuxSession = v } }
                .onChange(of: identityFile) { _, v in updateHost { $0.ssh.identityFile = v } }
                .onChange(of: codeIntelEnabled) { _, v in updateHost { $0.codeIntel.enabled = v } }
                .onChange(of: jdtlsPath) { _, v in updateHost { $0.codeIntel.jdtlsPath = v } }
                .onChange(of: heapMB) { _, v in updateHost { $0.codeIntel.heapMB = Int(v) ?? 0 } }
            }
        }
        .background(Color.white.opacity(0.04))
        .cornerRadius(6)
    }

    /// Per-host code-intelligence (jdtls) controls — extracted to keep the
    /// edit-form body cheap for the type checker.
    @ViewBuilder
    private var codeIntelFields: some View {
        Divider().background(Color.white.opacity(0.08)).padding(.vertical, 2)
        Toggle(isOn: $codeIntelEnabled) {
            Text("Code intelligence (Java)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
        }
        .toggleStyle(.switch)
        .tint(appState.accentColor)
        if codeIntelEnabled {
            OnyxTextField(label: "jdtls path", text: $jdtlsPath,
                          placeholder: "~/.onyx/jdtls/bin/jdtls")
            OnyxTextField(label: "Max heap (MB, 0 = default)", text: $heapMB, placeholder: "0")
                .frame(width: 200)
        }
    }

    private func updateHost(_ transform: (inout HostConfig) -> Void) {
        var updated = host
        transform(&updated)
        appState.updateHost(updated)
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(.gray.opacity(0.5))
            .tracking(3)
            .padding(.bottom, 4)
    }
}

// MARK: - Timezone Autocomplete Field

private struct TimezoneField: View {
    let index: Int
    @ObservedObject var appState: AppState
    let accentColor: Color

    @State private var query: String = ""
    @State private var showSuggestions = false
    @State private var initialized = false

    /// All known timezone IDs with friendly labels for searching
    private static let allTimezones: [(id: String, label: String)] = {
        TimeZone.knownTimeZoneIdentifiers.sorted().map { id in
            let city = id.split(separator: "/").last.map(String.init) ?? id
            let display = city.replacingOccurrences(of: "_", with: " ")
            let abbrev = TimeZone(identifier: id)?.abbreviation() ?? ""
            return (id: id, label: "\(display) (\(abbrev)) — \(id)")
        }
    }()

    private var suggestions: [(id: String, label: String)] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        return Self.allTimezones.filter { $0.label.lowercased().contains(q) }.prefix(8).map { $0 }
    }

    private var currentValue: String {
        index < appState.appearance.extraTimezones.count ? appState.appearance.extraTimezones[index] : ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(index + 1).")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.4))
                    .frame(width: 16)

                TextField("Type city or region...", text: $query, onEditingChanged: { editing in
                    showSuggestions = editing
                })
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.06))
                .cornerRadius(3)
                .onAppear {
                    if !initialized {
                        query = currentValue
                        initialized = true
                    }
                }
                .onChange(of: query) { _, newValue in
                    // If the user typed something that exactly matches an ID, commit it
                    if TimeZone(identifier: newValue) != nil {
                        commitTimezone(newValue)
                    }
                }

                // Clear button
                if !query.isEmpty {
                    Button(action: {
                        query = ""
                        commitTimezone("")
                        showSuggestions = false
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.gray.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Suggestions dropdown
            if showSuggestions && !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.id) { tz in
                        Button(action: {
                            query = tz.id
                            commitTimezone(tz.id)
                            showSuggestions = false
                        }) {
                            Text(tz.label)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.04))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color(nsColor: NSColor(white: 0.1, alpha: 1.0)))
                .cornerRadius(4)
                .padding(.leading, 24) // align with text field
            }
        }
    }

    private func commitTimezone(_ value: String) {
        while appState.appearance.extraTimezones.count <= index {
            appState.appearance.extraTimezones.append("")
        }
        appState.appearance.extraTimezones[index] = value
        // Remove trailing empty entries
        while appState.appearance.extraTimezones.last?.isEmpty == true {
            appState.appearance.extraTimezones.removeLast()
        }
    }
}

/// Flowtree controller settings — endpoint URL + optional Cloudflare Access
/// service-token (client id/secret). Once a URL is set, reminders can be
/// submitted to a workstream from the monitor overlay.
private struct FlowtreeSettingsSection: View {
    @ObservedObject private var config = FlowtreeConfigStore.shared

    private func field(_ placeholder: String, get: @escaping () -> String, set: @escaping (String) -> Void, secure: Bool = false) -> some View {
        let binding = Binding(get: get, set: set).sanitizingStylizedText()
        return Group {
            if secure {
                SecureField(placeholder, text: binding)
            } else {
                TextField(placeholder, text: binding)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.white.opacity(0.8))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.06))
        .cornerRadius(3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FLOWTREE")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Color.onyxBlue.opacity(0.7))
                .tracking(2)

            HStack(spacing: 8) {
                field("Controller URL (e.g. https://flowtree.example.com)",
                      get: { config.controllerURL }, set: { config.controllerURL = $0 })
                if config.isConfigured {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color.onyxGreen)
                }
            }

            Text("Cloudflare Access service token — optional; needed for the cloud instance, not for a local one")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.gray.opacity(0.3))
                .padding(.top, 6)

            field("CF-Access-Client-Id",
                  get: { config.clientId }, set: { config.clientId = $0 })
            field("CF-Access-Client-Secret",
                  get: { config.clientSecret }, set: { config.clientSecret = $0 }, secure: true)
        }
    }
}

/// GitHub PR watch settings — token + repo URLs. Styled to match the
/// Timing.app block above.
private struct GitHubSettingsSection: View {
    /// "Watching 2 repos + 1 owner" — an owner entry stands for however
    /// many repos it turns out to have, so counting them as repos would
    /// be wrong.
    static func watchSummary(_ specs: [GitHubRepoSpec]) -> String {
        let owners = specs.filter(\.isOwnerWide).count
        let repos = specs.count - owners
        var parts: [String] = []
        if repos > 0 { parts.append("\(repos) repo\(repos == 1 ? "" : "s")") }
        if owners > 0 { parts.append("\(owners) owner\(owners == 1 ? "" : "s")") }
        return "Watching " + (parts.isEmpty ? "nothing" : parts.joined(separator: " + "))
    }

    @ObservedObject private var config = GitHubConfigStore.shared
    @State private var reposText: String = ""
    @State private var hasInitializedText = false
    @State private var pipelinesText: String = ""
    @State private var hasInitializedPipelinesText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GITHUB")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Color.onyxBlue.opacity(0.7))
                .tracking(2)

            HStack(spacing: 8) {
                SecureField("Personal access token (classic — scope: repo)",
                            text: Binding(
                                get: { config.token },
                                set: { config.token = $0 }
                            ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(3)

                if !config.token.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color.onyxGreen)
                }
            }

            Text("Get token at github.com/settings/tokens (classic)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.gray.opacity(0.3))

            Text("REPOS — one per line: owner/repo, or just owner for all of them")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.gray.opacity(0.5))
                .tracking(1)
                .padding(.top, 6)

            TextEditor(text: $reposText.sanitizingStylizedText())
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.white.opacity(0.06))
                .cornerRadius(3)
                .frame(minHeight: 70, maxHeight: 110)
                .onAppear {
                    if !hasInitializedText {
                        reposText = config.repoURLs.joined(separator: "\n")
                        hasInitializedText = true
                    }
                }
                .onChange(of: reposText) { _, newValue in
                    let lines = newValue
                        .split(whereSeparator: \.isNewline)
                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if lines != config.repoURLs {
                        config.repoURLs = lines
                        // Kick a fresh poll so the section repopulates
                        // immediately rather than waiting for the next tick.
                        PullRequestManager.shared.refresh()
                    }
                }

            if !config.parsedRepos.isEmpty {
                Text(Self.watchSummary(config.parsedRepos))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.4))
            }

            MineOnlyToggle(
                isOn: Binding(get: { config.mineOnly },
                              set: { config.mineOnly = $0; PullRequestManager.shared.refresh() }),
                username: config.username
            )

            Text("PIPELINES — one workflow or run URL per line")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.gray.opacity(0.5))
                .tracking(1)
                .padding(.top, 10)

            TextEditor(text: $pipelinesText.sanitizingStylizedText())
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.white.opacity(0.06))
                .cornerRadius(3)
                .frame(minHeight: 70, maxHeight: 110)
                .onAppear {
                    if !hasInitializedPipelinesText {
                        pipelinesText = config.pipelineURLs.joined(separator: "\n")
                        hasInitializedPipelinesText = true
                    }
                }
                .onChange(of: pipelinesText) { _, newValue in
                    let lines = newValue
                        .split(whereSeparator: \.isNewline)
                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if lines != config.pipelineURLs {
                        config.pipelineURLs = lines
                        WorkflowMonitor.shared.refresh()
                    }
                }

            if !config.parsedPipelines.isEmpty {
                Text("Watching \(config.parsedPipelines.count) pipeline\(config.parsedPipelines.count == 1 ? "" : "s")")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.4))
            }
        }
    }
}

/// Compact "only my PRs/MRs" switch with the auto-detected username shown
/// once it's resolved. Shared by the GitHub and GitLab settings sections.
private struct MineOnlyToggle: View {
    @Binding var isOn: Bool
    let username: String

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(username.isEmpty ? "Only mine" : "Only mine (@\(username))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.gray.opacity(0.6))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Color.onyxBlue)
        .padding(.top, 2)
    }
}

private struct SearchFilterSettingsSection: View {
    @ObservedObject var appState: AppState

    private func toggle(_ id: String) {
        var ids = appState.appearance.searchFileTypeIDs
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
        appState.appearance.searchFileTypeIDs = ids
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SEARCH FILTER")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Color.onyxBlue.opacity(0.7))
                .tracking(2)
                .padding(.top, 12)

            Text("Restrict file search to these types (none = all files)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.gray.opacity(0.4))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SearchFileType.presets) { type in
                        let on = appState.appearance.searchFileTypeIDs.contains(type.id)
                        Button(action: { toggle(type.id) }) {
                            Text(type.label)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(on ? .white : .gray.opacity(0.5))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(on ? Color(hex: appState.appearance.accentHex).opacity(0.3)
                                              : Color.white.opacity(0.06))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct GitLabSettingsSection: View {
    /// Only single-segment paths are known to be groups up front; deeper
    /// ones are resolved by asking GitLab, so they're counted as projects
    /// here rather than guessed at.
    static func watchSummary(_ specs: [GitLabProjectSpec]) -> String {
        let groups = specs.filter(\.isDefinitelyGroup).count
        let projects = specs.count - groups
        var parts: [String] = []
        if projects > 0 { parts.append("\(projects) project\(projects == 1 ? "" : "s")") }
        if groups > 0 { parts.append("\(groups) group\(groups == 1 ? "" : "s")") }
        return "Watching " + (parts.isEmpty ? "nothing" : parts.joined(separator: " + "))
    }

    @ObservedObject private var config = GitLabConfigStore.shared
    @State private var projectsText: String = ""
    @State private var hasInitializedProjects = false
    @State private var pipelinesText: String = ""
    @State private var hasInitializedPipelines = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GITLAB")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Color(hex: "FC6D26").opacity(0.85))
                .tracking(2)
                .padding(.top, 12)

            HStack(spacing: 8) {
                SecureField("Personal access token (scope: read_api)",
                            text: Binding(
                                get: { config.token },
                                set: { config.token = $0 }
                            ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(3)

                if !config.token.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color.onyxGreen)
                }
            }

            Text("Get token at gitlab.com/-/user_settings/personal_access_tokens")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.gray.opacity(0.3))

            Text("PROJECTS — one per line: group/project, or a group for everything under it")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.gray.opacity(0.5))
                .tracking(1)
                .padding(.top, 6)

            TextEditor(text: $projectsText.sanitizingStylizedText())
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.white.opacity(0.06))
                .cornerRadius(3)
                .frame(minHeight: 70, maxHeight: 110)
                .onAppear {
                    if !hasInitializedProjects {
                        projectsText = config.projectURLs.joined(separator: "\n")
                        hasInitializedProjects = true
                    }
                }
                .onChange(of: projectsText) { _, newValue in
                    let lines = newValue
                        .split(whereSeparator: \.isNewline)
                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if lines != config.projectURLs {
                        config.projectURLs = lines
                        GitLabMergeRequestManager.shared.refresh()
                    }
                }

            if !config.parsedProjects.isEmpty {
                Text(Self.watchSummary(config.parsedProjects))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.4))
            }

            MineOnlyToggle(
                isOn: Binding(get: { config.mineOnly },
                              set: { config.mineOnly = $0; GitLabMergeRequestManager.shared.refresh() }),
                username: config.username
            )

            Text("PIPELINES — one /-/pipelines/<id> URL per line")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.gray.opacity(0.5))
                .tracking(1)
                .padding(.top, 10)

            TextEditor(text: $pipelinesText.sanitizingStylizedText())
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.white.opacity(0.06))
                .cornerRadius(3)
                .frame(minHeight: 70, maxHeight: 110)
                .onAppear {
                    if !hasInitializedPipelines {
                        pipelinesText = config.pipelineURLs.joined(separator: "\n")
                        hasInitializedPipelines = true
                    }
                }
                .onChange(of: pipelinesText) { _, newValue in
                    let lines = newValue
                        .split(whereSeparator: \.isNewline)
                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if lines != config.pipelineURLs {
                        config.pipelineURLs = lines
                        GitLabPipelineMonitor.shared.refresh()
                    }
                }

            if !config.parsedPipelines.isEmpty {
                Text("Watching \(config.parsedPipelines.count) pipeline\(config.parsedPipelines.count == 1 ? "" : "s")")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.4))
            }
        }
    }
}

// MARK: - Page watches

/// Watch a URL for one specific change.
///
/// Last in the settings list on purpose: almost nobody wants this, and
/// the people who do want it badly. It's the mechanism behind "tell me
/// the moment Apple's configurator stops saying the 512GB option is
/// coming later" — a question no feed or alert service answers precisely,
/// because the signal is a string on a page rather than an article about
/// the page.
private struct PageWatchSettingsSection: View {
    @ObservedObject private var store = PageWatchStore.shared
    @State private var label = ""
    @State private var url = ""
    @State private var text = ""
    @State private var trigger: WatchTrigger = .disappears
    @State private var interval = PageWatch.defaultInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PAGE WATCHES")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Color.onyxBlue.opacity(0.7))
                .tracking(2)

            Text("Polls a page and tells you when one string appears or disappears. Checked while Onyx is running, no more often than every \(PageWatch.minimumInterval) minutes.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.gray.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(store.entries) { entry in
                WatchRow(entry: entry)
            }

            if store.entries.isEmpty {
                Button(action: { store.add(.macStudioUltraMemory()) }) {
                    Text("+ Watch for the 512GB M5 Ultra Mac Studio")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color.onyxBlue.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Apple's configurator carries a footer reading \"512GB memory option for M5 Ultra coming late October\". This watches for that line to disappear, which is when the option goes orderable.")
            }

            Divider().background(Color.white.opacity(0.06)).padding(.vertical, 2)

            watchField("Name", text: $label, placeholder: "What to call it")
            watchField("URL", text: $url, placeholder: "https://…")

            Picker("", selection: $trigger) {
                ForEach(WatchTrigger.allCases, id: \.self) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if trigger.needsText {
                watchField("Text", text: $text, placeholder: "The exact string to look for")
            }

            HStack(spacing: 8) {
                Text("Every")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.5))
                Stepper("\(interval) min", value: $interval,
                        in: PageWatch.minimumInterval...720, step: 5)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))

                Spacer()

                Button(action: addWatch) {
                    Text("Add watch")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(canAdd ? Color.onyxBlue : .gray.opacity(0.3))
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
            }
        }
    }

    private var canAdd: Bool {
        PageWatch(label: label, url: url, trigger: trigger, text: text,
                  intervalMinutes: interval).isRunnable && !label.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func addWatch() {
        guard canAdd else { return }
        store.add(PageWatch(label: label, url: url, trigger: trigger,
                            text: text, intervalMinutes: interval))
        label = ""; url = ""; text = ""
    }

    private func watchField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray.opacity(0.5))
                .frame(width: 34, alignment: .leading)
            TextField(placeholder, text: text.sanitizingStylizedText())
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.06))
                .cornerRadius(3)
        }
    }
}

/// One configured watch: what it's for, what it last saw, and whether
/// it's actually working — a watch that has been 403ing for a week is
/// worse than no watch, so the last check and any error are always shown.
private struct WatchRow: View {
    let entry: WatchEntry
    @ObservedObject private var store = PageWatchStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                Text(entry.watch.label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)

                Spacer()

                Button(action: { PageWatchManager.shared.checkNow(entry.id) }) {
                    Text("check")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color.onyxBlue.opacity(0.7))
                }
                .buttonStyle(.plain)

                Button(action: { store.remove(entry.id) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8))
                        .foregroundColor(.gray.opacity(0.5))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text(status)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(statusColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }

    private var dotColor: Color {
        if entry.state.firedAt != nil { return Color.onyxGreen }
        if entry.state.lastError != nil { return Color.onyxRed }
        if entry.state.lastCheck == nil { return .gray.opacity(0.4) }
        return Color.onyxBlue.opacity(0.6)
    }

    private var statusColor: Color {
        if entry.state.firedAt != nil { return Color.onyxGreen.opacity(0.8) }
        if entry.state.lastError != nil { return Color.onyxRed.opacity(0.7) }
        return .gray.opacity(0.4)
    }

    private var status: String {
        if let fired = entry.state.firedAt {
            return "FIRED \(Self.stamp.string(from: fired)) — \(entry.watch.trigger.label)"
        }
        if let err = entry.state.lastError { return err }
        guard let last = entry.state.lastCheck else {
            return "Not checked yet — the first check only takes a baseline."
        }
        let seen = entry.state.present == true ? "text present" : "text absent"
        return "\(seen) at \(Self.stamp.string(from: last)) · waiting for \(entry.watch.trigger.label)"
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f
    }()
}

// MARK: - Shared state (home host)

/// Where session notes and favourites live.
///
/// The picker is the whole answer to "how do I get my notes on my other
/// Mac": pick a host both machines can reach and they meet in a file in
/// its `~/.onyx/`. Moving between homes MERGES rather than adopting, so
/// this control can't lose anything — which is why it's safe to have as a
/// one-click picker rather than an import/export dance.
private struct SharedStateSettingsSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var sync = SharedStateSync.shared

    /// Local hosts are excluded: "share via this Mac" is what the default
    /// already is, and syncing a file to yourself is a round trip that
    /// achieves nothing.
    private var candidates: [HostConfig] {
        appState.hosts.filter { !$0.isLocal }
    }

    private var homeLabel: String? {
        sync.homeHost(in: appState.hosts)?.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "SHARED STATE")

            Picker("", selection: Binding(
                get: { sync.homeHostID },
                set: { SharedStateSync.shared.setHomeHost($0) }
            )) {
                Text("This Mac only").tag(UUID?.none)
                ForEach(candidates) { host in
                    Text(host.label).tag(UUID?.some(host.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            HStack(spacing: 10) {
                Text(SharedStateSync.statusLine(sync.status, hostLabel: homeLabel,
                                                lastWrittenBy: sync.lastWrittenBy))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(statusColor)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if sync.homeHostID != nil {
                    Button(action: { SharedStateSync.shared.syncNow() }) {
                        Text("Sync now")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(appState.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Session notes and favourite sessions are kept in ~/.onyx/shared-state.json on the chosen host, so every Mac running Onyx sees the same set. Your Mac keeps its own copy and works normally when the host is unreachable. Changing hosts merges the two sets — nothing is replaced or deleted.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.gray.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusColor: Color {
        switch sync.status {
        case .failed:         return Color.onyxRed.opacity(0.8)
        case .waitingForHost: return Color.onyxAmber.opacity(0.7)
        case .synced:         return .gray.opacity(0.6)
        case .syncing:        return appState.accentColor.opacity(0.8)
        case .localOnly:      return .gray.opacity(0.45)
        }
    }
}
