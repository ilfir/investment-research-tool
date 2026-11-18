# Ticker Evaluator

A macOS app that takes a US ticker (a stock, ETF, mutual fund, bond fund or crypto) and tells you **whether it's worth buying instead of just buying the S&P 500**, and why. Tom Nash's rules are the rulebook. Every number shows where it came from, with a link and an as-of date.

> Educational tool, not financial advice. Past performance does not predict future returns.

- **Install:** see [INSTALL.md](INSTALL.md) (one command once Xcode is installed).
- **Data:** free, keyless public sources only (SEC EDGAR, Yahoo Finance, FRED, US Treasury, CoinGecko). Nothing is sent anywhere else, and everything you enter stays on your Mac.

---

## How to use

### 1. Evaluate a ticker
Type a ticker in the box at the top left (for example `VOO`, `SCHD`, `MSFT`, `BTC-USD`) and press **Return**. A panel covers the screen while data downloads, showing each step, and the report appears when it's done. If it takes too long or seems stuck, click **Cancel** (or press **Esc**): the lookup stops and the previous report stays on screen.

To check another ticker, just type it. Data downloaded in the last 15 minutes is reused, so switching back and forth is instant. **Fetch fresh** (⌘R) downloads everything again.

### 2. Read the report
From top to bottom:

| Section | What it tells you |
|---|---|
| **Verdict** | *Buy*, *Buy slowly (DCA)*, *Hold off*, *Avoid*, *Just buy the S&P 500 instead*, *Speculation (max 1%)*, or *Not evaluated* (REITs), with a confidence level and how it was worked out. |
| **Why** | The main reasons, each with its number and source. Click a source to open the filing or data page. |
| **Red flags** | Your checklist's "stop before you buy" list (fund size and age, thin trading, swap-based funds, fees, untraceable yield, leverage, duplicates, debt and dilution for stocks), each marked *Red flag*, *Look into*, *Clear* or *Check yourself*. |
| **Compared with the S&P 500** | Returns over 1, 3, 5 and 10 years; growth of $10,000; drawdowns; rolling 3- or 5-year excess return; risk table. Hover a chart to see values on a date. |
| **Fit with your portfolio** | Your S&P 500 share now and after this buy against your floor, your allocation, holdings you'd be doubling up on, stock count, the 1% speculation cap and the role. Needs your positions. |
| **Three-fund portfolio** | Nash's no-research mix (S&P 500 + Nasdaq + total US bond) for your age, next to your own mix. For comparison only. |
| **Scorecard** | Every rule with its status (Pass, Fail, Warning, Needs you, n/a), the actual value, the threshold and the evidence. |
| **Fund facts** (funds) | Fees, size, holdings, sectors, overlap with the S&P 500 and fee drag over 10, 20 and 30 years. Mutual funds add manager tenure and taxable distributions; crypto ETFs add the custodian. |
| **Dividends and yield** | Dividends per share and yield by year, trailing yield, 5-year dividend growth, and how many years it was raised. |
| **Financials** (stocks) | Ten years from SEC filings plus the balance sheet. |
| **Data quality** | Each key number from two sources, whether they agree, and anything stale or missing. |

### 3. Answer the judgement questions (stocks)
Three of Nash's steps need your judgement: **moat**, **top-tier CEO** and **recession-proof**. The app shows its suggestion and the evidence. Pick **✓ Yes** or **✗ No** next to each one. The verdict updates straight away, and your answers are remembered for that ticker. Until you answer, the best possible verdict is *Buy slowly*.

### 4. Set up your profile (optional)
Click the person button at the top right. Enter your age, time horizon, planned amount, account type, the role this holding would play, and how big a fall you can hold. Each field says which checks it affects. For example, age sets your S&P 500 floor: 40% under 50, 25% at 50–59, 30% at 60+. The open report re-scores as you type.

### 5. Add your positions (optional)
Click **Add positions** (or **Positions (n)**). Enter tickers with shares or a dollar value, or click **Import CSV…** and pick a Fidelity *Portfolio Positions* export (Accounts → Positions → Download). This turns on the portfolio checks: your S&P 500 share against your floor, overlap with what you own, the number of individual stocks, and the 1% speculation cap. Cash, pending activity and rows without a ticker are skipped, and the app lists them after the import.

### 6. Export
**Export** at the top saves the report as a **PDF** (US Letter) or **Markdown**.

### 7. Settings (⌘,)
- **Reuse downloaded data for:** default 15 minutes. Choose Off to always download.
- **SEC contact email:** SEC asks automated tools to identify themselves. It's sent only to sec.gov.
- **Saved downloads:** see how much is saved, and clear it.

### Where your data is kept
Everything is in `~/Library/Application Support/TickerEvaluator/store.sqlite`: saved downloads, your profile, positions, answers and settings. Delete that file to start over.

---

## Technical notes

### Build from source

```bash
xcodebuild -project TickerEvaluator.xcodeproj -scheme TickerEvaluator -derivedDataPath build test   # tests
./scripts/install.sh            # Release build → /Applications
```

The Xcode project is generated from `project.yml`. After adding or removing source files, run `xcodegen generate` (`brew install xcodegen`).

### Command-line mode (no window)

```bash
/Applications/TickerEvaluator.app/Contents/MacOS/TickerEvaluator --evaluate VOO [options]
```

| Option | Meaning |
|---|---|
| `--age N`, `--amount USD` | Profile values for this run |
| `--position TICKER=USD` | Use these positions instead of your saved ones (repeatable) |
| `--pdf out.pdf` / `--snapshot out.png [--dark]` | Write a PDF or an image instead of Markdown to stdout |
| `--fresh` | Ignore saved downloads (and save the new ones) |
| `--no-cache` | Don't read or write the local store at all |
| `--asof YYYY-MM-DD` | Evaluate as of a past date |
| `--record DIR` / `--replay DIR` | Save responses as test fixtures, or run offline from them |

### Layout
- `TickerEvaluator/Engine`: data clients, SQLite store, metrics, rules, verdict, Markdown report.
- `TickerEvaluator/UI`: report, profile, positions (CSV import), export, settings.
- `TickerEvaluatorTests`: Swift Testing suite. `Fixtures/` holds recorded responses so the tests run offline. Live tests run with `TE_LIVE=1`.
- `PLAN.md`: decisions, rule tables, verdict mapping and build status.
- `scripts/install.sh`: build and install. `tools/`: icon generator and a PDF page-preview helper.
