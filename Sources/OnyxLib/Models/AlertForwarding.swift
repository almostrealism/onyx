//
// AlertForwarding.swift
//
// Responsibility: Sending an alert somewhere that can reach a phone — and
//                 therefore a watch — plus the rules for which alerts are
//                 worth doing that to.
// Scope: Model. The config and a PURE request builder; the manager does
//        the I/O. Every service's exact payload is testable offline, which
//        matters because "the watch didn't buzz" is impossible to debug
//        from the outside.
//
// Why it's shaped this way: a Mac notification never reaches an Apple
// Watch. The Watch mirrors the PHONE, so the only path from "an agent is
// blocked" to "my wrist buzzes" is a push notification delivered to iOS.
// Onyx doesn't need to know any of that — it needs one outbound hook, and
// an app on the phone that already knows how to push.
//
// So: presets for the two services built for exactly this (ntfy,
// Pushover), a generic webhook for everything else (Discord, Slack, Home
// Assistant, a shortcut runner), and iMessage-to-yourself for the case
// with no signup at all — which is also the case that beats a carrier
// blocking SMS, because iMessage isn't SMS.
//

import Foundation

public enum PushService: String, Codable, CaseIterable, Identifiable {
    case off
    case ntfy
    case pushover
    case webhook
    case imessage

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off:      return "Off"
        case .ntfy:     return "ntfy"
        case .pushover: return "Pushover"
        case .webhook:  return "Webhook"
        case .imessage: return "iMessage to myself"
        }
    }
}

/// Which alerts get pushed to the phone.
public enum ForwardThreshold: String, Codable, CaseIterable, Identifiable {
    /// Only alerts the agent marked urgent — "I can't continue".
    case urgentOnly
    /// Urgent, plus anything the agent asked to be told about outside the
    /// app. This is the default: `external` already means "reach me when
    /// I'm not looking at Onyx", and a phone is where that is true.
    case urgentAndExternal
    /// Everything, including the quiet ones.
    case everything

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .urgentOnly:       return "Urgent only"
        case .urgentAndExternal: return "Urgent + external"
        case .everything:       return "Every alert"
        }
    }
}

public struct AlertForwardingConfig: Codable, Equatable {
    public var service: PushService = .off
    public var threshold: ForwardThreshold = .urgentAndExternal

    /// ntfy: server (defaults to the public one) and topic. The topic IS
    /// the credential on ntfy.sh — anyone who knows it can publish to it —
    /// so the settings panel says to make it unguessable.
    public var ntfyServer: String = "https://ntfy.sh"
    public var ntfyTopic: String = ""

    /// Pushover: the application token and the user key, both from
    /// pushover.net.
    public var pushoverToken: String = ""
    public var pushoverUser: String = ""

    /// Anything that accepts a JSON POST.
    public var webhookURL: String = ""

    /// Phone number or Apple ID to send an iMessage to — normally your
    /// own, so it lands on every device you're signed in on.
    public var imessageRecipient: String = ""

    public init() {}

    /// Whether this alert clears the bar the user set.
    public func shouldForward(_ alert: SessionAlert) -> Bool {
        guard service != .off else { return false }
        switch threshold {
        case .urgentOnly:        return alert.urgent
        case .urgentAndExternal: return alert.urgent || alert.external
        case .everything:        return true
        }
    }

    /// Whether the fields this service needs are filled in. Used to say
    /// "configured" without attempting a send.
    public var isComplete: Bool {
        switch service {
        case .off:      return false
        case .ntfy:     return !ntfyTopic.trimmed.isEmpty && !ntfyServer.trimmed.isEmpty
        case .pushover: return !pushoverToken.trimmed.isEmpty && !pushoverUser.trimmed.isEmpty
        case .webhook:  return URL(string: webhookURL.trimmed)?.scheme != nil
        case .imessage: return !imessageRecipient.trimmed.isEmpty
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

public enum AlertForwardRequest {

    /// An HTTP request, ready to send.
    public struct Outbound: Equatable {
        public let url: URL
        public let headers: [String: String]
        public let body: Data

        /// For tests and for the diagnostic log.
        public var bodyText: String { String(data: body, encoding: .utf8) ?? "" }
    }

    /// What to say. One line for the wrist, detail underneath.
    public static func title(_ alert: SessionAlert) -> String {
        String(alert.title.replacingOccurrences(of: "\n", with: " ").prefix(120))
    }

    public static func message(_ alert: SessionAlert, sessionLabel: String?) -> String {
        var parts: [String] = []
        if let body = alert.body, !body.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(body)
        }
        if let sessionLabel, !sessionLabel.isEmpty { parts.append("— \(sessionLabel)") }
        // Never empty: ntfy substitutes its own text for an empty message,
        // and a push that says "triggered" explains nothing.
        return parts.isEmpty ? title(alert) : parts.joined(separator: "\n")
    }

    /// Build the request for a service, or nil when the service isn't an
    /// HTTP one (iMessage) or isn't configured.
    public static func build(_ alert: SessionAlert, sessionLabel: String?,
                             config: AlertForwardingConfig) -> Outbound? {
        guard config.isComplete else { return nil }
        switch config.service {
        case .off, .imessage:
            return nil

        case .ntfy:
            // The JSON publish endpoint, not the header-based one: ntfy
            // carries the title in an HTTP HEADER otherwise, and headers
            // are ASCII — an agent's title with an em dash or an accent in
            // it would be mangled or rejected.
            let server = config.ntfyServer.trimmingCharacters(
                in: CharacterSet(charactersIn: " \t\n/"))
            guard let url = URL(string: server) else { return nil }
            let payload: [String: Any] = [
                "topic": config.ntfyTopic.trimmingCharacters(in: .whitespacesAndNewlines),
                "title": title(alert),
                "message": message(alert, sessionLabel: sessionLabel),
                // 5 is ntfy's max: on iOS it's the one that insists rather
                // than waiting to be noticed, which is what urgent means.
                "priority": alert.urgent ? 5 : (alert.external ? 4 : 3),
                "tags": [alert.urgent ? "warning" : "bell"],
            ]
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
            return Outbound(url: url,
                            headers: ["Content-Type": "application/json"],
                            body: body)

        case .pushover:
            guard let url = URL(string: "https://api.pushover.net/1/messages.json") else {
                return nil
            }
            var fields = [
                "token": config.pushoverToken.trimmingCharacters(in: .whitespacesAndNewlines),
                "user": config.pushoverUser.trimmingCharacters(in: .whitespacesAndNewlines),
                "title": title(alert),
                "message": message(alert, sessionLabel: sessionLabel),
            ]
            // 1 is high priority: it bypasses the user's quiet hours. Not
            // 2 — that repeats until acknowledged, and an agent deciding
            // to wake someone every minute is not a power it should have.
            fields["priority"] = alert.urgent ? "1" : "0"
            return Outbound(url: url,
                            headers: ["Content-Type": "application/x-www-form-urlencoded"],
                            body: Data(formEncode(fields).utf8))

        case .webhook:
            guard let url = URL(string: config.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme != nil else { return nil }
            let text = "\(title(alert))\n\(message(alert, sessionLabel: sessionLabel))"
            let payload: [String: Any] = [
                "title": title(alert),
                "body": alert.body ?? "",
                "urgent": alert.urgent,
                "external": alert.external,
                "session": sessionLabel ?? "",
                "at": ISO8601DateFormatter().string(from: alert.at),
                // Aliases so the two webhooks people actually have work
                // with no adapter: Slack reads `text`, Discord reads
                // `content`. Both ignore fields they don't know.
                "text": text,
                "content": text,
            ]
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
            return Outbound(url: url,
                            headers: ["Content-Type": "application/json"],
                            body: body)
        }
    }

    /// Percent-encode a form body. `+` and `&` in a token or a title would
    /// otherwise silently truncate the field.
    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.keys.sorted().map { key in
            let value = fields[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(key)=\(value)"
        }.joined(separator: "&")
    }

    /// The `osascript` invocation for the iMessage route.
    ///
    /// The text is passed as an ARGUMENT, never interpolated into the
    /// script. Alert titles come from agents over MCP, and an alert
    /// entitled `" & (do shell script "…") & "` pasted into an AppleScript
    /// literal would be arbitrary code execution on the user's Mac. With
    /// `on run argv` there is no literal to escape out of.
    public static func imessageCommand(_ alert: SessionAlert, sessionLabel: String?,
                                       recipient: String) -> (cmd: String, args: [String]) {
        let text = "\(title(alert))\n\(message(alert, sessionLabel: sessionLabel))"
        let script = [
            "on run argv",
            "tell application \"Messages\"",
            "set svc to 1st account whose service type = iMessage",
            "send (item 1 of argv) to participant (item 2 of argv) of svc",
            "end tell",
            "end run",
        ]
        var args: [String] = []
        for line in script { args.append(contentsOf: ["-e", line]) }
        args.append(contentsOf: [text, recipient.trimmingCharacters(in: .whitespacesAndNewlines)])
        return ("/usr/bin/osascript", args)
    }
}
