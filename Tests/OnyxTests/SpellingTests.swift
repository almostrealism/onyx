import XCTest
@testable import OnyxLib

/// Spellings that are settled, so they stop drifting back.
///
/// "favourite" had spread through comments, UI strings, test names and the
/// website while the DATA structures said `favorites` — so the code
/// disagreed with itself about the name of its own feature, and every new
/// line was a coin toss. The product is US English; this is the ratchet.
///
/// Scanning source text is a blunt instrument and deliberately narrow: it
/// covers the one word that actually caused the problem rather than
/// policing English generally.
final class SpellingTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OnyxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
    }

    private func swiftFiles(under directory: String) -> [URL] {
        let base = root.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(at: base,
                                                          includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    func testTheCodeSaysFavoriteEverywhere() throws {
        var offenders: [String] = []
        // This file is exempt: it has to name the word in order to look
        // for it, and a checker that fails on itself is just noise.
        let selfPath = URL(fileURLWithPath: #filePath).standardizedFileURL.path
        for directory in ["Sources", "Tests"] {
            for file in swiftFiles(under: directory)
            where file.standardizedFileURL.path != selfPath {
                let text = try String(contentsOf: file, encoding: .utf8)
                guard text.range(of: "favourit", options: .caseInsensitive) != nil else { continue }
                offenders.append(file.lastPathComponent)
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      """
                      US spelling: "favorite", not "favourite" — in comments and test \
                      names as much as in code, since the stored data has always said \
                      `favorites` and the mismatch is what made it spread. Found in: \
                      \(offenders.sorted().joined(separator: ", "))
                      """)
    }

    /// The rest of the sweep, kept from drifting back.
    ///
    /// Deliberately a list of STEMS that only ever continue one way —
    /// "analysis" and "emphasis" are correct US English and are not here,
    /// which is why this checks `analyse` and `emphasise` as whole words
    /// instead. If a legitimate identifier ever needs one of these (an
    /// Apple API spelled `grey`, say), narrow the entry rather than
    /// deleting the test.
    func testTheCodeUsesUSSpelling() throws {
        let stems = ["colour", "behaviour", "neighbour", "honour", "favour", "humour",
                     "flavour", "labour", "normalis", "recognis", "organis", "minimis",
                     "maximis", "optimis", "summaris", "prioritis", "synchronis",
                     "initialis", "customis", "serialis", "defence", "licence", "grey",
                     "labelled", "acknowledgement", "artefact", "judgement", "centre",
                     "whilst", "amongst", "sceptic", "manoeuvr", "programme"]
        let words = ["emphasise", "emphasised", "emphasising",
                     "analyse", "analysed", "analysing", "practise"]

        let selfPath = URL(fileURLWithPath: #filePath).standardizedFileURL.path
        var offenders: [String] = []
        for directory in ["Sources", "Tests"] {
            for file in swiftFiles(under: directory)
            where file.standardizedFileURL.path != selfPath {
                let text = try String(contentsOf: file, encoding: .utf8).lowercased()
                for stem in stems where text.contains(stem) {
                    offenders.append("\(file.lastPathComponent): \(stem)")
                }
                for word in words
                where text.range(of: "\\b\(word)\\b", options: .regularExpression) != nil {
                    offenders.append("\(file.lastPathComponent): \(word)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "US spelling, in comments as much as in code — found: "
                      + offenders.sorted().joined(separator: ", "))
    }

    /// The stored keys are the reason the spelling matters: they're on
    /// disk, in `favorites.json`, and in the shared-state bundle other
    /// machines read. Renaming them would be a migration, so they're
    /// asserted here rather than trusted.
    func testTheStoredFieldNamesAreUSSpelling() throws {
        let state = SharedState(favorites: [FavoriteEntry(sessionID: "k", windows: [0])])
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(state), encoding: .utf8))
        XCTAssertTrue(json.contains("\"favorites\""))
        XCTAssertFalse(json.lowercased().contains("favourite"))
    }
}
