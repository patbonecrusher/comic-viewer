import Foundation

public enum PageLayout: String, CaseIterable, Sendable {
    case single, double
}

public enum ReadingDirection: String, CaseIterable, Sendable {
    case leftToRight, rightToLeft
}

/// The page or pair of pages shown together, in reading order.
public struct Spread: Equatable, Sendable {
    public let pages: [Int]
    public init(_ pages: [Int]) { self.pages = pages }
    public var first: Int { pages[0] }
    public func contains(_ page: Int) -> Bool { pages.contains(page) }
}

public enum SpreadBuilder {
    /// Groups pages into spreads. In double layout the cover stands alone and so does any landscape
    /// page (already a two-page spread in the scan), so facing pages stay paired the way they were printed.
    public static func spreads(pageCount: Int, layout: PageLayout, coverAlone: Bool = true, isWide: (Int) -> Bool) -> [Spread] {
        guard pageCount > 0 else { return [] }
        guard layout == .double else { return (0..<pageCount).map { Spread([$0]) } }
        var result: [Spread] = []
        var index = 0
        if coverAlone { result.append(Spread([0])); index = 1 }
        while index < pageCount {
            if !isWide(index), index + 1 < pageCount, !isWide(index + 1) {
                result.append(Spread([index, index + 1]))
                index += 2
            } else {
                result.append(Spread([index]))
                index += 1
            }
        }
        return result
    }

    public static func index(of page: Int, in spreads: [Spread]) -> Int {
        spreads.firstIndex { $0.contains(page) } ?? 0
    }
}
