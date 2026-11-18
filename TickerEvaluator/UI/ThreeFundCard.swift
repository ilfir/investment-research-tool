import SwiftUI
import Charts

/// Nash's "no-research" three-fund portfolio (S&P 500 + Nasdaq + total US bond) for your age, next to your mix.
/// Reference only: it never changes the verdict.
struct ThreeFundCard: View {
    var r: EvaluationReport

    // Categorical slots 2–4 (validated; slot 1 blue stays reserved for the ticker). Light slots 3–4 are under 3:1
    // contrast, so every segment is also labelled with its name and percentage.
    static let colors: [ThreeFund.Sleeve: Color] = [
        .sp: Theme.benchmark, .nasdaq: Theme.dynamic(0x1baf7a, 0x199e70),
        .bonds: Theme.dynamic(0xeda100, 0xc98500), .other: Color.secondary.opacity(0.35),
    ]

    private var age: Int? { r.request.profile.age }

    var body: some View {
        let ref = ThreeFund.reference(age: age)
        Card(title: "Nash's no-research three-fund portfolio",
             subtitle: "S&P 500 + Nasdaq + total US bond index, by age. A reference mix for comparison only; it doesn't change the verdict.") {
            if let ref {
                let mine = r.portfolioFit.map(ThreeFund.actual)
                Chart {
                    ForEach(segments(ref, mine), id: \.id) { s in
                        // xStart/xEnd with a small inset leaves a surface gap between stacked segments.
                        BarMark(xStart: .value("From", s.start), xEnd: .value("To", max(s.start, s.start + s.value - 0.003)),
                                y: .value("Mix", s.row), height: .ratio(0.62))
                            .foregroundStyle(Self.colors[s.sleeve]!)
                            .annotation(position: .overlay) {
                                if s.value >= 0.07 {
                                    Text("\(s.sleeve == .other ? "Other" : s.sleeve.rawValue) \(Fmt.pct(s.value, digits: 0))")
                                        .font(.caption2.weight(.semibold)).foregroundStyle(Color.black.opacity(0.8)).lineLimit(1)
                                }
                            }
                    }
                }
                .chartXScale(domain: 0...1.0001)
                .chartXAxis { AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { v in
                    AxisGridLine().foregroundStyle(Theme.grid)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.pct(d, digits: 0)) } }
                } }
                .chartLegend(.hidden)
                .frame(height: mine == nil ? 60 : 104)
                Legend(items: ThreeFund.Sleeve.allCases.map { ($0.rawValue, Self.colors[$0]!) })
                if let mine { drift(ref, mine) }
                else { Text("Add your positions to compare your own mix with this reference.").font(.callout).foregroundStyle(.secondary) }
            } else {
                Text("Enter your age in your profile to see the mix for your age.").font(.callout).foregroundStyle(.secondary)
            }
            table(highlight: ref)
            Text("From your notes (\"learn to evaluate stocks like a pro\"). The bands overlap at 30, 40 and 50 in the source; read here as up to 30, 31–39, 40–49, 50–59, 60+.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    struct Segment { var id: String; var row: String; var sleeve: ThreeFund.Sleeve; var value: Double; var start = 0.0 }

    private func segments(_ ref: ThreeFund.Mix, _ mine: [ThreeFund.Sleeve: Double]?) -> [Segment] {
        let refRow = "Reference (\(ref.band))"
        var out = [(ThreeFund.Sleeve.sp, ref.sp), (.nasdaq, ref.nasdaq), (.bonds, ref.bonds)]
            .map { Segment(id: "r\($0.0)", row: refRow, sleeve: $0.0, value: $0.1) }
        if let mine {
            out += ThreeFund.Sleeve.allCases.compactMap { s in
                (mine[s] ?? 0) > 0 ? Segment(id: "m\(s)", row: r.portfolioFit!.planned > 0 ? "You, after this buy" : "You now", sleeve: s, value: mine[s]!) : nil
            }
        }
        var cum: [String: Double] = [:]
        for i in out.indices { out[i].start = cum[out[i].row, default: 0]; cum[out[i].row, default: 0] += out[i].value }
        return out
    }

    private func drift(_ ref: ThreeFund.Mix, _ mine: [ThreeFund.Sleeve: Double]) -> some View {
        let rows: [(String, Double, Double)] = [("S&P 500", mine[.sp] ?? 0, ref.sp), ("Nasdaq", mine[.nasdaq] ?? 0, ref.nasdaq), ("Bonds", mine[.bonds] ?? 0, ref.bonds)]
        return HStack(spacing: 24) {
            ForEach(rows, id: \.0) { name, a, b in
                let d = a - b
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                    Text("\(Fmt.pct(a, digits: 0)) vs \(Fmt.pct(b, digits: 0))").font(.callout.weight(.semibold)).monospacedDigit()
                    Text(abs(d) < 0.05 ? "on target" : "\(d > 0 ? "+" : "−")\(Fmt.pct(abs(d), digits: 0)) \(d > 0 ? "over" : "under")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let o = mine[.other], o > 0.005 {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Everything else").font(.caption).foregroundStyle(.secondary)
                    Text(Fmt.pct(o, digits: 0)).font(.callout.weight(.semibold)).monospacedDigit()
                    Text("stocks, other funds, speculation").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func table(highlight: ThreeFund.Mix?) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 4) {
            GridRow { ForEach(["Age", "S&P 500", "Nasdaq", "Bonds"], id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) } }
            ForEach(ThreeFund.table, id: \.band) { m in
                let mine = m == highlight
                GridRow {
                    Text(m.band + (mine ? "  ← you" : ""))
                    Text(Fmt.pct(m.sp, digits: 0)); Text(Fmt.pct(m.nasdaq, digits: 0)); Text(Fmt.pct(m.bonds, digits: 0))
                }
                .font(.callout.weight(mine ? .semibold : .regular)).monospacedDigit()
            }
        }
    }
}
