import SwiftUI
import UIKit

/// Where on the screen a tap landed.
enum TapZone { case left, middle, right }

/// Shows the pages and zooms to the panel in focus. Wraps `CanvasView`.
struct PageCanvas: UIViewRepresentable {
    let display: SpreadDisplay?
    let focus: PanelFocus?
    /// Fill the width and scroll down a page when the device is sideways, instead of shrinking it to fit.
    let fitWidthInLandscape: Bool
    /// Tapping the left side moves forward (right-to-left books).
    let forwardIsLeft: Bool
    let onForward: () -> Void
    let onBackward: () -> Void
    let onMiddleTap: () -> Void

    func makeUIView(context: Context) -> CanvasView { CanvasView() }

    func updateUIView(_ view: CanvasView, context: Context) {
        view.fitWidthInLandscape = fitWidthInLandscape
        view.forwardIsLeft = forwardIsLeft
        view.onForward = onForward
        view.onBackward = onBackward
        view.onMiddleTap = onMiddleTap
        view.show(display: display, focus: focus)
    }
}

/// A zooming page view. At rest it shows the whole page (or, sideways, the page's full width); with
/// a panel in focus it zooms to that panel and dims the rest. Everything is laid out again when the
/// view changes size, which is what turning the device does.
final class CanvasView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var fitWidthInLandscape = true { didSet { if oldValue != fitWidthInLandscape { layoutPages(animated: false) } } }
    var forwardIsLeft = false
    var onForward: () -> Void = {}
    var onBackward: () -> Void = {}
    var onMiddleTap: () -> Void = {}

    private let content = UIView()
    private var imageViews: [UIImageView] = []
    private let dim = CAShapeLayer()
    private var display: SpreadDisplay?
    private var focus: PanelFocus?
    private var laidOutSize = CGSize.zero
    /// The reader pinched in while a panel was in focus and is looking around; cleared at the next step.
    private var lookingAround = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        bouncesZoom = true
        decelerationRate = .fast
        addSubview(content)
        dim.fillRule = .evenOdd
        dim.fillColor = UIColor.black.withAlphaComponent(0.6).cgColor
        dim.zPosition = 1

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(tap)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            swipe.delegate = self
            addGestureRecognizer(swipe)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Content

    func show(display newDisplay: SpreadDisplay?, focus newFocus: PanelFocus?) {
        let pagesChanged = newDisplay?.id != display?.id
        let focusChanged = newFocus != focus
        guard pagesChanged || focusChanged else { return }
        display = newDisplay
        focus = newFocus
        if pagesChanged {
            imageViews.forEach { $0.removeFromSuperview() }
            imageViews = (newDisplay?.images ?? []).map { image in
                let view = UIImageView(image: UIImage(cgImage: image))
                view.contentMode = .scaleToFill
                view.layer.minificationFilter = .trilinear
                content.addSubview(view)
                return view
            }
            content.layer.addSublayer(dim)
            layoutPages(animated: false)
        } else {
            applyFocus(animated: true)
        }
    }

    /// Pixel size of the pages side by side at a common height.
    private var spreadSize: CGSize {
        guard let images = display?.images, let tallest = images.map(\.height).max(), tallest > 0 else { return .zero }
        let width = images.reduce(CGFloat(0)) { $0 + CGFloat($1.width) * CGFloat(tallest) / CGFloat($1.height) }
        return CGSize(width: width, height: CGFloat(tallest))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != laidOutSize { layoutPages(animated: false) } else { centreContent() }
    }

    /// Sizes the pages for the view as it is now and goes back to the panel in focus.
    private func layoutPages(animated: Bool) {
        laidOutSize = bounds.size
        lookingAround = false
        let spread = spreadSize
        guard spread.width > 0, bounds.width > 0, bounds.height > 0 else { return }
        let fitPage = min(bounds.width / spread.width, bounds.height / spread.height)
        var scale = fitPage
        // Sideways, a page shrunk to fit is too small to read: fill the width and scroll down it.
        let sideways = bounds.width > bounds.height
        if fitWidthInLandscape, sideways, focus == nil, spread.height / spread.width > bounds.height / bounds.width {
            scale = bounds.width / spread.width
        }
        minimumZoomScale = 1
        maximumZoomScale = 1
        zoomScale = 1
        let size = CGSize(width: spread.width * scale, height: spread.height * scale)
        content.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        var x: CGFloat = 0
        for (view, image) in zip(imageViews, display?.images ?? []) {
            let width = size.height * CGFloat(image.width) / CGFloat(image.height)
            view.frame = CGRect(x: x, y: 0, width: width, height: size.height)
            x += width
        }
        dim.frame = content.bounds
        // Pinching out goes back as far as the whole page.
        minimumZoomScale = min(1, fitPage / scale)
        maximumZoomScale = 16
        contentOffset = .zero
        applyFocus(animated: animated)
    }

    private func applyFocus(animated: Bool) {
        let size = content.bounds.size
        guard size.width > 0, bounds.width > 0 else { return }
        guard let rect = focus?.rect else {
            // Free reading: scrolling and pinching are the reader's.
            isScrollEnabled = true
            lookingAround = false
            setDim(nil)
            let change = { self.zoomScale = 1; self.centreContent(); self.contentOffset = CGPoint(x: -self.contentInset.left, y: -self.contentInset.top) }
            if animated { UIView.animate(withDuration: 0.3, animations: change) } else { change() }
            return
        }
        // Panel in focus: zoom so it fills the view, centred, with room to centre panels at the page's edge.
        isScrollEnabled = false
        lookingAround = false
        var panel = CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
        setDim(panel)
        let margin = min(size.width, size.height) * 0.012
        panel = panel.insetBy(dx: -margin, dy: -margin)
        let zoom = min(maximumZoomScale, max(minimumZoomScale, min(bounds.width / panel.width, bounds.height / panel.height)))
        let change = {
            self.contentInset = UIEdgeInsets(top: self.bounds.height, left: self.bounds.width, bottom: self.bounds.height, right: self.bounds.width)
            self.zoomScale = zoom
            self.contentOffset = CGPoint(x: panel.midX * zoom - self.bounds.width / 2, y: panel.midY * zoom - self.bounds.height / 2)
        }
        if animated { UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState], animations: change) } else { change() }
    }

    /// Darkens everything on the page except the panel being read.
    private func setDim(_ panel: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let panel {
            let path = UIBezierPath(rect: content.bounds.insetBy(dx: -4000, dy: -4000))
            path.append(UIBezierPath(rect: panel))
            dim.path = path.cgPath
            dim.isHidden = false
        } else {
            dim.isHidden = true
        }
        CATransaction.commit()
    }

    /// Keeps pages smaller than the view in its middle.
    private func centreContent() {
        guard focus == nil else { return }
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset { contentInset = inset }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centreContent() }

    /// Pinching while a panel is in focus lets the reader move around the page until the next step.
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        guard focus != nil, let pinch = pinchGestureRecognizer, pinch.state == .began || pinch.state == .changed else { return }
        lookingAround = true
        isScrollEnabled = true
    }

    /// Zoomed in by hand: dragging moves around the page, so it must not also turn it.
    private var zoomedByHand: Bool { focus == nil ? zoomScale > 1.01 : lookingAround }

    // MARK: Taps and swipes

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        let x = tap.location(in: self).x - bounds.minX
        if x < bounds.width * 0.3 { step(forward: forwardIsLeft) }
        else if x > bounds.width * 0.7 { step(forward: !forwardIsLeft) }
        else { onMiddleTap() }
    }

    @objc private func swiped(_ swipe: UISwipeGestureRecognizer) {
        // A swipe turns the page unless the reader has zoomed in and is moving around the page.
        guard !zoomedByHand, focus != nil || contentSize.width <= bounds.width + 1 else { return }
        let forward = (swipe.direction == .left) != forwardIsLeft
        if forward { onForward() } else { onBackward() }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// Moves on: down the page while there is more of it below, then to the next panel or page.
    private func step(forward: Bool) {
        if focus == nil, contentSize.height > bounds.height + 1 {
            let top = -contentInset.top, bottom = contentSize.height - bounds.height + contentInset.bottom
            let target = contentOffset.y + (forward ? 1 : -1) * bounds.height * 0.85
            if forward, contentOffset.y < bottom - 2 {
                return setContentOffset(CGPoint(x: contentOffset.x, y: min(bottom, target)), animated: true)
            }
            if !forward, contentOffset.y > top + 2 {
                return setContentOffset(CGPoint(x: contentOffset.x, y: max(top, target)), animated: true)
            }
        }
        if forward { onForward() } else { onBackward() }
    }
}
