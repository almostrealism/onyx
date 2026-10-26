//
// SharedSettings.swift
//
// Responsibility: Which settings follow the user between devices through
//                 the shared state, and how each is read from and written
//                 to AppearanceConfig.
// Scope: Model. Pure functions over AppearanceConfig.
//
// A setting is local unless it is listed here (docs/ios-plan.md, "What goes
// where"). The ones listed shape the Today page — what the iPhone shows —
// and are choices about the work rather than the desk. Anything about one
// machine (window layout, opacity, where alerts go: `externalDelivery` is
// per machine by rule) stays off this list; `SharedSettingsTests` names
// every member so adding one is a decision someone made.
//

import Foundation

public enum SharedSetting: String, CaseIterable, Codable {
    case prDraftFilter
    case remindersLists
    case remindersDueSoonOnly
    case agendaPane
    case extraTimezones
    case use12HourClock

    /// The setting's value in `config`, as JSON.
    public func value(in config: AppearanceConfig) -> JSONValue? {
        switch self {
        case .prDraftFilter:        return .from(config.prDraftFilter)
        case .remindersLists:       return .from(config.remindersLists)
        case .remindersDueSoonOnly: return .from(config.remindersDueSoonOnly)
        case .agendaPane:           return .from(config.agendaPane)
        case .extraTimezones:       return .from(config.extraTimezones)
        case .use12HourClock:       return .from(config.use12HourClock)
        }
    }

    /// Write `value` into `config`. A value of the wrong shape (a newer
    /// Onyx's idea of the setting) is ignored rather than guessed at.
    public func apply(_ value: JSONValue, to config: inout AppearanceConfig) {
        switch self {
        case .prDraftFilter:        if let v = value.decoded(as: PRDraftFilter.self) { config.prDraftFilter = v }
        case .remindersLists:       if let v = value.decoded(as: [String].self) { config.remindersLists = v }
        case .remindersDueSoonOnly: if let v = value.decoded(as: Bool.self) { config.remindersDueSoonOnly = v }
        case .agendaPane:           if let v = value.decoded(as: AgendaPane.self) { config.agendaPane = v }
        case .extraTimezones:       if let v = value.decoded(as: [String].self) { config.extraTimezones = v }
        case .use12HourClock:       if let v = value.decoded(as: Bool.self) { config.use12HourClock = v }
        }
    }

    /// Every shared setting's value in `config`, keyed by name.
    public static func snapshot(of config: AppearanceConfig) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for setting in allCases {
            if let v = setting.value(in: config) { out[setting.rawValue] = v }
        }
        return out
    }

    /// `config` with the shared settings in `values` written into it.
    /// Names this build doesn't know are left alone (they stay in the
    /// shared state for the Onyx that does).
    public static func applying(_ values: [String: JSONValue], to config: AppearanceConfig) -> AppearanceConfig {
        var next = config
        for (name, value) in values {
            SharedSetting(rawValue: name)?.apply(value, to: &next)
        }
        return next
    }
}
