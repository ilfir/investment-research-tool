import AppKit
// Ticker Evaluator icon: a lens weighing a ticker (blue) against the S&P 500 (orange), with a verdict check.
func draw(_ S: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    let u = S / 1024
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * u, y: y * u) }
    func col(_ h: UInt32, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: CGFloat(h >> 16 & 255)/255, green: CGFloat(h >> 8 & 255)/255, blue: CGFloat(h & 255)/255, alpha: a) }
    let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

    // Squircle tile (macOS grid: 824 of 1024 with shadow room)
    let tile = CGRect(x: 100*u, y: 100*u, width: 824*u, height: 824*u)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185*u, cornerHeight: 185*u, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10*u), blur: 24*u, color: col(0x000000, 0.35))
    c.addPath(tilePath); c.setFillColor(col(0x0b1a33)); c.fillPath()
    c.restoreGState()
    c.saveGState(); c.addPath(tilePath); c.clip()
    let bg = CGGradient(colorsSpace: rgb, colors: [col(0x12305e), col(0x0a1530)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(bg, start: p(200, 924), end: p(824, 100), options: [])
    // Faint grid
    c.setStrokeColor(col(0xffffff, 0.07)); c.setLineWidth(3*u)
    for y in stride(from: 260.0, through: 800, by: 135) { c.move(to: p(100, y)); c.addLine(to: p(924, y)) }
    c.strokePath()

    // Two lines: S&P 500 (orange, steady) and the ticker (blue, ends higher)
    func line(_ pts: [(CGFloat, CGFloat)], _ color: CGColor, _ w: CGFloat) {
        c.setStrokeColor(color); c.setLineWidth(w*u); c.setLineCap(.round); c.setLineJoin(.round)
        c.move(to: p(pts[0].0, pts[0].1)); for q in pts.dropFirst() { c.addLine(to: p(q.0, q.1)) }; c.strokePath()
    }
    let sp: [(CGFloat, CGFloat)] = [(150, 300), (260, 340), (360, 330), (470, 400), (580, 430), (690, 500), (800, 540), (880, 580)]
    let tk: [(CGFloat, CGFloat)] = [(150, 270), (250, 330), (330, 300), (430, 420), (520, 390), (620, 520), (720, 600), (880, 720)]
    line(sp, col(0xeb6834), 30)
    line(tk, col(0x3f93f0), 34)
    c.restoreGState()

    // Magnifying lens over the right part of the chart
    let center = p(590, 500), r = 200*u
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12*u), blur: 30*u, color: col(0x000000, 0.45))
    // handle
    c.setStrokeColor(col(0xdfe6ef)); c.setLineWidth(70*u); c.setLineCap(.round)
    c.move(to: CGPoint(x: center.x + r*0.72, y: center.y - r*0.72)); c.addLine(to: CGPoint(x: center.x + r*1.42, y: center.y - r*1.42)); c.strokePath()
    c.restoreGState()
    c.setStrokeColor(col(0x8a97a8)); c.setLineWidth(70*u); c.setLineCap(.round)
    c.move(to: CGPoint(x: center.x + r*1.12, y: center.y - r*1.12)); c.addLine(to: CGPoint(x: center.x + r*1.42, y: center.y - r*1.42)); c.strokePath()
    // glass
    let glass = CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r)
    c.saveGState(); c.addEllipse(in: glass); c.clip()
    let g = CGGradient(colorsSpace: rgb, colors: [col(0xeaf3ff, 0.97), col(0xc9dcf5, 0.97)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: center.x, y: center.y + r), end: CGPoint(x: center.x, y: center.y - r), options: [])
    // magnified lines inside the lens (2x around the lens centre)
    c.translateBy(x: center.x, y: center.y); c.scaleBy(x: 1.9, y: 1.9); c.translateBy(x: -center.x, y: -center.y)
    func lineIn(_ pts: [(CGFloat, CGFloat)], _ color: CGColor, _ w: CGFloat) {
        c.setStrokeColor(color); c.setLineWidth(w*u); c.setLineCap(.round); c.setLineJoin(.round)
        c.move(to: p(pts[0].0, pts[0].1)); for q in pts.dropFirst() { c.addLine(to: p(q.0, q.1)) }; c.strokePath()
    }
    lineIn(sp, col(0xeb6834), 16); lineIn(tk, col(0x2a78d6), 18)
    c.restoreGState()
    // rim
    c.setStrokeColor(col(0xf4f7fb)); c.setLineWidth(34*u); c.strokeEllipse(in: glass)
    c.setStrokeColor(col(0x9aa8ba, 0.6)); c.setLineWidth(4*u); c.strokeEllipse(in: glass.insetBy(dx: 17*u, dy: 17*u))
    // glare
    c.setStrokeColor(col(0xffffff, 0.75)); c.setLineWidth(14*u); c.setLineCap(.round)
    c.addArc(center: center, radius: r*0.78, startAngle: .pi*0.62, endAngle: .pi*0.86, clockwise: false); c.strokePath()

    // Verdict badge: green check, top-left of the tile
    let bc = p(285, 740), br = 105*u
    c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: -6*u), blur: 16*u, color: col(0x000000, 0.4))
    c.setFillColor(col(0x0ca30c)); c.fillEllipse(in: CGRect(x: bc.x - br, y: bc.y - br, width: 2*br, height: 2*br)); c.restoreGState()
    c.setStrokeColor(col(0xffffff)); c.setLineWidth(30*u); c.setLineCap(.round); c.setLineJoin(.round)
    c.move(to: CGPoint(x: bc.x - 48*u, y: bc.y + 2*u)); c.addLine(to: CGPoint(x: bc.x - 12*u, y: bc.y - 36*u)); c.addLine(to: CGPoint(x: bc.x + 52*u, y: bc.y + 40*u)); c.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}
let out = CommandLine.arguments[1]
try! FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
var images: [String] = []
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for s in scales {
        let name = "icon_\(pt)x\(pt)\(s == 2 ? "@2x" : "").png"
        try! draw(CGFloat(pt * s)).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
        images.append(#"{"idiom":"mac","size":"\#(pt)x\#(pt)","scale":"\#(s)x","filename":"\#(name)"}"#)
    }
}
try! #"{"images":[\#(images.joined(separator: ","))],"info":{"version":1,"author":"xcode"}}"#.write(toFile: "\(out)/Contents.json", atomically: true, encoding: .utf8)
