import SwiftUI

struct WindowRenameView: View {
    @ObservedObject var appState: AppState
    @State private var newTitle: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture {
                    appState.showWindowRename = false
                }

            VStack(spacing: 16) {
                Text("WINDOW TITLE")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(appState.accentColor)
                    .tracking(3)

                TextField("Window title", text: $newTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .light, design: .monospaced))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .focused($isFocused)
                    .padding(12)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(appState.accentColor.opacity(0.3), lineWidth: 1)
                    )
                    .onSubmit {
                        save()
                    }

                HStack(spacing: 12) {
                    Button(action: { appState.showWindowRename = false }) {
                        Text("Cancel")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.gray)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])

                    Button(action: save) {
                        Text("Save")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                            .background(appState.accentColor)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(30)
            .frame(width: 360)
            .background(Color(nsColor: NSColor(white: 0.06, alpha: 0.98)))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30)
        }
        .onAppear {
            newTitle = appState.appearance.windowTitle
            isFocused = true
        }
    }

    private func save() {
        appState.appearance.windowTitle = newTitle.isEmpty ? "Onyx" : newTitle
        appState.saveAppearance()
        appState.showWindowRename = false
        // Title update handled by ContentView's onChange(of: appearance.windowTitle)
    }
}
