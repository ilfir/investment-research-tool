import SwiftUI
import AppKit

/// Renders the report screen headlessly (used to check layout without opening the app).
enum Snapshot {
    @MainActor
    static func render(_ report: EvaluationReport, to url: URL, dark: Bool, width: CGFloat = 1180) throws {
        let view = ReportContent(report: report, model: nil)   // like a printed report: no answer pickers
            .padding(20)
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.printMode, true)
        let r = ImageRenderer(content: view)
        r.scale = 1.5
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var image: NSImage?
        appearance.performAsCurrentDrawingAppearance { image = r.nsImage }
        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { throw EngineError.parse("snapshot render") }
        try png.write(to: url)
        // Also write 1500-px-tall slices (name_0.png, name_1.png…) for easier review.
        guard let cg = rep.cgImage else { return }
        let base = url.deletingPathExtension().path
        var y = 0, i = 0
        while y < cg.height {
            let h = min(1500, cg.height - y)
            if let part = cg.cropping(to: CGRect(x: 0, y: y, width: cg.width, height: h)),
               let data = NSBitmapImageRep(cgImage: part).representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: "\(base)_\(i).png"))
            }
            y += h; i += 1
        }
    }
}
