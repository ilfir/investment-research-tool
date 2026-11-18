import SwiftUI
import Charts

/// Keep charts responsive: at most ~`max` points per series.
private func thin(_ s: Series, max: Int = 600, keepMin: Bool = false) -> [(Date, Double)] {
    let step = Swift.max(1, s.dates.count / max)
    var out: [(Date, Double)] = stride(from: 0, to: s.dates.count, by: step).map { i in
        guard keepMin else { return (s.dates[i], s.values[i]) }
        let r = i..<Swift.min(i + step, s.dates.count)
        let j = r.min { s.values[$0] < s.values[$1] } ?? i     // keep the lowest point (drawdown troughs)
        return (s.dates[j], s.values[j])
    }
    if let d = s.dates.last, out.last?.0 != d { out.append((d, s.values.last!)) }
    return out
}

private struct Pt: Identifiable { let id: Int; let date: Date; let value: Double; let series: String }

private func points(_ s: Series, _ name: String, offset: Int, max: Int = 600, keepMin: Bool = false) -> [Pt] {
    thin(s, max: max, keepMin: keepMin).enumerated().map { Pt(id: offset + $0.offset, date: $0.element.0, value: $0.element.1, series: name) }
}

/// Nearest value on or before a date, for hover readouts.
private func near(_ pts: [Pt], _ d: Date) -> Pt? { pts.last { $0.date <= d } ?? pts.first }

// MARK: Growth of $10,000

struct GrowthChart: View {
    @Environment(\.printMode) private var printMode
    var ticker: String
    var perf: PerformanceReport
    @State private var hover: Date?
    @State private var range = 0          // 0 = all, 10 / 5 = last N years

    /// Re-base both series to $10,000 at the start of the chosen range.
    private func rebased() -> (Series, Series) {
        let a = perf.growthOf10k.asset, b = perf.growthOf10k.benchmark
        guard range > 0, let end = a.dates.last, let start = Calendar.utc.date(byAdding: .year, value: -range, to: end) else { return (a, b) }
        let ra = a.since(start), rb = b.since(start)
        guard let a0 = ra.values.first, let b0 = rb.values.first else { return (a, b) }
        return (Series(dates: ra.dates, values: ra.values.map { $0 / a0 * 10_000 }),
                Series(dates: rb.dates, values: rb.values.map { $0 / b0 * 10_000 }))
    }

    var body: some View {
        let (sa, sb) = rebased()
        let a = points(sa, ticker, offset: 0), b = points(sb, "S&P 500 TR", offset: 100_000)
        let hi = max(a.map(\.value).max() ?? 1, b.map(\.value).max() ?? 1)
        let lo = max(1, min(a.map(\.value).min() ?? 1, b.map(\.value).min() ?? 1))
        let useLog = hi / lo > 20
        let aEnd = a.last?.value ?? 0, bEnd = b.last?.value ?? 0
        let years = Stats.years(perf.start, perf.end)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Legend(items: [(ticker, Theme.asset), ("S&P 500 total return", Theme.benchmark)])
                Spacer()
                if useLog { Text("Log scale").font(.caption).foregroundStyle(.secondary) }
                if printMode { Text("Full history").font(.caption).foregroundStyle(.secondary) } else {
                    Picker("", selection: $range) {
                        Text("All").tag(0)
                        if years > 10.5 { Text("10 yrs").tag(10) }
                        if years > 5.5 { Text("5 yrs").tag(5) }
                    }.pickerStyle(.segmented).frame(width: 200)
                }
            }
            Chart {
                ForEach(a) { LineMark(x: .value("Date", $0.date), y: .value("Value", $0.value), series: .value("Series", $0.series))
                    .foregroundStyle(Theme.asset).lineStyle(StrokeStyle(lineWidth: 2)) }
                ForEach(b) { LineMark(x: .value("Date", $0.date), y: .value("Value", $0.value), series: .value("Series", $0.series))
                    .foregroundStyle(Theme.benchmark).lineStyle(StrokeStyle(lineWidth: 2)) }
                if let l = a.last { endLabel(l, ticker, Theme.asset, above: aEnd >= bEnd) }
                if let l = b.last { endLabel(l, "S&P 500", Theme.benchmark, above: bEnd > aEnd) }
                if let hover, let pa = near(a, hover), let pb = near(b, hover) {
                    RuleMark(x: .value("Date", hover)).foregroundStyle(Color.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Tooltip(title: Fmt.date(pa.date), rows: [(ticker, Fmt.usd(pa.value), Theme.asset), ("S&P 500", Fmt.usd(pb.value), Theme.benchmark)])
                        }
                }
            }
            .chartXScale(domain: (a.first?.date ?? perf.start)...(a.last?.date ?? perf.end))
            .chartYScale(type: useLog ? .log : .linear)
            .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine().foregroundStyle(Theme.grid); AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.usd(d)) } } } }
            .chartXAxis { AxisMarks { AxisGridLine().foregroundStyle(Theme.grid.opacity(0.5)); AxisValueLabel() } }
            .chartXSelection(value: $hover)
            .padding(.trailing, 90)      // room for the end labels
            .frame(height: 260)
        }
    }

    @ChartContentBuilder
    private func endLabel(_ p: Pt, _ name: String, _ c: Color, above: Bool) -> some ChartContent {
        PointMark(x: .value("Date", p.date), y: .value("Value", p.value)).foregroundStyle(c).symbolSize(40)
            .annotation(position: above ? .topTrailing : .bottomTrailing, alignment: .leading, spacing: 2) {
                Text("\(name) \(Fmt.usd(p.value))").font(.caption2.weight(.medium)).foregroundStyle(.primary).fixedSize()
            }
    }
}

// MARK: Drawdowns

struct DrawdownChart: View {
    var ticker: String
    var perf: PerformanceReport
    @State private var hover: Date?

    var body: some View {
        let a = points(perf.drawdown.series, ticker, offset: 0, max: 800, keepMin: true)
        let b = points(perf.benchmarkDrawdown.series, "S&P 500 TR", offset: 100_000, max: 800, keepMin: true)
        VStack(alignment: .leading, spacing: 8) {
            Legend(items: [(ticker, Theme.asset), ("S&P 500 total return", Theme.benchmark)])
            Chart {
                ForEach(a) { AreaMark(x: .value("Date", $0.date), y: .value("Drawdown", $0.value), series: .value("Series", $0.series))
                    .foregroundStyle(Theme.asset.opacity(0.25)) }
                ForEach(a) { LineMark(x: .value("Date", $0.date), y: .value("Drawdown", $0.value), series: .value("Series", $0.series))
                    .foregroundStyle(Theme.asset).lineStyle(StrokeStyle(lineWidth: 1.5)) }
                ForEach(b) { LineMark(x: .value("Date", $0.date), y: .value("Drawdown", $0.value), series: .value("Series", $0.series))
                    .foregroundStyle(Theme.benchmark).lineStyle(StrokeStyle(lineWidth: 1.5)) }
                if let t = perf.drawdown.troughDate {
                    PointMark(x: .value("Date", t), y: .value("Drawdown", perf.drawdown.maxDrawdown)).foregroundStyle(Theme.asset).symbolSize(50)
                        .annotation(position: .bottom) { Text("Max \(Fmt.pct(perf.drawdown.maxDrawdown))").font(.caption2.weight(.medium)) }
                }
                if let hover, let pa = near(a, hover), let pb = near(b, hover) {
                    RuleMark(x: .value("Date", hover)).foregroundStyle(Color.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Tooltip(title: Fmt.date(pa.date), rows: [(ticker, Fmt.pct(pa.value), Theme.asset), ("S&P 500", Fmt.pct(pb.value), Theme.benchmark)])
                        }
                }
            }
            .chartYScale(domain: (min(perf.drawdown.maxDrawdown, perf.benchmarkDrawdown.maxDrawdown) * 1.15)...0)
            .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(Theme.grid); AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.pct(d, digits: 0)) } } } }
            .chartXSelection(value: $hover)
            .frame(height: 200)
        }
    }
}

// MARK: Rolling excess return (diverging: above / below the S&P)

struct RollingExcessChart: View {
    var ticker: String
    var rolling: RollingResult
    @State private var hover: Date?

    var body: some View {
        let pts = points(rolling.excessSeries, ticker, offset: 0, max: 400)
        let span = (pts.map(\.value).max() ?? 0) - (pts.map(\.value).min() ?? 0)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Legend(items: [("Beat the S&P", Theme.positive), ("Lagged the S&P", Theme.negative)])
                Spacer()
                Text("Beat the S&P in \(Fmt.pct(rolling.beatPct ?? 0, digits: 0)) of \(rolling.windows) windows").font(.caption).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(pts) { p in
                    BarMark(x: .value("Window end", p.date, unit: .month), y: .value("Excess", p.value))
                        .foregroundStyle(p.value >= 0 ? Theme.positive : Theme.negative)
                }
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1))
                if let hover, let p = near(pts, hover) {
                    RuleMark(x: .value("Date", hover)).foregroundStyle(Color.secondary.opacity(0.5))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Tooltip(title: "\(rolling.windowYears) yrs to \(Fmt.date(p.date))",
                                    rows: [("vs S&P per yr", (p.value >= 0 ? "+" : "") + Fmt.pct(p.value), p.value >= 0 ? Theme.positive : Theme.negative)])
                        }
                }
            }
            .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(Theme.grid); AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.pct(d, digits: span < 0.04 ? 2 : 0)) } } } }
            .chartXSelection(value: $hover)
            .frame(height: 170)
        }
    }
}

// MARK: Holdings / sectors (single series → no legend; the title names it)

struct WeightBars: View {
    var rows: [(String, Double)]
    var color: Color = Theme.asset
    @State private var hover: String?

    var body: some View {
        Chart {
            ForEach(rows.indices, id: \.self) { i in
                BarMark(x: .value("Weight", rows[i].1), y: .value("Name", rows[i].0), height: .ratio(0.7))
                    .foregroundStyle(color.opacity(hover == nil || hover == rows[i].0 ? 1 : 0.45))
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4))
                    .annotation(position: .trailing) { Text(Fmt.pct(rows[i].1)).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks { AxisValueLabel().font(.caption) } }
        .chartYSelection(value: $hover)
        .frame(height: CGFloat(rows.count) * 22 + 10)
    }
}

/// Paired bars: weight in this fund vs weight in VOO, for the largest shared holdings.
struct OverlapBars: View {
    var ticker: String
    var rows: [(name: String, a: Double, b: Double)]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Legend(items: [("Weight in \(ticker)", Theme.asset), ("Weight in VOO", Theme.benchmark)])
            Chart {
                ForEach(rows.indices, id: \.self) { i in
                    BarMark(x: .value("Weight", rows[i].a), y: .value("Holding", rows[i].name))
                        .foregroundStyle(by: .value("Fund", ticker)).position(by: .value("Fund", ticker))
                    BarMark(x: .value("Weight", rows[i].b), y: .value("Holding", rows[i].name))
                        .foregroundStyle(by: .value("Fund", "VOO")).position(by: .value("Fund", "VOO"))
                }
            }
            .chartForegroundStyleScale([ticker: Theme.asset, "VOO": Theme.benchmark])
            .chartLegend(.hidden)
            .chartXAxis { AxisMarks { v in AxisGridLine().foregroundStyle(Theme.grid); AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.pct(d, digits: 0)) } } } }
            .frame(height: CGFloat(rows.count) * 30 + 30)
        }
    }
}

struct Tooltip: View {
    var title: String
    var rows: [(String, String, Color)]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    Circle().fill(rows[i].2).frame(width: 7, height: 7)
                    Text(rows[i].0).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(rows[i].1).font(.caption.monospacedDigit())
                }
            }
        }
        .padding(8).frame(minWidth: 150)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
