import Foundation

/// Where a number came from. Every value shown in the app carries one of these.
nonisolated struct SourceRef: Hashable, Sendable, Codable {
    var name: String          // e.g. "SEC EDGAR companyfacts"
    var url: String
    var asOf: Date?           // the date the value describes (period end, price date…)
    var fetchedAt: Date

    var isPrimary: Bool { name.hasPrefix("SEC") || name.hasPrefix("US Treasury") || name.hasPrefix("FRED") || name.hasPrefix("Issuer") }
}

nonisolated enum Unit: String, Sendable, Codable {
    case usd, percent, ratio, count, years, days, shares, multiple
}

/// A single sourced number. `value` uses natural units: percent as a fraction (0.15 = 15%).
nonisolated struct DataPoint: Hashable, Sendable, Codable {
    var key: String
    var label: String
    var value: Double
    var unit: Unit
    var source: SourceRef
    var note: String? = nil

    var formatted: String { Fmt.value(value, unit) }
}

/// Result of the two-source rule for one number.
nonisolated struct CrossCheck: Hashable, Sendable {
    enum Status: String, Sendable { case agree, conflict, singleSource, definitionDiffers }
    var key: String
    var label: String
    var primary: DataPoint?
    var secondary: DataPoint?
    var status: Status
    var differencePct: Double?

    /// Compare two readings of the same number. `tolerance` is relative (0.05 = 5%).
    static func compare(_ label: String, key: String, _ a: DataPoint?, _ b: DataPoint?,
                        tolerance: Double = 0.05, definitionsDiffer: Bool = false) -> CrossCheck {
        guard let a, let b else {
            return CrossCheck(key: key, label: label, primary: a ?? b, secondary: nil, status: .singleSource, differencePct: nil)
        }
        let denom = max(abs(a.value), abs(b.value), 1e-12)
        let diff = abs(a.value - b.value) / denom
        let status: Status = diff <= tolerance ? .agree : (definitionsDiffer ? .definitionDiffers : .conflict)
        return CrossCheck(key: key, label: label, primary: a, secondary: b, status: status, differencePct: diff)
    }
}

nonisolated enum Fmt {
    static func value(_ v: Double, _ unit: Unit) -> String {
        switch unit {
        case .usd: return usd(v)
        case .percent: return pct(v, digits: abs(v) < 0.01 ? 2 : 1)
        case .ratio: return String(format: "%.2f", v)
        case .multiple: return String(format: "%.1fx", v)
        case .count, .shares: return grouped(v)
        case .years: return String(format: "%.1f yrs", v)
        case .days: return String(format: "%.0f days", v)
        }
    }
    static func pct(_ v: Double, digits: Int = 1) -> String { String(format: "%.\(digits)f%%", v * 100) }
    static func usd(_ v: Double) -> String {
        let a = abs(v), s = v < 0 ? "-" : ""
        switch a {
        case 1e12...: return "\(s)$\(String(format: "%.2f", a / 1e12))T"
        case 1e9...: return "\(s)$\(String(format: "%.2f", a / 1e9))B"
        case 1e6...: return "\(s)$\(String(format: "%.1f", a / 1e6))M"
        default: return "\(s)$\(grouped(a, digits: a < 100 ? 2 : 0))"
        }
    }
    static func grouped(_ v: Double, digits: Int = 0) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        f.maximumFractionDigits = digits; f.minimumFractionDigits = digits
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
    static func date(_ d: Date?) -> String {
        guard let d else { return "n/a" }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
}
