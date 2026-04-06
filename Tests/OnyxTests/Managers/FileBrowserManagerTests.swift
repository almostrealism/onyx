import XCTest
@testable import OnyxLib

final class FileBrowserTests: XCTestCase {

    private func makeBrowser() -> FileBrowserManager {
        let state = AppState()
        state.hosts = [.localhost]
        return FileBrowserManager(appState: state)
    }

    // MARK: - parseLsOutput

    func testParseLsOutput_typicalLinux() {
        let browser = makeBrowser()
        let output = """
        total 48
        drwxr-xr-x  5 user group  4096 Jan 15 14:30 projects/
        -rw-r--r--  1 user group  1234 Jan 14 09:15 readme.md
        -rwxr-xr-x  1 user group 56789 Jan 13 18:00 build.sh
        drwxr-xr-x  2 user group  4096 Jan 12 12:00 .config/
        """

        let entries = browser.parseLsOutput(output)
        XCTAssertEqual(entries.count, 4)

        // Directories should sort before files
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertTrue(entries[1].isDirectory)
        XCTAssertFalse(entries[2].isDirectory)
        XCTAssertFalse(entries[3].isDirectory)

        // Directory names should have trailing / stripped
        XCTAssertEqual(entries[0].name, ".config")
        XCTAssertEqual(entries[1].name, "projects")
    }

    func testParseLsOutput_skipsDotEntries() {
        let browser = makeBrowser()
        let output = """
        total 16
        drwxr-xr-x  3 user group 4096 Jan 15 14:30 ./
        drwxr-xr-x  5 user group 4096 Jan 15 14:30 ../
        -rw-r--r--  1 user group  100 Jan 14 09:15 file.txt
        """

        let entries = browser.parseLsOutput(output)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "file.txt")
    }

    func testParseLsOutput_emptyDirectory() {
        let browser = makeBrowser()
        let output = "total 0\n"
        let entries = browser.parseLsOutput(output)
        XCTAssertTrue(entries.isEmpty)
    }

    func testParseLsOutput_emptyString() {
        let browser = makeBrowser()
        let entries = browser.parseLsOutput("")
        XCTAssertTrue(entries.isEmpty)
    }

    func testParseLsOutput_sizeAndModified() {
        let browser = makeBrowser()
        let output = """
        total 4
        -rw-r--r--  1 user group  9876 Mar  5 10:22 data.json
        """
        let entries = browser.parseLsOutput(output)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].size, "9876")
        XCTAssertEqual(entries[0].modified, "Mar 5 10:22")
    }

    // MARK: - escapeForShell

    func testEscapeForShell_simplePath() {
        let browser = makeBrowser()
        let result = browser.escapeForShell("/home/user/projects")
        XCTAssertEqual(result, "\"/home/user/projects\"")
    }

    func testEscapeForShell_pathWithSpaces() {
        let browser = makeBrowser()
        let result = browser.escapeForShell("/home/user/my projects")
        XCTAssertEqual(result, "\"/home/user/my projects\"")
    }

    func testEscapeForShell_pathWithDollar() {
        let browser = makeBrowser()
        let result = browser.escapeForShell("/home/$USER/test")
        XCTAssertEqual(result, "\"/home/\\$USER/test\"")
    }

    func testEscapeForShell_pathWithBacktick() {
        let browser = makeBrowser()
        let result = browser.escapeForShell("/home/user/`whoami`")
        XCTAssertEqual(result, "\"/home/user/\\`whoami\\`\"")
    }

    func testEscapeForShell_pathWithQuotes() {
        let browser = makeBrowser()
        let result = browser.escapeForShell("/home/user/file\"name")
        XCTAssertEqual(result, "\"/home/user/file\\\"name\"")
    }

    func testEscapeForShell_pathWithBackslash() {
        let browser = makeBrowser()
        let result = browser.escapeForShell("/home/user/back\\slash")
        XCTAssertEqual(result, "\"/home/user/back\\\\slash\"")
    }
}

// MARK: - Search Tree Tests

class SearchTreeTests: XCTestCase {

    func testInsertSingleFile() {
        let tree = SearchResultTree()
        tree.insertPath("hello.txt", basePath: "/root")

        XCTAssertEqual(tree.roots.count, 1)
        XCTAssertEqual(tree.roots[0].name, "hello.txt")
        XCTAssertEqual(tree.roots[0].fullPath, "/root/hello.txt")
        XCTAssertFalse(tree.roots[0].isDirectory)
        XCTAssertEqual(tree.resultCount, 1)
    }

    func testInsertFileInSubdirectory() {
        let tree = SearchResultTree()
        tree.insertPath("alpha/hello.txt", basePath: "/root")

        XCTAssertEqual(tree.roots.count, 1)
        XCTAssertEqual(tree.roots[0].name, "alpha")
        XCTAssertTrue(tree.roots[0].isDirectory)
        XCTAssertEqual(tree.roots[0].fullPath, "/root/alpha")
        XCTAssertEqual(tree.roots[0].children.count, 1)
        XCTAssertEqual(tree.roots[0].children[0].name, "hello.txt")
        XCTAssertFalse(tree.roots[0].children[0].isDirectory)
    }

    func testInsertMultipleFilesUnderSameDirectory() {
        let tree = SearchResultTree()
        tree.insertPath("alpha/Xya", basePath: "/root")
        tree.insertPath("alpha/Xyb", basePath: "/root")

        XCTAssertEqual(tree.roots.count, 1, "Should share the same 'alpha' root")
        XCTAssertEqual(tree.roots[0].name, "alpha")
        XCTAssertEqual(tree.roots[0].children.count, 2)
        XCTAssertEqual(tree.roots[0].children[0].name, "Xya")
        XCTAssertEqual(tree.roots[0].children[1].name, "Xyb")
        XCTAssertEqual(tree.resultCount, 2)
    }

    func testInsertFilesUnderDifferentRoots() {
        let tree = SearchResultTree()
        tree.insertPath("alpha/Xya", basePath: "/root")
        tree.insertPath("alpha/Xyb", basePath: "/root")
        tree.insertPath("beta/gamma/Xyc", basePath: "/root")
        tree.insertPath("beta/gamma/Xyd", basePath: "/root")

        XCTAssertEqual(tree.roots.count, 2, "Should have alpha and beta roots")

        // Roots should be sorted
        XCTAssertEqual(tree.roots[0].name, "alpha")
        XCTAssertEqual(tree.roots[1].name, "beta")

        // alpha has 2 children
        XCTAssertEqual(tree.roots[0].children.count, 2)

        // beta has gamma, which has 2 children
        XCTAssertEqual(tree.roots[1].children.count, 1)
        XCTAssertEqual(tree.roots[1].children[0].name, "gamma")
        XCTAssertTrue(tree.roots[1].children[0].isDirectory)
        XCTAssertEqual(tree.roots[1].children[0].children.count, 2)
        XCTAssertEqual(tree.roots[1].children[0].children[0].name, "Xyc")
        XCTAssertEqual(tree.roots[1].children[0].children[1].name, "Xyd")

        XCTAssertEqual(tree.resultCount, 4)
    }

    func testInsertDeepNestedPath() {
        let tree = SearchResultTree()
        tree.insertPath("a/b/c/d/e/file.txt", basePath: "/root")

        XCTAssertEqual(tree.roots.count, 1)
        var node = tree.roots[0]
        XCTAssertEqual(node.name, "a")
        XCTAssertTrue(node.isDirectory)

        node = node.children[0]
        XCTAssertEqual(node.name, "b")
        XCTAssertTrue(node.isDirectory)

        node = node.children[0]
        XCTAssertEqual(node.name, "c")
        XCTAssertTrue(node.isDirectory)

        node = node.children[0]
        XCTAssertEqual(node.name, "d")
        XCTAssertTrue(node.isDirectory)

        node = node.children[0]
        XCTAssertEqual(node.name, "e")
        XCTAssertTrue(node.isDirectory)

        node = node.children[0]
        XCTAssertEqual(node.name, "file.txt")
        XCTAssertFalse(node.isDirectory)
        XCTAssertEqual(node.fullPath, "/root/a/b/c/d/e/file.txt")
    }

    func testMaxResultsLimit() {
        let tree = SearchResultTree()
        for i in 0..<150 {
            tree.insertPath("file\(i).txt", basePath: "/root")
        }
        XCTAssertEqual(tree.resultCount, 100, "Should cap at maxResults")
        XCTAssertEqual(tree.roots.count, 100)
    }

    func testClear() {
        let tree = SearchResultTree()
        tree.insertPath("alpha/file.txt", basePath: "/root")
        tree.insertPath("beta/file.txt", basePath: "/root")
        XCTAssertEqual(tree.resultCount, 2)

        tree.clear()
        XCTAssertEqual(tree.roots.count, 0)
        XCTAssertEqual(tree.resultCount, 0)
    }

    func testInsertEmptyPath() {
        let tree = SearchResultTree()
        tree.insertPath("", basePath: "/root")
        XCTAssertEqual(tree.roots.count, 0, "Empty path should be ignored")
        XCTAssertEqual(tree.resultCount, 0)
    }

    func testInsertDirectoryAsLeaf() {
        // When a directory name itself matches (last component = directory)
        // The current logic marks only the last component as a file,
        // so inserting "alpha" creates a file node named "alpha"
        let tree = SearchResultTree()
        tree.insertPath("alpha", basePath: "/root")
        XCTAssertEqual(tree.roots.count, 1)
        XCTAssertEqual(tree.roots[0].name, "alpha")
        // Single component is treated as a file (last component)
        XCTAssertFalse(tree.roots[0].isDirectory)
    }

    func testFullPathsAreCorrect() {
        let tree = SearchResultTree()
        tree.insertPath("src/main/java/Foo.java", basePath: "/home/user/project")

        XCTAssertEqual(tree.roots[0].fullPath, "/home/user/project/src")
        XCTAssertEqual(tree.roots[0].children[0].fullPath, "/home/user/project/src/main")
        XCTAssertEqual(tree.roots[0].children[0].children[0].fullPath, "/home/user/project/src/main/java")
        XCTAssertEqual(tree.roots[0].children[0].children[0].children[0].fullPath, "/home/user/project/src/main/java/Foo.java")
    }

    func testBasePathWithTrailingSlash() {
        let tree = SearchResultTree()
        tree.insertPath("file.txt", basePath: "/root/")

        XCTAssertEqual(tree.roots[0].fullPath, "/root/file.txt")
    }

    func testChildrenAreSorted() {
        let tree = SearchResultTree()
        tree.insertPath("dir/zebra.txt", basePath: "/root")
        tree.insertPath("dir/apple.txt", basePath: "/root")
        tree.insertPath("dir/mango.txt", basePath: "/root")

        XCTAssertEqual(tree.roots[0].children.count, 3)
        XCTAssertEqual(tree.roots[0].children[0].name, "apple.txt")
        XCTAssertEqual(tree.roots[0].children[1].name, "mango.txt")
        XCTAssertEqual(tree.roots[0].children[2].name, "zebra.txt")
    }

    func testRootsAreSorted() {
        let tree = SearchResultTree()
        tree.insertPath("zulu/file.txt", basePath: "/root")
        tree.insertPath("alpha/file.txt", basePath: "/root")
        tree.insertPath("middle/file.txt", basePath: "/root")

        XCTAssertEqual(tree.roots[0].name, "alpha")
        XCTAssertEqual(tree.roots[1].name, "middle")
        XCTAssertEqual(tree.roots[2].name, "zulu")
    }

    func testSharedIntermediateDirectories() {
        let tree = SearchResultTree()
        tree.insertPath("src/main/Foo.java", basePath: "/root")
        tree.insertPath("src/main/Bar.java", basePath: "/root")
        tree.insertPath("src/test/FooTest.java", basePath: "/root")

        XCTAssertEqual(tree.roots.count, 1, "Single src root")
        let src = tree.roots[0]
        XCTAssertEqual(src.children.count, 2, "main and test under src")
        XCTAssertEqual(src.children[0].name, "main")
        XCTAssertEqual(src.children[0].children.count, 2, "Bar.java and Foo.java")
        XCTAssertEqual(src.children[1].name, "test")
        XCTAssertEqual(src.children[1].children.count, 1, "FooTest.java")
    }
}

// MARK: - Search Command Tests

class SearchCommandTests: XCTestCase {

    func testSearchCommand_localHost() {
        // Verify the find command can actually execute and return results
        let process = Process()
        let pipe = Pipe()
        let testDir = "/Users/worker/Projects/onyx"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "find \"\(testDir)\" -maxdepth 10 -name \".*\" -prune -o -iname \"*Package*\" -print 2>/dev/null | head -100"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try! process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        XCTAssertFalse(lines.isEmpty, "find command should return results for 'Package' in onyx repo")
        XCTAssertTrue(lines.contains { $0.contains("Package.swift") }, "Should find Package.swift")
    }

    func testSearchCommand_noSingleQuotes() {
        // The find command must NOT contain single quotes since remoteCommand wraps in single quotes
        let appState = AppState()
        let browser = FileBrowserManager(appState: appState)

        // Simulate what startSearch builds
        let query = "test"
        let basePath = "/home/user/project"
        let escaped = browser.escapeForShell(basePath)
        let safeQuery = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "find \(escaped) -maxdepth 10 -name \".*\" -prune -o -iname \"*\(safeQuery)*\" -print 2>/dev/null | head -100"

        XCTAssertFalse(script.contains("'"), "Script must not contain single quotes — remoteCommand wraps in single quotes")
        XCTAssertTrue(script.contains("-iname \"*test*\""), "Should use double-quoted iname pattern")
        XCTAssertTrue(script.contains("-name \".*\""), "Should use double-quoted hidden dir pattern")
    }

    func testSearchCommand_specialCharactersEscaped() {
        let appState = AppState()
        let browser = FileBrowserManager(appState: appState)

        let query = "test\"file"
        let safeQuery = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escaped = browser.escapeForShell("/home/user")
        let script = "find \(escaped) -maxdepth 10 -name \".*\" -prune -o -iname \"*\(safeQuery)*\" -print 2>/dev/null | head -100"

        XCTAssertTrue(script.contains("test\\\"file"), "Double quotes in query should be escaped")
    }

    func testSearchCommand_endToEnd_local() {
        // Full end-to-end test: run the actual find command locally
        let process = Process()
        let pipe = Pipe()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        // Search for "OnyxApp" in the onyx project
        process.arguments = ["-lc", "find \"/Users/worker/Projects/onyx/Sources\" -maxdepth 10 -name \".*\" -prune -o -iname \"*OnyxApp*\" -print 2>/dev/null | head -100"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try! process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        XCTAssertFalse(lines.isEmpty, "Should find OnyxApp files")
        XCTAssertTrue(lines.contains { $0.hasSuffix("OnyxApp.swift") }, "Should find OnyxApp.swift")
    }

    func testSearchCommand_hiddenDirsPruned() {
        // Verify hidden directories are excluded from results
        let process = Process()
        let pipe = Pipe()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        // Search broadly — should not include .build or .git paths
        process.arguments = ["-lc", "find \"/Users/worker/Projects/onyx\" -maxdepth 10 -name \".*\" -prune -o -iname \"*swift*\" -print 2>/dev/null | head -100"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try! process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        XCTAssertFalse(lines.isEmpty, "Should find swift files")
        for line in lines {
            XCTAssertFalse(line.contains("/.build/"), "Should not include .build directory: \(line)")
            XCTAssertFalse(line.contains("/.git/"), "Should not include .git directory: \(line)")
        }
    }

    func testSearchResultTree_progressiveInsert() {
        // Simulate progressive insertion as find results arrive
        let tree = SearchResultTree()
        let basePath = "/Users/worker/Projects/onyx"

        // Simulate lines arriving from find
        let findResults = [
            "/Users/worker/Projects/onyx/Sources/OnyxApp/OnyxApp.swift",
            "/Users/worker/Projects/onyx/Sources/OnyxLib/AppState.swift",
            "/Users/worker/Projects/onyx/Sources/OnyxLib/ContentView.swift",
        ]

        let baseForStripping = basePath + "/"
        for result in findResults {
            let relative = String(result.dropFirst(baseForStripping.count))
            tree.insertPath(relative, basePath: basePath)
        }

        XCTAssertEqual(tree.resultCount, 3)
        XCTAssertEqual(tree.roots.count, 1, "All under Sources")
        XCTAssertEqual(tree.roots[0].name, "Sources")

        let sources = tree.roots[0]
        XCTAssertEqual(sources.children.count, 2, "OnyxApp and OnyxLib")
        XCTAssertEqual(sources.children[0].name, "OnyxApp")
        XCTAssertEqual(sources.children[0].children.count, 1)
        XCTAssertEqual(sources.children[1].name, "OnyxLib")
        XCTAssertEqual(sources.children[1].children.count, 2)
    }
}
