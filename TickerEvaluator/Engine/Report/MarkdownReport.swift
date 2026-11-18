import Foundation

nonisolated enum MarkdownReport {
    static func render(_ r: EvaluationReport) -> String {
        var md: [String] = []
        func line(_ s: String = "") { md.append(s) }
        func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }

        line("# \(r.ticker): \(r.name)")
        line("_\(r.assetType.rawValue) · generated \(Fmt.date(r.generatedAt)) · educational tool, not financial advice_")
        line()
        line("## Verdict: **\(r.verdict.verdict.rawValue)**  (confidence: \(r.verdict.confidence.rawValue))")
        line("_\(r.verdict.confidenceDetail)_")
        line()
        line("### Why")
        for reason in r.verdict.reasons {
            var s = "- \(reason.text)"
            if let e = reason.evidence.first { s += " _[\(e.source.name), as of \(Fmt.date(e.source.asOf))]_" }
            if let c = reason.citation { s += " _(\(c))_" }
            line(s)
        }
        if !r.verdict.actions.isEmpty {
            line(); line("### What to do")
            r.verdict.actions.forEach { line("- \($0)") }
        }

        line(); line("## Scorecard")
        for g in RuleGroup.allCases {
            let rows = r.rules.filter { $0.group == g }
            guard !rows.isEmpty else { continue }
            line(); line("### \(g.rawValue)")
            line("| | Rule | Actual | Threshold | Weight |"); line("|---|---|---|---|---|")
            for x in rows { line("| \(x.status.rawValue) | \(cell(x.title)) | \(cell(x.actual)) | \(cell(x.threshold)) | \(x.weight.rawValue) |") }
            for x in rows where x.detail != nil { line("- _\(x.title):_ \(x.detail!)") }
        }

        if let p = r.performance {
            line(); line("## vs \(p.benchmarkSymbol)  (\(Fmt.date(p.start)) → \(Fmt.date(p.end)))")
            line("| Period | \(r.ticker) | S&P 500 TR | Difference |"); line("|---|---|---|---|")
            for x in p.periods {
                let d = (x.asset != nil && x.benchmark != nil) ? Fmt.pct(x.asset! - x.benchmark!) : "n/a"
                line("| \(x.label)\(x.label.hasSuffix("y") && x.label != "1y" ? " (annualised)" : "") | \(x.asset.map { Fmt.pct($0) } ?? "n/a") | \(x.benchmark.map { Fmt.pct($0) } ?? "n/a") | \(d) |")
            }
            let g = p.growthOf10k
            line(); line("Growth of $10,000 since \(Fmt.date(p.start)): **\(Fmt.usd(g.asset.values.last ?? 0))** vs S&P 500 **\(Fmt.usd(g.benchmark.values.last ?? 0))**")
            line(); line("| Risk (\(p.riskWindowLabel)) | \(r.ticker) | S&P 500 TR |"); line("|---|---|---|")
            line("| Max drawdown (full history) | \(Fmt.pct(p.drawdown.maxDrawdown)) (\(Fmt.date(p.drawdown.peakDate)) → \(Fmt.date(p.drawdown.troughDate))) | \(Fmt.pct(p.benchmarkDrawdown.maxDrawdown)) |")
            line("| Recovery time | \(p.drawdown.recoveryDays.map { "\($0) days" } ?? "not yet recovered") | \(p.benchmarkDrawdown.recoveryDays.map { "\($0) days" } ?? "not yet recovered") |")
            line("| Volatility (annualised) | \(Fmt.pct(p.volatility)) | \(Fmt.pct(p.benchmarkVolatility)) |")
            line("| Sharpe (rf \(p.riskFreeUsed.map { Fmt.pct($0, digits: 2) } ?? "n/a")) | \(p.sharpe.map { String(format: "%.2f", $0) } ?? "n/a") | \(p.benchmarkSharpe.map { String(format: "%.2f", $0) } ?? "n/a") |")
            line("| Beta / correlation (monthly) | \(String(format: "%.2f", p.beta)) / \(String(format: "%.2f", p.correlation)) | 1.00 / 1.00 |")
            line("| Up / down capture | \(p.upCapture.map { Fmt.pct($0, digits: 0) } ?? "n/a") / \(p.downCapture.map { Fmt.pct($0, digits: 0) } ?? "n/a") | 100% / 100% |")
            for roll in [p.rolling3, p.rolling5] where roll.windows > 0 {
                line("| Rolling \(roll.windowYears)-yr windows beating S&P | \(Fmt.pct(roll.beatPct ?? 0, digits: 0)) of \(roll.windows) (avg excess \(Fmt.pct(roll.averageExcess ?? 0))/yr) | — |")
            }
        }
        if let pb = r.performanceVsBND {
            line(); line("### vs BND (total US bond)")
            for x in pb.periods { line("- \(x.label): \(x.asset.map { Fmt.pct($0) } ?? "n/a") vs \(x.benchmark.map { Fmt.pct($0) } ?? "n/a")") }
        }

        if let f = r.fundamentals {
            line(); line("## Financials (SEC XBRL, fiscal years)")
            line("| FY end | Revenue | Rev. growth | Op. margin | FCF | FCF margin | Opex growth |"); line("|---|---|---|---|---|---|---|")
            for (i, y) in f.years.enumerated().suffix(10) {
                let prev = i > 0 ? f.years[i - 1] : nil
                let rg = prev.flatMap { p in ratio(y.revenue, p.revenue).map { $0 - 1 } }
                let og = prev.flatMap { p in ratio(f.opex(y), f.opex(p)).map { $0 - 1 } }
                line("| \(Fmt.date(y.end)) | \(y.revenue.map(Fmt.usd) ?? "n/a") | \(rg.map { Fmt.pct($0) } ?? "") | \(y.operatingMargin.map { Fmt.pct($0) } ?? "n/a") | \(y.freeCashFlow.map(Fmt.usd) ?? "n/a") | \(y.fcfMargin.map { Fmt.pct($0) } ?? "n/a") | \(og.map { Fmt.pct($0) } ?? "") |")
            }
        }

        if let fp = r.fund {
            line(); line("## Fund facts")
            line("- Name / family / category: \(fp.name ?? "n/a") / \(fp.family ?? "n/a") / \(fp.category ?? "n/a")")
            line("- Inception: \(Fmt.date(fp.inceptionDate)) · holdings: \(fp.holdingsCount.map { Fmt.grouped($0.value) } ?? "n/a")\(fp.nport.map { " (N-PORT as of \($0.periodDate))" } ?? "")")
            if let o = fp.objective { line("- Objective: \(String(o.prefix(400)))\(o.count > 400 ? "…" : "")") }
            if !fp.top10.isEmpty { line("- Top 10 (\(Fmt.pct(fp.top10.reduce(0) { $0 + $1.weight }))): " + fp.top10.map { "\($0.symbol ?? $0.name) \(Fmt.pct($0.weight))" }.joined(separator: ", ")) }
            if !fp.sectors.isEmpty { line("- Sectors: " + fp.sectors.prefix(6).map { "\($0.name) \(Fmt.pct($0.weight))" }.joined(separator: ", ")) }
            if let d = fp.distributionYield { line("- Distribution yield (trailing 12m): \(Fmt.pct(d.value, digits: 2))") }
            if let ov = r.overlapWithSP {
                line("- Overlap with VOO (by weight): **\(Fmt.pct(ov))**. Largest shared: " + r.overlapCommonWithSP.prefix(5).map { "\($0.name) \(Fmt.pct(min($0.a, $0.b)))" }.joined(separator: ", "))
            }
            if !r.feeDrag.isEmpty {
                line("- Fee drag on \(Fmt.usd(r.request.profile.plannedAmount ?? 10_000)) at an illustrative 8%/yr: " +
                     r.feeDrag.map { "\($0.years) yrs \(Fmt.usd($0.costVsZero)) (\(Fmt.usd($0.costVsReference)) more than VOO's 0.03%)" }.joined(separator: "; "))
            }
        }
        if let d = r.dividends, !d.byYear.isEmpty {
            line(); line("## Dividends")
            line("Trailing 12-month yield: \(d.trailing12mYield.map { Fmt.pct($0, digits: 2) } ?? "n/a") · payments in last 12m: \(d.paymentsPerYear.map(String.init) ?? "n/a")")
            line("By year: " + d.byYear.suffix(10).map { "\($0.year): $\(String(format: "%.2f", $0.amount))" }.joined(separator: ", "))
        }

        line(); line("## Data quality")
        line("| Number | Source 1 | Source 2 | Status |"); line("|---|---|---|---|")
        for c in r.checks {
            func v(_ d: DataPoint?) -> String { d.map { "\($0.formatted) (\($0.source.name), \(Fmt.date($0.source.asOf)))" } ?? "—" }
            line("| \(c.label) | \(cell(v(c.primary))) | \(cell(v(c.secondary))) | \(c.status.rawValue)\(c.differencePct.map { " (\(Fmt.pct($0)) diff)" } ?? "") |")
        }
        if !r.stale.isEmpty { line(); line("**Stale:** " + r.stale.joined(separator: "; ")) }
        if !r.missing.isEmpty { line(); line("**Missing:** " + r.missing.joined(separator: "; ")) }
        line(); line("### Sources")
        for s in r.sources { line("- \(s.name): <\(s.url)> (as of \(Fmt.date(s.asOf)), fetched \(Fmt.date(s.fetchedAt)))") }
        line(); line("_Classification: \(r.classificationNote)_")
        line(); line("---"); line("_Educational tool, not financial advice. Past performance does not predict future returns. Rules follow Tom Nash's framework as summarised in your notes._")
        return md.joined(separator: "\n")
    }
}
