import CoreGraphics
import Foundation

/// One opened comic: a CBZ, CBR, PDF or folder of images.
public final class ComicBook: @unchecked Sendable {
    public let url: URL
    public let title: String
    public let pageCount: Int

    private let source: PageSource
    private let lock = NSLock()
    private var sizes: [Int: CGSize] = [:]

    public static let fileExtensions = ["cbz", "cbr", "zip", "rar", "pdf"]

    public init(url: URL) throws {
        self.url = url
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ComicError.unreadableFile("it no longer exists at \(url.path)")
        }
        if isDirectory.boolValue {
            source = try FolderSource(url: url)
            title = url.lastPathComponent
        } else {
            source = try Self.makeSource(for: url)
            title = url.deletingPathExtension().lastPathComponent
        }
        pageCount = source.pageCount
    }

    /// Picks the reader from the file's contents, not its extension — mislabelled .cbr/.cbz files are common.
    private static func makeSource(for url: URL) throws -> PageSource {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw ComicError.unreadableFile(error.localizedDescription) }
        let magic = [UInt8]((try? handle.read(upToCount: 8)) ?? Data())
        try? handle.close()
        if magic.starts(with: [0x50, 0x4B]) { return try ZipSource(url: url) }                       // PK
        if magic.starts(with: [0x52, 0x61, 0x72, 0x21]) { return try RarSource(url: url) }           // Rar!
        if magic.starts(with: [0x25, 0x50, 0x44, 0x46]) { return try PDFSource(url: url) }           // %PDF
        if magic.starts(with: [0x37, 0x7A, 0xBC, 0xAF]) { throw ComicError.unsupportedFormat("7-Zip / CB7") }
        switch url.pathExtension.lowercased() {
        case "cbz", "zip": return try ZipSource(url: url)
        case "cbr", "rar": return try RarSource(url: url)
        case "pdf": return try PDFSource(url: url)
        default: throw ComicError.unsupportedFormat(url.pathExtension.isEmpty ? "unknown" : url.pathExtension)
        }
    }

    public func pageName(at index: Int) -> String { source.pageName(at: index) }

    /// Decodes a page. Safe to call from any thread.
    public func image(at index: Int, maxPixelSize: Int? = nil) throws -> CGImage {
        guard (0..<pageCount).contains(index) else { throw ComicError.unreadablePage(index) }
        let image = try source.image(at: index, maxPixelSize: maxPixelSize)
        if maxPixelSize == nil { remember(CGSize(width: image.width, height: image.height), for: index) }
        return image
    }

    /// Pixel size of a page (cached). Returns nil when the page can't be read.
    public func pageSize(at index: Int) -> CGSize? {
        guard (0..<pageCount).contains(index) else { return nil }
        lock.lock(); let known = sizes[index]; lock.unlock()
        if let known { return known }
        guard let size = try? source.pageSize(at: index) else { return nil }
        remember(size, for: index)
        return size
    }

    private func remember(_ size: CGSize, for index: Int) {
        lock.lock(); sizes[index] = size; lock.unlock()
    }
}
