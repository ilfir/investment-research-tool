import SwiftUI
import AppKit

/// Colours from the validated reference palette (dataviz skill), each with its own dark-mode step.
enum Theme {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { app in
            let hex = app.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
    // Categorical: slot 1 = the ticker, slot 2 = the S&P 500 benchmark.
    static let asset = dynamic(0x2a78d6, 0x3987e5)
    static let benchmark = dynamic(0xeb6834, 0xd95926)
    // Diverging poles (above / below the S&P), neutral gray midpoint.
    static let positive = dynamic(0x2a78d6, 0x3987e5)
    static let negative = dynamic(0xe34948, 0xe66767)
    static let neutral = dynamic(0xf0efec, 0x383835)
    // Status (reserved; always shown with an icon + label).
    static let good = dynamic(0x0ca30c, 0x0ca30c)
    static let warning = dynamic(0xfab219, 0xfab219)
    static let serious = dynamic(0xec835a, 0xec835a)
    static let critical = dynamic(0xd03b3b, 0xd03b3b)

    static let card = Color(nsColor: .controlBackgroundColor)
    static let grid = Color.secondary.opacity(0.25)

    static func color(_ s: RuleStatus) -> Color {
        switch s { case .pass: good; case .fail: critical; case .warn: warning; case .unconfirmed: serious; case .na: .secondary }
    }
    static func icon(_ s: RuleStatus) -> String {
        switch s {
        case .pass: "checkmark.circle.fill"; case .fail: "xmark.octagon.fill"; case .warn: "exclamationmark.triangle.fill"
        case .unconfirmed: "questionmark.circle.fill"; case .na: "minus.circle"
        }
    }
    static func label(_ s: RuleStatus) -> String {
        switch s { case .pass: "Pass"; case .fail: "Fail"; case .warn: "Warning"; case .unconfirmed: "Needs you"; case .na: "n/a" }
    }

    static func verdictColor(_ v: Verdict) -> Color {
        switch v {
        case .buy: good; case .buySlowly: dynamic(0x1baf7a, 0x199e70); case .holdOff: warning; case .avoid: critical
        case .justBuySP: asset; case .speculation: dynamic(0x6250d6, 0x9085e9); case .notEvaluated: .secondary
        }
    }
    static func verdictIcon(_ v: Verdict) -> String {
        switch v {
        case .buy: "checkmark.seal.fill"; case .buySlowly: "tortoise.fill"; case .holdOff: "pause.circle.fill"
        case .avoid: "xmark.octagon.fill"; case .justBuySP: "arrow.uturn.right.circle.fill"
        case .speculation: "dice.fill"; case .notEvaluated: "eye.slash.circle.fill"
        }
    }
}

/// A titled card section.
struct Card<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.grid, lineWidth: 0.5))
    }
}

/// Small "where this number came from" marker: hover for source and date, click to open.
/// Drawn as plain text + tap handler (not Link) so it also renders in snapshots and PDF export.
struct SourceBadge: View {
    var source: SourceRef
    @Environment(\.openURL) private var openURL
    var body: some View {
        (Text(Image(systemName: "info.circle")) + Text(" \(source.name.replacingOccurrences(of: " (unofficial)", with: "")) · \(Fmt.date(source.asOf))"))
            .font(.caption).foregroundStyle(.secondary)
            .onTapGesture { if let u = URL(string: source.url) { openURL(u) } }
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            .help("\(source.name)\nAs of \(Fmt.date(source.asOf)), fetched \(Fmt.date(source.fetchedAt))\n\(source.url)\nClick to open")
    }
}

struct StatusChip: View {
    var status: RuleStatus
    var body: some View {
        Label(Theme.label(status), systemImage: Theme.icon(status))
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.color(status))
            .labelStyle(.titleAndIcon)
            .frame(width: 96, alignment: .leading)
    }
}

/// Two-series legend (identity never by colour alone: charts also label lines directly).
struct Legend: View {
    var items: [(String, Color)]
    var body: some View {
        HStack(spacing: 16) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1).fill(items[i].1).frame(width: 14, height: 3)
                    Text(items[i].0).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// True when rendering for PDF/snapshot: interactive controls are replaced by plain labels.
extension EnvironmentValues {
    @Entry var printMode = false
}
