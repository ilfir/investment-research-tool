import Foundation
import Testing
@testable import TickerEvaluator

// MARK: - Helpers

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")
private let asOf = DateParse.ymd("2026-11-17")!     // fixtures were recorded on this date

private func replay(_ ticker: String, age: Int = 40, positions: [Position] = [], judgements: JudgementAnswers = .init(),
                    plannedAmount: Double? = nil) async throws -> EvaluationReport {
    let http = HTTPClient(transport: FixtureTransport(directory: fixtures), store: nil)
    var req = EvaluationRequest(ticker: ticker, positions: positions, judgements: judgements, asOf: asOf)
    req.profile.age = age
    req.profile.plannedAmount = plannedAmount
    return try await Evaluator(http: http, store: nil).evaluate(req)
}

private func rule(_ r: EvaluationReport, _ id: String) -> RuleResult? { r.rules.first { $0.id == id } }

private func daily(_ values: [Double], start: String = "2020-01-01") -> Series {
    let d0 = DateParse.ymd(start)!
    return Series(dates: values.indices.map { Calendar.utc.date(byAdding: .day, value: $0, to: d0)! }, values: values)
}

private func monthly(_ values: [Double], start: String = "2000-01-31") -> Series {
    let d0 = DateParse.ymd(start)!
    return Series(dates: values.indices.map { Calendar.utc.date(byAdding: .month, value: $0, to: d0)! }, values: values)
}

// MARK: - Fixture replays: VOO, SCHD, MSFT (recorded 2026-11-17)

@Suite("Known tickers (recorded fixtures)")
struct KnownTickerTests {
    @Test func voo() async throws {
        let r = try await replay("VOO")
        #expect(r.assetType == .etf)
        #expect(r.verdict.verdict == .buy)
        let er = try #require(r.fund?.expenseRatio.primary)
        #expect(abs(er.value - 0.0003) < 0.00001)
        #expect(er.source.name.hasPrefix("SEC"))
        #expect(r.fund?.expenseRatio.status == .agree)
        #expect((r.overlapWithSP ?? 0) > 0.99)
        let p = try #require(r.performance)
        let tenY = try #require(p.periods.first { $0.label == "10y" })
        // VOO tracks the total-return index within a few basis points a year.
        #expect(abs((tenY.asset ?? 0) - (tenY.benchmark ?? 1)) < 0.001)
        #expect(abs(p.beta - 1) < 0.02)
        #expect(p.drawdown.maxDrawdown < -0.30 && p.drawdown.maxDrawdown > -0.40)   // COVID 2020
        #expect(rule(r, "F5")?.status == .pass)                                      // AUM
        #expect(r.missing.isEmpty)
    }

    @Test func schd() async throws {
        let r = try await replay("SCHD")
        #expect(r.assetType == .etf)
        let er = try #require(r.fund?.expenseRatio.primary)
        #expect(abs(er.value - 0.0006) < 0.00001)
        #expect((r.overlapWithSP ?? 1) < 0.20)          // dividend/value: low overlap with VOO
        #expect(rule(r, "F11")?.status == .pass)
        // Lagged the S&P in most rolling 5-yr windows → "Just buy the S&P 500" (approved mapping).
        #expect(rule(r, "F12")?.status == .fail)
        #expect(r.verdict.verdict == .justBuySP)
        #expect((r.dividends?.trailing12mYield ?? 0) > 0.02)
    }

    @Test func msft() async throws {
        let r = try await replay("MSFT")
        #expect(r.assetType == .stock)
        let f = try #require(r.fundamentals)
        let fy = try #require(f.latest)
        #expect(Fmt.date(fy.end) == "2026-06-30")
        #expect(abs((fy.revenue ?? 0) - 331.84e9) < 0.1e9)
        #expect(abs((fy.operatingMargin ?? 0) - 0.468) < 0.002)
        #expect(rule(r, "S2")?.status == .pass)
        #expect(rule(r, "S3")?.status == .pass)
        #expect(rule(r, "S4")?.status == .pass)
        // Leases are excluded from step 1 (decision 2026-11-17): $64.5B cash vs $35.5B debt passes.
        #expect(rule(r, "S1")?.status == .pass)
        #expect(rule(r, "S1")?.detail?.contains("would fail") == true)   // incl. leases it would fail; shown as context
        // Judgement items unconfirmed → best possible verdict is "Buy slowly".
        #expect(r.verdict.verdict == .buySlowly)
        // Judgement items stay unconfirmed until you answer them.
        #expect(rule(r, "S5")?.status == .unconfirmed)
        #expect(rule(r, "S7")?.suggestion == true)
        #expect(r.checks.first { $0.key == "cash" }?.status == .agree)
    }

    @Test func judgementsCountWhenConfirmed() async throws {
        let r = try await replay("MSFT", judgements: JudgementAnswers(moat: true, topTierCEO: false, recessionProof: true))
        #expect(rule(r, "S5")?.status == .pass)
        #expect(rule(r, "S6")?.status == .fail)
    }

    @Test func portfolioFitUsesPositions() async throws {
        // A 40-year-old holding only MSFT shares, planning $1,000 of VOO.
        let pos = [Position(ticker: "MSFT", amount: 9_000)]
        let r = try await replay("VOO", positions: pos, plannedAmount: 1_000)
        let p1 = try #require(rule(r, "P1"))
        #expect(p1.status == .fail)                 // 10% S&P after the buy < 40% floor
        #expect(rule(r, "P2")?.actual.hasPrefix("1") == true)
    }
}

// MARK: - Pure calculations

@Suite("Metrics")
struct MetricTests {
    @Test func cagr() {
        #expect(abs(Stats.cagr(start: 100, end: 200, years: 10)! - 0.071773) < 1e-5)
        #expect(Stats.cagr(start: 0, end: 200, years: 10) == nil)
    }

    @Test func drawdownAndRecovery() {
        let dd = Drawdown.of(daily([100, 120, 90, 60, 80, 121, 130]))
        #expect(abs(dd.maxDrawdown - (-0.5)) < 1e-9)
        #expect(Fmt.date(dd.peakDate) == "2020-01-02")
        #expect(Fmt.date(dd.troughDate) == "2020-01-04")
        #expect(dd.recoveryDays == 2)
    }

    @Test func rollingWindows() {
        let a = monthly((0...72).map { 100 * pow(1.01, Double($0)) })
        let b = monthly((0...72).map { 100 * pow(1.005, Double($0)) })
        let r = PerformanceCalc.rolling(a, b, years: 5)
        #expect(r.windows == 13)
        #expect(r.beatPct == 1)
    }

    @Test func parabolicRule() {
        var v = Array(repeating: 100.0, count: 60); v += [110, 125]
        let pa = PriceAction.of(daily(v))
        #expect(pa.isParabolic)
        #expect(!PriceAction.of(daily(Array(repeating: 100.0, count: 62))).isParabolic)
    }

    @Test func overlap() {
        let a = Exposure(weights: ["X": 0.5, "Y": 0.5]), b = Exposure(weights: ["X": 0.2, "Z": 0.8])
        #expect(abs(OverlapCalc.overlap(a, b) - 0.2) < 1e-12)
        #expect(OverlapCalc.overlap(a, a) == 1)
    }

    @Test func issuerNamesMatch() {
        #expect(IssuerKey.make("Alphabet Inc Class A") == IssuerKey.make("ALPHABET INC-CL C"))
        #expect(IssuerKey.make("Microsoft Corp") == IssuerKey.make("MICROSOFT CORPORATION"))
    }

    @Test func feeDrag() {
        let d = FeeDrag.project(expenseRatio: 0.01, referenceRatio: 0.0003, amount: 100_000)
        #expect(d.map(\.years) == [10, 20, 30])
        #expect(d[2].costVsReference > 200_000)          // ~$234k in the notes' example (8%, 30 yrs)
    }

    @Test func crossCheck() {
        let s = SourceRef(name: "A", url: "", asOf: nil, fetchedAt: .now)
        let a = DataPoint(key: "k", label: "k", value: 100, unit: .usd, source: s)
        var b = a; b.value = 103
        #expect(CrossCheck.compare("k", key: "k", a, b).status == .agree)
        b.value = 120
        #expect(CrossCheck.compare("k", key: "k", a, b).status == .conflict)
        #expect(CrossCheck.compare("k", key: "k", a, nil).status == .singleSource)
    }
}

@Suite("Rules and verdict")
struct RuleTests {
    @Test func spFloorByAge() {
        #expect(PortfolioRules.spFloor(age: 35) == 0.40)
        #expect(PortfolioRules.spFloor(age: 55) == 0.25)
        #expect(PortfolioRules.spFloor(age: 65) == 0.30)
        #expect(PortfolioRules.spFloor(age: nil) == 0.40)
    }

    private func r(_ id: String, _ s: RuleStatus, _ w: RuleWeight, group: RuleGroup = .screen) -> RuleResult {
        RuleResult(id: id, group: group, title: id, status: s, actual: "", threshold: "", weight: w)
    }
    private func decide(_ rules: [RuleResult], type: AssetType = .stock, pa: PriceAction = PriceAction()) -> Verdict {
        VerdictEngine.decide(type: type, rules: rules, isSPTracker: false, priceAction: pa, checks: [], staleCount: 0).verdict
    }

    @Test func mapping() {
        let pass = [r("S1", .pass, .hard), r("S2", .pass, .soft), r("S3", .pass, .soft), r("S4", .pass, .soft)]
        #expect(decide(pass + [r("S5", .pass, .soft), r("S6", .pass, .soft), r("S7", .pass, .soft)]) == .buy)
        #expect(decide(pass + [r("S5", .unconfirmed, .soft)]) == .buySlowly)
        #expect(decide(pass, pa: PriceAction(change30d: 0.25, drawdownFrom52wHigh: 0, high52w: nil)) == .buySlowly)
        #expect(decide([r("S1", .fail, .hard)] + pass.dropFirst()) == .avoid)
        #expect(decide([r("S2", .fail, .soft)] + pass) == .holdOff)
        #expect(decide([r("S2", .fail, .soft), r("S3", .fail, .soft), r("S4", .fail, .soft)]) == .avoid)
        #expect(decide([r("F12", .fail, .soft, group: .fund)], type: .etf) == .justBuySP)
        #expect(decide([], type: .crypto) == .speculation)
        #expect(decide([], type: .reit) == .notEvaluated)
        #expect(decide([], type: .leveragedOrInverse) == .avoid)
    }

    @Test func classifier() {
        #expect(Classifier.looksLeveraged("ProShares UltraPro QQQ"))
        #expect(Classifier.looksLeveraged("Direxion Daily S&P 500 Bull 3X Shares"))
        #expect(!Classifier.looksLeveraged("Vanguard S&P 500 ETF"))
        #expect(Classifier.looksCrypto("iShares Bitcoin Trust ETF"))
    }
}

@Suite("Storage and plumbing")
struct StoreTests {
    @Test func positionsRoundTrip() async throws {
        let s = try Store(path: ":memory:")
        await s.replacePositions([Position(ticker: "voo", shares: 10, accountType: .rothIRA), Position(ticker: "MSFT", amount: 5000)])
        let p = await s.positions()
        #expect(p.map(\.ticker) == ["MSFT", "VOO"])
        #expect(p.last?.accountType == .rothIRA)
    }

    @Test func dataPointsKeepSource() async throws {
        let s = try Store(path: ":memory:")
        let src = SourceRef(name: "SEC EDGAR companyfacts (XBRL)", url: "https://data.sec.gov/x", asOf: asOf, fetchedAt: asOf)
        await s.save([DataPoint(key: "opMargin", label: "Operating margin", value: 0.468, unit: .percent, source: src)], ticker: "MSFT")
        let back = await s.dataPoints(ticker: "MSFT")
        #expect(back.first?.source.url == "https://data.sec.gov/x")
        #expect(back.first?.source.asOf == asOf)
    }

    @Test func httpCacheHonoursMaxAge() async throws {
        let s = try Store(path: ":memory:")
        await s.putCache(url: "u", body: Data("x".utf8), fetchedAt: Date(timeIntervalSinceNow: -7200))
        #expect(await s.cached(url: "u", maxAge: 3600) == nil)
        #expect(await s.cached(url: "u", maxAge: 10_000) != nil)
    }

    @Test func fixtureNamesIgnoreCrumb() {
        #expect(FixtureName.for("https://q.com/v10/x?modules=a&crumb=abc") == FixtureName.for("https://q.com/v10/x?modules=a&crumb="))
    }
}

/// Opt-in: hits the real endpoints. Run with TE_LIVE=1 in the scheme's test environment.
@Suite("Live (opt-in)", .enabled(if: ProcessInfo.processInfo.environment["TE_LIVE"] == "1"))
struct LiveTests {
    @Test func liveVOO() async throws {
        let http = HTTPClient(store: nil)
        let r = try await Evaluator(http: http, store: nil).evaluate(EvaluationRequest(ticker: "VOO"))
        #expect(r.assetType == .etf)
        #expect(r.fund?.expenseRatio.primary != nil)
        #expect(r.performance != nil)
    }
}

@Suite("Profile")
@MainActor
struct ProfileTests {
    @Test func profileIsSavedAndRestored() async throws {
        let store = try Store(path: ":memory:")
        let m = AppModel(store: store, http: HTTPClient(transport: FixtureTransport(directory: URL(fileURLWithPath: "/nonexistent")), store: nil))
        m.profile = InvestorProfile(age: 55, horizonYears: 20, accountType: .rothIRA, role: .core, maxDrawdownTolerance: 0.3, plannedAmount: 5000)
        try await Task.sleep(for: .milliseconds(1200))
        let raw = try #require(await store.setting(AppModel.profileKey))
        let saved = try JSONDecoder().decode(InvestorProfile.self, from: Data(raw.utf8))
        #expect(saved.age == 55 && saved.accountType == .rothIRA && saved.plannedAmount == 5000)

        let m2 = AppModel(store: store, http: nil)
        await m2.loadProfile()
        #expect(m2.profile == saved)
    }

    @Test func profileFeedsPortfolioRules() {
        var req = EvaluationRequest(ticker: "BND")
        req.profile = InvestorProfile(age: 62, horizonYears: 3, accountType: .taxable, role: .hedge, maxDrawdownTolerance: 0.1)
        let ids = Set(PortfolioRules.behaviour(type: .bondFund, request: req, maxDrawdown: -0.18).map(\.id))
        #expect(ids == ["P6", "P7", "P8"])   // P9 horizon doesn't apply to bond funds
        #expect(PortfolioRules.spFloor(age: 62) == 0.30)
    }
}

@Suite("Positions CSV")
struct PositionsCSVTests {
    // Synthetic file in Fidelity's "Portfolio_Positions" layout (to be re-checked against a real export).
    static let fidelity = """
    \u{FEFF}Account Number,Account Name,Symbol,Description,Quantity,Last Price,Last Price Change,Current Value,Today's Gain/Loss Dollar,Type
    X12345678,Individual,SPAXX**,HELD IN MONEY MARKET,,,,$1520.11,,Cash,
    X12345678,Individual,VOO,VANGUARD INDEX FDS S&P 500 ETF USD,12.5,$548.10,+$1.20,"$6,851.25",+$15.00,Cash,
    X12345678,Individual,BRK.B,BERKSHIRE HATHAWAY INC CLASS B,3,$470.00,-$2.00,"$1,410.00",-$6.00,Cash,
    234567890,ROTH IRA,SCHD,SCHWAB US DIVIDEND EQUITY ETF,40,$27.50,,"$1,100.00",,Cash,
    234567890,ROTH IRA,Pending Activity,,,,,-$200.00,,,
    Z98765432,FIDELITY 401K PLAN,31617E471,FID 500 INDEX,,,,"$25,000.00",,,

    "The data and information in this spreadsheet is provided to you solely for your use, ""as is""."
    "Date downloaded 11/17/2026 4:01 PM ET"
    """

    @Test func parsesFidelityLayout() throws {
        let r = try PositionsCSV.parse(Self.fidelity)
        #expect(r.positions.map(\.ticker) == ["VOO", "BRK-B", "SCHD"])
        #expect(r.positions[0].shares == 12.5 && r.positions[0].amount == 6851.25 && r.positions[0].accountType == .taxable)
        #expect(r.positions[2].accountType == .rothIRA)
        #expect(r.skipped.count == 3)   // SPAXX cash, pending activity, CUSIP-only 401(k) fund
    }

    @Test func parsesGenericCSV() throws {
        let r = try PositionsCSV.parse("Ticker,Shares\nmsft,10\nqqq,(2)\n")
        #expect(r.positions.map(\.ticker) == ["MSFT"])
        #expect(throws: PositionsCSV.ImportError.self) { try PositionsCSV.parse("a,b\n1,2") }
        #expect(PositionsCSV.number("$1,234.50") == 1234.5)
    }
}
