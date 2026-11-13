import AppKit
import ComicCore
import Observation

/// What the canvas should show: the current spread's pages, already in left-to-right screen order.
struct SpreadDisplay {
    let id: Int
    let images: [CGImage]
}

/// The panel to zoom in on, as a unit rectangle within the spread (origin top left).
struct PanelFocus: Equatable {
    let id: Int
    let rect: CGRect
}

/// State of one reader window.
@MainActor
@Observable
final class ReaderModel {
    let book: ComicBook

    var layout: PageLayout { didSet { if layout != oldValue { layoutChanged() } } }
    var direction: ReadingDirection { didSet { if direction != oldValue { directionChanged() } } }
    var fit: FitMode
    /// Panel-by-panel reading: step through each page's panels instead of whole pages.
    var panelMode: Bool { didSet { if panelMode != oldValue { panelModeChanged() } } }
    private(set) var panels: [CGRect] = []
    private(set) var panelIndex = 0
    private(set) var focus: PanelFocus?
    private(set) var spreads: [Spread]
    private(set) var spreadIndex = 0
    private(set) var display: SpreadDisplay?
    private(set) var pageError: String?

    @ObservationIgnored weak var canvas: ReaderScrollView?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var focusCounter = 0
    @ObservationIgnored private var enterAtLastPanel = false
    @ObservationIgnored private var panelCache: [Int: [CGRect]] = [:]
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
        panelMode = saved?.panelMode ?? false
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
        let page = first == last ? "Page \(first + 1) of \(book.pageCount)" : "Pages \(first + 1)–\(last + 1) of \(book.pageCount)"
        return panelMode && panels.count > 1 ? "\(page) · Panel \(panelIndex + 1) of \(panels.count)" : page
    }

    func goToSpread(_ index: Int) {
        let clamped = max(0, min(spreads.count - 1, index))
        guard clamped != spreadIndex else { return }
        spreadIndex = clamped
        showCurrent()
        saveProgress()
    }

    /// Forward one step: the next panel in panel mode, otherwise the next page.
    func next() {
        if panelMode, panelIndex + 1 < panels.count { return showPanel(panelIndex + 1) }
        goToSpread(spreadIndex + 1)
    }

    func previous() {
        if panelMode, panelIndex > 0 { return showPanel(panelIndex - 1) }
        enterAtLastPanel = panelMode && canGoBack
        goToSpread(spreadIndex - 1)
    }
    func first() { goToSpread(0) }
    func last() { goToSpread(spreads.count - 1) }
    func goToPage(_ page: Int) { goToSpread(SpreadBuilder.index(of: page, in: spreads)) }

    /// Turns toward the left (-1) or right (+1) edge of the screen, whichever way the book reads.
    func turn(visual delta: Int) {
        (delta > 0) == (direction == .leftToRight) ? next() : previous()
    }

    func saveProgress() {
        let page = currentPage, layout = layout.rawValue, direction = direction.rawValue, panelMode = panelMode
        Recents.update(book.url) { $0.page = page; $0.layout = layout; $0.direction = direction; $0.panelMode = panelMode }
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
        panelCache.removeAll()      // panel order depends on the reading direction
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
            // In panel mode the page and its first panel appear together, so find the panels first.
            let found = panelMode ? await spreadPanels(pages: ordered, images: images) : []
            guard token == generation else { return }
            pageError = nil
            panels = found
            panelIndex = enterAtLastPanel ? max(0, found.count - 1) : 0
            enterAtLastPanel = false
            updateFocus()
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

    // MARK: - Panels

    private func panelModeChanged() {
        enterAtLastPanel = false
        showCurrent()
        saveProgress()
    }

    private func showPanel(_ index: Int) {
        panelIndex = index
        updateFocus()
    }

    private func updateFocus() {
        // A page that is one big panel is simply shown whole.
        guard panelMode, panels.count > 1, panels.indices.contains(panelIndex) else { return focus = nil }
        focusCounter += 1
        focus = PanelFocus(id: focusCounter, rect: panels[panelIndex])
    }

    /// Panels of every page in the spread, in reading order, in the spread's unit coordinates.
    /// `pages` and `images` are in screen order (left to right).
    private func spreadPanels(pages: [Int], images: [CGImage]) async -> [CGRect] {
        let direction = direction
        var perPage: [[CGRect]] = []
        for (page, image) in zip(pages, images) {
            if let cached = panelCache[page] { perPage.append(cached); continue }
            let found = await Task.detached(priority: .userInitiated) { PanelDetector.detect(in: image, direction: direction) }.value
            panelCache[page] = found
            perPage.append(found)
        }
        // Facing pages are drawn at the same height, so widths are proportional to aspect ratios.
        let widths = images.map { CGFloat($0.width) / CGFloat($0.height) }
        let total = widths.reduce(0, +)
        var result: [[CGRect]] = []
        var offset: CGFloat = 0
        for (index, found) in perPage.enumerated() {
            let share = widths[index] / total
            result.append(found.map { CGRect(x: offset + $0.minX * share, y: $0.minY, width: $0.width * share, height: $0.height) })
            offset += share
        }
        // Read the right-hand page first in a right-to-left book.
        return (direction == .rightToLeft ? result.reversed() : result).flatMap { $0 }
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
