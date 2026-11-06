import AppKit
import Foundation
import Testing

@testable import Feather

@MainActor
struct BookmarkTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherBookmarks-\(UUID().uuidString)")
    private var file: URL { folder.appendingPathComponent("bookmarks.json") }

    private func url(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func addRemoveAndToggle() throws {
        defer { cleanUp() }
        let store = BookmarkStore(file: file)
        let page = try url("https://www.naver.com/news")
        store.add(page, title: "뉴스")
        #expect(store.contains(page))
        #expect(store.bookmarks == [Bookmark(url: page, title: "뉴스")])
        store.remove(page)
        #expect(!store.contains(page) && store.bookmarks.isEmpty)
        #expect(store.toggle(page, title: "뉴스"))
        #expect(!store.toggle(page, title: "뉴스"))
        #expect(store.bookmarks.isEmpty)
    }

    @Test func samePageIsSavedOnce() throws {
        defer { cleanUp() }
        let store = BookmarkStore(file: file)
        store.add(try url("https://Example.com"), title: "a")
        store.add(try url("https://example.com/"), title: "b")
        store.add(try url("https://example.com/#top"), title: "c")
        #expect(store.bookmarks.count == 1)
        #expect(store.contains(try url("https://example.com/#section")))
        store.add(try url("https://example.com/other"), title: "d")
        #expect(store.bookmarks.count == 2)
    }

    @Test func keepsBookmarksAcrossLaunches() throws {
        defer { cleanUp() }
        let first = BookmarkStore(file: file)
        first.add(try url("https://ko.wikipedia.org/wiki/%EB%8C%80%ED%95%9C%EB%AF%BC%EA%B5%AD"), title: "대한민국")
        first.add(try url("https://github.com"), title: "")
        let second = BookmarkStore(file: file)
        #expect(second.bookmarks == first.bookmarks)
        #expect(second.bookmarks.last?.title == "github.com", "empty titles fall back to the host")
    }

    @Test func brokenFileIsKeptAside() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let store = BookmarkStore(file: file)
        #expect(store.bookmarks.isEmpty)
        store.add(try url("https://example.com"), title: "x")
        let aside = folder.appendingPathComponent("bookmarks.broken.json")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "not json")
        #expect(BookmarkStore(file: file).bookmarks.count == 1)
    }

    @Test func onlyWebPagesCanBeBookmarked() throws {
        #expect(BookmarkStore.canBookmark(try url("https://a.com")))
        #expect(BookmarkStore.canBookmark(try url("http://a.com")))
        #expect(BookmarkStore.canBookmark(try url("file:///Users/me/page.html")))
        #expect(!BookmarkStore.canBookmark(try url("about:blank")))
        #expect(!BookmarkStore.canBookmark(try url("data:text/html,hi")))
        #expect(!BookmarkStore.canBookmark(nil))
        defer { cleanUp() }
        let store = BookmarkStore(file: file)
        store.add(try url("about:blank"), title: "blank")
        #expect(store.bookmarks.isEmpty)
    }

    @Test func menuListsBookmarksWithDeleteAlternates() throws {
        let long = String(repeating: "가", count: 80)
        let bookmarks = [Bookmark(url: try url("https://a.com/"), title: "에이"), Bookmark(url: try url("https://b.com/"), title: long)]
        let items = BookmarksMenu.items(for: bookmarks)
        #expect(items.count == 4)
        let open = items[0], delete = items[1]
        #expect(open.title == "에이" && open.representedObject as? URL == bookmarks[0].url)
        #expect(open.action == #selector(BrowserWindowController.openBookmark(_:)) && !open.isAlternate)
        #expect(delete.title == "삭제: 에이" && delete.representedObject as? URL == bookmarks[0].url)
        #expect(delete.action == #selector(BrowserWindowController.deleteBookmark(_:)))
        #expect(delete.isAlternate && delete.keyEquivalentModifierMask == .option && open.keyEquivalentModifierMask.isEmpty)
        #expect(items[2].title.count == BookmarksMenu.maxTitleLength && items[2].title.hasSuffix("…"))
        #expect(items.allSatisfy { $0.tag >= BookmarksMenu.listTag })
    }

    @Test func emptyMenuSaysSo() {
        let items = BookmarksMenu.items(for: [])
        #expect(items.count == 1 && items[0].title == "북마크 없음" && !items[0].isEnabled)
    }

    @Test func menuRebuildKeepsFixedCommands() throws {
        defer { cleanUp() }
        let store = BookmarkStore(file: file)
        store.add(try url("https://a.com"), title: "a")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "이 페이지 북마크", action: nil, keyEquivalent: "d"))
        menu.addItem(.separator())
        let delegate = BookmarksMenu(store: store)
        delegate.menuNeedsUpdate(menu)
        delegate.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == ["이 페이지 북마크", "", "a", "삭제: a"])
    }
}
