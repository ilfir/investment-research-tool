import Foundation

/// A dated value series (e.g. total-return index level).
nonisolated struct Series: Sendable {
    var dates: [Date], values: [Double]
    var isEmpty: Bool { dates.isEmpty }

    /// Last value on or before each month end.
    func monthly() -> Series {
        var d: [Date] = [], v: [Double] = []
        for i in dates.indices {
            let isLastOfMonth = i == dates.count - 1 ||
                Calendar.utc.component(.month, from: dates[i]) != Calendar.utc.component(.month, from: dates[i + 1])
            if isLastOfMonth { d.append(dates[i]); v.append(values[i]) }
        }
        return Series(dates: d, values: v)
    }
    func returns() -> [Double] { zip(values.dropFirst(), values).map { $0 / $1 - 1 } }
    /// Value on or before date (binary search).
    func value(onOrBefore date: Date) -> (Date, Double)? {
        var lo = 0, hi = dates.count - 1, ans = -1
        while lo <= hi { let m = (lo + hi) / 2; if dates[m] <= date { ans = m; lo = m + 1 } else { hi = m - 1 } }
        return ans >= 0 ? (dates[ans], values[ans]) : nil
    }
    func since(_ start: Date) -> Series {
        let i = dates.firstIndex { $0 >= start } ?? dates.count
        return Series(dates: Array(dates[i...]), values: Array(values[i...]))
    }
}

/// Align two series on common dates.
nonisolated func align(_ a: Series, _ b: Series) -> (Series, Series) {
    var bi: [Date: Double] = [:]
    for (d, v) in zip(b.dates, b.values) { bi[d] = v }
    var d: [Date] = [], va: [Double] = [], vb: [Double] = []
    for (date, v) in zip(a.dates, a.values) { if let w = bi[date] { d.append(date); va.append(v); vb.append(w) } }
    return (Series(dates: d, values: va), Series(dates: d, values: vb))
}

nonisolated enum Stats {
    static func mean(_ x: [Double]) -> Double { x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count) }
    static func std(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let m = mean(x); return sqrt(x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count - 1))
    }
    static func cov(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count); guard n > 1 else { return 0 }
        let ma = mean(Array(a.prefix(n))), mb = mean(Array(b.prefix(n)))
        return (0..<n).reduce(0) { $0 + (a[$1] - ma) * (b[$1] - mb) } / Double(n - 1)
    }
    static func corr(_ a: [Double], _ b: [Double]) -> Double {
        let s = std(a) * std(b); return s == 0 ? 0 : cov(a, b) / s
    }
    static func median(_ x: [Double]) -> Double? {
        guard !x.isEmpty else { return nil }; let s = x.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
    static func years(_ a: Date, _ b: Date) -> Double { b.timeIntervalSince(a) / (365.25 * 86_400) }
    static func cagr(start: Double, end: Double, years: Double) -> Double? {
        guard start > 0, end > 0, years > 0 else { return nil }
        return pow(end / start, 1 / years) - 1
    }
}

nonisolated struct Drawdown: Sendable {
    var maxDrawdown: Double            // negative fraction
    var peakDate: Date?, troughDate: Date?, recoveryDate: Date?
    var recoveryDays: Int? { guard let t = troughDate, let r = recoveryDate else { return nil }; return Calendar.utc.dateComponents([.day], from: t, to: r).day }
    var series: Series                 // drawdown at each date (≤ 0)

    static func of(_ s: Series) -> Drawdown {
        var peak = -Double.infinity, peakD: Date?, maxDD = 0.0, pD: Date?, tD: Date?, rD: Date?
        var dd: [Double] = []
        for (d, v) in zip(s.dates, s.values) {
            if v > peak { peak = v; peakD = d }
            let x = v / peak - 1; dd.append(x)
            if x < maxDD { maxDD = x; pD = peakD; tD = d; rD = nil }
        }
        if let t = tD, let p = pD, let pv = s.value(onOrBefore: p)?.1 {
            rD = zip(s.dates, s.values).first { $0.0 > t && $0.1 >= pv }?.0
        }
        return Drawdown(maxDrawdown: maxDD, peakDate: pD, troughDate: tD, recoveryDate: rD, series: Series(dates: s.dates, values: dd))
    }
}

nonisolated struct PeriodReturn: Sendable, Hashable { var label: String; var years: Double?; var asset: Double?; var benchmark: Double? }

nonisolated struct RollingResult: Sendable {
    var windowYears: Int, windows: Int, beatCount: Int
    var beatPct: Double? { windows == 0 ? nil : Double(beatCount) / Double(windows) }
    var averageExcess: Double?        // annualised, asset − benchmark
    var excessSeries: Series          // annualised excess per window end
}

nonisolated struct PerformanceReport: Sendable {
    var assetSymbol: String, benchmarkSymbol: String
    var start: Date, end: Date
    var periods: [PeriodReturn]
    var growthOf10k: (asset: Series, benchmark: Series)
    var drawdown: Drawdown, benchmarkDrawdown: Drawdown
    var riskWindowLabel: String
    var volatility: Double, benchmarkVolatility: Double
    var sharpe: Double?, benchmarkSharpe: Double?
    var beta: Double, correlation: Double
    var upCapture: Double?, downCapture: Double?
    var rolling3: RollingResult, rolling5: RollingResult
    var riskFreeUsed: Double?
}

nonisolated enum PerformanceCalc {
    /// - Parameters: asset/benchmark are total-return index levels (daily).
    static func compute(assetSymbol: String, asset: Series, benchmarkSymbol: String, benchmark: Series, riskFree: RateSeries?) -> PerformanceReport? {
        let (a, b) = align(asset, benchmark)
        guard a.dates.count > 20, let start = a.dates.first, let end = a.dates.last else { return nil }

        // Trailing period returns (annualised for > 1 year).
        var periods: [PeriodReturn] = []
        for y in [1, 3, 5, 10] {
            guard let from = Calendar.utc.date(byAdding: .year, value: -y, to: end), from >= start,
                  let a0 = a.value(onOrBefore: from), let b0 = b.value(onOrBefore: from) else {
                periods.append(PeriodReturn(label: "\(y)y", years: Double(y), asset: nil, benchmark: nil)); continue
            }
            periods.append(PeriodReturn(label: "\(y)y", years: Double(y),
                                        asset: Stats.cagr(start: a0.1, end: a.values.last!, years: Double(y)),
                                        benchmark: Stats.cagr(start: b0.1, end: b.values.last!, years: Double(y))))
        }
        let yrs = Stats.years(start, end)
        periods.append(PeriodReturn(label: "Since \(Fmt.date(start).prefix(4))", years: yrs,
                                    asset: Stats.cagr(start: a.values.first!, end: a.values.last!, years: yrs),
                                    benchmark: Stats.cagr(start: b.values.first!, end: b.values.last!, years: yrs)))

        let g = (Series(dates: a.monthly().dates, values: a.monthly().values.map { $0 / a.values[0] * 10_000 }),
                 Series(dates: b.monthly().dates, values: b.monthly().values.map { $0 / b.values[0] * 10_000 }))

        // Risk stats on up to the last 10 years of monthly returns.
        let riskStart = max(start, Calendar.utc.date(byAdding: .year, value: -10, to: end)!)
        let am = a.since(riskStart).monthly(), bm = b.since(riskStart).monthly()
        let ar = am.returns(), br = bm.returns()
        let rf = riskFree?.average(from: riskStart, to: end)
        func sharpe(_ r: [Double]) -> Double? {
            guard let rf, r.count > 11 else { return nil }
            let ex = r.map { $0 - rf / 12 }; let s = Stats.std(r)
            return s == 0 ? nil : Stats.mean(ex) * 12 / (s * sqrt(12))
        }
        let varB = Stats.std(br) * Stats.std(br)
        let up = zip(ar, br).filter { $0.1 > 0 }, down = zip(ar, br).filter { $0.1 < 0 }
        let upCap = up.isEmpty ? nil : Stats.mean(up.map(\.0)) / Stats.mean(up.map(\.1))
        let downCap = down.isEmpty ? nil : Stats.mean(down.map(\.0)) / Stats.mean(down.map(\.1))

        let dailyA = a.since(riskStart).returns(), dailyB = b.since(riskStart).returns()

        return PerformanceReport(
            assetSymbol: assetSymbol, benchmarkSymbol: benchmarkSymbol, start: start, end: end, periods: periods,
            growthOf10k: g, drawdown: Drawdown.of(a), benchmarkDrawdown: Drawdown.of(b),
            riskWindowLabel: Stats.years(riskStart, end) >= 9.9 ? "last 10 yrs" : "since \(Fmt.date(riskStart))",
            volatility: Stats.std(dailyA) * sqrt(252), benchmarkVolatility: Stats.std(dailyB) * sqrt(252),
            sharpe: sharpe(ar), benchmarkSharpe: sharpe(br),
            beta: varB == 0 ? 0 : Stats.cov(ar, br) / varB, correlation: Stats.corr(ar, br),
            upCapture: upCap, downCapture: downCap,
            rolling3: rolling(a.monthly(), b.monthly(), years: 3), rolling5: rolling(a.monthly(), b.monthly(), years: 5),
            riskFreeUsed: rf)
    }

    static func rolling(_ a: Series, _ b: Series, years: Int) -> RollingResult {
        let n = years * 12
        guard a.values.count > n else { return RollingResult(windowYears: years, windows: 0, beatCount: 0, averageExcess: nil, excessSeries: Series(dates: [], values: [])) }
        var beat = 0, ex: [Double] = [], dates: [Date] = []
        for i in n..<a.values.count {
            let ra = pow(a.values[i] / a.values[i - n], 1 / Double(years)) - 1
            let rb = pow(b.values[i] / b.values[i - n], 1 / Double(years)) - 1
            if ra > rb { beat += 1 }
            ex.append(ra - rb); dates.append(a.dates[i])
        }
        return RollingResult(windowYears: years, windows: ex.count, beatCount: beat, averageExcess: Stats.mean(ex),
                             excessSeries: Series(dates: dates, values: ex))
    }
}

/// Price-action flags (Nash's parabolic rule and "price down, fundamentals intact").
nonisolated struct PriceAction: Sendable {
    var change30d: Double?
    var drawdownFrom52wHigh: Double?
    var high52w: Double?
    var isParabolic: Bool { (change30d ?? 0) >= 0.20 }
    var isDown: Bool { (drawdownFrom52wHigh ?? 0) <= -0.15 }

    static func of(_ s: Series) -> PriceAction {
        guard let end = s.dates.last, let last = s.values.last else { return PriceAction() }
        let ago = Calendar.utc.date(byAdding: .day, value: -30, to: end)!
        let yearAgo = Calendar.utc.date(byAdding: .year, value: -1, to: end)!
        let past = s.value(onOrBefore: ago)?.1
        let hi = s.since(yearAgo).values.max()
        return PriceAction(change30d: past.map { last / $0 - 1 }, drawdownFrom52wHigh: hi.map { last / $0 - 1 }, high52w: hi)
    }
}

nonisolated struct DividendInfo: Sendable {
    struct Year: Sendable, Hashable {
        var year: Int
        var amount: Double            // dividends per share paid in the calendar year
        var yield: Double?            // amount / average close that year
        var payments: Int
        var partial: Bool             // the current year (not complete yet)
    }
    var trailing12mYield: Double?
    var byYear: [(year: Int, amount: Double)]
    var years: [Year] = []
    var paymentsPerYear: Int?
    var source: SourceRef? = nil

    /// Annualised growth of the yearly dividend over the last `n` complete years.
    func growth(years n: Int) -> Double? {
        let full = years.filter { !$0.partial }
        guard full.count > n, let b = full.last?.amount else { return nil }
        let a = full[full.count - 1 - n].amount
        guard a > 0, b > 0 else { return nil }
        return pow(b / a, 1 / Double(n)) - 1
    }

    /// In how many of the last `n` complete years the dividend was raised (vs the year before).
    func raises(lastYears n: Int) -> (raised: Int, of: Int)? {
        let full = years.filter { !$0.partial }.suffix(n + 1)
        guard full.count >= 2 else { return nil }
        let pairs = zip(full.dropLast(), full.dropFirst())
        return (pairs.filter { $1.amount > $0.amount * 1.0001 }.count, full.count - 1)
    }

    static func of(_ h: PriceHistory) -> DividendInfo {
        guard let end = h.lastDate, let px = h.lastClose else { return DividendInfo(byYear: []) }
        let cal = Calendar.utc
        let yearAgo = cal.date(byAdding: .day, value: -365, to: end)!
        let last12 = h.dividends.filter { $0.date > yearAgo }
        var by: [Int: (Double, Int)] = [:]
        for d in h.dividends { let y = cal.component(.year, from: d.date); by[y, default: (0, 0)].0 += d.amount; by[y, default: (0, 0)].1 += 1 }
        var avg: [Int: (Double, Int)] = [:]
        for (d, c) in zip(h.dates, h.close) { let y = cal.component(.year, from: d); avg[y, default: (0, 0)].0 += c; avg[y, default: (0, 0)].1 += 1 }
        let endYear = cal.component(.year, from: end)
        let firstYear = h.dates.first.map { cal.component(.year, from: $0) }
        let years = by.keys.sorted().map { y -> Year in
            let a = avg[y].map { $0.0 / Double($0.1) }
            return Year(year: y, amount: by[y]!.0, yield: a.map { by[y]!.0 / $0 }, payments: by[y]!.1,
                        partial: y == endYear || y == firstYear)   // first year usually starts mid-year too
        }
        return DividendInfo(trailing12mYield: last12.isEmpty ? (h.dividends.isEmpty ? 0 : nil) : last12.map(\.amount).reduce(0, +) / px,
                            byYear: years.map { ($0.year, $0.amount) }, years: years,
                            paymentsPerYear: last12.isEmpty ? nil : last12.count, source: h.source)
    }
}

/// Cost of an expense ratio vs a reference fee on `amount`, at an illustrative gross return.
nonisolated struct FeeDrag: Sendable, Hashable {
    var years: Int, costVsZero: Double, costVsReference: Double
    static let illustrativeReturn = 0.08          // the 8% teaching assumption used in the notes; not a forecast
    static func project(expenseRatio er: Double, referenceRatio ref: Double, amount: Double) -> [FeeDrag] {
        let g = illustrativeReturn
        return [10, 20, 30].map { n in
            let gross = amount * pow(1 + g, Double(n))
            return FeeDrag(years: n, costVsZero: gross - amount * pow(1 + g - er, Double(n)),
                           costVsReference: amount * pow(1 + g - ref, Double(n)) - amount * pow(1 + g - er, Double(n)))
        }
    }
}
