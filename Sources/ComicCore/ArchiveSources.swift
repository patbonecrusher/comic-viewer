import Foundation
import Unrar
import ZIPFoundation

/// CBZ / ZIP.
final class ZipSource: DataPageSource {
    private let archive: ZIPFoundation.Archive
    private let entries: [ZIPFoundation.Entry]
    private let lock = NSLock()          // ZIPFoundation archives aren't thread-safe

    init(url: URL) throws {
        do { archive = try ZIPFoundation.Archive(url: url, accessMode: .read) }
        catch { throw ComicError.unreadableFile(error.localizedDescription) }
        entries = PageNames.sortedPages(archive.filter { $0.type == .file }, path: \.path)
        if entries.isEmpty { throw ComicError.noPages }
    }

    var pageCount: Int { entries.count }
    func pageName(at index: Int) -> String { entries[index].path }

    func data(at index: Int) throws -> Data {
        let entry = entries[index]
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        lock.lock(); defer { lock.unlock() }
        _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
        return data
    }
}

/// CBR / RAR.
final class RarSource: DataPageSource {
    private let archive: Unrar.Archive
    private let entries: [Unrar.Entry]
    private let lock = NSLock()

    init(url: URL) throws {
        do {
            archive = try Unrar.Archive(fileURL: url)
            entries = PageNames.sortedPages(try archive.entries().filter { !$0.directory }, path: \.fileName)
        } catch { throw ComicError.unreadableFile("\(error)") }
        if entries.isEmpty { throw ComicError.noPages }
    }

    var pageCount: Int { entries.count }
    func pageName(at index: Int) -> String { entries[index].fileName }

    func data(at index: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        return try archive.extract(entries[index])
    }
}

/// A plain folder of images.
final class FolderSource: DataPageSource {
    private let files: [URL]
    private let root: URL

    init(url: URL) throws {
        root = url
        var found: [URL] = []
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        while let file = enumerator?.nextObject() as? URL { found.append(file) }
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        files = PageNames.sortedPages(found) { $0.path.hasPrefix(prefix) ? String($0.path.dropFirst(prefix.count)) : $0.lastPathComponent }
        if files.isEmpty { throw ComicError.noPages }
    }

    var pageCount: Int { files.count }
    func pageName(at index: Int) -> String { files[index].lastPathComponent }
    func data(at index: Int) throws -> Data { try Data(contentsOf: files[index], options: .mappedIfSafe) }
}
