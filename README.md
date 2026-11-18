# investment-research-tool

**Ticker Evaluator**: a macOS app (SwiftUI) that takes a US ticker and says whether it's worth buying instead of the S&P 500 total return, using Tom Nash's rules as the rulebook. Every number shows its source, link and as-of date. Educational tool, not financial advice.

## Build and run

Requires Xcode 26+ (macOS 26). The project is generated from `project.yml`:

```bash
brew install xcodegen      # once
xcodegen generate          # after adding or removing files
xcodebuild -project TickerEvaluator.xcodeproj -scheme TickerEvaluator -derivedDataPath build test
open build/Build/Products/Debug/TickerEvaluator.app
```

Command-line mode (no window):

```bash
build/Build/Products/Debug/TickerEvaluator.app/Contents/MacOS/TickerEvaluator --evaluate VOO [--age N] [--amount USD] [--pdf out.pdf] [--snapshot out.png]
```

## Layout

- `TickerEvaluator/Engine`: data clients (SEC EDGAR, Yahoo, FRED/Treasury, CoinGecko — all keyless), SQLite store, metrics, rules, verdict.
- `TickerEvaluator/UI`: report, profile, positions (with CSV import), export.
- `TickerEvaluatorTests`: Swift Testing suite; `Fixtures/` holds recorded responses so tests run offline. Live tests run with `TE_LIVE=1`.
- `PLAN.md`: decisions, rules, verdict mapping and build status.
- `tools/`: icon generator and a PDF page-preview helper.
