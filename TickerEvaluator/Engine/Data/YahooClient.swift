import Foundation

/// Daily price history. `adjClose` is the dividend- and split-adjusted series (total return proxy).
nonisolated struct PriceHistory: Sendable {
    var symbol: String
    var dates: [Date]
    var close: [Double]
    var adjClose: [Double]
    var volume: [Double]
    var dividends: [(date: Date, amount: Double)]
    var firstTradeDate: Date?
    var instrumentType: String?      // EQUITY, ETF, MUTUALFUND, CRYPTOCURRENCY, INDEX
    var longName: String?
    var exchange: String?
    var currency: String?
    var source: SourceRef

    var lastDate: Date? { dates.last }
    var lastClose: Double? { close.last }
}

/// Yahoo Finance (unofficial, keyless). Main maintenance risk: endpoints may change.
struct YahooClient: Sendable {
    let http: HTTPClient

    func chart(_ symbol: String, asOf: Date) async throws -> PriceHistory {
        let end = Int(Calendar.utc.startOfDay(for: asOf).timeIntervalSince1970) + 86_400
        let enc = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "^="))) ?? symbol
        let url = "https://query1.finance.yahoo.com/v8/finance/chart/\(enc)?period1=0&period2=\(end)&interval=1d&events=div%2Csplit&includeAdjustedClose=true"
        let (obj, resp) = try await http.json(url, maxAge: Cache.prices)
        guard let root = (obj as? [String: Any])?.dict("chart"),
              let result = (root.arr("result")?.first as? [String: Any]) else {
            throw EngineError.notFound("Yahoo chart for \(symbol)")
        }
        let meta = result.dict("meta") ?? [:]
        let ts = (result.arr("timestamp") as? [NSNumber])?.map { $0.doubleValue } ?? []
        let quote = (result.dict("indicators")?.arr("quote")?.first as? [String: Any]) ?? [:]
        let adj = (result.dict("indicators")?.arr("adjclose")?.first as? [String: Any])?.arr("adjclose") ?? []
        let closes = quote.arr("close") ?? [], vols = quote.arr("volume") ?? []

        var h = PriceHistory(symbol: symbol, dates: [], close: [], adjClose: [], volume: [], dividends: [],
                             firstTradeDate: meta.num("firstTradeDate").map { Date(timeIntervalSince1970: $0) },
                             instrumentType: meta.str("instrumentType"), longName: meta.str("longName") ?? meta.str("shortName"),
                             exchange: meta.str("fullExchangeName"), currency: meta.str("currency"),
                             source: SourceRef(name: "Yahoo Finance chart (unofficial)", url: url, asOf: nil, fetchedAt: resp.fetchedAt))
        for i in ts.indices {
            guard i < closes.count, let c = (closes[i] as? NSNumber)?.doubleValue, c > 0 else { continue }
            let a = i < adj.count ? ((adj[i] as? NSNumber)?.doubleValue ?? c) : c
            // Yahoo timestamps are market-open times; normalise to the UTC calendar day.
            h.dates.append(Calendar.utc.startOfDay(for: Date(timeIntervalSince1970: ts[i] + 6 * 3600)))
            h.close.append(c); h.adjClose.append(a)
            h.volume.append(i < vols.count ? ((vols[i] as? NSNumber)?.doubleValue ?? 0) : 0)
        }
        if let divs = result.dict("events")?.dict("dividends") {
            h.dividends = divs.values.compactMap { v in
                guard let d = v as? [String: Any], let amt = d.num("amount"), let t = d.num("date") else { return nil }
                return (Calendar.utc.startOfDay(for: Date(timeIntervalSince1970: t + 6 * 3600)), amt)
            }.sorted { $0.date < $1.date }
        }
        h.source.asOf = h.dates.last
        guard h.dates.count > 1 else { throw EngineError.notFound("price history for \(symbol)") }
        return h
    }

    /// quoteSummary needs a session cookie + "crumb". Returns module dictionaries keyed by module name.
    func quoteSummary(_ symbol: String) async throws -> (modules: [String: [String: Any]], source: SourceRef) {
        let modules = "quoteType,price,summaryDetail,defaultKeyStatistics,financialData,fundProfile,topHoldings,assetProfile"
        let base = "https://query2.finance.yahoo.com/v10/finance/quoteSummary/\(symbol)?modules=\(modules)"
        let cacheKey = base
        // Serve from cache without touching the crumb endpoints when possible.
        if let r = await http.cachedResponse(cacheKey, url: base, maxAge: Cache.fundamentals) {
            return try parseSummary(r, symbol: symbol)
        }
        let crumb = await YahooSession.shared.crumb(http: http)
        let url = base + "&crumb=" + (crumb.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? crumb)
        let r = try await http.get(url, maxAge: Cache.fundamentals, cacheKey: cacheKey)
        return try parseSummary(r, symbol: symbol)
    }

    private func parseSummary(_ r: HTTPClient.Response, symbol: String) throws -> (modules: [String: [String: Any]], source: SourceRef) {
        guard let obj = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any],
              let res = obj.dict("quoteSummary")?.arr("result")?.first as? [String: Any] else {
            throw EngineError.notFound("Yahoo quoteSummary for \(symbol)")
        }
        var out: [String: [String: Any]] = [:]
        for (k, v) in res { if let d = v as? [String: Any] { out[k] = d } }
        let display = r.url.replacingOccurrences(of: #"&crumb=[^&]*"#, with: "", options: .regularExpression)
        return (out, SourceRef(name: "Yahoo Finance quoteSummary (unofficial)", url: display, asOf: r.fetchedAt, fetchedAt: r.fetchedAt))
    }
}

/// Holds the Yahoo crumb for the app session.
actor YahooSession {
    static let shared = YahooSession()
    private var crumb: String?

    func crumb(http: HTTPClient) async -> String {
        if let crumb { return crumb }
        _ = try? await http.transport.get(URLRequest(url: URL(string: "https://fc.yahoo.com")!))   // sets cookie (404 is normal)
        var req = URLRequest(url: URL(string: "https://query1.finance.yahoo.com/v1/test/getcrumb")!)
        req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        if let (d, code) = try? await http.transport.get(req), code == 200, let s = String(data: d, encoding: .utf8), !s.isEmpty, !s.contains("<") {
            crumb = s
        }
        return crumb ?? ""
    }
}

nonisolated extension Calendar {
    static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
}
