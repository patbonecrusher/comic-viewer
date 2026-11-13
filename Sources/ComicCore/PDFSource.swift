import CoreGraphics
import Foundation

/// PDF comics, rendered with Core Graphics (available on every Apple platform).
final class PDFSource: PageSource {
    private let document: CGPDFDocument
    private let lock = NSLock()
    /// Pixels per PDF point when no size limit is given (216 dpi).
    private static let nominalScale: CGFloat = 3

    init(url: URL) throws {
        guard let document = CGPDFDocument(url as CFURL) else { throw ComicError.unreadableFile("not a readable PDF") }
        guard !document.isEncrypted || document.unlockWithPassword("") else { throw ComicError.unreadableFile("the PDF is password-protected") }
        guard document.numberOfPages > 0 else { throw ComicError.noPages }
        self.document = document
    }

    var pageCount: Int { document.numberOfPages }
    func pageName(at index: Int) -> String { "Page \(index + 1)" }

    private func pointSize(of page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let quarterTurn = (page.rotationAngle / 90) % 2 != 0
        return quarterTurn ? CGSize(width: box.height, height: box.width) : box.size
    }

    func pageSize(at index: Int) throws -> CGSize {
        lock.lock(); defer { lock.unlock() }
        guard let page = document.page(at: index + 1) else { throw ComicError.unreadablePage(index) }
        let size = pointSize(of: page)
        return CGSize(width: size.width * Self.nominalScale, height: size.height * Self.nominalScale)
    }

    func image(at index: Int, maxPixelSize: Int?) throws -> CGImage {
        lock.lock(); defer { lock.unlock() }
        guard let page = document.page(at: index + 1) else { throw ComicError.unreadablePage(index) }
        let points = pointSize(of: page)
        guard points.width > 0, points.height > 0 else { throw ComicError.unreadablePage(index) }
        var scale = Self.nominalScale
        if let maxPixelSize { scale = min(scale, CGFloat(maxPixelSize) / max(points.width, points.height)) }
        let width = max(1, Int((points.width * scale).rounded())), height = max(1, Int((points.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ComicError.unreadablePage(index) }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: points), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw ComicError.unreadablePage(index) }
        return image
    }
}
