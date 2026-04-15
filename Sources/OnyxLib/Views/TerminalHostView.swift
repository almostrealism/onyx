import SwiftUI
import AppKit
import SwiftTerm

struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var appState: AppState

    func makeNSView(context: Context) -> OnyxTerminalView {
        let view = OnyxTerminalView(appState: appState)
        return view
    }

    func updateNSView(_ nsView: OnyxTerminalView, context: Context) {
        if appState.configLoaded && !appState.showSetup && !nsView.hasStarted {
            nsView.startSSH()
        }
        if appState.reconnectRequested {
            DispatchQueue.main.async {
                appState.reconnectRequested = false
                appState.connectionError = nil
                appState.needsKeySetup = false
            }
            nsView.forceReconnect()
        }
        if appState.refreshSessionList {
            DispatchQueue.main.async {
                appState.refreshSessionList = false
            }
            nsView.softRefreshSessions()
        }
        if appState.keySetupInProgress {
            DispatchQueue.main.async {
                appState.keySetupInProgress = false
            }
            nsView.startKeySetup()
        }
        if let session = appState.switchToSession {
            if session.source.isLocal {
                // Local sessions (browser, etc.) bypass the terminal pool.
                // Clear switchToSession immediately to prevent re-entry,
                // defer activeSession change to next run loop tick.
                appState.switchToSession = nil
                DispatchQueue.main.async {
                    appState.activeSession = session
                }
            } else {
                DispatchQueue.main.async {
                    appState.switchToSession = nil
                }
                nsView.switchToSession(session)
            }
        }
        if let newSession = appState.createNewSession {
            DispatchQueue.main.async {
                appState.createNewSession = nil
            }
            if newSession.source.isLocal {
                // Local sessions (browser, etc.) don't need terminal pool creation.
                // Add to session list and activate, deferring to next tick.
                DispatchQueue.main.async {
                    if !appState.allSessions.contains(where: { $0.id == newSession.id }) {
                        appState.allSessions.append(newSession)
                    }
                    appState.activeSession = newSession
                    appState.showSessionManager = false
                    appState.saveLocalSessions()
                }
            } else {
                nsView.createNewTmuxSession(newSession)
            }
        }
        // Capture terminal text when entering text mode
        if appState.showTerminalText && appState.terminalTextContent.isEmpty {
            let text = nsView.getVisibleText()
            DispatchQueue.main.async {
                appState.terminalTextContent = text
            }
        }
        nsView.updateTerminalFont(
            name: appState.appearance.terminalFontName,
            size: appState.appearance.effectiveTerminalFontSize
        )
    }
}
