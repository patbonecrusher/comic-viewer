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
