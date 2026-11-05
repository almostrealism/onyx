//
// LegacyBundleMigration.swift
//
// Responsibility: Bring a user's ~/Library state across from the app's old
//                 bundle id (`com.onyx.terminal`) the first time Onyx runs
//                 as `ai.almostrealism.onyx`.
// Scope: Once per Mac account, at launch, before anything reads
//        UserDefaults or opens a web view (OnyxApp.init).
//
// What macOS keys by bundle id, and what happens to each:
//
//   Preferences (UserDefaults)   copied, key by key, where the new domain
//                                has no value — window frames, panel
//                                widths, learned hostnames, workflow
//                                filter, forge settings
//   Saved Application State      copied — the windows come back where
//                                they were
//   WebKit, HTTPStorages         copied — browser tabs keep their cookies,
//                                logins and site data
//   Caches                       left behind; they rebuild
//   Privacy grants (Reminders,   CAN'T move: macOS asks again, once
//   Calendars, Notifications,
//   Automation)
//
// Application Support/Onyx, ~/.onyx and the secrets file aren't keyed by
// bundle id and need nothing.
//
// COPIED, never moved, and the old files are left alone: an older Onyx
// started afterwards still finds everything where it left it. A copy is
// only made where the new location is empty, so nothing the new app has
// written is ever overwritten, and a marker in the new domain stops it
// running twice.
//

import Foundation
import OnyxCore

public enum LegacyBundleMigration {

    public static let legacyID = "com.onyx.terminal"
    public static let currentID = "ai.almostrealism.onyx"
    static let markerKey = "migratedFromBundleID"

    /// The Library items to copy, relative to ~/Library, for a bundle id.
    static func libraryItems(for id: String) -> [String] {
        ["Saved Application State/\(id).savedState",
         "WebKit/\(id)",
         "HTTPStorages/\(id)",
         "HTTPStorages/\(id).binarycookies"]
    }

    /// What a run did, for the log and the tests.
    public struct Result: Equatable {
        public var copiedDefaults = 0
        public var copiedItems: [String] = []
        public var skipped = false
    }

    /// Run once, as the packaged app. A `swift run` build has no bundle id
    /// and nothing to migrate.
    public static func runIfNeeded() {
        guard Bundle.main.bundleIdentifier == currentID else { return }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let result = migrate(legacyDefaults: UserDefaults.standard.persistentDomain(forName: legacyID),
                             into: .standard, library: library)
        if !result.skipped {
            OnyxLog.store.notice("migrated from \(legacyID): \(result.copiedDefaults) settings, items: \(result.copiedItems.joined(separator: ", "))")
        }
    }

    /// The migration itself, with everything it touches passed in.
    @discardableResult
    static func migrate(legacyDefaults: [String: Any]?, into defaults: UserDefaults,
                        library: URL, fileManager: FileManager = .default) -> Result {
        var result = Result()
        guard defaults.string(forKey: markerKey) == nil else {
            result.skipped = true
            return result
        }
        for (key, value) in legacyDefaults ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            result.copiedDefaults += 1
        }
        for (old, new) in zip(libraryItems(for: legacyID), libraryItems(for: currentID)) {
            let from = library.appendingPathComponent(old)
            let to = library.appendingPathComponent(new)
            guard fileManager.fileExists(atPath: from.path),
                  !fileManager.fileExists(atPath: to.path) else { continue }
            do {
                try fileManager.createDirectory(at: to.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try fileManager.copyItem(at: from, to: to)
                result.copiedItems.append(new)
            } catch {
                OnyxLog.store.error("couldn't copy \(old): \(error.localizedDescription)")
            }
        }
        // Written last, so a run cut short tries again next launch.
        defaults.set(legacyID, forKey: markerKey)
        return result
    }
}
