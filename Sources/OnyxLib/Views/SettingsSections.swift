//
// SettingsSections.swift
//
// Responsibility: The per-feature blocks of the settings panel — the
//                 forges, the file-search filter, page watches, shared
//                 state, and alert forwarding.
// Scope: Views. Each is a self-contained section that SettingsView places
//        in order and otherwise knows nothing about.
//
// Split out of SettingsView.swift, which had grown past a thousand lines
// and, more to the point, past the point where SwiftUI's type checker
// would infer the body in reasonable time — adding one more section to
// that single `var body` is what pushed it over. A section per struct
// keeps each one cheap to compile and cheap to find.
//
// Nothing here changed in the move except visibility: `private` becomes
// internal so SettingsView can still place them.
//

import SwiftUI
import AppKit

struct FlowtreeSettingsSection: View {
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
struct GitHubSettingsSection: View {
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
struct MineOnlyToggle: View {
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

struct SearchFilterSettingsSection: View {
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

struct GitLabSettingsSection: View {
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
struct PageWatchSettingsSection: View {
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
struct WatchRow: View {
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
struct SharedStateSettingsSection: View {
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

// MARK: - Alert forwarding (phone / watch)

/// Getting an alert off the Mac and onto a wrist.
///
/// The explanation carries weight here, because the thing users expect —
/// "forward my Mac notifications to my watch" — does not exist. The watch
/// mirrors a PHONE. So Onyx sends the alert to something the phone already
/// listens to, and the panel says which options those are and what each
/// one costs to set up.
struct AlertForwardingSettingsSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var store = AlertForwardingStore.shared
    @ObservedObject private var forwarder = AlertForwarder.shared

    private var config: AlertForwardingConfig { store.config }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "ALERTS ON YOUR PHONE")

            Picker("", selection: Binding(
                get: { config.service },
                set: { service in store.update { $0.service = service } }
            )) {
                ForEach(PushService.allCases) { service in
                    Text(service.label).tag(service)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if config.service != .off {
                VStack(alignment: .leading, spacing: 8) {
                    serviceFields

                    Picker("", selection: Binding(
                        get: { config.threshold },
                        set: { threshold in store.update { $0.threshold = threshold } }
                    )) {
                        ForEach(ForwardThreshold.allCases) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    HStack(spacing: 10) {
                        Button(action: { AlertForwarder.shared.sendTest() }) {
                            Text("Send a test")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(appState.accentColor)
                        }
                        .buttonStyle(.plain)

                        if let result = forwarder.lastResult {
                            Text(result)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(result.hasPrefix("sent")
                                                 ? .gray.opacity(0.6)
                                                 : Color.onyxRed.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 4)
            }

            Text(explanation)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.gray.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var serviceFields: some View {
        switch config.service {
        case .off:
            EmptyView()
        case .ntfy:
            OnyxTextField(label: "ntfy topic", text: Binding(
                get: { config.ntfyTopic },
                set: { v in store.update { $0.ntfyTopic = v } }
            ), placeholder: "onyx-2f9a7c41")
            OnyxTextField(label: "ntfy server", text: Binding(
                get: { config.ntfyServer },
                set: { v in store.update { $0.ntfyServer = v } }
            ), placeholder: "https://ntfy.sh")
        case .pushover:
            OnyxTextField(label: "Pushover user key", text: Binding(
                get: { config.pushoverUser },
                set: { v in store.update { $0.pushoverUser = v } }
            ), placeholder: "u…")
            OnyxTextField(label: "Pushover app token", text: Binding(
                get: { config.pushoverToken },
                set: { v in store.update { $0.pushoverToken = v } }
            ), placeholder: "a…")
        case .webhook:
            OnyxTextField(label: "POST URL", text: Binding(
                get: { config.webhookURL },
                set: { v in store.update { $0.webhookURL = v } }
            ), placeholder: "https://…")
        case .imessage:
            OnyxTextField(label: "Send to", text: Binding(
                get: { config.imessageRecipient },
                set: { v in store.update { $0.imessageRecipient = v } }
            ), placeholder: "+15551234567 or you@icloud.com")
        }
    }

    private var explanation: String {
        switch config.service {
        case .off:
            return "An Apple Watch mirrors your iPhone, not your Mac — macOS notifications never reach it. Pick a service your phone already listens to and Onyx will send urgent alerts there, which is what makes your wrist buzz."
        case .ntfy:
            return "Free. Install ntfy from the App Store, subscribe it to a topic, and put the same topic here. Anyone who knows the topic name can publish to it, so use something unguessable rather than \"onyx\". Urgent alerts go out at max priority, which is the one iOS delivers insistently."
        case .pushover:
            return "One-off purchase, and the most reliable of these. Create an application at pushover.net for the token; the user key is on your dashboard. Urgent alerts are sent high-priority, so they arrive through Do Not Disturb."
        case .webhook:
            return "Any endpoint that takes a JSON POST — a Discord or Slack webhook, Home Assistant, a shortcut runner. The body carries title, body, urgent, external and session, plus `text` and `content` copies so Slack and Discord webhooks work with no adapter."
        case .imessage:
            return "No signup: Onyx asks Messages on this Mac to text you. iMessage is data rather than SMS, so a carrier that filters gateway messages has nothing to filter. Send to your own number or Apple ID and it lands on every device you're signed in on. macOS will ask once for permission to control Messages — the first send fails if you decline."
        }
    }
}
