import ComicCore
import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.layout) private var layout = PageLayout.single.rawValue
    @AppStorage(Prefs.direction) private var direction = ReadingDirection.leftToRight.rawValue
    @AppStorage(Prefs.background) private var background = ReaderBackground.dark.rawValue
    @AppStorage(Prefs.showStatusBar) private var showStatusBar = true
    @AppStorage(Prefs.panelStorage) private var panelStorage = PanelStorage.ask.rawValue

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
            Section {
                Picker("Save panel edits", selection: $panelStorage) {
                    ForEach(PanelStorage.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
            } header: {
                Text("Panels")
            } footer: {
                Text("Saving in the comic file adds a small file to a CBZ or folder so your edits travel with the comic. Pages are never changed. CBR and PDF comics can’t be written to; their edits stay in Comic Viewer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Picker("Background", selection: $background) {
                    ForEach(ReaderBackground.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Show status bar", isOn: $showStatusBar)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 430)
    }
}
