import Foundation
import Unrar
import ZIPFoundation

/// CBZ / ZIP.
final class ZipSource: DataPageSource {
    private let archive: ZIPFoundation.Archive
    private let entries: [ZIPFoundation.Entry]
    private let others: [ZIPFoundation.Entry]
    private let lock = NSLock()          // ZIPFoundation archives aren't thread-safe

    init(url: URL) throws {
        do { archive = try ZIPFoundation.Archive(url: url, accessMode: .read) }
        catch { throw ComicError.unreadableFile(error.localizedDescription) }
        let files = archive.filter { $0.type == .file }
        entries = PageNames.sortedPages(files, path: \.path)
        others = files.filter { !PageNames.isPage($0.path) }
        if entries.isEmpty { throw ComicError.noPages }
    }

    var pageCount: Int { entries.count }
    func pageName(at index: Int) -> String { entries[index].path }
    func data(at index: Int) throws -> Data { try extract(entries[index]) }

    func sidecar(named name: String) -> Data? {
        guard let entry = others.first(where: { ($0.path as NSString).lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }),
              entry.uncompressedSize < 4_000_000 else { return nil }
        return try? extract(entry)
    }

    private func extract(_ entry: ZIPFoundation.Entry) throws -> Data {
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
    private let others: [Unrar.Entry]
    private let lock = NSLock()

    init(url: URL) throws {
        do {
            archive = try Unrar.Archive(fileURL: url)
            let files = try archive.entries().filter { !$0.directory }
            entries = PageNames.sortedPages(files, path: \.fileName)
            others = files.filter { !PageNames.isPage($0.fileName) }
        } catch { throw ComicError.unreadableFile("\(error)") }
        if entries.isEmpty { throw ComicError.noPages }
    }

    var pageCount: Int { entries.count }
    func pageName(at index: Int) -> String { entries[index].fileName }

    func data(at index: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        return try archive.extract(entries[index])
    }

    func sidecar(named name: String) -> Data? {
        // RAR paths may use either separator.
        guard let entry = others.first(where: {
            ($0.fileName.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
        }), entry.uncompressedSize < 4_000_000 else { return nil }
        lock.lock(); defer { lock.unlock() }
        return try? archive.extract(entry)
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
    func sidecar(named name: String) -> Data? { try? Data(contentsOf: root.appendingPathComponent(name)) }
}
