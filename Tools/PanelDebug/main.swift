// Draws the detected panels over pages of a comic, for tuning PanelDetector.
//   swift run PanelDebug <comic> <output-dir> [first-page] [count] [rtl]
import AppKit
import ComicCore

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: PanelDebug <comic> <output-dir> [first-page] [count] [rtl]"); exit(1) }
let book = try ComicBook(url: URL(fileURLWithPath: args[1]))
let output = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let first = args.count > 3 ? max(1, Int(args[3]) ?? 1) : 1
let count = args.count > 4 ? Int(args[4]) ?? book.pageCount : book.pageCount
let direction: ReadingDirection = args.contains("rtl") ? .rightToLeft : .leftToRight

for page in (first - 1)..<min(book.pageCount, first - 1 + count) {
    let image = try book.image(at: page, maxPixelSize: 2400)     // about what the reader hands the detector
    let started = Date()
    let panels = PanelDetector.detect(in: image, direction: direction)
    let ms = Int(Date().timeIntervalSince(started) * 1000)
    let w = CGFloat(image.width), h = CGFloat(image.height)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.width, pixelsHigh: image.height, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    for (index, panel) in panels.enumerated() {
        let rect = CGRect(x: panel.minX * w, y: (1 - panel.maxY) * h, width: panel.width * w, height: panel.height * h)
        context.setStrokeColor(NSColor.systemRed.cgColor); context.setLineWidth(10); context.stroke(rect.insetBy(dx: 5, dy: 5))
        let label = NSAttributedString(string: " \(index + 1) ", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 96), .foregroundColor: NSColor.white, .backgroundColor: NSColor.systemRed])
        label.draw(at: CGPoint(x: rect.minX + 8, y: rect.maxY - 128))
    }
    NSGraphicsContext.current = nil
    try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.5])!.write(to: output.appendingPathComponent(String(format: "page-%03d.jpg", page + 1)))
    print("page \(page + 1): \(panels.count) panel(s), \(ms) ms")
}
