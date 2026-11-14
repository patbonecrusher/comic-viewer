import ComicCore
import SwiftUI

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.showStatusBar) private var showStatusBar = true
    @AppStorage(Prefs.showThumbnails) private var showThumbnails = false
    private var windows: ReaderWindows { .shared }

    var body: some Commands {
        let reader = windows.active

        CommandGroup(replacing: .newItem) {
            Button("Open…") { windows.showOpenPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(Library.shared.recentlyRead.prefix(12)) { book in
                    Button(book.title) { windows.open(book) }
                }
            }
            Button("Add Folder to Library…") {
                openWindow(id: "library")
                Library.shared.chooseFolders()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Edit Details…") { if let book = Library.shared.selectedBook { Library.shared.promptEditDetails(book) } }
                .keyboardShortcut("i")
                .disabled(reader != nil || Library.shared.selectedBook == nil)
            Button("Rename File…") { if let book = Library.shared.selectedBook { Library.shared.promptRename(book) } }
                .disabled(reader != nil || Library.shared.selectedBook == nil)
            Button("Rename Series…") { if let book = Library.shared.selectedBook { Library.shared.promptRenameSeries(book.series) } }
                .disabled(reader != nil || (Library.shared.selectedBook?.series ?? "").isEmpty)
            Button("Move to Series…") { Library.shared.promptMoveToSeries(Library.shared.selectedBooks) }
                .disabled(reader != nil || Library.shared.selectedBookIDs.isEmpty)
            if let book = Library.shared.selectedBook, book.isInCloud, reader == nil {
                if book.downloaded {
                    Button("Remove Download") { Library.shared.removeDownload(book) }
                } else {
                    Button("Download from iCloud") { Task { await Library.shared.download(book) } }
                }
            }
            if Library.shared.cloudFolder != nil {
                Button("Move to iCloud") { Library.shared.moveToCloud(Library.shared.selectedBooks) }
                    .disabled(reader != nil || Library.shared.selectedBooks.allSatisfy(Library.shared.isInCloudFolder))
            }
            Button("Remove from Library") { Library.shared.remove(Library.shared.selectedBooks) }
                .keyboardShortcut(.delete)
                .disabled(reader != nil || Library.shared.selectedBookIDs.isEmpty)
            Divider()
            Button("Remove Missing Comics…") { Library.shared.removeMissing() }
            Button(Library.shared.hiddenCount > 0 ? "Restore Removed Comics (\(Library.shared.hiddenCount))" : "Restore Removed Comics") {
                Library.shared.restoreRemoved()
            }
            .disabled(Library.shared.hiddenCount == 0)
            Divider()
            Button("Show Library") { openWindow(id: "library") }
                .keyboardShortcut("0")
        }

        CommandGroup(before: .toolbar) {
            Picker("Page Layout", selection: Binding(get: { reader?.layout ?? .single }, set: { reader?.layout = $0 })) {
                Text(PageLayout.single.title).tag(PageLayout.single).keyboardShortcut("1")
                Text(PageLayout.double.title).tag(PageLayout.double).keyboardShortcut("2")
            }
            .pickerStyle(.inline)
            .disabled(reader == nil)
            Toggle("Panel by Panel", isOn: Binding(get: { reader?.panelMode ?? false }, set: { reader?.panelMode = $0 }))
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(reader == nil)
            Toggle("Edit Panels", isOn: Binding(get: { reader?.isEditingPanels ?? false }, set: { _ in reader?.togglePanelEditing() }))
                .keyboardShortcut("e")
                .disabled(reader == nil)
            Picker("Reading Direction", selection: Binding(get: { reader?.direction ?? .leftToRight }, set: { reader?.direction = $0 })) {
                ForEach(ReadingDirection.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .disabled(reader == nil)
            Divider()
            Picker("Zoom", selection: Binding(get: { reader?.fit ?? .page }, set: { reader?.setFit($0) })) {
                Text(FitMode.page.title).tag(FitMode.page).keyboardShortcut("9")
                Text(FitMode.width.title).tag(FitMode.width).keyboardShortcut("8")
                Text(FitMode.height.title).tag(FitMode.height)
                Text(FitMode.actual.title).tag(FitMode.actual).keyboardShortcut("7")
            }
            .pickerStyle(.inline)
            .disabled(reader == nil)
            Button("Zoom In") { reader?.zoomIn() }
                .keyboardShortcut("+")
                .disabled(reader == nil)
            Button("Zoom Out") { reader?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(reader == nil)
            Divider()
            Toggle("Show Thumbnails", isOn: $showThumbnails)
                .keyboardShortcut("t", modifiers: [.command, .option])
            Toggle("Show Status Bar", isOn: $showStatusBar)
                .keyboardShortcut("/")
            Divider()
        }

        CommandMenu("Go") {
            Button("Next Page") { reader?.next() }
                .keyboardShortcut("]")
                .disabled(reader?.canGoForward != true)
            Button("Previous Page") { reader?.previous() }
                .keyboardShortcut("[")
                .disabled(reader?.canGoBack != true)
            Divider()
            Button("First Page") { reader?.first() }
                .keyboardShortcut(.upArrow)
                .disabled(reader?.canGoBack != true)
            Button("Last Page") { reader?.last() }
                .keyboardShortcut(.downArrow)
                .disabled(reader?.canGoForward != true)
        }

        CommandGroup(replacing: .help) {
            Link("Comic Viewer Website", destination: URL(string: "https://patbonecrusher.github.io/comic-viewer/")!)
        }
    }
}
