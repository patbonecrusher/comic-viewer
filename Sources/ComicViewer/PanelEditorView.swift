import AppKit

/// Drawn over the page while editing panels. Drag empty space to add a panel, drag a panel to move
/// it, drag a handle to resize it. Panels are unit rectangles (0…1, origin top left) of the spread.
final class PanelEditorView: NSView {
    var panels: [CGRect] = [] { didSet { if panels != oldValue { needsDisplay = true } } }
    var selection: Int? { didSet { if selection != oldValue { needsDisplay = true } } }
    /// Reports every change: the new panels and which one is selected.
    var onChange: (([CGRect], Int?) -> Void)?

    private enum Drag {
        case move(index: Int, grab: CGPoint)                 // grab = pointer offset from the panel's origin
        case resize(index: Int, anchor: CGPoint)             // the corner or edge that stays put
        case create(index: Int, origin: CGPoint)
    }
    private var drag: Drag?
    private var resizeAxes = (x: true, y: true)
    private static let minimumSize: CGFloat = 0.02

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Screen points per view unit: drawing is counter-scaled so lines and handles stay the same size at any zoom.
    private var zoom: CGFloat { max(0.01, enclosingScrollView?.magnification ?? 1) }

    private func frame(of panel: CGRect) -> CGRect {
        CGRect(x: panel.minX * bounds.width, y: panel.minY * bounds.height, width: panel.width * bounds.width, height: panel.height * bounds.height)
    }

    private func unitPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(x: min(1, max(0, point.x / bounds.width)), y: min(1, max(0, point.y / bounds.height)))
    }

    /// The eight resize handles of a panel, each with the point that stays fixed and the axes it changes.
    private func handles(of panel: CGRect) -> [(point: CGPoint, anchor: CGPoint, x: Bool, y: Bool)] {
        let xs = [panel.minX, panel.midX, panel.maxX], ys = [panel.minY, panel.midY, panel.maxY]
        var result: [(CGPoint, CGPoint, Bool, Bool)] = []
        for (i, x) in xs.enumerated() {
            for (j, y) in ys.enumerated() where !(i == 1 && j == 1) {
                result.append((CGPoint(x: x, y: y), CGPoint(x: xs[2 - i], y: ys[2 - j]), i != 1, j != 1))
            }
        }
        return result
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let scale = 1 / zoom
        let accent = NSColor.controlAccentColor
        for (index, panel) in panels.enumerated() {
            let rect = frame(of: panel), isSelected = index == selection
            accent.withAlphaComponent(isSelected ? 0.28 : 0.12).setFill()
            rect.fill()
            let outline = NSBezierPath(rect: rect.insetBy(dx: scale, dy: scale))
            outline.lineWidth = (isSelected ? 3 : 2) * scale
            (isSelected ? accent : accent.withAlphaComponent(0.85)).setStroke()
            outline.stroke()

            // Reading-order number.
            let diameter = 26 * scale
            let badge = CGRect(x: rect.minX + 6 * scale, y: rect.minY + 6 * scale, width: diameter, height: diameter)
            accent.setFill()
            NSBezierPath(ovalIn: badge).fill()
            let label = NSAttributedString(string: "\(index + 1)", attributes: [
                .font: NSFont.systemFont(ofSize: 14 * scale, weight: .bold), .foregroundColor: NSColor.white])
            let size = label.size()
            label.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
        }
        if let selection, panels.indices.contains(selection) {
            let side = 9 * scale
            for handle in handles(of: panels[selection]) {
                let center = CGPoint(x: handle.point.x * bounds.width, y: handle.point.y * bounds.height)
                let square = NSBezierPath(rect: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side))
                NSColor.white.setFill(); square.fill()
                square.lineWidth = 1.5 * scale
                accent.setStroke(); square.stroke()
            }
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = unitPoint(event)
        let reach = 8 / zoom        // how close, in view points, counts as "on the handle"
        if let selection, panels.indices.contains(selection) {
            for handle in handles(of: panels[selection]) {
                let dx = (handle.point.x - point.x) * bounds.width, dy = (handle.point.y - point.y) * bounds.height
                if abs(dx) <= reach, abs(dy) <= reach {
                    resizeAxes = (handle.x, handle.y)
                    drag = .resize(index: selection, anchor: handle.anchor)
                    return
                }
            }
        }
        // The smallest panel under the pointer, so a panel inside another can still be picked.
        // A whole-page "overview" panel would swallow every click; it is picked from the list instead,
        // leaving the page free for drawing panels on.
        let hit = panels.indices.filter { panels[$0].contains(point) && panels[$0].width * panels[$0].height < 0.9 }.min { panels[$0].width * panels[$0].height < panels[$1].width * panels[$1].height }
        if let hit {
            drag = .move(index: hit, grab: CGPoint(x: point.x - panels[hit].minX, y: point.y - panels[hit].minY))
            if selection != hit { selection = hit; onChange?(panels, hit) }
        } else {
            panels.append(CGRect(origin: point, size: .zero))
            selection = panels.count - 1
            resizeAxes = (true, true)
            drag = .create(index: panels.count - 1, origin: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = unitPoint(event)
        switch drag {
        case .move(let index, let grab):
            let size = panels[index].size
            panels[index].origin = CGPoint(x: min(1 - size.width, max(0, point.x - grab.x)), y: min(1 - size.height, max(0, point.y - grab.y)))
        case .resize(let index, let anchor), .create(let index, let anchor):
            var rect = panels[index]
            if resizeAxes.x { rect.origin.x = min(anchor.x, point.x); rect.size.width = abs(point.x - anchor.x) }
            if resizeAxes.y { rect.origin.y = min(anchor.y, point.y); rect.size.height = abs(point.y - anchor.y) }
            panels[index] = rect
        case nil:
            return
        }
        onChange?(panels, selection)
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        switch drag {
        case .create(let index, _), .resize(let index, _):
            // A click on empty space (or a panel squashed to nothing) isn't a panel.
            if panels[index].width < Self.minimumSize || panels[index].height < Self.minimumSize {
                panels.remove(at: index)
                selection = nil
            }
            onChange?(panels, selection)
        case .move:
            onChange?(panels, selection)
        case nil:
            break
        }
    }
}
