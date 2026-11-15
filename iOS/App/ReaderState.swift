import ComicCore
import SwiftUI

/// The pages on screen: one, or two facing pages when the device is held sideways.
struct SpreadDisplay: Equatable {
    let id: Int
    let images: [CGImage]
    static func == (a: SpreadDisplay, b: SpreadDisplay) -> Bool { a.id == b.id }
}

/// The panel to zoom in on, in the spread's unit coordinates.
struct PanelFocus: Equatable {
    let id: Int
    let rect: CGRect
}

private final class ImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

enum MobilePrefs {
    static let pageBeforePanels = "wholePageBeforePanels"
    static let pageAfterPanels = "wholePageAfterPanels"
    static let twoPagesInLandscape = "twoPagesInLandscape"
    static let fitWidthInLandscape = "fitWidthInLandscape"
    static var wholePageBeforePanels: Bool { UserDefaults.standard.bool(forKey: pageBeforePanels) }
    static var wholePageAfterPanels: Bool { UserDefaults.standard.bool(forKey: pageAfterPanels) }
}

/// One comic being read.
@MainActor
@Observable
final class ReaderState: Identifiable {
    let book: ComicBook
    let recordID: Int64?
    let title: String

    private(set) var spreads: [Spread] = []
    private(set) var spreadIndex = 0
    private(set) var display: SpreadDisplay?
    private(set) var focus: PanelFocus?
    private(set) var pageError: String?
    /// What panel-by-panel reading stops at on this page, in the spread's unit coordinates.
    private(set) var panels: [CGRect] = []
    private(set) var panelIndex = 0
    /// Two facing pages side by side (the device is sideways and the reader wants that).
    private(set) var twoUp = false

    var panelMode: Bool {
        didSet {
            guard oldValue != panelMode else { return }
            enterAtLastPanel = false
            showCurrent()
            saveProgress()
        }
    }
    var direction: ReadingDirection {
        didSet {
            guard oldValue != direction else { return }
            panelCache = [:]          // reading order depends on it
            showCurrent()
            saveProgress()
        }
    }

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var focusCounter = 0
    @ObservationIgnored private var enterAtLastPanel = false
    @ObservationIgnored private var sizesScanned = false
    @ObservationIgnored private var sizeScan: Task<Void, Never>?
    @ObservationIgnored private var panelCache: [Int: [CGRect]] = [:]
    @ObservationIgnored private var customPanels: [Int: [CGRect]] = [:]
    @ObservationIgnored private var inFlight: [Int: Task<CGImage?, Never>] = [:]
    @ObservationIgnored private let pageCache = NSCache<NSNumber, ImageBox>()
    private nonisolated static let maxPagePixels = 3072

    init(book: ComicBook, record: LibraryBook?, startPage: Int? = nil, panelMode: Bool? = nil) {
        self.book = book
        recordID = record?.id
        title = record?.title ?? book.title
        self.panelMode = panelMode ?? record?.panelMode ?? false
        direction = record?.direction.flatMap(ReadingDirection.init(rawValue:)) ?? .leftToRight
        pageCache.countLimit = 6
        if let recordID, let store = MobileLibrary.shared.store { customPanels = store.panelOverrides(bookID: recordID) }
        rebuildSpreads(keeping: 0)
        let page = startPage ?? (record?.finished == true ? 0 : record?.page ?? 0)
        spreadIndex = SpreadBuilder.index(of: min(max(0, page), max(0, book.pageCount - 1)), in: spreads)
        showCurrent()
        saveProgress()
    }

    // MARK: Where we are

    var currentPages: [Int] { spreads.indices.contains(spreadIndex) ? spreads[spreadIndex].pages : [] }
    var currentPage: Int { currentPages.first ?? 0 }
    var canGoForward: Bool { spreadIndex + 1 < spreads.count }

    /// Whether the page has anything to zoom in on: several panels, or a single one smaller than the page.
    private var hasPanelSteps: Bool {
        panels.count > 1 || panels.first.map { !isWholeSpread($0) } == true
    }

    var positionLabel: String {
        let pages = currentPages
        guard let first = pages.first, let last = pages.last else { return "" }
        let page = first == last ? "Page \(first + 1) of \(book.pageCount)" : "Pages \(first + 1)–\(last + 1) of \(book.pageCount)"
        guard panelMode, hasPanelSteps, panels.indices.contains(panelIndex) else { return page }
        // The whole-page views before and after the panels are not panels and are not counted as such.
        if isWholeSpread(panels[panelIndex]) { return "\(page) · Whole page" }
        let real = panels.filter { !isWholeSpread($0) }.count
        let number = panels[...panelIndex].filter { !isWholeSpread($0) }.count
        return "\(page) · Panel \(number) of \(real)"
    }

    // MARK: Moving

    func next() {
        if panelMode, panelIndex + 1 < panels.count { return showPanel(panelIndex + 1) }
        guard canGoForward else { return }
        spreadIndex += 1
        enterAtLastPanel = false
        showCurrent()
        saveProgress()
    }

    func previous() {
        if panelMode, panelIndex > 0 { return showPanel(panelIndex - 1) }
        guard spreadIndex > 0 else { return }
        spreadIndex -= 1
        enterAtLastPanel = panelMode       // going back lands on the page's last panel
        showCurrent()
        saveProgress()
    }

    func goToSpread(_ index: Int) {
        guard spreads.indices.contains(index), index != spreadIndex else { return }
        spreadIndex = index
        enterAtLastPanel = false
        showCurrent()
        saveProgress()
    }

    func saveProgress() {
        guard let recordID else { return }
        let page = currentPage, direction = direction.rawValue, panelMode = panelMode
        // Reaching the last page finishes the comic (a one-page comic is finished by opening it).
        let atEnd = !canGoForward
        MobileLibrary.shared.update(recordID) {
            $0.page = page; $0.direction = direction; $0.panelMode = panelMode
            $0.lastReadAt = Date()
            if atEnd { $0.finished = true } else if page > 0 { $0.finished = false }
        }
    }

    // MARK: Layout

    /// Called as the device turns: two facing pages when it is sideways and the reader wants them.
    func setTwoUp(_ wanted: Bool) {
        guard wanted != twoUp else { return }
        let page = currentPage
        twoUp = wanted
        rebuildSpreads(keeping: page)
        enterAtLastPanel = false
        showCurrent()
        if wanted { scanPageSizes() }
    }

    private func rebuildSpreads(keeping page: Int) {
        let book = book, scanned = sizesScanned
        spreads = SpreadBuilder.spreads(pageCount: book.pageCount, layout: twoUp ? .double : .single) { index in
            guard scanned, let size = book.pageSize(at: index) else { return false }
            return size.width > size.height
        }
        spreadIndex = SpreadBuilder.index(of: page, in: spreads)
    }

    /// Wide pages are already two pages in one scan and must stand alone; finding them means reading
    /// every page's size, which is done once, in the background.
    private func scanPageSizes() {
        guard !sizesScanned, sizeScan == nil else { return }
        let book = book
        sizeScan = Task {
            await Task.detached(priority: .utility) {
                for index in 0..<book.pageCount { _ = book.pageSize(at: index) }
            }.value
            sizesScanned = true
            guard twoUp else { return }
            let before = spreads
            rebuildSpreads(keeping: currentPage)
            if spreads != before { showCurrent() }
        }
    }

    // MARK: Showing pages

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
            panels = readingSteps(for: found)
            panelIndex = enterAtLastPanel ? max(0, panels.count - 1) : 0
            enterAtLastPanel = false
            display = SpreadDisplay(id: token, images: images)
            updateFocus()
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
        let book = book
        return await Task.detached(priority: .utility) { try? book.image(at: page, maxPixelSize: 240) }.value
    }

    // MARK: Panels

    /// What panel-by-panel reading stops at on a page: its panels, with the whole page shown first
    /// and/or last when the reader asked for that. A page that is one picture is left alone, and so
    /// is an end that already shows the whole page.
    private func readingSteps(for found: [CGRect]) -> [CGRect] {
        guard !found.isEmpty, !(found.count == 1 && isWholeSpread(found[0])) else { return found }
        var steps = found
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        if MobilePrefs.wholePageBeforePanels, let first = steps.first, !isWholeSpread(first) { steps.insert(whole, at: 0) }
        if MobilePrefs.wholePageAfterPanels, let last = steps.last, !isWholeSpread(last) { steps.append(whole) }
        return steps
    }

    private func showPanel(_ index: Int) {
        panelIndex = index
        updateFocus()
    }

    private func updateFocus() {
        // A page that is one big picture is simply shown whole.
        guard panelMode, hasPanelSteps, panels.indices.contains(panelIndex) else { return focus = nil }
        focusCounter += 1
        focus = PanelFocus(id: focusCounter, rect: panels[panelIndex])
    }

    private func isWholeSpread(_ rect: CGRect) -> Bool {
        rect.minX < 0.01 && rect.minY < 0.01 && rect.width > 0.98 && rect.height > 0.98
    }

    /// Panels of every page in the spread, in reading order, in the spread's unit coordinates.
    private func spreadPanels(pages: [Int], images: [CGImage]) async -> [CGRect] {
        let direction = direction
        var perPage: [[CGRect]] = []
        for (page, image) in zip(pages, images) {
            // Panels set by hand win, then ones that came inside the file, then detection.
            if let custom = customPanels[page] { perPage.append(custom.isEmpty ? [PanelDetector.wholePage] : custom); continue }
            if let cached = panelCache[page] { perPage.append(cached); continue }
            let book = book
            if let embedded = await Task.detached(priority: .userInitiated, operation: { book.embeddedPanels(forPage: page) }).value {
                let panels = embedded.isEmpty ? [PanelDetector.wholePage] : embedded
                panelCache[page] = panels
                perPage.append(panels)
                continue
            }
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

    /// The reader changed a whole-page setting: apply it to the page on screen.
    func readingOptionsChanged() {
        if panelMode { showCurrent() }
    }
}
