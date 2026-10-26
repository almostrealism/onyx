//
// WatchModels.swift
//
// Responsibility: The data behind page watches — "tell me when this URL
//                 changes in this specific way". Pure types; the polling
//                 lives in PageWatchManager and the persistence in
//                 PageWatchStore.
// Scope: Models. No I/O, no networking, no clock of its own.
//
// This exists because the interesting moment for some things isn't when
// someone writes an article about them — it's when a string on a vendor's
// page changes. A product configurator gaining an option, a status page
// losing the word "degraded", a docs page finally mentioning a flag.
// Polling one URL for one substring answers that precisely, and nothing
// else in the app was going to.
//

import Foundation

/// What counts as "it happened".
public enum WatchTrigger: String, Codable, CaseIterable, Equatable {
    /// The text wasn't there and now is — an option opening up.
    case appears
    /// The text was there and now isn't. Usually the better signal: a
    /// vendor's own "coming later" notice is a promise they'll delete on
    /// the day, while the thing that replaces it is unknowable in advance.
    case disappears
    /// The page's content hash changed at all. Blunt, and on a big
    /// commercial page it fires constantly (prices, banners, session
    /// tokens), so it's a last resort rather than a default.
    case changes

    public var label: String {
        switch self {
        case .appears:    return "text appears"
        case .disappears: return "text disappears"
        case .changes:    return "page changes at all"
        }
    }

    /// Whether this trigger needs a needle to mean anything.
    public var needsText: Bool { self != .changes }
}

/// One configured watch.
public struct PageWatch: Identifiable, Codable, Equatable {
    public var id: UUID
    /// What the user calls it — shown when it fires, so it should read
    /// like the news itself ("Mac Studio 512GB").
    public var label: String
    public var url: String
    public var trigger: WatchTrigger
    /// The substring to look for. Matched case-insensitively against the
    /// raw response body, not against rendered text: these pages carry
    /// their state in embedded JSON as often as in visible markup, and
    /// the JSON is usually the more precise place to look.
    public var text: String
    public var enabled: Bool
    /// Minutes between checks. Floored by `PageWatch.minimumInterval` —
    /// this is somebody else's server, and a watch that matters is
    /// usually one you're waiting weeks for.
    public var intervalMinutes: Int

    /// Polite floor. A page you're watching for a launch does not need
    /// to be hit every thirty seconds, and being rude gets you blocked
    /// right before the thing you were waiting for.
    public static let minimumInterval = 5
    public static let defaultInterval = 15

    public init(id: UUID = UUID(), label: String, url: String,
                trigger: WatchTrigger = .appears, text: String = "",
                enabled: Bool = true, intervalMinutes: Int = defaultInterval) {
        self.id = id
        self.label = label
        self.url = url
        self.trigger = trigger
        self.text = text
        self.enabled = enabled
        self.intervalMinutes = max(Self.minimumInterval, intervalMinutes)
    }

    /// A watch that can actually run: somewhere to look, and something to
    /// look for unless the trigger is "anything at all".
    public var isRunnable: Bool {
        guard enabled, let u = URL(string: url), u.scheme?.hasPrefix("http") == true,
              u.host != nil else { return false }
        return trigger.needsText ? !text.trimmingCharacters(in: .whitespaces).isEmpty : true
    }
}

/// What a watch has seen. Persisted alongside the watch, because the
/// whole mechanism depends on remembering the previous observation —
/// "appears" is meaningless without knowing it was absent before.
public struct WatchState: Codable, Equatable {
    /// Whether the text was present at the last successful check. Nil
    /// until the first one lands.
    public var present: Bool?
    /// Content hash at the last successful check (for `.changes`).
    public var hash: String?
    public var lastCheck: Date?
    /// When the condition was met. Non-nil means "this has fired and is
    /// waiting to be acknowledged" — kept so the news survives a restart
    /// and the app doesn't announce it once and lose it.
    public var firedAt: Date?
    /// The last failure, in the server's own words where possible.
    /// Reported rather than swallowed: a watch that has been quietly
    /// 403ing for a week is worse than no watch, because you think
    /// you're covered.
    public var lastError: String?

    public init(present: Bool? = nil, hash: String? = nil, lastCheck: Date? = nil,
                firedAt: Date? = nil, lastError: String? = nil) {
        self.present = present
        self.hash = hash
        self.lastCheck = lastCheck
        self.firedAt = firedAt
        self.lastError = lastError
    }

    /// Decide what a fresh observation means, given what we saw last.
    ///
    /// The first check of a watch NEVER fires. It establishes the
    /// baseline — otherwise every "text disappears" watch would announce
    /// itself the moment you created it, which is both wrong and the
    /// fastest way to teach someone to ignore the alert.
    public func evaluate(trigger: WatchTrigger,
                         present nowPresent: Bool,
                         hash nowHash: String) -> Bool {
        switch trigger {
        case .appears:
            guard let was = present else { return false }
            return !was && nowPresent
        case .disappears:
            guard let was = present else { return false }
            return was && !nowPresent
        case .changes:
            guard let was = hash else { return false }
            return was != nowHash
        }
    }
}

/// A watch plus what it has seen — what the UI actually renders.
public struct WatchEntry: Identifiable, Codable, Equatable {
    public var watch: PageWatch
    public var state: WatchState

    public var id: UUID { watch.id }

    public init(watch: PageWatch, state: WatchState = WatchState()) {
        self.watch = watch
        self.state = state
    }
}

// MARK: - Presets

public extension PageWatch {
    /// The watch this whole feature was built for.
    ///
    /// Apple's Mac Studio configurator carries its own countdown: a
    /// footer note reading "512GB memory option for M5 Ultra coming late
    /// October", and a memory `variantOrder` that lists everything up to
    /// 256gb and stops. Watching for that footer to DISAPPEAR is the
    /// precise signal, and it's better than watching for "512GB" to
    /// appear — that string is already on the page three times, twice as
    /// a storage size and once in the notice itself.
    ///
    /// If Apple reworders the notice this goes quiet rather than wrong;
    /// the watch list shows the last check time, so a watch that has
    /// stopped meaning anything is visible rather than silently useless.
    static func macStudioUltraMemory() -> PageWatch {
        PageWatch(label: "Mac Studio — 512GB M5 Ultra",
                  url: "https://www.apple.com/shop/buy-mac/mac-studio",
                  trigger: .disappears,
                  text: "512GB memory option for M5 Ultra coming late October",
                  intervalMinutes: 15)
    }
}
