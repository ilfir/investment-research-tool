import Foundation

nonisolated struct SECCompany: Sendable { var cik: Int; var ticker: String; var title: String }
nonisolated struct SECFundClass: Sendable { var cik: Int; var seriesId: String; var classId: String; var ticker: String }

nonisolated struct SECFiling: Sendable {
    var form: String, filingDate: String, reportDate: String, accession: String, primaryDocument: String
    var accessionNoDashes: String { accession.replacingOccurrences(of: "-", with: "") }
}

nonisolated struct SECSubmissions: Sendable {
    var cik: Int, name: String, sic: String, sicDescription: String, entityType: String
    var filings: [SECFiling]
    var source: SourceRef
}

nonisolated struct FundHolding: Sendable, Hashable {
    var name: String, title: String, cusip: String, isin: String?, ticker: String?
    var weight: Double             // fraction of net assets
    var valueUSD: Double
    var assetCategory: String      // EC equity common, DBT debt, ...
    var issuerCategory: String
    var country: String
}

nonisolated struct NPortReport: Sendable {
    var seriesId: String, seriesName: String
    var periodDate: String          // repPdDate (holdings as of)
    var netAssets: Double
    var holdings: [FundHolding]
    var monthlyReturns: [String: [Double]]   // classId -> last 3 monthly total returns (%)
    var source: SourceRef
}

/// One fact from an XBRL instance.
nonisolated struct XBRLFact: Sendable {
    var name: String, contextRef: String, value: String
    var classMember: String?, seriesMember: String?, otherDims: [String: String]
    var start: String?, end: String?, instant: String?
    var number: Double? { Double(value.replacingOccurrences(of: ",", with: "")) }
}

/// SEC EDGAR (keyless, needs a declared User-Agent, ≤ 10 req/s).
struct SECClient: Sendable {
    let http: HTTPClient

    func companies() async throws -> [String: SECCompany] {
        let url = "https://www.sec.gov/files/company_tickers.json"
        let (obj, _) = try await http.json(url, maxAge: Cache.tickerMaps)
        var out: [String: SECCompany] = [:]
        for case let row as [String: Any] in ((obj as? [String: Any]) ?? [:]).values {
            guard let t = row.str("ticker"), let cik = row.num("cik_str") else { continue }
            out[t.uppercased()] = SECCompany(cik: Int(cik), ticker: t.uppercased(), title: row.str("title") ?? t)
        }
        return out
    }

    func fundClasses() async throws -> [String: SECFundClass] {
        let url = "https://www.sec.gov/files/company_tickers_mf.json"
        let (obj, _) = try await http.json(url, maxAge: Cache.tickerMaps)
        var out: [String: SECFundClass] = [:]
        for case let r as [Any] in ((obj as? [String: Any])?.arr("data") ?? []) where r.count >= 4 {
            guard let cik = (r[0] as? NSNumber)?.intValue, let s = r[1] as? String, let c = r[2] as? String, let t = r[3] as? String else { continue }
            out[t.uppercased()] = SECFundClass(cik: cik, seriesId: s, classId: c, ticker: t.uppercased())
        }
        return out
    }

    static func cik10(_ cik: Int) -> String { String(format: "%010d", cik) }

    func submissions(cik: Int) async throws -> SECSubmissions {
        let url = "https://data.sec.gov/submissions/CIK\(Self.cik10(cik)).json"
        let (obj, r) = try await http.json(url, maxAge: Cache.fundamentals)
        guard let d = obj as? [String: Any], let recent = d.dict("filings")?.dict("recent") else { throw EngineError.parse("submissions") }
        let forms = recent.arr("form") as? [String] ?? []
        func col(_ k: String) -> [String] { recent.arr(k) as? [String] ?? [] }
        let fd = col("filingDate"), rd = col("reportDate"), acc = col("accessionNumber"), pd = col("primaryDocument")
        let filings = forms.indices.map { i in
            SECFiling(form: forms[i], filingDate: fd[safe: i] ?? "", reportDate: rd[safe: i] ?? "",
                      accession: acc[safe: i] ?? "", primaryDocument: pd[safe: i] ?? "")
        }
        return SECSubmissions(cik: cik, name: d.str("name") ?? "", sic: d.str("sic") ?? "",
                              sicDescription: d.str("sicDescription") ?? "", entityType: d.str("entityType") ?? "",
                              filings: filings,
                              source: SourceRef(name: "SEC EDGAR submissions", url: url, asOf: nil, fetchedAt: r.fetchedAt))
    }

    func companyFacts(cik: Int) async throws -> (facts: [String: Any], source: SourceRef) {
        let url = "https://data.sec.gov/api/xbrl/companyfacts/CIK\(Self.cik10(cik)).json"
        let (obj, r) = try await http.json(url, maxAge: Cache.fundamentals)
        guard let d = (obj as? [String: Any])?.dict("facts") else { throw EngineError.parse("companyfacts") }
        return (d, SourceRef(name: "SEC EDGAR companyfacts (XBRL)", url: url, asOf: nil, fetchedAt: r.fetchedAt))
    }

    func archiveURL(cik: Int, _ f: SECFiling, _ file: String) -> String {
        "https://www.sec.gov/Archives/edgar/data/\(cik)/\(f.accessionNoDashes)/\(file)"
    }

    /// Most recent filing of the given forms whose SGML header lists `contractId` (series or class id).
    func latestFiling(cik: Int, forms: Set<String>, containing contractId: String, in subs: SECSubmissions, maxScan: Int = 40) async throws -> SECFiling? {
        let candidates = subs.filings.filter { forms.contains($0.form) }.prefix(maxScan)
        for f in candidates {
            let url = archiveURL(cik: cik, f, "\(f.accession)-index-headers.html")
            guard let r = try? await http.get(url, maxAge: Cache.filings * 52) else { continue }   // headers never change
            if let s = String(data: r.data, encoding: .utf8) ?? String(data: r.data, encoding: .isoLatin1), s.contains(contractId) {
                return f
            }
        }
        return nil
    }

    /// Facts from the filing's extracted XBRL instance (…_htm.xml).
    func xbrlFacts(cik: Int, filing f: SECFiling) async throws -> (facts: [XBRLFact], source: SourceRef) {
        let idxURL = archiveURL(cik: cik, f, "index.json")
        let (obj, _) = try await http.json(idxURL, maxAge: Cache.filings * 52)
        let items = ((obj as? [String: Any])?.dict("directory")?.arr("item") as? [[String: Any]]) ?? []
        guard let inst = items.compactMap({ $0.str("name") }).first(where: { $0.hasSuffix("_htm.xml") }) else {
            throw EngineError.notFound("XBRL instance in \(f.accession)")
        }
        let url = archiveURL(cik: cik, f, inst)
        let r = try await http.get(url, maxAge: Cache.filings * 52)
        let facts = XBRLInstanceParser.parse(r.data)
        let asOf = DateParse.ymd(f.reportDate)
        return (facts, SourceRef(name: "SEC EDGAR \(f.form) XBRL", url: archiveURL(cik: cik, f, f.primaryDocument), asOf: asOf, fetchedAt: r.fetchedAt))
    }

    /// Latest N-PORT-P holdings report for a fund series.
    func nport(cik: Int, seriesId: String, subs: SECSubmissions) async throws -> NPortReport {
        guard let f = try await latestFiling(cik: cik, forms: ["NPORT-P"], containing: seriesId, in: subs, maxScan: 80) else {
            throw EngineError.notFound("N-PORT for \(seriesId)")
        }
        let url = archiveURL(cik: cik, f, "primary_doc.xml")
        let r = try await http.get(url, maxAge: Cache.filings * 52)
        guard var rep = NPortParser.parse(r.data) else { throw EngineError.parse("N-PORT \(f.accession)") }
        rep.source = SourceRef(name: "SEC EDGAR N-PORT", url: url, asOf: DateParse.ymd(rep.periodDate), fetchedAt: r.fetchedAt)
        return rep
    }
}

// MARK: - Parsers

nonisolated enum DateParse {
    static func ymd(_ s: String?) -> Date? {
        guard let s, s.count >= 10 else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: String(s.prefix(10)))
    }
}

nonisolated extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Minimal XBRL instance parser: contexts (period + dimension members) and simple facts.
nonisolated final class XBRLInstanceParser: NSObject, XMLParserDelegate {
    private struct Ctx { var start: String?, end: String?, instant: String?, dims: [String: String] = [:] }
    private var contexts: [String: Ctx] = [:]
    private var raw: [(name: String, ctx: String, value: String)] = []
    private var curCtxId: String?, cur = Ctx(), curDim: String?
    private var curFact: (name: String, ctx: String)?, text = ""

    static func parse(_ data: Data) -> [XBRLFact] {
        let p = XBRLInstanceParser(); let x = XMLParser(data: data); x.delegate = p; x.parse()
        return p.raw.compactMap { r in
            guard let c = p.contexts[r.ctx] else { return nil }
            var dims = c.dims
            let cls = dims.removeValue(forKey: "ClassAxis"), ser = dims.removeValue(forKey: "LegalEntityAxis")
            return XBRLFact(name: r.name, contextRef: r.ctx, value: r.value.trimmingCharacters(in: .whitespacesAndNewlines),
                            classMember: cls.map(Self.member), seriesMember: ser.map(Self.member), otherDims: dims,
                            start: c.start, end: c.end, instant: c.instant)
        }
    }
    private static func member(_ s: String) -> String {   // "nacc2:C000092055Member" -> "C000092055"
        let local = s.split(separator: ":").last.map(String.init) ?? s
        return local.hasSuffix("Member") ? String(local.dropLast(6)) : local
    }
    private func local(_ n: String) -> String { n.split(separator: ":").last.map(String.init) ?? n }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        text = ""
        switch local(name) {
        case "context": curCtxId = a["id"]; cur = Ctx()
        case "explicitMember": curDim = a["dimension"].map(local)
        default:
            if curCtxId == nil, let ctx = a["contextRef"], name.contains(":") { curFact = (name, ctx) }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch local(name) {
        case "context": if let id = curCtxId { contexts[id] = cur }; curCtxId = nil
        case "startDate": cur.start = t
        case "endDate": cur.end = t
        case "instant": cur.instant = t
        case "explicitMember": if let d = curDim { cur.dims[d] = t }; curDim = nil
        default:
            if let f = curFact, f.name == name { raw.append((f.name, f.ctx, t)); curFact = nil }
        }
    }
}

nonisolated final class NPortParser: NSObject, XMLParserDelegate {
    private var rep = NPortReport(seriesId: "", seriesName: "", periodDate: "", netAssets: 0, holdings: [], monthlyReturns: [:],
                                  source: SourceRef(name: "", url: "", asOf: nil, fetchedAt: .now))
    private var path: [String] = [], text = ""
    private var h: [String: String] = [:], inHolding = false

    static func parse(_ data: Data) -> NPortReport? {
        let p = NPortParser(); let x = XMLParser(data: data); x.delegate = p
        guard x.parse() || !p.rep.holdings.isEmpty else { return nil }
        return p.rep
    }
    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        let n = e.split(separator: ":").last.map(String.init) ?? e
        path.append(n); text = ""
        if n == "invstOrSec" { inHolding = true; h = [:] }
        if inHolding, n == "isin", let v = a["value"] { h["isin"] = v }
        if inHolding, n == "ticker", let v = a["value"] { h["ticker"] = v }
        if n == "monthlyTotReturn", let c = a["classId"] {
            rep.monthlyReturns[c] = ["rtn1", "rtn2", "rtn3"].compactMap { a[$0].flatMap(Double.init) }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        let n = path.popLast() ?? ""
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inHolding {
            if n == "invstOrSec" {
                inHolding = false
                rep.holdings.append(FundHolding(name: h["name"] ?? "", title: h["title"] ?? "", cusip: h["cusip"] ?? "",
                                                isin: h["isin"], ticker: h["ticker"],
                                                weight: (Double(h["pctVal"] ?? "") ?? 0) / 100,
                                                valueUSD: Double(h["valUSD"] ?? "") ?? 0,
                                                assetCategory: h["assetCat"] ?? h["assetConditional"] ?? "",
                                                issuerCategory: h["issuerCat"] ?? "", country: h["invCountry"] ?? ""))
            } else if !t.isEmpty, h[n] == nil { h[n] = t }
        } else {
            switch n {
            case "seriesId": rep.seriesId = t
            case "seriesName": rep.seriesName = t
            case "repPdDate": rep.periodDate = t
            case "netAssets": rep.netAssets = Double(t) ?? 0
            default: break
            }
        }
        text = ""
    }
}
