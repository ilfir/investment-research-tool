import Foundation

nonisolated enum Verdict: String, Sendable {
    case buy = "Buy"
    case buySlowly = "Buy slowly (DCA)"
    case holdOff = "Hold off"
    case avoid = "Avoid"
    case justBuySP = "Just buy the S&P 500 instead"
    case speculation = "Speculation: max 1% of portfolio"
    case notEvaluated = "Not evaluated: S&P comparison only"
}

nonisolated enum Confidence: String, Sendable { case high = "High", medium = "Medium", low = "Low" }

nonisolated struct Reason: Sendable, Hashable {
    var text: String
    var evidence: [DataPoint] = []
    var citation: String? = nil
}

/// Research already verified by you (prompt §1); cited in "why" text where relevant.
nonisolated enum Citations {
    static let spiva = "SPIVA US Year-End 2025: 79% of active large-cap funds lagged the S&P 500 in 2025, 89% over 5 years."
    static let mindTheGap = "Morningstar Mind the Gap 2025: investors earned 8.7%/yr vs 9.9% for the funds themselves (10 yrs to Dec 2025)."
    static let schwab = "Schwab \"Does Market Timing Work?\" (2005–2024): investing immediately grew to $170,555 vs $47,357 in T-bills."
    static let bestDays = "J.P. Morgan: missing the market's best days sharply cuts long-run returns."
    static let barberOdean = "Barber & Odean (2000): the most active traders earned 11.4%/yr vs 17.9% for the market."
}

nonisolated struct VerdictResult: Sendable {
    var verdict: Verdict
    var confidence: Confidence
    var confidenceDetail: String
    var reasons: [Reason]
    var actions: [String]             // DCA guidance etc.
}

nonisolated enum VerdictEngine {
    static func decide(type: AssetType, rules: [RuleResult], isSPTracker: Bool, priceAction: PriceAction,
                       checks: [CrossCheck], staleCount: Int) -> VerdictResult {
        let fails = rules.filter { $0.status == .fail }
        let hard = fails.filter { $0.weight == .hard }
        let soft = fails.filter { $0.weight == .soft }
        let unconfirmed = rules.filter { $0.status == .unconfirmed }
        let screenNumericFails = soft.filter { ["S2", "S3", "S4"].contains($0.id) }
        let valuationStretched = rules.filter { $0.group == .valuation && $0.status == .warn }

        var reasons: [Reason] = []
        func add(_ r: RuleResult, prefix: String = "") {
            reasons.append(Reason(text: "\(prefix)\(r.title): \(r.actual) (threshold: \(r.threshold))", evidence: r.evidence))
        }
        var actions: [String] = []
        if priceAction.isParabolic { actions.append("Parabolic: up \(Fmt.pct(priceAction.change30d ?? 0)) in 30 days. Slow your DCA to 50% speed until the run cools off.") }

        let verdict: Verdict
        switch type {
        case .reit:
            verdict = .notEvaluated
            reasons.append(Reason(text: "REIT fundamentals are not evaluated (your choice). Only the S&P 500 comparison is shown."))
        case .crypto, .cryptoETF:
            verdict = .speculation
            reasons.append(Reason(text: "No fundamentals to analyse. Under Nash's rule, speculation is capped at 1% of your portfolio."))
            if let p3 = rules.first(where: { $0.id == "P3" }) { add(p3) }
        default:
            if type == .leveragedOrInverse {
                verdict = .avoid
                reasons.append(Reason(text: "Leveraged/inverse fund: daily rebalancing breaks long-run compounding, so it is not a long-term holding. It counts as speculation (max 1%)."))
                hard.forEach { add($0) }
            } else if !hard.isEmpty || screenNumericFails.count >= 3 {
                verdict = .avoid
                hard.forEach { add($0, prefix: "Hard fail: ") }
                screenNumericFails.forEach { add($0) }
            } else if type.isFund, let f = rules.first(where: { ["F11", "F12"].contains($0.id) && $0.status == .fail }) {
                verdict = .justBuySP
                add(f)
                reasons.append(Reason(text: "Index funds are hard to beat after fees.", citation: Citations.spiva))
            } else if !soft.isEmpty {
                verdict = .holdOff
                soft.forEach { add($0) }
            } else if priceAction.isParabolic || !valuationStretched.isEmpty || !unconfirmed.isEmpty {
                verdict = .buySlowly
                if !unconfirmed.isEmpty { reasons.append(Reason(text: "Still needs your judgement: \(unconfirmed.map(\.title).joined(separator: ", ")). The best possible verdict until you confirm them is \"Buy slowly\".")) }
                valuationStretched.forEach { add($0, prefix: "Valuation stretched vs own history: ") }
                if priceAction.isParabolic { reasons.append(Reason(text: "Price is up \(Fmt.pct(priceAction.change30d ?? 0)) in 30 days (parabolic rule).")) }
            } else {
                verdict = .buy
            }
            // Supporting passes (most important first), so "why" isn't only negatives.
            let passOrder = ["S1", "S2", "S3", "S4", "F1", "F11", "F13", "F5", "P1"]
            for id in passOrder { if let r = rules.first(where: { $0.id == id && $0.status == .pass }), reasons.count < 6 { add(r, prefix: "✓ ") } }
            if isSPTracker { reasons.append(Reason(text: "This is an S&P 500 index fund: Nash's core holding (at least \(Fmt.pct(PortfolioRules.spFloor(age: nil), digits: 0)) of the portfolio).", citation: Citations.spiva)) }
        }

        if priceAction.isDown, verdict == .buy || verdict == .buySlowly {
            actions.append("Price is \(Fmt.pct(priceAction.drawdownFrom52wHigh ?? 0)) below its 52-week high with fundamentals intact. Nash's rule is to double the DCA.")
        }
        if verdict == .buy || verdict == .buySlowly {
            actions.append("Dollar-cost average a fixed amount on a schedule rather than timing the entry.")
            reasons.append(Reason(text: "Invest on a schedule instead of waiting for a dip.", citation: Citations.schwab))
        }

        // Confidence from data quality
        let agree = checks.filter { $0.status == .agree }.count
        let conflicts = checks.filter { $0.status == .conflict }.count
        let single = checks.filter { $0.status == .singleSource }.count
        let applicable = rules.filter { $0.weight != .info }
        let naShare = applicable.isEmpty ? 0 : Double(applicable.filter { $0.status == .na }.count) / Double(applicable.count)
        var score = checks.isEmpty ? 0.5 : (Double(agree) + 0.5 * Double(single)) / Double(checks.count)
        score -= 0.15 * Double(conflicts) + 0.1 * Double(staleCount) + 0.5 * naShare
        let conf: Confidence = score >= 0.7 ? .high : (score >= 0.45 ? .medium : .low)
        let detail = "\(agree) of \(checks.count) key numbers agree across two sources, \(single) single-source, \(conflicts) conflicting; \(staleCount) stale; \(Fmt.pct(naShare, digits: 0)) of scored rules n/a."
        return VerdictResult(verdict: verdict, confidence: conf, confidenceDetail: detail, reasons: Array(reasons.prefix(8)), actions: actions)
    }
}
