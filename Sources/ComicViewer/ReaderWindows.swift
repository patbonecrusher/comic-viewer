import AppKit
import ComicCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Opens comics in their own windows and knows which one is in front (for the menu bar).
@MainActor
@Observable
final class ReaderWindows {
    static let shared = ReaderWindows()

    /// The reader in the key window, if the key window is a reader.
    private(set) var active: ReaderModel?

    @ObservationIgnored private var open: [String: (window: NSWindow, model: ReaderModel)] = [:]
    @ObservationIgnored private var cascadePoint = NSPoint.zero

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true        // a folder of images is a comic too
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ComicBook.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose comics (CBZ, CBR, PDF) or a folder of images."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    func open(_ book: LibraryBook) {
        guard let url = Library.shared.url(for: book) else {
            return present(error: "It may have been moved or deleted.", title: book.title)
        }
        open(url)
    }

    func open(_ url: URL) {
        let url = url.standardizedFileURL
        if let existing = open[url.path] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        Task {
            do {
                let library = Library.shared
                let (book, record) = try await Task.detached(priority: .userInitiated) {
                    let book = try ComicBook(url: url)
                    return (book, library.record(opened: book))
                }.value
                guard open[url.path] == nil else { return }
                show(book, record: record)
            } catch {
                present(error: error.localizedDescription, title: url.lastPathComponent)
            }
        }
    }

    private func show(_ book: ComicBook, record: LibraryBook?) {
        let model = ReaderModel(book: book, record: record)
        let controller = NSHostingController(rootView: ReaderView(model: model))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = record?.title ?? book.title
        window.representedURL = book.url
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.tabbingIdentifier = "reader"
        if !window.setFrameUsingName("Reader") {
            let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let height = min(visible.height, 1000), width = min(visible.width, height * 0.78)
            window.setFrame(NSRect(x: visible.midX - width / 2, y: visible.maxY - height, width: width, height: height), display: false)
        }
        if !open.isEmpty { cascadePoint = window.cascadeTopLeft(from: cascadePoint) }
        window.setFrameAutosaveName("Reader")

        let key = book.url.path
        open[key] = (window, model)
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self, weak model] _ in
            MainActor.assumeIsolated { self?.active = model }
        }
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self, weak model] _ in
            MainActor.assumeIsolated { if self?.active === model { self?.active = nil } }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak model] _ in
            MainActor.assumeIsolated {
                model?.commitPanelEdits()
                model?.savePanelsToFile()
                model?.saveProgress()
                if self?.active === model { self?.active = nil }
                self?.open[key] = nil
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func present(error message: String, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t open “\(title)”"
        alert.informativeText = message
        alert.runModal()
    }
}
