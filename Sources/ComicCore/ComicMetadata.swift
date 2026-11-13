import Foundation

/// Descriptive details of one comic.
public struct ComicMetadata: Equatable, Sendable {
    public var title: String?
    public var series: String?
    public var number: Double?
    public var volume: Int?
    public var year: Int?
    public var writer: String?
    public var publisher: String?
    public var summary: String?
    /// True when the comic says it reads right to left.
    public var manga: Bool?

    public init() {}

    /// Fills in whatever `other` knows; its values win.
    mutating func merge(_ other: ComicMetadata) {
        title = other.title ?? title
        series = other.series ?? series
        number = other.number ?? number
        volume = other.volume ?? volume
        year = other.year ?? year
        writer = other.writer ?? writer
        publisher = other.publisher ?? publisher
        summary = other.summary ?? summary
        manga = other.manga ?? manga
    }

    /// Best guess from names like "Saga 012 (2013) (Digital).cbz", "Akira v03.cbz" or
    /// "bladerunner2019volume2_offworld.cbz". When the name gives no series, the folder's name is used.
    public static func fromFileName(_ url: URL) -> ComicMetadata {
        var metadata = ComicMetadata()
        var name = url.hasDirectoryPath ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        name = name.replacingOccurrences(of: "_", with: " ")

        // (2019), (Digital), [Scanlator] … — keep a year if one is there, drop the rest.
        for match in matches(#"[\(\[]([^\)\]]*)[\)\]]"#, in: name) {
            if metadata.year == nil, let year = Int(match[1].prefix(4)), match[1].count >= 4, (1900...2100).contains(year) { metadata.year = year }
        }
        name = name.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)

        var seriesPart = name, titlePart = ""
        if let volume = matches(#"(?i)(?<![a-z])(?:volume|vol\.?|v)[\s.]*(\d{1,3})(?!\d)"#, in: name).first, let range = name.range(of: volume[0]) {
            metadata.volume = Int(volume[1])
            seriesPart = String(name[..<range.lowerBound])
            titlePart = String(name[range.upperBound...])
        }
        // "Issue 4" spelled out, anywhere after the series name.
        if let issue = matches(#"(?i)(?<![a-z])issue[\s.]*(\d{1,4})(?!\d)"#, in: name).first, let range = seriesPart.range(of: issue[0]) {
            metadata.number = Double(issue[1])
            if titlePart.isEmpty { titlePart = String(seriesPart[range.upperBound...]) }
            seriesPart = String(seriesPart[..<range.lowerBound])
        } else if let range = titlePart.range(of: #"(?i)(?<![a-z])issue[\s.]*(\d{1,4})(?!\d)"#, options: .regularExpression) {
            metadata.number = matches(#"(\d+)"#, in: String(titlePart[range])).first.flatMap { Double($0[1]) }
            titlePart.removeSubrange(range)
        }
        // A trailing issue number: "#12", "012", "12.5" — but not something that looks like a year in the title.
        if metadata.number == nil, let issue = matches(#"(?:\s|^)(#?)(\d{1,4}(?:\.\d+)?)\s*$"#, in: seriesPart).first, let value = Double(issue[2]) {
            let looksLikeYear = issue[1].isEmpty && issue[2].count == 4 && (1900...2100).contains(Int(value))
            if !looksLikeYear, let range = seriesPart.range(of: issue[0], options: .backwards) {
                metadata.number = value
                seriesPart.removeSubrange(range)
            }
        }
        let trim = CharacterSet(charactersIn: " -–—.,:#")
        let series = seriesPart.trimmingCharacters(in: trim), title = titlePart.trimmingCharacters(in: trim)
        if !series.isEmpty {
            metadata.series = series
        } else {
            let folder = url.deletingLastPathComponent().lastPathComponent
            if !folder.isEmpty, folder != "/" { metadata.series = folder }
        }
        if !title.isEmpty { metadata.title = title }
        return metadata
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }
}

/// Reads the ComicInfo.xml that ComicRack-compatible tools embed in archives.
enum ComicInfoParser {
    static func parse(_ data: Data) -> ComicMetadata {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        func text(_ key: String) -> String? {
            let value = delegate.values[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        var metadata = ComicMetadata()
        metadata.title = text("Title")
        metadata.series = text("Series")
        metadata.number = text("Number").flatMap(Double.init)
        metadata.volume = text("Volume").flatMap(Int.init)
        metadata.year = text("Year").flatMap(Int.init)
        metadata.writer = text("Writer")
        metadata.publisher = text("Publisher")
        metadata.summary = text("Summary")
        if let manga = text("Manga") { metadata.manga = manga == "YesAndRightToLeft" }
        return metadata
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        private var depth = 0
        private var current = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            current = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { current += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if depth == 2 { values[name] = current }      // direct children of <ComicInfo>
            depth -= 1
        }
    }
}
