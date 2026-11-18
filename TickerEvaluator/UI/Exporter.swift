import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Report export: vector PDF (US Letter, light appearance, sections kept whole where they fit) and Markdown.
enum Exporter {
    static let page = CGSize(width: 612, height: 792)         // US Letter, points
    static let margin: CGFloat = 36
    static let contentWidth: CGFloat = 820                     // layout width before scaling onto the page
    static let headerH: CGFloat = 18, footerH: CGFloat = 26

    static func fileName(_ r: EvaluationReport, ext: String) -> String {
        "\(r.ticker) evaluation \(Fmt.date(r.request.asOf)).\(ext)"
    }

    static func markdown(_ r: EvaluationReport, to url: URL) throws {
        try MarkdownReport.render(r).write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor
    static func pdf(_ r: EvaluationReport, to url: URL) throws {
        let scale = (page.width - 2 * margin) / contentWidth
        let bodyH = (page.height - 2 * margin - headerH - footerH) / scale   // usable height in layout points
        let gap: CGFloat = 14

        // Render each section once (vector), measuring its height.
        struct Block { let height: CGFloat; let draw: (CGContext) -> Void; let blankRows: [Bool] }
        var blocks: [Block] = []
        let views = ReportContent.sections(r, model: nil, print: true) + [AnyView(
            Text(ReportContent.disclaimer).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center))]
        for v in views {
            let renderer = ImageRenderer(content: v.frame(width: contentWidth).environment(\.colorScheme, .light).environment(\.printMode, true))
            renderer.proposedSize = ProposedViewSize(width: contentWidth, height: nil)
            var block: Block?
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                renderer.render { size, draw in
                    // ImageRenderer's draw closure is only valid during this call, so draw into a recorded PDF page now.
                    let data = NSMutableData()
                    var box = CGRect(origin: .zero, size: size)
                    guard let consumer = CGDataConsumer(data: data as CFMutableData),
                          let rec = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
                    rec.beginPDFPage(nil); draw(rec); rec.endPDFPage(); rec.closePDF()
                    guard let doc = CGPDFDocument(CGDataProvider(data: data)!), let pg = doc.page(at: 1) else { return }
                    block = Block(height: size.height, draw: { ctx in ctx.drawPDFPage(pg) }, blankRows: blankRows(pg, size))
                }
            }
            if let block { blocks.append(block) }
        }

        // Pack blocks onto pages: keep a section whole if it fits on a page; split taller ones
        // at a blank horizontal band (between rows) so text and charts aren't cut in half.
        struct Placement { let block: Block; let page: Int; let y: CGFloat; let sliceTop: CGFloat; let sliceH: CGFloat }
        var placements: [Placement] = [], pageIx = 0, y: CGFloat = 0
        for b in blocks {
            if y > 0 && y + b.height > bodyH && (b.height <= bodyH || bodyH - y < 160) { pageIx += 1; y = 0 }
            var top: CGFloat = 0
            while top < b.height {
                let space = bodyH - y
                var h = min(b.height - top, space)
                if top + h < b.height { h = safeCut(b.blankRows, top: top, limit: h) }
                placements.append(Placement(block: b, page: pageIx, y: y, sliceTop: top, sliceH: h))
                top += h; y += h
                if top < b.height { pageIx += 1; y = 0 }
            }
            y += gap
        }
        let pageCount = pageIx + 1

        var media = CGRect(origin: .zero, size: page)
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, [kCGPDFContextTitle: "\(r.ticker) evaluation",
                                                                   kCGPDFContextCreator: "Ticker Evaluator"] as CFDictionary)
        else { throw EngineError.parse("could not create PDF at \(url.path)") }
        let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        for p in 0..<pageCount {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gctx
            let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor(white: 0.45, alpha: 1)]
            NSAttributedString(string: "Ticker Evaluator · \(r.ticker) · \(r.verdict.verdict.rawValue) · as of \(Fmt.date(r.request.asOf))", attributes: small)
                .draw(at: CGPoint(x: margin, y: page.height - margin - 10))
            let foot = NSAttributedString(string: "Not financial advice · page \(p + 1) of \(pageCount)", attributes: small)
            foot.draw(at: CGPoint(x: page.width - margin - foot.size().width, y: margin))
            NSGraphicsContext.restoreGraphicsState()

            let topY = page.height - margin - headerH                     // top of the body area (PDF y grows upward)
            for pl in placements where pl.page == p {
                ctx.saveGState()
                // Clip to this slice's spot on the page, then draw the whole block shifted so the slice lands there.
                let dest = CGRect(x: margin, y: topY - (pl.y + pl.sliceH) * scale, width: contentWidth * scale, height: pl.sliceH * scale)
                ctx.clip(to: dest)
                ctx.translateBy(x: margin, y: topY - (pl.y - pl.sliceTop + pl.block.height) * scale)
                ctx.scaleBy(x: scale, y: scale)
                pl.block.draw(ctx)
                ctx.restoreGState()
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// Per layout-point row (top to bottom): true when the row is one flat colour across the inner width.
    private static func blankRows(_ pg: CGPDFPage, _ size: CGSize) -> [Bool] {
        let w = Int(size.width), h = Int(size.height.rounded(.up))
        guard w > 40, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = ctx.data else { return [] }
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.drawPDFPage(pg)
        let px = base.assumingMemoryBound(to: UInt8.self)
        return (0..<h).map { row in                                     // memory row 0 = top of the image
            let o = row * w * 4, f = o + 6 * 4
            for x in stride(from: 6, to: w - 6, by: 2) {
                let i = o + x * 4
                if abs(Int(px[i]) - Int(px[f])) > 6 || abs(Int(px[i + 1]) - Int(px[f + 1])) > 6 || abs(Int(px[i + 2]) - Int(px[f + 2])) > 6 { return false }
            }
            return true
        }
    }

    /// Height of the slice starting at `top`: ends in the middle of the lowest blank band (≥ 7 rows) that keeps
    /// at least 40% of the available space; otherwise a hard cut at `limit`.
    private static func safeCut(_ blank: [Bool], top: CGFloat, limit: CGFloat) -> CGFloat {
        guard !blank.isEmpty else { return limit }
        let t = Int(top), end = min(blank.count - 1, Int(top + limit) - 1), floor = t + Int(limit * 0.4)
        var run = 0
        var r = end
        while r >= floor {
            run = blank[r] ? run + 1 : 0
            if run >= 7 { return CGFloat(r + 3 - t) }
            r -= 1
        }
        return limit
    }

    /// Shows a save panel and writes the chosen format.
    @MainActor
    static func save(_ r: EvaluationReport, pdf asPDF: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [asPDF ? .pdf : UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = fileName(r, ext: asPDF ? "pdf" : "md")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if asPDF { try pdf(r, to: url) } else { try markdown(r, to: url) }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
