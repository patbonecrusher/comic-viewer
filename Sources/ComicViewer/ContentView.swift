import SwiftUI

struct ContentView: View {
    @AppStorage(Prefs.showStatusBar) private var showStatusBar = true

    var body: some View {
        VStack(spacing: 0) {
            ContentUnavailableView("Comic Viewer", systemImage: "app.dashed", description: Text("Replace ContentView with your UI."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showStatusBar {
                Divider()
                HStack {
                    Text("Ready").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(.bar)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { } label: { Label("Action", systemImage: "sparkles") }
            }
        }
    }
}

struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Link("Comic Viewer Website", destination: URL(string: "https://patbonecrusher.github.io/comic-viewer/")!)
        }
    }
}

struct SettingsView: View {
    @AppStorage(Prefs.showStatusBar) private var showStatusBar = true

    var body: some View {
        Form {
            Toggle("Show status bar", isOn: $showStatusBar)
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 160)
    }
}

enum Prefs {
    static let showStatusBar = "showStatusBar"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [showStatusBar: true])
    }
}
