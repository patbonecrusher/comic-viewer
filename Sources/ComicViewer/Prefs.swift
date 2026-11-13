import AppKit
import ComicCore

enum FitMode: String, CaseIterable {
    case page, width, height, actual, custom

    var title: String {
        switch self {
        case .page: return "Fit Page"
        case .width: return "Fit Width"
        case .height: return "Fit Height"
        case .actual: return "Actual Size"
        case .custom: return "Custom"
        }
    }
    static let selectable: [FitMode] = [.page, .width, .height, .actual]
}

enum ReaderBackground: String, CaseIterable {
    case black, dark, gray, white

    var title: String { rawValue.capitalized }
    var color: NSColor {
        switch self {
        case .black: return .black
        case .dark: return NSColor(white: 0.13, alpha: 1)
        case .gray: return NSColor(white: 0.45, alpha: 1)
        case .white: return .white
        }
    }
}

extension PageLayout {
    var title: String { self == .single ? "Single Page" : "Double Page" }
    var symbol: String { self == .single ? "rectangle.portrait" : "rectangle.split.2x1" }
}

extension ReadingDirection {
    var title: String { self == .leftToRight ? "Left to Right" : "Right to Left (Manga)" }
}

enum Prefs {
    static let showStatusBar = "showStatusBar"
    static let showThumbnails = "showThumbnails"
    static let layout = "defaultLayout"
    static let direction = "defaultDirection"
    static let fit = "defaultFit"
    static let background = "readerBackground"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showStatusBar: true,
            showThumbnails: false,
            layout: PageLayout.single.rawValue,
            direction: ReadingDirection.leftToRight.rawValue,
            fit: FitMode.page.rawValue,
            background: ReaderBackground.dark.rawValue,
        ])
    }

    static var defaultLayout: PageLayout { PageLayout(rawValue: UserDefaults.standard.string(forKey: layout) ?? "") ?? .single }
    static var defaultDirection: ReadingDirection { ReadingDirection(rawValue: UserDefaults.standard.string(forKey: direction) ?? "") ?? .leftToRight }
    static var defaultFit: FitMode {
        let mode = FitMode(rawValue: UserDefaults.standard.string(forKey: fit) ?? "") ?? .page
        return mode == .custom ? .page : mode
    }
}
