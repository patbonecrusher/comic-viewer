import CoreGraphics
import Foundation

/// Finds the panels on a comic page and puts them in reading order.
///
/// The method is a recursive "XY cut": gutters are bands of background colour that cross a region
/// from side to side. Cut a page along its horizontal gutters into strips, cut each strip along its
/// vertical gutters, and repeat until nothing more can be cut. The order the cuts are made in is the
/// reading order, so no separate sorting step is needed.
///
/// Gutters only exist on pages laid out as a grid on plain paper. Many pages instead set framed
/// panels on top of full-page artwork, so a second pass (`FrameFinder`) looks inside every large
/// uncut area for rectangles whose four sides are drawn as straight edges. Where the frames leave a
/// good part of the artwork showing, the area itself comes first as an overview, then its frames.
///
/// Pages neither method can make sense of (splash pages, borderless or irregular panels) come back
/// as one panel covering the whole page, which the reader shows as-is.
public enum PanelDetector {
    /// A panel's frame in unit coordinates (0…1, origin at the top left of the page).
    public typealias Panel = CGRect

    public static let wholePage = CGRect(x: 0, y: 0, width: 1, height: 1)

    public static func detect(in image: CGImage, direction: ReadingDirection = .leftToRight) -> [Panel] {
        guard let page = GrayPage(image: image, longSide: 900) else { return [wholePage] }
        let frames = FrameFinder(page: page, direction: direction)
        for background in page.backgroundCandidates() {
            let regions = Cutter(page: page, background: background, direction: direction).regions()
            guard regions.count >= 2 else { continue }
            // Look for framed panels inside the bigger pieces the gutters left.
            let refined = regions.flatMap { region -> [Region] in
                guard region.area * 100 >= page.width * page.height * 15 else { return [region] }
                let inner = frames.frames(in: region)
                return inner.isEmpty ? [region] : inner
            }
            return refined.map { $0.unit(width: page.width, height: page.height) }
        }
        let whole = Region(x0: 0, y0: 0, x1: page.width, y1: page.height)
        let inner = frames.frames(in: whole)
        return inner.isEmpty ? [wholePage] : inner.map { $0.unit(width: page.width, height: page.height) }
    }
}

/// A pixel rectangle on the downsampled page (half-open).
private struct Region: Equatable {
    var x0: Int, y0: Int, x1: Int, y1: Int
    var width: Int { x1 - x0 }
    var height: Int { y1 - y0 }
    var area: Int { width * height }

    func unit(width: Int, height: Int) -> CGRect {
        CGRect(x: Double(x0) / Double(width), y: Double(y0) / Double(height),
               width: Double(self.width) / Double(width), height: Double(self.height) / Double(height))
    }

    func intersectionArea(_ other: Region) -> Int {
        max(0, min(x1, other.x1) - max(x0, other.x0)) * max(0, min(y1, other.y1) - max(y0, other.y0))
    }
}

/// The page as 8-bit luminance, top row first.
private struct GrayPage {
    let width: Int, height: Int
    let pixels: [UInt8]

    init?(image: CGImage, longSide: Int) {
        guard image.width > 0, image.height > 0 else { return nil }
        let scale = min(1, Double(longSide) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width; self.height = height; self.pixels = pixels
    }

    /// Gutter colours worth trying, most likely first: whatever the page's outer edge is made of
    /// when that is clearly paper-white or black, then plain white and black.
    func backgroundCandidates() -> [UInt8] {
        let frame = max(2, min(width, height) / 60)
        var histogram = [Int](repeating: 0, count: 256), count = 0
        for y in 0..<height {
            let edgeRow = y < frame || y >= height - frame
            for x in stride(from: 0, to: width, by: edgeRow ? 1 : max(1, width - frame)) {
                // On interior rows only the left and right bands count.
                for dx in 0..<(edgeRow ? 1 : frame) where x + dx < width {
                    histogram[Int(pixels[y * width + x + dx])] += 1; count += 1
                }
            }
        }
        var seen = 0, median = 255
        for value in 0..<256 { seen += histogram[value]; if seen * 2 >= count { median = value; break } }
        var candidates: [UInt8] = []
        if median >= 200 || median <= 55 { candidates.append(UInt8(median)) }
        for fallback: UInt8 in [255, 0] where !candidates.contains(where: { abs(Int($0) - Int(fallback)) < 40 }) { candidates.append(fallback) }
        return candidates
    }
}

private struct Cutter {
    let width: Int, height: Int
    let direction: ReadingDirection
    /// Summed-area table of "this pixel is not background", so any row or column slice is counted in O(1).
    private let table: [Int32]
    /// The same, with "background" meaning almost exactly the paper colour. Bright artwork (glare, sky,
    /// snow) passes the looser test but not this one.
    private let strictTable: [Int32]
    private let minGutter: Int

    init(page: GrayPage, background: UInt8, direction: ReadingDirection) {
        width = page.width; height = page.height; self.direction = direction
        minGutter = max(3, max(width, height) * 45 / 10_000)
        let tolerance = 28, strictTolerance = 8, stride = width + 1
        var table = [Int32](repeating: 0, count: stride * (height + 1)), strictTable = table
        for y in 0..<height {
            var rowSum: Int32 = 0, strictSum: Int32 = 0
            for x in 0..<width {
                let difference = abs(Int(page.pixels[y * width + x]) - Int(background))
                if difference > tolerance { rowSum += 1 }
                if difference > strictTolerance { strictSum += 1 }
                table[(y + 1) * stride + x + 1] = table[y * stride + x + 1] + rowSum
                strictTable[(y + 1) * stride + x + 1] = strictTable[y * stride + x + 1] + strictSum
            }
        }
        self.table = table; self.strictTable = strictTable
    }

    private func ink(_ r: Region, strict: Bool = false) -> Int {
        let s = width + 1
        return strict
            ? Int(strictTable[r.y1 * s + r.x1] - strictTable[r.y0 * s + r.x1] - strictTable[r.y1 * s + r.x0] + strictTable[r.y0 * s + r.x0])
            : Int(table[r.y1 * s + r.x1] - table[r.y0 * s + r.x1] - table[r.y1 * s + r.x0] + table[r.y0 * s + r.x0])
    }

    /// Runs of non-gutter lines across `region` along one axis. Gutters narrower than `minGutter`
    /// that sit between two runs are treated as part of the artwork (thin white lines, lettering gaps).
    private func segments(of r: Region, rows: Bool) -> [(Int, Int)] {
        let span = rows ? r.x1 - r.x0 : r.y1 - r.y0
        let noise = max(1, span / 500)
        let lower = rows ? r.y0 : r.x0, upper = rows ? r.y1 : r.x1
        var result: [(Int, Int)] = []
        var start: Int?
        for line in lower..<upper {
            let slice = rows ? Region(x0: r.x0, y0: line, x1: r.x1, y1: line + 1) : Region(x0: line, y0: r.y0, x1: line + 1, y1: r.y1)
            let isGutter = ink(slice) <= noise
            if !isGutter, start == nil { start = line }
            if isGutter, let begun = start { result.append((begun, line)); start = nil }
        }
        if let begun = start { result.append((begun, upper)) }
        var merged: [(Int, Int)] = []
        for segment in result {
            if let last = merged.last, segment.0 - last.1 < minGutter { merged[merged.count - 1].1 = segment.1 } else { merged.append(segment) }
        }
        return merged
    }

    /// A second, more forgiving look for gutters when the strict one finds none: art that breaks out of
    /// its panel (a head, a sound effect, a balloon) may cover up to 30% of a gutter's length. To avoid
    /// mistaking pale artwork for a gutter, the band must be gutter-thin and have busy artwork on both sides.
    private func bridgedSegments(of r: Region, rows: Bool) -> [(Int, Int)] {
        let span = rows ? r.x1 - r.x0 : r.y1 - r.y0
        let lower = rows ? r.y0 : r.x0, upper = rows ? r.y1 : r.x1
        let maxGutter = max(width, height) * 3 / 100
        guard upper - lower > 2 * maxGutter else { return [(lower, upper)] }
        // Strict: the uncovered part of a crossed gutter is bare paper, not merely something pale.
        let inkPerLine = (lower..<upper).map { line in
            ink(rows ? Region(x0: r.x0, y0: line, x1: r.x1, y1: line + 1) : Region(x0: line, y0: r.y0, x1: line + 1, y1: r.y1), strict: true)
        }
        func isBusy(_ range: Range<Int>) -> Bool {
            let lines = range.clamped(to: 0..<inkPerLine.count)
            return !lines.isEmpty && inkPerLine[lines].reduce(0, +) * 2 >= span * lines.count
        }
        var cuts: [(Int, Int)] = []
        var start: Int?
        for index in 0...inkPerLine.count {
            let isCandidate = index < inkPerLine.count && inkPerLine[index] * 10 <= span * 3
            if isCandidate, start == nil { start = index }
            if !isCandidate, let begun = start {
                start = nil
                let thickness = index - begun
                if begun > 0, index < inkPerLine.count, thickness >= minGutter, thickness <= maxGutter,
                   isBusy(begun - 4..<begun - 1), isBusy(index + 1..<index + 4) {
                    cuts.append((begun, index))
                }
            }
        }
        var result: [(Int, Int)] = [], position = 0
        for (begun, ended) in cuts { result.append((lower + position, lower + begun)); position = ended }
        result.append((lower + position, upper))
        return result
    }

    /// Shrinks a region to its content.
    private func trimmed(_ region: Region) -> Region? {
        var r = region
        for _ in 0..<3 {
            let rows = segments(of: r, rows: true)
            guard let top = rows.first, let bottom = rows.last else { return nil }
            r.y0 = top.0; r.y1 = bottom.1
            let columns = segments(of: r, rows: false)
            guard let left = columns.first, let right = columns.last else { return nil }
            if left.0 == r.x0, right.1 == r.x1 { break }
            r.x0 = left.0; r.x1 = right.1
        }
        return r
    }

    private func cut(_ region: Region, depth: Int, into leaves: inout [Region]) {
        guard let r = trimmed(region) else { return }
        guard depth < 10 else { return leaves.append(r) }
        let rows = segments(of: r, rows: true)
        if rows.count > 1 {
            for (y0, y1) in rows { cut(Region(x0: r.x0, y0: y0, x1: r.x1, y1: y1), depth: depth + 1, into: &leaves) }
            return
        }
        let columns = segments(of: r, rows: false)
        if columns.count > 1 {
            for (x0, x1) in direction == .rightToLeft ? columns.reversed() : columns {
                cut(Region(x0: x0, y0: r.y0, x1: x1, y1: r.y1), depth: depth + 1, into: &leaves)
            }
            return
        }
        let bridgedRows = bridgedSegments(of: r, rows: true)
        if bridgedRows.count > 1 {
            for (y0, y1) in bridgedRows { cut(Region(x0: r.x0, y0: y0, x1: r.x1, y1: y1), depth: depth + 1, into: &leaves) }
            return
        }
        let bridgedColumns = bridgedSegments(of: r, rows: false)
        if bridgedColumns.count > 1 {
            for (x0, x1) in direction == .rightToLeft ? bridgedColumns.reversed() : bridgedColumns {
                cut(Region(x0: x0, y0: r.y0, x1: x1, y1: r.y1), depth: depth + 1, into: &leaves)
            }
            return
        }
        leaves.append(r)
    }

    func regions() -> [Region] {
        var leaves: [Region] = []
        cut(Region(x0: 0, y0: 0, x1: width, y1: height), depth: 0, into: &leaves)
        // Drop page numbers, stray captions and specks.
        let kept = leaves.filter { r in
            let w = Double(r.x1 - r.x0) / Double(width), h = Double(r.y1 - r.y0) / Double(height)
            return w >= 0.06 && h >= 0.05 && w * h >= 0.012
        }
        // Too many pieces means we shredded a text page or a collage; too little coverage means we threw most of the page away.
        let coverage = kept.reduce(0.0) { $0 + Double(($1.x1 - $1.x0) * ($1.y1 - $1.y0)) } / Double(width * height)
        guard kept.count >= 2, kept.count <= 24, coverage >= 0.35 else { return [] }
        return kept
    }
}

/// Finds framed panels: rectangles whose sides are straight edges in the artwork.
private struct FrameFinder {
    let width: Int, height: Int
    let direction: ReadingDirection
    /// vertical[x * (height + 1) + y] = number of "edge of a vertical line" pixels in column x above row y
    /// (the edge map is widened by a pixel either side, so slightly wobbly borders still line up).
    private let vertical: [Int32]
    /// horizontal[y * (width + 1) + x] = the same along row y, left of column x.
    private let horizontal: [Int32]

    init(page: GrayPage, direction: ReadingDirection) {
        width = page.width; height = page.height; self.direction = direction
        let w = width, h = height, pixels = page.pixels, threshold = 15
        var vEdge = [Bool](repeating: false, count: w * h), hEdge = [Bool](repeating: false, count: w * h)
        for y in 1..<max(1, h - 1) {
            for x in 1..<max(1, w - 1) {
                let i = y * w + x
                if abs(Int(pixels[i + 1]) - Int(pixels[i - 1])) >= threshold { vEdge[i] = true }
                if abs(Int(pixels[i + w]) - Int(pixels[i - w])) >= threshold { hEdge[i] = true }
            }
        }
        var vertical = [Int32](repeating: 0, count: w * (h + 1)), horizontal = [Int32](repeating: 0, count: h * (w + 1))
        for x in 0..<w {
            var sum: Int32 = 0
            for y in 0..<h {
                let i = y * w + x
                if vEdge[i] || (x > 0 && vEdge[i - 1]) || (x + 1 < w && vEdge[i + 1]) { sum += 1 }
                vertical[x * (h + 1) + y + 1] = sum
            }
        }
        for y in 0..<h {
            var sum: Int32 = 0
            for x in 0..<w {
                let i = y * w + x
                if hEdge[i] || (y > 0 && hEdge[i - w]) || (y + 1 < h && hEdge[i + w]) { sum += 1 }
                horizontal[y * (w + 1) + x + 1] = sum
            }
        }
        self.vertical = vertical; self.horizontal = horizontal
    }

    private func verticalEdges(x: Int, from y0: Int, to y1: Int) -> Int {
        Int(vertical[x * (height + 1) + y1] - vertical[x * (height + 1) + y0])
    }

    private func horizontalEdges(y: Int, from x0: Int, to x1: Int) -> Int {
        Int(horizontal[y * (width + 1) + x1] - horizontal[y * (width + 1) + x0])
    }

    /// How much of a side is a drawn edge (0…1), and how much more that is than the lines a few pixels either side of it.
    private func side(vertical isVertical: Bool, at position: Int, from start: Int, to end: Int) -> (support: Double, standout: Double) {
        let limit = isVertical ? width : height
        func density(_ p: Int) -> Double {
            guard p >= 0, p < limit else { return 0 }
            return Double(isVertical ? verticalEdges(x: p, from: start, to: end) : horizontalEdges(y: p, from: start, to: end)) / Double(end - start)
        }
        let support = density(position)
        // Two distances each way, taking the quieter, so a thick border isn't compared with itself.
        let before = min(density(position - 6), density(position - 11)), after = min(density(position + 6), density(position + 11))
        return (support, support - (before + after) / 2)
    }

    /// For a side partly hidden behind other frames: how much of the part that still shows is a drawn edge.
    /// Nil when under two fifths of the side is hidden (then it simply isn't a border).
    private func visibleSupport(of r: Region, side: Int, behind frames: [Region]) -> Double? {
        let isVertical = side < 2                                   // sides are left, right, top, bottom
        let position = [r.x0, r.x1 - 1, r.y0, r.y1 - 1][side]
        let start = isVertical ? r.y0 : r.x0, end = isVertical ? r.y1 - 1 : r.x1 - 1
        let margin = 3
        var hidden = [Bool](repeating: false, count: max(0, end - start))
        for frame in frames {
            let across = isVertical ? (frame.x0 - margin...frame.x1 + margin) : (frame.y0 - margin...frame.y1 + margin)
            guard across.contains(position) else { continue }
            let from = max(start, (isVertical ? frame.y0 : frame.x0) - margin), to = min(end, (isVertical ? frame.y1 : frame.x1) + margin)
            if from < to { for index in from..<to { hidden[index - start] = true } }
        }
        let hiddenCount = hidden.filter { $0 }.count
        guard !hidden.isEmpty, hiddenCount * 5 >= hidden.count * 2 else { return nil }
        var edges = 0, length = 0, index = 0
        while index < hidden.count {
            guard !hidden[index] else { index += 1; continue }
            var runEnd = index
            while runEnd < hidden.count, !hidden[runEnd] { runEnd += 1 }
            edges += isVertical ? verticalEdges(x: position, from: start + index, to: start + runEnd)
                                : horizontalEdges(y: position, from: start + index, to: start + runEnd)
            length += runEnd - index
            index = runEnd
        }
        return length == 0 ? 1 : Double(edges) / Double(length)
    }

    /// Positions along one axis where a long straight edge runs. Lines are ranked by how much they stand
    /// out from the lines a few pixels either side, so one faint border in flat colour beats a row of
    /// hatching, and a thick border (several adjacent peaks) takes one place in the list, not three.
    private func lines(in r: Region, vertical isVertical: Bool) -> [Int] {
        let lower = isVertical ? r.x0 : r.y0, upper = isVertical ? r.x1 : r.y1
        let minimum = (isVertical ? height : width) * 5 / 100
        let counts = (lower..<upper).map { isVertical ? verticalEdges(x: $0, from: r.y0, to: r.y1) : horizontalEdges(y: $0, from: r.x0, to: r.x1) }
        func count(_ index: Int) -> Int { counts.indices.contains(index) ? counts[index] : 0 }
        var peaks: [(index: Int, standout: Int)] = []
        for index in counts.indices where counts[index] >= minimum && counts[index] >= count(index - 1) && counts[index] > count(index + 1) {
            let standout = counts[index] - (min(count(index - 6), count(index - 11)) + min(count(index + 6), count(index + 11))) / 2
            if standout * 2 >= minimum { peaks.append((index, standout)) }
        }
        var chosen: [Int] = []
        for peak in peaks.sorted(by: { $0.standout > $1.standout }) where chosen.count < 44 {
            if !chosen.contains(where: { abs($0 - peak.index) <= 3 }) { chosen.append(peak.index) }
        }
        // The area's own edges can be sides too (a panel that bleeds off the page has no drawn border there).
        return Array(Set(chosen.map { lower + $0 } + [lower, upper - 1])).sorted()
    }

    func frames(in r: Region) -> [Region] {
        let xs = lines(in: r, vertical: true), ys = lines(in: r, vertical: false)
        // Smaller rectangles than this are nearly always part of the scenery: signs, screens, windows.
        let minWidth = max(8, width * 9 / 100), minHeight = max(8, height * 8 / 100), minArea = width * height * 4 / 100
        let slack = 3
        typealias Side = (support: Double, standout: Double)
        // A side on the area's boundary needs no drawn edge (nil). "Standout" separates a border from
        // hatching, rain or blinds, where every nearby line is an edge too.
        func isWeak(_ side: Side?, needing support: Double = 0.7) -> Bool {
            guard let side else { return false }
            return !(side.support >= support && side.standout >= 0.4)
        }
        var found: [(region: Region, score: Double)] = []
        // Candidates with exactly one side that isn't drawn well enough: possibly a panel tucked behind another.
        var tucked: [(region: Region, score: Double, weakSide: Int)] = []
        for (i, left) in xs.enumerated() {
            let leftOnBoundary = left - r.x0 <= slack
            for right in xs[(i + 1)...] where right - left >= minWidth {
                let rightOnBoundary = r.x1 - 1 - right <= slack
                for (j, top) in ys.enumerated() {
                    let topSide: Side? = top - r.y0 <= slack ? nil : side(vertical: false, at: top, from: left, to: right)
                    for bottom in ys[(j + 1)...] where bottom - top >= minHeight {
                        let candidate = Region(x0: left, y0: top, x1: right + 1, y1: bottom + 1)
                        guard candidate.area >= minArea, candidate.area * 100 < r.area * 90 else { continue }
                        // At most one side may be weak, so most candidates are thrown out after two or three sides.
                        let bottomSide: Side? = r.y1 - 1 - bottom <= slack ? nil : side(vertical: false, at: bottom, from: left, to: right)
                        if isWeak(topSide), isWeak(bottomSide) { continue }
                        let leftSide: Side? = leftOnBoundary ? nil : side(vertical: true, at: left, from: top, to: bottom)
                        if [topSide, bottomSide, leftSide].filter({ isWeak($0) }).count >= 2 { continue }
                        let rightSide: Side? = rightOnBoundary ? nil : side(vertical: true, at: right, from: top, to: bottom)
                        let sides = [leftSide, rightSide, topSide, bottomSide]
                        let drawn = sides.compactMap { $0 }
                        // One drawn line across an area is as likely a horizon or a table edge as a panel border.
                        guard drawn.count >= 2 else { continue }
                        // With only half of its outline drawn, that half has to be near-perfect.
                        let weak = sides.indices.filter { isWeak(sides[$0], needing: drawn.count == 2 ? 0.9 : 0.7) }
                        if weak.isEmpty {
                            let mean = drawn.reduce(0) { $0 + $1.support } / Double(drawn.count)
                            // Rank by how cleanly the outline is drawn: a true border is nearly complete and stands
                            // clear of its surroundings, where a chance rectangle is patchy on at least one side.
                            let clarity = drawn.reduce(0) { $0 + $1.standout } / Double(drawn.count)
                            let weakest = drawn.map(\.support).min() ?? 0
                            if mean >= 0.86 { found.append((candidate, mean + clarity * 0.5 + weakest * 0.5 + Double(drawn.count) * 0.02)) }
                        } else if weak.count == 1, drawn.count >= 3 {
                            let others = sides.indices.filter { $0 != weak[0] }.compactMap { sides[$0]?.support }
                            let othersMean = others.reduce(0, +) / Double(others.count)
                            if othersMean >= 0.88 { tucked.append((candidate, othersMean, weak[0])) }
                        }
                    }
                }
            }
        }
        // Panels don't partly overlap. Going from the best-supported candidate down, drop any that cuts
        // across one already kept — which also removes the repeats of a frame found on the inner and
        // outer edge of its border. (One wholly inside another is dealt with below.)
        var kept: [Region] = []
        for candidate in found.sorted(by: { ($0.score, $0.region.area) > ($1.score, $1.region.area) }).map(\.region) {
            let clashes = kept.contains { other in
                let shared = candidate.intersectionArea(other), smaller = min(candidate.area, other.area)
                guard shared * 100 > smaller * 10 else { return false }
                // Cutting across a better frame, repeating it, or being mostly made of it (two neighbours
                // read as one big frame) all lose. A frame with a much smaller one inside is fine.
                return shared * 100 < smaller * 90 || shared * 100 > max(candidate.area, other.area) * 35
            }
            if !clashes { kept.append(candidate) }
            if kept.count > 60 { break }
        }
        // Two neighbouring frames also look like one big frame around both: drop those unions.
        kept = kept.filter { candidate in
            let inside = kept.filter { $0 != candidate && $0.area < candidate.area && $0.intersectionArea(candidate) * 100 >= $0.area * 90 }
            return !(inside.count >= 2 && inside.reduce(0) { $0 + $1.area } * 100 >= candidate.area * 70)
        }
        // And a small frame sitting inside another is a detail of it (a screen, a window, a caption box), not a panel.
        kept = kept.filter { candidate in
            !kept.contains { $0 != candidate && $0.area > candidate.area * 8 && $0.intersectionArea(candidate) * 100 >= candidate.area * 85 }
        }
        // Panels are often laid partly over one another. A candidate missing one side is accepted when the
        // missing stretch is exactly where a panel found above covers it, and what does show is drawn.
        for candidate in tucked.sorted(by: { ($0.score, $0.region.area) > ($1.score, $1.region.area) }) where !kept.isEmpty && kept.count < 16 {
            let c = candidate.region
            let fits = kept.allSatisfy { other in
                let shared = c.intersectionArea(other)
                return shared * 100 <= c.area * 30 && shared * 100 <= other.area * 30
            }
            guard fits, let visible = visibleSupport(of: c, side: candidate.weakSide, behind: kept), visible >= 0.8 else { continue }
            kept.append(c)
        }
        guard !kept.isEmpty, kept.count <= 16 else { return [] }
        let covered = kept.reduce(0) { $0 + $1.area }
        guard covered * 100 >= r.area * 8 else { return [] }
        let ordered = inReadingOrder(kept)
        // Frames that tile the area are its panels.
        if covered * 100 >= r.area * 72 { return ordered.count >= 2 ? ordered : [] }
        // Frames floating on artwork come after a look at the whole — but only where the area is most of a
        // page. Inside one panel of a grid, stray rectangles are scenery (a doorway, a screen, a window).
        return r.area * 2 >= width * height ? [r] + ordered : []
    }

    /// Rows from the top; within a row, in the reading direction. A frame joins a row when its
    /// vertical middle falls inside the row's first frame.
    private func inReadingOrder(_ frames: [Region]) -> [Region] {
        var rows: [[Region]] = []
        for frame in frames.sorted(by: { ($0.y0, $0.x0) < ($1.y0, $1.x0) }) {
            let middle = (frame.y0 + frame.y1) / 2
            if let index = rows.firstIndex(where: { middle >= $0[0].y0 && middle < $0[0].y1 }) { rows[index].append(frame) } else { rows.append([frame]) }
        }
        return rows.flatMap { row in row.sorted { direction == .rightToLeft ? $0.x0 > $1.x0 : $0.x0 < $1.x0 } }
    }
}
