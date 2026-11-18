import Foundation
import Observation

/// UI state for the app. The engine stays in Engine/; this only drives it.
@MainActor @Observable
final class AppModel {
    var ticker = ""
    var profile = InvestorProfile() {
        didSet { if profile != oldValue { profileChanged() } }
    }
    var showProfile = false
    var showPositions = false
    var positions: [Position] = []
    var prices: [String: Double] = [:]                    // latest close per ticker, for the Positions screen
    /// Settings (saved in SQLite settings). 0 = always download (still reused within one evaluation).
    var reuseMinutes = 15
    var secContact = HTTPClient.defaultSECContact
    static let reuseKey = "reuseMinutes", secContactKey = "secContact"
    var judgements: [String: JudgementAnswers] = [:]      // per ticker, saved in SQLite settings
    var report: EvaluationReport?
    var busy = false
    var progress = ""
    var error: String?

    @ObservationIgnored private var store: Store?
    @ObservationIgnored private var http: HTTPClient?
    @ObservationIgnored private var profileTask: Task<Void, Never>?
    @ObservationIgnored private var loadingProfile = false
    static let profileKey = "profile"

    init(store: Store? = nil, http: HTTPClient? = nil) {
        self.store = store ?? (try? Store())
        self.http = http ?? HTTPClient(store: self.store)
        Task { await loadSettings(); await loadProfile(); await loadPositions() }
    }

    func loadSettings() async {
        guard let store else { return }
        if let m = await store.setting(Self.reuseKey).flatMap(Int.init) { reuseMinutes = m }
        if let c = await store.setting(Self.secContactKey), !c.isEmpty { secContact = c }
        await applySettings()
    }

    func saveSettings() async {
        if let store {
            await store.setSetting(Self.reuseKey, String(reuseMinutes))
            await store.setSetting(Self.secContactKey, secContact)
        }
        await applySettings()
    }

    private func applySettings() async {
        await http?.setSessionReuse(TimeInterval(max(reuseMinutes, 1) * 60))
        await http?.setSECContact(secContact)
    }

    func savedDownloads() async -> (count: Int, bytes: Int) { await store?.httpCacheSize() ?? (0, 0) }
    func clearSavedDownloads() async { await store?.clearHTTPCache(); prices = [:] }

    func loadPositions() async {
        guard let store else { return }
        positions = await store.positions()
        await refreshPrices()
    }

    /// Saves the list (SQLite) and re-scores the open report against it.
    func savePositions(_ list: [Position]) async {
        let clean = list.filter { !$0.ticker.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { var p = $0; p.ticker = p.ticker.uppercased().trimmingCharacters(in: .whitespaces); return p }
        positions = clean
        if let store { await store.replacePositions(clean) }
        await refreshPrices()
        if let t = report?.ticker, !busy { await evaluate(t) }
    }

    func refreshPrices(_ list: [Position]? = nil) async {
        guard let http else { return }
        let y = YahooClient(http: http)
        for t in Set((list ?? positions).map { $0.ticker.uppercased() }) where prices[t] == nil && !t.isEmpty {
            if let c = try? await y.chart(t, asOf: .now).lastClose { prices[t] = c }
        }
    }

    /// Value used by the portfolio checks: shares × latest close, else the entered value.
    func value(of p: Position) -> Double? {
        if let s = p.shares, let px = prices[p.ticker.uppercased()], s > 0 { return s * px }
        return p.amount
    }

    /// Restores the saved profile (SQLite settings) without triggering a re-evaluation.
    func loadProfile() async {
        guard let store, let raw = await store.setting(Self.profileKey),
              let p = try? JSONDecoder().decode(InvestorProfile.self, from: Data(raw.utf8)) else { return }
        loadingProfile = true; profile = p; loadingProfile = false
    }

    /// Saves the profile and, after a short pause (so typing doesn't re-run on every key),
    /// re-scores the current report. Fetched data is cached, so this is quick.
    private func profileChanged() {
        guard !loadingProfile else { return }
        profileTask?.cancel()
        let p = profile
        profileTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled else { return }
            if let store = self.store, let data = try? JSONEncoder().encode(p) {
                await store.setSetting(Self.profileKey, String(decoding: data, as: UTF8.self))
            }
            if let t = self.report?.ticker, !self.busy { await self.evaluate(t) }
        }
    }

    /// For snapshots/previews: show an already-computed report.
    init(report: EvaluationReport) {
        self.report = report; self.ticker = report.ticker
        judgements[report.ticker] = report.request.judgements
    }

    /// - Parameter fresh: ignore saved downloads and fetch everything again (filed documents excepted).
    func evaluate(_ t: String? = nil, fresh: Bool = false) async {
        let sym = (t ?? ticker).uppercased().trimmingCharacters(in: .whitespaces)
        guard !sym.isEmpty, let http else { return }
        if fresh || reuseMinutes == 0 { await http.fetchFresh(); prices = [:]; await refreshPrices() }
        ticker = sym; busy = true; error = nil; progress = "Starting…"
        defer { busy = false; progress = "" }
        if judgements[sym] == nil, let store, let raw = await store.setting("judgement.\(sym)"),
           let j = try? JSONDecoder().decode(JudgementAnswers.self, from: Data(raw.utf8)) {
            judgements[sym] = j
        }
        var req = EvaluationRequest(ticker: sym, profile: profile, judgements: judgements[sym] ?? .init())
        if positions.isEmpty, let store { positions = await store.positions() }   // in case startup load hasn't finished
        req.positions = positions
        do {
            report = try await Evaluator(http: http, store: store).evaluate(req) { [weak self] msg in
                Task { @MainActor in self?.progress = msg }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Your answer to a judgement step (nil = clear). Re-scores using cached data.
    func setJudgement(_ id: String, _ value: Bool?) async {
        guard let r = report else { return }
        var j = judgements[r.ticker] ?? .init()
        switch id {
        case "S5": j.moat = value
        case "S6": j.topTierCEO = value
        case "S7": j.recessionProof = value
        default: return
        }
        judgements[r.ticker] = j
        if let store, let data = try? JSONEncoder().encode(j) {
            await store.setSetting("judgement.\(r.ticker)", String(decoding: data, as: UTF8.self))
        }
        await evaluate(r.ticker)
    }

    func answer(for id: String) -> Bool? {
        guard let r = report, let j = judgements[r.ticker] else { return nil }
        switch id { case "S5": return j.moat; case "S6": return j.topTierCEO; case "S7": return j.recessionProof; default: return nil }
    }
}
