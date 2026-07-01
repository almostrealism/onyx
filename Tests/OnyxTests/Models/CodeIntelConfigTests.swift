import XCTest
@testable import OnyxLib

/// Back-compat tests for CodeIntelConfig on HostConfig. Hosts decode with
/// `try?` (AppState), so a decode failure silently wipes the user's entire
/// host list — old hosts.json without `codeIntel` MUST still decode.
final class CodeIntelConfigTests: XCTestCase {

    func test_decode_legacyHostWithoutCodeIntel_getsDefaults() throws {
        // A hosts.json written before code intelligence existed.
        let legacy = """
        {"id":"11111111-1111-1111-1111-111111111111","label":"prod",
         "ssh":{"host":"example.com","user":"me","port":22,
                "tmuxSession":"onyx","identityFile":""}}
        """
        let host = try JSONDecoder().decode(HostConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(host.label, "prod")
        XCTAssertTrue(host.codeIntel.enabled, "default enabled")
        XCTAssertEqual(host.codeIntel.jdtlsPath, "~/.onyx/jdtls/bin/jdtls")
        XCTAssertEqual(host.codeIntel.heapMB, 0)
    }

    func test_legacyHostArray_decodes(){
        // The exact path AppState uses: decode([HostConfig]) with try?.
        let legacy = """
        [{"id":"22222222-2222-2222-2222-222222222222","label":"a",
          "ssh":{"host":"h","user":"u","port":22,"tmuxSession":"onyx","identityFile":""}}]
        """
        let hosts = try? JSONDecoder().decode([HostConfig].self, from: Data(legacy.utf8))
        XCTAssertEqual(hosts?.count, 1, "legacy array must not silently drop to nil")
    }

    func test_roundtrip_preservesCodeIntel() throws {
        var host = HostConfig(label: "dev")
        host.codeIntel = CodeIntelConfig(enabled: false, jdtlsPath: "/opt/jdtls/bin/jdtls", heapMB: 2048)
        let data = try JSONEncoder().encode(host)
        let back = try JSONDecoder().decode(HostConfig.self, from: data)
        XCTAssertEqual(back.codeIntel.enabled, false)
        XCTAssertEqual(back.codeIntel.jdtlsPath, "/opt/jdtls/bin/jdtls")
        XCTAssertEqual(back.codeIntel.heapMB, 2048)
    }

    func test_defaultHost_hasCodeIntelEnabled() {
        XCTAssertTrue(HostConfig(label: "x").codeIntel.enabled)
    }
}
