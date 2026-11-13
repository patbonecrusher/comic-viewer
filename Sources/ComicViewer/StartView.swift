import SwiftUI

/// The hub window. For now it lists recently read comics; the library will live here.
struct StartView: View {
    @State private var recents = Recents.all
    @State private var isDropTarget = false

    var body: some View {
        Group {
            if recents.isEmpty {
                ContentUnavailableView {
                    Label("No Comics Yet", systemImage: "books.vertical")
                } description: {
                    Text("Open a CBZ, CBR or PDF, or a folder of images — or drop one here.")
                } actions: {
                    Button("Open…") { ReaderWindows.shared.showOpenPanel() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    Section("Continue Reading") {
                        ForEach(recents) { recent in
                            Button { ReaderWindows.shared.open(recent) } label: { RecentRow(recent: recent) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Show in Finder") {
                                        if let url = recent.resolve() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    }
                                    Button("Remove from Recents") { Recents.remove(recent) }
                                }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 3).padding(6)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls { ReaderWindows.shared.open(url) }
            return !urls.isEmpty
        } isTargeted: { isDropTarget = $0 }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { ReaderWindows.shared.showOpenPanel() } label: { Label("Open…", systemImage: "folder") }
                    .help("Open a comic")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recentsChanged)) { _ in recents = Recents.all }
    }
}

private struct RecentRow: View {
    let recent: RecentComic

    private var progress: Double {
        recent.pageCount > 1 ? Double(recent.page) / Double(recent.pageCount - 1) : 1
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "book.closed")
                .font(.title2).foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(recent.title).lineLimit(1)
                Text("Page \(recent.page + 1) of \(recent.pageCount)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView(value: progress)
                .frame(width: 90)
                .accessibilityLabel("Reading progress")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
