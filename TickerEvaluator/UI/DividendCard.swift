import SwiftUI
import Charts

/// Dividend and yield history: dividends per share by calendar year (bars) and the yield each year (line, its own chart).
struct DividendCard: View {
    var ticker: String
    var d: DividendInfo
    var isMutualFund = false
    @State private var hover: Int?

    private var shown: [DividendInfo.Year] { Array(d.years.suffix(15)) }

    var body: some View {
        Card(title: isMutualFund ? "Distributions and yield" : "Dividends and yield",
             subtitle: "Per share, by calendar year (split-adjusted). Lighter bars are part-years." +
                (isMutualFund ? " For mutual funds Yahoo includes capital-gains distributions in these amounts." : "")) {
            HStack(alignment: .top, spacing: 28) {
                stat("Trailing 12-month yield", d.trailing12mYield.map { Fmt.pct($0, digits: 2) } ?? "n/a")
                stat("Payments in last 12 months", d.paymentsPerYear.map(String.init) ?? "n/a")
                stat("Dividend growth, 5 yrs /yr", d.growth(years: 5).map { Fmt.pct($0) } ?? "n/a")
                stat("Raised in", d.raises(lastYears: 10).map { "\($0.raised) of last \($0.of) yrs" } ?? "n/a")
                Spacer()
                if let s = d.source { SourceBadge(source: s) }
            }
            if shown.isEmpty {
                Text("\(ticker) hasn't paid dividends in the price history.").foregroundStyle(.secondary)
            } else {
                Text("Dividends per share").font(.headline).padding(.top, 4)
                Chart {
                    ForEach(shown, id: \.year) { y in
                        BarMark(x: .value("Year", String(y.year)), y: .value("Dividend", y.amount), width: .ratio(0.7))
                            .foregroundStyle(Theme.asset.opacity(y.partial ? 0.4 : (hover == nil || hover == y.year ? 1 : 0.55)))
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                    }
                    if let h = hover, let y = shown.first(where: { $0.year == h }) {
                        RuleMark(x: .value("Year", String(y.year))).foregroundStyle(.clear)
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                Tooltip(title: "\(y.year)\(y.partial ? " (part-year)" : "")", rows: [
                                    ("Dividends", String(format: "$%.2f", y.amount), Theme.asset),
                                    ("Yield", y.yield.map { Fmt.pct($0, digits: 2) } ?? "n/a", Theme.asset),
                                    ("Payments", "\(y.payments)", Theme.asset)])
                            }
                    }
                }
                .chartXSelection(value: Binding(get: { hover.map(String.init) }, set: { hover = $0.flatMap(Int.init) }))
                .chartYAxis { AxisMarks(position: .leading) { v in
                    AxisGridLine().foregroundStyle(Theme.grid)
                    AxisValueLabel { if let x = v.as(Double.self) { Text(String(format: "$%.2f", x)) } }
                } }
                .chartXAxis { AxisMarks { AxisValueLabel().font(.caption) } }
                .frame(height: 170)

                let ys = shown.filter { $0.yield != nil && !$0.partial }
                if ys.count >= 2 {
                    Text("Yield (dividends ÷ average price that year)").font(.headline).padding(.top, 4)
                    Chart {
                        ForEach(ys, id: \.year) { y in
                            LineMark(x: .value("Year", String(y.year)), y: .value("Yield", y.yield!))
                                .foregroundStyle(Theme.asset).lineStyle(StrokeStyle(lineWidth: 2))
                            PointMark(x: .value("Year", String(y.year)), y: .value("Yield", y.yield!))
                                .foregroundStyle(Theme.asset).symbolSize(30)
                        }
                        if let last = ys.last {
                            PointMark(x: .value("Year", String(last.year)), y: .value("Yield", last.yield!)).opacity(0)
                                .annotation(position: .top) { Text(Fmt.pct(last.yield!, digits: 2)).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    .chartYAxis { AxisMarks(position: .leading) { v in
                        AxisGridLine().foregroundStyle(Theme.grid)
                        AxisValueLabel { if let x = v.as(Double.self) { Text(Fmt.pct(x, digits: 1)) } }
                    } }
                    .chartXAxis { AxisMarks { AxisValueLabel().font(.caption) } }
                    .frame(height: 120)
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }
}
