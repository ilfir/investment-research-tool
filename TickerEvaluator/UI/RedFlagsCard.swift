import SwiftUI

/// Your checklist's section F ("red flags that should stop you before you buy"), each tied to the rule that checks it.
struct RedFlagsCard: View {
    var r: EvaluationReport

    struct Item: Identifiable {
        var id: String { title }
        var title: String
        var ruleIDs: [String]
        var manual: String? = nil          // shown when no rule can check it automatically
        var clearIfMissing: String? = nil  // text when the rule doesn't apply because the flag is absent
    }

    private var items: [Item] {
        switch r.assetType {
        case .stock:
            return [
                Item(title: "Debt exceeds cash (debt is the \"silent killer\")", ruleIDs: ["S1"]),
                Item(title: "Burning cash (negative free cash flow)", ruleIDs: ["B1"]),
                Item(title: "Heavy debt load", ruleIDs: ["B2", "B3"]),
                Item(title: "Shareholders being diluted", ruleIDs: ["B4"]),
                Item(title: "Price gone parabolic", ruleIDs: ["A1"]),
                Item(title: "Duplicates what you already own", ruleIDs: ["P4"], clearIfMissing: "add your positions to check"),
                Item(title: "Guaranteed returns or urgency language (\"act before…\")", ruleIDs: [], manual: "Can't be checked automatically: ignore any pitch, newsletter or post that promises returns or pushes urgency."),
            ]
        case .crypto, .cryptoETF, .leveragedOrInverse:
            return [
                Item(title: "Leveraged or inverse structure held long term", ruleIDs: ["R1"], clearIfMissing: "not leveraged or inverse"),
                Item(title: "More than 1% of your portfolio in speculation", ruleIDs: ["P3"], clearIfMissing: "add your positions to check"),
                Item(title: "Price gone parabolic", ruleIDs: ["A1"]),
                Item(title: "Fund under $100m or younger than 3 years", ruleIDs: ["F5", "F6"]),
                Item(title: "Guaranteed returns or urgency language", ruleIDs: [], manual: "Can't be checked automatically: be most wary of this with crypto."),
            ]
        default:
            return [
                Item(title: "Fund under ~$100m or younger than ~3 years", ruleIDs: ["F5", "F6"]),
                Item(title: "Thin trading or a wide bid/ask spread", ruleIDs: ["F7", "F8"]),
                Item(title: "Synthetic replication you don't fully understand", ruleIDs: ["R2"]),
                Item(title: "Fees well above the cheapest equivalent exposure", ruleIDs: ["F1", "F11"]),
                Item(title: "Yield you can't trace to dividends or interest paid", ruleIDs: ["R3", "D3"]),
                Item(title: "Leveraged or inverse structure held long term", ruleIDs: ["R1"], clearIfMissing: "not leveraged or inverse"),
                Item(title: "Duplicates what you already own (same top 10)", ruleIDs: ["P4"], clearIfMissing: "add your positions to check"),
                Item(title: "Guaranteed or \"average\" returns, urgency language", ruleIDs: [], manual: "Can't be checked automatically: check the fund's own marketing and anyone pitching it."),
                Item(title: "Tax or domicile claims no official source confirms", ruleIDs: ["F14"]),
            ]
        }
    }

    /// Worst status among the item's rules (fail > warn > pass > n/a).
    private func status(_ item: Item) -> (RuleStatus, String) {
        if let m = item.manual { return (.na, m) }
        let rules = r.rules.filter { item.ruleIDs.contains($0.id) }
        if rules.isEmpty { return item.clearIfMissing.map { ($0.hasPrefix("add") ? .na : .pass, $0) } ?? (.na, "no data") }
        let order: [RuleStatus] = [.fail, .warn, .unconfirmed, .pass, .na]
        let worst = rules.min { order.firstIndex(of: $0.status)! < order.firstIndex(of: $1.status)! }!
        if item.ruleIDs == ["F14"], worst.status == .na { return (.pass, "US-domiciled fund in US dollars: no foreign withholding or domicile claims to verify") }
        let shown = rules.filter { $0.status == worst.status }
        return (worst.status, shown.map { "\($0.title): \($0.actual)" }.joined(separator: " · "))
    }

    var body: some View {
        let rows = items.map { ($0, status($0)) }
        let found = rows.filter { $0.1.0 == .fail }.count, watch = rows.filter { $0.1.0 == .warn }.count
        Card(title: "Red flags", subtitle: summary(found, watch)) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows, id: \.0.id) { item, st in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: icon(st.0)).foregroundStyle(color(st.0)).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).fontWeight(st.0 == .fail ? .semibold : .regular)
                            Text(st.1).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text(st.1.hasPrefix("add your positions") ? "Needs positions" : label(st.0)).font(.caption.weight(.medium)).foregroundStyle(color(st.0))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func summary(_ found: Int, _ watch: Int) -> String {
        if found == 0 && watch == 0 { return "None found in what could be checked. From your checklist, section F." }
        var parts: [String] = []
        if found > 0 { parts.append("\(found) found") }
        if watch > 0 { parts.append("\(watch) to look into") }
        return parts.joined(separator: ", ") + ". From your checklist, section F."
    }
    private func icon(_ s: RuleStatus) -> String {
        switch s { case .fail: "flag.fill"; case .warn: "exclamationmark.triangle.fill"; case .pass: "checkmark.circle"; default: "minus.circle" }
    }
    private func color(_ s: RuleStatus) -> Color {
        switch s { case .fail: Theme.critical; case .warn: Theme.warning; case .pass: Theme.good; default: .secondary }
    }
    private func label(_ s: RuleStatus) -> String {
        switch s { case .fail: "Red flag"; case .warn: "Look into"; case .pass: "Clear"; default: "Check yourself" }
    }
}
