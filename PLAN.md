# Ticker Evaluator: plan (draft for approval)

_Educational tool, not financial advice. Drafted 2026-11-17._

## 1. Decisions so far

| Topic | Decision |
|---|---|
| Platform | **SwiftUI + Swift Charts**, a single macOS app with no backend. The engine code lives in the app target. |
| Toolchain | Xcode 27.2, Swift 6.4, macOS 26 (arm64). Already installed. |
| Storage | **SQLite** (macOS built-in `libsqlite3`, no third-party packages) holds every fetched data point with its source URL and as-of date, plus your saved positions. There is no evaluation-history screen; each evaluation is one-shot. |
| Data | **Keyless only.** No API keys. |
| Rulebook | Tom Nash's rules decide the verdict. The measured evidence (overlap, rolling returns, etc.) is always displayed. |
| S&P floor | **By age:** 40% under 50, 25% at 50–59, 30% at 60+ (Nash's three-fund table). |
| Moat / CEO / recession-proof | The app suggests pass or fail with the evidence; **you confirm or override**. If any are unconfirmed, the best possible verdict is "Buy slowly". |
| REITs | No REIT module. REIT tickers get the S&P comparison only, with "REIT fundamentals not evaluated" and **no verdict**. |
| Defaults approved | Double the DCA on dips when fundamentals are intact · Morningstar 2025 gap only · Nash wins on QQQ/international · quarterly drift checks · fees under 0.20% (ideally under 0.10%) · revenue growth checked on the latest year **and** 3 years · cash + short-term investments vs debt excl. leases (leases shown as context; changed 2026-11-17) · parabolic rule on all assets · speculation = crypto + leveraged/inverse ETFs · crypto is always "speculation, max 1%" · valuation can only downgrade a verdict · only the 5 listed notes. |

## 2. Architecture (one app target, folders keep the engine apart from the UI)

```
TickerEvaluator/
  Engine/
    Data/        SEC, Yahoo, Treasury, FRED, CoinGecko, SSGA clients -> DataPoint(value, unit, source, url, asOf)
    Store/       SQLite (GRDB): data_points, positions, settings
    Classify/    ticker -> Stock | ETF | MutualFund | BondFund | Crypto | REIT(comparison only) | Leveraged/Inverse
    Metrics/     CAGR, drawdown/recovery, volatility, Sharpe, beta, correlation, up/down capture, rolling 3y/5y
    Rules/       StockScreen, EtfChecklist, MutualFundChecklist, BondFundChecklist, CryptoRules, PortfolioFit
    Verdict/     rule results -> verdict + confidence + "why" reasons (each reason linked to a DataPoint)
    Report/      Markdown + PDF export
  UI/            SwiftUI screens (Input/Profile, Positions, Report, Data Quality, Settings)
TickerEvaluatorTests/   Engine tests: VOO, SCHD, MSFT on recorded JSON fixtures + one opt-in live test
```

## 3. Data sources (checked live from this Mac on 2026-11-17)

| Data | Primary | Second source / fallback | Status |
|---|---|---|---|
| Ticker → CIK, fund series/class | SEC `company_tickers.json`, `company_tickers_mf.json` | Yahoo search | ✅ (SEC needs a "Name email" User-Agent) |
| Company financials (revenue, opex, op. margin, FCF, cash, debt, shares) | SEC `data.sec.gov/api/xbrl/companyfacts` | Recomputed from the 10-K/10-Q filing facts (frames API); Yahoo quoteSummary only if the crumb flow works | ✅ |
| Prices, dividends, splits (adjusted) | Yahoo `v8/finance/chart` (unofficial) | None keyless and reliable: **Stooq now blocks scripts** (JS challenge). Shown as single-source where needed | ✅ / ⚠️ unofficial |
| S&P 500 total-return benchmark | Yahoo `^SP500TR` | VOO adjusted closes (dividends reinvested) | ✅ |
| Risk-free rate | US Treasury daily bill rates CSV | FRED `fredgraph.csv?id=DGS3MO` (keyless) | ✅ both |
| Fund holdings (overlap) | SEC **N-PORT** filings (quarterly, ~60-day lag) | Issuer files: SSGA (SPY) XLSX ✅; iShares CSV needs the right URL ⚠️; Vanguard API ❌ | ✅ / partial |
| Fund fees, loads, 12b-1, turnover | SEC shareholder report (N-CSR/N-CSRS `oef:ExpenseRatioPct`, turnover, net assets) + prospectus (485BPOS fee table) | Yahoo quoteSummary fundProfile | ✅ built |
| Fund profile (AUM, inception, category) | SEC N-CSR / N-PORT (net assets) | Yahoo quoteSummary (works with the session-cookie + crumb flow) | ✅ built |
| Bid/ask spread, volume | Yahoo chart (volume) | Spread is **often unavailable** keyless; shown as "n/a" | partial |
| Crypto prices | CoinGecko keyless `market_chart` (365 days max keyless) | Yahoo `BTC-USD` for longer history | ✅ |

**What "keyless" costs you:**
- Yahoo is unofficial and can break, which is the main maintenance risk.
- Some numbers will only have **one source**. The two-source rule shows those as "single source" in the Data Quality panel instead of hiding them.
- Bid/ask spread and some fund-profile fields will often show "n/a".

## 4. Rule tables

### 4a. Stocks (Nash 7-step + extras)
| # | Rule | Threshold | Data |
|---|---|---|---|
| 1 | Cash > debt | cash + short-term investments > total debt excl. leases (leases shown, not counted) | 10-K/10-Q XBRL |
| 2 | Revenue growth | ≥ 10% latest YoY **and** ≥ 10% 3-yr CAGR | XBRL |
| 3 | Operating margin | ≥ 15% (FCF margin also shown) | XBRL |
| 4 | Revenue growth > opex growth | same periods as #2 | XBRL |
| 5 | Moat | **you confirm**. Evidence: margin level and stability over 10 yrs | XBRL |
| 6 | Top-tier CEO | **you confirm**. Evidence: tenure, filings links | SEC submissions |
| 7 | Recession-proof | **you confirm**. Evidence: revenue/margin in 2008, 2020, 2022 | XBRL |
| + | Debt/equity, interest coverage, dilution (3-yr share-count change) | shown; dilution > 2%/yr and coverage < 5x are red flags | XBRL |
| + | Valuation: P/E, P/FCF, EV/EBIT vs own 10-yr history and vs S&P | info only, can downgrade Buy → Buy slowly | XBRL + price |
| — | Analyst price targets | **never used** | — |

### 4b. ETFs / index funds
The 11 fact-sheet parameters (domicile, ACC/DIST and currency show "n/a (US-domiciled)"), plus:
- **Expense ratio:** under 0.20% passes; under 0.10% is ideal.
- **Tracking difference:** 3–5 yr return vs the index is shown.
- **AUM:** under $100M is a red flag.
- **Fund age:** under 3 years is a red flag.
- **Volume and spread:** low volume is a red flag.
- **Top-10 concentration:** shown.
- **Index methodology:** shown as a link.
- **Overlap with VOO and with your positions.** At ≥ 85% overlap with VOO and a higher fee, the verdict is **"Just buy the S&P 500"**.
- **Leveraged or inverse:** classed as speculation.

### 4c. Mutual funds
- Expense ratio: same limits as ETFs.
- Front or back load > 0 is a red flag.
- 12b-1 fee > 0 is a red flag.
- Minimum investment, turnover, manager tenure, capital-gains distributions (tax cost) and the after-fee return vs the index are shown.
- If it lags the index after fees, the verdict leans to "Just buy the S&P 500".

### 4d. Bond funds
- Shown: duration, average credit quality, SEC yield vs distribution yield (a large gap is a red flag) and expense ratio.
- Rate sensitivity: estimated price change for a 1% rate move.
- Compared with both **BND/AGG** and the S&P.

### 4e. Crypto
- Shown: volatility, drawdowns and correlation with the S&P.
- For spot ETFs, the fee and custodian are also shown.
- The verdict is always **"Speculation: max 1% of portfolio"**, with a check against your current crypto %.

### 4f. Every asset type: vs the S&P 500 (total return)
- CAGR over 1/3/5/10 years and since inception, plus a growth-of-$10k chart.
- Max drawdown, recovery time and a drawdown chart.
- Volatility, Sharpe, beta, correlation and up/down capture.
- Rolling 3- and 5-year windows: % of periods it beat the S&P.
- Dividend history and fee drag projected over 10/20/30 years.

### 4g. Portfolio fit (from saved positions)
- **S&P sleeve:** compared with the age floor; flagged if this purchase pushes it below.
- **Stock count:** 7–10 individual stocks is a warning; more than 10 fails.
- **Speculation:** more than 1% of the portfolio fails.
- Overlap and sector concentration are shown.
- The role you give the holding (core / satellite / income / hedge / speculation) is checked against its asset type.

### 4h. Price-action flags (all assets)
- **Up ≥ 20% in 30 days:** "Parabolic: slow DCA to 50% speed".
- **Down ≥ 15% from the 52-week high, with fundamentals passing:** "Fundamentals intact: Nash's rule is to double the DCA".

## 5. Proposed verdict mapping (please confirm)
| Verdict | When |
|---|---|
| **Avoid** | Any hard fail: debt rule fails, leveraged/inverse held as core, a red flag such as AUM < $100M with a load, or speculation cap breached |
| **Hold off** | Fails 1–2 of the numeric screen steps, or a judgement item you rated ✗ |
| **Just buy the S&P 500 instead** | Fund with ≥ 85% VOO overlap at a higher fee, or a fund lagging the S&P after fees over most rolling 5-yr windows (applies to all funds, whatever their overlap; confirmed 2026-11-17) |
| **Buy slowly (DCA)** | Passes, but is parabolic, has valuation stretched vs its own history, or has unconfirmed judgement items |
| **Buy** | Passes every applicable rule, with judgement items confirmed ✓ |

**Confidence (High / Medium / Low):** based on data quality, meaning the share of key numbers confirmed by two sources, data freshness, and how many rules returned n/a.

## 6. Open items

### Resolved (2026-11-17)
- **Verdict mapping and confidence (section 5):** approved as written.
- **Tests:** unit tests on recorded fixtures for VOO, SCHD and MSFT, plus one opt-in live test.
- **Distribution:** local build for your Mac only, with no App Store and no sandbox.

- **SEC User-Agent:** one fixed app identifier, `TickerEvaluator/1.0 (personal research tool; <contact email>)`. It is the same on every request, rate-limited to well under SEC's 10 requests per second, and responses are cached in SQLite.

### Still open
1. **Contact email for the SEC identifier.** Enter it in Settings (⌘,); until then the placeholder `contact@example.com` is sent.
2. **Fidelity CSV.** Waiting for a real export to confirm the column names. The importer already reads Fidelity's published layout and any CSV with Symbol/Ticker plus Quantity or Current Value.

## 7. Engine status (2026-11-17)
- Built: data clients (SEC, Yahoo, FRED, Treasury, CoinGecko), SQLite store, metrics, rules, verdict, Markdown export, and a CLI mode (`TickerEvaluator --evaluate VOO`).
- 28 unit tests pass on recorded fixtures (`TickerEvaluatorTests/Fixtures`, 2 MB). The live test is opt-in with `TE_LIVE=1`.
- Results are in `engine-check/VOO.md`, `SCHD.md` and `MSFT.md`.
- After adding or removing source files, run `xcodegen generate`.

## 8. Build order
1. Engine: data clients + SQLite store → metrics → rules → verdict, with tests. **I'll show you the VOO / SCHD / MSFT numbers before any UI.**
2. UI one screen at a time: Report → Input/Profile → Positions + CSV import → Data Quality → Export → Settings.
   - Done 2026-11-17: Report screen; Input/Profile (side panel from the top-bar button; saved in SQLite settings key `profile`; edits re-score the open report after 0.7 s); Positions (sheet from the top bar; manual table + CSV import in Fidelity layout, unverified until a real sample arrives; cash/money-market, pending and CUSIP-only rows skipped and listed; values = shares × latest close, entered value as fallback); Export (top-bar menu: vector PDF on US Letter with page header/footer, sections kept whole or split at blank bands; Markdown; CLI `--pdf out.pdf`); app icon (generated by tools/make-icon.swift); Settings window (⌘,): reuse downloaded data for N minutes (default 15; was 6 h prices / 24 h fundamentals), SEC contact email, clear saved downloads; "Fetch fresh" (⌘R, CLI `--fresh`); loading overlay that blocks the screen while a ticker loads.
   - Done 2026-11-17 (report gaps): dividend/yield history card; Fit with your portfolio card (PortfolioFit); Red flags card (checklist section F, new rules R2 synthetic replication from N-PORT derivatives, R3 quoted vs paid yield); Nash three-fund reference by age (bands read as ≤30, 31–39, 40–49, 50–59, 60+); mutual funds M1 manager tenure (Yahoo, earliest start) and M2 taxable distributions vs VOO's yield (Yahoo folds capital gains into mutual-fund dividends, so total payout is used); crypto ETFs K1 custodian (defined "Custodian" in the latest 10-K). README how-to + INSTALL.md + scripts/install.sh.
