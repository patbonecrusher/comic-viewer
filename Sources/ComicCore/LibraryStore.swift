import CoreGraphics
import Foundation
import GRDB
import ImageIO

/// A comic the app knows about: one found in a library folder, or one opened directly.
public struct LibraryBook: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "book"

    public var id: Int64?
    public var path: String
    /// The library folder it was found in; nil for a comic opened on its own.
    public var folderID: Int64?
    /// Sandbox bookmark for a comic opened on its own (library comics are covered by their folder's).
    public var bookmark: Data?
    public var title: String
    public var series: String
    public var number: Double?
    public var volume: Int?
    public var year: Int?
    public var writer: String?
    public var publisher: String?
    public var summary: String?
    public var pageCount: Int
    public var fileSize: Int64
    public var modifiedAt: Date
    public var addedAt: Date
    public var lastReadAt: Date?
    public var page: Int
    public var finished: Bool
    public var layout: String?
    public var direction: String?
    public var panelMode: Bool?
    /// Removed from the library by hand while its file is still in a library folder: kept out of
    /// sight so a rescan doesn't bring it back, with its reading position and panel edits intact.
    public var hidden: Bool = false
    /// False while the file is in iCloud and not on this Mac; such a comic can't be read until it is fetched.
    public var downloaded: Bool = true
    /// The series this comic was put in by hand ("" for none); nil leaves it to what the file says.
    public var seriesOverride: String?
    /// Title, series, number, volume and year are kept as they are instead of being read from the
    /// file again. Set when the app renames a file whose details came from its old name: the series
    /// and numbering stay, and the title follows the new name.
    public var pinned: Bool = false

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var isStarted: Bool { lastReadAt != nil && !finished }
    public var isUnread: Bool { lastReadAt == nil && !finished }
    public var progress: Double { finished ? 1 : (pageCount > 1 ? Double(page) / Double(pageCount - 1) : 0) }

    /// "Vol. 2 · #5" — whichever parts are known.
    public var issueLabel: String? {
        var parts: [String] = []
        if let volume { parts.append("Vol. \(volume)") }
        if let number { parts.append("#" + (number == number.rounded() ? String(Int(number)) : String(number))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Whether the file is kept in iCloud Drive (downloaded or not).
    public var isInCloud: Bool { path.contains("/Library/Mobile Documents/") }

    /// A tidy file name (no extension) built from what is known about the comic:
    /// "Saga 002 - Chapter Two (2012)" for an issue of a series ("Akira v03 - Title" for a volume),
    /// otherwise the title and year.
    public var suggestedFileName: String {
        var name = title
        if !series.isEmpty, number != nil || volume != nil {
            name = series
            if let volume { name += String(format: " v%02d", volume) }
            if let number {
                name += " " + (number == number.rounded() ? String(format: "%03d", Int(number)) : String(format: "%05.1f", number))
            }
            // A title that is only the series and number again adds nothing.
            let generated = [series, issueLabel].compactMap { $0 }.joined(separator: " ")
            if title != generated, title != series, !title.isEmpty { name += " - " + title }
        }
        if let year, !name.contains("(\(year))") { name += " (\(year))" }
        return Self.fileNameSafe(name)
    }

    /// Removes what a file name can't hold ("/" and ":"), control characters and stray spaces or dots.
    public static func fileNameSafe(_ name: String) -> String {
        var safe = name.replacingOccurrences(of: ": ", with: " - ")
        safe = String(safe.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" { return "-" }
            return CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        })
        safe = safe.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        safe = safe.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String(safe.prefix(200))
    }
}

public struct LibraryFolder: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "folder"

    public var id: Int64?
    public var path: String
    public var bookmark: Data
    public var addedAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    public var name: String { (path as NSString).lastPathComponent }
}

/// The collection database (SQLite) and its cover image cache.
public final class LibraryStore: @unchecked Sendable {
    public static let comicExtensions: Set<String> = ["cbz", "cbr", "pdf"]

    private let database: DatabaseQueue
    private let coversDirectory: URL

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        coversDirectory = directory.appendingPathComponent("Covers", isDirectory: true)
        try FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        database = try DatabaseQueue(path: directory.appendingPathComponent("library.sqlite").path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "folder") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("bookmark", .blob).notNull()
                t.column("addedAt", .datetime).notNull()
            }
            try db.create(table: "book") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("folderID", .integer).references("folder", onDelete: .cascade).indexed()
                t.column("bookmark", .blob)
                t.column("title", .text).notNull()
                t.column("series", .text).notNull().indexed()
                t.column("number", .double)
                t.column("volume", .integer)
                t.column("year", .integer)
                t.column("writer", .text)
                t.column("publisher", .text)
                t.column("summary", .text)
                t.column("pageCount", .integer).notNull()
                t.column("fileSize", .integer).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("addedAt", .datetime).notNull()
                t.column("lastReadAt", .datetime)
                t.column("page", .integer).notNull().defaults(to: 0)
                t.column("finished", .boolean).notNull().defaults(to: false)
                t.column("layout", .text)
                t.column("direction", .text)
                t.column("panelMode", .boolean)
            }
        }
        migrator.registerMigration("v2-panels") { db in
            // Panels the reader drew by hand for a page, replacing automatic detection.
            try db.create(table: "panelOverride") { t in
                t.column("bookID", .integer).notNull().references("book", onDelete: .cascade)
                t.column("page", .integer).notNull()
                t.column("rects", .text).notNull()       // JSON [[x, y, width, height], …] in page unit coordinates
                t.primaryKey(["bookID", "page"])
            }
        }
        migrator.registerMigration("v3-hidden-cloud") { db in
            try db.alter(table: "book") { t in
                t.add(column: "hidden", .boolean).notNull().defaults(to: false)
                t.add(column: "downloaded", .boolean).notNull().defaults(to: true)
            }
        }
        migrator.registerMigration("v4-series-names") { db in
            // Series renamed by hand: the name found in the file, and the name to show instead.
            try db.create(table: "seriesName") { t in
                t.primaryKey("detected", .text)
                t.column("name", .text).notNull()
            }
        }
        migrator.registerMigration("v5-series-override") { db in
            try db.alter(table: "book") { t in t.add(column: "seriesOverride", .text) }
        }
        migrator.registerMigration("v6-pinned") { db in
            try db.alter(table: "book") { t in t.add(column: "pinned", .boolean).notNull().defaults(to: false) }
        }
        try migrator.migrate(database)
    }

    // MARK: Reading

    /// The comics in the library. Ones removed by hand that would otherwise come back are left out
    /// unless asked for.
    public func books(includingHidden: Bool = false) -> [LibraryBook] {
        (try? database.read { db in
            try includingHidden ? LibraryBook.fetchAll(db) : LibraryBook.filter(Column("hidden") == false).fetchAll(db)
        }) ?? []
    }
    public func hiddenCount() -> Int { (try? database.read { try LibraryBook.filter(Column("hidden") == true).fetchCount($0) }) ?? 0 }
    public func folders() -> [LibraryFolder] { (try? database.read { try LibraryFolder.order(Column("path")).fetchAll($0) }) ?? [] }
    public func book(path: String) -> LibraryBook? { try? database.read { try LibraryBook.filter(Column("path") == path).fetchOne($0) } }
    public func book(id: Int64) -> LibraryBook? { try? database.read { try LibraryBook.fetchOne($0, key: id) } }

    public func coverURL(for id: Int64) -> URL { coversDirectory.appendingPathComponent("\(id).jpg") }

    // MARK: Folders

    @discardableResult
    public func addFolder(path: String, bookmark: Data) throws -> LibraryFolder {
        try database.write { db in
            if var existing = try LibraryFolder.filter(Column("path") == path).fetchOne(db) {
                existing.bookmark = bookmark
                try existing.update(db)
                return existing
            }
            var folder = LibraryFolder(id: nil, path: path, bookmark: bookmark, addedAt: Date())
            try folder.insert(db)
            return folder
        }
    }

    /// Forgets a folder and the comics found in it. Files on disk are not touched.
    public func removeFolder(id: Int64) throws {
        let ids = try database.write { db -> [Int64] in
            let ids = try Int64.fetchAll(db, sql: "SELECT id FROM book WHERE folderID = ?", arguments: [id])
            try LibraryFolder.deleteOne(db, key: id)
            return ids
        }
        ids.forEach(removeCover)
    }

    // MARK: Books

    public func update(id: Int64, _ change: (inout LibraryBook) -> Void) {
        try? database.write { db in
            guard var book = try LibraryBook.fetchOne(db, key: id) else { return }
            change(&book)
            try book.update(db)
        }
    }

    /// Points a comic's record at the file's new place after it was renamed or moved, and reads its
    /// details again. Reading position, settings and panel edits are kept.
    @discardableResult
    public func relocate(id: Int64, to url: URL, bookmark: Data? = nil, intoFolder newFolder: Int64? = nil) throws -> LibraryBook {
        let path = url.standardizedFileURL.path
        var folderID: Int64?
        var before: LibraryBook?
        try database.write { db in
            guard var book = try LibraryBook.fetchOne(db, key: id) else { throw ComicError.unreadableFile("it is no longer in the library") }
            before = book
            // A leftover record for the new path would collide with this one.
            let stale = try LibraryBook.filter(Column("path") == path && Column("id") != id).fetchAll(db).compactMap(\.id)
            try LibraryBook.deleteAll(db, keys: stale)
            book.path = path
            if let bookmark { book.bookmark = bookmark }
            if let newFolder { book.folderID = newFolder; book.bookmark = nil }
            folderID = book.folderID
            try book.update(db)
        }
        var book = try record(ComicBook(url: URL(fileURLWithPath: path)), folderID: folderID, bookmark: bookmark)
        // The comic is the same one under a new name. If its details were being guessed from the old
        // name, the new name would guess differently (another series, a lost volume): keep what it had.
        if let before, !before.title.isEmpty,
           before.pinned || [book.title, book.series] != [before.title, before.series] || book.number != before.number
            || book.volume != before.volume || book.year != before.year {
            // The title follows a name the reader typed; a name the app suggested says nothing new.
            var title = before.title
            let name = url.deletingPathExtension().lastPathComponent
            if name != URL(fileURLWithPath: before.path).deletingPathExtension().lastPathComponent, name != before.suggestedFileName {
                title = ComicMetadata.fromFileName(url).title ?? name
            }
            update(id: id) {
                $0.title = title; $0.series = before.series; $0.number = before.number
                $0.volume = before.volume; $0.year = before.year; $0.pinned = true
            }
            book = self.book(id: id) ?? book
        }
        return book
    }

    /// Forgets comics. Files on disk are not touched.
    public func remove(ids: [Int64]) {
        _ = try? database.write { try LibraryBook.deleteAll($0, keys: ids) }
        ids.forEach(removeCover)
    }

    /// Takes comics out of the library for good. One that lives in a library folder is hidden rather
    /// than forgotten, so the next scan doesn't add it again; the rest are forgotten. Files are not touched.
    public func takeOut(ids: [Int64]) {
        var forgotten: [Int64] = []
        try? database.write { db in
            for id in ids {
                guard var book = try LibraryBook.fetchOne(db, key: id) else { continue }
                if book.folderID != nil {
                    book.hidden = true
                    try book.update(db)
                } else {
                    try book.delete(db)
                    forgotten.append(id)
                }
            }
        }
        forgotten.forEach(removeCover)
    }

    /// Brings back every comic that was taken out by hand. Returns how many.
    @discardableResult
    public func restoreHidden() -> Int {
        (try? database.write { db -> Int in
            try db.execute(sql: "UPDATE book SET hidden = 0 WHERE hidden = 1")
            return db.changesCount
        }) ?? 0
    }

    // MARK: Series names

    /// The name a series goes by: the one given by hand if it was renamed, otherwise the one found in the file.
    private func seriesName(for detected: String?, _ db: Database) throws -> String? {
        guard let detected, !detected.isEmpty else { return detected }
        return try String.fetchOne(db, sql: "SELECT name FROM seriesName WHERE detected = ?", arguments: [detected]) ?? detected
    }

    /// Renames a series for every comic in it, and for comics of that series found later. Giving the
    /// name of another series merges the two. Files are not touched. Returns how many comics changed.
    @discardableResult
    public func renameSeries(_ old: String, to new: String) -> Int {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty, !new.isEmpty, old != new else { return 0 }
        return (try? database.write { db -> Int in
            // `old` may itself be a name given earlier; point what led to it at the new name too.
            try db.execute(sql: "UPDATE seriesName SET name = ? WHERE name = ?", arguments: [new, old])
            try db.execute(sql: "INSERT OR REPLACE INTO seriesName (detected, name) VALUES (?, ?)", arguments: [old, new])
            try db.execute(sql: "DELETE FROM seriesName WHERE detected = name")
            let books = try LibraryBook.filter(Column("series") == old).fetchAll(db)
            for var book in books {
                // A title made up from the series and number ("Saga #12") follows the series.
                if book.issueLabel != nil, book.title == [old, book.issueLabel].compactMap({ $0 }).joined(separator: " ") {
                    book.title = [new, book.issueLabel].compactMap { $0 }.joined(separator: " ")
                }
                book.series = new
                if book.seriesOverride == old { book.seriesOverride = new }
                try book.update(db)
            }
            return books.count
        }) ?? 0
    }

    /// Puts comics in a series by hand (an empty name takes them out of any series). The choice
    /// holds when the files are read again. Files are not touched.
    public func setSeries(_ name: String, ids: [Int64]) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try? database.write { db in
            for id in ids {
                guard var book = try LibraryBook.fetchOne(db, key: id) else { continue }
                // A title made up from the series and number ("Saga #12") follows the series.
                if !name.isEmpty, !book.series.isEmpty, book.issueLabel != nil,
                   book.title == [book.series, book.issueLabel].compactMap({ $0 }).joined(separator: " ") {
                    book.title = [name, book.issueLabel].compactMap { $0 }.joined(separator: " ")
                }
                book.series = name
                book.seriesOverride = name
                try book.update(db)
            }
        }
    }

    /// Sets a comic's details by hand. They hold from then on, whatever the file says.
    public func setDetails(id: Int64, title: String, series: String, volume: Int?, number: Double?, year: Int?) {
        let series = series.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id: id) { book in
            book.series = series
            book.seriesOverride = series
            book.volume = volume
            book.number = number
            book.year = year
            if !title.isEmpty { book.title = title }
            book.pinned = true
        }
    }

    private func removeCover(_ id: Int64) { try? FileManager.default.removeItem(at: coverURL(for: id)) }

    /// Adds or refreshes the record for an opened comic. Reading position and settings are kept.
    @discardableResult
    public func record(_ comic: ComicBook, folderID: Int64? = nil, bookmark: Data? = nil) throws -> LibraryBook {
        let attributes = try? FileManager.default.attributesOfItem(atPath: comic.url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes?[.modificationDate] as? Date ?? Date()
        let metadata = comic.metadata()
        var book = try database.write { db -> LibraryBook in
            var book = try LibraryBook.filter(Column("path") == comic.url.path).fetchOne(db)
                ?? LibraryBook(id: nil, path: comic.url.path, folderID: folderID, bookmark: bookmark, title: "", series: "",
                               pageCount: 0, fileSize: 0, modifiedAt: modified, addedAt: Date(), page: 0, finished: false)
            book.folderID = folderID ?? book.folderID
            book.bookmark = bookmark ?? book.bookmark
            if !book.pinned {
                var series = try self.seriesName(for: metadata.series, db)
                if let chosen = book.seriesOverride { series = chosen.isEmpty ? nil : chosen }
                book.series = series ?? ""
                book.number = metadata.number
                book.volume = metadata.volume
                // With no title of its own, an issue is known by its series and number: "Saga #12".
                book.title = metadata.title ?? [series, book.issueLabel].compactMap { $0 }.joined(separator: " ")
                if book.title.isEmpty || book.issueLabel == nil && metadata.title == nil { book.title = metadata.title ?? comic.title }
                book.year = metadata.year
            }
            book.writer = metadata.writer
            book.publisher = metadata.publisher
            book.summary = metadata.summary
            book.pageCount = comic.pageCount
            book.downloaded = true
            book.fileSize = size
            book.modifiedAt = modified
            book.page = min(book.page, max(0, comic.pageCount - 1))
            if book.direction == nil, metadata.manga == true { book.direction = ReadingDirection.rightToLeft.rawValue }
            try book.save(db)
            return book
        }
        if book.id == nil { book = self.book(path: comic.url.path) ?? book }
        if let id = book.id { writeCover(of: comic, id: id) }
        return book
    }

    private func writeCover(of comic: ComicBook, id: Int64) {
        guard let image = try? comic.image(at: 0, maxPixelSize: 640),
              let destination = CGImageDestinationCreateWithURL(coverURL(for: id) as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    // MARK: Hand-drawn panels

    /// Pages of a comic whose panels were set by hand, in reading order. An empty list means "show this page whole".
    public func panelOverrides(bookID: Int64) -> [Int: [CGRect]] {
        let rows = (try? database.read { try Row.fetchAll($0, sql: "SELECT page, rects FROM panelOverride WHERE bookID = ?", arguments: [bookID]) }) ?? []
        var result: [Int: [CGRect]] = [:]
        for row in rows {
            let page: Int = row["page"], json: String = row["rects"]
            guard let values = try? JSONDecoder().decode([[Double]].self, from: Data(json.utf8)) else { continue }
            result[page] = values.filter { $0.count == 4 }.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
        }
        return result
    }

    /// Saves hand-drawn panels for a page; nil goes back to automatic detection.
    public func setPanelOverride(_ panels: [CGRect]?, bookID: Int64, page: Int) {
        try? database.write { db in
            guard let panels else {
                return try db.execute(sql: "DELETE FROM panelOverride WHERE bookID = ? AND page = ?", arguments: [bookID, page])
            }
            let values = panels.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
            let json = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
            try db.execute(sql: "INSERT OR REPLACE INTO panelOverride (bookID, page, rects) VALUES (?, ?, ?)", arguments: [bookID, page, json])
        }
    }

    // MARK: Scanning

    /// False for a file kept in iCloud whose contents are not on this Mac right now.
    public static func isDownloaded(_ url: URL) -> Bool {
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus else { return true }
        return status != .notDownloaded
    }

    /// Whether a file is kept in iCloud at all.
    public static func isInCloud(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    /// Lists a comic that can't be opened yet (not downloaded), from its file name alone.
    @discardableResult
    public func recordPlaceholder(for file: URL, folderID: Int64?, size: Int64, modified: Date) throws -> LibraryBook {
        let metadata = ComicMetadata.fromFileName(file)
        return try database.write { db in
            let series = try self.seriesName(for: metadata.series, db)
            var book = LibraryBook(id: nil, path: file.path, folderID: folderID, bookmark: nil, title: "", series: series ?? "",
                                   number: metadata.number, volume: metadata.volume, year: metadata.year,
                                   pageCount: 0, fileSize: size, modifiedAt: modified, addedAt: Date(), page: 0, finished: false)
            book.title = [series, book.issueLabel].compactMap { $0 }.joined(separator: " ")
            if book.title.isEmpty || book.issueLabel == nil { book.title = metadata.title ?? file.deletingPathExtension().lastPathComponent }
            book.downloaded = false
            try book.insert(db)
            return book
        }
    }

    public struct ScanResult: Sendable {
        public var added = 0, updated = 0, removed = 0, failed = 0
    }

    /// Brings the database in line with what is in a library folder. Slow (opens every new or changed
    /// file); call it off the main thread. `progress` is told (done, total) as it goes.
    public func scan(_ folder: LibraryFolder, at url: URL, progress: (Int, Int) -> Void = { _, _ in }) -> ScanResult {
        guard let folderID = folder.id else { return ScanResult() }
        var files: [URL] = []
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let file = enumerator?.nextObject() as? URL {
            if Self.comicExtensions.contains(file.pathExtension.lowercased()) { files.append(file.standardizedFileURL) }
        }
        let known = Dictionary(books(includingHidden: true).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var result = ScanResult()
        for (index, file) in files.enumerated() {
            progress(index, files.count)
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let existing = known[file.path]
            // A comic that is in iCloud but not on this Mac is listed without being opened: reading it
            // would download it, and a scan must not pull a whole collection down.
            if !Self.isDownloaded(file) {
                if let existing {
                    if existing.downloaded { update(id: existing.id!) { $0.downloaded = false } }
                } else if (try? recordPlaceholder(for: file, folderID: folderID, size: Int64(values?.fileSize ?? 0),
                                                  modified: values?.contentModificationDate ?? Date())) != nil {
                    result.added += 1
                }
                continue
            }
            if let existing, existing.downloaded, existing.pageCount > 0, existing.fileSize == Int64(values?.fileSize ?? -1),
               let modified = values?.contentModificationDate, abs(existing.modifiedAt.timeIntervalSince(modified)) < 1 {
                if existing.folderID != folderID { update(id: existing.id!) { $0.folderID = folderID } }
                continue
            }
            do {
                try record(ComicBook(url: file), folderID: folderID)
                if existing == nil { result.added += 1 } else { result.updated += 1 }
            } catch {
                result.failed += 1
            }
        }
        progress(files.count, files.count)
        // Comics that were in this folder and are gone now. Skipped if the folder itself is unreachable
        // (an unplugged drive shouldn't wipe reading history).
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let present = Set(files.map(\.path))
            let gone = known.values.filter { $0.folderID == folderID && !present.contains($0.path) }.compactMap(\.id)
            remove(ids: gone)
            result.removed = gone.count
        }
        return result
    }
}
