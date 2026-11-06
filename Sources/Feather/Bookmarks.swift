import AppKit

struct Bookmark: Codable, Equatable {
    var url: URL
    var title: String
}

/// Bookmarks, kept in one local JSON file. Nothing is synced or sent anywhere.
@MainActor
final class BookmarkStore {
    static let shared = BookmarkStore(file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Feather/bookmarks.json"))

    /// Posted on every change, so the menu and the toolbar star stay current.
    static let didChange = Notification.Name("FeatherBookmarksDidChange")

    private(set) var bookmarks: [Bookmark] = []
    private let file: URL

    init(file: URL) {
        self.file = file
        guard let data = try? Data(contentsOf: file) else { return }
        if let saved = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = saved
        } else {
            // Unreadable: keep the file for the user instead of overwriting it on the next save.
            let aside = file.deletingPathExtension().appendingPathExtension("broken.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: file, to: aside)
        }
    }

    /// Pages that can be bookmarked: not blank tabs or Feather's own error pages.
    static func canBookmark(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return ["http", "https", "file"].contains(scheme)
    }

    func contains(_ url: URL) -> Bool {
        bookmarks.contains { Self.samePage($0.url, url) }
    }

    func add(_ url: URL, title: String) {
        guard Self.canBookmark(url), !contains(url) else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmarks.append(Bookmark(url: url, title: name.isEmpty ? (url.host ?? url.absoluteString) : name))
        save()
    }

    func remove(_ url: URL) {
        let before = bookmarks.count
        bookmarks.removeAll { Self.samePage($0.url, url) }
        if bookmarks.count != before { save() }
    }

    /// Adds the page, or removes it if it's already bookmarked. Returns whether it's bookmarked now.
    @discardableResult
    func toggle(_ url: URL, title: String) -> Bool {
        if contains(url) {
            remove(url)
            return false
        }
        add(url, title: title)
        return contains(url)
    }

    /// `#section` fragments and the root's trailing slash don't make a different page.
    static func samePage(_ lhs: URL, _ rhs: URL) -> Bool {
        key(lhs) == key(rhs)
    }

    private static func key(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.fragment = nil
        if components.path.isEmpty { components.path = "/" }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.string ?? url.absoluteString
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(bookmarks).write(to: file, options: .atomic)
        } catch {
            NSLog("Feather: couldn't save bookmarks: \(error.localizedDescription)")
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

/// Fills the 북마크 menu with the saved bookmarks each time it opens. Holding ⌥ turns each
/// entry into its "삭제" alternate.
@MainActor
final class BookmarksMenu: NSObject, NSMenuDelegate {
    static let maxTitleLength = 50
    /// Items before this tag are the menu's fixed commands; everything after is rebuilt.
    static let listTag = 7_000

    private let store: BookmarkStore

    init(store: BookmarkStore) {
        self.store = store
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        while let last = menu.items.last, last.tag >= Self.listTag { menu.removeItem(last) }
        Self.items(for: store.bookmarks).forEach(menu.addItem)
    }

    static func items(for bookmarks: [Bookmark]) -> [NSMenuItem] {
        guard !bookmarks.isEmpty else {
            let empty = NSMenuItem(title: "북마크 없음", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            empty.tag = listTag
            return [empty]
        }
        return bookmarks.flatMap { bookmark -> [NSMenuItem] in
            let title = shortened(bookmark.title)
            let open = NSMenuItem(title: title, action: #selector(BrowserWindowController.openBookmark(_:)), keyEquivalent: "")
            open.representedObject = bookmark.url
            open.toolTip = bookmark.url.absoluteString
            open.keyEquivalentModifierMask = []
            open.tag = listTag
            let delete = NSMenuItem(title: "삭제: \(title)", action: #selector(BrowserWindowController.deleteBookmark(_:)), keyEquivalent: "")
            delete.representedObject = bookmark.url
            delete.isAlternate = true
            delete.keyEquivalentModifierMask = .option
            delete.tag = listTag
            return [open, delete]
        }
    }

    private static func shortened(_ title: String) -> String {
        title.count > maxTitleLength ? String(title.prefix(maxTitleLength - 1)) + "…" : title
    }
}
