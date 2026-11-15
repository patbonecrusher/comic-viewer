import ComicCore
import SwiftUI

/// The reader: the page fills the screen, and a tap in the middle shows or hides the controls.
struct ReaderScreen: View {
    @State var state: ReaderState
    @Environment(\.dismiss) private var dismiss
    @State private var showControls = true
    @State private var scrub: Double?
    @AppStorage(MobilePrefs.twoPagesInLandscape) private var twoPagesInLandscape = UIDevice.current.userInterfaceIdiom == .pad
    @AppStorage(MobilePrefs.fitWidthInLandscape) private var fitWidthInLandscape = true
    @AppStorage(MobilePrefs.pageBeforePanels) private var pageBeforePanels = false
    @AppStorage(MobilePrefs.pageAfterPanels) private var pageAfterPanels = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                PageCanvas(display: state.display, focus: state.focus, fitWidthInLandscape: fitWidthInLandscape,
                           forwardIsLeft: state.direction == .rightToLeft,
                           onForward: { hideControls(); state.next() }, onBackward: { hideControls(); state.previous() },
                           onMiddleTap: { withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() } })
                if let error = state.pageError {
                    ContentUnavailableView("Can’t Show This Page", systemImage: "exclamationmark.triangle", description: Text(error))
                        .foregroundStyle(.white)
                } else if state.display == nil {
                    ProgressView().tint(.white)
                }
            }
            .overlay(alignment: .top) { if showControls { topBar.transition(.move(edge: .top).combined(with: .opacity)) } }
            .overlay(alignment: .bottom) { if showControls { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) } }
            // Turning the device sideways makes room for two facing pages.
            .onChange(of: geometry.size.width > geometry.size.height, initial: true) { _, sideways in
                state.setTwoUp(sideways && twoPagesInLandscape)
            }
            .onChange(of: twoPagesInLandscape) { _, wanted in
                state.setTwoUp(wanted && geometry.size.width > geometry.size.height)
            }
        }
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(showControls ? .automatic : .hidden)
        .preferredColorScheme(.dark)
        .onChange(of: pageBeforePanels) { state.readingOptionsChanged() }
        .onChange(of: pageAfterPanels) { state.readingOptionsChanged() }
        .onDisappear { state.saveProgress() }
    }

    /// Turning a page puts the controls away; they cover the top and bottom of the page.
    private func hideControls() {
        if showControls { withAnimation(.easeInOut(duration: 0.2)) { showControls = false } }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title3.weight(.semibold)) }
                .accessibilityLabel("Close")
            Text(state.title).font(.headline).lineLimit(1)
            Spacer(minLength: 8)
            Button { state.panelMode.toggle() } label: {
                Image(systemName: state.panelMode ? "rectangle.split.2x2.fill" : "rectangle.split.2x2").font(.title3)
            }
            .accessibilityLabel("Panel by Panel")
            .accessibilityValue(state.panelMode ? "On" : "Off")
            Menu {
                Toggle("Panel by Panel", isOn: $state.panelMode)
                Picker("Reading Direction", selection: $state.direction) {
                    Text("Left to Right").tag(ReadingDirection.leftToRight)
                    Text("Right to Left (Manga)").tag(ReadingDirection.rightToLeft)
                }
                Section("When Held Sideways") {
                    Toggle("Two Pages Side by Side", isOn: $twoPagesInLandscape)
                    Toggle("Fill the Width", isOn: $fitWidthInLandscape)
                }
                Section("Reading Panel by Panel") {
                    Toggle("Whole Page Before Its Panels", isOn: $pageBeforePanels)
                    Toggle("Whole Page After Its Panels", isOn: $pageAfterPanels)
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .accessibilityLabel("Reading Options")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.95), ignoresSafeAreaEdges: [.top, .horizontal])
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            if state.spreads.count > 1 {
                Slider(value: Binding(get: { scrub ?? Double(state.spreadIndex) }, set: { scrub = $0 }),
                       in: 0...Double(state.spreads.count - 1), step: 1) { editing in
                    if !editing, let target = scrub { state.goToSpread(Int(target)); scrub = nil }
                }
                .environment(\.layoutDirection, state.direction == .rightToLeft ? .rightToLeft : .leftToRight)
                .accessibilityLabel("Page")
            }
            Text(label).font(.footnote.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)
        .background(.ultraThinMaterial.opacity(0.95), ignoresSafeAreaEdges: [.bottom, .horizontal])
    }

    /// While the slider is dragged the label follows the thumb.
    private var label: String {
        guard let scrub, state.spreads.indices.contains(Int(scrub)) else { return state.positionLabel }
        let pages = state.spreads[Int(scrub)].pages
        return pages.count > 1 ? "Pages \(pages[0] + 1)–\(pages[pages.count - 1] + 1) of \(state.book.pageCount)"
                               : "Page \(pages[0] + 1) of \(state.book.pageCount)"
    }
}
