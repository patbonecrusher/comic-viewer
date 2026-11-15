import ComicCore
import SwiftUI
import UniformTypeIdentifiers

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All", reading = "Reading", unread = "Unread", finished = "Finished"
    var id: String { rawValue }
}

/// The collection: a grid of covers, filtered by reading state, series and search.
struct LibraryScreen: View {
    @State private var library = MobileLibrary.shared
    @State private var filter = LibraryFilter.all
    @State private var series: String?
    @State private var search = ""
    @State private var isImporting = false
    @State private var reader: ReaderState?
    @State private var opening: Int64?
    @State private var pendingDelete: LibraryBook?
    @Environment(\.scenePhase) private var scenePhase

    static let comicTypes: [UTType] = {
        var types: [UTType] = [.pdf, .zip]
        for identifier in ["com.patlaplante.ComicViewer.cbz", "com.patlaplante.ComicViewer.cbr", "com.rarlab.rar-archive"] {
            if let type = UTType(identifier) { types.append(type) }
        }
        return types
    }()

    private var seriesNames: [String] {
        Set(library.books.map(\.series)).filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var books: [LibraryBook] {
        var books = library.books
        switch filter {
        case .all: break
        case .reading: books = books.filter(\.isStarted)
        case .unread: books = books.filter(\.isUnread)
        case .finished: books = books.filter(\.finished)
        }
        if let series { books = books.filter { $0.series == series } }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            books = books.filter { book in
                [book.title, book.series, book.writer ?? "", book.publisher ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }
        if filter == .reading {
            return books.sorted { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
        }
        // Series together, in volume and issue order.
        return books.sorted { a, b in
            let left = a.series.isEmpty ? a.title : a.series, right = b.series.isEmpty ? b.title : b.series
            let bySeries = left.localizedStandardCompare(right)
            if bySeries != .orderedSame { return bySeries == .orderedAscending }
            if a.volume != b.volume { return (a.volume ?? 0) < (b.volume ?? 0) }
            if a.number != b.number { return (a.number ?? 0) < (b.number ?? 0) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.books.isEmpty {
                    empty
                } else {
                    grid
                }
            }
            .navigationTitle(series ?? "Comics")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { filterMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isImporting = true } label: { Label("Add Comics", systemImage: "plus") }
                }
            }
            .searchable(text: $search, prompt: "Title, series, writer")
            .refreshable { library.rescan() }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.comicTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await library.importFiles(urls) } }
        }
        .fullScreenCover(item: $reader, onDismiss: { library.reload() }) { ReaderScreen(state: $0) }
        .alert("Comic Viewer", isPresented: Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.message ?? "")
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { book in
            Button("Delete", role: .destructive) { library.delete(book) }
        } message: { book in
            Text(library.isInCloud(book) ? "The file is deleted from iCloud Drive, on all your devices." : "The file is deleted from this device.")
        }
        // A comic opened from the Files app or sent from another app.
        .onOpenURL { url in Task { await openFile(url) } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { library.rescan() } }
        .task { await openForTesting() }
    }

    private var deleteTitle: String { "Delete “\(pendingDelete?.title ?? "")”?" }

    private var empty: some View {
        ContentUnavailableView {
            Label("No Comics Yet", systemImage: "books.vertical")
        } description: {
            Text("Add CBZ, CBR or PDF comics, or copy them into the Comic Viewer folder with the Files app. Comics the Mac app keeps in iCloud show up here too.")
        } actions: {
            Button("Add Comics…") { isImporting = true }.buttonStyle(.borderedProminent)
        }
    }

    private var grid: some View {
        ScrollView {
            if books.isEmpty {
                ContentUnavailableView.search(text: search).padding(.top, 60)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 170), spacing: 16, alignment: .top)], spacing: 20) {
                ForEach(books) { book in
                    Button { open(book) } label: {
                        BookCell(book: book, showSeries: series == nil,
                                 isBusy: book.id.map { library.downloading.contains($0) || opening == $0 } ?? false)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menu(for: book) }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $filter) {
                ForEach(LibraryFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            if !seriesNames.isEmpty {
                Picker("Series", selection: $series) {
                    Text("All Series").tag(String?.none)
                    ForEach(seriesNames, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .pickerStyle(.menu)
            }
        } label: {
            Label("Filter", systemImage: filter == .all && series == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
    }

    @ViewBuilder
    private func menu(for book: LibraryBook) -> some View {
        Button { open(book) } label: { Label(book.isStarted ? "Continue Reading" : "Read", systemImage: "book") }
        if book.finished {
            Button { library.setFinished(false, for: book) } label: { Label("Mark as Unread", systemImage: "circle") }
        } else {
            Button { library.setFinished(true, for: book) } label: { Label("Mark as Finished", systemImage: "checkmark.circle") }
            if book.isStarted { Button { library.setFinished(false, for: book) } label: { Label("Mark as Unread", systemImage: "circle") } }
        }
        if library.isInCloud(book) {
            if book.id.map(library.downloading.contains) ?? false {
                Button { library.cancelDownload(book) } label: { Label("Cancel Download", systemImage: "xmark.circle") }
            } else if !book.downloaded {
                Button { Task { await library.download(book) } } label: { Label("Download", systemImage: "icloud.and.arrow.down") }
            } else {
                Button { library.removeDownload(book) } label: { Label("Remove Download", systemImage: "icloud") }
                Button { library.move(book, toCloud: false) } label: { Label("Keep Only on This Device", systemImage: "iphone") }
            }
        } else if library.cloudAvailable {
            Button { library.move(book, toCloud: true) } label: { Label("Move to iCloud", systemImage: "icloud.and.arrow.up") }
        }
        Button(role: .destructive) { pendingDelete = book } label: { Label("Delete…", systemImage: "trash") }
    }

    // MARK: Opening

    private func open(_ book: LibraryBook, startPage: Int? = nil, panelMode: Bool? = nil) {
        guard opening == nil, let id = book.id else { return }
        opening = id
        Task {
            defer { opening = nil }
            let url = URL(fileURLWithPath: book.path)
            if !LibraryStore.isDownloaded(url) { guard await library.download(book) else { return } }
            do {
                let comic = try await Task.detached(priority: .userInitiated) { try ComicBook(url: url) }.value
                // The record may have been filled in by the download.
                let record = library.books.first { $0.id == id } ?? book
                reader = ReaderState(book: comic, record: record, startPage: startPage, panelMode: panelMode)
            } catch {
                library.message = "Couldn’t open “\(book.title)”. \(error.localizedDescription)"
            }
        }
    }

    private func openFile(_ url: URL) async {
        guard let place = await library.importFiles([url]), let book = library.book(at: place) else { return }
        reader = nil
        open(book)
    }

    /// Launch arguments for screenshots and testing: `-openFirst YES` opens the first comic,
    /// optionally at `-startPage 12` and with `-panelMode YES`, then plays `-testScript`.
    private func openForTesting() async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "openFirst") else { return }
        for _ in 0..<40 where library.books.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
        guard let book = books.first(where: { $0.downloaded }) else { return }
        open(book, startPage: defaults.object(forKey: "startPage") != nil ? defaults.integer(forKey: "startPage") : nil,
             panelMode: defaults.object(forKey: "panelMode") != nil ? defaults.bool(forKey: "panelMode") : nil)
        // `-testScript nnLnP`: n next, p previous, L turn sideways, P turn upright, one step a second.
        guard let script = defaults.string(forKey: "testScript") else { return }
        for _ in 0..<40 where reader == nil { try? await Task.sleep(for: .milliseconds(250)) }
        for step in script {
            try? await Task.sleep(for: .seconds(1))
            switch step {
            case "n": reader?.next()
            case "p": reader?.previous()
            case "L", "P":
                let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
                scene?.requestGeometryUpdate(.iOS(interfaceOrientations: step == "L" ? .landscapeRight : .portrait))
            default: break
            }
        }
    }
}

private struct BookCell: View {
    let book: LibraryBook
    let showSeries: Bool
    let isBusy: Bool
    @State private var cover: UIImage?

    private var subtitle: String {
        if isBusy, !book.downloaded { return "Downloading…" }
        var parts: [String] = []
        if showSeries, !book.series.isEmpty, book.series != book.title { parts.append(book.series) }
        if let label = book.issueLabel { parts.append(label) }
        if book.pageCount > 0 {
            parts.append(book.pageCount == 1 ? "1 page" : "\(book.pageCount) pages")
        } else if !book.downloaded {
            parts.append("In iCloud")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottom) {
                if let cover {
                    Image(uiImage: cover).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary).aspectRatio(2 / 3, contentMode: .fit)
                        .overlay { Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.tertiary) }
                }
                if book.isStarted {
                    ProgressView(value: book.progress)
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .accessibilityLabel("Reading progress")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
            .overlay(alignment: .topLeading) {
                if isBusy {
                    ProgressView().padding(6).background(.ultraThinMaterial, in: Circle()).padding(5)
                } else if !book.downloaded {
                    Image(systemName: "icloud.and.arrow.down").font(.footnote).padding(5)
                        .background(.ultraThinMaterial, in: Circle()).padding(5)
                        .accessibilityLabel("In iCloud, not downloaded")
                }
            }
            .overlay(alignment: .topTrailing) {
                if book.finished {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette).foregroundStyle(.white, .green)
                        .font(.title3).padding(5)
                        .accessibilityLabel("Finished")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if book.isUnread {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7).accessibilityLabel("Unread")
                }
                Text(book.title).font(.footnote.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
            }
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .task(id: [book.id ?? 0, Int64(book.pageCount), Int64(MobileLibrary.shared.coverGeneration)]) {
            if let id = book.id { cover = await MobileLibrary.shared.cover(for: id) }
        }
    }
}
