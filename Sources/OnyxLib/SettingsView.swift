import SwiftUI
import AppKit
import EventKit

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @FocusState private var focusedField: Field?
    @StateObject private var remindersManager = RemindersManager()
    @State private var editingHostID: UUID?

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
                    .foregroundColor(Color(hex: "66CCFF"))
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
                                        .foregroundColor(Color(hex: "66CCFF").opacity(0.7))
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
                                    OnyxTextField(label: "Terminal font size", text: terminalFontSizeBinding, placeholder: "13")
                                        .focused($focusedField, equals: .fontSize)
                                        .frame(width: 130)

                                    OnyxTextField(label: "UI font size", text: uiFontSizeBinding, placeholder: "12")
                                        .frame(width: 130)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("WINDOW OPACITY")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundColor(Color(hex: "66CCFF").opacity(0.7))
                                        .tracking(2)

                                    HStack(spacing: 12) {
                                        Slider(value: $appState.appearance.windowOpacity, in: 0.3...1.0, step: 0.05)
                                            .tint(Color(hex: "66CCFF"))

                                        Text("\(Int(appState.appearance.windowOpacity * 100))%")
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(.gray)
                                            .frame(width: 40)
                                    }
                                }

                                // Accent color picker
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("ACCENT COLOR")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundColor(Color(hex: "66CCFF").opacity(0.7))
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

                                // Reminders list picker
                                if remindersManager.accessGranted {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("REMINDERS LIST")
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            .foregroundColor(Color(hex: "66CCFF").opacity(0.7))
                                            .tracking(2)

                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 6) {
                                                let isToday = appState.appearance.remindersList.isEmpty
                                                Button(action: { appState.appearance.remindersList = "" }) {
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
                                                    let selected = appState.appearance.remindersList == list
                                                    Button(action: { appState.appearance.remindersList = list }) {
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
                        }
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
    }

    private var terminalFontSizeBinding: Binding<String> {
        Binding(
            get: { String(Int(appState.appearance.effectiveTerminalFontSize)) },
            set: { appState.appearance.terminalFontSize = Double(Int($0) ?? 13) }
        )
    }

    private var uiFontSizeBinding: Binding<String> {
        Binding(
            get: { String(Int(appState.appearance.uiFontSize)) },
            set: { appState.appearance.uiFontSize = max(8, Double(Int($0) ?? 12)) }
        )
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
        appState.saveHosts()
        appState.saveAppearance()
        appState.showSettings = false
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

    var body: some View {
        VStack(spacing: 0) {
            // Summary row
            HStack(spacing: 8) {
                Image(systemName: host.isLocal ? "desktopcomputer" : "network")
                    .font(.system(size: 11))
                    .foregroundColor(appState.accentColor.opacity(0.6))

                VStack(alignment: .leading, spacing: 1) {
                    Text(host.label)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))

                    if !host.isLocal {
                        let display = host.ssh.user.isEmpty ? host.ssh.host : "\(host.ssh.user)@\(host.ssh.host)"
                        Text(display.isEmpty ? "not configured" : display)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.4))
                    }
                }

                Spacer()

                if !host.isLocal {
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
                if !host.isLocal { onToggleEdit() }
            }

            // Expanded edit form
            if isEditing && !host.isLocal {
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

                    HStack {
                        Spacer()
                        Button(action: onDelete) {
                            Text("Remove")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color(hex: "FF6B6B"))
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
                }
                .onChange(of: label) { _, v in updateHost { $0.label = v } }
                .onChange(of: sshHost) { _, v in updateHost { $0.ssh.host = v } }
                .onChange(of: user) { _, v in updateHost { $0.ssh.user = v } }
                .onChange(of: port) { _, v in updateHost { $0.ssh.port = Int(v) ?? 22 } }
                .onChange(of: tmuxSession) { _, v in updateHost { $0.ssh.tmuxSession = v } }
                .onChange(of: identityFile) { _, v in updateHost { $0.ssh.identityFile = v } }
            }
        }
        .background(Color.white.opacity(0.04))
        .cornerRadius(6)
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
