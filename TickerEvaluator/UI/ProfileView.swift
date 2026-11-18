import SwiftUI

/// "About you" inputs. Every field is optional; each one says which checks it feeds.
/// Changes are saved to SQLite and re-score the current report after a short pause.
struct ProfileView: View {
    @Bindable var model: AppModel

    static let drawdownChoices: [Double] = [0.10, 0.20, 0.30, 0.40, 0.50, 0.60]

    var body: some View {
        Form {
            Section {
                LabeledContent("Age") {
                    TextField("Age", value: $model.profile.age, format: .number, prompt: Text("not set"))
                        .multilineTextAlignment(.trailing).frame(width: 90).labelsHidden()
                }
                hint(floorHint)
                LabeledContent("Time horizon") {
                    HStack(spacing: 4) {
                        TextField("Years", value: $model.profile.horizonYears, format: .number, prompt: Text("not set"))
                            .multilineTextAlignment(.trailing).frame(width: 90).labelsHidden()
                        Text("yrs").foregroundStyle(.secondary)
                    }
                }
                hint("Under 5 years flags stock-heavy holdings (P9).")
            } header: { Text("You") }

            Section {
                LabeledContent("Planned amount") {
                    TextField("USD", value: $model.profile.plannedAmount, format: .currency(code: "USD").precision(.fractionLength(0)),
                              prompt: Text("not set"))
                        .multilineTextAlignment(.trailing).frame(width: 130).labelsHidden()
                }
                hint("Used for the S&P sleeve and speculation cap after this buy (P1, P3) and the fee-drag projection (default $10,000).")
                Picker("Account", selection: $model.profile.accountType) {
                    Text("Not set").tag(AccountType?.none)
                    ForEach(AccountType.allCases, id: \.self) { Text($0.rawValue).tag(AccountType?.some($0)) }
                }
                hint("Bond funds in a taxable account get a location note (P8).")
                Picker("Role in portfolio", selection: $model.profile.role) {
                    Text("Not set").tag(HoldingRole?.none)
                    ForEach(HoldingRole.allCases, id: \.self) { Text($0.rawValue).tag(HoldingRole?.some($0)) }
                }
                hint("Checked against the asset type (P7). “Speculation” counts toward the 1% cap (P3).")
                Picker("Drawdown you can hold", selection: $model.profile.maxDrawdownTolerance) {
                    Text("Not set").tag(Double?.none)
                    ForEach(Self.drawdownChoices, id: \.self) { Text("−\(Int(($0 * 100).rounded()))%").tag(Double?.some($0)) }
                }
                hint("Compared with the worst historical fall (P6). Decide now what you'll do at −20%, −30%, −40%.")
            } header: { Text("This purchase") }

            Section {
                HStack {
                    Text(model.busy ? "Re-scoring…" : (model.report == nil ? "Saved. Applies to your next evaluation." : "Saved. The report updates automatically."))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear all") { model.profile = InvestorProfile() }
                        .disabled(model.profile == InvestorProfile())
                }
            }
        }
        .formStyle(.grouped)
    }

    private var floorHint: String {
        let f = Fmt.pct(PortfolioRules.spFloor(age: model.profile.age), digits: 0)
        return model.profile.age == nil
            ? "Sets your S&P 500 floor (P1). Without an age the strictest floor, \(f), is used."
            : "Your S&P 500 floor is \(f) (40% under 50, 25% at 50–59, 30% at 60+)."
    }

    private func hint(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Compact summary for the top bar; click to open the profile panel.
struct ProfileSummaryButton: View {
    @Bindable var model: AppModel
    var body: some View {
        Button { model.showProfile.toggle() } label: {
            Label(summary, systemImage: "person.crop.circle")
        }
        .help("Your age, horizon, account, role and planned amount")
    }
    private var summary: String {
        let p = model.profile
        var parts: [String] = []
        if let a = p.age { parts.append("Age \(a)") }
        if let h = p.horizonYears { parts.append("\(h) yrs") }
        if let a = p.plannedAmount { parts.append(Fmt.usd(a)) }
        if let acct = p.accountType { parts.append(acct.rawValue) }
        return parts.isEmpty ? "Set up your profile" : parts.joined(separator: " · ")
    }
}
