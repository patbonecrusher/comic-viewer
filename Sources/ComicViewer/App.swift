import SwiftUI

@main
struct ComicViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The hub window: recents today, the library later. Comics open in their own AppKit-managed
        // reader windows (see ReaderWindows) so Finder, drag-and-drop and the menu all go through one path.
        Window("Comic Viewer", id: "start") {
            StartView()
        }
        .defaultSize(width: 720, height: 520)
        .commands { AppCommands() }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        super.init()
        Prefs.registerDefaults()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { ReaderWindows.shared.open(url) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Debug/screenshot hooks: `-preferRetina YES` moves new windows to the highest-density screen,
        // `-windowSize 1280x800` sets their size. Both are no-ops unless passed on the command line.
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "preferRetina") || defaults.string(forKey: "windowSize") != nil else { return }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, window.isVisible else { return }
            var frame = window.frame
            if let spec = defaults.string(forKey: "windowSize") {
                let parts = spec.lowercased().split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { frame.size = NSSize(width: parts[0], height: parts[1]) }
            }
            if defaults.bool(forKey: "preferRetina"),
               let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) {
                let v = screen.visibleFrame
                frame.origin = NSPoint(x: v.midX - frame.width / 2, y: v.midY - frame.height / 2)
            }
            window.setFrame(frame, display: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
