import AppKit
import SwiftUI

/// The page area: an AppKit scroll view, because it gives precise zoom, pan and animated
/// "magnify to rect" — which panel-by-panel reading will build on.
struct ReaderCanvas: NSViewRepresentable {
    let model: ReaderModel
    // Passed as plain values so SwiftUI re-runs updateNSView when they change.
    let display: SpreadDisplay?
    let fit: FitMode
    let startAtRightEdge: Bool
    let background: NSColor

    func makeNSView(context: Context) -> ReaderScrollView {
        let view = ReaderScrollView()
        view.onTurn = { [weak model] in model?.turn(visual: $0) }
        view.onStep = { [weak model] forward in forward ? model?.next() : model?.previous() }
        view.onJump = { [weak model] toEnd in toEnd ? model?.last() : model?.first() }
        view.onFitChanged = { [weak model] in model?.setFit($0) }
        model.canvas = view
        return view
    }

    func updateNSView(_ view: ReaderScrollView, context: Context) {
        view.backgroundColor = background
        view.startAtRightEdge = startAtRightEdge
        if view.fit != fit {
            view.fit = fit
            view.applyFit()
        }
        if view.shownID != display?.id { view.show(display) }
    }
}

final class ReaderScrollView: NSScrollView {
    let spreadView = SpreadView()
    var fit: FitMode = .page
    var startAtRightEdge = false
    private(set) var shownID: Int?

    var onTurn: ((Int) -> Void)?            // -1 = toward the left edge, +1 = toward the right
    var onStep: ((Bool) -> Void)?           // true = forward in reading order
    var onJump: ((Bool) -> Void)?           // true = last page
    var onFitChanged: ((FitMode) -> Void)?

    private var lastFittedSize = NSSize.zero
    private var swipeDistance: CGFloat = 0
    private var swipeConsumed = false
    private var mouseDownPoint: NSPoint?
    private var dragged = false
    private var keyMonitor: Any?

    init() {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        documentView = spreadView
        drawsBackground = true
        allowsMagnification = true
        minMagnification = 0.02
        maxMagnification = 16
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        usesPredominantAxisScrolling = false
        NotificationCenter.default.addObserver(self, selector: #selector(userMagnified), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollerStyleChanged), name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard window != nil else { return }
        // Reading keys work wherever focus is in the window (toolbar, thumbnails…), except while typing.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window, !(window.firstResponder is NSText) else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    @objc private func scrollerStyleChanged() { scrollerStyle = .overlay }

    // MARK: Content

    func show(_ display: SpreadDisplay?) {
        shownID = display?.id
        spreadView.show(display?.images ?? [], backingScale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        if fit == .custom { scrollToStart() } else { applyFit() }
    }

    override func layout() {
        super.layout()
        if bounds.size != lastFittedSize {
            lastFittedSize = bounds.size
            if fit != .custom { applyFit(resetScroll: false) }
        }
    }

    func applyFit(resetScroll: Bool = true) {
        let content = spreadView.frame.size, viewport = bounds.size
        guard content.width > 0, content.height > 0, viewport.width > 0, viewport.height > 0 else { return }
        let scale: CGFloat
        switch fit {
        case .page: scale = min(viewport.width / content.width, viewport.height / content.height)
        case .width: scale = viewport.width / content.width
        case .height: scale = viewport.height / content.height
        case .actual: scale = 1
        case .custom: return
        }
        magnification = max(minMagnification, min(maxMagnification, scale))
        if resetScroll { scrollToStart() }
    }

    /// Top of the page, at the edge reading starts from.
    private func scrollToStart() {
        let visible = contentView.bounds.size
        let x = startAtRightEdge ? max(0, spreadView.frame.width - visible.width) : 0
        scrollContent(to: NSPoint(x: x, y: 0))
    }

    /// Scrolls, keeping within the page and centring it on any axis where it is smaller than the window.
    private func scrollContent(to origin: NSPoint) {
        let constrained = contentView.constrainBoundsRect(NSRect(origin: origin, size: contentView.bounds.size))
        contentView.scroll(to: constrained.origin)
        reflectScrolledClipView(contentView)
    }

    func zoom(by factor: CGFloat) {
        let target = max(minMagnification, min(maxMagnification, magnification * factor))
        setMagnification(target, centeredAt: NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY))
        fit = .custom
        onFitChanged?(.custom)
    }

    @objc private func userMagnified() {
        fit = .custom
        onFitChanged?(.custom)
    }

    override func smartMagnify(with event: NSEvent) {
        let mode: FitMode = fit == .width ? .page : .width
        fit = mode
        applyFit()
        onFitChanged?(mode)
    }

    // MARK: Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 123: onTurn?(-1)                                               // ←
        case 124: onTurn?(1)                                                // →
        case 125: scrollVertically(by: 80)                                  // ↓
        case 126: scrollVertically(by: -80)                                 // ↑
        case 49: pageOrStep(forward: !event.modifierFlags.contains(.shift)) // space
        case 121: pageOrStep(forward: true)                                 // page down
        case 116: pageOrStep(forward: false)                                // page up
        case 115: onJump?(false)                                            // home
        case 119: onJump?(true)                                             // end
        default: return false
        }
        return true
    }

    private func scrollVertically(by points: CGFloat) {
        let visible = contentView.bounds
        scrollContent(to: NSPoint(x: visible.origin.x, y: visible.origin.y + points / magnification))
    }

    /// Space bar reading: scroll down through a zoomed page, then on to the next one.
    private func pageOrStep(forward: Bool) {
        let visible = contentView.bounds
        let maxY = spreadView.frame.height - visible.height
        if forward, visible.origin.y < maxY - 1 {
            scrollVertically(by: visible.height * 0.9 * magnification)
        } else if !forward, maxY > 1, visible.origin.y > 1 {
            scrollVertically(by: -visible.height * 0.9 * magnification)
        } else {
            onStep?(forward)
        }
    }

    // MARK: Trackpad swipe

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began {
            swipeDistance = 0
            swipeConsumed = false
        }
        let canScrollSideways = spreadView.frame.width > contentView.bounds.width + 1
        if !canScrollSideways, !event.phase.isEmpty, event.momentumPhase.isEmpty, !swipeConsumed,
           abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            swipeDistance += event.scrollingDeltaX
            if abs(swipeDistance) > 50 {
                swipeConsumed = true
                // Fingers moving left drag the next (right-hand) page in.
                onTurn?(swipeDistance < 0 ? 1 : -1)
            }
            return
        }
        if swipeConsumed { return }      // swallow the rest of the gesture, including its momentum
        super.scrollWheel(with: event)
    }

    // MARK: Mouse — click the left or right third to turn, drag to pan

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        if !dragged, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) < 4 { return }
        dragged = true
        let origin = contentView.bounds.origin
        scrollContent(to: NSPoint(x: origin.x - event.deltaX / magnification, y: origin.y - event.deltaY / magnification))
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard mouseDownPoint != nil, !dragged else { return }
        let x = convert(event.locationInWindow, from: nil).x / max(1, bounds.width)
        if x < 0.3 { onTurn?(-1) } else if x > 0.7 { onTurn?(1) }
    }
}

/// Keeps the page centred when it is smaller than the window.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

/// Draws the one or two pages of a spread side by side, at one image pixel per screen pixel when unmagnified.
final class SpreadView: NSView {
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ images: [CGImage], backingScale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard !images.isEmpty else { return setFrameSize(.zero) }
        // Facing pages share the taller page's height.
        let height = CGFloat(images.map(\.height).max() ?? 1) / backingScale
        var x: CGFloat = 0
        for image in images {
            let width = (CGFloat(image.width) * height / CGFloat(image.height)).rounded()
            let page = CALayer()
            page.contents = image
            page.contentsGravity = .resize
            page.minificationFilter = .trilinear
            page.magnificationFilter = .linear
            page.frame = CGRect(x: x, y: 0, width: width, height: height)
            layer?.addSublayer(page)
            x += width
        }
        setFrameSize(NSSize(width: x, height: height))
    }

    // Clicks and drags are handled by the scroll view whether they land on the page or beside it.
    override func mouseDown(with event: NSEvent) { enclosingScrollView?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { enclosingScrollView?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { enclosingScrollView?.mouseUp(with: event) }
}
