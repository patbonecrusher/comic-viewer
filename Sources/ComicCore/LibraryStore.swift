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
        try migrator.migrate(database)
    }

    // MARK: Reading

    public func books() -> [LibraryBook] { (try? database.read { try LibraryBook.fetchAll($0) }) ?? [] }
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

    /// Forgets comics. Files on disk are not touched.
    public func remove(ids: [Int64]) {
        _ = try? database.write { try LibraryBook.deleteAll($0, keys: ids) }
        ids.forEach(removeCover)
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
            book.series = metadata.series ?? ""
            book.number = metadata.number
            book.volume = metadata.volume
            // With no title of its own, an issue is known by its series and number: "Saga #12".
            book.title = metadata.title ?? [metadata.series, book.issueLabel].compactMap { $0 }.joined(separator: " ")
            if book.title.isEmpty || book.issueLabel == nil && metadata.title == nil { book.title = metadata.title ?? comic.title }
            book.number = metadata.number
            book.volume = metadata.volume
            book.year = metadata.year
            book.writer = metadata.writer
            book.publisher = metadata.publisher
            book.summary = metadata.summary
            book.pageCount = comic.pageCount
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

    // MARK: Scanning

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
        let known = Dictionary(books().map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var result = ScanResult()
        for (index, file) in files.enumerated() {
            progress(index, files.count)
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let existing = known[file.path]
            if let existing, existing.fileSize == Int64(values?.fileSize ?? -1),
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
