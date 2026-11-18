import Foundation

nonisolated enum RuleStatus: String, Sendable { case pass = "✓", fail = "✗", warn = "!", na = "n/a", unconfirmed = "?" }
nonisolated enum RuleGroup: String, Sendable, CaseIterable {
    case screen = "Nash 7-step screen", balance = "Balance sheet & cash flow", valuation = "Valuation (info only)"
    case fund = "Fund checklist", costs = "Costs", portfolio = "Fit with your portfolio"
    case price = "Price action", redFlag = "Red flags", crypto = "Speculation"
}
/// hard: a fail means Avoid. soft: a fail means Hold off. info: shown, never changes the verdict.
nonisolated enum RuleWeight: String, Sendable { case hard, soft, info }

nonisolated struct RuleResult: Sendable, Identifiable {
    var id: String
    var group: RuleGroup
    var title: String
    var status: RuleStatus
    var actual: String
    var threshold: String
    var weight: RuleWeight
    var evidence: [DataPoint] = []
    var detail: String? = nil
    var suggestion: Bool? = nil        // judgement items: the app's suggested answer
}

// MARK: - Stocks

nonisolated enum StockRules {
    struct Inputs {
        var f: CompanyFundamentals
        var price: Double?
        var priceHistory: Series?          // unadjusted closes, for valuation history
        var judgements: JudgementAnswers
        var spPE: DataPoint?               // S&P 500 trailing P/E (VOO), for comparison
    }

    static func evaluate(_ i: Inputs) -> [RuleResult] {
        let f = i.f, src = f.source
        var out: [RuleResult] = []
        func dp(_ key: String, _ label: String, _ v: Double?, _ unit: Unit, asOf: Date?) -> DataPoint? {
            guard let v else { return nil }
            var s = src; s.asOf = asOf ?? s.asOf
            return DataPoint(key: key, label: label, value: v, unit: unit, source: s)
        }
        let bs = f.balance, ly = f.latest

        // 1. Cash > debt. Leases are excluded (your decision 2026-11-17) but shown for context.
        if let bs, let cash = bs.totalCash, let debt = bs.debtExLeases {
            let leases = (bs.operatingLeases ?? 0) + (bs.financeLeases ?? 0)
            out.append(RuleResult(id: "S1", group: .screen, title: "1. More cash than debt", status: cash > debt ? .pass : .fail,
                                  actual: "\(Fmt.usd(cash)) cash vs \(Fmt.usd(debt)) debt", threshold: "cash + short-term investments > debt (excl. leases)",
                                  weight: .hard,
                                  evidence: [dp("cash", "Cash + short-term investments", cash, .usd, asOf: bs.date),
                                             dp("debtExLeases", "Debt excl. leases", debt, .usd, asOf: bs.date),
                                             dp("leases", "Lease liabilities (not counted)", leases, .usd, asOf: bs.date)].compactMap { $0 },
                                  detail: "Lease liabilities not counted: operating \(Fmt.usd(bs.operatingLeases ?? 0)), finance \(Fmt.usd(bs.financeLeases ?? 0)). Including them, debt would be \(Fmt.usd(debt + leases)) (\(cash > debt + leases ? "still passes" : "would fail")). Balance sheet as of \(Fmt.date(bs.date)) (\(bs.form))."))
        } else {
            out.append(RuleResult(id: "S1", group: .screen, title: "1. More cash than debt", status: .na, actual: "missing", threshold: "cash > debt", weight: .hard))
        }

        // 2. Revenue growth ≥ 10% (latest year AND 3-yr CAGR)
        let g1 = f.growth(\.revenue, yearsBack: 1), g3 = f.growth(\.revenue, yearsBack: 3)
        out.append(RuleResult(id: "S2", group: .screen, title: "2. Revenue growth ≥ 10%",
                              status: g1 == nil || g3 == nil ? .na : (g1! >= 0.10 && g3! >= 0.10 ? .pass : .fail),
                              actual: "latest yr \(g1.map { Fmt.pct($0) } ?? "n/a"), 3-yr CAGR \(g3.map { Fmt.pct($0) } ?? "n/a")",
                              threshold: "≥ 10% on both", weight: .soft,
                              evidence: [dp("revGrowth1y", "Revenue growth (latest FY)", g1, .percent, asOf: ly?.end),
                                         dp("revGrowth3y", "Revenue growth (3-yr CAGR)", g3, .percent, asOf: ly?.end),
                                         dp("revenue", "Revenue (latest FY)", ly?.revenue, .usd, asOf: ly?.end)].compactMap { $0 }))

        // 3. Operating margin ≥ 15% (FCF margin shown)
        let om = ly?.operatingMargin, fm = ly?.fcfMargin
        out.append(RuleResult(id: "S3", group: .screen, title: "3. Operating margin ≥ 15%",
                              status: om == nil ? .na : (om! >= 0.15 ? .pass : .fail),
                              actual: "operating \(om.map { Fmt.pct($0) } ?? "n/a"), FCF margin \(fm.map { Fmt.pct($0) } ?? "n/a")",
                              threshold: "operating margin ≥ 15%", weight: .soft,
                              evidence: [dp("opMargin", "Operating margin", om, .percent, asOf: ly?.end),
                                         dp("fcfMargin", "FCF margin", fm, .percent, asOf: ly?.end)].compactMap { $0 }))

        // 4. Revenue growth > opex growth (same periods)
        let ox1 = growthOf(f, yearsBack: 1), ox3 = growthOf(f, yearsBack: 3)
        let s4: RuleStatus = (g1 == nil || g3 == nil || ox1 == nil || ox3 == nil) ? .na : (g1! > ox1! && g3! > ox3! ? .pass : .fail)
        out.append(RuleResult(id: "S4", group: .screen, title: "4. Revenue growing faster than expenses", status: s4,
                              actual: "revenue \(g1.map { Fmt.pct($0) } ?? "n/a") vs opex \(ox1.map { Fmt.pct($0) } ?? "n/a") (1 yr); \(g3.map { Fmt.pct($0) } ?? "n/a") vs \(ox3.map { Fmt.pct($0) } ?? "n/a") (3 yr)",
                              threshold: "revenue growth > opex growth, both periods", weight: .soft,
                              evidence: [dp("opexGrowth1y", "Opex growth (latest FY)", ox1, .percent, asOf: ly?.end),
                                         dp("opexGrowth3y", "Opex growth (3-yr CAGR)", ox3, .percent, asOf: ly?.end)].compactMap { $0 },
                              detail: "Expenses measured as: \(f.opexConcept)."))

        // 5–7. Judgement calls: suggestion + evidence, your answer decides.
        let margins = f.years.suffix(10).compactMap(\.operatingMargin)
        let avgM = margins.isEmpty ? nil : Stats.mean(margins), sdM = margins.count > 2 ? Stats.std(margins) : nil
        let minM = margins.min()
        let moatSuggest: Bool? = avgM.map { $0 >= 0.20 && (minM ?? 0) >= 0.15 }
        out.append(judgement("S5", "5. Has a real moat", answer: i.judgements.moat, suggestion: moatSuggest,
                             evidence: "Operating margin over \(margins.count) yrs: average \(avgM.map { Fmt.pct($0) } ?? "n/a"), lowest \(minM.map { Fmt.pct($0) } ?? "n/a"), std dev \(sdM.map { Fmt.pct($0) } ?? "n/a"). Suggestion rule: average ≥ 20% and never below 15% hints at pricing power. Check competitors and the 10-K \"Competition\" section."))
        out.append(judgement("S6", "6. Top-tier CEO", answer: i.judgements.topTierCEO, suggestion: nil,
                             evidence: "No reliable keyless data for this. Read the latest proxy statement (DEF 14A) and shareholder letter in the company's EDGAR filings."))
        let rec = recessionCheck(f)
        out.append(judgement("S7", "7. Recession-proof", answer: i.judgements.recessionProof, suggestion: rec.suggest, evidence: rec.text))

        // Balance sheet & cash flow extras
        if let fcf = ly?.freeCashFlow {
            out.append(RuleResult(id: "B1", group: .balance, title: "Free cash flow positive", status: fcf > 0 ? .pass : .fail,
                                  actual: Fmt.usd(fcf), threshold: "> 0 (Nash: focus on FCF)", weight: .soft,
                                  evidence: [dp("fcf", "Free cash flow (latest FY)", fcf, .usd, asOf: ly?.end)].compactMap { $0 }))
        }
        if let bs, let eq = bs.equity, eq > 0, let d = bs.debtExLeases {
            out.append(RuleResult(id: "B2", group: .balance, title: "Debt / equity", status: d / eq <= 1 ? .pass : .warn,
                                  actual: String(format: "%.2f", d / eq), threshold: "≤ 1.0 (debt is the silent killer)", weight: .info,
                                  evidence: [dp("debtToEquity", "Debt / equity (excl. leases)", d / eq, .ratio, asOf: bs.date)].compactMap { $0 }))
        }
        if let oi = ly?.operatingIncome, let ie = ly?.interestExpense, ie > 0 {
            let cov = oi / ie
            out.append(RuleResult(id: "B3", group: .balance, title: "Interest coverage", status: cov >= 5 ? .pass : .warn,
                                  actual: String(format: "%.1fx", cov), threshold: "≥ 5x", weight: .info,
                                  evidence: [dp("interestCoverage", "Interest coverage (EBIT / interest)", cov, .multiple, asOf: ly?.end)].compactMap { $0 }))
        }
        if f.years.count > 3, let s0 = f.years[f.years.count - 4].dilutedShares, let s1 = ly?.dilutedShares, s0 > 0 {
            let dil = pow(s1 / s0, 1.0 / 3) - 1
            out.append(RuleResult(id: "B4", group: .balance, title: "Share dilution (3-yr)", status: dil <= 0.02 ? .pass : .warn,
                                  actual: "\(Fmt.pct(dil)) per yr", threshold: "≤ 2% per yr", weight: .info,
                                  evidence: [dp("dilution", "Diluted share count change per yr (3-yr)", dil, .percent, asOf: ly?.end)].compactMap { $0 }))
        }

        out += valuation(i)
        return out
    }

    static func growthOf(_ f: CompanyFundamentals, yearsBack n: Int) -> Double? {
        guard f.years.count > n, let a = f.opex(f.years[f.years.count - 1 - n]), let b = f.latest.flatMap(f.opex), a > 0, b > 0 else { return nil }
        return pow(b / a, 1 / Double(n)) - 1
    }

    static func judgement(_ id: String, _ title: String, answer: Bool?, suggestion: Bool?, evidence: String) -> RuleResult {
        RuleResult(id: id, group: .screen, title: title,
                   status: answer.map { $0 ? .pass : .fail } ?? .unconfirmed,
                   actual: answer.map { $0 ? "you confirmed ✓" : "you rated ✗" } ?? "needs your confirmation",
                   threshold: "your judgement (suggested: \(suggestion.map { $0 ? "✓" : "✗" } ?? "no suggestion"))",
                   weight: .soft, detail: evidence, suggestion: suggestion)
    }

    /// Revenue change in the fiscal years covering 2008-09, 2020 and 2022.
    static func recessionCheck(_ f: CompanyFundamentals) -> (suggest: Bool?, text: String) {
        let windows: [(String, ClosedRange<Date>)] = [
            ("2008–09", DateParse.ymd("2008-07-01")!...DateParse.ymd("2010-03-31")!),
            ("2020", DateParse.ymd("2020-03-01")!...DateParse.ymd("2021-03-31")!),
            ("2022", DateParse.ymd("2022-01-01")!...DateParse.ymd("2023-06-30")!)]
        var parts: [String] = [], worst: [Double] = []
        for (name, r) in windows {
            let changes = f.years.indices.dropFirst().compactMap { i -> Double? in
                guard r.contains(f.years[i].end), let a = f.years[i - 1].revenue, let b = f.years[i].revenue, a > 0 else { return nil }
                return b / a - 1
            }
            let margins = f.years.filter { r.contains($0.end) }.compactMap(\.operatingMargin)
            if let w = changes.min() {
                worst.append(w)
                parts.append("\(name): revenue \(Fmt.pct(w))\(margins.min().map { ", op. margin \(Fmt.pct($0))" } ?? "")")
            } else { parts.append("\(name): no data") }
        }
        let suggest: Bool? = worst.isEmpty ? nil : worst.allSatisfy { $0 >= -0.05 }
        return (suggest, parts.joined(separator: "; ") + ". Suggestion rule: revenue fell no more than 5% in any of these periods.")
    }

    static func valuation(_ i: Inputs) -> [RuleResult] {
        let f = i.f
        guard let price = i.price, let shares = f.balance?.sharesOutstanding ?? f.latest?.dilutedShares, let ly = f.latest else { return [] }
        let mcap = price * shares
        let cash = f.balance?.totalCash ?? 0, debt = f.balance?.debtExLeases ?? 0
        let pe = ratio(mcap, ly.netIncome), pfcf = ratio(mcap, ly.freeCashFlow), evebit = ratio(mcap + debt - cash, ly.operatingIncome)

        // Own history: same multiples at each fiscal-year end (last 10 yrs) using the price on that date.
        var histPE: [Double] = [], histPFCF: [Double] = [], histEV: [Double] = []
        if let ph = i.priceHistory {
            for y in f.years.suffix(11).dropLast() {
                guard let p = ph.value(onOrBefore: y.end)?.1, let sh = y.dilutedShares else { continue }
                let m = p * sh
                if let v = ratio(m, y.netIncome), v > 0 { histPE.append(v) }
                if let v = ratio(m, y.freeCashFlow), v > 0 { histPFCF.append(v) }
                if let v = ratio(m, y.operatingIncome), v > 0 { histEV.append(v) }   // EV approximated by market cap historically
            }
        }
        func row(_ id: String, _ name: String, _ v: Double?, _ hist: [Double], extra: String = "") -> RuleResult? {
            guard let v, v > 0 else { return nil }
            let med = Stats.median(hist)
            let stretched = med.map { v > $0 * 1.25 } ?? false
            var s = f.source; s.asOf = ly.end
            return RuleResult(id: id, group: .valuation, title: name, status: stretched ? .warn : .pass,
                              actual: String(format: "%.1fx", v) + (med.map { String(format: " (own %d-yr median %.1fx)", hist.count, $0) } ?? ""),
                              threshold: "≤ 1.25× own median" + extra, weight: .info,
                              evidence: [DataPoint(key: id, label: name, value: v, unit: .multiple, source: s,
                                                   note: "Price \(Fmt.usd(price)) × \(Fmt.grouped(shares)) shares; latest FY \(Fmt.date(ly.end)).")])
        }
        let spText = i.spPE.map { String(format: "; S&P 500 trailing P/E %.1fx", $0.value) } ?? ""
        return [row("V1", "P/E", pe, histPE, extra: spText), row("V2", "P/FCF", pfcf, histPFCF), row("V3", "EV/EBIT", evebit, histEV)].compactMap { $0 }
    }
}

// MARK: - Funds (ETF, mutual fund, bond fund)

nonisolated enum FundRules {
    struct Inputs {
        var type: AssetType
        var profile: FundProfile
        var overlapWithSP: Double?          // weight overlap with VOO
        var vooExpenseRatio: Double
        var isSPTracker: Bool
        var perf: PerformanceReport?
        var perfVsBND: PerformanceReport?
        var history: PriceHistory?
    }

    static func evaluate(_ i: Inputs) -> [RuleResult] {
        let p = i.profile
        var out: [RuleResult] = []
        let er = p.expenseRatio.primary ?? p.expenseRatio.secondary

        // Costs
        if let er {
            let v = er.value
            out.append(RuleResult(id: "F1", group: .costs, title: "Expense ratio", status: v < 0.0020 ? .pass : .fail,
                                  actual: Fmt.pct(v, digits: 2) + (v < 0.0010 ? " (ideal: under 0.10%)" : ""),
                                  threshold: "< 0.20%, ideally < 0.10%", weight: .soft, evidence: [er]))
        } else {
            out.append(RuleResult(id: "F1", group: .costs, title: "Expense ratio", status: .na, actual: "missing", threshold: "< 0.20%", weight: .soft))
        }
        if i.type == .mutualFund || p.frontLoad != nil || p.deferredLoad != nil {
            let load = max(p.frontLoad?.value ?? 0, p.deferredLoad?.value ?? 0)
            out.append(RuleResult(id: "F2", group: .costs, title: "Sales load", status: load > 0 ? .fail : .pass,
                                  actual: load > 0 ? Fmt.pct(load, digits: 2) : "none", threshold: "no load", weight: .soft,
                                  evidence: [p.frontLoad, p.deferredLoad].compactMap { $0 }))
        }
        if let b = p.twelveB1 {
            out.append(RuleResult(id: "F3", group: .costs, title: "12b-1 fee", status: b.value > 0 ? .fail : .pass,
                                  actual: Fmt.pct(b.value, digits: 2), threshold: "0%", weight: .soft, evidence: [b]))
        }
        if let m = p.minInvestment {
            out.append(RuleResult(id: "F4", group: .costs, title: "Minimum investment", status: .na, actual: Fmt.usd(m.value), threshold: "info", weight: .info, evidence: [m]))
        }

        // Fund checklist
        if let na = p.netAssets.primary ?? p.netAssets.secondary {
            out.append(RuleResult(id: "F5", group: .redFlag, title: "Fund size (AUM)", status: na.value >= 100e6 ? .pass : .fail,
                                  actual: Fmt.usd(na.value), threshold: "≥ $100M", weight: .hard, evidence: [na],
                                  detail: "SEC figure is for the whole fund (all share classes)."))
        }
        if let inc = p.inceptionDate {
            let age = Stats.years(inc, .now)
            out.append(RuleResult(id: "F6", group: .redFlag, title: "Fund age", status: age >= 3 ? .pass : .fail,
                                  actual: String(format: "%.1f yrs (since %@)", age, Fmt.date(inc)), threshold: "≥ 3 yrs", weight: .soft))
        }
        if i.type != .mutualFund {
            if let vol = p.averageVolume, let px = i.history?.lastClose {
                let dollars = vol.value * px
                out.append(RuleResult(id: "F7", group: .redFlag, title: "Liquidity (avg daily $ volume)", status: dollars >= 1e6 ? .pass : .fail,
                                      actual: Fmt.usd(dollars), threshold: "≥ $1M/day", weight: .soft, evidence: [vol]))
            }
            if let sp = p.bidAskSpread {
                out.append(RuleResult(id: "F8", group: .redFlag, title: "Bid/ask spread", status: sp.value <= 0.005 ? .pass : .warn,
                                      actual: Fmt.pct(sp.value, digits: 2), threshold: "≤ 0.50%", weight: .info, evidence: [sp], detail: sp.note))
            } else {
                out.append(RuleResult(id: "F8", group: .redFlag, title: "Bid/ask spread", status: .na, actual: "not available keyless right now", threshold: "≤ 0.50%", weight: .info))
            }
        }
        let t10 = p.top10.reduce(0) { $0 + $1.weight }
        if t10 > 0 {
            out.append(RuleResult(id: "F9", group: .fund, title: "Top-10 concentration", status: t10 <= 0.50 ? .pass : .warn,
                                  actual: Fmt.pct(t10), threshold: "≤ 50% (info)", weight: .info,
                                  detail: p.top10.map { "\($0.symbol ?? $0.name) \(Fmt.pct($0.weight))" }.joined(separator: ", ")))
        }
        if let to = p.turnover.primary ?? p.turnover.secondary {
            out.append(RuleResult(id: "F10", group: .fund, title: "Turnover", status: to.value <= 0.50 ? .pass : .warn,
                                  actual: Fmt.pct(to.value), threshold: "≤ 50% (hidden tax cost in taxable accounts)", weight: .info, evidence: [to]))
        }
        if let ov = i.overlapWithSP {
            let higherFee = (er?.value ?? 0) > i.vooExpenseRatio + 0.00005
            let s: RuleStatus = i.isSPTracker ? .pass : (ov >= 0.85 && higherFee ? .fail : .pass)
            out.append(RuleResult(id: "F11", group: .fund, title: "Overlap with the S&P 500 (VOO)", status: s,
                                  actual: Fmt.pct(ov), threshold: i.isSPTracker ? "this is an S&P 500 fund" : "fail if ≥ 85% at a higher fee than VOO",
                                  weight: .soft, detail: "Weight overlap = Σ min(weight in fund, weight in VOO), from SEC N-PORT holdings."))
        }
        if let perf = i.perf, !i.isSPTracker, i.type != .bondFund {
            let r = perf.rolling5.windows > 0 ? perf.rolling5 : perf.rolling3
            if let bp = r.beatPct {
                out.append(RuleResult(id: "F12", group: .fund, title: "Beat the S&P 500 over rolling \(r.windowYears)-yr windows", status: bp >= 0.5 ? .pass : .fail,
                                      actual: "\(Fmt.pct(bp, digits: 0)) of \(r.windows) windows", threshold: "≥ 50% of windows (after fees)",
                                      weight: .soft, detail: "Average annualised excess return \(r.averageExcess.map { Fmt.pct($0) } ?? "n/a")."))
            }
        }
        if i.isSPTracker, let perf = i.perf, let p1 = perf.periods.first(where: { $0.label == "5y" }) ?? perf.periods.first(where: { $0.label == "3y" }),
           let a = p1.asset, let b = p1.benchmark {
            out.append(RuleResult(id: "F13", group: .fund, title: "Tracking difference (\(p1.label), annualised)", status: abs(a - b) <= 0.002 ? .pass : .warn,
                                  actual: Fmt.pct(a - b, digits: 2), threshold: "within ±0.20%/yr of the index", weight: .info))
        }
        // US-only parameters that don't apply
        out.append(RuleResult(id: "F14", group: .fund, title: "Domicile / withholding, ACC vs DIST, trading currency", status: .na,
                              actual: "n/a (US-domiciled, USD, US funds distribute)", threshold: "—", weight: .info))

        if i.type == .bondFund { out += bond(i) }
        return out
    }

    static func bond(_ i: Inputs) -> [RuleResult] {
        let p = i.profile
        var out: [RuleResult] = []
        if let d = p.duration {
            out.append(RuleResult(id: "D1", group: .fund, title: "Duration / rate sensitivity", status: .na,
                                  actual: String(format: "%.1f yrs → about %@ price change per 1%% rate rise", d.value, Fmt.pct(-d.value / 100)),
                                  threshold: "info", weight: .info, evidence: [d]))
        } else {
            out.append(RuleResult(id: "D1", group: .fund, title: "Duration", status: .na, actual: "not available keyless", threshold: "info", weight: .info))
        }
        out.append(RuleResult(id: "D2", group: .fund, title: "Average credit quality", status: p.creditQuality == nil ? .na : (["AAA", "AA", "A", "BBB"].contains(p.creditQuality!) ? .pass : .warn),
                              actual: p.creditQuality ?? "not available", threshold: "investment grade (BBB or better)", weight: .info))
        out.append(RuleResult(id: "D3", group: .fund, title: "SEC yield vs distribution yield", status: .na,
                              actual: "distribution \(p.distributionYield.map { Fmt.pct($0.value, digits: 2) } ?? "n/a"); SEC yield not available keyless",
                              threshold: "a large gap can mean return of capital", weight: .info, evidence: [p.distributionYield].compactMap { $0 }))
        if let pb = i.perfVsBND, let bp = (pb.rolling5.windows > 0 ? pb.rolling5 : pb.rolling3).beatPct {
            let r = pb.rolling5.windows > 0 ? pb.rolling5 : pb.rolling3
            out.append(RuleResult(id: "D4", group: .fund, title: "Vs total bond index (BND), rolling \(r.windowYears)-yr", status: bp >= 0.5 ? .pass : .fail,
                                  actual: "beat BND in \(Fmt.pct(bp, digits: 0)) of \(r.windows) windows", threshold: "≥ 50%", weight: .soft))
        }
        return out
    }
}

// MARK: - Portfolio fit

nonisolated struct PortfolioContext: Sendable {
    var totalValue: Double
    var spValue: Double
    var stockTickers: Set<String>
    var speculationValue: Double
    var exposure: Exposure
    var unresolved: [String]
}

nonisolated enum PortfolioRules {
    static let spTrackers: Set<String> = ["VOO", "SPY", "IVV", "SPLG", "SPYM", "FXAIX", "SWPPX", "VFIAX", "VFINX"]

    /// Nash's S&P floor by age (approved): 40% under 50, 25% at 50–59, 30% at 60+.
    static func spFloor(age: Int?) -> Double {
        guard let age else { return 0.40 }
        return age >= 60 ? 0.30 : (age >= 50 ? 0.25 : 0.40)
    }

    static func evaluate(ticker: String, type: AssetType, isSPTracker: Bool, candidate: Exposure?, request: EvaluationRequest,
                         context: PortfolioContext?, maxDrawdown: Double?) -> [RuleResult] {
        var out: [RuleResult] = []
        let prof = request.profile
        let planned = prof.plannedAmount ?? 0
        guard let c = context, c.totalValue + planned > 0 else {
            out.append(RuleResult(id: "P0", group: .portfolio, title: "Portfolio checks", status: .na, actual: "no positions entered", threshold: "add positions or a Fidelity CSV", weight: .info))
            out += behaviour(type: type, request: request, maxDrawdown: maxDrawdown)
            return out
        }
        let total = c.totalValue + planned
        let spAfter = (c.spValue + (isSPTracker ? planned : 0)) / total
        let floor = spFloor(age: prof.age)
        out.append(RuleResult(id: "P1", group: .portfolio, title: "S&P 500 sleeve", status: spAfter >= floor ? .pass : .fail,
                              actual: "\(Fmt.pct(c.spValue / max(c.totalValue, 1))) now → \(Fmt.pct(spAfter)) after this buy",
                              threshold: "≥ \(Fmt.pct(floor, digits: 0)) (age \(prof.age.map(String.init) ?? "unknown"))", weight: .soft,
                              detail: "Don't let the S&P sleeve get phased out (Nash). Rebalance quarterly; in taxable accounts use new money instead of selling."))
        var stocks = c.stockTickers
        if type == .stock { stocks.insert(ticker.uppercased()) }
        out.append(RuleResult(id: "P2", group: .portfolio, title: "Number of individual stocks", status: stocks.count > 10 ? .fail : (stocks.count > 6 ? .warn : .pass),
                              actual: "\(stocks.count)\(type == .stock && !c.stockTickers.contains(ticker.uppercased()) ? " incl. this one" : "")",
                              threshold: "≤ 10 (ideally 5–6)", weight: .soft))
        let isSpec = type.isSpeculation || prof.role == .speculation
        let specAfter = (c.speculationValue + (isSpec ? planned : 0)) / total
        out.append(RuleResult(id: "P3", group: .portfolio, title: "Speculation cap", status: specAfter <= 0.01 ? .pass : .fail,
                              actual: Fmt.pct(specAfter, digits: 2), threshold: "≤ 1% of portfolio", weight: isSpec ? .hard : .soft))
        if let cand = candidate {
            let ov = OverlapCalc.overlap(cand, c.exposure.normalised())
            out.append(RuleResult(id: "P4", group: .portfolio, title: "Overlap with what you already own", status: ov >= 0.70 ? .fail : (ov >= 0.50 ? .warn : .pass),
                                  actual: Fmt.pct(ov), threshold: "red flag if ≥ 70% (duplicates your holdings)", weight: .soft,
                                  detail: OverlapCalc.common(cand, c.exposure.normalised(), top: 5).map { "\($0.name) \(Fmt.pct($0.a)) here / \(Fmt.pct($0.b)) yours" }.joined(separator: "; ")))
        }
        if !c.unresolved.isEmpty {
            out.append(RuleResult(id: "P5", group: .portfolio, title: "Positions without holdings data", status: .warn,
                                  actual: c.unresolved.joined(separator: ", "), threshold: "overlap may be understated", weight: .info))
        }
        out += behaviour(type: type, request: request, maxDrawdown: maxDrawdown)
        return out
    }

    static func behaviour(type: AssetType, request: EvaluationRequest, maxDrawdown: Double?) -> [RuleResult] {
        var out: [RuleResult] = []
        let prof = request.profile
        if let tol = prof.maxDrawdownTolerance, let dd = maxDrawdown {
            out.append(RuleResult(id: "P6", group: .portfolio, title: "Drawdown you said you can hold", status: -dd <= tol ? .pass : .warn,
                                  actual: "historical max drawdown \(Fmt.pct(dd))", threshold: "≤ \(Fmt.pct(tol, digits: 0))", weight: .info,
                                  detail: "Write down what you will do at −20%, −30%, −40% before it happens."))
        }
        if let role = prof.role {
            let ok: Bool
            switch role {
            case .core: ok = [.etf, .mutualFund].contains(type)
            case .speculation: ok = true
            case .income: ok = [.etf, .mutualFund, .bondFund, .stock].contains(type)
            case .hedge: ok = [.bondFund, .etf, .mutualFund].contains(type)
            case .satellite: ok = !type.isSpeculation
            }
            out.append(RuleResult(id: "P7", group: .portfolio, title: "Role: \(role.rawValue)", status: ok ? .pass : .warn,
                                  actual: type.rawValue, threshold: "role should match the asset type", weight: .info))
        }
        if let acct = prof.accountType, acct == .taxable, type == .bondFund {
            out.append(RuleResult(id: "P8", group: .portfolio, title: "Account location", status: .warn, actual: "bond fund in a taxable account",
                                  threshold: "bonds/income are usually better in tax-advantaged accounts", weight: .info))
        }
        if let h = prof.horizonYears, h < 5, type != .bondFund {
            out.append(RuleResult(id: "P9", group: .portfolio, title: "Time horizon", status: .warn, actual: "\(h) yrs",
                                  threshold: "≥ 5 yrs for stock-heavy holdings", weight: .info))
        }
        return out
    }
}

nonisolated extension Exposure {
    func normalised() -> Exposure {
        let t = weights.values.reduce(0, +); guard t > 0 else { return self }
        var e = self; e.weights = weights.mapValues { $0 / t }; return e
    }
}

// MARK: - Price action (all asset types)

nonisolated enum PriceRules {
    static func evaluate(_ pa: PriceAction, fundamentalsIntact: Bool?, source: SourceRef?) -> [RuleResult] {
        var out: [RuleResult] = []
        if let c = pa.change30d {
            out.append(RuleResult(id: "A1", group: .price, title: "Parabolic rule (30-day move)", status: pa.isParabolic ? .warn : .pass,
                                  actual: Fmt.pct(c), threshold: "up ≥ 20% in 30 days → slow DCA to 50% speed", weight: .info,
                                  evidence: source.map { [DataPoint(key: "change30d", label: "30-day price change", value: c, unit: .percent, source: $0)] } ?? []))
        }
        if let d = pa.drawdownFrom52wHigh {
            let msg: String
            if pa.isDown { msg = fundamentalsIntact == true ? "Fundamentals intact: Nash's rule is to double the DCA" : (fundamentalsIntact == false ? "Price down and fundamentals failing: don't add" : "Price down: check fundamentals before adding") }
            else { msg = "normal DCA" }
            out.append(RuleResult(id: "A2", group: .price, title: "Down from 52-week high", status: pa.isDown ? .warn : .pass,
                                  actual: "\(Fmt.pct(d)) → \(msg)", threshold: "≥ 15% down triggers the dip rule", weight: .info))
        }
        return out
    }
}
