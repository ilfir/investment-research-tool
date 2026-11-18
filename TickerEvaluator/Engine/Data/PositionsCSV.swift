import Foundation

/// Reads a brokerage positions export (Fidelity "Portfolio_Positions_*.csv" layout first, any CSV with
/// Symbol/Ticker + Quantity/Shares and/or Current Value/Market Value columns as a fallback).
/// The Fidelity layout is from its public export format; confirm against your own file.
nonisolated enum PositionsCSV {
    struct Result: Sendable {
        var positions: [Position]
        var skipped: [String]          // rows not imported, with the reason
    }

    enum ImportError: Error, LocalizedError {
        case noHeader
        var errorDescription: String? { "Couldn't find a header row with a Symbol (or Ticker) column and a Quantity or Current Value column." }
    }

    static func parse(_ text: String) throws -> Result {
        let rows = records(text.replacingOccurrences(of: "\u{FEFF}", with: ""))
        guard let hi = rows.firstIndex(where: { r in
            let h = r.map(norm)
            return h.contains(where: symbolHeaders.contains) && (h.contains(where: qtyHeaders.contains) || h.contains(where: valueHeaders.contains))
        }) else { throw ImportError.noHeader }
        let header = rows[hi].map(norm)
        func col(_ names: Set<String>) -> Int? { header.firstIndex(where: names.contains) }
        let iSym = col(symbolHeaders)!, iQty = col(qtyHeaders), iVal = col(valueHeaders)
        let iAcct = col(["account name", "account", "account type"]), iDesc = col(["description", "name", "security description"])

        var out: [Position] = [], skipped: [String] = []
        for r in rows[(hi + 1)...] {
            func cell(_ i: Int?) -> String { i.flatMap { $0 < r.count ? r[$0].trimmingCharacters(in: .whitespaces) : nil } ?? "" }
            let rawSym = cell(iSym)
            if rawSym.isEmpty { continue }                                 // blank lines and footer text
            if r.count < 2 { continue }                                    // disclaimer paragraphs at the end of the file
            let desc = cell(iDesc)
            if rawSym.localizedCaseInsensitiveContains("pending") { skipped.append("\(rawSym): pending activity"); continue }
            if rawSym.hasSuffix("**") || desc.localizedCaseInsensitiveContains("money market") || desc.localizedCaseInsensitiveContains("cash reserves") {
                skipped.append("\(rawSym.replacingOccurrences(of: "*", with: "")): cash / money market"); continue
            }
            let sym = rawSym.replacingOccurrences(of: "*", with: "").uppercased()
            guard sym.range(of: #"^[A-Z][A-Z0-9.\-^]{0,9}$"#, options: .regularExpression) != nil else {
                skipped.append("\(rawSym): not a ticker (CUSIP or other identifier)"); continue
            }
            let qty = number(cell(iQty)), val = number(cell(iVal))
            guard (qty ?? 0) > 0 || (val ?? 0) > 0 else { skipped.append("\(sym): no quantity or value"); continue }
            out.append(Position(ticker: sym.replacingOccurrences(of: ".", with: "-"), shares: qty, amount: val, accountType: account(cell(iAcct))))
        }
        return Result(positions: out, skipped: skipped)
    }

    static let symbolHeaders: Set<String> = ["symbol", "ticker", "ticker symbol"]
    static let qtyHeaders: Set<String> = ["quantity", "shares", "qty"]
    static let valueHeaders: Set<String> = ["current value", "market value", "value", "current value ($)"]

    static func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// "$1,234.56", "(12.00)", "--", "n/a" → number or nil.
    static func number(_ s: String) -> Double? {
        var t = s.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespaces)
        var neg = false
        if t.hasPrefix("("), t.hasSuffix(")") { neg = true; t = String(t.dropFirst().dropLast()) }
        guard let v = Double(t) else { return nil }
        return neg ? -v : v
    }

    static func account(_ name: String) -> AccountType {
        let n = name.lowercased()
        if n.contains("roth") { return .rothIRA }
        if n.contains("401") || n.contains("403") || n.contains("netbenefits") { return .k401 }
        if n.contains("ira") || n.contains("rollover") || n.contains("sep") { return .traditionalIRA }
        if n.contains("hsa") || n.contains("529") { return .other }
        return .taxable                                                   // Individual, Joint, Brokerage, blank
    }

    /// RFC 4180-ish CSV: quoted fields, doubled quotes, CRLF or LF.
    static func records(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = Array(text).makeIterator()
        var pending: Character? = nil
        while let c = pending ?? it.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let n = it.next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } } else { quoted = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n", "\r": row.append(field); field = ""; rows.append(row); row = []
                default: field.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
