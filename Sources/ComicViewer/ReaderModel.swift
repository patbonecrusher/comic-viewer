import AppKit
import ComicCore
import Observation

/// What the canvas should show: the current spread's pages, already in left-to-right screen order.
struct SpreadDisplay {
    let id: Int
    let images: [CGImage]
}

/// State of one reader window.
@MainActor
@Observable
final class ReaderModel {
    let book: ComicBook

    var layout: PageLayout { didSet { if layout != oldValue { layoutChanged() } } }
    var direction: ReadingDirection { didSet { if direction != oldValue { directionChanged() } } }
    var fit: FitMode
    private(set) var spreads: [Spread]
    private(set) var spreadIndex = 0
    private(set) var display: SpreadDisplay?
    private(set) var pageError: String?

    @ObservationIgnored weak var canvas: ReaderScrollView?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sizesScanned = false
    @ObservationIgnored private var inFlight: [Int: Task<CGImage?, Never>] = [:]
    @ObservationIgnored private let pageCache = NSCache<NSNumber, ImageBox>()
    @ObservationIgnored private let thumbnailCache = NSCache<NSNumber, ImageBox>()

    /// Longest side pages are decoded at. Enough for a 5K display; keeps huge scans from eating memory.
    private nonisolated static let maxPagePixels = 4096

    init(book: ComicBook) {
        self.book = book
        let saved = Recents.entry(for: book.url)
        layout = saved?.layout.flatMap(PageLayout.init(rawValue:)) ?? Prefs.defaultLayout
        direction = saved?.direction.flatMap(ReadingDirection.init(rawValue:)) ?? Prefs.defaultDirection
        fit = Prefs.defaultFit
        pageCache.countLimit = 10
        thumbnailCache.countLimit = 600
        spreads = SpreadBuilder.spreads(pageCount: book.pageCount, layout: .single) { _ in false }
        rebuildSpreads(keeping: min(saved?.page ?? 0, book.pageCount - 1))
        showCurrent()
        if layout == .double { scanSizes() }
    }

    // MARK: - Position

    var currentPages: [Int] { spreads.isEmpty ? [] : spreads[spreadIndex].pages }
    var currentPage: Int { currentPages.first ?? 0 }
    var canGoForward: Bool { spreadIndex + 1 < spreads.count }
    var canGoBack: Bool { spreadIndex > 0 }

    var positionLabel: String {
        let pages = currentPages
        guard let first = pages.first, let last = pages.last else { return "" }
        return first == last ? "Page \(first + 1) of \(book.pageCount)" : "Pages \(first + 1)–\(last + 1) of \(book.pageCount)"
    }

    func goToSpread(_ index: Int) {
        let clamped = max(0, min(spreads.count - 1, index))
        guard clamped != spreadIndex else { return }
        spreadIndex = clamped
        showCurrent()
        saveProgress()
    }

    func next() { goToSpread(spreadIndex + 1) }
    func previous() { goToSpread(spreadIndex - 1) }
    func first() { goToSpread(0) }
    func last() { goToSpread(spreads.count - 1) }
    func goToPage(_ page: Int) { goToSpread(SpreadBuilder.index(of: page, in: spreads)) }

    /// Turns toward the left (-1) or right (+1) edge of the screen, whichever way the book reads.
    func turn(visual delta: Int) {
        (delta > 0) == (direction == .leftToRight) ? next() : previous()
    }

    func saveProgress() {
        let page = currentPage, layout = layout.rawValue, direction = direction.rawValue
        Recents.update(book.url) { $0.page = page; $0.layout = layout; $0.direction = direction }
    }

    // MARK: - Layout

    private func rebuildSpreads(keeping page: Int) {
        let book = book, scanned = sizesScanned
        spreads = SpreadBuilder.spreads(pageCount: book.pageCount, layout: layout) { index in
            guard scanned, let size = book.pageSize(at: index) else { return false }
            return size.width > size.height
        }
        spreadIndex = SpreadBuilder.index(of: page, in: spreads)
    }

    private func layoutChanged() {
        rebuildSpreads(keeping: currentPage)
        showCurrent()
        saveProgress()
        if layout == .double { scanSizes() }
    }

    private func directionChanged() {
        showCurrent()
        saveProgress()
    }

    /// Double-page layout needs every page's proportions to keep landscape pages on their own.
    /// Reading them means touching the whole file, so it happens once, in the background.
    private func scanSizes() {
        guard !sizesScanned else { return }
        let book = book
        Task {
            await Task.detached(priority: .utility) {
                for index in 0..<book.pageCount { _ = book.pageSize(at: index) }
            }.value
            sizesScanned = true
            guard layout == .double else { return }
            let before = spreads
            rebuildSpreads(keeping: currentPage)
            if spreads != before { showCurrent() }
        }
    }

    // MARK: - Images

    private func showCurrent() {
        generation += 1
        let token = generation
        let pages = currentPages
        let ordered = direction == .rightToLeft ? Array(pages.reversed()) : pages
        Task {
            var images: [CGImage] = []
            for page in ordered {
                guard let image = await image(for: page) else {
                    if token == generation { pageError = ComicError.unreadablePage(page).localizedDescription; display = nil }
                    return
                }
                images.append(image)
            }
            guard token == generation else { return }
            pageError = nil
            display = SpreadDisplay(id: token, images: images)
            preloadNeighbours()
        }
    }

    private func preloadNeighbours() {
        for index in [spreadIndex + 1, spreadIndex - 1] where spreads.indices.contains(index) {
            for page in spreads[index].pages { Task { _ = await image(for: page) } }
        }
    }

    private func image(for page: Int) async -> CGImage? {
        if let cached = pageCache.object(forKey: page as NSNumber) { return cached.image }
        if let running = inFlight[page] { return await running.value }
        let book = book
        let task = Task.detached(priority: .userInitiated) { try? book.image(at: page, maxPixelSize: Self.maxPagePixels) }
        inFlight[page] = task
        let image = await task.value
        inFlight[page] = nil
        if let image { pageCache.setObject(ImageBox(image), forKey: page as NSNumber) }
        return image
    }

    func thumbnail(for page: Int) async -> CGImage? {
        if let cached = thumbnailCache.object(forKey: page as NSNumber) { return cached.image }
        let book = book
        let image = await Task.detached(priority: .utility) { try? book.image(at: page, maxPixelSize: 320) }.value
        if let image { thumbnailCache.setObject(ImageBox(image), forKey: page as NSNumber) }
        return image
    }

    // MARK: - Zoom

    func setFit(_ mode: FitMode) {
        fit = mode
        if mode != .custom { UserDefaults.standard.set(mode.rawValue, forKey: Prefs.fit) }
    }

    func zoomIn() { canvas?.zoom(by: 1.25) }
    func zoomOut() { canvas?.zoom(by: 0.8) }
}

final class ImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
