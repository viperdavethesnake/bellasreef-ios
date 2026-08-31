// Bella's Reef iOS — closed source.

import Foundation

/// Renders `GET /api/v1/hub-status` (the hub machine's own vitals) into the
/// strings the System tab's Hub status leaf shows. Pure functions, tested
/// against coco's measured values — the same fixtures the backend pins.
public enum HubStatusFormat {

    /// "555 MB of 991 MB" — used derived as total minus available, the same
    /// arithmetic `free -m` prints as "used" plus cache pressure honesty:
    /// MemAvailable is what the kernel says could be had, which is the number
    /// an operator actually wants.
    public static func memoryLine(totalKB: Int, availableKB: Int) -> String {
        let usedMB = (totalKB - availableKB) / 1024
        let totalMB = totalKB / 1024
        return "\(usedMB) MB of \(totalMB) MB"
    }

    /// Used fraction for the capsule bar; 0 when the total is unknown rather
    /// than a division by zero.
    public static func memoryFraction(totalKB: Int, availableKB: Int) -> Double {
        guard totalKB > 0 else { return 0 }
        return Double(totalKB - availableKB) / Double(totalKB)
    }

    /// "0.42 · 0.38 · 0.33" — the classic 1/5/15 triple, in that order.
    public static func loadLine(load1m: Double, load5m: Double, load15m: Double) -> String {
        [load1m, load5m, load15m].map { String(format: "%.2f", $0) }.joined(separator: " · ")
    }

    /// "46.3 °C"; nil renders as an em dash — a host with no thermal zone
    /// reports nothing, and nothing must never look like freezing.
    public static func temperatureLine(tempC: Double?) -> String {
        guard let tempC else { return "—" }
        return String(format: "%.1f °C", tempC)
    }

    /// Coarse on purpose: uptime is a "since when" answer, not a stopwatch.
    public static func uptimeLine(seconds: Double) -> String {
        let total = Int(seconds)
        if total < 60 { return "less than a minute" }
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes) min" }
        return "\(minutes) min"
    }
}
