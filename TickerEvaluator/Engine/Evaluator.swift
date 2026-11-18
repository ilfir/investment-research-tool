import Foundation

/// Everything the report screen (or Markdown export) needs.
nonisolated struct EvaluationReport: Sendable {
    var ticker: String
    var name: String
    var assetType: AssetType
    var classificationNote: String
    var request: EvaluationRequest
    var verdict: VerdictResult
    var rules: [RuleResult]
    var performance: PerformanceReport?
    var performanceVsBND: PerformanceReport?
    var priceAction: PriceAction
    var dividends: DividendInfo?
    var feeDrag: [FeeDrag]
    var fundamentals: CompanyFundamentals?
    var fund: FundProfile?
    var overlapWithSP: Double?
    var overlapCommonWithSP: [(name: String, a: Double, b: Double)]
    var portfolio: PortfolioContext?
    var portfolioFit: PortfolioFit? = nil
    var checks: [CrossCheck]
    var dataPoints: [DataPoint]
    var sources: [SourceRef]
    var missing: [String]
    var stale: [String]
    var generatedAt: Date
}

nonisolated struct StalenessLimits: Sendable {
    var priceDays = 7, fundamentalsDays = 150, holdingsDays = 270, feesDays = 400
}

struct Evaluator: Sendable {
    let http: HTTPClient
    let store: Store?
    var limits = StalenessLimits()

    var yahoo: YahooClient { YahooClient(http: http) }
    var sec: SECClient { SECClient(http: http) }
    var rates: RatesClient { RatesClient(http: http) }

    static let spSeries = (cik: 36405, seriesId: "S000002839", classId: "C000092055")   // Vanguard 500 Index (VOO)

    func evaluate(_ req: EvaluationRequest, progress: (@Sendable (String) -> Void)? = nil) async throws -> EvaluationReport {
        let ticker = req.ticker.uppercased().trimmingCharacters(in: .whitespaces)
        var missing: [String] = [], sources: [SourceRef] = [], checks: [CrossCheck] = []
        progress?("Prices for \(ticker) and the S&P 500 total return index…")

        async let assetChartT = yahoo.chart(ticker, asOf: req.asOf)
        async let spChartT = yahoo.chart("^SP500TR", asOf: req.asOf)
        async let fredT = try? rates.fred3Month()
        async let tsyT = try? rates.treasury3Month(year: Calendar.utc.component(.year, from: req.asOf))
        let history = try await assetChartT
        sources.append(history.source)
        var benchmark: Series
        var benchName = "S&P 500 TR (^SP500TR)"
        if let sp = try? await spChartT {
            benchmark = Series(dates: sp.dates, values: sp.close); sources.append(sp.source)
        } else {
            let voo = try await yahoo.chart("VOO", asOf: req.asOf)
            benchmark = Series(dates: voo.dates, values: voo.adjClose); benchName = "VOO (dividends reinvested)"
            sources.append(voo.source); missing.append("^SP500TR unavailable: VOO adjusted prices used as the benchmark")
        }
        let fred = await fredT, tsy = await tsyT
        if let fred { sources.append(fred.source) } else { missing.append("FRED risk-free rate") }
        if let tsy { sources.append(tsy.source) }
        if let fl = fred?.latest, let fredDate = fred?.dates.last {
            var s = fred!.source; s.asOf = fredDate
            checks.append(CrossCheck.compare("Risk-free rate (3-month T-bill)", key: "riskFree",
                                             DataPoint(key: "riskFree", label: "3-month T-bill", value: fl, unit: .percent, source: s), tsy, tolerance: 0.05))
        }

        progress?("Profile and classification…")
        let summary = try? await yahoo.quoteSummary(ticker)
        if let summary { sources.append(summary.source) } else { missing.append("Yahoo quoteSummary (fund profile, second-source fundamentals)") }
        let companies = (try? await sec.companies()) ?? [:]
        let fundClasses = (try? await sec.fundClasses()) ?? [:]
        let company = companies[ticker], fundClass = fundClasses[ticker]
        var subs: SECSubmissions?
        if let cik = fundClass?.cik ?? company?.cik { subs = try? await sec.submissions(cik: cik); if let s = subs?.source { sources.append(s) } }

        let (type, note) = Classifier.classify(ticker: ticker, history: history, yahoo: summary?.modules, company: company,
                                               fundClass: fundClass, sic: subs?.sic)
        let name = history.longName ?? company?.title ?? ticker

        // Performance vs S&P 500 (total return)
        var assetSeries = Series(dates: history.dates, values: history.adjClose)
        if type == .crypto, let coin = CoinGeckoClient.ids[ticker.replacingOccurrences(of: "-USD", with: "")] {
            let cg = CoinGeckoClient(http: http)
            if let pts = try? await cg.dailyPrices(coinId: coin), let last = pts.last, let ylast = history.lastClose {
                let src = SourceRef(name: "CoinGecko (keyless)", url: cg.sourceURL(coinId: coin), asOf: last.0, fetchedAt: .now)
                checks.append(CrossCheck.compare("Latest price", key: "price",
                                                 DataPoint(key: "price", label: "Price", value: ylast, unit: .usd, source: history.source),
                                                 DataPoint(key: "price", label: "Price", value: last.1, unit: .usd, source: src), tolerance: 0.03))
                sources.append(src)
            }
            // Crypto trades 7 days a week; align to benchmark trading days.
            assetSeries = Series(dates: history.dates, values: history.close)
        }
        progress?("Return, drawdown and risk statistics…")
        let perf = PerformanceCalc.compute(assetSymbol: ticker, asset: assetSeries, benchmarkSymbol: benchName, benchmark: benchmark, riskFree: fred)
        if perf == nil { missing.append("Not enough overlapping price history for the S&P comparison") }
        let priceAction = PriceAction.of(Series(dates: history.dates, values: history.close))
        let dividends = DividendInfo.of(history)

        var rules: [RuleResult] = []
        var fundamentals: CompanyFundamentals?
        var fund: FundProfile?
        var overlapSP: Double?, commonSP: [(name: String, a: Double, b: Double)] = []
        var candidateExposure: Exposure?
        var isSPTracker = PortfolioRules.spTrackers.contains(ticker)
        var feeDrag: [FeeDrag] = []
        var perfBND: PerformanceReport?
        var fundamentalsIntact: Bool?

        switch type {
        case .stock:
            progress?("SEC financial statements…")
            if let company, let cf = try? await sec.companyFacts(cik: company.cik) {
                sources.append(cf.source)
                let f = FundamentalsExtractor.extract(facts: cf.facts, source: cf.source)
                fundamentals = f
                let spPE: DataPoint? = await {
                    guard let s = try? await yahoo.quoteSummary("VOO"), let pe = s.modules["summaryDetail"]?.raw("trailingPE") else { return nil }
                    return DataPoint(key: "spPE", label: "S&P 500 trailing P/E (VOO)", value: pe, unit: .multiple, source: s.source)
                }()
                rules += StockRules.evaluate(.init(f: f, price: history.lastClose, priceHistory: Series(dates: history.dates, values: history.close),
                                                   judgements: req.judgements, spPE: spPE))
                checks += stockCrossChecks(f, yahoo: summary)
                let numeric = rules.filter { ["S1", "S2", "S3", "S4"].contains($0.id) }
                fundamentalsIntact = numeric.allSatisfy { $0.status == .pass }
            } else {
                missing.append("SEC companyfacts for \(ticker) (no CIK match)")
            }
            candidateExposure = Exposure.single(name: company?.title ?? name)

        case .etf, .mutualFund, .bondFund, .cryptoETF, .leveragedOrInverse:
            progress?("SEC fund filings (shareholder report, prospectus, N-PORT holdings)…")
            var ncsr: (facts: [XBRLFact], source: SourceRef)?, prosp: (facts: [XBRLFact], source: SourceRef)?, nport: NPortReport?
            if let fc = fundClass, let subs {
                if let f = try? await sec.latestFiling(cik: fc.cik, forms: ["N-CSR", "N-CSRS"], containing: fc.classId, in: subs) {
                    ncsr = try? await sec.xbrlFacts(cik: fc.cik, filing: f)
                }
                if let f = try? await sec.latestFiling(cik: fc.cik, forms: ["485BPOS", "497K"], containing: fc.classId, in: subs, maxScan: 25) {
                    prosp = try? await sec.xbrlFacts(cik: fc.cik, filing: f)
                }
                nport = try? await sec.nport(cik: fc.cik, seriesId: fc.seriesId, subs: subs)
            }
            if ncsr == nil { missing.append("SEC shareholder report (N-CSR) XBRL for this share class") } else { sources.append(ncsr!.source) }
            if let prosp { sources.append(prosp.source) }
            if nport == nil { missing.append("SEC N-PORT holdings") } else { sources.append(nport!.source) }

            let profile = FundProfileBuilder.build(ticker: ticker, cls: fundClass, ncsr: ncsr, prospectus: prosp, nport: nport,
                                                   yahoo: summary?.modules, yahooSource: summary?.source, history: history)
            fund = profile
            checks += [profile.expenseRatio, profile.netAssets, profile.turnover]

            if history.instrumentType == "MUTUALFUND" {
                progress?("Manager tenure and taxable distributions…")
                let voo = try? await yahoo.chart("VOO", asOf: req.asOf)
                rules += MutualFundRules.evaluate(management: summary?.modules["fundProfile"]?.dict("managementInfo"), managementSource: summary?.source,
                                                  history: history, vooYield: voo.flatMap { DividendInfo.of($0).trailing12mYield },
                                                  account: req.profile.accountType, asOf: req.asOf)
            }
            if type == .cryptoETF {
                progress?("Custodian (SEC annual report)…")
                if let company, let subs, let c = try? await sec.cryptoCustodian(cik: company.cik, subs: subs) {
                    sources.append(c.source)
                    rules.append(RuleResult(id: "K1", group: .crypto, title: "Custodian (who holds the coins)", status: .na,
                                            actual: c.name, threshold: "a regulated, named custodian", weight: .info,
                                            evidence: [DataPoint(key: "custodianMentions", label: "Mentions in \(c.source.name)", value: Double(c.mentions), unit: .count, source: c.source)],
                                            detail: "The custodian the trust's latest SEC filing names as \"Custodian\". Check the prospectus for cold-storage and insurance terms."))
                } else {
                    rules.append(RuleResult(id: "K1", group: .crypto, title: "Custodian (who holds the coins)", status: .na,
                                            actual: "not found in SEC filings", threshold: "check the prospectus", weight: .info))
                }
            }

            // Overlap with VOO
            let spNport: NPortReport? = ticker == "VOO" ? nport : await {
                guard let s = try? await sec.submissions(cik: Self.spSeries.cik) else { return nil }
                return try? await sec.nport(cik: Self.spSeries.cik, seriesId: Self.spSeries.seriesId, subs: s)
            }()
            if let nport, let spNport {
                let a = Exposure.of(holdings: nport.holdings).normalised(), b = Exposure.of(holdings: spNport.holdings).normalised()
                candidateExposure = a
                overlapSP = OverlapCalc.overlap(a, b)
                commonSP = OverlapCalc.common(a, b)
                if (overlapSP ?? 0) >= 0.95 { isSPTracker = true }
            }
            let vooER = 0.0003
            if let er = (profile.expenseRatio.primary ?? profile.expenseRatio.secondary)?.value {
                feeDrag = FeeDrag.project(expenseRatio: er, referenceRatio: vooER, amount: req.profile.plannedAmount ?? 10_000)
            }
            if type == .bondFund, let bnd = try? await yahoo.chart("BND", asOf: req.asOf) {
                perfBND = PerformanceCalc.compute(assetSymbol: ticker, asset: assetSeries, benchmarkSymbol: "BND (total US bond)",
                                                  benchmark: Series(dates: bnd.dates, values: bnd.adjClose), riskFree: fred)
                sources.append(bnd.source)
            }
            rules += FundRules.evaluate(.init(type: type, profile: profile, overlapWithSP: overlapSP, vooExpenseRatio: vooER,
                                              isSPTracker: isSPTracker, perf: perf, perfVsBND: perfBND,
                                              isMutualFund: history.instrumentType == "MUTUALFUND", history: history))
            fundamentalsIntact = rules.filter { $0.weight != .info }.allSatisfy { $0.status != .fail }
            if type == .leveragedOrInverse {
                rules.append(RuleResult(id: "R1", group: .redFlag, title: "Leveraged or inverse structure", status: .fail,
                                        actual: profile.name ?? ticker, threshold: "not a long-term holding", weight: .hard))
            }

        case .crypto:
            rules.append(RuleResult(id: "C1", group: .crypto, title: "Fundamentals", status: .na, actual: "none (no cash flows)", threshold: "—", weight: .info))
        case .reit:
            rules.append(RuleResult(id: "R0", group: .fund, title: "REIT fundamentals", status: .na, actual: "not evaluated (your choice)", threshold: "—", weight: .info))
        case .unknown:
            missing.append("Could not classify \(ticker)")
        }

        if let perf, type.isSpeculation || type == .crypto {
            rules.append(RuleResult(id: "C2", group: .crypto, title: "Volatility vs S&P 500", status: .na,
                                    actual: "\(Fmt.pct(perf.volatility)) vs \(Fmt.pct(perf.benchmarkVolatility))", threshold: "info", weight: .info))
            rules.append(RuleResult(id: "C3", group: .crypto, title: "Max drawdown", status: .na, actual: Fmt.pct(perf.drawdown.maxDrawdown), threshold: "info", weight: .info))
            rules.append(RuleResult(id: "C4", group: .crypto, title: "Correlation with S&P 500 (monthly)", status: .na, actual: String(format: "%.2f", perf.correlation), threshold: "info", weight: .info))
        }

        rules += PriceRules.evaluate(priceAction, fundamentalsIntact: fundamentalsIntact, source: history.source)

        progress?("Your portfolio…")
        let context = await portfolioContext(req.positions, companies: companies, fundClasses: fundClasses, asOf: req.asOf)
        rules += PortfolioRules.evaluate(ticker: ticker, type: type, isSPTracker: isSPTracker, candidate: candidateExposure, request: req,
                                         context: context, maxDrawdown: perf?.drawdown.maxDrawdown)
        let fit = PortfolioFit.make(ticker: ticker, type: type, isSPTracker: isSPTracker, candidate: candidateExposure, request: req, context: context)

        // Staleness
        var stale: [String] = []
        func age(_ d: Date?) -> Int? { d.map { Calendar.utc.dateComponents([.day], from: $0, to: req.asOf).day ?? 0 } }
        if let a = age(history.lastDate), a > limits.priceDays { stale.append("Prices last updated \(Fmt.date(history.lastDate)) (\(a) days old)") }
        if let a = age(fundamentals?.balance?.date), a > limits.fundamentalsDays { stale.append("Balance sheet as of \(Fmt.date(fundamentals?.balance?.date)) (\(a) days old)") }
        if let n = fund?.nport, let a = age(DateParse.ymd(n.periodDate)), a > limits.holdingsDays { stale.append("Holdings as of \(n.periodDate) (\(a) days old)") }
        if let er = fund?.expenseRatio.primary, let a = age(er.source.asOf), a > limits.feesDays { stale.append("Expense ratio as of \(Fmt.date(er.source.asOf)) (\(a) days old)") }

        let verdict = VerdictEngine.decide(type: type, rules: rules, isSPTracker: isSPTracker, priceAction: priceAction, checks: checks, staleCount: stale.count)

        var points = rules.flatMap(\.evidence)
        points += checks.flatMap { [$0.primary, $0.secondary].compactMap { $0 } }
        if let store { await store.save(points, ticker: ticker) }

        var seen = Set<String>()
        let uniqueSources = sources.filter { seen.insert($0.url).inserted }
        return EvaluationReport(ticker: ticker, name: name, assetType: type, classificationNote: note, request: req, verdict: verdict,
                                rules: rules, performance: perf, performanceVsBND: perfBND, priceAction: priceAction, dividends: dividends,
                                feeDrag: feeDrag, fundamentals: fundamentals, fund: fund, overlapWithSP: overlapSP, overlapCommonWithSP: commonSP,
                                portfolio: context, portfolioFit: fit, checks: checks, dataPoints: points, sources: uniqueSources, missing: missing, stale: stale,
                                generatedAt: .now)
    }

    /// Second-source checks for stock fundamentals (Yahoo financialData vs SEC).
    func stockCrossChecks(_ f: CompanyFundamentals, yahoo: (modules: [String: [String: Any]], source: SourceRef)?) -> [CrossCheck] {
        let fd = yahoo?.modules["financialData"] ?? [:], ks = yahoo?.modules["defaultKeyStatistics"] ?? [:]
        func y(_ k: String, _ label: String, _ v: Double?, _ u: Unit) -> DataPoint? { v.flatMap { v in yahoo.map { DataPoint(key: k, label: label, value: v, unit: u, source: $0.source) } } }
        func s(_ k: String, _ label: String, _ v: Double?, _ u: Unit, _ d: Date?) -> DataPoint? {
            v.map { var src = f.source; src.asOf = d; return DataPoint(key: k, label: label, value: $0, unit: u, source: src) }
        }
        let bs = f.balance
        return [
            CrossCheck.compare("Cash + short-term investments", key: "cash", s("cash", "Cash + ST investments", bs?.totalCash, .usd, bs?.date), y("cash", "Total cash", fd.raw("totalCash"), .usd), tolerance: 0.05),
            CrossCheck.compare("Debt (excl. operating leases)", key: "debt", s("debt", "Debt excl. leases", bs?.debtExLeases, .usd, bs?.date), y("debt", "Total debt", fd.raw("totalDebt"), .usd), tolerance: 0.10, definitionsDiffer: true),
            CrossCheck.compare("Operating margin", key: "opMargin", s("opMargin", "Operating margin (latest FY)", f.latest?.operatingMargin, .percent, f.latest?.end), y("opMargin", "Operating margin (TTM)", fd.raw("operatingMargins"), .percent), tolerance: 0.10, definitionsDiffer: true),
            CrossCheck.compare("Shares outstanding", key: "shares", s("shares", "Shares outstanding", bs?.sharesOutstanding, .shares, bs?.date), y("shares", "Shares outstanding", ks.raw("sharesOutstanding"), .shares), tolerance: 0.03),
            CrossCheck.compare("Free cash flow", key: "fcf", s("fcf", "Free cash flow (latest FY)", f.latest?.freeCashFlow, .usd, f.latest?.end), y("fcf", "Free cash flow (TTM, levered)", fd.raw("freeCashflow"), .usd), tolerance: 0.15, definitionsDiffer: true),
        ]
    }

    /// Values, look-through exposure and counts for your saved positions.
    func portfolioContext(_ positions: [Position], companies: [String: SECCompany], fundClasses: [String: SECFundClass], asOf: Date) async -> PortfolioContext? {
        guard !positions.isEmpty else { return nil }
        var total = 0.0, sp = 0.0, spec = 0.0, stocks = Set<String>(), unresolved: [String] = []
        var exposure = Exposure()
        var valued: [(Position, Double, PriceHistory?)] = []
        for p in positions {
            let t = p.ticker.uppercased()
            let h = try? await yahoo.chart(t, asOf: asOf)
            // Shares × latest close keeps an old import current; the entered/imported value is the fallback.
            let live = (p.shares ?? 0) * (h?.lastClose ?? 0)
            let value = live > 0 ? live : (p.amount ?? 0)
            if value <= 0 { unresolved.append("\(t) (no value)"); continue }
            valued.append((p, value, h)); total += value
        }
        var holdings: [PortfolioHolding] = []
        for (p, value, h) in valued {
            let t = p.ticker.uppercased()
            let inst = h?.instrumentType ?? ""
            var kind: PortfolioHolding.Kind = .unknown
            if PortfolioRules.spTrackers.contains(t) { sp += value; kind = .spTracker }
            let isSpec = inst == "CRYPTOCURRENCY" || t.hasSuffix("-USD") || Classifier.looksLeveraged(h?.longName ?? "") || Classifier.looksCrypto(h?.longName ?? "")
            if isSpec { spec += value; kind = .speculation }
            if inst == "EQUITY", let c = companies[t] {
                stocks.insert(t); if kind == .unknown { kind = .stock }
                exposure.add(.single(name: c.title), scale: value / total)
            } else if let fc = fundClasses[t], let subs = try? await sec.submissions(cik: fc.cik),
                      let np = try? await sec.nport(cik: fc.cik, seriesId: fc.seriesId, subs: subs) {
                if kind == .unknown { kind = .fund }
                exposure.add(.of(holdings: np.holdings), scale: value / total)
            } else {
                if kind == .unknown, inst == "ETF" || inst == "MUTUALFUND" { kind = .fund }
                unresolved.append(t)
            }
            if kind == .fund, Classifier.looksBond(h?.longName ?? "") || ThreeFund.bondIndexFunds.contains(t) { kind = .bondFund }
            holdings.append(PortfolioHolding(ticker: t, value: value, kind: kind))
        }
        return PortfolioContext(totalValue: total, spValue: sp, stockTickers: stocks, speculationValue: spec, exposure: exposure,
                                unresolved: unresolved, holdings: holdings)
    }
}

nonisolated enum Classifier {
    static func looksLeveraged(_ name: String) -> Bool {
        name.range(of: #"(?i)\b(2x|3x|-1x|-2x|-3x|ultra|ultrapro|inverse|leveraged|bear|daily (bull|bear))\b"#, options: .regularExpression) != nil
    }
    static func looksBond(_ name: String) -> Bool {
        name.range(of: #"(?i)\b(bond|treasury|aggregate|fixed income|municipal|muni|t-bill)\b"#, options: .regularExpression) != nil
    }
    static func looksCrypto(_ name: String) -> Bool {
        name.range(of: #"(?i)\b(bitcoin|ether|ethereum|solana|crypto|xrp)\b"#, options: .regularExpression) != nil
    }

    static func classify(ticker: String, history: PriceHistory, yahoo: [String: [String: Any]]?, company: SECCompany?,
                         fundClass: SECFundClass?, sic: String?) -> (AssetType, String) {
        let inst = history.instrumentType ?? yahoo?["quoteType"]?.str("quoteType") ?? ""
        let name = history.longName ?? ""
        let category = yahoo?["fundProfile"]?.str("categoryName") ?? yahoo?["defaultKeyStatistics"]?.str("category") ?? ""
        let industry = yahoo?["assetProfile"]?.str("industry") ?? ""
        let bondPos = yahoo?["topHoldings"]?.raw("bondPosition") ?? 0

        if inst == "CRYPTOCURRENCY" || ticker.hasSuffix("-USD") { return (.crypto, "Yahoo instrument type \(inst)") }
        if inst == "EQUITY" {
            if sic == "6798" || industry.localizedCaseInsensitiveContains("REIT") {
                return (.reit, "Equity with SIC \(sic ?? "?") / industry \"\(industry)\": REIT")
            }
            return (.stock, "Equity (SEC CIK \(company.map { String($0.cik) } ?? "not found"))")
        }
        if inst == "ETF" || inst == "MUTUALFUND" || fundClass != nil {
            if looksLeveraged(name) || category.localizedCaseInsensitiveContains("Leveraged") || category.localizedCaseInsensitiveContains("Inverse") || category.hasPrefix("Trading") {
                return (.leveragedOrInverse, "Fund name/category \"\(name)\" / \"\(category)\" indicates leverage or inverse exposure")
            }
            if category.localizedCaseInsensitiveContains("Digital Assets") || looksCrypto(name) { return (.cryptoETF, "Crypto fund (\(category.isEmpty ? name : category))") }
            if category.localizedCaseInsensitiveContains("Real Estate") { return (.reit, "Real-estate fund category \"\(category)\": REIT comparison only") }
            let bondWords = ["Bond", "Treasury", "Muni", "Government", "Corporate", "Ultrashort", "Short-Term", "Intermediate", "Inflation", "High Yield", "Bank Loan"]
            if bondPos > 0.6 || bondWords.contains(where: { category.localizedCaseInsensitiveContains($0) }) && !category.localizedCaseInsensitiveContains("Allocation") {
                return (.bondFund, "Category \"\(category)\", bond position \(Fmt.pct(bondPos, digits: 0))")
            }
            return (inst == "MUTUALFUND" ? .mutualFund : .etf, "Yahoo instrument type \(inst), category \"\(category)\"")
        }
        return (.unknown, "Unrecognised instrument type \"\(inst)\"")
    }
}
