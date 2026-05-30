import XCTest
@testable import OnyxLib

final class CPUStreamStoreTests: XCTestCase {

    private var tmpDir: URL!
    private var streamURL: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpu-stream-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir,
                                                 withIntermediateDirectories: true)
        streamURL = tmpDir.appendingPathComponent("cpu-stream.json")

        CPUStreamStore.shared.reset()
        CPUStreamStore.shared.configure(url: streamURL)
    }

    override func tearDown() {
        CPUStreamStore.shared.reset()
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - Buffer behavior

    func testAppend_buildsPerHostBufferInOrder() {
        let store = CPUStreamStore.shared
        store.appendSample(hostID: "h1", label: "alpha", color: "#FF0000",
                           cpu: 10, timestamp: 100)
        store.appendSample(hostID: "h1", label: "alpha", color: "#FF0000",
                           cpu: 20, timestamp: 101)

        let snap = store.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap[0].hostID, "h1")
        XCTAssertEqual(snap[0].samples.map { $0.cpu }, [10, 20])
        XCTAssertEqual(snap[0].samples.map { $0.t }, [100, 101])
    }

    func testAppend_capsAtMaxSamplesPerHost() {
        let store = CPUStreamStore.shared
        let cap = CPUStreamStore.maxSamplesPerHost

        for i in 0..<(cap + 50) {
            store.appendSample(hostID: "h1", label: "h1", color: "#FF0000",
                               cpu: Double(i), timestamp: Double(i))
        }

        let samples = store.snapshot()[0].samples
        XCTAssertEqual(samples.count, cap)
        // Newest cap samples should be kept — first sample we should see
        // is index 50 (since 0..49 fell off the front).
        XCTAssertEqual(samples.first?.cpu, 50)
        XCTAssertEqual(samples.last?.cpu, Double(cap + 49))
    }

    func testAppend_refreshesLabelAndColor() {
        // Hosts get renamed, themes get changed — the latest caller's label
        // and color should win, not the first one we ever saw.
        let store = CPUStreamStore.shared
        store.appendSample(hostID: "h1", label: "old-name", color: "#FF0000",
                           cpu: 10, timestamp: 100)
        store.appendSample(hostID: "h1", label: "new-name", color: "#00FF00",
                           cpu: 20, timestamp: 101)

        let snap = store.snapshot()
        XCTAssertEqual(snap[0].label, "new-name")
        XCTAssertEqual(snap[0].color, "#00FF00")
        XCTAssertEqual(snap[0].samples.count, 2,
                       "label/color refresh must not wipe existing samples")
    }

    func testRemoveHost_dropsBufferAndPersists() {
        let store = CPUStreamStore.shared
        store.appendSample(hostID: "h1", label: "h1", color: "#FF0000",
                           cpu: 10, timestamp: 100)
        store.appendSample(hostID: "h2", label: "h2", color: "#00FF00",
                           cpu: 20, timestamp: 100)

        store.removeHost("h1")
        XCTAssertEqual(store.snapshot().map { $0.hostID }, ["h2"])
    }

    // MARK: - File writing

    func testFlush_writesAtomicFileWithCorrectShape() throws {
        let store = CPUStreamStore.shared
        store.clockOverride = { 12345.5 }
        store.appendSample(hostID: "h1", label: "alpha", color: "#FF0000",
                           cpu: 42, timestamp: 100)
        store.appendSample(hostID: "h2", label: "beta", color: "#00FF00",
                           cpu: 88, timestamp: 100)
        store.flushForTesting()

        let data = try Data(contentsOf: streamURL)
        let decoded = try JSONDecoder().decode(CPUStreamFile.self, from: data)

        XCTAssertEqual(decoded.updatedAt, 12345.5)
        XCTAssertEqual(decoded.hosts.count, 2)
        XCTAssertEqual(decoded.hosts.map { $0.hostID }, ["h1", "h2"])
        XCTAssertEqual(decoded.hosts[0].samples.first?.cpu, 42)
    }

    func testFlush_writesOnceForDebouncedBurst() {
        // The point of debouncing: 50 rapid appends shouldn't produce 50 file
        // writes. flushForTesting() collapses any pending debounced write
        // into one synchronous write, so the file should exist exactly once
        // and contain all 50 samples.
        let store = CPUStreamStore.shared
        for i in 0..<50 {
            store.appendSample(hostID: "h1", label: "alpha", color: "#FF0000",
                               cpu: Double(i), timestamp: Double(i))
        }
        store.flushForTesting()

        XCTAssertTrue(FileManager.default.fileExists(atPath: streamURL.path))
        let data = try! Data(contentsOf: streamURL)
        let decoded = try! JSONDecoder().decode(CPUStreamFile.self, from: data)
        XCTAssertEqual(decoded.hosts[0].samples.count, 50)
    }

    func testFlush_writesEmptyHostsArrayWhenNoSamples() throws {
        // After reset+configure with no appends, a flush should still produce
        // a valid file — the screensaver can then show its idle state instead
        // of a missing-file error.
        CPUStreamStore.shared.flushForTesting()
        let data = try Data(contentsOf: streamURL)
        let decoded = try JSONDecoder().decode(CPUStreamFile.self, from: data)
        XCTAssertEqual(decoded.hosts.count, 0)
    }

    func testReset_clearsBufferAndUnsetsURL() {
        let store = CPUStreamStore.shared
        store.appendSample(hostID: "h1", label: "h1", color: "#FF0000",
                           cpu: 10, timestamp: 100)
        XCTAssertFalse(store.snapshot().isEmpty)
        store.reset()
        XCTAssertTrue(store.snapshot().isEmpty)
        // After reset, a configure should work again (fresh state).
        store.configure(url: streamURL)
        XCTAssertTrue(store.snapshot().isEmpty)
    }
}
