//
// HostMachineNames.swift
//
// Responsibility: Remember each host's own short `hostname`, which is how
//                 its Claude hooks name it — a host configured by ssh
//                 alias or IP address carries no such name otherwise.
// Scope: App-wide; persisted in UserDefaults so matching works before a
//        host has answered this run.
//

import Foundation

public final class HostMachineNames: ObservableObject {

    public static let shared = HostMachineNames()

    static let defaultsKey = "HostMachineNames"

    /// Host id → short hostname. Main thread only.
    @Published public private(set) var names: [UUID: String]
    /// Hosts asked this run, so each is asked once per launch.
    public private(set) var askedThisRun: Set<UUID> = []
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        names = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    public func name(for hostID: UUID) -> String? { names[hostID] }

    /// Mark a host as asked, whatever the answer turns out to be.
    public func markAsked(_ hostID: UUID) { askedThisRun.insert(hostID) }

    /// Record what `hostname` printed. Takes the short form (the bridge
    /// sends the part before the first dot) and ignores anything that
    /// isn't shaped like a hostname.
    public func record(_ output: String, for hostID: UUID) {
        guard let short = Self.shortName(from: output), names[hostID] != short else { return }
        names[hostID] = short
        defaults.set(Dictionary(uniqueKeysWithValues: names.map { ($0.key.uuidString, $0.value) }),
                     forKey: Self.defaultsKey)
    }

    /// What to run: the marker keeps an echo of the script itself, which
    /// carries `$(hostname)` unevaluated, from being read as the answer.
    public static let script = "echo \"ONYX-HOST=$(hostname)\""

    /// The short hostname in the script's output: the value after the
    /// last marker that is a plain hostname, before its first dot.
    public static func shortName(from output: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let range = line.range(of: "ONYX-HOST=") else { continue }
            let word = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, word.unicodeScalars.allSatisfy(allowed.contains) else { continue }
            let short = word.split(separator: ".").first.map(String.init) ?? word
            if !short.isEmpty { return short }
        }
        return nil
    }
}
