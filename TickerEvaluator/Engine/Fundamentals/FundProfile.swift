import Foundation

/// Everything we know about a fund, with each number sourced. Optional = not available keyless.
nonisolated struct FundProfile: Sendable {
    var name: String?
    var family: String?
    var category: String?
    var legalType: String?
    var objective: String?                 // Yahoo assetProfile longBusinessSummary (fund description)
    var inceptionDate: Date?
    var expenseRatio: CrossCheck
    var netAssets: CrossCheck
    var holdingsCount: DataPoint?
    var turnover: CrossCheck
    var frontLoad: DataPoint?, deferredLoad: DataPoint?, twelveB1: DataPoint?
    var minInvestment: DataPoint?
    var managerName: String?, managerStart: Date?
    var averageVolume: DataPoint?
    var bidAskSpread: DataPoint?
    var distributionYield: DataPoint?
    var secYield: DataPoint?               // not available keyless → nil
    var duration: DataPoint?
    var creditQuality: String?
    var assetMix: (stock: Double?, bond: Double?, cash: Double?)
    var sectors: [(name: String, weight: Double)]
    var top10: [(name: String, symbol: String?, weight: Double)]
    var top10Source: SourceRef?
    var nport: NPortReport?
    var notes: [String] = []
}

nonisolated enum FundProfileBuilder {
    static func build(ticker: String, cls: SECFundClass?, ncsr: (facts: [XBRLFact], source: SourceRef)?,
                      prospectus: (facts: [XBRLFact], source: SourceRef)?, nport: NPortReport?,
                      yahoo: [String: [String: Any]]?, yahooSource: SourceRef?, history: PriceHistory?) -> FundProfile {
        let fp = yahoo?["fundProfile"] ?? [:], sd = yahoo?["summaryDetail"] ?? [:], ks = yahoo?["defaultKeyStatistics"] ?? [:]
        let th = yahoo?["topHoldings"] ?? [:], ap = yahoo?["assetProfile"] ?? [:], qt = yahoo?["quoteType"] ?? [:]
        let fees = fp.dict("feesExpensesInvestment") ?? [:]
        func y(_ key: String, _ label: String, _ v: Double?, _ unit: Unit) -> DataPoint? {
            guard let v, let yahooSource else { return nil }
            return DataPoint(key: key, label: label, value: v, unit: unit, source: yahooSource)
        }
        /// Latest fact for this share class (or fund-level if no class member) from an SEC XBRL instance.
        func sec(_ facts: (facts: [XBRLFact], source: SourceRef)?, _ names: [String], key: String, label: String, unit: Unit, divide: Double = 1) -> DataPoint? {
            guard let facts else { return nil }
            let match = facts.facts.filter { f in names.contains { f.name.hasSuffix(":" + $0) } && f.otherDims.isEmpty && f.number != nil }
            let forClass = match.filter { $0.classMember == cls?.classId }
            let pick = (forClass.isEmpty ? match.filter { $0.classMember == nil } : forClass)
                .max { ($0.end ?? $0.instant ?? "") < ($1.end ?? $1.instant ?? "") }
            guard let p = pick, let n = p.number else { return nil }
            var src = facts.source; src.asOf = DateParse.ymd(p.end ?? p.instant) ?? src.asOf
            return DataPoint(key: key, label: label, value: n / divide, unit: unit, source: src)
        }

        let erSEC = sec(ncsr, ["ExpenseRatioPct"], key: "expenseRatio", label: "Expense ratio", unit: .percent)
            ?? sec(prospectus, ["ExpensesOverAssets"], key: "expenseRatio", label: "Expense ratio (prospectus)", unit: .percent)
        let erY = y("expenseRatio", "Expense ratio", fees.raw("annualReportExpenseRatio") ?? ks.raw("annualReportExpenseRatio") ?? sd.raw("expenseRatio").map { $0 / 100 }, .percent)

        var naSEC = sec(ncsr, ["AssetsNet"], key: "netAssets", label: "Fund net assets", unit: .usd)
        if naSEC == nil, let nport, nport.netAssets > 0 {
            naSEC = DataPoint(key: "netAssets", label: "Fund net assets", value: nport.netAssets, unit: .usd, source: nport.source)
        }
        let naY = y("netAssets", "Fund net assets", sd.raw("totalAssets") ?? ks.raw("totalAssets"), .usd)

        let toSEC = sec(ncsr, ["InvestmentCompanyPortfolioTurnover"], key: "turnover", label: "Portfolio turnover", unit: .percent)
            ?? sec(prospectus, ["PortfolioTurnoverRate"], key: "turnover", label: "Portfolio turnover", unit: .percent)
        let toY = y("turnover", "Portfolio turnover", fees.raw("annualHoldingsTurnover"), .percent)

        var p = FundProfile(
            name: qt.str("longName") ?? history?.longName, family: fp.str("family"), category: fp.str("categoryName") ?? ks.str("category"),
            legalType: fp.str("legalType"), objective: ap.str("longBusinessSummary"),
            inceptionDate: ks.raw("fundInceptionDate").map { Date(timeIntervalSince1970: $0) } ?? history?.firstTradeDate,
            // Net assets: SEC is fund-level (all share classes) and Yahoo may be class-level → definitions can differ.
            expenseRatio: CrossCheck.compare("Expense ratio", key: "expenseRatio", erSEC, erY, tolerance: 0.10),
            netAssets: CrossCheck.compare("Net assets", key: "netAssets", naSEC, naY, tolerance: 0.15, definitionsDiffer: true),
            holdingsCount: sec(ncsr, ["HoldingsCount"], key: "holdingsCount", label: "Number of holdings", unit: .count)
                ?? nport.map { DataPoint(key: "holdingsCount", label: "Number of holdings", value: Double($0.holdings.count), unit: .count, source: $0.source) },
            turnover: CrossCheck.compare("Turnover", key: "turnover", toSEC, toY, tolerance: 0.25, definitionsDiffer: true),
            frontLoad: sec(prospectus, ["MaximumSalesChargeImposedOnPurchasesOverOfferingPrice"], key: "frontLoad", label: "Front-end load", unit: .percent)
                ?? y("frontLoad", "Front-end load", fees.raw("frontEndSalesLoad"), .percent),
            deferredLoad: sec(prospectus, ["MaximumDeferredSalesChargeOverOther", "MaximumDeferredSalesChargeOverOfferingPrice"], key: "deferredLoad", label: "Deferred load", unit: .percent)
                ?? y("deferredLoad", "Deferred load", fees.raw("deferredSalesLoad"), .percent),
            twelveB1: sec(prospectus, ["DistributionAndService12b1FeesOverAssets"], key: "12b1", label: "12b-1 fee", unit: .percent)
                ?? y("12b1", "12b-1 fee", fees.raw("twelveBOne"), .percent),
            minInvestment: y("minInvestment", "Minimum initial investment", fp.raw("initInvestment"), .usd),
            managerName: fp.dict("managementInfo")?.str("managerName"),
            managerStart: fp.dict("managementInfo")?.dict("startdate")?.num("raw").map { Date(timeIntervalSince1970: $0) },
            averageVolume: y("avgVolume", "Average daily volume (shares)", sd.raw("averageVolume"), .count),
            bidAskSpread: nil, distributionYield: nil, secYield: nil,
            duration: nil, creditQuality: nil,
            assetMix: (th.raw("stockPosition"), th.raw("bondPosition"), th.raw("cashPosition")),
            sectors: [], top10: [], top10Source: yahooSource, nport: nport)

        if let bid = sd.raw("bid"), let ask = sd.raw("ask"), bid > 0, ask > bid {
            p.bidAskSpread = y("spread", "Bid/ask spread", (ask - bid) / ((ask + bid) / 2), .percent)
            p.bidAskSpread?.note = "Snapshot at fetch time; outside market hours it can be stale or wide."
        }
        if let history {
            let d = DividendInfo.of(history)
            if let ty = d.trailing12mYield {
                p.distributionYield = DataPoint(key: "distYield", label: "Distribution yield (trailing 12m)", value: ty, unit: .percent, source: history.source)
            }
        }
        if let bh = th.dict("bondHoldings"), let dur = bh.raw("duration") {
            p.duration = y("duration", "Average duration", dur, .years)
        }
        if let ratings = th.arr("bondRatings") as? [[String: Any]] {
            p.creditQuality = averageRating(ratings)
        }
        if let sw = th.arr("sectorWeightings") as? [[String: Any]] {
            p.sectors = sw.compactMap { d in d.first.flatMap { k, v in (v as? [String: Any])?.num("raw").map { (sectorName(k), $0) } } }
                .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        }
        if let hs = th.arr("holdings") as? [[String: Any]] {
            p.top10 = hs.prefix(10).map { ($0.str("holdingName") ?? $0.str("symbol") ?? "?", $0.str("symbol"), $0.raw("holdingPercent") ?? 0) }
        }
        if p.top10.isEmpty, let nport {
            let e = Exposure.of(holdings: nport.holdings)
            p.top10 = e.top(10).map { ($0.name, nil, $0.weight) }; p.top10Source = nport.source
        }
        return p
    }

    static func sectorName(_ k: String) -> String {
        ["realestate": "Real estate", "consumer_cyclical": "Consumer cyclical", "basic_materials": "Basic materials",
         "consumer_defensive": "Consumer defensive", "technology": "Technology", "communication_services": "Communication services",
         "financial_services": "Financial services", "utilities": "Utilities", "industrials": "Industrials",
         "energy": "Energy", "healthcare": "Healthcare"][k] ?? k
    }

    /// Weighted average credit rating from Yahoo bondRatings (e.g. [{"aaa": {raw}}, {"bb": {raw}}]).
    static func averageRating(_ ratings: [[String: Any]]) -> String? {
        let scale = ["us_government": 1.0, "aaa": 1, "aa": 2, "a": 3, "bbb": 4, "bb": 5, "b": 6, "below_b": 7, "other": 7]
        var tot = 0.0, w = 0.0
        for r in ratings { for (k, v) in r { if let s = scale[k], let x = (v as? [String: Any])?.num("raw"), x > 0 { tot += s * x; w += x } } }
        guard w > 0 else { return nil }
        return ["AAA", "AA", "A", "BBB", "BB", "B", "Below B"][min(6, max(0, Int((tot / w).rounded()) - 1))]
    }
}
