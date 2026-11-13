import CoreGraphics
import Foundation
import ImageIO

public enum ComicError: LocalizedError {
    case unsupportedFormat(String)
    case noPages
    case unreadablePage(Int)
    case unreadableFile(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let what): return "This file format isn’t supported yet (\(what))."
        case .noPages: return "No pages were found in this comic."
        case .unreadablePage(let index): return "Page \(index + 1) couldn’t be read."
        case .unreadableFile(let why): return "The file couldn’t be opened: \(why)"
        }
    }
}

/// Something that can produce the pages of one comic, in reading order.
protocol PageSource: AnyObject {
    var pageCount: Int { get }
    func pageName(at index: Int) -> String
    /// Decoded page, downsampled so its longest side is at most `maxPixelSize` (nil = full size).
    func image(at index: Int, maxPixelSize: Int?) throws -> CGImage
    /// Pixel size of the page without decoding it.
    func pageSize(at index: Int) throws -> CGSize
    /// A non-page file stored with the comic, such as ComicInfo.xml. Matched on file name, ignoring case.
    func sidecar(where matches: (String) -> Bool) -> Data?
    /// Whether extra files can be saved alongside the pages (a CBZ or a folder; not CBR or PDF).
    var canWriteSidecars: Bool { get }
    /// Adds or replaces a non-page file stored with the comic.
    func writeSidecar(named name: String, data: Data) throws
}

extension PageSource {
    func sidecar(where matches: (String) -> Bool) -> Data? { nil }
    var canWriteSidecars: Bool { false }
    func writeSidecar(named name: String, data: Data) throws { throw ComicError.unsupportedFormat("saving into this kind of file") }

    func sidecar(named name: String) -> Data? {
        sidecar { ($0 as NSString).lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// A source whose pages are encoded image files (everything except PDF).
protocol DataPageSource: PageSource {
    func data(at index: Int) throws -> Data
}

extension DataPageSource {
    func image(at index: Int, maxPixelSize: Int?) throws -> CGImage {
        let data = try data(at: index)
        guard let image = ImageDecoding.image(from: data, maxPixelSize: maxPixelSize) else { throw ComicError.unreadablePage(index) }
        return image
    }

    func pageSize(at index: Int) throws -> CGSize {
        let data = try data(at: index)
        guard let size = ImageDecoding.pixelSize(of: data) else { throw ComicError.unreadablePage(index) }
        return size
    }
}

enum ImageDecoding {
    static func image(from data: Data, maxPixelSize: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        if let maxPixelSize, let size = pixelSize(of: source), Int(max(size.width, size.height)) > maxPixelSize {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return pixelSize(of: source)
    }

    private static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return nil }
        // EXIF orientations 5–8 are rotated a quarter turn.
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }
}

/// Which archive entries count as pages, and in what order.
public enum PageNames {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "avif", "jxl"]

    public static func isPage(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard let name = parts.last else { return false }
        if parts.contains(where: { $0 == "__MACOSX" || $0.hasPrefix(".") }) { return false }
        guard let dot = name.lastIndex(of: ".") else { return false }
        return imageExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    /// Natural ordering: "page2" sorts before "page10".
    public static func sorted(_ paths: [String]) -> [String] {
        paths.sorted { $0.compare($1, options: [.numeric, .caseInsensitive, .widthInsensitive]) == .orderedAscending }
    }

    static func sortedPages<T>(_ items: [T], path: (T) -> String) -> [T] {
        items.filter { isPage(path($0)) }
            .sorted { path($0).compare(path($1), options: [.numeric, .caseInsensitive, .widthInsensitive]) == .orderedAscending }
    }
}
