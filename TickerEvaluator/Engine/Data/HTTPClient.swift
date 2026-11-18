import Foundation

/// How bytes are obtained. Live uses URLSession; tests replay recorded fixtures.
protocol Transport: Sendable {
    func get(_ request: URLRequest) async throws -> (Data, Int)
}

struct LiveTransport: Transport {
    let session: URLSession
    init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = .shared                // app's own cookie jar (holds the Yahoo session cookie)
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
    }
    func get(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, resp) = try await session.data(for: request)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Replays files from a fixture directory. File name = FixtureName.for(url).
struct FixtureTransport: Transport {
    let directory: URL
    func get(_ request: URLRequest) async throws -> (Data, Int) {
        let url = request.url!.absoluteString
        let file = directory.appending(path: FixtureName.for(url))
        guard let data = try? Data(contentsOf: file) else {
            throw EngineError.notFound("fixture \(FixtureName.for(url)) for \(url)")
        }
        return (try FixtureName.inflate(data), 200)
    }
}

/// Wraps a live transport and writes every successful response to a fixture directory.
struct RecordingTransport: Transport {
    let inner: Transport
    let directory: URL
    func get(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, code) = try await inner.get(request)
        if code == 200, let url = request.url?.absoluteString, !url.contains("getcrumb"), !url.contains("fc.yahoo.com") {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FixtureName.deflate(data).write(to: directory.appending(path: FixtureName.for(url)))
        }
        return (data, code)
    }
}

enum FixtureName {
    /// Stable, filesystem-safe name: host + readable path + short hash of the full URL.
    static func `for`(_ url: String) -> String {
        let comps = URLComponents(string: url)
        let host = comps?.host ?? "x"
        let tail = (comps?.path ?? "").split(separator: "/").suffix(2).joined(separator: "_")
        let safe = (host + "_" + tail).map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" ? $0 : "_" }
        let crumbless = url.replacingOccurrences(of: #"&crumb=[^&]*"#, with: "", options: .regularExpression)
        var h: UInt64 = 14695981039346656037
        for b in crumbless.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(String(safe).prefix(90)) + "-" + String(h, radix: 36) + ".lzfse"
    }

    static func deflate(_ d: Data) throws -> Data { try (d as NSData).compressed(using: .lzfse) as Data }
    static func inflate(_ d: Data) throws -> Data { try (d as NSData).decompressed(using: .lzfse) as Data }
}

/// Shared HTTP client: per-host User-Agent, SEC rate limiting, SQLite response cache.
actor HTTPClient {
    /// Fixed identifier approved for SEC requests (SEC fair-access policy requires name + contact).
    static let defaultSECContact = "contact@example.com"
    private let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    let transport: Transport
    let store: Store?
    var secContact: String
    private var lastSECRequest = Date.distantPast
    /// "Fetch fresh": cached copies saved before this moment are ignored (except permanent filing documents).
    /// Anything fetched after it is reused, so one fresh run doesn't download the same URL twice.
    private(set) var freshSince: Date?
    static let permanentAge: TimeInterval = 300 * 24 * 3600

    /// How long prices / fundamentals / filing lists (anything requested with `Cache.session`) are reused. Set in Settings.
    private(set) var sessionReuse: TimeInterval = Cache.session

    func fetchFresh(from date: Date = .now) { freshSince = date }
    func setSessionReuse(_ seconds: TimeInterval) { sessionReuse = max(1, seconds) }
    func setSECContact(_ contact: String) { secContact = contact }

    private func effectiveMaxAge(_ maxAge: TimeInterval) -> TimeInterval {
        let m = maxAge == Cache.session ? sessionReuse : maxAge
        guard let f = freshSince, m < Self.permanentAge else { return m }
        return min(m, max(0.001, Date.now.timeIntervalSince(f)))
    }
    private let secMinInterval: TimeInterval = 0.15   // ≈ 6–7 req/s, under SEC's 10 req/s limit

    init(transport: Transport = LiveTransport(), store: Store?, secContact: String = HTTPClient.defaultSECContact) {
        self.transport = transport; self.store = store; self.secContact = secContact
    }

    var secUserAgent: String { "TickerEvaluator/1.0 (personal research tool; \(secContact))" }

    struct Response: Sendable { let data: Data; let fetchedAt: Date; let url: String; let fromCache: Bool }

    /// - Parameter maxAge: how long a cached copy is acceptable (0 = always refetch).
    func get(_ url: String, maxAge: TimeInterval, cacheKey: String? = nil) async throws -> Response {
        let key = cacheKey ?? url
        if maxAge > 0, let store, let (data, at) = await store.cached(url: key, maxAge: effectiveMaxAge(maxAge)) {
            return Response(data: data, fetchedAt: at, url: url, fromCache: true)
        }
        guard let u = URL(string: url) else { throw EngineError.parse("bad URL \(url)") }
        var req = URLRequest(url: u)
        let host = u.host ?? ""
        if host.hasSuffix("sec.gov") {
            req.setValue(secUserAgent, forHTTPHeaderField: "User-Agent")
            let wait = secMinInterval - Date.now.timeIntervalSince(lastSECRequest)
            if wait > 0, !(transport is FixtureTransport) { try await Task.sleep(for: .seconds(wait)) }
            lastSECRequest = .now
        } else {
            req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        }
        var (data, code) = try await transport.get(req)
        if code == 429 || code == 503 {               // back off once
            try await Task.sleep(for: .seconds(2))
            (data, code) = try await transport.get(req)
        }
        guard code == 200 else { throw EngineError.badResponse(url, code) }
        let now = Date.now
        if let store, maxAge > 0 { await store.putCache(url: key, body: data, fetchedAt: now) }
        return Response(data: data, fetchedAt: now, url: url, fromCache: false)
    }

    func cachedResponse(_ key: String, url: String, maxAge: TimeInterval) async -> Response? {
        guard let store, let (data, at) = await store.cached(url: key, maxAge: effectiveMaxAge(maxAge)) else { return nil }
        return Response(data: data, fetchedAt: at, url: url, fromCache: true)
    }

    nonisolated func json(_ url: String, maxAge: TimeInterval, cacheKey: String? = nil) async throws -> (Any, Response) {
        let r = try await get(url, maxAge: maxAge, cacheKey: cacheKey)
        guard let obj = try? JSONSerialization.jsonObject(with: r.data) else { throw EngineError.parse("JSON from \(url)") }
        return (obj, r)
    }
}

/// Small helpers for walking untyped JSON.
nonisolated extension Dictionary where Key == String, Value == Any {
    func dict(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
    func arr(_ k: String) -> [Any]? { self[k] as? [Any] }
    func str(_ k: String) -> String? { self[k] as? String }
    func num(_ k: String) -> Double? { (self[k] as? NSNumber)?.doubleValue }
    /// Yahoo style {"raw": 1.2, "fmt": "1.2"}
    func raw(_ k: String) -> Double? { dict(k)?.num("raw") ?? num(k) }
}

enum Cache {
    static let hour: TimeInterval = 3600
    /// Prices, fundamentals and filing lists are reused for 15 minutes by default (adjustable in Settings) so you can
    /// switch between tickers quickly; after that they're downloaded again (changed 2026-11-17 from 6 h / 24 h).
    static let session: TimeInterval = 15 * 60
    static let prices: TimeInterval = session
    static let fundamentals: TimeInterval = session
    static let filings: TimeInterval = 7 * 24 * hour
    static let tickerMaps: TimeInterval = 7 * 24 * hour
}
