import Foundation

/// Risk-free rate: FRED 3-month Treasury (DGS3MO, full daily history, keyless CSV) as the series
/// used in Sharpe; US Treasury daily bill rates (current year) as the cross-check for the latest value.
nonisolated struct RateSeries: Sendable {
    var dates: [Date], rates: [Double]      // annual yield as a fraction
    var source: SourceRef

    /// Average annual rate between two dates (fallback: latest).
    func average(from: Date, to: Date) -> Double? {
        let v = zip(dates, rates).filter { $0.0 >= from && $0.0 <= to }.map(\.1)
        return v.isEmpty ? rates.last : v.reduce(0, +) / Double(v.count)
    }
    var latest: Double? { rates.last }
}

struct RatesClient: Sendable {
    let http: HTTPClient

    func fred3Month() async throws -> RateSeries {
        let url = "https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS3MO"
        let r = try await http.get(url, maxAge: Cache.fundamentals)
        guard let text = String(data: r.data, encoding: .utf8) else { throw EngineError.parse("FRED CSV") }
        var dates: [Date] = [], rates: [Double] = []
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let c = line.split(separator: ",", omittingEmptySubsequences: false)
            guard c.count >= 2, let d = DateParse.ymd(String(c[0])), let v = Double(c[1]) else { continue }
            dates.append(d); rates.append(v / 100)
        }
        guard !rates.isEmpty else { throw EngineError.parse("FRED CSV empty") }
        return RateSeries(dates: dates, rates: rates,
                          source: SourceRef(name: "FRED DGS3MO (3-month Treasury)", url: url, asOf: dates.last, fetchedAt: r.fetchedAt))
    }

    /// Latest 13-week (3-month) bill coupon-equivalent yield from Treasury.gov for `year`.
    func treasury3Month(year: Int) async throws -> DataPoint {
        let url = "https://home.treasury.gov/resource-center/data-chart-center/interest-rates/daily-treasury-rates.csv/\(year)/all?type=daily_treasury_bill_rates&field_tdr_date_value=\(year)&page&_format=csv"
        let r = try await http.get(url, maxAge: Cache.fundamentals)
        guard let text = String(data: r.data, encoding: .utf8) else { throw EngineError.parse("Treasury CSV") }
        let lines = text.split(whereSeparator: \.isNewline)
        guard let header = lines.first?.split(separator: ",").map({ $0.replacingOccurrences(of: "\"", with: "") }),
              let col = header.firstIndex(where: { $0.contains("13 WEEKS COUPON EQUIVALENT") }),
              let row = lines.dropFirst().first?.split(separator: ",", omittingEmptySubsequences: false),
              col < row.count, let v = Double(row[col]) else { throw EngineError.parse("Treasury CSV columns") }
        let f = DateFormatter(); f.dateFormat = "MM/dd/yyyy"; f.timeZone = TimeZone(identifier: "UTC")
        let d = f.date(from: String(row[0]))
        return DataPoint(key: "riskFree", label: "3-month T-bill yield", value: v / 100, unit: .percent,
                         source: SourceRef(name: "US Treasury daily bill rates", url: url, asOf: d, fetchedAt: r.fetchedAt))
    }
}

/// CoinGecko keyless API (demo tier without key: ~365 days of daily history, low rate limits).
struct CoinGeckoClient: Sendable {
    let http: HTTPClient
    static let ids = ["BTC": "bitcoin", "ETH": "ethereum", "SOL": "solana", "XRP": "ripple", "DOGE": "dogecoin",
                      "ADA": "cardano", "LTC": "litecoin", "BNB": "binancecoin", "AVAX": "avalanche-2", "DOT": "polkadot"]

    func dailyPrices(coinId: String) async throws -> [(Date, Double)] {
        let url = "https://api.coingecko.com/api/v3/coins/\(coinId)/market_chart?vs_currency=usd&days=365&interval=daily"
        let (obj, _) = try await http.json(url, maxAge: Cache.prices)
        let prices = ((obj as? [String: Any])?.arr("prices") as? [[NSNumber]]) ?? []
        return prices.compactMap { p in p.count == 2 ? (Calendar.utc.startOfDay(for: Date(timeIntervalSince1970: p[0].doubleValue / 1000)), p[1].doubleValue) : nil }
    }
    func sourceURL(coinId: String) -> String {
        "https://api.coingecko.com/api/v3/coins/\(coinId)/market_chart?vs_currency=usd&days=365&interval=daily"
    }
}
