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

    /// Two panels on top, one wide panel below, on white paper.
    private func threePanelPage() -> CGImage {
        let context = CGContext(data: nil, width: 600, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        // Core Graphics has y pointing up: these two are the top row.
        context.fill(CGRect(x: 30, y: 480, width: 250, height: 390))
        context.fill(CGRect(x: 310, y: 480, width: 260, height: 390))
        context.fill(CGRect(x: 30, y: 30, width: 540, height: 420))
        return context.makeImage()!
    }

    func testDetectsPanelsInReadingOrder() {
        let panels = PanelDetector.detect(in: threePanelPage())
        XCTAssertEqual(panels.count, 3)
        guard panels.count == 3 else { return }
        XCTAssertEqual(panels[0].minX, 0.05, accuracy: 0.01)
        XCTAssertEqual(panels[0].minY, 30.0 / 900, accuracy: 0.01)
        XCTAssertEqual(panels[1].minX, 310.0 / 600, accuracy: 0.01)
        XCTAssertEqual(panels[2].minY, 450.0 / 900, accuracy: 0.01)
        XCTAssertEqual(panels[2].width, 0.9, accuracy: 0.01)
    }

    func testMangaOrderReadsTopRowRightToLeft() {
        let panels = PanelDetector.detect(in: threePanelPage(), direction: .rightToLeft)
        XCTAssertEqual(panels.count, 3)
        guard panels.count == 3 else { return }
        XCTAssertGreaterThan(panels[0].minX, panels[1].minX)
        XCTAssertGreaterThan(panels[2].minY, panels[0].minY)
    }

    func testPageWithoutGuttersIsOnePanel() {
        let context = CGContext(data: nil, width: 300, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.4, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        XCTAssertEqual(PanelDetector.detect(in: context.makeImage()!), [PanelDetector.wholePage])
    }

    func testGuessesMetadataFromFileNames() {
        func parse(_ name: String) -> ComicMetadata { .fromFileName(URL(fileURLWithPath: "/Comics/Shelf/" + name)) }
        var m = parse("Saga 012 (2013) (Digital) (Zone-Empire).cbz")
        XCTAssertEqual([m.series, m.title], ["Saga", nil]); XCTAssertEqual(m.number, 12); XCTAssertEqual(m.year, 2013)
        m = parse("Akira v03.cbz")
        XCTAssertEqual(m.series, "Akira"); XCTAssertEqual(m.volume, 3); XCTAssertNil(m.number)
        m = parse("bladerunner2019volume2_offworld.cbz")
        XCTAssertEqual([m.series, m.title], ["bladerunner2019", "offworld"]); XCTAssertEqual(m.volume, 2)
        m = parse("Blade Runner 2019.cbz")
        XCTAssertEqual(m.series, "Blade Runner 2019"); XCTAssertNil(m.number)
        m = parse("Batman #4.5.cbr")
        XCTAssertEqual(m.series, "Batman"); XCTAssertEqual(m.number, 4.5)
        m = parse("bladerunnerblacklotus_lasvegas_issue1.cbz")
        XCTAssertEqual(m.series, "bladerunnerblacklotus lasvegas"); XCTAssertEqual(m.number, 1)
        m = parse("001.cbz")
        XCTAssertEqual(m.series, "Shelf"); XCTAssertEqual(m.number, 1)
    }

    private func makeComic(at url: URL, pages: Int, comicInfo: String? = nil) throws {
        let archive = try Archive(url: url, accessMode: .create)
        var files = try (1...pages).map { ("p\($0).png", try png(width: 20, height: 30)) }
        if let comicInfo { files.append(("ComicInfo.xml", Data(comicInfo.utf8))) }
        for (name, data) in files {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }

    func testLibraryScanAddsReadsMetadataAndRemoves() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).standardizedFileURL
        let comics = root.appendingPathComponent("Comics/Saga")
        try FileManager.default.createDirectory(at: comics, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeComic(at: comics.appendingPathComponent("Saga 001 (2012).cbz"), pages: 3)
        try makeComic(at: comics.appendingPathComponent("whatever.cbz"), pages: 2, comicInfo: """
            <?xml version="1.0"?><ComicInfo><Series>Saga</Series><Number>2</Number><Title>Chapter Two</Title>
            <Writer>Brian K. Vaughan</Writer><Manga>YesAndRightToLeft</Manga><Pages><Page Image="0"/></Pages></ComicInfo>
            """)
        try Data("not a comic".utf8).write(to: comics.appendingPathComponent("broken.cbz"))

        let store = try LibraryStore(directory: root.appendingPathComponent("Store"))
        let folder = try store.addFolder(path: root.appendingPathComponent("Comics").path, bookmark: Data())
        var result = store.scan(folder, at: root.appendingPathComponent("Comics"))
        XCTAssertEqual([result.added, result.failed], [2, 1])

        let books = store.books().sorted { ($0.number ?? 0) < ($1.number ?? 0) }
        XCTAssertEqual(books.map(\.series), ["Saga", "Saga"])
        XCTAssertEqual(books.map(\.pageCount), [3, 2])
        XCTAssertEqual(books[0].year, 2012)
        XCTAssertEqual(books[0].title, "Saga #1")
        XCTAssertEqual(books[1].title, "Chapter Two")
        XCTAssertEqual(books[1].writer, "Brian K. Vaughan")
        XCTAssertEqual(books[1].direction, ReadingDirection.rightToLeft.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.coverURL(for: books[0].id!).path))

        // Progress survives a rescan; deleted files leave the library.
        store.update(id: books[0].id!) { $0.page = 2; $0.lastReadAt = Date() }
        try FileManager.default.removeItem(at: comics.appendingPathComponent("whatever.cbz"))
        result = store.scan(folder, at: root.appendingPathComponent("Comics"))
        XCTAssertEqual([result.added, result.updated, result.removed], [0, 0, 1])
        XCTAssertEqual(store.books().map(\.page), [2])

        // Hand-drawn panels are kept per page, can mean "whole page", and can be cleared.
        let id = store.books()[0].id!
        let drawn = [CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.25), CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.5)]
        store.setPanelOverride(drawn, bookID: id, page: 1)
        store.setPanelOverride([], bookID: id, page: 2)
        XCTAssertEqual(store.panelOverrides(bookID: id), [1: drawn, 2: []])
        store.setPanelOverride(nil, bookID: id, page: 1)
        XCTAssertEqual(store.panelOverrides(bookID: id), [2: []])

        try store.removeFolder(id: folder.id!)
        XCTAssertTrue(store.books().isEmpty)
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
