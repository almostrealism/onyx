import SwiftUI

struct SetupView: View {
    @ObservedObject var appState: AppState
    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case host, user, port, tmux, identity
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Text("ONYX")
                    .font(.system(size: 36, weight: .ultraLight, design: .monospaced))
                    .foregroundColor(appState.accentColor)
                    .tracking(12)

                Text("Configure your connection")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.gray)

                VStack(spacing: 12) {
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

                    OnyxTextField(label: "Identity file (optional)", text: $appState.sshConfig.identityFile, placeholder: "~/.ssh/id_ed25519")
                        .focused($focusedField, equals: .identity)
                }
                .frame(maxWidth: 400)

                Button(action: connect) {
                    Text("Connect")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 8)
                        .background(Color(hex: "66CCFF"))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(appState.sshConfig.host.isEmpty)
            }
            .padding(40)
        }
        .onAppear {
            focusedField = .host
        }
    }

    private var portBinding: Binding<String> {
        Binding(
            get: { String(appState.sshConfig.port) },
            set: { appState.sshConfig.port = Int($0) ?? 22 }
        )
    }

    private func connect() {
        guard !appState.sshConfig.host.isEmpty else { return }
        appState.saveConfig()
    }
}

struct OnyxTextField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Color(hex: "66CCFF").opacity(0.7))
                .tracking(2)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.white)
                .padding(8)
                .background(Color.white.opacity(0.06))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        }
    }
}

public extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            r = 1; g = 1; b = 1
        }
        self.init(red: r, green: g, blue: b)
    }
}
