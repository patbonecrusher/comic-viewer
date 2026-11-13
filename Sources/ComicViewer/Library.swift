import AppKit
import ComicCore
import Observation

/// The user's collection: library folders, the comics in them, and anything opened directly.
@MainActor
@Observable
final class Library {
    static let shared = Library()

    private(set) var books: [LibraryBook] = []
    private(set) var folders: [LibraryFolder] = []
    /// Shown while folders are being scanned, e.g. "Scanning Comics… 12 of 240".
    private(set) var scanStatus: String?
    private(set) var storeError: String?

    @ObservationIgnored nonisolated let store: LibraryStore?
    @ObservationIgnored private var folderURLs: [Int64: URL] = [:]
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var rescanRequested = false

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Comic Viewer", isDirectory: true)
        do {
            store = try LibraryStore(directory: support)
        } catch {
            store = nil
            storeError = error.localizedDescription
        }
        reload()
        rescan()
    }

    func reload() {
        guard let store else { return }
        books = store.books()
        folders = store.folders()
    }

    // MARK: Folders

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders that hold your comics. Comic Viewer reads them in place and never moves them."
        panel.prompt = "Add to Library"
        guard panel.runModal() == .OK else { return }
        addFolders(panel.urls)
    }

    func addFolders(_ urls: [URL]) {
        guard let store else { return }
        for url in urls {
            let url = url.standardizedFileURL
            guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil),
                  let folder = try? store.addFolder(path: url.path, bookmark: bookmark), let id = folder.id else { continue }
            folderURLs[id] = url
        }
        reload()
        rescan()
    }

    func removeFolder(_ folder: LibraryFolder) {
        guard let store, let id = folder.id else { return }
        try? store.removeFolder(id: id)
        folderURLs[id]?.stopAccessingSecurityScopedResource()
        folderURLs[id] = nil
        reload()
    }

    /// The folder's location with sandbox access switched on (kept for the life of the app).
    private func resolvedURL(for folder: LibraryFolder) -> URL? {
        guard let id = folder.id else { return nil }
        if let url = folderURLs[id] { return url }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: folder.bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        folderURLs[id] = url
        return url
    }

    /// Looks for new, changed and deleted comics in every library folder.
    func rescan() {
        guard let store else { return }
        if scanning { rescanRequested = true; return }
        let targets = folders.compactMap { folder in resolvedURL(for: folder).map { (folder, $0) } }
        guard !targets.isEmpty else { return }
        scanning = true
        Task {
            for (folder, url) in targets {
                scanStatus = "Scanning \(folder.name)…"
                let name = folder.name
                _ = await Task.detached(priority: .utility) {
                    var lastReport = Date.distantPast
                    return store.scan(folder, at: url) { done, total in
                        guard Date().timeIntervalSince(lastReport) > 0.5 else { return }
                        lastReport = Date()
                        Task { @MainActor in
                            let library = Library.shared
                            library.scanStatus = "Scanning \(name)… \(done) of \(total)"
                            library.reload()
                        }
                    }
                }.value
                reload()
            }
            scanStatus = nil
            scanning = false
            if rescanRequested { rescanRequested = false; rescan() }
        }
    }

    // MARK: Books

    /// Where a comic is, with sandbox access. Nil when its bookmark no longer resolves.
    func url(for book: LibraryBook) -> URL? {
        if let folderID = book.folderID, let folder = folders.first(where: { $0.id == folderID }) {
            _ = resolvedURL(for: folder)
            return URL(fileURLWithPath: book.path)
        }
        guard let bookmark = book.bookmark else { return URL(fileURLWithPath: book.path) }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()   // balanced never: the app keeps access for its lifetime
        return url
    }

    /// The record for a comic that was just opened, creating one (with a sandbox bookmark and cover)
    /// the first time. Does file work; call it off the main thread.
    nonisolated func record(opened comic: ComicBook) -> LibraryBook? {
        guard let store else { return nil }
        if let existing = store.book(path: comic.url.path) { return existing }
        let bookmark = try? comic.url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        return try? store.record(comic, bookmark: bookmark)
    }

    func update(_ id: Int64, _ change: (inout LibraryBook) -> Void) {
        guard let store else { return }
        store.update(id: id, change)
        guard let fresh = store.book(id: id) else { return }
        if let index = books.firstIndex(where: { $0.id == id }) {
            if books[index] != fresh { books[index] = fresh }
        } else {
            books.append(fresh)
        }
    }

    func setFinished(_ finished: Bool, for book: LibraryBook) {
        guard let id = book.id else { return }
        update(id) { $0.finished = finished; if !finished { $0.page = 0; $0.lastReadAt = nil } }
    }

    /// Forgets a comic (the file stays where it is). One in a library folder comes back on the next scan.
    func remove(_ book: LibraryBook) {
        guard let store, let id = book.id else { return }
        store.remove(ids: [id])
        books.removeAll { $0.id == id }
        CoverCache.shared.forget(id)
    }

    var recentlyRead: [LibraryBook] {
        books.filter { $0.lastReadAt != nil }.sorted { $0.lastReadAt! > $1.lastReadAt! }
    }
}

/// Cover thumbnails, loaded from the store's JPEGs on demand.
@MainActor
final class CoverCache {
    static let shared = CoverCache()
    private let cache = NSCache<NSNumber, NSImage>()

    func image(for id: Int64) async -> NSImage? {
        if let cached = cache.object(forKey: id as NSNumber) { return cached }
        guard let url = Library.shared.store?.coverURL(for: id) else { return nil }
        let loaded = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
        }.value
        if let loaded { cache.setObject(loaded, forKey: id as NSNumber) }
        return loaded
    }

    func forget(_ id: Int64) { cache.removeObject(forKey: id as NSNumber) }
}
