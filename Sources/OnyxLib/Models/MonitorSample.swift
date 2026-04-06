import Foundation

public struct MonitorSample: Identifiable {
    public let id = UUID()
    public let timestamp: Date
    public var cpuUsage: Double?     // 0-100, nil if unparseable
    public var memUsed: Double?      // MB
    public var memTotal: Double?     // MB
    public var gpuUsage: Double?     // 0-100
    public var gpuMemUsage: Double?  // 0-100
    public var gpuTemp: Int?
    public var gpuName: String?
    public var loadAvg1: Double?
    public var loadAvg5: Double?
    public var loadAvg15: Double?

    public init(timestamp: Date, cpuUsage: Double? = nil, memUsed: Double? = nil, memTotal: Double? = nil, gpuUsage: Double? = nil, gpuMemUsage: Double? = nil, gpuTemp: Int? = nil, gpuName: String? = nil, loadAvg1: Double? = nil, loadAvg5: Double? = nil, loadAvg15: Double? = nil) {
        self.timestamp = timestamp
        self.cpuUsage = cpuUsage
        self.memUsed = memUsed
        self.memTotal = memTotal
        self.gpuUsage = gpuUsage
        self.gpuMemUsage = gpuMemUsage
        self.gpuTemp = gpuTemp
        self.gpuName = gpuName
        self.loadAvg1 = loadAvg1
        self.loadAvg5 = loadAvg5
        self.loadAvg15 = loadAvg15
    }
}
