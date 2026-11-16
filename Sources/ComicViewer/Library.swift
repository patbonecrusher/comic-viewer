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
    /// Comics taken out by hand that are still in a library folder (see `restoreRemoved`).
    private(set) var hiddenCount = 0
    @ObservationIgnored private var cloudSync: Task<Void, Never>?
    /// Goes up when covers arrive from another device, so cells showing a blank cover look again.
    private(set) var coverGeneration = 0
    /// The latest series rename (old name, new name), so a window showing the old series can follow it.
    private(set) var seriesRename: [String] = []
    /// Comics being fetched from iCloud right now.
    private(set) var downloading: Set<Int64> = []
    /// The app's own folder in iCloud Drive, when iCloud is available to this copy of the app.
    private(set) var cloudFolder: URL?

    @ObservationIgnored nonisolated let store: LibraryStore?
    @ObservationIgnored private var folderURLs: [Int64: URL] = [:]
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var rescanRequested = false

    private init() {
        // Screenshot hook: `-libraryName Demo` on the command line uses a separate, empty library.
        let name = UserDefaults.standard.string(forKey: "libraryName") ?? "Comic Viewer"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(name, isDirectory: true)
        do {
            store = try LibraryStore(directory: support)
        } catch {
            store = nil
            storeError = error.localizedDescription
        }
        reload()
        rescan()
        findCloudFolder()
    }

    func reload() {
        guard let store else { return }
        books = store.books()
        folders = store.folders()
        hiddenCount = store.hiddenCount()
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
        // The app's iCloud folder needs no bookmark: the app always has access to its own container.
        if let cloudFolder, folder.path == cloudFolder.path {
            folderURLs[id] = cloudFolder
            return cloudFolder
        }
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
            scheduleCloudSync(after: 0.5)
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
        if let existing = store.book(path: comic.url.path) {
            // Opening a comic by hand brings it back if it had been taken out of the library, and one
            // listed before it was downloaded gets its real details now.
            if existing.pageCount == 0 || !existing.downloaded { return (try? store.record(comic)) ?? existing }
            if existing.hidden, let id = existing.id { store.update(id: id) { $0.hidden = false } }
            return existing
        }
        let bookmark = try? comic.url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        return try? store.record(comic, bookmark: bookmark)
    }

    func update(_ id: Int64, _ change: (inout LibraryBook) -> Void) {
        guard let store else { return }
        store.update(id: id, change)
        scheduleCloudSync()
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

    // MARK: Renaming files

    /// The comics selected in the library window, for menu commands.
    var selectedBookIDs: Set<Int64> = []
    var selectedBooks: [LibraryBook] { books.filter { $0.id.map(selectedBookIDs.contains) ?? false } }
    /// The selected comic when exactly one is selected.
    var selectedBook: LibraryBook? { selectedBooks.count == 1 ? selectedBooks.first : nil }

    enum RenameError: LocalizedError {
        case emptyName, missing, open, taken(String), failed(String)
        var errorDescription: String? {
            switch self {
            case .emptyName: return "The name can’t be empty."
            case .missing: return "The file could not be found. It may have been moved or deleted."
            case .open: return "This comic is open. Close its window, then rename it."
            case .taken(let name): return "There is already a file named “\(name)” in that folder."
            case .failed(let reason): return reason
            }
        }
    }

    /// Renames a comic's file on disk (same folder, same extension) and keeps its library record,
    /// reading position and panel edits attached to it.
    func rename(_ book: LibraryBook, to newName: String) throws {
        guard let store, let id = book.id else { return }
        guard let source = url(for: book), FileManager.default.fileExists(atPath: source.path) else { throw RenameError.missing }
        guard !ReaderWindows.shared.isOpen(source) else { throw RenameError.open }
        let ext = source.pathExtension
        var base = newName
        if !ext.isEmpty, base.lowercased().hasSuffix("." + ext.lowercased()) { base = String(base.dropLast(ext.count + 1)) }
        base = LibraryBook.fileNameSafe(base)
        guard !base.isEmpty else { throw RenameError.emptyName }
        let fileName = ext.isEmpty ? base : base + "." + ext
        guard fileName != source.lastPathComponent else { return }
        let destination = source.deletingLastPathComponent().appendingPathComponent(fileName)
        // On a case-insensitive disk the file "exists" under its own new spelling; that is not a clash.
        let caseOnly = fileName.lowercased() == source.lastPathComponent.lowercased()
        if !caseOnly, FileManager.default.fileExists(atPath: destination.path) { throw RenameError.taken(fileName) }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            let hint = book.folderID == nil ? " Comics opened on their own can only be renamed once their folder is added to the library." : ""
            throw RenameError.failed(error.localizedDescription + hint)
        }
        // A comic opened on its own is reached through a bookmark, which has to follow the file.
        let bookmark = book.folderID == nil
            ? try? destination.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        do {
            let fresh = try store.relocate(id: id, to: destination, bookmark: bookmark)
            if let index = books.firstIndex(where: { $0.id == id }) { books[index] = fresh }
            CoverCache.shared.forget(id)
        } catch {
            reload()
            throw RenameError.failed("The file was renamed, but its library entry could not be updated: \(error.localizedDescription)")
        }
    }

    /// Asks for the new name, offering one built from the comic's title, and renames the file.
    func promptRename(_ book: LibraryBook) {
        let current = URL(fileURLWithPath: book.path)
        let alert = NSAlert()
        alert.messageText = "Rename File"
        alert.informativeText = "Now named “\(current.lastPathComponent)”. The name below comes from the comic’s title; change it if you like. The file stays in its folder."
        let field = NSTextField(string: book.suggestedFileName)
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        field.lineBreakMode = .byTruncatingMiddle
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try rename(book, to: field.stringValue)
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "Couldn’t rename “\(current.lastPathComponent)”"
            failure.informativeText = error.localizedDescription
            failure.runModal()
        }
    }

    // MARK: Renaming a series

    /// Asks for a series' new name and applies it. Returns the new name, or nil if nothing changed.
    @discardableResult
    func promptRenameSeries(_ name: String) -> String? {
        guard let store, !name.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = "Rename Series"
        alert.informativeText = "Comics of “\(name)” are listed under the new name, including ones added later. Typing the name of another series merges the two. Files are not changed."
        let field = NSTextField(string: name)
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let new = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != name else { return nil }
        store.renameSeries(name, to: new)
        reload()
        seriesRename = [name, new]
        return new
    }

    /// Asks which series the comics belong in (an existing one or a new name) and moves them there.
    func promptMoveToSeries(_ moved: [LibraryBook]) {
        guard let store, let first = moved.first else { return }
        let alert = NSAlert()
        alert.messageText = moved.count == 1 ? "Move “\(first.title)” to a Series" : "Move \(moved.count) Comics to a Series"
        alert.informativeText = "Choose a series or type a new name. Leave it empty to take the comics out of any series. Files are not changed."
        let names = Set(books.map(\.series)).filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        field.addItems(withObjectValues: names)
        field.completes = true
        field.numberOfVisibleItems = 12
        let current = Set(moved.map(\.series))
        field.stringValue = current.count == 1 ? first.series : ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.setSeries(field.stringValue, ids: moved.compactMap(\.id))
        reload()
    }

    /// Puts comics in a series without asking (used when they are dropped on one).
    func moveToSeries(_ name: String, ids: [Int64]) {
        guard let store, !ids.isEmpty else { return }
        store.setSeries(name, ids: ids)
        reload()
    }

    /// Lets the reader correct a comic's title, series, volume, issue number and year.
    func promptEditDetails(_ book: LibraryBook) {
        guard let store, let id = book.id else { return }
        let alert = NSAlert()
        alert.messageText = "Edit Details"
        alert.informativeText = "These are kept in Comic Viewer’s library. The file is not changed."
        func field(_ value: String, width: CGFloat = 280) -> NSTextField {
            let field = NSTextField(string: value)
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
            return field
        }
        func text(_ number: Double?) -> String {
            guard let number else { return "" }
            return number == number.rounded() ? String(Int(number)) : String(number)
        }
        let title = field(book.title), series = field(book.series)
        let volume = field(book.volume.map(String.init) ?? "", width: 70)
        let number = field(text(book.number), width: 70)
        let year = field(book.year.map(String.init) ?? "", width: 70)
        let rows: [(String, NSTextField)] = [("Title:", title), ("Series:", series), ("Volume:", volume), ("Issue number:", number), ("Year:", year)]
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        alert.accessoryView = grid
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = title
        for (index, row) in rows.enumerated() { row.1.nextKeyView = rows[(index + 1) % rows.count].1 }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        func trimmed(_ field: NSTextField) -> String { field.stringValue.trimmingCharacters(in: .whitespaces) }
        store.setDetails(id: id, title: trimmed(title), series: trimmed(series), volume: Int(trimmed(volume)),
                         number: Double(trimmed(number).replacingOccurrences(of: ",", with: ".")), year: Int(trimmed(year)))
        reload()
    }

    // MARK: Taking comics out of the library

    /// Takes comics out of the library. Files stay where they are. A comic in a library folder is
    /// hidden (so scans don't add it back) and can be restored; one opened on its own is forgotten.
    func remove(_ removed: [LibraryBook], confirm: Bool = true) {
        guard let store, !removed.isEmpty else { return }
        if confirm, removed.count > 1 {
            let alert = NSAlert()
            alert.messageText = "Remove \(removed.count) comics from the library?"
            alert.informativeText = "The files stay where they are. Comics in library folders can be brought back with File > Restore Removed Comics."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let ids = removed.compactMap(\.id)
        store.takeOut(ids: ids)
        for book in removed where book.folderID == nil { if let id = book.id { CoverCache.shared.forget(id) } }
        selectedBookIDs.subtract(ids)
        reload()
    }

    func remove(_ book: LibraryBook) { remove([book]) }

    /// Brings back everything that was taken out by hand and is still in a library folder.
    func restoreRemoved() {
        guard let store else { return }
        store.restoreHidden()
        reload()
    }

    /// Comics whose files can no longer be found. A comic on a drive or folder that is not reachable
    /// right now does not count: unplugging a drive must not empty the library.
    func missingBooks() -> [LibraryBook] {
        let fileManager = FileManager.default
        var reachable: [Int64: Bool] = [:]
        return books.filter { book in
            if let folderID = book.folderID {
                if reachable[folderID] == nil {
                    var isDirectory: ObjCBool = false
                    let url = folders.first { $0.id == folderID }.flatMap { resolvedURL(for: $0) }
                    reachable[folderID] = url.map { fileManager.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue } ?? false
                }
                return reachable[folderID] == true && !fileManager.fileExists(atPath: book.path)
            }
            guard let bookmark = book.bookmark else { return !fileManager.fileExists(atPath: book.path) }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { return true }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            return !fileManager.fileExists(atPath: url.path)
        }
    }

    /// Finds comics whose files are gone and, after asking, removes them from the library.
    func removeMissing() {
        guard let store else { return }
        let missing = missingBooks()
        let alert = NSAlert()
        guard !missing.isEmpty else {
            alert.messageText = "No Missing Comics"
            alert.informativeText = "Every comic in the library still has its file."
            alert.runModal()
            return
        }
        alert.messageText = missing.count == 1 ? "Remove 1 comic whose file is missing?" : "Remove \(missing.count) comics whose files are missing?"
        let names = missing.prefix(8).map { "• " + $0.title }.joined(separator: "\n")
        alert.informativeText = names + (missing.count > 8 ? "\n…and \(missing.count - 8) more" : "")
            + "\n\nTheir reading positions and panel edits are removed too."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let ids = missing.compactMap(\.id)
        store.remove(ids: ids)
        ids.forEach(CoverCache.shared.forget)
        selectedBookIDs.subtract(ids)
        reload()
    }

    // MARK: iCloud

    /// The folder's name in the sidebar.
    func displayName(for folder: LibraryFolder) -> String { isCloudFolder(folder) ? "iCloud Drive" : folder.name }
    func isCloudFolder(_ folder: LibraryFolder) -> Bool { cloudFolder.map { $0.path == folder.path } ?? false }
    func isInCloudFolder(_ book: LibraryBook) -> Bool { cloudFolder.map { book.path.hasPrefix($0.path + "/") } ?? false }

    /// Looks for the app's iCloud Drive folder (slow the first time, so off the main thread). If it
    /// already holds something, say comics added on another device, it joins the library.
    private func findCloudFolder() {
        Task {
            let documents = await Task.detached(priority: .utility) { () -> URL? in
                FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents", isDirectory: true).standardizedFileURL
            }.value
            guard let documents else { return }
            cloudFolder = documents
            if FileManager.default.fileExists(atPath: documents.path) || folders.contains(where: { $0.path == documents.path }) {
                _ = cloudFolderID()
                reload()
                rescan()
            }
        }
    }

    /// Shares covers and reading positions of the comics in the iCloud folder with the reader's other
    /// devices, and picks up theirs. Runs a little after the last change, off the main thread.
    func scheduleCloudSync(after seconds: Double = 2, retries: Int = 5) {
        guard let store, let cloudFolder, let folderID = folders.first(where: { $0.path == cloudFolder.path })?.id else { return }
        cloudSync?.cancel()
        cloudSync = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            let sync = CloudSync(container: cloudFolder.deletingLastPathComponent())
            let result = await Task.detached(priority: .utility) { sync.sync(store: store, folderID: folderID, root: cloudFolder) }.value
            if result.changed > 0 { coverGeneration += 1; reload() }
            // Files from other devices that were still coming down: look again shortly.
            if result.pending, retries > 0, !Task.isCancelled { scheduleCloudSync(after: 4, retries: retries - 1) }
        }
    }

    /// The library's record for the iCloud folder, creating the folder itself the first time.
    private func cloudFolderID() -> Int64? {
        guard let store, let cloudFolder else { return nil }
        try? FileManager.default.createDirectory(at: cloudFolder, withIntermediateDirectories: true)
        guard let id = (try? store.addFolder(path: cloudFolder.path, bookmark: Data()))?.id else { return nil }
        folderURLs[id] = cloudFolder
        return id
    }

    /// Copies comics into the app's iCloud Drive folder (a subfolder per series). The original file
    /// stays where it is, untouched. The library follows the copy, with its reading position and
    /// panel edits, because that is the one the reader's other devices see; an original in a
    /// library folder is set aside (File › Restore Removed Comics) so the comic isn't listed twice.
    func copyToCloud(_ moved: [LibraryBook]) {
        guard let store, let cloudFolder, let folderID = cloudFolderID() else { return }
        var skipped: [String] = []
        var jobs: [(id: Int64, title: String, source: URL, directory: URL, folderID: Int64?)] = []
        for book in moved where !isInCloudFolder(book) {
            guard let id = book.id, let source = url(for: book), FileManager.default.fileExists(atPath: source.path) else {
                skipped.append("\(book.title): the file could not be found")
                continue
            }
            guard !ReaderWindows.shared.isOpen(source) else {
                skipped.append("\(book.title): it is open; close its window first")
                continue
            }
            let series = LibraryBook.fileNameSafe(book.series)
            jobs.append((id, book.title, source, series.isEmpty ? cloudFolder : cloudFolder.appendingPathComponent(series, isDirectory: true), book.folderID))
        }
        guard !jobs.isEmpty || !skipped.isEmpty else { return }
        Task {
            for (index, job) in jobs.enumerated() {
                scanStatus = "Copying to iCloud… \(index + 1) of \(jobs.count)"
                let outcome = await Task.detached(priority: .userInitiated) { () -> Error? in
                    do {
                        let fileManager = FileManager.default
                        try fileManager.createDirectory(at: job.directory, withIntermediateDirectories: true)
                        var destination = job.directory.appendingPathComponent(job.source.lastPathComponent)
                        var attempt = 2
                        while fileManager.fileExists(atPath: destination.path) {
                            let base = job.source.deletingPathExtension().lastPathComponent, ext = job.source.pathExtension
                            destination = job.directory.appendingPathComponent(ext.isEmpty ? "\(base) \(attempt)" : "\(base) \(attempt).\(ext)")
                            attempt += 1
                        }
                        try fileManager.copyItem(at: job.source, to: destination)
                        try store.relocate(id: job.id, to: destination, intoFolder: folderID)
                        // The original is still in its library folder, where the next scan would list it again.
                        if let folder = job.folderID, let original = try? store.record(ComicBook(url: job.source), folderID: folder), let id = original.id {
                            store.takeOut(ids: [id])
                        }
                        return nil
                    } catch {
                        return error
                    }
                }.value
                if let outcome { skipped.append("\(job.title): \(outcome.localizedDescription)") }
                CoverCache.shared.forget(job.id)
            }
            scanStatus = nil
            reload()
            scheduleCloudSync(after: 0.5)      // share the covers of what just arrived in iCloud
            guard !skipped.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = "Some comics were not copied to iCloud"
            alert.informativeText = skipped.map { "• " + $0 }.joined(separator: "\n")
            alert.runModal()
        }
    }

    /// Fetches a comic that is in iCloud but not on this Mac. True once it can be opened.
    @discardableResult
    func download(_ book: LibraryBook) async -> Bool {
        guard let store, let id = book.id, let url = url(for: book) else { return false }
        if !LibraryStore.isDownloaded(url) {
            guard !downloading.contains(id) else { return false }
            do {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn’t download “\(book.title)”"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return false
            }
            downloading.insert(id)
            while downloading.contains(id), !LibraryStore.isDownloaded(url) {
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard downloading.remove(id) != nil else { return false }     // cancelled
        }
        // Now that it can be read: page count, details from inside the file, cover.
        let folderID = book.folderID
        _ = await Task.detached(priority: .userInitiated) { try? store.record(ComicBook(url: url), folderID: folderID) }.value
        CoverCache.shared.forget(id)
        reload()
        return true
    }

    func cancelDownload(_ book: LibraryBook) { if let id = book.id { downloading.remove(id) } }

    /// Frees the space a comic takes on this Mac; it stays in iCloud and in the library.
    func removeDownload(_ book: LibraryBook) {
        guard let id = book.id, let url = url(for: book) else { return }
        do {
            guard !ReaderWindows.shared.isOpen(url) else { throw RenameError.open }
            try FileManager.default.evictUbiquitousItem(at: url)
            update(id) { $0.downloaded = false }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t remove the download of “\(book.title)”"
            alert.informativeText = error is RenameError ? "This comic is open. Close its window first." : error.localizedDescription
            alert.runModal()
        }
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
