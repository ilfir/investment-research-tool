import PDFKit; import AppKit
let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
print("pages:", doc.pageCount)
for i in 0..<doc.pageCount {
    let pg = doc.page(at: i)!; let b = pg.bounds(for: .mediaBox)
    let img = NSImage(size: NSSize(width: b.width*1.5, height: b.height*1.5), flipped: false) { r in
        NSColor.white.setFill(); r.fill()
        let ctx = NSGraphicsContext.current!.cgContext; ctx.scaleBy(x: 1.5, y: 1.5); pg.draw(with: .mediaBox, to: ctx); return true }
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(CommandLine.arguments[2])_p\(i+1).png"))
}
