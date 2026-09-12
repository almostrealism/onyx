import XCTest
@testable import OnyxLib

/// What leaves the Mac when an agent says something urgent.
///
/// These are all offline assertions about bytes, because the live failure
/// is unobservable: a wrist that didn't buzz looks identical whether the
/// token was wrong, the payload was malformed, or the alert never cleared
/// the threshold.
final class AlertForwardingTests: XCTestCase {

    private func alert(_ title: String = "Migration needs a decision",
                       body: String? = "Keep the newer row, keep both, or stop?",
                       urgent: Bool = true, external: Bool = true) -> SessionAlert {
        SessionAlert(title: title, body: body, urgent: urgent, external: external)
    }

    private func config(_ service: PushService) -> AlertForwardingConfig {
        var c = AlertForwardingConfig()
        c.service = service
        c.ntfyTopic = "onyx-2f9a7c41"
        c.pushoverUser = "uUSER"
        c.pushoverToken = "aTOKEN"
        c.webhookURL = "https://hooks.example.com/abc"
        c.imessageRecipient = "+15551234567"
        return c
    }

    private func json(_ outbound: AlertForwardRequest.Outbound) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: outbound.body)) as? [String: Any] ?? [:]
    }

    // MARK: - Thresholds

    func testUrgentOnlyIgnoresTheQuietOnes() {
        var c = config(.ntfy)
        c.threshold = .urgentOnly
        XCTAssertTrue(c.shouldForward(alert(urgent: true, external: false)))
        XCTAssertFalse(c.shouldForward(alert(urgent: false, external: true)))
    }

    /// The default. `external` already means "reach me when I'm not
    /// looking at Onyx", and a phone is where that's true.
    func testTheDefaultForwardsUrgentAndExternal() {
        let c = config(.ntfy)
        XCTAssertEqual(c.threshold, .urgentAndExternal)
        XCTAssertTrue(c.shouldForward(alert(urgent: false, external: true)))
        XCTAssertFalse(c.shouldForward(alert(urgent: false, external: false)))
    }

    func testNothingIsForwardedWhileTheServiceIsOff() {
        var c = config(.off)
        c.threshold = .everything
        XCTAssertFalse(c.shouldForward(alert()))
    }

    func testAnIncompleteConfigIsNotConsideredConfigured() {
        var c = AlertForwardingConfig()
        c.service = .ntfy
        XCTAssertFalse(c.isComplete, "no topic means nowhere to publish")
        c.ntfyTopic = "t"
        XCTAssertTrue(c.isComplete)

        var hook = AlertForwardingConfig()
        hook.service = .webhook
        hook.webhookURL = "not a url"
        XCTAssertFalse(hook.isComplete)
    }

    // MARK: - ntfy

    /// The title travels in the BODY, not an HTTP header. ntfy's
    /// header-based API is ASCII-only, and agents write em dashes.
    func testNtfySendsJSONSoUnicodeTitlesSurvive() {
        let a = SessionAlert(title: "Build broke — 3 tests", urgent: true)
        let out = AlertForwardRequest.build(a, sessionLabel: "ci", config: config(.ntfy))
        guard let out else { return XCTFail("no request built") }
        XCTAssertEqual(out.url.absoluteString, "https://ntfy.sh")
        XCTAssertEqual(out.headers["Content-Type"], "application/json")
        XCTAssertEqual(json(out)["title"] as? String, "Build broke — 3 tests")
        XCTAssertEqual(json(out)["topic"] as? String, "onyx-2f9a7c41")
    }

    func testNtfyUrgencyMapsToMaxPriority() {
        let urgent = AlertForwardRequest.build(alert(urgent: true, external: true),
                                               sessionLabel: nil, config: config(.ntfy))!
        XCTAssertEqual(json(urgent)["priority"] as? Int, 5)

        let quiet = AlertForwardRequest.build(alert(urgent: false, external: false),
                                              sessionLabel: nil, config: config(.ntfy))!
        XCTAssertEqual(json(quiet)["priority"] as? Int, 3)
    }

    func testATrailingSlashOnTheServerDoesNotProduceADoubleSlashURL() {
        var c = config(.ntfy)
        c.ntfyServer = "https://ntfy.example.com/ "
        let out = AlertForwardRequest.build(alert(), sessionLabel: nil, config: c)
        XCTAssertEqual(out?.url.absoluteString, "https://ntfy.example.com")
    }

    // MARK: - Pushover

    func testPushoverSendsAFormWithBothCredentials() {
        let out = AlertForwardRequest.build(alert(), sessionLabel: "trainer",
                                           config: config(.pushover))
        guard let out else { return XCTFail("no request built") }
        XCTAssertEqual(out.url.absoluteString, "https://api.pushover.net/1/messages.json")
        XCTAssertTrue(out.bodyText.contains("token=aTOKEN"))
        XCTAssertTrue(out.bodyText.contains("user=uUSER"))
        XCTAssertTrue(out.bodyText.contains("priority=1"), "urgent bypasses quiet hours")
    }

    /// A `&` in a title would end the field and silently drop the rest of
    /// the message — including, depending on order, the credentials.
    func testFormFieldsArePercentEncoded() {
        let out = AlertForwardRequest.build(
            alert("deploy A&B failed +now", body: nil), sessionLabel: nil,
            config: config(.pushover))!
        XCTAssertFalse(out.bodyText.contains("A&B"))
        XCTAssertTrue(out.bodyText.contains("A%26B"))
        XCTAssertTrue(out.bodyText.contains("%2Bnow"), "a literal + must not become a space")
    }

    func testAQuietAlertIsSentAtNormalPriority() {
        let out = AlertForwardRequest.build(alert(urgent: false, external: true),
                                           sessionLabel: nil, config: config(.pushover))!
        XCTAssertTrue(out.bodyText.contains("priority=0"))
    }

    // MARK: - Webhook

    /// Slack reads `text`, Discord reads `content`. Carrying both means
    /// the two webhooks people actually have work with no adapter.
    func testTheWebhookBodyCarriesSlackAndDiscordAliases() {
        let out = AlertForwardRequest.build(alert(), sessionLabel: "trainer",
                                           config: config(.webhook))!
        let payload = json(out)
        XCTAssertEqual(payload["title"] as? String, "Migration needs a decision")
        XCTAssertEqual(payload["urgent"] as? Bool, true)
        XCTAssertEqual(payload["session"] as? String, "trainer")
        let text = payload["text"] as? String
        XCTAssertEqual(text, payload["content"] as? String)
        XCTAssertTrue(text?.contains("Migration needs a decision") == true)
    }

    // MARK: - iMessage

    /// Alert titles come from agents over MCP. Interpolating one into an
    /// AppleScript string literal would make a title like
    /// `" & (do shell script "rm -rf ~") & "` arbitrary code execution on
    /// the user's Mac — so the text is an ARGUMENT and there is no literal
    /// to escape out of.
    func testTheMessageTextIsPassedAsAnArgumentNotInterpolated() {
        let hostile = #"" & (do shell script "echo pwned") & ""#
        let (cmd, args) = AlertForwardRequest.imessageCommand(
            alert(hostile, body: nil), sessionLabel: nil, recipient: "+15551234567")
        XCTAssertEqual(cmd, "/usr/bin/osascript")

        // Every script line is behind a -e; the payload is at the end,
        // after them, as data.
        let scriptLines = zip(args, args.dropFirst())
            .filter { $0.0 == "-e" }
            .map(\.1)
        XCTAssertFalse(scriptLines.contains { $0.contains("pwned") },
                       "the alert text must never appear inside the script")
        XCTAssertTrue(scriptLines.contains { $0 == "on run argv" })
        XCTAssertTrue(args.contains { $0.contains("pwned") },
                      "it should still be sent — as an argument")
        XCTAssertEqual(args.last, "+15551234567")
    }

    func testTheRecipientIsTrimmed() {
        let (_, args) = AlertForwardRequest.imessageCommand(alert(), sessionLabel: nil,
                                                           recipient: "  me@icloud.com \n")
        XCTAssertEqual(args.last, "me@icloud.com")
    }

    // MARK: - Text

    func testTheSessionIsNamedInTheMessageSoAPushSaysWhereItCameFrom() {
        let text = AlertForwardRequest.message(alert(), sessionLabel: "me@build-01:trainer")
        XCTAssertTrue(text.contains("me@build-01:trainer"))
    }

    /// ntfy substitutes its own text for an empty message, and "triggered"
    /// explains nothing.
    func testAnAlertWithNoBodyStillHasAMessage() {
        let text = AlertForwardRequest.message(alert("done", body: nil), sessionLabel: nil)
        XCTAssertEqual(text, "done")
    }

    func testATitleIsOneLine() {
        let title = AlertForwardRequest.title(alert("two\nlines", body: nil))
        XCTAssertEqual(title, "two lines")
    }

    // MARK: - Persistence

    func testTheConfigRoundTripsThroughTheStore() {
        let store = AlertForwardingStore.shared
        defer { store.resetForTesting() }
        store.update {
            $0.service = .pushover
            $0.pushoverUser = "u1"
            $0.threshold = .everything
        }
        XCTAssertEqual(store.config.service, .pushover)
        XCTAssertEqual(store.config.pushoverUser, "u1")
        XCTAssertEqual(store.config.threshold, .everything)
    }

    func testAnUnconfiguredStoreIsOff() {
        AlertForwardingStore.shared.resetForTesting()
        XCTAssertEqual(AlertForwardingStore.shared.config.service, .off)
    }
}
