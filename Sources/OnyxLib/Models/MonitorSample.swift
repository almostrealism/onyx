import Foundation

/// MonitorSample.
public struct MonitorSample: Identifiable {
    /// Id.
    public let id = UUID()
    /// Timestamp.
    public let timestamp: Date
    /// Cpu usage.
    public var cpuUsage: Double?     // 0-100, nil if unparseable
    /// Mem used.
    public var memUsed: Double?      // MB
    /// Mem total.
    public var memTotal: Double?     // MB
    /// Gpu usage.
    public var gpuUsage: Double?     // 0-100
    /// Gpu mem usage.
    public var gpuMemUsage: Double?  // 0-100
    /// Gpu temp.
    public var gpuTemp: Int?
    /// Gpu name.
    public var gpuName: String?
    /// Load avg1.
    public var loadAvg1: Double?
    /// Load avg5.
    public var loadAvg5: Double?
    /// Load avg15.
    public var loadAvg15: Double?

    /// Create a new instance.
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
