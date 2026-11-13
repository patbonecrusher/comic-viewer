import ComicCore
import Foundation

/// A comic that was opened before, stored with a security-scoped bookmark so the sandbox lets us
/// reopen it after relaunch, plus where the reader left off and how they were reading it.
struct RecentComic: Codable, Identifiable, Equatable {
    var id: String { path }
    var path: String
    var title: String
    var bookmark: Data
    var date: Date
    var page: Int
    var pageCount: Int
    var layout: String?
    var direction: String?
    var panelMode: Bool?

    func resolve() -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()   // balanced never: the app keeps access for its lifetime
        return url
    }
}

enum Recents {
    static let limit = 30

    static var all: [RecentComic] {
        guard let data = UserDefaults.standard.data(forKey: Prefs.recents),
              let list = try? PropertyListDecoder().decode([RecentComic].self, from: data) else { return [] }
        return list
    }

    static func entry(for url: URL) -> RecentComic? { all.first { $0.path == url.path } }

    /// Records that a comic was opened (keeps its saved position) and moves it to the top.
    static func noteOpened(_ book: ComicBook) {
        var list = all
        let existing = list.first { $0.path == book.url.path }
        guard let bookmark = (try? book.url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
                ?? existing?.bookmark else { return }
        var item = existing ?? RecentComic(path: book.url.path, title: book.title, bookmark: bookmark, date: Date(), page: 0, pageCount: book.pageCount)
        item.bookmark = bookmark
        item.date = Date()
        item.pageCount = book.pageCount
        list.removeAll { $0.path == item.path }
        list.insert(item, at: 0)
        if list.count > limit { list.removeLast(list.count - limit) }
        save(list)
    }

    static func update(_ url: URL, _ change: (inout RecentComic) -> Void) {
        var list = all
        guard let index = list.firstIndex(where: { $0.path == url.path }) else { return }
        let before = list[index]
        change(&list[index])
        if list[index] != before { save(list) }
    }

    static func remove(_ item: RecentComic) { save(all.filter { $0.id != item.id }) }
    static func clear() { save([]) }

    private static func save(_ list: [RecentComic]) {
        UserDefaults.standard.set(try? PropertyListEncoder().encode(list), forKey: Prefs.recents)
        NotificationCenter.default.post(name: .recentsChanged, object: nil)
    }
}

extension Notification.Name {
    static let recentsChanged = Notification.Name("ComicViewerRecentsChanged")
}
