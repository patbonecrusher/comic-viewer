import Foundation
import Unrar
import ZIPFoundation

/// CBZ / ZIP.
final class ZipSource: DataPageSource {
    private let url: URL
    private var archive: ZIPFoundation.Archive
    private var entries: [ZIPFoundation.Entry]
    private var others: [ZIPFoundation.Entry]
    private let lock = NSLock()          // ZIPFoundation archives aren't thread-safe

    init(url: URL) throws {
        self.url = url
        do { archive = try ZIPFoundation.Archive(url: url, accessMode: .read) }
        catch { throw ComicError.unreadableFile(error.localizedDescription) }
        let files = archive.filter { $0.type == .file }
        entries = PageNames.sortedPages(files, path: \.path)
        others = files.filter { !PageNames.isPage($0.path) }
        if entries.isEmpty { throw ComicError.noPages }
    }

    var canWriteSidecars: Bool { FileManager.default.isWritableFile(atPath: url.path) }

    func writeSidecar(named name: String, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        do {
            let writable = try ZIPFoundation.Archive(url: url, accessMode: .update)
            if let existing = writable[name] { try writable.remove(existing) }
            try writable.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        // The file's directory has moved: read it again. Pages keep their order.
        archive = try ZIPFoundation.Archive(url: url, accessMode: .read)
        let files = archive.filter { $0.type == .file }
        entries = PageNames.sortedPages(files, path: \.path)
        others = files.filter { !PageNames.isPage($0.path) }
    }

    var pageCount: Int { entries.count }
    func pageName(at index: Int) -> String { lock.lock(); defer { lock.unlock() }; return entries[index].path }

    func data(at index: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        return try extract(entries[index])
    }

    func sidecar(where matches: (String) -> Bool) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = others.first(where: { matches($0.path) }), entry.uncompressedSize < 8_000_000 else { return nil }
        return try? extract(entry)
    }

    /// Call with the lock held.
    private func extract(_ entry: ZIPFoundation.Entry) throws -> Data {
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
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

    func sidecar(where matches: (String) -> Bool) -> Data? {
        // RAR paths may use either separator.
        guard let entry = others.first(where: { matches($0.fileName.replacingOccurrences(of: "\\", with: "/")) }),
              entry.uncompressedSize < 8_000_000 else { return nil }
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

    func sidecar(where matches: (String) -> Bool) -> Data? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.first(where: matches).flatMap { try? Data(contentsOf: root.appendingPathComponent($0)) }
    }

    var canWriteSidecars: Bool { FileManager.default.isWritableFile(atPath: root.path) }
    func writeSidecar(named name: String, data: Data) throws { try data.write(to: root.appendingPathComponent(name), options: .atomic) }
}
