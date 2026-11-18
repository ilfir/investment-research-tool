import SwiftUI
import UniformTypeIdentifiers

/// What you already own. Edits are made on a draft and saved with "Save" (which re-scores the open report).
struct PositionsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [Position] = []
    @State private var selection = Set<Position.ID>()
    @State private var importing = false
    @State private var imported: PositionsCSV.Result?
    @State private var importError: String?
    @State private var importNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Divider()
            if draft.isEmpty {
                ContentUnavailableView {
                    Label("No positions yet", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Add what you own so the app can check your S&P 500 share, overlap, number of stocks and the 1% speculation cap.")
                } actions: {
                    HStack { Button("Add position", action: add); Button("Import CSV…") { importing = true } }
                }
                .frame(maxHeight: .infinity)
            } else {
                table
            }
            Divider()
            footer.padding(12)
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear { draft = model.positions }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            importFile(result)
        }
        .confirmationDialog("Import \(imported?.positions.count ?? 0) positions", isPresented: Binding(get: { imported != nil && !draft.isEmpty }, set: { if !$0 { imported = nil } })) {
            Button("Replace current list") { apply(replace: true) }
            Button("Add to current list") { apply(replace: false) }
            Button("Cancel", role: .cancel) { imported = nil }
        } message: {
            Text("A brokerage export is usually your whole account, so replacing is the normal choice.")
        }
        .alert("Couldn't import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
    }

    // MARK: Parts

    private var header: some View {
        let total = draft.compactMap(model.value(of:)).reduce(0, +)
        let sp = draft.filter { PortfolioRules.spTrackers.contains($0.ticker.uppercased()) }.compactMap(model.value(of:)).reduce(0, +)
        let floor = PortfolioRules.spFloor(age: model.profile.age)
        return HStack(alignment: .firstTextBaseline, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your positions").font(.title2.weight(.semibold))
                Text("Saved on this Mac only. Values use shares × latest close when possible.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            stat("Total", Fmt.usd(total))
            stat("S&P 500 trackers", total > 0 ? Fmt.pct(sp / total) : "—",
                 note: "floor \(Fmt.pct(floor, digits: 0))", ok: total > 0 ? sp / total >= floor : nil)
            stat("Positions", "\(draft.count)")
        }
    }

    private func stat(_ title: String, _ value: String, note: String? = nil, ok: Bool? = nil) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            if let note {
                HStack(spacing: 3) {
                    if let ok { Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ok ? Theme.good : Theme.warning) }
                    Text(note)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var table: some View {
        let total = draft.compactMap(model.value(of:)).reduce(0, +)
        return Table($draft, selection: $selection) {
            TableColumn("Ticker") { $p in
                TextField("Ticker", text: $p.ticker).textCase(.uppercase)
                    .onSubmit { Task { await model.refreshPrices(draft) } }
            }.width(min: 80, ideal: 90)
            TableColumn("Shares") { $p in
                TextField("—", value: $p.shares, format: .number.precision(.fractionLength(0...4))).multilineTextAlignment(.trailing)
                    .onSubmit { Task { await model.refreshPrices(draft) } }
            }.width(min: 80, ideal: 100)
            TableColumn("Value entered") { $p in
                TextField("—", value: $p.amount, format: .currency(code: "USD").precision(.fractionLength(0...2))).multilineTextAlignment(.trailing)
            }.width(min: 100, ideal: 120)
            TableColumn("Value now") { $p in
                let v = model.value(of: p)
                Text(v.map(Fmt.usd) ?? "—").monospacedDigit().foregroundStyle(v == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(priceHelp(p))
            }.width(min: 100, ideal: 120)
            TableColumn("Weight") { $p in
                Text(total > 0 ? (model.value(of: p).map { Fmt.pct($0 / total) } ?? "—") : "—").monospacedDigit()
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }.width(min: 60, ideal: 70)
            TableColumn("Account") { $p in
                Picker("Account", selection: $p.accountType) {
                    ForEach(AccountType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden()
            }.width(min: 120, ideal: 140)
        }
        .onDeleteCommand { draft.removeAll { selection.contains($0.id) }; selection = [] }
    }

    private var footer: some View {
        HStack {
            Button(action: add) { Label("Add", systemImage: "plus") }
            Button { draft.removeAll { selection.contains($0.id) }; selection = [] } label: { Label("Remove", systemImage: "minus") }
                .disabled(selection.isEmpty)
            Button("Import CSV…") { importing = true }
                .help("Fidelity “Portfolio Positions” export, or any CSV with Symbol and Quantity or Current Value columns")
            if let importNote { Text(importNote).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(importNote) }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") {
                Task { await model.savePositions(draft); dismiss() }
            }.keyboardShortcut(.defaultAction).disabled(draft == model.positions)
        }
    }

    // MARK: Actions

    private func add() {
        let p = Position(ticker: "")
        draft.append(p); selection = [p.id]
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let r = try PositionsCSV.parse(text)
            if r.positions.isEmpty { importError = "No positions found in \(url.lastPathComponent)."; return }
            imported = r
            if draft.isEmpty { apply(replace: true) }
        } catch { importError = error.localizedDescription }
    }

    private func apply(replace: Bool) {
        guard let r = imported else { return }
        draft = replace ? r.positions : draft + r.positions
        importNote = "Imported \(r.positions.count)." + (r.skipped.isEmpty ? "" : " Skipped \(r.skipped.count): " + r.skipped.joined(separator: "; "))
        imported = nil
        Task { await model.refreshPrices(draft) }
    }

    private func priceHelp(_ p: Position) -> String {
        if let s = p.shares, let px = model.prices[p.ticker.uppercased()], s > 0 {
            return "\(Fmt.grouped(s)) shares × \(Fmt.usd(px)) latest close (Yahoo Finance)"
        }
        return p.amount != nil ? "Value you entered (no price found for the shares)" : "Enter shares or a value"
    }
}
