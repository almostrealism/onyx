import XCTest
@testable import OnyxLib

final class DockerStatsParseTests: XCTestCase {

    func testParse_typicalOutput() {
        let output = """
        nginx|0.05%|12.34MiB / 7.656GiB|1.2kB / 0B|0B / 0B|5
        redis|1.23%|45.6MiB / 7.656GiB|500B / 200B|4.1kB / 0B|4
        """
        let (_, stats) = DockerStatsManager.parse(output: output)
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats[0].name, "nginx")
        XCTAssertEqual(stats[0].cpu, "0.05%")
        XCTAssertEqual(stats[0].memUsage, "12.34MiB / 7.656GiB")
        XCTAssertEqual(stats[0].pids, "5")
        XCTAssertEqual(stats[1].name, "redis")
        XCTAssertEqual(stats[1].cpu, "1.23%")
        XCTAssertEqual(stats[1].pids, "4")
    }

    func testParse_emptyOutput() {
        XCTAssertEqual(DockerStatsManager.parse(output: "").containers.count, 0)
        XCTAssertEqual(DockerStatsManager.parse(output: "\n\n").containers.count, 0)
    }

    func testParse_malformedLine() {
        let output = "incomplete|data\ngood|1%|10MiB / 1GiB|0B / 0B|0B / 0B|2"
        let (_, stats) = DockerStatsManager.parse(output: output)
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].name, "good")
    }

    func testParse_singleContainer() {
        let output = "myapp|50.00%|256MiB / 4GiB|10kB / 5kB|1MB / 500kB|12\n"
        let (_, stats) = DockerStatsManager.parse(output: output)
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].name, "myapp")
        XCTAssertEqual(stats[0].cpu, "50.00%")
        XCTAssertEqual(stats[0].netIO, "10kB / 5kB")
        XCTAssertEqual(stats[0].blockIO, "1MB / 500kB")
        XCTAssertEqual(stats[0].pids, "12")
    }

    func testParse_withCoresLine() {
        let output = "CORES=12\nnginx|150.00%|64MiB / 8GiB|1kB / 0B|0B / 0B|8\n"
        let (cores, stats) = DockerStatsManager.parse(output: output)
        XCTAssertEqual(cores, 12)
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].name, "nginx")
    }

    func testParse_defaultCoresWhenMissing() {
        let output = "app|1%|10MiB / 1GiB|0B / 0B|0B / 0B|1"
        let (cores, _) = DockerStatsManager.parse(output: output)
        XCTAssertEqual(cores, 1)
    }
}

final class MonitorParseTests: XCTestCase {

    // MARK: - parseSizeMB

    func testParseSizeMB_gigabytes() {
        XCTAssertEqual(MonitorManager.parseSizeMB("127G"), 127 * 1024)
        XCTAssertEqual(MonitorManager.parseSizeMB("1g"), 1024)
    }

    func testParseSizeMB_megabytes() {
        XCTAssertEqual(MonitorManager.parseSizeMB("512M"), 512)
        XCTAssertEqual(MonitorManager.parseSizeMB("121m"), 121)
    }

    func testParseSizeMB_kilobytes() {
        let result = MonitorManager.parseSizeMB("4096K")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 4.0, accuracy: 0.001)

        let result2 = MonitorManager.parseSizeMB("1024k")
        XCTAssertEqual(result2!, 1.0, accuracy: 0.001)
    }

    func testParseSizeMB_plainNumber() {
        XCTAssertEqual(MonitorManager.parseSizeMB("256"), 256)
    }

    func testParseSizeMB_withWhitespace() {
        XCTAssertEqual(MonitorManager.parseSizeMB("  512M  "), 512)
    }

    func testParseSizeMB_invalidInput() {
        XCTAssertNil(MonitorManager.parseSizeMB("abc"))
    }

    // MARK: - parse() with Linux output

    func testParseLinuxOutput() {
        let output = "---UPTIME---\n 14:32:01 up 45 days,  3:12,  2 users,  load average: 1.23, 0.98, 0.76\n---CPU---\ntop - 14:32:01 up 45 days,  3:12,  2 users,  load average: 1.23, 0.98, 0.76\nTasks: 312 total,   1 running, 311 sleeping,   0 stopped,   0 zombie\n%Cpu(s):  2.3 us,  1.0 sy,  0.0 ni, 96.7 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st\nMiB Mem :  15896.0 total,   2345.2 free,   8934.1 used,   4616.7 buff/cache\nMiB Swap:   2048.0 total,   2048.0 free,      0.0 used.   6429.3 avail Mem\n---MEM---\n              total        used        free      shared  buff/cache   available\nMem:          15896        8934        2345         234        4616        6429\nSwap:          2048           0        2048\n---GPU---\n45, 32, 67, NVIDIA GeForce RTX 3090"

        let sample = MonitorManager.parse(output: output)
        XCTAssertNotNil(sample)
        guard let sample = sample else { return }

        // Load averages
        if let la1 = sample.loadAvg1 {
            XCTAssertEqual(la1, 1.23, accuracy: 0.01)
        } else {
            XCTFail("loadAvg1 is nil")
        }
        if let la5 = sample.loadAvg5 {
            XCTAssertEqual(la5, 0.98, accuracy: 0.01)
        } else {
            XCTFail("loadAvg5 is nil")
        }
        if let la15 = sample.loadAvg15 {
            XCTAssertEqual(la15, 0.76, accuracy: 0.01)
        } else {
            XCTFail("loadAvg15 is nil")
        }

        // CPU: 100 - 96.7 = 3.3
        if let cpu = sample.cpuUsage {
            XCTAssertEqual(cpu, 3.3, accuracy: 0.1)
        } else {
            XCTFail("cpuUsage is nil")
        }

        // MEM: from "Mem:" line
        if let memT = sample.memTotal, let memU = sample.memUsed {
            XCTAssertEqual(memT, 15896, accuracy: 1)
            XCTAssertEqual(memU, 8934, accuracy: 1)
        } else {
            XCTFail("memTotal or memUsed is nil: total=\(String(describing: sample.memTotal)) used=\(String(describing: sample.memUsed))")
        }

        // GPU
        if let gpuU = sample.gpuUsage, let gpuM = sample.gpuMemUsage {
            XCTAssertEqual(gpuU, 45, accuracy: 0.1)
            XCTAssertEqual(gpuM, 32, accuracy: 0.1)
        } else {
            XCTFail("gpuUsage or gpuMemUsage is nil")
        }
        XCTAssertEqual(sample.gpuTemp, 67)
        XCTAssertEqual(sample.gpuName, "NVIDIA GeForce RTX 3090")
    }

    // MARK: - parse() with macOS output

    func testParseMacOSOutput() {
        let output = "---UPTIME---\n 2:32  up 10 days,  4:15, 3 users, load averages: 2.50 1.80 1.50\n---CPU---\nProcesses: 450 total, 3 running, 447 sleeping, 1892 threads\n2024/01/15 14:32:01\nLoad Avg: 2.50, 1.80, 1.50\nCPU usage: 19.46% user, 7.6% sys, 72.94% idle\nSharedLibs: 380M resident, 90M data, 45M linkedit.\nMemRegions: 135421 total, 5631M resident, 245M private, 2345M shared.\nPhysMem: 14G used (2500M wired, 1200M compressor), 2G unused.\nVM: 245G vram, 3456M framework vram.\nNetworks: packets: 123456/78M in, 98765/45M out.\nDisks: 2345678/45G read, 1234567/23G written.\n---MEM---\nPhysMem: 14G used (2500M wired, 1200M compressor), 2G unused.\n---GPU---\nN/A"

        let sample = MonitorManager.parse(output: output)
        XCTAssertNotNil(sample)
        guard let sample = sample else { return }

        // Load averages: macOS uses space-separated "load averages: 2.50 1.80 1.50"
        // but the parser splits by comma, so only the first value parses (as "2.50 1.80 1.50")
        // loadAvg1 will be nil because Double("2.50 1.80 1.50") fails
        XCTAssertNil(sample.loadAvg1, "macOS space-separated load averages are not parsed by comma-split logic")

        // CPU: 100 - 72.94 = 27.06
        XCTAssertNotNil(sample.cpuUsage)
        XCTAssertEqual(sample.cpuUsage!, 27.06, accuracy: 0.1)

        // Memory from PhysMem: 14G used, 2G unused => 14*1024 used, (14+2)*1024 total
        XCTAssertNotNil(sample.memUsed)
        XCTAssertEqual(sample.memUsed!, 14 * 1024, accuracy: 1)
        XCTAssertEqual(sample.memTotal!, 16 * 1024, accuracy: 1)

        // GPU is N/A
        XCTAssertNil(sample.gpuUsage)
        XCTAssertNil(sample.gpuName)
    }

    // MARK: - parse() with no GPU

    func testParseOutputNoGPU() {
        let output = "---UPTIME---\n 14:32:01 up 1 day, load average: 0.50, 0.40, 0.30\n---CPU---\n%Cpu(s):  5.0 us,  2.0 sy,  0.0 ni, 93.0 id,  0.0 wa\n---MEM---\nMem:           7982        3456        1234         123        3291        4123\n---GPU---\nN/A"

        let sample = MonitorManager.parse(output: output)
        XCTAssertNotNil(sample)
        guard let sample = sample else { return }
        XCTAssertNotNil(sample.cpuUsage)
        XCTAssertEqual(sample.cpuUsage!, 7.0, accuracy: 0.1)
        XCTAssertNil(sample.gpuUsage)
    }

    // MARK: - parse() empty/garbage

    func testParseEmptyOutput() {
        let sample = MonitorManager.parse(output: "")
        XCTAssertNotNil(sample) // returns a sample with all nils
        XCTAssertNil(sample!.cpuUsage)
        XCTAssertNil(sample!.memUsed)
    }
}

// MARK: - Uptime parsing

final class DockerUptimeTests: XCTestCase {

    func test_compactUptime_numericForms() {
        XCTAssertEqual(DockerStatsManager.compactUptime(from: "Up 5 seconds"), "5s")
        XCTAssertEqual(DockerStatsManager.compactUptime(from: "Up 5 minutes"), "5m")
        XCTAssertEqual(DockerStatsManager.compactUptime(from: "Up 2 hours"), "2h")
        XCTAssertEqual(DockerStatsManager.compactUptime(from: "Up 3 days"), "3d")
        XCTAssertEqual(DockerStatsManager.compactUptime(from: "Up 1 week"), "1w")
        XCTAssertEqual(DockerStatsManager.compactUptime(from: "Up 4 months"), "4mo")
        XCTAssertEqual(DockerStatsManager.compactUptime(from: "Up 1 year"), "1y")
    }

    func test_compactUptime_aboutForms() {
        XCTAssertEqual(DockerStatsManager.compactUptime(from: "Up About a minute"), "1m")
        XCTAssertEqual(DockerStatsManager.compactUptime(from: "Up About an hour"), "1h")
        XCTAssertEqual(DockerStatsManager.compactUptime(from: "Up Less than a second"), "<1s")
    }

    func test_compactUptime_stripsHealthAnnotation() {
        XCTAssertEqual(DockerStatsManager.compactUptime(from: "Up 2 hours (healthy)"), "2h")
        XCTAssertEqual(DockerStatsManager.compactUptime(from: "Up 5 minutes (unhealthy)"), "5m")
    }

    func test_compactUptime_nonUpStatusPassesThrough() {
        XCTAssertEqual(DockerStatsManager.compactUptime(from: "Exited (0) 5 minutes ago"),
                       "Exited (0) 5 minutes ago")
        XCTAssertEqual(DockerStatsManager.compactUptime(from: "Restarting (1) 2 seconds ago"),
                       "Restarting (1) 2 seconds ago")
    }

    func test_parse_joinsStatAndPsByName() {
        let output = """
        CORES=8
        STAT|nginx|0.05%|12.34MiB / 7.656GiB|1.2kB / 0B|0B / 0B|5
        STAT|redis|1.23%|45.6MiB / 7.656GiB|500B / 200B|4.1kB / 0B|4
        PS|nginx|Up 2 hours
        PS|redis|Up 5 minutes (healthy)
        """
        let (cores, stats) = DockerStatsManager.parse(output: output)
        XCTAssertEqual(cores, 8)
        XCTAssertEqual(stats.count, 2)
        let byName = Dictionary(uniqueKeysWithValues: stats.map { ($0.name, $0) })
        XCTAssertEqual(byName["nginx"]?.uptime, "2h")
        XCTAssertEqual(byName["redis"]?.uptime, "5m")
        XCTAssertEqual(byName["nginx"]?.cpu, "0.05%")
    }

    func test_parse_uptimeMissingForContainerIsEmpty() {
        // STAT row with no matching PS row → uptime is empty, not crashing
        let output = """
        STAT|orphan|0.5%|10MiB / 1GiB|0B / 0B|0B / 0B|1
        """
        let (_, stats) = DockerStatsManager.parse(output: output)
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].uptime, "")
    }

    func test_parse_backwardsCompatibleWithUntaggedRows() {
        // Older format (no STAT/PS prefix) still parses for the existing tests
        let output = "nginx|0.05%|12MiB / 1GiB|0B / 0B|0B / 0B|5"
        let (_, stats) = DockerStatsManager.parse(output: output)
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].name, "nginx")
        XCTAssertEqual(stats[0].uptime, "")
    }
}
