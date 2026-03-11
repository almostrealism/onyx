import SwiftUI
import EventKit

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @FocusState private var focusedField: Field?
    @StateObject private var remindersManager = RemindersManager()

    enum Field: Hashable {
        case host, user, port, tmux, identity, fontSize, opacity, windowTitle
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

                // Connection section
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeader(title: "CONNECTION")

                    VStack(spacing: 10) {
                        OnyxTextField(label: "Host", text: $appState.sshConfig.host, placeholder: "192.168.1.100")
                            .focused($focusedField, equals: .host)

                        OnyxTextField(label: "User", text: $appState.sshConfig.user, placeholder: "root")
                            .focused($focusedField, equals: .user)

                        HStack(spacing: 12) {
                            OnyxTextField(label: "Port", text: portBinding, placeholder: "22")
                                .focused($focusedField, equals: .port)
                                .frame(width: 100)

                            OnyxTextField(label: "tmux session", text: $appState.sshConfig.tmuxSession, placeholder: "onyx")
                                .focused($focusedField, equals: .tmux)
                        }

                        OnyxTextField(label: "Identity file", text: $appState.sshConfig.identityFile, placeholder: "~/.ssh/id_ed25519")
                            .focused($focusedField, equals: .identity)
                    }
                }

                // Appearance section
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeader(title: "APPEARANCE")

                    VStack(spacing: 10) {
                        OnyxTextField(label: "Window title", text: $appState.appearance.windowTitle, placeholder: "Onyx")
                            .focused($focusedField, equals: .windowTitle)

                        OnyxTextField(label: "Font size", text: fontSizeBinding, placeholder: "13")
                            .focused($focusedField, equals: .fontSize)
                            .frame(width: 100)

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

                                HStack(spacing: 6) {
                                    let isAll = appState.appearance.remindersList.isEmpty
                                    Button(action: { appState.appearance.remindersList = "" }) {
                                        Text("All")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(isAll ? .white : .gray.opacity(0.5))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(isAll ? Color(hex: appState.appearance.accentHex).opacity(0.3) : Color.white.opacity(0.06))
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 6) {
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
            .frame(maxWidth: 440)
            .background(Color(nsColor: NSColor(white: 0.06, alpha: 0.98)))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30)
        }
    }

    private var portBinding: Binding<String> {
        Binding(
            get: { String(appState.sshConfig.port) },
            set: { appState.sshConfig.port = Int($0) ?? 22 }
        )
    }

    private var fontSizeBinding: Binding<String> {
        Binding(
            get: { String(Int(appState.appearance.fontSize)) },
            set: { appState.appearance.fontSize = Double(Int($0) ?? 13) }
        )
    }

    private func save() {
        appState.saveConfig()
        appState.saveAppearance()
        appState.showSettings = false
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
