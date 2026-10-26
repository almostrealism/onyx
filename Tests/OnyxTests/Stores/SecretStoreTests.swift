import XCTest
@testable import OnyxCore

/// Tokens moved from UserDefaults to the Keychain, syncing through iCloud
/// where the build may. These never touch the real Keychain: the backends
/// are in memory, and a file backend writes only to a temp folder.
final class SecretStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "SecretStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testATokenInDefaultsMovesOnFirstReadAndLeavesDefaults() {
        defaults.set("ghp_abc", forKey: "github_token")
        let synced = InMemorySecretBackend()
        let store = SecretStore(synced: synced, local: InMemorySecretBackend(), defaults: defaults)
        XCTAssertEqual(store.get(.githubToken), "ghp_abc")
        XCTAssertEqual(synced.read(.githubToken), "ghp_abc")
        XCTAssertNil(defaults.string(forKey: "github_token"), "one copy, in the Keychain")
        XCTAssertEqual(store.syncsToOtherDevices, true)
    }

    /// A build without the entitlement keeps secrets on this device, and
    /// says so.
    func testWithoutTheEntitlementSecretsStayLocal() {
        let synced = InMemorySecretBackend(available: false)
        let local = InMemorySecretBackend()
        let store = SecretStore(synced: synced, local: local, defaults: defaults)
        store.set(.timingToken, "tok")
        XCTAssertEqual(local.read(.timingToken), "tok")
        XCTAssertNil(synced.read(.timingToken))
        XCTAssertEqual(store.syncsToOtherDevices, false)
        store.reload()
        XCTAssertEqual(store.get(.timingToken), "tok")
    }

    /// Nowhere to put it: the token stays in defaults rather than vanish.
    func testAFailedMoveNeverLosesTheToken() {
        defaults.set("glpat", forKey: "gitlab_token")
        let store = SecretStore(synced: InMemorySecretBackend(available: false), local: nil, defaults: defaults)
        XCTAssertEqual(store.get(.gitlabToken), "glpat")
        XCTAssertEqual(defaults.string(forKey: "gitlab_token"), "glpat")
    }

    func testEmptyDeletesEverywhere() {
        let synced = InMemorySecretBackend()
        let local = InMemorySecretBackend()
        try? local.write(.githubToken, "old")
        let store = SecretStore(synced: synced, local: local, defaults: defaults)
        store.set(.githubToken, "new")
        XCTAssertNil(local.read(.githubToken), "a synced write removes the local copy")
        store.set(.githubToken, "")
        XCTAssertNil(synced.read(.githubToken))
        XCTAssertEqual(store.get(.githubToken), "")
    }

    func testTheFileBackendWritesPrivately() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("secrets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = FileSecretBackend(directory: dir)
        try files.write(.sshPrivateKey, "k1")
        try files.write(.sshPrivateKey, "k2")
        XCTAssertEqual(files.read(.sshPrivateKey), "k2")
        let fileMode = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent(SecretKey.sshPrivateKey.rawValue).path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(dirMode, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 1,
                       "no temp files left behind")
        files.delete(.sshPrivateKey)
        XCTAssertNil(files.read(.sshPrivateKey))
    }

    /// The process-wide store never reaches the real Keychain from tests.
    func testTestsUseMemory() {
        XCTAssertTrue(SecretStore.isRunningTests)
    }
}
