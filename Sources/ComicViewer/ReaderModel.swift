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

    /// Panel editing: the page is shown whole with its panels drawn over it, to fix what detection got wrong.
    private(set) var isEditingPanels = false
    /// The panels being edited, in reading order, in the spread's unit coordinates.
    private(set) var editPanels: [CGRect] = []
    var editSelection: Int?
    private(set) var spreads: [Spread]
    private(set) var spreadIndex = 0
    private(set) var display: SpreadDisplay?
    private(set) var pageError: String?

    @ObservationIgnored weak var canvas: ReaderScrollView?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var focusCounter = 0
    @ObservationIgnored private var enterAtLastPanel = false
    @ObservationIgnored private var panelCache: [Int: [CGRect]] = [:]
    /// Pages whose panels were drawn by hand (page unit coordinates); these win over detection.
    @ObservationIgnored private var customPanels: [Int: [CGRect]] = [:]
    @ObservationIgnored private var editDirty = false
    /// Pages whose panels from the file were discarded this session ("Detect Again").
    @ObservationIgnored private var ignoredEmbedded: Set<Int> = []
    @ObservationIgnored private var fileSavePending = false
    /// Where each page of the current spread sits across its width: (page, left edge, share), left to right.
    @ObservationIgnored private var spreadGeometry: [(page: Int, offset: CGFloat, share: CGFloat)] = []
    @ObservationIgnored private var sizesScanned = false
    @ObservationIgnored private var inFlight: [Int: Task<CGImage?, Never>] = [:]
    @ObservationIgnored private let pageCache = NSCache<NSNumber, ImageBox>()
    @ObservationIgnored private let thumbnailCache = NSCache<NSNumber, ImageBox>()

    /// Longest side pages are decoded at. Enough for a 5K display; keeps huge scans from eating memory.
    private nonisolated static let maxPagePixels = 4096

    let title: String
    /// The comic's entry in the library database, where reading position and settings are kept.
    @ObservationIgnored private let recordID: Int64?

    init(book: ComicBook, record saved: LibraryBook?) {
        self.book = book
        recordID = saved?.id
        title = saved.map { book in
            [book.series == book.title ? "" : book.series, book.issueLabel ?? "", book.title].filter { !$0.isEmpty }.joined(separator: " — ")
        } ?? book.title
        layout = saved?.layout.flatMap(PageLayout.init(rawValue:)) ?? Prefs.defaultLayout
        direction = saved?.direction.flatMap(ReadingDirection.init(rawValue:)) ?? Prefs.defaultDirection
        fit = Prefs.defaultFit
        panelMode = saved?.panelMode ?? false
        if let id = saved?.id, let store = Library.shared.store { customPanels = store.panelOverrides(bookID: id) }
        pageCache.countLimit = 10
        thumbnailCache.countLimit = 600
        spreads = SpreadBuilder.spreads(pageCount: book.pageCount, layout: .single) { _ in false }
        // A finished comic starts over.
        rebuildSpreads(keeping: saved?.finished == true ? 0 : min(saved?.page ?? 0, book.pageCount - 1))
        showCurrent()
        if layout == .double { scanSizes() }
        saveProgress()
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
        if isEditingPanels { return "\(page) · Editing \(editPanels.count) panel\(editPanels.count == 1 ? "" : "s")" }
        return panelMode && panels.count > 1 ? "\(page) · Panel \(panelIndex + 1) of \(panels.count)" : page
    }

    func goToSpread(_ index: Int) {
        let clamped = max(0, min(spreads.count - 1, index))
        guard clamped != spreadIndex else { return }
        commitPanelEdits()      // turning the page while editing keeps the work and carries on with the next page
        spreadIndex = clamped
        showCurrent()
        saveProgress()
    }

    /// Forward one step: the next panel in panel mode, otherwise the next page.
    func next() {
        if panelMode, !isEditingPanels, panelIndex + 1 < panels.count { return showPanel(panelIndex + 1) }
        goToSpread(spreadIndex + 1)
    }

    func previous() {
        if panelMode, !isEditingPanels, panelIndex > 0 { return showPanel(panelIndex - 1) }
        enterAtLastPanel = panelMode && !isEditingPanels && canGoBack
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
        guard let recordID else { return }
        let page = currentPage, layout = layout.rawValue, direction = direction.rawValue, panelMode = panelMode
        // Reaching the last page finishes the comic (a one-page comic is finished by opening it).
        let atEnd = !canGoForward
        Library.shared.update(recordID) {
            $0.page = page; $0.layout = layout; $0.direction = direction; $0.panelMode = panelMode
            $0.lastReadAt = Date()
            if atEnd { $0.finished = true } else if page > 0 { $0.finished = false }
        }
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
        commitPanelEdits()
        rebuildSpreads(keeping: currentPage)
        showCurrent()
        saveProgress()
        if layout == .double { scanSizes() }
    }

    private func directionChanged() {
        commitPanelEdits()
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
            let found = panelMode || isEditingPanels ? await spreadPanels(pages: ordered, images: images) : []
            guard token == generation else { return }
            pageError = nil
            panels = found
            if isEditingPanels {
                // A page shown whole has nothing to adjust: start it with no panels rather than one giant one.
                editPanels = found.count == 1 && isWholeSpread(found[0]) ? [] : found
                editSelection = nil
                editDirty = false
            }
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
        guard panelMode, !isEditingPanels, panels.count > 1, panels.indices.contains(panelIndex) else { return focus = nil }
        focusCounter += 1
        focus = PanelFocus(id: focusCounter, rect: panels[panelIndex])
    }

    /// Panels of every page in the spread, in reading order, in the spread's unit coordinates.
    /// `pages` and `images` are in screen order (left to right).
    private func spreadPanels(pages: [Int], images: [CGImage]) async -> [CGRect] {
        let direction = direction
        var perPage: [[CGRect]] = []
        for (page, image) in zip(pages, images) {
            if let custom = customPanels[page] { perPage.append(custom.isEmpty ? [PanelDetector.wholePage] : custom); continue }
            if let cached = panelCache[page] { perPage.append(cached); continue }
            // Panels that came inside the file (saved by Comic Viewer elsewhere, or ACBF frames) beat detection.
            let book = book
            if !ignoredEmbedded.contains(page),
               let embedded = await Task.detached(priority: .userInitiated, operation: { book.embeddedPanels(forPage: page) }).value {
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
        spreadGeometry = []
        for (index, found) in perPage.enumerated() {
            let share = widths[index] / total
            spreadGeometry.append((pages[index], offset, share))
            result.append(found.map { CGRect(x: offset + $0.minX * share, y: $0.minY, width: $0.width * share, height: $0.height) })
            offset += share
        }
        // Read the right-hand page first in a right-to-left book.
        return (direction == .rightToLeft ? result.reversed() : result).flatMap { $0 }
    }

    // MARK: - Editing panels

    private func isWholeSpread(_ rect: CGRect) -> Bool {
        rect.minX < 0.01 && rect.minY < 0.01 && rect.width > 0.98 && rect.height > 0.98
    }

    func togglePanelEditing() {
        if isEditingPanels {
            commitPanelEdits()
            isEditingPanels = false
            savePanelsToFile()
        } else {
            isEditingPanels = true
        }
        showCurrent()
    }

    /// Called as the reader draws, moves, resizes, reorders or deletes panels.
    func panelsEdited(_ panels: [CGRect], selection: Int?) {
        if panels != editPanels { editPanels = panels; editDirty = true }
        editSelection = selection
    }

    func deleteSelectedPanel() {
        guard let index = editSelection, editPanels.indices.contains(index) else { return }
        var panels = editPanels
        panels.remove(at: index)
        panelsEdited(panels, selection: panels.isEmpty ? nil : min(index, panels.count - 1))
    }

    func movePanels(from source: IndexSet, to destination: Int) {
        var panels = editPanels
        let moving = source.map { panels[$0] }
        // Same arithmetic as Array.move(fromOffsets:toOffset:), which lives in SwiftUI.
        let before = source.filter { $0 < destination }.count
        for index in source.reversed() { panels.remove(at: index) }
        panels.insert(contentsOf: moving, at: destination - before)
        panelsEdited(panels, selection: nil)
    }

    func removeAllPanels() { panelsEdited([], selection: nil) }

    /// Throws away hand-drawn panels for the pages on screen and detects them again.
    func redetectPanels() {
        for page in currentPages {
            customPanels[page] = nil
            panelCache[page] = nil
            ignoredEmbedded.insert(page)
            if let recordID { Library.shared.store?.setPanelOverride(nil, bookID: recordID, page: page) }
        }
        fileSavePending = true
        editDirty = false
        showCurrent()
    }

    /// Saves the edited panels, page by page. A page left with no panels is shown whole from now on.
    func commitPanelEdits() {
        guard isEditingPanels, editDirty, !spreadGeometry.isEmpty else { return }
        editDirty = false
        var perPage: [Int: [CGRect]] = [:]
        for geometry in spreadGeometry { perPage[geometry.page] = [] }
        for rect in editPanels {
            // A panel belongs to the page its centre is on, and is clipped to that page.
            guard let home = spreadGeometry.first(where: { rect.midX >= $0.offset && rect.midX <= $0.offset + $0.share }) ?? spreadGeometry.last else { continue }
            let local = CGRect(x: (rect.minX - home.offset) / home.share, y: rect.minY, width: rect.width / home.share, height: rect.height)
                .intersection(PanelDetector.wholePage)
            if !local.isNull, local.width > 0.01, local.height > 0.01 { perPage[home.page, default: []].append(local) }
        }
        for (page, panels) in perPage {
            customPanels[page] = panels
            if let recordID { Library.shared.store?.setPanelOverride(panels, bookID: recordID, page: page) }
        }
        fileSavePending = true
    }

    /// Writes every hand-set panel into the comic file, if the reader wants that and the format allows it,
    /// so the edits travel with the comic. Asks once, the first time there is something to save.
    func savePanelsToFile() {
        guard fileSavePending, book.canStorePanels else { return }
        if Prefs.panelStorageChoice == .ask {
            let alert = NSAlert()
            alert.messageText = "Save panel edits inside the comic file too?"
            alert.informativeText = "Comic Viewer always remembers your panel edits itself. It can also store them in the comic, as a small file inside the CBZ (or in the folder), so they come along if you move or copy the comic.\n\nThis changes the comic file. Its pages are not touched. You can change your mind in Settings."
            alert.addButton(withTitle: "Save in Comic File")
            alert.addButton(withTitle: "Keep in Comic Viewer Only")
            Prefs.panelStorageChoice = alert.runModal() == .alertFirstButtonReturn ? .file : .app
        }
        fileSavePending = false
        guard Prefs.panelStorageChoice == .file else { return }
        // What the file already holds, with this session's discards removed and everything set here on top.
        let book = book, custom = customPanels, ignored = ignoredEmbedded, title = title
        Task.detached(priority: .utility) {
            var pages = book.storedPanels().filter { !ignored.contains($0.key) }
            pages.merge(custom) { _, new in new }
            do {
                try book.storePanels(pages)
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Couldn’t save panels inside “\(title)”"
                    alert.informativeText = "Your edits are still saved in Comic Viewer. \(error.localizedDescription)"
                    alert.runModal()
                }
            }
        }
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
