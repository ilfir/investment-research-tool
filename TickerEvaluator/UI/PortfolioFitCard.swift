import SwiftUI
import Charts

/// "Fit with your portfolio": S&P sleeve vs your floor, allocation after this buy, overlap with what you own,
/// stock count, speculation cap and role. Statuses come from the same P-rules as the scorecard.
struct PortfolioFitCard: View {
    var r: EvaluationReport
    var model: AppModel?

    private static let other = Color.secondary.opacity(0.45)

    var body: some View {
        Card(title: "Fit with your portfolio", subtitle: subtitle) {
            if let f = r.portfolioFit {
                HStack(alignment: .top, spacing: 28) {
                    stat("S&P 500 share after", Fmt.pct(f.spAfter), "floor \(Fmt.pct(f.floor, digits: 0))", rule("P1"))
                    stat("Individual stocks", "\(f.stocksAfter)", "≤ 10, ideally 5–6", rule("P2"))
                    stat("Speculation", Fmt.pct(f.speculationAfter, digits: 2), "≤ 1%", rule("P3"))
                    stat("Overlap with your holdings", f.overlap.map { Fmt.pct($0) } ?? "n/a", "red flag ≥ 70%", rule("P4"))
                    stat("Role", f.role?.rawValue ?? "not set", r.rules.first { $0.id == "P7" }.map { "suits a \($0.actual)?" } ?? "set it in your profile", rule("P7"))
                }
                Divider()
                sleeve(f)
                Divider()
                allocation(f)
                if !f.common.isEmpty, (f.overlap ?? 0) > 0.001 {
                    Divider()
                    Text("Biggest holdings you'd be doubling up on").font(.headline)
                    OverlapBars(ticker: r.ticker, rows: f.common, other: "your portfolio", otherColor: Self.other)
                }
                if let p5 = r.rules.first(where: { $0.id == "P5" }) {
                    Label("No holdings data for \(p5.actual), so overlap may be understated.", systemImage: Theme.icon(.warn))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Add your positions (top bar → Add positions, or import a Fidelity CSV) and a planned amount in your profile to see your S&P 500 share against your floor, overlap with what you already own, your stock count and the 1% speculation cap.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let model {
                    Button("Add positions…") { model.showPositions = true }
                }
            }
        }
    }

    private var subtitle: String {
        guard let f = r.portfolioFit else { return "No positions entered" }
        return "\(Fmt.usd(f.totalBefore)) now" + (f.planned > 0 ? " + \(Fmt.usd(f.planned)) planned in \(r.ticker)" : " · enter a planned amount in your profile to see the effect of buying")
    }

    private func rule(_ id: String) -> RuleStatus? { r.rules.first { $0.id == id }?.status }

    private func stat(_ title: String, _ value: String, _ note: String, _ status: RuleStatus?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                if let status, status != .na { Image(systemName: Theme.icon(status)).foregroundStyle(Theme.color(status)).font(.callout) }
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func sleeve(_ f: PortfolioFit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("S&P 500 share vs your floor (age \(f.age.map(String.init) ?? "not set"))").font(.headline)
            Chart {
                ForEach([("Now", f.spNow), ("After this buy", f.spAfter)], id: \.0) { row in
                    BarMark(x: .value("Share", row.1), y: .value("When", row.0), height: .ratio(0.6))
                        .foregroundStyle(Theme.benchmark)
                        .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4))
                        .annotation(position: .trailing) { Text(Fmt.pct(row.1)).font(.caption).foregroundStyle(.secondary) }
                }
                RuleMark(x: .value("Floor", f.floor))
                    .foregroundStyle(Color.primary.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .annotation(position: .top, alignment: .center) { Text("floor \(Fmt.pct(f.floor, digits: 0))").font(.caption2).foregroundStyle(.secondary) }
            }
            .chartXScale(domain: 0...1)
            .chartXAxis { AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { v in
                AxisGridLine().foregroundStyle(Theme.grid)
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.pct(d, digits: 0)) } }
            } }
            .frame(height: 92)
        }
    }

    private func allocation(_ f: PortfolioFit) -> some View {
        let top = Array(f.allocationAfter.prefix(12))
        let rest = f.allocationAfter.dropFirst(12).map(\.weight).reduce(0, +)
        let rows = top.map { (label: $0.ticker, weight: $0.weight, color: color($0)) } + (rest > 0 ? [(label: "Other (\(f.allocationAfter.count - 12))", weight: rest, color: Self.other)] : [])
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(f.planned > 0 ? "Your allocation after this buy" : "Your allocation").font(.headline)
                Spacer()
                Legend(items: [(r.ticker, Theme.asset), ("S&P 500 trackers", Theme.benchmark), ("Everything else", Self.other)])
            }
            Chart {
                ForEach(rows.indices, id: \.self) { i in
                    BarMark(x: .value("Weight", rows[i].weight), y: .value("Position", rows[i].label), height: .ratio(0.7))
                        .foregroundStyle(rows[i].color)
                        .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4))
                        .annotation(position: .trailing) { Text(Fmt.pct(rows[i].weight)).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks { AxisValueLabel().font(.caption) } }
            .frame(height: CGFloat(rows.count) * 22 + 10)
        }
    }

    private func color(_ a: (ticker: String, weight: Double, kind: PortfolioHolding.Kind, isCandidate: Bool)) -> Color {
        a.isCandidate ? Theme.asset : (a.kind == .spTracker ? Theme.benchmark : Self.other)
    }
}
