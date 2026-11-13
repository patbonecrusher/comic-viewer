import XCTest
import ZIPFoundation
@testable import ComicCore

final class ComicCoreTests: XCTestCase {
    func testPageFilteringAndNaturalOrder() {
        XCTAssertTrue(PageNames.isPage("Book/page01.JPG"))
        XCTAssertFalse(PageNames.isPage("__MACOSX/Book/._page01.jpg"))
        XCTAssertFalse(PageNames.isPage("Book/.hidden.png"))
        XCTAssertFalse(PageNames.isPage("ComicInfo.xml"))
        XCTAssertEqual(PageNames.sorted(["p10.jpg", "p2.jpg", "P1.jpg"]), ["P1.jpg", "p2.jpg", "p10.jpg"])
    }

    func testSingleLayoutIsOnePagePerSpread() {
        let spreads = SpreadBuilder.spreads(pageCount: 3, layout: .single) { _ in false }
        XCTAssertEqual(spreads.map(\.pages), [[0], [1], [2]])
    }

    func testDoubleLayoutKeepsCoverAndWidePagesAlone() {
        // page 3 is a landscape double-page scan
        let spreads = SpreadBuilder.spreads(pageCount: 8, layout: .double) { $0 == 3 }
        XCTAssertEqual(spreads.map(\.pages), [[0], [1, 2], [3], [4, 5], [6, 7]])
        XCTAssertEqual(SpreadBuilder.index(of: 5, in: spreads), 3)
    }

    func testDoubleLayoutLeavesTrailingPageAlone() {
        let spreads = SpreadBuilder.spreads(pageCount: 4, layout: .double) { _ in false }
        XCTAssertEqual(spreads.map(\.pages), [[0], [1, 2], [3]])
    }

    func testReadsPagesFromZipInNaturalOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Test Comic.cbr")      // wrong extension on purpose: content decides
        let archive = try Archive(url: url, accessMode: .create)
        for (name, width) in [("p10.png", 30), ("p2.png", 20), ("p1.png", 10), ("ComicInfo.xml", 0)] {
            let data = width == 0 ? Data("<ComicInfo/>".utf8) : try png(width: width, height: 40)
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        let book = try ComicBook(url: url)
        XCTAssertEqual(book.title, "Test Comic")
        XCTAssertEqual(book.pageCount, 3)
        XCTAssertEqual((0..<3).map { book.pageName(at: $0) }, ["p1.png", "p2.png", "p10.png"])
        XCTAssertEqual(book.pageSize(at: 2), CGSize(width: 30, height: 40))
        XCTAssertEqual(try book.image(at: 1).width, 20)
        XCTAssertEqual(try book.image(at: 2, maxPixelSize: 20).height, 20)
    }

    func testRendersPDFPages() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for _ in 0..<2 { context.beginPDFPage(nil); context.fill(CGRect(x: 10, y: 10, width: 50, height: 50)); context.endPDFPage() }
        context.closePDF()
        let book = try ComicBook(url: url)
        XCTAssertEqual(book.pageCount, 2)
        XCTAssertEqual(book.pageSize(at: 0), CGSize(width: 600, height: 900))
        let image = try book.image(at: 1, maxPixelSize: 150)
        XCTAssertEqual([image.width, image.height], [100, 150])
    }

    private func png(width: Int, height: Int) throws -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
