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
    private var embedded: EmbeddedPanels?

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

    /// What is known about the comic: its embedded ComicInfo.xml where there is one, the file name otherwise.
    public func metadata() -> ComicMetadata {
        var metadata = ComicMetadata.fromFileName(url)
        if let data = source.sidecar(named: "ComicInfo.xml") { metadata.merge(ComicInfoParser.parse(data)) }
        return metadata
    }

    // MARK: Panels stored in the file

    /// Whether panels can be saved inside this comic (CBZ and folders; not CBR or PDF).
    public var canStorePanels: Bool { source.canWriteSidecars }

    private func loadEmbedded() -> EmbeddedPanels {
        lock.lock(); let loaded = embedded; lock.unlock()
        if let loaded { return loaded }
        var result = EmbeddedPanels()
        if let data = source.sidecar(named: PanelSidecar.fileName) { result.sidecar = PanelSidecar.decode(data) }
        if let data = source.sidecar(where: { $0.lowercased().hasSuffix(".acbf") }) { result.acbf = ACBFParser.frames(in: data) }
        lock.lock(); embedded = result; lock.unlock()
        return result
    }

    /// Panels that came with the comic for one page, in reading order and unit coordinates: ones saved
    /// by Comic Viewer, otherwise the frames of an ACBF file. Nil when the file says nothing about the
    /// page; an empty list means "show it whole".
    public func embeddedPanels(forPage index: Int) -> [CGRect]? {
        guard (0..<pageCount).contains(index) else { return nil }
        let stored = loadEmbedded(), name = source.pageName(at: index)
        if let panels = stored.sidecar[name] { return panels }
        // ACBF gives frames as pixel polygons on the page image.
        guard let frames = stored.acbf[(name as NSString).lastPathComponent.lowercased()], !frames.isEmpty,
              let size = pageSize(at: index), size.width > 0, size.height > 0 else { return nil }
        return frames.compactMap { points -> CGRect? in
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
            let rect = CGRect(x: minX / size.width, y: minY / size.height, width: (maxX - minX) / size.width, height: (maxY - minY) / size.height)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            return rect.isNull || rect.width < 0.01 || rect.height < 0.01 ? nil : rect
        }
    }

    /// Every page with panels saved by Comic Viewer in the file.
    public func storedPanels() -> [Int: [CGRect]] {
        let stored = loadEmbedded().sidecar
        guard !stored.isEmpty else { return [:] }
        var result: [Int: [CGRect]] = [:]
        for index in 0..<pageCount { if let panels = stored[source.pageName(at: index)] { result[index] = panels } }
        return result
    }

    /// Saves hand-set panels inside the comic, replacing any saved before. Pages are identified by
    /// their file names, so the panels survive pages being added or removed. Rewrites part of the
    /// file; call it off the main thread.
    public func storePanels(_ pages: [Int: [CGRect]]) throws {
        var byName: [String: [CGRect]] = [:]
        for (index, panels) in pages where (0..<pageCount).contains(index) { byName[source.pageName(at: index)] = panels }
        try source.writeSidecar(named: PanelSidecar.fileName, data: PanelSidecar.encode(byName))
        lock.lock(); embedded?.sidecar = byName; lock.unlock()
    }

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
