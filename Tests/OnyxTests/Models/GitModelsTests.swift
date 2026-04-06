import XCTest
@testable import OnyxLib

// MARK: - Git Parser Tests

final class GitParserTests: XCTestCase {

    private func makeGitManager() -> GitManager {
        let state = AppState()
        return GitManager(appState: state)
    }

    // MARK: - parseGitStatusPorcelain

    func testParseGitStatus_modifiedFile() {
        let gm = makeGitManager()
        let files = gm.parseGitStatusPorcelain(" M src/main.swift")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "src/main.swift")
        XCTAssertEqual(files[0].status, .modified)
        XCTAssertEqual(files[0].area, .unstaged)
    }

    func testParseGitStatus_stagedFile() {
        let gm = makeGitManager()
        let files = gm.parseGitStatusPorcelain("M  src/main.swift")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].status, .modified)
        XCTAssertEqual(files[0].area, .staged)
    }

    func testParseGitStatus_stagedAndUnstaged() {
        let gm = makeGitManager()
        let files = gm.parseGitStatusPorcelain("MM src/main.swift")
        XCTAssertEqual(files.count, 2) // one staged, one unstaged
        XCTAssertTrue(files.contains(where: { $0.area == .staged }))
        XCTAssertTrue(files.contains(where: { $0.area == .unstaged }))
    }

    func testParseGitStatus_addedFile() {
        let gm = makeGitManager()
        let files = gm.parseGitStatusPorcelain("A  newfile.swift")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].status, .added)
        XCTAssertEqual(files[0].area, .staged)
    }

    func testParseGitStatus_deletedFile() {
        let gm = makeGitManager()
        let files = gm.parseGitStatusPorcelain(" D oldfile.swift")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].status, .deleted)
        XCTAssertEqual(files[0].area, .unstaged)
    }

    func testParseGitStatus_untrackedFile() {
        let gm = makeGitManager()
        let files = gm.parseGitStatusPorcelain("?? new_untracked.txt")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].status, .untracked)
        XCTAssertEqual(files[0].area, .untracked)
        XCTAssertEqual(files[0].path, "new_untracked.txt")
    }

    func testParseGitStatus_multipleFiles() {
        let gm = makeGitManager()
        let output = """
        M  staged.swift
         M unstaged.swift
        ?? untracked.txt
        A  added.swift
         D deleted.swift
        """
        let files = gm.parseGitStatusPorcelain(output)
        XCTAssertEqual(files.count, 5)
    }

    func testParseGitStatus_empty() {
        let gm = makeGitManager()
        let files = gm.parseGitStatusPorcelain("")
        XCTAssertTrue(files.isEmpty)
    }

    func testParseGitStatus_renamedFile() {
        let gm = makeGitManager()
        let files = gm.parseGitStatusPorcelain("R  old.swift -> new.swift")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].status, .renamed)
        XCTAssertEqual(files[0].area, .staged)
    }

    // MARK: - parseDiffStat

    func testParseDiffStat_typical() {
        let gm = makeGitManager()
        let output = """
         src/main.swift  | 10 +++++++---
         src/utils.swift |  5 ++---
         3 files changed, 45 insertions(+), 12 deletions(-)
        """
        let stats = gm.parseDiffStat(output)
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.filesChanged, 3)
        XCTAssertEqual(stats?.insertions, 45)
        XCTAssertEqual(stats?.deletions, 12)
    }

    func testParseDiffStat_singleFile() {
        let gm = makeGitManager()
        let output = " 1 file changed, 2 insertions(+)"
        let stats = gm.parseDiffStat(output)
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.filesChanged, 1)
        XCTAssertEqual(stats?.insertions, 2)
        XCTAssertEqual(stats?.deletions, 0)
    }

    func testParseDiffStat_deletionsOnly() {
        let gm = makeGitManager()
        let output = " 1 file changed, 5 deletions(-)"
        let stats = gm.parseDiffStat(output)
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.filesChanged, 1)
        XCTAssertEqual(stats?.insertions, 0)
        XCTAssertEqual(stats?.deletions, 5)
    }

    func testParseDiffStat_empty() {
        let gm = makeGitManager()
        let stats = gm.parseDiffStat("")
        XCTAssertNil(stats)
    }

    func testParseDiffStat_noChanges() {
        let gm = makeGitManager()
        let stats = gm.parseDiffStat("no changes at all")
        XCTAssertNil(stats)
    }

    // MARK: - GitRepoStatus computed properties

    func testGitRepoStatus_isClean() {
        let status = GitRepoStatus(branch: "main", isDetachedHead: false, changedFiles: [], diffStats: nil)
        XCTAssertTrue(status.isClean)
        XCTAssertTrue(status.stagedFiles.isEmpty)
        XCTAssertTrue(status.unstagedFiles.isEmpty)
        XCTAssertTrue(status.untrackedFiles.isEmpty)
    }

    func testGitRepoStatus_filtersAreas() {
        let files = [
            GitChangedFile(path: "a.swift", status: .modified, area: .staged),
            GitChangedFile(path: "b.swift", status: .modified, area: .unstaged),
            GitChangedFile(path: "c.txt", status: .untracked, area: .untracked),
            GitChangedFile(path: "d.swift", status: .added, area: .staged),
        ]
        let status = GitRepoStatus(branch: "main", isDetachedHead: false, changedFiles: files, diffStats: nil)
        XCTAssertFalse(status.isClean)
        XCTAssertEqual(status.stagedFiles.count, 2)
        XCTAssertEqual(status.unstagedFiles.count, 1)
        XCTAssertEqual(status.untrackedFiles.count, 1)
    }
}

