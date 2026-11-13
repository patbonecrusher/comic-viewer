import CoreGraphics
import Foundation

/// Panel information found inside a comic file.
struct EmbeddedPanels {
    /// Saved by Comic Viewer: page file name → panels in unit coordinates.
    var sidecar: [String: [CGRect]] = [:]
    /// From an ACBF document: page file name (lowercased, no folder) → frames as pixel polygons.
    var acbf: [String: [[CGPoint]]] = [:]
}

/// The small JSON file Comic Viewer adds to a CBZ (or folder) to keep hand-set panels with the comic:
///
///     { "version": 1, "generator": "Comic Viewer",
///       "pages": { "Book/page-012.jpg": { "panels": [[x, y, width, height], …] } } }
///
/// Coordinates are fractions of the page (0…1, origin top left) and panels are in reading order.
/// An empty list means the page is to be shown whole. Readers that don't know the file ignore it.
public enum PanelSidecar {
    public static let fileName = "ComicViewerPanels.json"

    private struct Document: Codable {
        struct Page: Codable { var panels: [[Double]] }
        var version = 1
        var generator = "Comic Viewer"
        var pages: [String: Page]
    }

    public static func encode(_ pages: [String: [CGRect]]) throws -> Data {
        let document = Document(pages: pages.mapValues { panels in
            // Four decimals is a third of a pixel on a 3000-pixel page, and keeps the file small.
            Document.Page(panels: panels.map { [$0.minX, $0.minY, $0.width, $0.height].map { (Double($0) * 10_000).rounded() / 10_000 } })
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) -> [String: [CGRect]] {
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else { return [:] }
        return document.pages.mapValues { page in
            page.panels.filter { $0.count == 4 }.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
        }
    }
}

/// Reads the panel frames out of an ACBF (Advanced Comic Book Format) document. Each `<page>` (and
/// the `<coverpage>`) names its image and lists `<frame points="x,y x,y …">` in reading order.
enum ACBFParser {
    static func frames(in data: Data) -> [String: [[CGPoint]]] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.pages
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var pages: [String: [[CGPoint]]] = [:]
        private var inPage = false
        private var image: String?
        private var frames: [[CGPoint]] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            switch name.lowercased() {
            case "page", "coverpage":
                inPage = true; image = nil; frames = []
            case "image" where inPage:
                // href is a file name, sometimes with a "zip:archive!/" prefix or a folder.
                if let href = attributes["href"], !href.hasPrefix("#") {
                    image = ((href.components(separatedBy: "!").last ?? href) as NSString).lastPathComponent.lowercased()
                }
            case "frame" where inPage:
                let points = (attributes["points"] ?? "").split(separator: " ").compactMap { pair -> CGPoint? in
                    let values = pair.split(separator: ",").compactMap { Double($0) }
                    return values.count == 2 ? CGPoint(x: values[0], y: values[1]) : nil
                }
                if points.count >= 3 { frames.append(points) }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard ["page", "coverpage"].contains(name.lowercased()) else { return }
            if let image, !frames.isEmpty { pages[image] = frames }
            inPage = false
        }
    }
}
