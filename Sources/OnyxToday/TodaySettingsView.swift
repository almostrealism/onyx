//
// TodaySettingsView.swift
//
// Responsibility: The phone's few settings: where the shared state comes
//                 from, the API tokens when iCloud Keychain didn't bring
//                 them, and re-pairing.
// Scope: A sheet over the Today page.
//

import SwiftUI
import OnyxCore
import OnyxUI

struct TodaySettingsView: View {
    @ObservedObject var model: TodayModel
    @Environment(\.dismiss) private var dismiss
    @State private var github = GitHubConfigStore.shared.token
    @State private var gitlab = GitLabConfigStore.shared.token
    @State private var timing = SecretStore.shared.get(.timingToken)
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Home host") {
                    if let home = model.home {
                        LabeledContent("Host", value: home.label)
                        LabeledContent("Address", value: "\(home.user)@\(home.address)" + (home.port == 22 ? "" : ":\(home.port)"))
                    }
                    Text(model.syncStatusLine)
                        .font(.footnote)
                        .foregroundColor(model.syncFailed ? .red : .secondary)
                    Button("Sync now") { SharedStateSync.shared.syncNow() }
                }

                Section {
                    SecureField("GitHub token", text: $github)
                    SecureField("GitLab token", text: $gitlab)
                    SecureField("Timing token", text: $timing)
                    Button("Save tokens") {
                        GitHubConfigStore.shared.token = github
                        GitLabConfigStore.shared.token = gitlab
                        SecretStore.shared.set(.timingToken, timing)
                        TodayState.refreshServices()
                        TimingDataStore.shared.startPolling()
                    }
                } header: {
                    Text("Tokens")
                } footer: {
                    Text("These normally arrive from your Mac through iCloud Keychain. They're kept in the keychain, never in the shared state.")
                }

                Section {
                    TextField("onyx1:…", text: $code)
                        .codeEntry()
                    Button("Pair again") {
                        if model.pair(with: code) { dismiss() }
                    }
                    .disabled(code.isEmpty)
                    if let problem = model.pairingProblem {
                        Text(problem).font(.footnote).foregroundColor(.red)
                    }
                } header: {
                    Text("Pairing code")
                } footer: {
                    Text("From your Mac: Settings → Shared state → Show pairing code.")
                }
            }
            .navigationTitle("Onyx Today")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }
}
