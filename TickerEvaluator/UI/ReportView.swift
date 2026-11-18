import SwiftUI

/// Screen 1: ticker input bar + the report.
struct ReportScreen: View {
    @Bindable var model: AppModel
    @State private var showOverlay = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Ticker, e.g. VOO, MSFT, BTC-USD", text: $model.ticker)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                    .onSubmit { Task { await model.evaluate() } }
                Button("Evaluate") { Task { await model.evaluate() } }
                    .keyboardShortcut(.defaultAction).disabled(model.busy || model.ticker.isEmpty)
                Button { Task { await model.evaluate(fresh: true) } } label: { Label("Fetch fresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command).disabled(model.busy || model.ticker.isEmpty)
                    .help("Download everything again instead of reusing what was downloaded in the last 15 minutes (⌘R)")
                Spacer()
                Menu {
                    Button("PDF…") { if let r = model.report { Exporter.save(r, pdf: true) } }
                    Button("Markdown…") { if let r = model.report { Exporter.save(r, pdf: false) } }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .fixedSize().disabled(model.report == nil || model.busy)
                .help("Save this report as PDF or Markdown")
                Button { model.showPositions = true } label: {
                    Label(model.positions.isEmpty ? "Add positions" : "Positions (\(model.positions.count))", systemImage: "list.bullet.rectangle")
                }.help("What you already own (manual entry or Fidelity CSV)")
                ProfileSummaryButton(model: model)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .disabled(model.busy)
            Divider()
            ZStack {
            if let e = model.error {
                ContentUnavailableView("Couldn't evaluate \(model.ticker)", systemImage: "exclamationmark.triangle", description: Text(e))
            } else if let r = model.report {
                ScrollView { ReportContent(report: r, model: model).padding(20) }
            } else {
                ContentUnavailableView("Enter a US ticker", systemImage: "chart.line.uptrend.xyaxis",
                                       description: Text("Stocks, ETFs, mutual funds, bond funds and crypto are compared against the S&P 500 total return."))
            }
            if showOverlay { LoadingOverlay(ticker: model.ticker, step: model.progress).transition(.opacity) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.2), value: showOverlay)
        // Shown only if loading takes > 0.25 s, so quick re-scores (profile edits) don't flash.
        .task(id: model.busy) {
            if model.busy { try? await Task.sleep(for: .milliseconds(250)); if model.busy { showOverlay = true } }
            else { showOverlay = false }
        }
        .sheet(isPresented: $model.showPositions) { PositionsView(model: model) }
        .inspector(isPresented: $model.showProfile) {
            ProfileView(model: model).inspectorColumnWidth(min: 300, ideal: 340, max: 420)
        }
    }
}

/// Covers the report while a ticker is being fetched: blocks clicks and shows the current step.
struct LoadingOverlay: View {
    var ticker: String
    var step: String
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 44, weight: .medium)).foregroundStyle(Theme.asset)
                    .symbolEffect(.variableColor.iterative.reversing, options: .repeating)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Evaluating \(ticker)").font(.title2.weight(.semibold))
                ProgressView().progressViewStyle(.linear).frame(width: 260)
                Text(step.isEmpty ? "Starting…" : step)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).frame(width: 360)
                    .contentTransition(.opacity).animation(.easeInOut(duration: 0.15), value: step)
                Text("Comparing against the S&P 500 total return · every number keeps its source")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(32)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.grid, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
        }
        .contentShape(Rectangle())
        .onTapGesture {}                     // swallow clicks so the report underneath can't be used
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Evaluating \(ticker). \(step)")
    }
}

/// The report body (no ScrollView, so it can also be rendered to an image or PDF).
struct ReportContent: View {
    var report: EvaluationReport
    var model: AppModel?

    static let disclaimer = "Educational tool, not financial advice. Past performance does not predict future returns. Rules follow Tom Nash's framework as summarised in your research notes."

    /// The report's sections in order; the PDF export lays these out page by page.
    @MainActor static func sections(_ report: EvaluationReport, model: AppModel?, print: Bool = false) -> [AnyView] {
        var out: [AnyView] = [AnyView(VerdictBanner(r: report)), AnyView(WhyCard(r: report))]
        if report.assetType != .reit { out.append(AnyView(RedFlagsCard(r: report))) }
        if let p = report.performance {
            if print {
                out.append(AnyView(PerformanceCard(ticker: report.ticker, perf: p, vsBND: report.performanceVsBND, part: .returns)))
                out.append(AnyView(PerformanceCard(ticker: report.ticker, perf: p, vsBND: report.performanceVsBND, part: .risk)))
            } else {
                out.append(AnyView(PerformanceCard(ticker: report.ticker, perf: p, vsBND: report.performanceVsBND)))
            }
        }
        out.append(AnyView(PortfolioFitCard(r: report, model: model)))
        out.append(AnyView(ThreeFundCard(r: report)))
        out.append(AnyView(ScorecardCard(r: report, model: model)))
        if let f = report.fund { out.append(AnyView(FundCard(r: report, fund: f))) }
        if let d = report.dividends, !d.years.isEmpty || (d.trailing12mYield ?? 0) > 0 { out.append(AnyView(DividendCard(ticker: report.ticker, d: d, isMutualFund: report.sources.contains { $0.name.hasPrefix("Yahoo") } && report.rules.contains { $0.id == "M2" || $0.id == "M1" }))) }
        if let f = report.fundamentals { out.append(AnyView(FinancialsCard(f: f))) }
        out.append(AnyView(DataQualityCard(r: report)))
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let parts = Self.sections(report, model: model)
            ForEach(parts.indices, id: \.self) { parts[$0] }
            Text(Self.disclaimer)
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.top, 4)
        }
        .frame(maxWidth: 1100)
        .frame(maxWidth: .infinity)
    }
}

// MARK: Verdict

struct VerdictBanner: View {
    /// When this ticker's prices were downloaded (saved copies are reused for up to 15 minutes).
    private var downloaded: String {
        guard let at = r.sources.filter({ $0.url.contains("/v8/finance/chart/") && $0.url.contains(r.ticker) }).map(\.fetchedAt).min() else { return "" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        return Date.now.timeIntervalSince(at) < 60 ? " · prices just downloaded" : " · prices downloaded \(f.localizedString(for: at, relativeTo: .now))"
    }
    var r: EvaluationReport
    var body: some View {
        let v = r.verdict.verdict, c = Theme.verdictColor(v)
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: Theme.verdictIcon(v)).font(.system(size: 40)).foregroundStyle(c)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(r.ticker) · \(r.name)").font(.headline).foregroundStyle(.secondary)
                Text(v.rawValue).font(.system(size: 30, weight: .bold))
                Text("\(r.assetType.rawValue) · as of \(Fmt.date(r.performance?.end ?? r.generatedAt))\(downloaded)").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("Confidence").font(.caption).foregroundStyle(.secondary)
                Text(r.verdict.confidence.rawValue).font(.title2.weight(.semibold))
                Text(r.verdict.confidenceDetail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing).frame(maxWidth: 320, alignment: .trailing)
            }
        }
        .padding(18)
        .background(c.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(c.opacity(0.6), lineWidth: 1.5))
    }
}

struct WhyCard: View {
    var r: EvaluationReport
    var body: some View {
        Card(title: "Why") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(r.verdict.reasons.indices, id: \.self) { i in
                    let reason = r.verdict.reasons[i]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reason.text)
                        HStack(spacing: 12) {
                            if let e = reason.evidence.first { SourceBadge(source: e.source) }
                            if let c = reason.citation { Text(c).font(.caption).foregroundStyle(.secondary).italic() }
                        }
                    }
                }
                if !r.verdict.actions.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text("What to do").font(.headline)
                    ForEach(r.verdict.actions, id: \.self) { Label($0, systemImage: "arrow.right.circle").foregroundStyle(.primary) }
                }
            }
        }
    }
}

// MARK: Performance vs S&P

struct PerformanceCard: View {
    enum Part { case all, returns, risk }      // PDF prints it as two cards so charts aren't cut across pages
    var ticker: String
    var perf: PerformanceReport
    var vsBND: PerformanceReport?
    var part: Part = .all
    @State private var rollingYears = 5
    @Environment(\.printMode) private var printMode

    var body: some View {
        Card(title: part == .risk ? "Compared with the S&P 500: drawdowns and risk" : "Compared with the S&P 500 (total return)",
             subtitle: "\(Fmt.date(perf.start)) → \(Fmt.date(perf.end)), dividends reinvested") {
            if part != .risk { returnsPart }
            if part == .all { Divider() }
            if part != .returns { riskPart }
        }
    }

    @ViewBuilder private var returnsPart: some View {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 6) {
                GridRow { ForEach(["Period", ticker, "S&P 500 TR", "Difference"], id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) } }
                Divider()
                ForEach(perf.periods, id: \.label) { p in
                    GridRow {
                        Text(p.label + (p.label == "1y" || p.label.hasPrefix("Since") ? "" : " /yr"))
                        Text(p.asset.map { Fmt.pct($0) } ?? "n/a").monospacedDigit()
                        Text(p.benchmark.map { Fmt.pct($0) } ?? "n/a").monospacedDigit()
                        diff(p.asset, p.benchmark)
                    }
                }
            }
            Divider()
            Text("Growth of $10,000").font(.headline)
            GrowthChart(ticker: ticker, perf: perf)
    }

    @ViewBuilder private var riskPart: some View {
            Text("Drawdowns (fall from previous peak)").font(.headline)
            DrawdownChart(ticker: ticker, perf: perf)
            HStack {
                Text("Rolling excess return vs S&P (per year)").font(.headline)
                Spacer()
                if printMode { Text("\(rollingYears)-yr windows").font(.caption).foregroundStyle(.secondary) } else {
                    Picker("", selection: $rollingYears) { Text("3-yr windows").tag(3); Text("5-yr windows").tag(5) }
                        .pickerStyle(.segmented).frame(width: 220)
                }
            }.padding(.top, 6)
            let roll = rollingYears == 5 ? perf.rolling5 : perf.rolling3
            if roll.windows > 0 { RollingExcessChart(ticker: ticker, rolling: roll) }
            else { Text("Not enough history for \(rollingYears)-yr windows.").foregroundStyle(.secondary) }
            Divider()
            Text("Risk (\(perf.riskWindowLabel); drawdown uses full history)").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 6) {
                GridRow { ForEach(["", ticker, "S&P 500 TR"], id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) } }
                row("Max drawdown", Fmt.pct(perf.drawdown.maxDrawdown) + "  (\(Fmt.date(perf.drawdown.peakDate)) → \(Fmt.date(perf.drawdown.troughDate)))", Fmt.pct(perf.benchmarkDrawdown.maxDrawdown))
                row("Recovery time", perf.drawdown.recoveryDays.map { "\($0) days" } ?? "not yet recovered", perf.benchmarkDrawdown.recoveryDays.map { "\($0) days" } ?? "not yet recovered")
                row("Volatility (annualised)", Fmt.pct(perf.volatility), Fmt.pct(perf.benchmarkVolatility))
                row("Sharpe ratio (risk-free \(perf.riskFreeUsed.map { Fmt.pct($0, digits: 2) } ?? "n/a"))",
                    perf.sharpe.map { String(format: "%.2f", $0) } ?? "n/a", perf.benchmarkSharpe.map { String(format: "%.2f", $0) } ?? "n/a")
                row("Beta / correlation (monthly)", String(format: "%.2f / %.2f", perf.beta, perf.correlation), "1.00 / 1.00")
                row("Up / down capture", "\(perf.upCapture.map { Fmt.pct($0, digits: 0) } ?? "n/a") / \(perf.downCapture.map { Fmt.pct($0, digits: 0) } ?? "n/a")", "100% / 100%")
            }
            if let b = vsBND {
                Divider()
                Text("Compared with BND (total US bond index)").font(.headline)
                Text(b.periods.map { "\($0.label): \($0.asset.map { Fmt.pct($0) } ?? "n/a") vs \($0.benchmark.map { Fmt.pct($0) } ?? "n/a")" }.joined(separator: " · "))
                    .font(.callout)
            }
    }

    private func row(_ a: String, _ b: String, _ c: String) -> some View {
        GridRow { Text(a); Text(b).monospacedDigit(); Text(c).monospacedDigit() }
    }
    @ViewBuilder private func diff(_ a: Double?, _ b: Double?) -> some View {
        if let a, let b {
            let d = a - b
            let text = (d > 0 ? "+" : "") + Fmt.pct(d, digits: abs(d) < 0.01 ? 2 : 1)
            if abs(d) < 0.00005 { Text("0.00%").monospacedDigit() }
            else {
                Label(text, systemImage: d >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .monospacedDigit().foregroundStyle(.primary).labelStyle(.titleAndIcon)
            }
        } else { Text("n/a").foregroundStyle(.secondary) }
    }
}

// MARK: Scorecard

struct ScorecardCard: View {
    var r: EvaluationReport
    var model: AppModel?

    var body: some View {
        Card(title: "Scorecard", subtitle: "Hard rules → Avoid if failed · soft rules → Hold off if failed · info rules never change the verdict") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(RuleGroup.allCases, id: \.self) { g in
                    let rows = r.rules.filter { $0.group == g }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(g.rawValue).font(.headline)
                            ForEach(rows) { RuleRow(rule: $0, model: model) }
                        }
                    }
                }
            }
        }
    }
}

struct RuleRow: View {
    var rule: RuleResult
    var model: AppModel?
    private var isJudgement: Bool { ["S5", "S6", "S7"].contains(rule.id) }

    /// -1 = not yet, 1 = yes, 0 = no
    private func answerBinding(_ model: AppModel) -> Binding<Int> {
        let id = rule.id
        return Binding<Int>(
            get: {
                guard let a = model.answer(for: id) else { return -1 }
                return a ? 1 : 0
            },
            set: { (v: Int) in
                let answer: Bool? = v == -1 ? nil : (v == 1)
                Task { await model.setJudgement(id, answer) }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                StatusChip(status: rule.status)
                Text(rule.title).fontWeight(.medium).frame(width: 260, alignment: .leading)
                Text(rule.actual).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
                Text(rule.threshold).font(.callout).foregroundStyle(.secondary).frame(width: 260, alignment: .leading)
                Text(rule.weight.rawValue).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            }
            if isJudgement, let model {
                HStack(spacing: 10) {
                    Text("Your answer:").font(.callout).foregroundStyle(.secondary)
                    Picker("", selection: answerBinding(model)) {
                        Text("Not yet").tag(-1); Text("✓ Yes").tag(1); Text("✗ No").tag(0)
                    }
                    .pickerStyle(.segmented).frame(width: 240).disabled(model.busy)
                    if let s = rule.suggestion { Text("App suggests \(s ? "✓" : "✗")").font(.callout).foregroundStyle(.secondary) }
                }
                .padding(.leading, 108)
            }
            if let d = rule.detail {
                Text(d).font(.callout).foregroundStyle(.secondary).padding(.leading, 108).fixedSize(horizontal: false, vertical: true)
            }
            if let e = rule.evidence.first { SourceBadge(source: e.source).padding(.leading, 108) }
        }
        .padding(.vertical, 4)
        Divider().opacity(0.5)
    }
}

// MARK: Fund facts

struct FundCard: View {
    var r: EvaluationReport
    var fund: FundProfile

    var body: some View {
        Card(title: "Fund facts", subtitle: [fund.family, fund.category, fund.legalType].compactMap { $0 }.joined(separator: " · ")) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                fact("Expense ratio", fund.expenseRatio.primary ?? fund.expenseRatio.secondary)
                fact("Fund net assets", fund.netAssets.primary ?? fund.netAssets.secondary)
                fact("Holdings", fund.holdingsCount)
                fact("Turnover", fund.turnover.primary ?? fund.turnover.secondary)
                fact("Distribution yield (12m)", fund.distributionYield)
                GridRow { Text("Inception").foregroundStyle(.secondary); Text(Fmt.date(fund.inceptionDate)); Text("") }
                if let n = fund.nport { GridRow { Text("Holdings as of").foregroundStyle(.secondary); Text(n.periodDate); SourceBadge(source: n.source) } }
            }
            if let o = fund.objective { Text(o).font(.callout).foregroundStyle(.secondary).lineLimit(4) }
            HStack(alignment: .top, spacing: 24) {
                if !fund.top10.isEmpty {
                    VStack(alignment: .leading) {
                        Text("Top 10 holdings (\(Fmt.pct(fund.top10.reduce(0) { $0 + $1.weight })))").font(.headline)
                        WeightBars(rows: fund.top10.map { ($0.symbol ?? $0.name, $0.weight) })
                    }.frame(maxWidth: .infinity)
                }
                if !fund.sectors.isEmpty {
                    VStack(alignment: .leading) {
                        Text("Sectors").font(.headline)
                        WeightBars(rows: fund.sectors.prefix(11).map { ($0.name, $0.weight) })
                    }.frame(maxWidth: .infinity)
                }
            }
            if let ov = r.overlapWithSP {
                Divider()
                Text("Overlap with the S&P 500 (VOO): \(Fmt.pct(ov)) by weight").font(.headline)
                if ov < 0.95, !r.overlapCommonWithSP.isEmpty { OverlapBars(ticker: r.ticker, rows: Array(r.overlapCommonWithSP.prefix(8))) }
            }
            if !r.feeDrag.isEmpty {
                Divider()
                Text("Fee drag on \(Fmt.usd(r.request.profile.plannedAmount ?? 10_000)) (illustrative 8%/yr, not a forecast)").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 4) {
                    GridRow { ForEach(["Years", "Total fees cost", "Extra vs VOO's 0.03%"], id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) } }
                    ForEach(r.feeDrag, id: \.years) { d in GridRow { Text("\(d.years)"); Text(Fmt.usd(d.costVsZero)).monospacedDigit(); Text(Fmt.usd(d.costVsReference)).monospacedDigit() } }
                }
            }
        }
    }

    @ViewBuilder private func fact(_ label: String, _ d: DataPoint?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(d?.formatted ?? "n/a").monospacedDigit()
            if let d { SourceBadge(source: d.source) } else { Text("") }
        }
    }
}

// MARK: Financials (stocks)

struct FinancialsCard: View {
    var f: CompanyFundamentals
    var body: some View {
        Card(title: "Financials (SEC filings, fiscal years)", subtitle: "Expenses measured as \(f.opexConcept)") {
            Grid(alignment: .trailing, horizontalSpacing: 22, verticalSpacing: 5) {
                GridRow { ForEach(["FY end", "Revenue", "Growth", "Op. margin", "FCF", "FCF margin", "Opex growth"], id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) } }
                Divider()
                ForEach(Array(f.years.enumerated().suffix(10)), id: \.offset) { i, y in
                    let prev = i > 0 ? f.years[i - 1] : nil
                    GridRow {
                        Text(Fmt.date(y.end)).gridColumnAlignment(.leading)
                        Text(y.revenue.map(Fmt.usd) ?? "n/a")
                        Text(prev.flatMap { p in ratio(y.revenue, p.revenue).map { Fmt.pct($0 - 1) } } ?? "")
                        Text(y.operatingMargin.map { Fmt.pct($0) } ?? "n/a")
                        Text(y.freeCashFlow.map(Fmt.usd) ?? "n/a")
                        Text(y.fcfMargin.map { Fmt.pct($0) } ?? "n/a")
                        Text(prev.flatMap { p in ratio(f.opex(y), f.opex(p)).map { Fmt.pct($0 - 1) } } ?? "")
                    }.monospacedDigit()
                }
            }
            if let b = f.balance {
                Divider()
                Text("Balance sheet \(Fmt.date(b.date)) (\(b.form)): cash + short-term investments \(Fmt.usd(b.totalCash ?? 0)) · debt \(Fmt.usd(b.debtExLeases ?? 0)) · leases (not counted) \(Fmt.usd((b.operatingLeases ?? 0) + (b.financeLeases ?? 0))) · equity \(Fmt.usd(b.equity ?? 0))")
                    .font(.callout)
            }
            SourceBadge(source: f.source)
        }
    }
}

// MARK: Data quality

struct DataQualityCard: View {
    var r: EvaluationReport
    var body: some View {
        Card(title: "Data quality", subtitle: "Two-source rule: key numbers checked against a second source") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow { ForEach(["Number", "Source 1", "Source 2", "Status"], id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) } }
                Divider()
                ForEach(r.checks.indices, id: \.self) { i in
                    let c = r.checks[i]
                    GridRow {
                        Text(c.label)
                        cell(c.primary); cell(c.secondary)
                        status(c)
                    }
                }
            }
            if !r.stale.isEmpty { Label(r.stale.joined(separator: " · "), systemImage: "clock.badge.exclamationmark").foregroundStyle(.primary) }
            if !r.missing.isEmpty { Label("Missing: " + r.missing.joined(separator: " · "), systemImage: "questionmark.folder").foregroundStyle(.primary) }
            DisclosureGroup("Sources used (\(r.sources.count))") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(r.sources, id: \.url) { SourceBadge(source: $0) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Classification: \(r.classificationNote)").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func cell(_ d: DataPoint?) -> some View {
        if let d {
            VStack(alignment: .leading, spacing: 1) { Text(d.formatted).monospacedDigit(); SourceBadge(source: d.source) }
        } else { Text("—").foregroundStyle(.secondary) }
    }
    @ViewBuilder private func status(_ c: CrossCheck) -> some View {
        switch c.status {
        case .agree: Label("Agree", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
        case .conflict: Label("Conflict \(c.differencePct.map { Fmt.pct($0) } ?? "")", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.critical)
        case .definitionDiffers: Label("Different definitions \(c.differencePct.map { Fmt.pct($0) } ?? "")", systemImage: "arrow.left.arrow.right.circle").foregroundStyle(Theme.warning)
        case .singleSource: Label("Single source", systemImage: "1.circle").foregroundStyle(.secondary)
        }
    }
}
