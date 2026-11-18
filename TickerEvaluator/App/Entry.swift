import Foundation
import SwiftUI
import AppKit

/// Launch modes:
///   TickerEvaluator                          → the app window
///   TickerEvaluator --evaluate VOO [options] → prints a Markdown report to stdout (engine check, no UI)
///     --age N  --amount USD  --position TICKER=USD (repeatable)  --record DIR (save responses as test fixtures)  --replay DIR (offline from fixtures)
///     --no-cache  --fresh (ignore saved downloads, keep saving)  --asof YYYY-MM-DD  --snapshot out.png [--dark] (render the report screen to an image)  --pdf out.pdf
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--evaluate"), i + 1 < args.count else {
            TickerEvaluatorApp.main(); return
        }
        // Run a hidden AppKit run loop so the main actor (and SwiftUI rendering for --snapshot) works.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task.detached { exit(await CLI.run(ticker: args[i + 1], args: args)) }
        app.run()
    }
}

enum CLI {
    static func value(_ args: [String], _ flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    static func run(ticker: String, args: [String]) async -> Int32 {
        do {
            let transport: Transport
            if let dir = value(args, "--replay") { transport = FixtureTransport(directory: URL(fileURLWithPath: dir)) }
            else if let dir = value(args, "--record") { transport = RecordingTransport(inner: LiveTransport(), directory: URL(fileURLWithPath: dir)) }
            else { transport = LiveTransport() }
            let useCache = !args.contains("--no-cache") && value(args, "--replay") == nil && value(args, "--record") == nil
            let store = useCache ? try Store() : nil
            let http = HTTPClient(transport: transport, store: store)
            if let store {                                     // same Settings as the app (reuse time, SEC contact)
                if let m = await store.setting(AppModel.reuseKey).flatMap(Int.init) {
                    if m == 0 { await http.fetchFresh() } else { await http.setSessionReuse(TimeInterval(m * 60)) }
                }
                if let c = await store.setting(AppModel.secContactKey), !c.isEmpty { await http.setSECContact(c) }
            }
            if args.contains("--fresh") { await http.fetchFresh() }
            var req = EvaluationRequest(ticker: ticker)
            if let a = value(args, "--age").flatMap(Int.init) { req.profile.age = a }
            if let a = value(args, "--amount").flatMap(Double.init) { req.profile.plannedAmount = a }
            if let d = value(args, "--asof").flatMap(DateParse.ymd) { req.asOf = d }
            // --position TICKER=USD (repeatable) evaluates against these instead of your saved positions.
            let given = args.indices.filter { args[$0] == "--position" && $0 + 1 < args.count }.compactMap { i -> Position? in
                let parts = args[i + 1].split(separator: "=")
                guard parts.count == 2, let v = Double(parts[1]) else { return nil }
                return Position(ticker: String(parts[0]).uppercased(), amount: v)
            }
            if !given.isEmpty { req.positions = given } else if let store { req.positions = await store.positions() }
            let report = try await Evaluator(http: http, store: store).evaluate(req) { msg in
                FileHandle.standardError.write(Data("… \(msg)\n".utf8))
            }
            if let pdf = value(args, "--pdf") {
                try await Exporter.pdf(report, to: URL(fileURLWithPath: pdf))
                FileHandle.standardError.write(Data("Wrote \(pdf)\n".utf8))
            } else if let png = value(args, "--snapshot") {
                try await Snapshot.render(report, to: URL(fileURLWithPath: png), dark: args.contains("--dark"))
                FileHandle.standardError.write(Data("Wrote \(png)\n".utf8))
            } else {
                print(MarkdownReport.render(report))
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
