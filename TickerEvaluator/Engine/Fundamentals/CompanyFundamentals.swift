import Foundation

/// One fiscal year of reported numbers (USD).
nonisolated struct FiscalYear: Sendable, Hashable {
    var end: Date
    var fy: Int
    var revenue: Double?, operatingIncome: Double?, operatingExpenses: Double?, netIncome: Double?
    var operatingCashFlow: Double?, capex: Double?, interestExpense: Double?, dilutedShares: Double?
    var freeCashFlow: Double? { operatingCashFlow.flatMap { o in capex.map { o - $0 } } }
    var operatingMargin: Double? { ratio(operatingIncome, revenue) }
    var fcfMargin: Double? { ratio(freeCashFlow, revenue) }
    /// Total operating costs = revenue − operating income (used when OperatingExpenses is not reported).
    var totalCosts: Double? { revenue.flatMap { r in operatingIncome.map { r - $0 } } }
}

nonisolated func ratio(_ a: Double?, _ b: Double?) -> Double? {
    guard let a, let b, b != 0 else { return nil }; return a / b
}

nonisolated struct BalanceSheet: Sendable {
    var date: Date
    var cash: Double?, shortTermInvestments: Double?, cashAndSTI: Double?
    var longTermDebt: Double?, shortTermDebt: Double?
    var operatingLeases: Double?, financeLeases: Double?
    var equity: Double?, sharesOutstanding: Double?
    var form: String

    var totalCash: Double? { cashAndSTI ?? cash.map { $0 + (shortTermInvestments ?? 0) } }
    var debtExLeases: Double? { longTermDebt.map { $0 + (shortTermDebt ?? 0) } ?? shortTermDebt }
    var debtInclLeases: Double? { debtExLeases.map { $0 + (operatingLeases ?? 0) + (financeLeases ?? 0) } }
}

nonisolated struct CompanyFundamentals: Sendable {
    var years: [FiscalYear]          // ascending
    var balance: BalanceSheet?
    var source: SourceRef
    var opexConcept: String          // "OperatingExpenses" or "Revenue − operating income"

    var latest: FiscalYear? { years.last }
    func year(endingIn calendarYear: Int) -> FiscalYear? {
        years.first { Calendar.utc.component(.year, from: $0.end) == calendarYear }
    }
    func growth(_ kp: KeyPath<FiscalYear, Double?>, yearsBack n: Int) -> Double? {
        guard years.count > n, let a = years[years.count - 1 - n][keyPath: kp], let b = years.last?[keyPath: kp], a > 0, b > 0 else { return nil }
        return pow(b / a, 1 / Double(n)) - 1
    }
    func opex(_ y: FiscalYear) -> Double? { opexConcept == "OperatingExpenses" ? y.operatingExpenses : y.totalCosts }
}

/// Extracts annual and latest balance-sheet values from SEC companyfacts.
nonisolated enum FundamentalsExtractor {
    struct Fact {
        var start: Date?
        var end: Date
        var val: Double
        var form: String
        var filed: String
        var fy: Int?
    }

    static let revenue = ["RevenueFromContractWithCustomerExcludingAssessedTax", "Revenues", "SalesRevenueNet",
                          "RevenueFromContractWithCustomerIncludingAssessedTax", "SalesRevenueGoodsNet"]
    static let interest = ["InterestExpenseNonoperating", "InterestExpense", "InterestExpenseDebt"]

    static func extract(facts: [String: Any], source: SourceRef) -> CompanyFundamentals {
        let g = facts["us-gaap"] as? [String: Any] ?? [:]
        let dei = facts["dei"] as? [String: Any] ?? [:]

        func raw(_ concept: String, in tax: [String: Any] = g) -> [Fact] {
            guard let units = (tax[concept] as? [String: Any])?["units"] as? [String: Any],
                  let list = (units["USD"] ?? units["shares"] ?? units.values.first) as? [[String: Any]] else { return [] }
            return list.compactMap { x in
                guard let e = DateParse.ymd(x.str("end")), let v = x.num("val") else { return nil }
                return Fact(start: DateParse.ymd(x.str("start")), end: e, val: v, form: x.str("form") ?? "",
                            filed: x.str("filed") ?? "", fy: x.num("fy").map(Int.init))
            }
        }
        /// Annual (≈ 1-year duration from 10-K) values by period end; latest filing wins; first concept wins per date.
        func annual(_ concepts: [String]) -> [Date: Double] {
            var out: [Date: (Double, String)] = [:]
            for (rank, c) in concepts.enumerated() {
                for f in raw(c) where f.form.hasPrefix("10-K") || f.form.hasPrefix("20-F") {
                    guard let s = f.start else { continue }
                    let days = f.end.timeIntervalSince(s) / 86_400
                    guard days > 340, days < 390 else { continue }
                    let tag = "\(rank)|\(f.filed)"
                    if let cur = out[f.end] {
                        let curRank = Int(cur.1.split(separator: "|")[0])!
                        if rank > curRank || (rank == curRank && f.filed <= String(cur.1.split(separator: "|")[1])) { continue }
                    }
                    out[f.end] = (f.val, tag)
                }
            }
            return out.mapValues(\.0)
        }
        /// Latest instant value (any form) for a concept list.
        func latestInstant(_ concepts: [String], tax: [String: Any] = g) -> (Date, Double, String)? {
            var best: Fact?
            for c in concepts { for f in raw(c, in: tax) where f.start == nil {
                if best == nil || f.end > best!.end || (f.end == best!.end && f.filed > best!.filed) { best = f }
            } }
            return best.map { ($0.end, $0.val, $0.form) }
        }
        func instant(_ concepts: [String], at date: Date) -> Double? {
            for c in concepts {
                let m = raw(c).filter { $0.start == nil && $0.end == date }.max { $0.filed < $1.filed }
                if let m { return m.val }
            }
            return nil
        }

        let rev = annual(revenue), op = annual(["OperatingIncomeLoss"]), opx = annual(["OperatingExpenses"])
        let ni = annual(["NetIncomeLoss", "ProfitLoss"]), ocf = annual(["NetCashProvidedByUsedInOperatingActivities", "NetCashProvidedByUsedInOperatingActivitiesContinuingOperations"])
        let capex = annual(["PaymentsToAcquirePropertyPlantAndEquipment", "PaymentsToAcquireProductiveAssets"])
        let intr = annual(interest), sh = annual(["WeightedAverageNumberOfDilutedSharesOutstanding"])

        let ends = Set(rev.keys).union(op.keys).sorted()
        var years = ends.map { e in
            FiscalYear(end: e, fy: Calendar.utc.component(.year, from: e), revenue: rev[e], operatingIncome: op[e],
                       operatingExpenses: opx[e], netIncome: ni[e], operatingCashFlow: ocf[e], capex: capex[e],
                       interestExpense: intr[e], dilutedShares: sh[e])
        }
        years = years.filter { $0.revenue != nil }
        let opexCount = years.suffix(4).filter { $0.operatingExpenses != nil }.count
        let opexConcept = opexCount >= 4 ? "OperatingExpenses" : "Revenue − operating income"

        var bs: BalanceSheet?
        if let (date, _, form) = latestInstant(["CashAndCashEquivalentsAtCarryingValue", "CashCashEquivalentsAndShortTermInvestments",
                                                "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents"]) {
            let ltdTotal = instant(["LongTermDebt"], at: date)
            let ltdNon = instant(["LongTermDebtNoncurrent", "LongTermDebtAndCapitalLeaseObligations"], at: date)
            let ltdCur = instant(["LongTermDebtCurrent"], at: date)
            let st = [instant(["CommercialPaper"], at: date), instant(["ShortTermBorrowings"], at: date)].compactMap { $0 }
            let opL = instant(["OperatingLeaseLiability"], at: date) ??
                [instant(["OperatingLeaseLiabilityNoncurrent"], at: date), instant(["OperatingLeaseLiabilityCurrent"], at: date)].compactMap { $0 }.nilIfEmptySum
            let finL = instant(["FinanceLeaseLiability"], at: date) ??
                [instant(["FinanceLeaseLiabilityNoncurrent"], at: date), instant(["FinanceLeaseLiabilityCurrent"], at: date)].compactMap { $0 }.nilIfEmptySum
            let shares = latestInstant(["EntityCommonStockSharesOutstanding"], tax: dei)?.1
            bs = BalanceSheet(date: date,
                              cash: instant(["CashAndCashEquivalentsAtCarryingValue"], at: date),
                              shortTermInvestments: instant(["ShortTermInvestments", "MarketableSecuritiesCurrent", "AvailableForSaleSecuritiesDebtSecuritiesCurrent"], at: date),
                              cashAndSTI: instant(["CashCashEquivalentsAndShortTermInvestments"], at: date),
                              longTermDebt: ltdTotal ?? [ltdNon, ltdCur].compactMap { $0 }.nilIfEmptySum,
                              shortTermDebt: st.nilIfEmptySum,
                              operatingLeases: opL, financeLeases: finL,
                              equity: instant(["StockholdersEquity", "StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest"], at: date),
                              sharesOutstanding: shares, form: form)
        }
        var src = source; src.asOf = bs?.date ?? years.last?.end
        return CompanyFundamentals(years: years, balance: bs, source: src, opexConcept: opexConcept)
    }
}

nonisolated extension Array where Element == Double {
    var nilIfEmptySum: Double? { isEmpty ? nil : reduce(0, +) }
}
