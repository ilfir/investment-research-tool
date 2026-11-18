import Foundation

/// Look-through exposure: issuer key → weight (fractions summing to ≤ 1).
nonisolated struct Exposure: Sendable {
    var weights: [String: Double] = [:]
    var labels: [String: String] = [:]      // key → display name

    static func of(holdings: [FundHolding]) -> Exposure {
        var e = Exposure()
        for h in holdings where h.weight > 0 {
            let k = IssuerKey.make(h.name.isEmpty ? h.title : h.name)
            e.weights[k, default: 0] += h.weight; e.labels[k] = e.labels[k] ?? h.name
        }
        return e
    }
    static func single(name: String) -> Exposure {
        let k = IssuerKey.make(name); return Exposure(weights: [k: 1], labels: [k: name])
    }
    mutating func add(_ other: Exposure, scale: Double) {
        for (k, w) in other.weights { weights[k, default: 0] += w * scale; labels[k] = labels[k] ?? other.labels[k] }
    }
    var top10Weight: Double { weights.values.sorted(by: >).prefix(10).reduce(0, +) }
    func top(_ n: Int) -> [(name: String, weight: Double)] {
        weights.sorted { $0.value > $1.value }.prefix(n).map { (labels[$0.key] ?? $0.key, $0.value) }
    }
}

nonisolated enum OverlapCalc {
    /// Weight overlap = Σ min(wA, wB). 1.0 means identical portfolios.
    static func overlap(_ a: Exposure, _ b: Exposure) -> Double {
        a.weights.reduce(0) { $0 + min($1.value, b.weights[$1.key] ?? 0) }
    }
    /// Share of A's holdings (by count) that also appear in B.
    static func countOverlap(_ a: Exposure, _ b: Exposure) -> Double {
        guard !a.weights.isEmpty else { return 0 }
        return Double(a.weights.keys.filter { b.weights[$0] != nil }.count) / Double(a.weights.count)
    }
    static func common(_ a: Exposure, _ b: Exposure, top n: Int = 10) -> [(name: String, a: Double, b: Double)] {
        a.weights.compactMap { k, w in b.weights[k].map { (a.labels[k] ?? k, w, $0) } }
            .sorted { min($0.1, $0.2) > min($1.1, $1.2) }.prefix(n).map { $0 }
    }
}

/// Normalises issuer names so "Alphabet Inc Class A", "ALPHABET INC-CL C" and "Alphabet Inc." match.
nonisolated enum IssuerKey {
    private static let drop: Set<String> = ["INC", "CORP", "CORPORATION", "CO", "COMPANY", "LTD", "LIMITED", "PLC", "THE",
                                            "HOLDINGS", "HOLDING", "GROUP", "NV", "SA", "AG", "SE", "LLC", "LP", "CLASS",
                                            "CL", "A", "B", "C", "COM", "NEW", "DEL", "ORD", "SHS", "ADR", "REIT", "TRUST"]
    static func make(_ name: String) -> String {
        let cleaned = name.uppercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        let words = String(cleaned).split(separator: " ").map(String.init).filter { !drop.contains($0) }
        return words.prefix(3).joined(separator: " ")
    }
}
