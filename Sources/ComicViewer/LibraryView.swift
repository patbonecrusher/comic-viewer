import ComicCore
import SwiftUI

enum LibrarySection: Hashable {
    case all, reading, unread, finished
    case series(String)
    case folder(Int64)
}

enum LibrarySort: String, CaseIterable {
    case series, title, added, recent

    var title: String {
        switch self {
        case .series: return "Series"
        case .title: return "Title"
        case .added: return "Date Added"
        case .recent: return "Recently Read"
        }
    }
}

struct LibraryView: View {
    private var library: Library { .shared }
    @State private var section: LibrarySection? = .all
    @State private var search = ""
    @State private var selection: Set<Int64> = []
    /// Where a shift-click range starts.
    @State private var anchor: Int64?
    @State private var dropTarget: String?
    @FocusState private var gridFocused: Bool
    @State private var isDropTarget = false
    @AppStorage("librarySort") private var sort = LibrarySort.series.rawValue

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 320)
        } detail: {
            detail
        }
        .searchable(text: $search, prompt: "Search title, series, writer")
        .frame(minWidth: 640, minHeight: 400)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 3).padding(6)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter(\.hasDirectoryPath), files = urls.filter { !$0.hasDirectoryPath }
            if !folders.isEmpty { library.addFolders(folders) }
            for url in files { ReaderWindows.shared.open(url) }
            return !urls.isEmpty
        } isTargeted: { isDropTarget = $0 }
        .toolbar { toolbar }
    }

    // MARK: Sidebar

    private var seriesNames: [(name: String, count: Int)] {
        Dictionary(grouping: library.books.filter { !$0.series.isEmpty }, by: \.series)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    private var sidebar: some View {
        List(selection: $section) {
            Section("Library") {
                row("All Comics", "books.vertical", .all, library.books.count)
                row("Continue Reading", "bookmark", .reading, library.books.filter(\.isStarted).count)
                row("Unread", "circle", .unread, library.books.filter(\.isUnread).count)
                row("Finished", "checkmark.circle", .finished, library.books.filter(\.finished).count)
            }
            if !seriesNames.isEmpty {
                Section("Series") {
                    ForEach(seriesNames, id: \.name) { series in
                        row(series.name, "square.stack", .series(series.name), series.count)
                            .listRowBackground(dropTarget == series.name
                                ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.3)).padding(.horizontal, 10) : nil)
                            // Comics dragged from the grid join this series.
                            .dropDestination(for: String.self) { items, _ in
                                let ids = items.flatMap(Self.bookIDs(in:))
                                library.moveToSeries(series.name, ids: ids)
                                return !ids.isEmpty
                            } isTargeted: { over in
                                if over { dropTarget = series.name } else if dropTarget == series.name { dropTarget = nil }
                            }
                            .contextMenu { Button("Rename Series…") { renameSeries(series.name) } }
                    }
                }
            }
            Section("Folders") {
                ForEach(library.folders) { folder in
                    row(library.displayName(for: folder), library.isCloudFolder(folder) ? "icloud" : "folder",
                        .folder(folder.id ?? 0), library.books.filter { $0.folderID == folder.id }.count)
                        .help(library.isCloudFolder(folder) ? "Comic Viewer’s folder in iCloud Drive" : folder.path)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)]) }
                            // The iCloud folder belongs to the app and would only come back.
                            if !library.isCloudFolder(folder) {
                                Button("Remove from Library") {
                                    if section == .folder(folder.id ?? 0) { section = .all }
                                    library.removeFolder(folder)
                                }
                            }
                        }
                }
                Button { library.chooseFolders() } label: { Label("Add Folder…", systemImage: "plus") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let status = library.scanStatus {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.bar)
            }
        }
    }

    // Comics are dragged as their library ids: "comic-viewer-books:3,8,12".
    private static let dragPrefix = "comic-viewer-books:"
    private static func bookIDs(in payload: String) -> [Int64] {
        guard payload.hasPrefix(dragPrefix) else { return [] }
        return payload.dropFirst(dragPrefix.count).split(separator: ",").compactMap { Int64($0) }
    }
    /// Dragging one of several selected comics takes all of them; otherwise just that one.
    private func dragPayload(for book: LibraryBook) -> String {
        guard let id = book.id else { return "" }
        let ids = selection.contains(id) && selection.count > 1 ? selection.sorted() : [id]
        return Self.dragPrefix + ids.map(String.init).joined(separator: ",")
    }

    private func renameSeries(_ name: String) { library.promptRenameSeries(name) }

    private func row(_ title: String, _ symbol: String, _ value: LibrarySection, _ count: Int) -> some View {
        Label(title, systemImage: symbol)
            .badge(count)
            .tag(value)
    }

    // MARK: Grid

    private var sectionTitle: String {
        switch section ?? .all {
        case .all: return "All Comics"
        case .reading: return "Continue Reading"
        case .unread: return "Unread"
        case .finished: return "Finished"
        case .series(let name): return name
        case .folder(let id): return library.folders.first { $0.id == id }.map(library.displayName) ?? "Folder"
        }
    }

    private var visibleBooks: [LibraryBook] {
        var books = library.books
        switch section ?? .all {
        case .all: break
        case .reading: books = books.filter(\.isStarted)
        case .unread: books = books.filter(\.isUnread)
        case .finished: books = books.filter(\.finished)
        case .series(let name): books = books.filter { $0.series == name }
        case .folder(let id): books = books.filter { $0.folderID == id }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            books = books.filter { book in
                [book.title, book.series, book.writer ?? "", book.publisher ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }
        // "Continue Reading" is always most recent first; a single series is always in issue order.
        var order = LibrarySort(rawValue: sort) ?? .series
        if section == .reading { order = .recent }
        if case .series = section { order = .series }
        return books.sorted { a, b in
            switch order {
            case .title: return a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .added: return a.addedAt > b.addedAt
            case .recent: return (a.lastReadAt ?? .distantPast, a.addedAt) > (b.lastReadAt ?? .distantPast, b.addedAt)
            case .series:
                let left = a.series.isEmpty ? a.title : a.series, right = b.series.isEmpty ? b.title : b.series
                let bySeries = left.localizedStandardCompare(right)
                if bySeries != .orderedSame { return bySeries == .orderedAscending }
                if a.volume != b.volume { return (a.volume ?? 0) < (b.volume ?? 0) }
                if a.number != b.number { return (a.number ?? 0) < (b.number ?? 0) }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        let books = visibleBooks
        Group {
            if let error = library.storeError {
                ContentUnavailableView("Library Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if library.books.isEmpty {
                ContentUnavailableView {
                    Label("Your Library Is Empty", systemImage: "books.vertical")
                } description: {
                    Text("Add a folder of comics (CBZ, CBR or PDF) and Comic Viewer will keep track of them where they are. You can also open a single comic, or drop files and folders here.")
                } actions: {
                    Button("Add Folder…") { library.chooseFolders() }
                        .buttonStyle(.borderedProminent)
                    Button("Open Comic…") { ReaderWindows.shared.showOpenPanel() }
                }
            } else if books.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("Nothing Here Yet", systemImage: "tray", description: Text("No comics in “\(sectionTitle)”."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 18, alignment: .top)], spacing: 22) {
                        ForEach(books) { book in
                            BookCell(book: book, isSelected: book.id.map(selection.contains) ?? false, showSeries: !isSeriesSection,
                                     isDownloading: book.id.map(library.downloading.contains) ?? false)
                                .onTapGesture(count: 2) { ReaderWindows.shared.open(book) }
                                .onTapGesture { click(book, in: books) }
                                .contextMenu { menu(for: book) }
                                .draggable(dragPayload(for: book)) {
                                    let count = book.id.map(selection.contains) == true ? max(1, selection.count) : 1
                                    Label(count > 1 ? "\(count) comics" : book.title, systemImage: "book.closed")
                                        .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, minHeight: 300, alignment: .top)
                    .background { Color.clear.contentShape(Rectangle()).onTapGesture { selection = []; gridFocused = true } }
                }
                .background(.background)
                .focusable()
                .focusEffectDisabled()
                .focused($gridFocused)
                .onDeleteCommand { library.remove(library.selectedBooks) }
                .onCommand(#selector(NSText.selectAll(_:))) { selection = Set(books.compactMap(\.id)) }
                .onKeyPress(.return) {
                    guard let book = library.selectedBook else { return .ignored }
                    ReaderWindows.shared.open(book)
                    return .handled
                }
            }
        }
        .onChange(of: selection) { _, ids in library.selectedBookIDs = ids }
        // A renamed series stays on screen under its new name.
        .onChange(of: library.seriesRename) { _, rename in
            if rename.count == 2, section == .series(rename[0]) { section = .series(rename[1]) }
        }
        .onChange(of: library.selectedBookIDs) { _, ids in if ids != selection { selection = ids } }
        .navigationTitle(sectionTitle)
        .navigationSubtitle(library.books.isEmpty ? "" : "\(books.count) comic\(books.count == 1 ? "" : "s")")
    }

    private var isSeriesSection: Bool { if case .series = section { return true } else { return false } }

    /// Click selects, ⌘-click adds or removes one, ⇧-click selects the run from the last plain click.
    private func click(_ book: LibraryBook, in books: [LibraryBook]) {
        guard let id = book.id else { return }
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let anchor,
                  let from = books.firstIndex(where: { $0.id == anchor }), let to = books.firstIndex(where: { $0.id == id }) {
            selection = Set(books[min(from, to)...max(from, to)].compactMap(\.id))
        } else {
            selection = [id]
            anchor = id
        }
        gridFocused = true
    }

    /// Right-clicking one of several selected comics acts on all of them; otherwise on that comic alone.
    @ViewBuilder
    private func menu(for book: LibraryBook) -> some View {
        let group = library.selectedBooks
        if group.count > 1, book.id.map(selection.contains) ?? false {
            Button("Mark as Finished") { group.forEach { library.setFinished(true, for: $0) } }
            Button("Mark as Unread") { group.forEach { library.setFinished(false, for: $0) } }
            Divider()
            if library.cloudFolder != nil, group.contains(where: { !library.isInCloudFolder($0) }) {
                Button("Move \(group.count) Comics to iCloud") { library.moveToCloud(group) }
            }
            Button("Move \(group.count) Comics to Series…") { library.promptMoveToSeries(group) }
            Button("Remove \(group.count) Comics from Library") { library.remove(group) }
        } else {
            let isDownloading = book.id.map(library.downloading.contains) ?? false
            Button(book.isStarted ? "Continue Reading" : "Read") { ReaderWindows.shared.open(book) }
            Divider()
            if book.finished {
                Button("Mark as Unread") { library.setFinished(false, for: book) }
            } else {
                Button("Mark as Finished") { library.setFinished(true, for: book) }
                if book.isStarted { Button("Mark as Unread") { library.setFinished(false, for: book) } }
            }
            Divider()
            if isDownloading {
                Button("Cancel Download") { library.cancelDownload(book) }
            } else if !book.downloaded {
                Button("Download from iCloud") { Task { await library.download(book) } }
            } else if book.isInCloud {
                Button("Remove Download") { library.removeDownload(book) }
            }
            if library.cloudFolder != nil, !library.isInCloudFolder(book) {
                Button("Move to iCloud") { library.moveToCloud([book]) }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: book.path)]) }
            Button("Rename File…") { library.promptRename(book) }
                .disabled(!book.downloaded)
            Button("Edit Details…") { library.promptEditDetails(book) }
            Button("Move to Series…") { library.promptMoveToSeries([book]) }
            if !book.series.isEmpty {
                Button("Rename Series “\(book.series)”…") { renameSeries(book.series) }
            }
            Button("Remove from Library") { library.remove(book) }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button { library.chooseFolders() } label: { Label("Add Folder", systemImage: "folder.badge.plus") }
                .help("Add a folder of comics to the library")
        }
        ToolbarItem {
            Button { ReaderWindows.shared.showOpenPanel() } label: { Label("Open Comic", systemImage: "doc") }
                .help("Open a single comic")
        }
        ToolbarItem {
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(LibrarySort.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort comics")
        }
        ToolbarItem {
            Button { library.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .help("Look for new and removed comics")
                .disabled(library.folders.isEmpty || library.scanStatus != nil)
        }
    }
}

private struct BookCell: View {
    let book: LibraryBook
    let isSelected: Bool
    let showSeries: Bool
    let isDownloading: Bool
    @State private var cover: NSImage?

    private var subtitle: String {
        var parts: [String] = []
        if showSeries, !book.series.isEmpty, book.series != book.title { parts.append(book.series) }
        if let label = book.issueLabel { parts.append(label) }
        if isDownloading { return "Downloading…" }
        if book.pageCount > 0 {
            parts.append(book.pageCount == 1 ? "1 page" : "\(book.pageCount) pages")
        } else if parts.isEmpty || !book.downloaded {
            parts.append("In iCloud")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                Group {
                    if let cover {
                        Image(nsImage: cover).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle().fill(.quaternary).aspectRatio(2 / 3, contentMode: .fit)
                            .overlay { Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.tertiary) }
                    }
                }
                if book.isStarted {
                    ProgressView(value: book.progress)
                        .progressViewStyle(.linear)
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .accessibilityLabel("Reading progress")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 3 : 1))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            .overlay(alignment: .topLeading) {
                if isDownloading {
                    ProgressView().controlSize(.small).padding(6)
                        .background(.ultraThinMaterial, in: Circle()).padding(5)
                        .accessibilityLabel("Downloading from iCloud")
                } else if !book.downloaded {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.callout).padding(5)
                        .background(.ultraThinMaterial, in: Circle()).padding(5)
                        .accessibilityLabel("In iCloud, not downloaded")
                        .help("In iCloud. Open it to download.")
                } else if book.isInCloud {
                    Image(systemName: "icloud")
                        .font(.callout).padding(5)
                        .background(.ultraThinMaterial, in: Circle()).padding(5)
                        .accessibilityLabel("In iCloud, downloaded")
                        .help("Kept in iCloud and downloaded to this Mac.")
                }
            }
            .overlay(alignment: .topTrailing) {
                if book.finished {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette).foregroundStyle(.white, .green)
                        .font(.title3).padding(6)
                        .accessibilityLabel("Finished")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if book.isUnread {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                        .accessibilityLabel("Unread")
                }
                Text(book.title).font(.callout).fontWeight(.medium).lineLimit(2)
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .task(id: [book.id ?? 0, Int64(book.pageCount)]) { if let id = book.id { cover = await CoverCache.shared.image(for: id) } }
    }
}
