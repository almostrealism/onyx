//
// AlertForwarder.swift
//
// Responsibility: Actually sending an alert to the user's phone, and
//                 saying plainly what happened when it doesn't work.
// Scope: Shared singleton. Called from AlertDelivery on whatever thread an
//        MCP request arrived on.
// Threading: URLSession is async; @Published result on main.
//
// The failure mode this is written against: a push that silently doesn't
// arrive. There is no way to tell from a wrist that nothing buzzed because
// the topic is wrong, the token is wrong, the Mac has no network, or the
// agent's alert never cleared the threshold. So every attempt records its
// outcome — HTTP status and the service's own response body included —
// and the Settings panel shows the last one next to a Test button.
//

import Foundation
import AppKit

public final class AlertForwarder: ObservableObject {
    public static let shared = AlertForwarder()

    /// What happened last time, for the settings panel. Set for successes
    /// too: "sent, 200" is how you tell "it worked and the phone is
    /// misconfigured" from "it never left the Mac".
    @Published public private(set) var lastResult: String?
    @Published public private(set) var lastAttempt: Date?

    private let session: URLSession
    private let queue = DispatchQueue(label: "com.onyx.alert-forwarder", qos: .utility)

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// Push this alert if the user's threshold says so.
    public func consider(_ alert: SessionAlert, sessionLabel: String?) {
        let config = AlertForwardingStore.shared.config
        guard config.shouldForward(alert) else { return }
        guard config.isComplete else {
            record("\(config.service.label) is selected but not configured")
            return
        }
        // Never from a test process: a unit test must not send the user a
        // notification, and it definitely must not talk to ntfy.sh.
        guard NSClassFromString("XCTest") == nil else { return }
        send(alert, sessionLabel: sessionLabel, config: config)
    }

    /// Send a canned alert so the user can see the thing arrive.
    public func sendTest() {
        let alert = SessionAlert(
            title: "Onyx test alert",
            body: "If this reached your watch, forwarding works.",
            urgent: true, external: true)
        let config = AlertForwardingStore.shared.config
        guard config.service != .off else {
            record("Pick a service first")
            return
        }
        guard config.isComplete else {
            record("\(config.service.label) needs its details filled in")
            return
        }
        send(alert, sessionLabel: "test", config: config)
    }

    // MARK: - Sending

    private func send(_ alert: SessionAlert, sessionLabel: String?,
                      config: AlertForwardingConfig) {
        if config.service == .imessage {
            sendIMessage(alert, sessionLabel: sessionLabel, recipient: config.imessageRecipient)
            return
        }
        guard let outbound = AlertForwardRequest.build(alert, sessionLabel: sessionLabel,
                                                       config: config) else {
            record("couldn't build the request — check the server or URL")
            return
        }
        var request = URLRequest(url: outbound.url)
        request.httpMethod = "POST"
        for (key, value) in outbound.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = outbound.body

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.record("failed: \(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                self.record("sent (HTTP \(status))")
            } else {
                // The service's own words. Pushover says "user identifier
                // is invalid"; guessing from a 400 would not.
                let said = data.flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self.record("rejected (HTTP \(status))\(said.isEmpty ? "" : ": \(String(said.prefix(200)))")")
            }
        }.resume()
    }

    /// iMessage, via Messages.app on this Mac.
    ///
    /// The point of this route: iMessage is data, not SMS, so a carrier
    /// that filters messages from short codes and gateways has nothing to
    /// filter. Sending to your own number puts it on every device you're
    /// signed in on, which includes the watch.
    private func sendIMessage(_ alert: SessionAlert, sessionLabel: String?, recipient: String) {
        let (cmd, args) = AlertForwardRequest.imessageCommand(alert, sessionLabel: sessionLabel,
                                                             recipient: recipient)
        queue.async { [weak self] in
            let result = RemoteExec.shared.run(cmd, args: args, stdin: nil, softTimeout: 25,
                                               captureStdout: true, captureStderr: true,
                                               label: "alertIMessage")
            guard let self else { return }
            if result.exit == 0 {
                self.record("sent via Messages")
            } else {
                let said = (result.stderr + result.stdout)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // The overwhelmingly likely first failure: macOS hasn't
                // been told Onyx may drive Messages. Say so rather than
                // relaying an error number.
                let hint = said.lowercased().contains("not allowed")
                        || said.lowercased().contains("1743")
                    ? " — allow Onyx to control Messages in System Settings → Privacy & Security → Automation"
                    : ""
                self.record("Messages refused: \(String(said.prefix(160)))\(hint)")
            }
        }
    }

    private func record(_ text: String) {
        DispatchQueue.main.async {
            self.lastResult = text
            self.lastAttempt = Date()
        }
        DiagnosticLog.shared.record("alerts", "forward: \(text)")
    }
}
