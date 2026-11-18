import Foundation
import SwiftUI
import AppKit

/// Launch modes:
///   TickerEvaluator                          → the app window
///   TickerEvaluator --evaluate VOO [options] → prints a Markdown report to stdout (engine check, no UI)
///     --age N  --amount USD  --record DIR (save responses as test fixtures)  --replay DIR (offline from fixtures)
///     --no-cache  --asof YYYY-MM-DD  --snapshot out.png [--dark] (render the report screen to an image)  --pdf out.pdf
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
            var req = EvaluationRequest(ticker: ticker)
            if let a = value(args, "--age").flatMap(Int.init) { req.profile.age = a }
            if let a = value(args, "--amount").flatMap(Double.init) { req.profile.plannedAmount = a }
            if let d = value(args, "--asof").flatMap(DateParse.ymd) { req.asOf = d }
            if let store { req.positions = await store.positions() }
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
