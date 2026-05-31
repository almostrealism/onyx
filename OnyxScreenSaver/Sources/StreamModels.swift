import AppKit
import Foundation

/// One CPU sample at a point in time. The wire format the Onyx app writes
/// and the screensaver reads. `gpu` is nullable so older publishers (and
/// hosts without a GPU sensor) still decode.
struct CPUSample: Codable {
    let t: TimeInterval
    let cpu: Double
    let gpu: Double?

    enum CodingKeys: String, CodingKey { case t, cpu, gpu }

    init(t: TimeInterval, cpu: Double, gpu: Double? = nil) {
        self.t = t; self.cpu = cpu; self.gpu = gpu
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.t = try c.decode(TimeInterval.self, forKey: .t)
        self.cpu = try c.decode(Double.self, forKey: .cpu)
        self.gpu = try c.decodeIfPresent(Double.self, forKey: .gpu)
    }
}

/// One host's CPU history. `samples` is ordered oldest-first; newest goes on
/// top of the totem.
struct HostStream: Codable, Identifiable {
    let hostID: String
    let label: String
    /// Hex color string like "#FF8800". Drives the totem's tint.
    let color: String
    let samples: [CPUSample]

    var id: String { hostID }
}

/// Per-project hours, color-coded. The screensaver blends these colors
/// (weighted by hours) to tint the central ball — a week dominated by
/// one project shows that project's color; a balanced week shows a mix.
struct ProjectShare: Codable {
    let title: String
    let color: String   // hex without "#"
    let hours: Double
}

/// The shape of the JSON file Onyx publishes.
///
/// Trailing fields are optional so the screensaver decodes cleanly when
/// running against an older Onyx that didn't publish them.
struct CPUStreamFile: Codable {
    let updatedAt: TimeInterval
    let hosts: [HostStream]
    let weeklyHours: Double?
    let weeklyProjects: [ProjectShare]?

    enum CodingKeys: String, CodingKey {
        case updatedAt, hosts, weeklyHours, weeklyProjects
    }

    init(updatedAt: TimeInterval, hosts: [HostStream],
         weeklyHours: Double? = nil,
         weeklyProjects: [ProjectShare]? = nil) {
        self.updatedAt = updatedAt
        self.hosts = hosts
        self.weeklyHours = weeklyHours
        self.weeklyProjects = weeklyProjects
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.updatedAt = try c.decode(TimeInterval.self, forKey: .updatedAt)
        self.hosts = try c.decode([HostStream].self, forKey: .hosts)
        self.weeklyHours = try c.decodeIfPresent(Double.self, forKey: .weeklyHours)
        self.weeklyProjects = try c.decodeIfPresent([ProjectShare].self,
                                                    forKey: .weeklyProjects)
    }
}

// MARK: - NSColor helpers

extension NSColor {
    /// Parse "#RRGGBB" (with or without leading #). Returns nil for malformed
    /// input so the renderer can fall back to a default.
    static func fromOnyxHex(_ hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xff) / 255
        let g = CGFloat((v >> 8) & 0xff) / 255
        let b = CGFloat(v & 0xff) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// Multiply this color's HSB brightness by `factor`. Used to fade older
    /// rings so the time axis is visually readable even without motion cues.
    func withBrightnessMultiplied(by factor: CGFloat) -> NSColor {
        guard let rgb = usingColorSpace(.deviceRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(calibratedHue: h,
                       saturation: s,
                       brightness: max(0.05, b * factor),
                       alpha: a)
    }
}
