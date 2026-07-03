import XCTest
@testable import OnyxLib

final class JDTLSBootstrapTests: XCTestCase {

    // MARK: java version parsing

    func test_parseJavaMajor_modern() {
        XCTAssertEqual(JDTLSBootstrap.parseJavaMajor(#"openjdk version "21.0.2" 2024-01-16 LTS"#), 21)
        XCTAssertEqual(JDTLSBootstrap.parseJavaMajor(#"openjdk version "17.0.9""#), 17)
    }

    func test_parseJavaMajor_legacy1Dot8() {
        XCTAssertEqual(JDTLSBootstrap.parseJavaMajor(#"java version "1.8.0_401""#), 8)
    }

    func test_parseJavaMajor_unquotedDoubleDashFormat() {
        // `java --version` output has no quotes.
        XCTAssertEqual(JDTLSBootstrap.parseJavaMajor("java 21.0.2 2024-01-16 LTS"), 21)
        XCTAssertEqual(JDTLSBootstrap.parseJavaMajor("openjdk 17.0.9 2023-10-17"), 17)
    }

    func test_parseJavaMajor_garbage() {
        XCTAssertNil(JDTLSBootstrap.parseJavaMajor("command not found: java"))
        XCTAssertNil(JDTLSBootstrap.parseJavaMajor(""))
        // The conda "Picked up" noise line must NOT parse as a version.
        XCTAssertNil(JDTLSBootstrap.parseJavaMajor("Picked up JAVA_TOOL_OPTIONS: -Dfile.encoding=UTF-8"))
    }

    // MARK: preflight parsing + derived flags

    func test_parsePreflight_allPresentJava21() {
        let out = """
        JAVA_LINE=openjdk version "21.0.2" 2024-01-16 LTS
        PY=yes
        JDTLS=yes
        """
        let p = JDTLSBootstrap.parsePreflight(out)
        XCTAssertEqual(p.javaMajor, 21)
        XCTAssertTrue(p.hasPython)
        XCTAssertTrue(p.hasJDTLS)
        XCTAssertTrue(p.javaOK)
        XCTAssertFalse(p.canInstall, "already installed — nothing to install")
    }

    func test_parsePreflight_jdtlsMissingButInstallable() {
        let out = """
        JAVA_LINE=openjdk version "21.0.2"
        PY=yes
        JDTLS=no
        """
        let p = JDTLSBootstrap.parsePreflight(out)
        XCTAssertTrue(p.canInstall, "java21 + python + no jdtls → offer install")
    }

    func test_parsePreflight_javaTooOld_notInstallable() {
        let out = """
        JAVA_LINE=java version "1.8.0_401"
        PY=yes
        JDTLS=no
        """
        let p = JDTLSBootstrap.parsePreflight(out)
        XCTAssertFalse(p.javaOK)
        XCTAssertFalse(p.canInstall, "Java 8 can't run jdtls — don't offer install")
    }

    func test_parsePreflight_noPython_notInstallable() {
        let out = "JAVA_LINE=openjdk version \"21\"\nPY=no\nJDTLS=no"
        XCTAssertFalse(JDTLSBootstrap.parsePreflight(out).canInstall)
    }

    // MARK: script shape

    func test_preflightScript_probesAllThree() {
        let s = JDTLSBootstrap.preflightScript(jdtlsPath: "~/.onyx/jdtls/bin/jdtls")
        XCTAssertTrue(s.contains("-version"))
        XCTAssertTrue(s.contains("python3"))
        XCTAssertTrue(s.contains("~/.onyx/jdtls/bin/jdtls"), "jdtls path unquoted so ~ expands")
        // Must skip the JAVA_TOOL_OPTIONS "Picked up" noise and grab the real
        // version line, not blindly take head -1.
        XCTAssertTrue(s.contains("picked up"), "should filter the Picked up noise line")
        XCTAssertTrue(s.contains("grep -i 'version'"), "should extract the version line")
        // Robust java resolution: PATH, then JAVA_HOME, then macOS java_home.
        XCTAssertTrue(s.contains("JAVA_HOME"), "should fall back to JAVA_HOME")
        XCTAssertTrue(s.contains("java_home"), "should fall back to macOS java_home")
    }

    func test_parsePreflight_capturesRawJavaLine() {
        let out = "JAVA_LINE=openjdk version \"21.0.2\"\nPY=yes\nJDTLS=no"
        let p = JDTLSBootstrap.parsePreflight(out)
        XCTAssertEqual(p.javaLine, "openjdk version \"21.0.2\"")
        XCTAssertEqual(p.javaMajor, 21)
    }

    func test_parsePreflight_emptyJavaLine_isNil() {
        // No java anywhere → empty JAVA_LINE → nil (not an empty string).
        let p = JDTLSBootstrap.parsePreflight("JAVA_LINE=\nPY=yes\nJDTLS=no")
        XCTAssertNil(p.javaLine)
        XCTAssertNil(p.javaMajor)
    }

    func test_installDir_derivedFromLauncherPath() {
        XCTAssertEqual(JDTLSBootstrap.installDir(forJDTLSPath: "/opt/jdtls/bin/jdtls"), "/opt/jdtls")
        XCTAssertEqual(JDTLSBootstrap.installDir(forJDTLSPath: "~/.onyx/jdtls/bin/jdtls"), "~/.onyx/jdtls")
        XCTAssertEqual(JDTLSBootstrap.installDir(forJDTLSPath: "/weird/path"), "~/.onyx/jdtls")
    }

    func test_installScript_downloadsAndVerifies() {
        let s = JDTLSBootstrap.installScript(installDir: "~/.onyx/jdtls")
        XCTAssertTrue(s.contains("curl"))
        XCTAssertTrue(s.contains(JDTLSBootstrap.downloadURL))
        XCTAssertTrue(s.contains("tar xz"))
        XCTAssertTrue(s.contains("INSTALL_OK"))
        XCTAssertTrue(JDTLSBootstrap.installSucceeded(in: "some output\nINSTALL_OK\n"))
        XCTAssertFalse(JDTLSBootstrap.installSucceeded(in: "INSTALL_FAIL"))
    }
}
