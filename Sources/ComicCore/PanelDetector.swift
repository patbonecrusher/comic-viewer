import CoreGraphics
import Foundation

/// Finds the panels on a comic page and puts them in reading order.
///
/// The method is a recursive "XY cut": gutters are bands of background colour that cross a region
/// from side to side. Cut a page along its horizontal gutters into strips, cut each strip along its
/// vertical gutters, and repeat until nothing more can be cut. The order the cuts are made in is the
/// reading order, so no separate sorting step is needed.
///
/// It needs clean, straight gutters. Pages it can't make sense of (full-bleed art, overlapping or
/// borderless panels) come back as one panel covering the whole page, which the reader shows as-is.
public enum PanelDetector {
    /// A panel's frame in unit coordinates (0…1, origin at the top left of the page).
    public typealias Panel = CGRect

    public static let wholePage = CGRect(x: 0, y: 0, width: 1, height: 1)

    public static func detect(in image: CGImage, direction: ReadingDirection = .leftToRight) -> [Panel] {
        guard let page = GrayPage(image: image, longSide: 900) else { return [wholePage] }
        for background in page.backgroundCandidates() {
            let panels = Cutter(page: page, background: background, direction: direction).panels()
            if panels.count >= 2 { return panels }
        }
        return [wholePage]
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
    private let minGutter: Int

    private struct Region { var x0: Int, y0: Int, x1: Int, y1: Int }   // half-open

    init(page: GrayPage, background: UInt8, direction: ReadingDirection) {
        width = page.width; height = page.height; self.direction = direction
        minGutter = max(3, max(width, height) * 45 / 10_000)
        let tolerance = 28, stride = width + 1
        var table = [Int32](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var rowSum: Int32 = 0
            for x in 0..<width {
                if abs(Int(page.pixels[y * width + x]) - Int(background)) > tolerance { rowSum += 1 }
                table[(y + 1) * stride + x + 1] = table[y * stride + x + 1] + rowSum
            }
        }
        self.table = table
    }

    private func ink(_ r: Region) -> Int {
        let s = width + 1
        return Int(table[r.y1 * s + r.x1] - table[r.y0 * s + r.x1] - table[r.y1 * s + r.x0] + table[r.y0 * s + r.x0])
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
        let inkPerLine = (lower..<upper).map { line in
            ink(rows ? Region(x0: r.x0, y0: line, x1: r.x1, y1: line + 1) : Region(x0: line, y0: r.y0, x1: line + 1, y1: r.y1))
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

    func panels() -> [CGRect] {
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
        return kept.map { r in
            CGRect(x: Double(r.x0) / Double(width), y: Double(r.y0) / Double(height),
                   width: Double(r.x1 - r.x0) / Double(width), height: Double(r.y1 - r.y0) / Double(height))
        }
    }
}
