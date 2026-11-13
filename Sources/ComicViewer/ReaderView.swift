import ComicCore
import SwiftUI

struct ReaderView: View {
    @Bindable var model: ReaderModel
    @AppStorage(Prefs.showStatusBar) private var showStatusBar = true
    @AppStorage(Prefs.showThumbnails) private var showThumbnails = false
    @AppStorage(Prefs.background) private var background = ReaderBackground.dark.rawValue

    var body: some View {
        HStack(spacing: 0) {
            if showThumbnails {
                ThumbnailStrip(model: model)
                    .frame(width: 150)
                Divider()
            }
            VStack(spacing: 0) {
                ZStack {
                    ReaderCanvas(model: model, display: model.display, fit: model.fit,
                                 startAtRightEdge: model.direction == .rightToLeft,
                                 background: (ReaderBackground(rawValue: background) ?? .dark).color)
                    if let error = model.pageError {
                        ContentUnavailableView("Can’t Show This Page", systemImage: "exclamationmark.triangle", description: Text(error))
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding(40)
                    }
                }
                if showStatusBar {
                    Divider()
                    statusBar
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .navigationTitle(model.book.title)
        .toolbar { toolbar }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(model.positionLabel)
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 150, alignment: .leading)
            if model.spreads.count > 1 {
                Slider(value: Binding(get: { Double(model.spreadIndex) }, set: { model.goToSpread(Int($0.rounded())) }),
                       in: 0...Double(model.spreads.count - 1))
                    .controlSize(.small)
                    // The scrubber runs the way the book reads.
                    .environment(\.layoutDirection, model.direction == .rightToLeft ? .rightToLeft : .leftToRight)
                    .accessibilityLabel("Page")
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { showThumbnails.toggle() } label: { Label("Thumbnails", systemImage: "sidebar.left") }
                .help("Show or hide page thumbnails")
        }
        ToolbarItem {
            ControlGroup {
                Button { model.turn(visual: -1) } label: { Label("Turn Left", systemImage: "chevron.left") }
                    .disabled(model.direction == .leftToRight ? !model.canGoBack : !model.canGoForward)
                Button { model.turn(visual: 1) } label: { Label("Turn Right", systemImage: "chevron.right") }
                    .disabled(model.direction == .leftToRight ? !model.canGoForward : !model.canGoBack)
            }
        }
        ToolbarItem {
            Picker("Layout", selection: $model.layout) {
                ForEach(PageLayout.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Single or double page")
        }
        ToolbarItem {
            Menu {
                Picker("Zoom", selection: Binding(get: { model.fit }, set: { model.setFit($0) })) {
                    ForEach(FitMode.selectable, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Picker("Reading Direction", selection: $model.direction) {
                    ForEach(ReadingDirection.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("View Options", systemImage: "textformat.size")
            }
            .help("Zoom and reading direction")
        }
    }
}

private struct ThumbnailStrip: View {
    let model: ReaderModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(0..<model.book.pageCount, id: \.self) { page in
                        ThumbnailCell(model: model, page: page, isCurrent: model.currentPages.contains(page))
                            .id(page)
                            .onTapGesture { model.goToPage(page) }
                    }
                }
                .padding(.vertical, 10)
            }
            .background(.background.secondary)
            .onChange(of: model.currentPage) { _, page in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(page, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(model.currentPage, anchor: .center) }
        }
    }
}

private struct ThumbnailCell: View {
    let model: ReaderModel
    let page: Int
    let isCurrent: Bool
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let image {
                    Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary).aspectRatio(2 / 3, contentMode: .fit)
                }
            }
            .frame(maxWidth: 110, maxHeight: 165)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 3))
            Text("\(page + 1)")
                .font(.caption).monospacedDigit()
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .accessibilityLabel("Page \(page + 1)")
        .task { if image == nil { image = await model.thumbnail(for: page) } }
    }
}
