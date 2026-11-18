import Foundation
import SQLite3

/// Local SQLite store: raw HTTP responses (cache), every data point used in a report
/// (value + source URL + as-of date), and saved positions.
/// Location: ~/Library/Application Support/TickerEvaluator/store.sqlite
actor Store {
    nonisolated(unsafe) private var db: OpaquePointer?

    static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "TickerEvaluator", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "store.sqlite")
    }

    /// Pass ":memory:" for tests.
    init(path: String = Store.defaultURL().path) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw EngineError.parse("cannot open SQLite at \(path)")
        }
        db = handle
        let schema = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS http_cache(
            url TEXT PRIMARY KEY, body BLOB NOT NULL, fetched_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS data_points(
            ticker TEXT NOT NULL, key TEXT NOT NULL, label TEXT, value REAL NOT NULL, unit TEXT,
            source TEXT, url TEXT, as_of REAL, fetched_at REAL NOT NULL, note TEXT,
            PRIMARY KEY(ticker, key, source));
        CREATE TABLE IF NOT EXISTS positions(
            id TEXT PRIMARY KEY, ticker TEXT NOT NULL, shares REAL, amount REAL, account_type TEXT);
        CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT);
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            throw EngineError.parse("schema: \(String(cString: sqlite3_errmsg(handle)))")
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: HTTP cache

    func cached(url: String, maxAge: TimeInterval) -> (Data, Date)? {
        query("SELECT body, fetched_at FROM http_cache WHERE url = ?", [.text(url)]) { st in
            let n = Int(sqlite3_column_bytes(st, 0))
            let data = n > 0 ? Data(bytes: sqlite3_column_blob(st, 0), count: n) : Data()
            return (data, Date(timeIntervalSince1970: sqlite3_column_double(st, 1)))
        }.first.flatMap { Date.now.timeIntervalSince($0.1) <= maxAge ? $0 : nil }
    }

    func putCache(url: String, body: Data, fetchedAt: Date) {
        exec("INSERT OR REPLACE INTO http_cache(url, body, fetched_at) VALUES(?,?,?)",
             [.text(url), .blob(body), .real(fetchedAt.timeIntervalSince1970)])
    }

    // MARK: Data points

    func save(_ points: [DataPoint], ticker: String) {
        exec("BEGIN", [])
        for p in points {
            exec("""
                 INSERT OR REPLACE INTO data_points(ticker,key,label,value,unit,source,url,as_of,fetched_at,note)
                 VALUES(?,?,?,?,?,?,?,?,?,?)
                 """,
                 [.text(ticker), .text(p.key), .text(p.label), .real(p.value), .text(p.unit.rawValue),
                  .text(p.source.name), .text(p.source.url),
                  p.source.asOf.map { .real($0.timeIntervalSince1970) } ?? .null,
                  .real(p.source.fetchedAt.timeIntervalSince1970), p.note.map { .text($0) } ?? .null])
        }
        exec("COMMIT", [])
    }

    func dataPoints(ticker: String) -> [DataPoint] {
        query("SELECT key,label,value,unit,source,url,as_of,fetched_at,note FROM data_points WHERE ticker = ?", [.text(ticker)]) { st in
            let asOf = sqlite3_column_type(st, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(st, 6))
            return DataPoint(key: Self.text(st, 0), label: Self.text(st, 1), value: sqlite3_column_double(st, 2),
                             unit: Unit(rawValue: Self.text(st, 3)) ?? .ratio,
                             source: SourceRef(name: Self.text(st, 4), url: Self.text(st, 5), asOf: asOf,
                                               fetchedAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 7))),
                             note: sqlite3_column_type(st, 8) == SQLITE_NULL ? nil : Self.text(st, 8))
        }
    }

    // MARK: Positions

    func positions() -> [Position] {
        query("SELECT id,ticker,shares,amount,account_type FROM positions ORDER BY ticker", []) { st in
            Position(id: UUID(uuidString: Self.text(st, 0)) ?? UUID(), ticker: Self.text(st, 1),
                     shares: sqlite3_column_type(st, 2) == SQLITE_NULL ? nil : sqlite3_column_double(st, 2),
                     amount: sqlite3_column_type(st, 3) == SQLITE_NULL ? nil : sqlite3_column_double(st, 3),
                     accountType: AccountType(rawValue: Self.text(st, 4)) ?? .taxable)
        }
    }

    func replacePositions(_ list: [Position]) {
        exec("BEGIN", []); exec("DELETE FROM positions", [])
        for p in list {
            exec("INSERT INTO positions(id,ticker,shares,amount,account_type) VALUES(?,?,?,?,?)",
                 [.text(p.id.uuidString), .text(p.ticker.uppercased()),
                  p.shares.map { .real($0) } ?? .null, p.amount.map { .real($0) } ?? .null, .text(p.accountType.rawValue)])
        }
        exec("COMMIT", [])
    }

    // MARK: Settings

    func setting(_ key: String) -> String? {
        query("SELECT value FROM settings WHERE key = ?", [.text(key)]) { Self.text($0, 0) }.first
    }
    func setSetting(_ key: String, _ value: String) {
        exec("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)", [.text(key), .text(value)])
    }

    // MARK: SQLite plumbing

    private enum Arg { case text(String), real(Double), blob(Data), null }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func text(_ st: OpaquePointer?, _ i: Int32) -> String {
        sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""
    }

    private func prepare(_ sql: String, _ args: [Arg]) -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .text(let s): sqlite3_bind_text(st, idx, s, -1, Self.transient)
            case .real(let d): sqlite3_bind_double(st, idx, d)
            case .blob(let b): _ = b.withUnsafeBytes { sqlite3_bind_blob(st, idx, $0.baseAddress, Int32(b.count), Self.transient) }
            case .null: sqlite3_bind_null(st, idx)
            }
        }
        return st
    }

    private func exec(_ sql: String, _ args: [Arg]) {
        guard let st = prepare(sql, args) else { return }
        sqlite3_step(st); sqlite3_finalize(st)
    }

    private func query<T>(_ sql: String, _ args: [Arg], _ row: (OpaquePointer?) -> T) -> [T] {
        guard let st = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(st) }
        var out: [T] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(row(st)) }
        return out
    }
}
