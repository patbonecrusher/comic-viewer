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

    /// Full-page artwork (a gradient, so there are no gutters) with two outlined panels set on top of it.
    func testFindsFramedPanelsOverArtwork() {
        let context = CGContext(data: nil, width: 600, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let colors = [CGColor(gray: 0.25, alpha: 1), CGColor(gray: 0.6, alpha: 1)] as CFArray
        context.drawLinearGradient(CGGradient(colorsSpace: nil, colors: colors, locations: nil)!,
                                   start: .zero, end: CGPoint(x: 600, y: 900), options: [])
        // y points up in Core Graphics: the first frame is near the top left, the second lower right.
        let frames = [CGRect(x: 60, y: 560, width: 220, height: 260), CGRect(x: 330, y: 120, width: 210, height: 300)]
        for frame in frames {
            context.setFillColor(CGColor(gray: 0.9, alpha: 1)); context.fill(frame)
            context.setStrokeColor(CGColor(gray: 0, alpha: 1)); context.setLineWidth(5); context.stroke(frame)
        }
        let panels = PanelDetector.detect(in: context.makeImage()!)
        // The page as a whole first, then each frame in reading order.
        XCTAssertEqual(panels.count, 3)
        guard panels.count == 3 else { return }
        XCTAssertEqual(panels[0], PanelDetector.wholePage)
        XCTAssertEqual(panels[1].minX, 0.1, accuracy: 0.02); XCTAssertEqual(panels[1].minY, 80.0 / 900, accuracy: 0.02)
        XCTAssertEqual(panels[2].minX, 0.55, accuracy: 0.02); XCTAssertEqual(panels[2].height, 300.0 / 900, accuracy: 0.03)
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

    func testRemovedComicsStayRemovedUntilRestored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).standardizedFileURL
        let comics = root.appendingPathComponent("Comics")
        try FileManager.default.createDirectory(at: comics, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeComic(at: comics.appendingPathComponent("Saga 001.cbz"), pages: 3)
        try makeComic(at: comics.appendingPathComponent("Saga 002.cbz"), pages: 3)
        let loose = root.appendingPathComponent("Loose 001.cbz")
        try makeComic(at: loose, pages: 2)

        let store = try LibraryStore(directory: root.appendingPathComponent("Store"))
        let folder = try store.addFolder(path: comics.path, bookmark: Data())
        _ = store.scan(folder, at: comics)
        let own = try store.record(ComicBook(url: loose))
        XCTAssertEqual(store.books().count, 3)

        let first = try XCTUnwrap(store.books().first { $0.number == 1 && $0.folderID != nil })
        store.update(id: first.id!) { $0.page = 2 }
        store.takeOut(ids: [first.id!, own.id!])
        XCTAssertEqual(store.books().map(\.title), ["Saga #2"])
        XCTAssertEqual(store.hiddenCount(), 1)                 // the one opened on its own is simply forgotten

        // A scan must not bring the removed comic back, nor add it a second time.
        let result = store.scan(folder, at: comics)
        XCTAssertEqual([result.added, result.removed], [0, 0])
        XCTAssertEqual(store.books().count, 1)

        XCTAssertEqual(store.restoreHidden(), 1)
        let restored = try XCTUnwrap(store.books().first { $0.id == first.id })
        XCTAssertEqual(restored.page, 2)                       // with its reading position
        XCTAssertEqual(store.hiddenCount(), 0)

        // A removed comic whose file is then deleted is forgotten by the next scan.
        store.takeOut(ids: [first.id!])
        try FileManager.default.removeItem(at: comics.appendingPathComponent("Saga 001.cbz"))
        _ = store.scan(folder, at: comics)
        XCTAssertEqual(store.hiddenCount(), 0)
    }

    func testRenamedSeriesSticksAndTakesInLaterIssues() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).standardizedFileURL
        let comics = root.appendingPathComponent("Comics")
        try FileManager.default.createDirectory(at: comics, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeComic(at: comics.appendingPathComponent("BB 001.cbz"), pages: 2)
        try makeComic(at: comics.appendingPathComponent("BB 002.cbz"), pages: 2)
        try makeComic(at: comics.appendingPathComponent("Other 001.cbz"), pages: 2)
        let store = try LibraryStore(directory: root.appendingPathComponent("Store"))
        let folder = try store.addFolder(path: comics.path, bookmark: Data())
        _ = store.scan(folder, at: comics)
        XCTAssertEqual(Set(store.books().map(\.series)), ["BB", "Other"])

        XCTAssertEqual(store.renameSeries("BB", to: " Buster Brown "), 2)
        XCTAssertEqual(Set(store.books().map(\.series)), ["Buster Brown", "Other"])
        XCTAssertTrue(store.books().contains { $0.title == "Buster Brown #1" })

        // A later issue joins the renamed series, and reading a comic again doesn't undo the name.
        try makeComic(at: comics.appendingPathComponent("BB 003.cbz"), pages: 2)
        _ = store.scan(folder, at: comics)
        _ = try store.record(ComicBook(url: comics.appendingPathComponent("BB 001.cbz")), folderID: folder.id)
        XCTAssertEqual(store.books().filter { $0.series == "Buster Brown" }.count, 3)

        // Renaming again carries the files' own name along; naming another series merges into it.
        store.renameSeries("Buster Brown", to: "Other")
        try makeComic(at: comics.appendingPathComponent("BB 004.cbz"), pages: 2)
        _ = store.scan(folder, at: comics)
        XCTAssertEqual(Set(store.books().map(\.series)), ["Other"])
        XCTAssertEqual(store.books().count, 5)
    }

    func testComicMovedToAnotherSeriesStaysThere() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).standardizedFileURL
        let comics = root.appendingPathComponent("Comics")
        try FileManager.default.createDirectory(at: comics, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stray = comics.appendingPathComponent("origins 001.cbz")
        try makeComic(at: stray, pages: 2)
        try makeComic(at: comics.appendingPathComponent("Runner 001.cbz"), pages: 2)
        let store = try LibraryStore(directory: root.appendingPathComponent("Store"))
        let folder = try store.addFolder(path: comics.path, bookmark: Data())
        _ = store.scan(folder, at: comics)
        let book = try XCTUnwrap(store.book(path: stray.path))
        XCTAssertEqual(book.series, "origins")

        store.setSeries("Runner", ids: [book.id!])
        XCTAssertEqual(store.book(id: book.id!)?.title, "Runner #1")
        // Reading the file again doesn't put it back, and a later rename of the series carries it along.
        _ = try store.record(ComicBook(url: stray), folderID: folder.id)
        XCTAssertEqual(store.books().map(\.series), ["Runner", "Runner"])
        store.renameSeries("Runner", to: "Blade Runner")
        _ = try store.record(ComicBook(url: stray), folderID: folder.id)
        XCTAssertEqual(store.books().map(\.series), ["Blade Runner", "Blade Runner"])

        // An empty name takes it out of any series.
        store.setSeries("", ids: [book.id!])
        _ = try store.record(ComicBook(url: stray), folderID: folder.id)
        XCTAssertEqual(store.book(id: book.id!)?.series, "")
    }

    func testRenamingAFileKeepsItsSeriesAndDetails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).standardizedFileURL
        let comics = root.appendingPathComponent("Comics")
        try FileManager.default.createDirectory(at: comics, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // No ComicInfo: everything known about this comic comes from its file name.
        let old = comics.appendingPathComponent("bladerunner2019volume2_offworld.cbz")
        try makeComic(at: old, pages: 2)
        let store = try LibraryStore(directory: root.appendingPathComponent("Store"))
        let folder = try store.addFolder(path: comics.path, bookmark: Data())
        _ = store.scan(folder, at: comics)
        let book = try XCTUnwrap(store.books().first)
        XCTAssertEqual([book.series, book.title], ["bladerunner2019", "offworld"])
        XCTAssertEqual(book.suggestedFileName, "bladerunner2019 v02 - offworld")

        // A name that says nothing about the series must not start a new one.
        let new = comics.appendingPathComponent("my favourite.cbz")
        try FileManager.default.moveItem(at: old, to: new)
        var moved = try store.relocate(id: book.id!, to: new)
        // The title follows the name that was typed; the series and volume stay.
        XCTAssertEqual([moved.series, moved.title], ["bladerunner2019", "my favourite"])
        XCTAssertEqual(moved.volume, 2)
        // Still true after a rescan and after the comic is opened again.
        _ = store.scan(folder, at: comics)
        moved = try store.record(ComicBook(url: new), folderID: folder.id)
        XCTAssertEqual([moved.series, moved.title], ["bladerunner2019", "my favourite"])
        XCTAssertEqual(store.books().count, 1)

        // Details set by hand hold through later reads of the file.
        store.setDetails(id: book.id!, title: "My Favourite", series: "Blade Runner 2019", volume: 5, number: nil, year: 2019)
        moved = try store.record(ComicBook(url: new), folderID: folder.id)
        XCTAssertEqual([moved.series, moved.title], ["Blade Runner 2019", "My Favourite"])
        XCTAssertEqual([moved.volume, moved.year], [5, 2019])
        store.setDetails(id: book.id!, title: "my favourite", series: "bladerunner2019", volume: 2, number: nil, year: nil)
        moved = try XCTUnwrap(store.book(id: book.id!))

        // The app's own suggestion keeps the title, and a typed "Series v02 - Title" name gives just the title.
        let tidy = comics.appendingPathComponent(moved.suggestedFileName + ".cbz")
        XCTAssertEqual(tidy.lastPathComponent, "bladerunner2019 v02 - my favourite.cbz")
        try FileManager.default.moveItem(at: new, to: tidy)
        moved = try store.relocate(id: book.id!, to: tidy)
        XCTAssertEqual(moved.title, "my favourite")
        let typed = comics.appendingPathComponent("bladerunner2019 v02 - Off-World.cbz")
        try FileManager.default.moveItem(at: tidy, to: typed)
        moved = try store.relocate(id: book.id!, to: typed)
        XCTAssertEqual([moved.series, moved.title], ["bladerunner2019", "Off-World"])

        // The names the app suggests read back as the same comic.
        func parse(_ name: String) -> ComicMetadata { .fromFileName(URL(fileURLWithPath: "/Comics/Shelf/" + name)) }
        let issue = parse("Saga 002 - Chapter Two (2012).cbz")
        XCTAssertEqual(issue.series, "Saga"); XCTAssertEqual(issue.number, 2); XCTAssertEqual(issue.title, "Chapter Two")
        let volume = parse("bladerunner2019 v02 - offworld.cbz")
        XCTAssertEqual(volume.series, "bladerunner2019"); XCTAssertEqual(volume.volume, 2); XCTAssertEqual(volume.title, "offworld")
        let both = parse("Akira v03 012 - Tetsuo.cbz")
        XCTAssertEqual(both.series, "Akira"); XCTAssertEqual(both.volume, 3); XCTAssertEqual(both.number, 12); XCTAssertEqual(both.title, "Tetsuo")
        XCTAssertEqual(parse("Blade Runner 2049 - Art Book.cbz").number, nil)
    }

    func testCoverAndProgressReachADeviceThatNeverDownloadedTheComic() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root.appendingPathComponent("Container")
        // The Mac has the file.
        let macComics = container.appendingPathComponent("Documents/Saga")
        try FileManager.default.createDirectory(at: macComics, withIntermediateDirectories: true)
        try makeComic(at: macComics.appendingPathComponent("Saga 001.cbz"), pages: 5)
        let mac = try LibraryStore(directory: root.appendingPathComponent("MacStore"))
        let macRoot = container.appendingPathComponent("Documents")
        let macFolder = try mac.addFolder(path: macRoot.path, bookmark: Data())
        _ = mac.scan(macFolder, at: macRoot)
        let onMac = try XCTUnwrap(mac.books().first)
        mac.update(id: onMac.id!) { $0.page = 3; $0.lastReadAt = Date(timeIntervalSinceNow: -60) }
        mac.setDetails(id: onMac.id!, title: "Chapter One", series: "Saga", volume: 1, number: 1, year: 2012)

        // The phone sees the same folder, but iCloud has only left a stand-in for the file.
        let phoneRoot = root.appendingPathComponent("Phone/Documents")
        try FileManager.default.createDirectory(at: phoneRoot.appendingPathComponent("Saga"), withIntermediateDirectories: true)
        let standIn = phoneRoot.appendingPathComponent("Saga/.Saga 001.cbz.icloud")
        try Data().write(to: standIn)
        let phone = try LibraryStore(directory: root.appendingPathComponent("PhoneStore"))
        let phoneFolder = try phone.addFolder(path: phoneRoot.path, bookmark: Data())
        _ = phone.scan(phoneFolder, at: phoneRoot)
        var onPhone = try XCTUnwrap(phone.books().first)
        XCTAssertFalse(onPhone.downloaded)
        XCTAssertEqual(onPhone.pageCount, 0)

        let sync = CloudSync(container: container)
        XCTAssertEqual(sync.sync(store: mac, folderID: macFolder.id!, root: macRoot).changed, 0)
        XCTAssertEqual(sync.sync(store: phone, folderID: phoneFolder.id!, root: phoneRoot).changed, 1)
        onPhone = try XCTUnwrap(phone.books().first)
        XCTAssertEqual([onPhone.title, onPhone.series], ["Chapter One", "Saga"])
        XCTAssertEqual([onPhone.pageCount, onPhone.page, onPhone.volume ?? 0], [5, 3, 1])
        XCTAssertTrue(onPhone.isStarted)
        XCTAssertFalse(onPhone.downloaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: phone.coverURL(for: onPhone.id!).path))
        // Nothing more to do on a second pass, either way.
        XCTAssertEqual(sync.sync(store: phone, folderID: phoneFolder.id!, root: phoneRoot).changed, 0)
        XCTAssertEqual(sync.sync(store: mac, folderID: macFolder.id!, root: macRoot).changed, 0)

        // The phone fetches the file and reads on; the Mac picks up the new position, and its details survive.
        try FileManager.default.removeItem(at: standIn)
        try FileManager.default.copyItem(at: macComics.appendingPathComponent("Saga 001.cbz"), to: phoneRoot.appendingPathComponent("Saga/Saga 001.cbz"))
        _ = phone.scan(phoneFolder, at: phoneRoot)
        onPhone = try XCTUnwrap(phone.books().first)
        XCTAssertTrue(onPhone.downloaded)
        XCTAssertEqual([onPhone.title, String(onPhone.page)], ["Chapter One", "3"])
        phone.update(id: onPhone.id!) { $0.page = 4; $0.finished = true; $0.lastReadAt = Date() }
        _ = sync.sync(store: phone, folderID: phoneFolder.id!, root: phoneRoot)
        XCTAssertEqual(sync.sync(store: mac, folderID: macFolder.id!, root: macRoot).changed, 1)
        let after = try XCTUnwrap(mac.books().first)
        XCTAssertEqual(after.page, 4)
        XCTAssertTrue(after.finished)
        XCTAssertEqual(after.title, "Chapter One")
    }

    func testRenamedFileKeepsItsRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).standardizedFileURL
        let comics = root.appendingPathComponent("Comics")
        try FileManager.default.createDirectory(at: comics, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = comics.appendingPathComponent("scan_0042_final.cbz")
        try makeComic(at: old, pages: 3, comicInfo: """
            <?xml version="1.0"?><ComicInfo><Series>Batman: Year One</Series><Number>2</Number><Title>War on Crime</Title><Year>1987</Year></ComicInfo>
            """)
        let store = try LibraryStore(directory: root.appendingPathComponent("Store"))
        let folder = try store.addFolder(path: comics.path, bookmark: Data())
        _ = store.scan(folder, at: comics)
        let book = try XCTUnwrap(store.books().first)
        XCTAssertEqual(book.suggestedFileName, "Batman - Year One 002 - War on Crime (1987)")
        store.update(id: book.id!) { $0.page = 2 }
        store.setPanelOverride([CGRect(x: 0, y: 0, width: 0.5, height: 0.5)], bookID: book.id!, page: 1)

        let new = comics.appendingPathComponent(book.suggestedFileName + ".cbz")
        try FileManager.default.moveItem(at: old, to: new)
        let moved = try store.relocate(id: book.id!, to: new)
        XCTAssertEqual(moved.id, book.id)
        XCTAssertEqual(moved.path, new.path)
        XCTAssertEqual(moved.page, 2)
        XCTAssertEqual(store.panelOverrides(bookID: book.id!).count, 1)

        // The next scan sees the same comic, not a new one plus a missing one.
        let result = store.scan(folder, at: comics)
        XCTAssertEqual([result.added, result.removed], [0, 0])
        XCTAssertEqual(store.books().count, 1)

        // Names built from the file name alone stay as they are.
        var plain = book
        plain.series = "Saga"; plain.number = 1; plain.title = "Saga #1"; plain.year = 2012
        XCTAssertEqual(plain.suggestedFileName, "Saga 001 (2012)")
        plain.series = ""; plain.number = nil; plain.title = "A/B: C."; plain.year = nil
        XCTAssertEqual(plain.suggestedFileName, "A-B - C")
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

    func testPanelsSavedInsideCBZComeBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Edited.cbz")
        try makeComic(at: url, pages: 3)

        let book = try ComicBook(url: url)
        XCTAssertTrue(book.canStorePanels)
        XCTAssertNil(book.embeddedPanels(forPage: 0))
        let drawn = [CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.3), CGRect(x: 0.55, y: 0.1, width: 0.35, height: 0.3)]
        try book.storePanels([1: drawn, 2: []])
        // Still readable through the same object after the file was rewritten…
        XCTAssertEqual(try book.image(at: 2).width, 20)
        XCTAssertEqual(book.embeddedPanels(forPage: 1), drawn)
        // …and saving again replaces rather than piles up.
        try book.storePanels([1: [drawn[0]]])

        let reopened = try ComicBook(url: url)
        XCTAssertEqual(reopened.pageCount, 3)
        XCTAssertEqual(reopened.storedPanels(), [1: [drawn[0]]])
        XCTAssertNil(reopened.embeddedPanels(forPage: 2))
    }

    func testReadsACBFFrames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("WithFrames.cbz")
        try makeComic(at: url, pages: 2)      // 20 × 30 pixel pages named p1.png, p2.png
        let acbf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ACBF xmlns="http://www.acbf.info/xml/acbf/1.1"><meta-data><book-info>
            <coverpage><image href="p1.png"/><frame points="0,0 20,0 20,30 0,30"/></coverpage></book-info></meta-data>
            <body><page><image href="P2.png"/>
            <frame points="2,3 10,3 10,15 2,15"/><frame points="10,15 20,15 20,30 10,30"/><text-layer lang="en"/></page></body></ACBF>
            """
        let archive = try Archive(url: url, accessMode: .update)
        let data = Data(acbf.utf8)
        try archive.addEntry(with: "WithFrames.acbf", type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
        let book = try ComicBook(url: url)
        XCTAssertEqual(book.embeddedPanels(forPage: 0), [CGRect(x: 0, y: 0, width: 1, height: 1)])
        let panels = try XCTUnwrap(book.embeddedPanels(forPage: 1))
        XCTAssertEqual(panels.count, 2)
        XCTAssertEqual(panels[0].minX, 0.1, accuracy: 0.001); XCTAssertEqual(panels[0].height, 0.4, accuracy: 0.001)
        XCTAssertEqual(panels[1].minY, 0.5, accuracy: 0.001)
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
        // A small page is drawn large enough to stay sharp when zoomed in: 3600 pixels on its long side.
        XCTAssertEqual(book.pageSize(at: 0), CGSize(width: 2400, height: 3600))
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
