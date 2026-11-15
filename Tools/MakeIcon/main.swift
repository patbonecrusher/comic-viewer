// Generates the app icon (.iconset folder) with CoreGraphics: a comic page with three
// panels and a speech balloon on a warm tile.
// Usage: MakeIcon <out.iconset>       the Mac icon at every size
//        MakeIcon --ios <out.png>     the iPhone/iPad icon: 1024 pixels, edge to edge, no transparency
import AppKit

let args = CommandLine.arguments
guard args.count > 1 else { FileHandle.standardError.write(Data("usage: MakeIcon <output.iconset> | --ios <output.png>\n".utf8)); exit(1) }

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }

func drawIcon(in ctx: CGContext, pixels: CGFloat, edgeToEdge: Bool = false) {
    ctx.scaleBy(x: pixels / 1024, y: pixels / 1024)
    let square = CGRect(x: 100, y: 100, width: 824, height: 824)          // macOS icon grid
    // iOS rounds the corners itself and wants the tile to fill the whole image.
    if edgeToEdge { ctx.translateBy(x: 512, y: 512); ctx.scaleBy(x: 1024 / 824, y: 1024 / 824); ctx.translateBy(x: -512, y: -512) }
    let shape = edgeToEdge ? CGPath(rect: square, transform: nil) : CGPath(roundedRect: square, cornerWidth: 186, cornerHeight: 186, transform: nil)
    let ink = rgb(28, 28, 44)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.30))
    ctx.setFillColor(ink); ctx.addPath(shape); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(shape); ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [rgb(255, 196, 64), rgb(240, 84, 68)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 160, y: 900), end: CGPoint(x: 880, y: 140), options: [])

    // A comic page, slightly tilted: white paper with three inked panels.
    ctx.translateBy(x: 512, y: 512); ctx.rotate(by: -0.10); ctx.translateBy(x: -512, y: -512)
    let page = CGRect(x: 262, y: 190, width: 500, height: 644)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: CGColor(gray: 0, alpha: 0.35))
    ctx.setFillColor(rgb(252, 250, 244)); ctx.addPath(CGPath(roundedRect: page, cornerWidth: 18, cornerHeight: 18, transform: nil)); ctx.fillPath()
    ctx.restoreGState()
    let panels: [(CGRect, CGColor)] = [
        (CGRect(x: 300, y: 560, width: 424, height: 236), rgb(64, 168, 236)),      // wide panel on top
        (CGRect(x: 300, y: 228, width: 184, height: 298), rgb(236, 72, 118)),      // bottom left
        (CGRect(x: 518, y: 228, width: 206, height: 298), rgb(255, 205, 56)),      // bottom right
    ]
    for (rect, color) in panels {
        ctx.setFillColor(color); ctx.fill(rect)
        ctx.setStrokeColor(ink); ctx.setLineWidth(14); ctx.setLineJoin(.miter); ctx.stroke(rect)
    }
    // A speech balloon breaking out of the top panel.
    let balloon = CGMutablePath()
    balloon.addEllipse(in: CGRect(x: 468, y: 600, width: 300, height: 190))
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 520, y: 640)); tail.addLine(to: CGPoint(x: 452, y: 566)); tail.addLine(to: CGPoint(x: 590, y: 612)); tail.closeSubpath()
    ctx.setStrokeColor(ink); ctx.setLineWidth(28); ctx.setLineJoin(.round)
    ctx.addPath(balloon); ctx.addPath(tail); ctx.strokePath()
    ctx.setFillColor(rgb(255, 255, 255)); ctx.addPath(balloon); ctx.addPath(tail); ctx.fillPath()
    ctx.setFillColor(ink)
    for x in [556, 618, 680] { ctx.fillEllipse(in: CGRect(x: CGFloat(x) - 17, y: 678, width: 34, height: 34)) }
    ctx.restoreGState()
}

if args[1] == "--ios" {
    guard args.count > 2,
          let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(2) }
    drawIcon(in: ctx, pixels: 1024, edgeToEdge: true)
    guard let image = ctx.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, "public.png" as CFString, 1, nil) else { exit(2) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { exit(2) }
    exit(0)
}

let outDir = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = points * scale
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let gc = NSGraphicsContext(bitmapImageRep: rep) else { exit(2) }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gc
    drawIcon(in: gc.cgContext, pixels: CGFloat(px))
    gc.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
}
