import ComicCore
import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.layout) private var layout = PageLayout.single.rawValue
    @AppStorage(Prefs.direction) private var direction = ReadingDirection.leftToRight.rawValue
    @AppStorage(Prefs.background) private var background = ReaderBackground.dark.rawValue
    @AppStorage(Prefs.showStatusBar) private var showStatusBar = true

    var body: some View {
        Form {
            Section("New comics open with") {
                Picker("Page layout", selection: $layout) {
                    ForEach(PageLayout.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Reading direction", selection: $direction) {
                    ForEach(ReadingDirection.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section("Appearance") {
                Picker("Background", selection: $background) {
                    ForEach(ReaderBackground.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Show status bar", isOn: $showStatusBar)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 300)
    }
}
