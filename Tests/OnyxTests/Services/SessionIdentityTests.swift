import XCTest
@testable import OnyxLib

/// How a session's note and favourite are keyed on disk. This decides
/// whether they survive a reinstall, follow you to another machine, and
/// stay apart when they belong to different people — so the rules are
/// pinned rather than assumed.
final class SessionIdentityTests: XCTestCase {

    private func host(_ name: String, user: String = "me",
                      id: UUID = UUID()) -> HostConfig {
        HostConfig(id: id, label: name, ssh: SSHConfig(host: name, user: user))
    }

    // MARK: - What goes in the key

    /// tmux sessions are per-user: another account on the same machine
    /// has a different `tmux ls`. Keying by host alone would merge two
    /// people's sessions under one note.
    func testUserAndHostBothMatter() {
        XCTAssertEqual(SessionIdentity.key(for: host("build", user: "me")), "me@build")
        XCTAssertNotEqual(SessionIdentity.key(for: host("build", user: "me")),
                          SessionIdentity.key(for: host("build", user: "you")))
    }

    /// An empty ssh user means "connect as whoever I am locally" — which
    /// is a DIFFERENT remote account depending on the machine you're
    /// sitting at, and therefore different sessions. Resolving it keeps
    /// them apart instead of pretending they're one.
    func testAnUnsetUserResolvesToTheLocalAccount() {
        let h = host("build", user: "")
        XCTAssertEqual(SessionIdentity.key(for: h, localUser: "michael"), "michael@build")
        XCTAssertEqual(SessionIdentity.key(for: h, localUser: "worker"), "worker@build")
    }

    /// The private key isn't part of identity — using a different key
    /// from the laptop than the desktop must not split the notes.
    func testTheSSHKeyIsNotPartOfTheIdentity() {
        var a = host("build")
        a.ssh.identityFile = "/Users/me/.ssh/laptop"
        var b = host("build")
        b.ssh.identityFile = "/Users/me/.ssh/desktop"
        XCTAssertEqual(SessionIdentity.key(for: a), SessionIdentity.key(for: b))
    }

    /// Nor is the host's local UUID: it differs per machine and changes
    /// when a host entry is deleted and re-added.
    func testTheLocalHostEntryUUIDIsNotPartOfTheIdentity() {
        XCTAssertEqual(SessionIdentity.key(for: host("build", id: UUID())),
                       SessionIdentity.key(for: host("build", id: UUID())))
    }

    func testHostIsCaseAndWhitespaceInsensitiveWithNoTrailingDot() {
        XCTAssertEqual(SessionIdentity.key(for: host("  BUILD.example.com. ")),
                       "me@build.example.com")
    }

    /// "Whatever we see it as from here" is the rule, so an alias and an
    /// IP for one machine are two identities — accepted deliberately,
    /// because the alternative is letting a remote name itself.
    func testTwoRoutesToOneMachineAreTwoIdentities() {
        XCTAssertNotEqual(SessionIdentity.key(for: host("build")),
                          SessionIdentity.key(for: host("10.0.0.7")))
    }

    // MARK: - Session keys

    func testSessionKeysCarryTheMachineAndTheContainer() {
        let h = host("build")
        let plain = TmuxSession(name: "api", source: .host(hostID: h.id))
        XCTAssertEqual(SessionIdentity.storageKey(for: plain, host: h), "host:me@build:api")

        let inContainer = TmuxSession(name: "api",
                                      source: .docker(hostID: h.id, containerName: "web"))
        XCTAssertEqual(SessionIdentity.storageKey(for: inContainer, host: h),
                       "docker:me@build:web:api")
    }

    // MARK: - Migration

    func testAUUIDKeyBecomesAUserHostKey() {
        let h = host("build")
        XCTAssertEqual(
            SessionIdentity.migrate(storageKey: "host:\(h.id.uuidString):api", hosts: [h]),
            "host:me@build:api")
    }

    func testContainerKeysKeepTheirContainer() {
        let h = host("build")
        XCTAssertEqual(
            SessionIdentity.migrate(storageKey: "docker:\(h.id.uuidString):web:api", hosts: [h]),
            "docker:me@build:web:api")
    }

    /// Idempotent: running the migration again must do nothing, since it
    /// runs on every launch.
    func testAnAlreadyMigratedKeyIsLeftAlone() {
        let h = host("build")
        XCTAssertNil(SessionIdentity.migrate(storageKey: "host:me@build:api", hosts: [h]))
    }

    /// A note for a deleted host is NOT dropped. Someone may re-add that
    /// host, and losing notes during a migration is unforgivable.
    func testAKeyForAnUnknownHostIsLeftAlone() {
        XCTAssertNil(SessionIdentity.migrate(storageKey: "host:\(UUID().uuidString):api",
                                             hosts: [host("build")]))
    }

    func testMalformedKeysAreLeftAlone() {
        XCTAssertNil(SessionIdentity.migrate(storageKey: "host:api", hosts: [host("build")]))
        XCTAssertNil(SessionIdentity.migrate(storageKey: "", hosts: [host("build")]))
    }

    /// A session name containing a colon must not be truncated — only
    /// the machine field is rewritten.
    func testSessionNamesWithColonsSurvive() {
        let h = host("build")
        XCTAssertEqual(
            SessionIdentity.migrate(storageKey: "host:\(h.id.uuidString):api:v2", hosts: [h]),
            "host:me@build:api:v2")
    }

    /// Two host entries pointing at the same machine and user collapse to
    /// one key — which is the point: they're the same tmux sessions.
    func testDuplicateHostEntriesProduceOneIdentity() {
        let a = host("build"), b = host("build")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(SessionIdentity.migrate(storageKey: "host:\(a.id.uuidString):api",
                                               hosts: [a, b]),
                       SessionIdentity.migrate(storageKey: "host:\(b.id.uuidString):api",
                                               hosts: [a, b]))
    }
}
