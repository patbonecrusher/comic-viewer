import ComicCore
import SwiftUI
import UIKit

/// The collection on an iPhone or iPad: the comics in the app's own folder ("On My iPhone › Comic
/// Viewer" in the Files app) and in its iCloud Drive folder, which is the one the Mac app uses.
@MainActor
@Observable
final class MobileLibrary {
    static let shared = MobileLibrary()

    private(set) var books: [LibraryBook] = []
    private(set) var downloading: Set<Int64> = []
    private(set) var isScanning = false
    private(set) var cloudAvailable = false
    /// Goes up when covers arrive from another device, so cells showing a blank cover look again.
    private(set) var coverGeneration = 0
    /// Something went wrong that the reader should hear about.
    var message: String?

    @ObservationIgnored let store: LibraryStore?
    @ObservationIgnored private let localRoot: URL
    @ObservationIgnored private var cloudRoot: URL?
    @ObservationIgnored private var localFolder: LibraryFolder?
    @ObservationIgnored private var cloudFolder: LibraryFolder?
    @ObservationIgnored private var scanAgain = false
    @ObservationIgnored private let covers = NSCache<NSNumber, UIImage>()
    @ObservationIgnored private var cloudSync: Task<Void, Never>?

    private init() {
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Comic Viewer", isDirectory: true)
        localRoot = files.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
        try? files.createDirectory(at: localRoot, withIntermediateDirectories: true)
        do {
            store = try LibraryStore(directory: support)
        } catch {
            store = nil
            message = "The library couldn’t be opened: \(error.localizedDescription)"
        }
        localFolder = folder(saved: "localFolderID", at: localRoot)
        reload()
        rescan()
        findCloudFolder()
    }

    // MARK: Folders

    /// The library's record of one of the app's folders. An app's folders move when it is reinstalled
    /// or restored from a backup, so the record is found by a saved id and pointed at where the folder is now.
    private func folder(saved key: String, at url: URL) -> LibraryFolder? {
        guard let store else { return nil }
        let path = url.standardizedFileURL.path
        let id = Int64(UserDefaults.standard.integer(forKey: key))
        if id != 0, let existing = store.folders().first(where: { $0.id == id }) {
            if existing.path != path { store.moveFolder(id: id, to: path) }
            return store.folders().first { $0.id == id }
        }
        guard let added = try? store.addFolder(path: path, bookmark: Data()), let newID = added.id else { return nil }
        UserDefaults.standard.set(Int(newID), forKey: key)
        return added
    }

    /// Looks for the app's iCloud Drive folder. This can take a moment and must not run on the main thread.
    private func findCloudFolder() {
        Task {
            let root = await Task.detached(priority: .utility) { () -> URL? in
                guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
                let documents = container.appendingPathComponent("Documents", isDirectory: true)
                try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
                return documents.standardizedFileURL
            }.value
            guard let root else { return }
            cloudRoot = root
            cloudFolder = folder(saved: "cloudFolderID", at: root)
            cloudAvailable = cloudFolder != nil
            rescan()
        }
    }

    func isInCloud(_ book: LibraryBook) -> Bool { cloudFolder != nil && book.folderID == cloudFolder?.id }

    // MARK: Reading the folders

    func reload() {
        books = store?.books() ?? []
    }

    /// Brings the library in line with what is in the app's folders.
    func rescan() {
        guard let store else { return }
        if isScanning { scanAgain = true; return }
        isScanning = true
        var roots: [(LibraryFolder, URL)] = []
        if let localFolder { roots.append((localFolder, localRoot)) }
        if let cloudFolder, let cloudRoot { roots.append((cloudFolder, cloudRoot)) }
        Task {
            await Task.detached(priority: .utility) {
                for (folder, url) in roots { _ = store.scan(folder, at: url) }
            }.value
            reload()
            isScanning = false
            scheduleCloudSync(after: 0.3)
            if scanAgain { scanAgain = false; rescan() }
        }
    }

    /// Shares covers and reading positions of the comics in iCloud with the reader's other devices and
    /// picks up theirs, so a comic that was never downloaded here still shows its cover and how far
    /// it has been read. Runs a little after the last change, off the main thread.
    func scheduleCloudSync(after seconds: Double = 2, retries: Int = 8) {
        guard let store, let cloudRoot, let folderID = cloudFolder?.id else { return }
        cloudSync?.cancel()
        cloudSync = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            let sync = CloudSync(container: cloudRoot.deletingLastPathComponent())
            let result = await Task.detached(priority: .utility) { sync.sync(store: store, folderID: folderID, root: cloudRoot) }.value
            if result.changed > 0 {
                covers.removeAllObjects()
                coverGeneration += 1
                reload()
            }
            // Covers and positions from other devices that were still coming down: look again shortly.
            if result.pending, retries > 0, !Task.isCancelled { scheduleCloudSync(after: 3, retries: retries - 1) }
        }
    }

    // MARK: Adding comics

    /// Copies comics chosen in the file picker (or sent from another app) into the app's folder.
    /// Returns where the first one ended up.
    @discardableResult
    func importFiles(_ urls: [URL]) async -> URL? {
        let root = localRoot
        let result = await Task.detached(priority: .userInitiated) { () -> (first: URL?, failures: [String]) in
            var first: URL?
            var failures: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                // Already in one of the app's folders: nothing to copy.
                if url.standardizedFileURL.path.hasPrefix(root.path + "/") { first = first ?? url.standardizedFileURL; continue }
                var destination = root.appendingPathComponent(url.lastPathComponent)
                var copy = 2
                while FileManager.default.fileExists(atPath: destination.path) {
                    let name = url.deletingPathExtension().lastPathComponent + " \(copy)"
                    destination = root.appendingPathComponent(name).appendingPathExtension(url.pathExtension)
                    copy += 1
                }
                var failure: String?
                var coordinationError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                    do { try FileManager.default.copyItem(at: readable, to: destination) } catch { failure = error.localizedDescription }
                }
                if let problem = failure ?? coordinationError?.localizedDescription {
                    failures.append("\(url.lastPathComponent): \(problem)")
                } else {
                    first = first ?? destination.standardizedFileURL
                }
            }
            return (first, failures)
        }.value
        if !result.failures.isEmpty { message = "Couldn’t add:\n" + result.failures.joined(separator: "\n") }
        // Record the first one right away so it can be opened without waiting for the scan.
        if let first = result.first, let store, let folderID = localFolder?.id, first.path.hasPrefix(root.path + "/") {
            _ = await Task.detached { try? store.record(ComicBook(url: first), folderID: folderID) }.value
        }
        reload()
        rescan()
        return result.first
    }

    func book(at url: URL) -> LibraryBook? { store?.book(path: url.standardizedFileURL.path) }

    // MARK: Changing comics

    func update(_ id: Int64, _ change: @escaping (inout LibraryBook) -> Void) {
        store?.update(id: id, change)
        if let index = books.firstIndex(where: { $0.id == id }), let fresh = store?.book(id: id) { books[index] = fresh }
        scheduleCloudSync()
    }

    func setFinished(_ finished: Bool, for book: LibraryBook) {
        guard let id = book.id else { return }
        update(id) {
            $0.finished = finished
            if finished { $0.lastReadAt = $0.lastReadAt ?? Date() } else { $0.page = 0; $0.lastReadAt = nil }
        }
    }

    /// Deletes a comic's file and forgets it. In iCloud this deletes it everywhere.
    func delete(_ book: LibraryBook) {
        guard let id = book.id else { return }
        let url = URL(fileURLWithPath: book.path)
        do {
            if FileManager.default.fileExists(atPath: url.path) || !book.downloaded { try FileManager.default.removeItem(at: url) }
        } catch where FileManager.default.fileExists(atPath: url.path) {
            message = "Couldn’t delete “\(book.title)”: \(error.localizedDescription)"
            return
        } catch {}
        if let cloudRoot, isInCloud(book), book.path.hasPrefix(cloudRoot.path + "/") {
            CloudSync(container: cloudRoot.deletingLastPathComponent()).forget(relativePath: String(book.path.dropFirst(cloudRoot.path.count + 1)))
        }
        store?.remove(ids: [id])
        covers.removeObject(forKey: id as NSNumber)
        reload()
    }

    // MARK: iCloud

    /// Fetches a comic that is in iCloud but not on this device. Returns whether it is here now.
    func download(_ book: LibraryBook) async -> Bool {
        guard let id = book.id, let store else { return false }
        let url = URL(fileURLWithPath: book.path)
        if !LibraryStore.isDownloaded(url) {
            do {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
            } catch {
                message = "Couldn’t download “\(book.title)”: \(error.localizedDescription)"
                return false
            }
            downloading.insert(id)
            while downloading.contains(id), !LibraryStore.isDownloaded(url) {
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard downloading.remove(id) != nil else { return false }      // cancelled
        }
        let folderID = book.folderID
        _ = await Task.detached { try? store.record(ComicBook(url: url), folderID: folderID) }.value
        covers.removeObject(forKey: id as NSNumber)
        reload()
        return true
    }

    func cancelDownload(_ book: LibraryBook) {
        if let id = book.id { downloading.remove(id) }
    }

    /// Frees the space a downloaded iCloud comic takes on this device; it stays in iCloud.
    func removeDownload(_ book: LibraryBook) {
        guard let id = book.id else { return }
        do {
            try FileManager.default.evictUbiquitousItem(at: URL(fileURLWithPath: book.path))
            update(id) { $0.downloaded = false }
        } catch {
            message = "Couldn’t remove the download of “\(book.title)”: \(error.localizedDescription)"
        }
    }

    /// Moves a comic between the app's folder on this device and its iCloud Drive folder.
    func move(_ book: LibraryBook, toCloud: Bool) {
        guard let id = book.id, let store, let cloudRoot, let cloudFolder, let localFolder else { return }
        let source = URL(fileURLWithPath: book.path)
        let series = LibraryBook.fileNameSafe(book.series)
        var folder = toCloud ? cloudRoot : localRoot
        if toCloud, !series.isEmpty { folder = folder.appendingPathComponent(series, isDirectory: true) }
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        let target = toCloud ? cloudFolder.id : localFolder.id
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: destination.path) { return "a file with that name is already there" }
                    try FileManager.default.setUbiquitous(toCloud, itemAt: source, destinationURL: destination)
                    try store.relocate(id: id, to: destination, intoFolder: target)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure { message = "Couldn’t move “\(book.title)”: \(failure)" }
            reload()
        }
    }

    // MARK: Covers

    func cover(for id: Int64) async -> UIImage? {
        if let cached = covers.object(forKey: id as NSNumber) { return cached }
        guard let url = store?.coverURL(for: id) else { return nil }
        let image = await Task.detached(priority: .utility) { UIImage(contentsOfFile: url.path) }.value
        if let image { covers.setObject(image, forKey: id as NSNumber) }
        return image
    }
}
