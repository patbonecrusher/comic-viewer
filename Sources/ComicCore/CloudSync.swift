import CryptoKit
import Foundation
import ImageIO

/// Shares what a device knows about the comics kept in the app's iCloud Drive folder with the
/// reader's other devices: a small cover and how far each comic has been read.
///
/// A comic that is in iCloud but was never downloaded to a device can't be opened there, so that
/// device knows nothing about it but its file name. A device that does have the file writes two small
/// files next to the comics folder (in `Sync`, which iCloud carries along but the Files app and Finder
/// don't show): `<key>.jpg`, the cover, and `<key>.json`, the comic's details and reading position.
/// Other devices read them, so the comic is listed with its cover and progress before it is fetched,
/// and a comic read on one device continues from the same page on another. The newest reading
/// position wins.
public struct CloudSync: Sendable {
    public struct Result: Sendable {
        /// Comics whose record on this device changed.
        public var changed = 0
        /// Some of the other devices' files are still on their way down; worth another pass shortly.
        public var pending = false
    }

    private struct State: Codable, Equatable {
        var path: String
        var title: String
        var series: String
        var number: Double?
        var volume: Int?
        var year: Int?
        var pinned: Bool
        var pageCount: Int
        var page: Int
        var finished: Bool
        var lastReadAt: Date?
        var changedAt: Date?

        init(_ book: LibraryBook, path: String) {
            self.path = path
            title = book.title; series = book.series; number = book.number; volume = book.volume; year = book.year
            pinned = book.pinned
            pageCount = book.pageCount; page = book.page; finished = book.finished; lastReadAt = book.lastReadAt
            changedAt = book.progressChangedAt
        }

        func sameDetails(as other: State) -> Bool {
            title == other.title && series == other.series && number == other.number && volume == other.volume
                && year == other.year && pageCount == other.pageCount
        }
    }

    private let directory: URL

    /// `container` is the app's iCloud container, the folder that holds `Documents`.
    public init(container: URL) {
        directory = container.appendingPathComponent("Sync", isDirectory: true)
    }

    /// A comic is known across devices by where it is in the iCloud folder.
    static func key(forRelativePath path: String) -> String {
        SHA256.hash(data: Data(path.precomposedStringWithCanonicalMapping.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Brings this device and the shared files in line, both ways. Reads and writes files; call it
    /// off the main thread. `root` is the comics folder in iCloud and `folderID` its library record.
    public func sync(store: LibraryStore, folderID: Int64, root: URL) -> Result {
        var result = Result()
        let files = FileManager.default
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        // What is here, and what iCloud has only left a stand-in for (not downloaded yet).
        var here: Set<String> = [], away: Set<String> = []
        for url in (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if let real = LibraryStore.fileBehindStandIn(url) { away.insert(real.lastPathComponent) } else { here.insert(url.lastPathComponent) }
        }
        away.subtract(here)
        let prefix = root.standardizedFileURL.path + "/"
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for listed in store.books(includingHidden: true) where listed.folderID == folderID && listed.path.hasPrefix(prefix) {
            guard let id = listed.id else { continue }
            var book = listed
            let relative = String(book.path.dropFirst(prefix.count))
            let key = Self.key(forRelativePath: relative)
            let stateURL = directory.appendingPathComponent(key + ".json"), coverURL = directory.appendingPathComponent(key + ".jpg")

            var remote: State?
            if here.contains(stateURL.lastPathComponent) {
                remote = (try? Data(contentsOf: stateURL)).flatMap { try? decoder.decode(State.self, from: $0) }
            } else if away.contains(stateURL.lastPathComponent) {
                try? files.startDownloadingUbiquitousItem(at: stateURL)
                result.pending = true
            }

            // Take what another device knows.
            if let remote {
                var changed = false
                // Never opened here: the other device's details stand in until the file is fetched.
                let unseen = !book.downloaded && book.pageCount == 0
                let newer = (remote.changedAt ?? .distantPast).timeIntervalSince(book.progressChangedAt ?? .distantPast) > 0.002
                if unseen || newer {
                    store.update(id: id) { book in
                        if unseen {
                            book.title = remote.title; book.series = remote.series; book.number = remote.number
                            book.volume = remote.volume; book.year = remote.year; book.pinned = remote.pinned
                            book.pageCount = remote.pageCount
                        }
                        if newer {
                            book.page = book.pageCount > 0 ? min(remote.page, book.pageCount - 1) : remote.page
                            book.finished = remote.finished
                            book.lastReadAt = remote.lastReadAt
                            book.progressChangedAt = remote.changedAt
                        }
                    }
                    changed = true
                    book = store.book(id: id) ?? book
                }
                if changed { result.changed += 1 }
            }

            // Its cover, if this device has none.
            let localCover = store.coverURL(for: id)
            if !files.fileExists(atPath: localCover.path) {
                if here.contains(coverURL.lastPathComponent) {
                    if (try? files.copyItem(at: coverURL, to: localCover)) != nil, remote == nil { result.changed += 1 }
                } else if away.contains(coverURL.lastPathComponent) {
                    try? files.startDownloadingUbiquitousItem(at: coverURL)
                    result.pending = true
                }
            }

            // Tell the other devices what this one knows. Only a device that has opened the file knows anything.
            guard book.downloaded, book.pageCount > 0 else { continue }
            if !here.contains(coverURL.lastPathComponent), !away.contains(coverURL.lastPathComponent), files.fileExists(atPath: localCover.path) {
                Self.writeSmallCover(from: localCover, to: coverURL)
            }
            let mine = State(book, path: relative)
            let missing = remote == nil && !away.contains(stateURL.lastPathComponent)
            let ahead = remote.map { (mine.changedAt ?? .distantPast).timeIntervalSince($0.changedAt ?? .distantPast) > 0.002 } ?? false
            // Details set by hand here replace ones another device guessed from the file name.
            let corrected = remote.map { book.pinned && !mine.sameDetails(as: $0) && !ahead
                && abs((mine.changedAt ?? .distantPast).timeIntervalSince($0.changedAt ?? .distantPast)) <= 0.002 } ?? false
            if missing || ahead || corrected, let data = try? encoder.encode(mine) {
                try? data.write(to: stateURL, options: .atomic)
            }
        }
        return result
    }

    /// Forgets what was shared about a comic, for when it is deleted or moved out of iCloud.
    public func forget(relativePath: String) {
        let key = Self.key(forRelativePath: relativePath)
        for name in [key + ".json", key + ".jpg"] { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
    }

    /// Covers travel small: a few tens of kilobytes each, so a big collection costs little iCloud space.
    private static func writeSmallCover(from source: URL, to destination: URL) {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 420,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary) else { return }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        guard let output = CGImageDestinationCreateWithURL(temporary as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { return }
        try? FileManager.default.moveItem(at: temporary, to: destination)
    }
}
