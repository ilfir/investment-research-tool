import SwiftUI

/// App settings (⌘,). Saved in the local SQLite store.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var contactDraft = ""
    @State private var cache: (count: Int, bytes: Int) = (0, 0)
    @State private var confirmClear = false

    static let reuseChoices = [0, 5, 15, 30, 60, 360, 1440]

    var body: some View {
        Form {
            Section {
                Picker("Reuse downloaded data for", selection: $model.reuseMinutes) {
                    ForEach(Self.reuseChoices, id: \.self) { m in Text(label(m)).tag(m) }
                }
                .onChange(of: model.reuseMinutes) { Task { await model.saveSettings() } }
                Text("Prices, company financials, fund data and SEC filing lists are reused for this long, so switching back and forth between tickers is quick. Ticker lists (7 days) and filed documents (they never change) are kept longer. “Fetch fresh” (⌘R) always downloads again.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LabeledContent("Saved downloads") {
                    HStack {
                        Text("\(cache.count) files · \(ByteCountFormatter.string(fromByteCount: Int64(cache.bytes), countStyle: .file))")
                            .foregroundStyle(.secondary).monospacedDigit()
                        Button("Clear…") { confirmClear = true }.disabled(cache.count == 0)
                    }
                }
            } header: { Text("Data") }

            Section {
                TextField("Contact email", text: $contactDraft, prompt: Text("you@example.com"))
                    .onSubmit(saveContact)
                HStack {
                    Text("SEC asks every automated client to identify itself. Sent only to sec.gov as “TickerEvaluator/1.0 (personal research tool; <this email>)”.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Save", action: saveContact).disabled(!validContact || contactDraft == model.secContact)
                }
                if !contactDraft.isEmpty && !validContact {
                    Label("Enter a valid email address", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.warning)
                } else if model.secContact == HTTPClient.defaultSECContact {
                    Label("Still using the placeholder address", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("SEC EDGAR identification") }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            contactDraft = model.secContact == HTTPClient.defaultSECContact ? "" : model.secContact
            cache = await model.savedDownloads()
        }
        .confirmationDialog("Delete all saved downloads?", isPresented: $confirmClear) {
            Button("Delete", role: .destructive) { Task { await model.clearSavedDownloads(); cache = await model.savedDownloads() } }
        } message: {
            Text("The next evaluation downloads everything again. Your positions, profile and answers are kept.")
        }
    }

    private var validContact: Bool {
        contactDraft.range(of: #"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }

    private func saveContact() {
        guard validContact else { return }
        model.secContact = contactDraft
        Task { await model.saveSettings() }
    }

    private func label(_ m: Int) -> String {
        switch m {
        case 0: "Don't reuse (always download)"
        case 15: "15 minutes (default)"
        case ..<60: "\(m) minutes"
        case 60: "1 hour"
        case 1440: "1 day"
        default: "\(m / 60) hours"
        }
    }
}
