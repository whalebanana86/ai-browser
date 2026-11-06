import AppKit
import Foundation
import Testing

@testable import Feather

/// The window's bookmark commands, run on a real (unshown) browser window with a temporary
/// bookmark file and session saving off, so the user's files are never touched.
@MainActor
struct BrowserBookmarkTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherBrowser-\(UUID().uuidString)")

    private func makeBrowser() -> (BrowserWindowController, BookmarkStore) {
        _ = NSApplication.shared
        let browser = BrowserWindowController()
        browser.persistsSession = false
        let store = BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"))
        browser.bookmarks = store
        return (browser, store)
    }

    private func menuItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    @Test func commandBookmarksAndUnbookmarksTheCurrentPage() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (browser, store) = makeBrowser()
        let page = try #require(URL(string: "https://example.com/article"))
        browser.openTab(page)
        let command = menuItem(#selector(BrowserWindowController.toggleBookmarkAction(_:)))

        #expect(browser.validateMenuItem(command) && command.title == "이 페이지 북마크")
        browser.toggleBookmarkAction(nil)
        #expect(store.contains(page))
        #expect(browser.validateMenuItem(command) && command.title == "북마크에서 제거")
        browser.toggleBookmarkAction(nil)
        #expect(!store.contains(page))
    }

    @Test func blankTabCannotBeBookmarked() {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (browser, store) = makeBrowser()
        browser.openTab(nil)
        let command = menuItem(#selector(BrowserWindowController.toggleBookmarkAction(_:)))
        #expect(!browser.validateMenuItem(command))
        browser.toggleBookmarkAction(nil)
        #expect(store.bookmarks.isEmpty)
    }

    @Test func mainMenuHasBookmarksMenu() throws {
        let menu = MainMenu.build()
        let bookmarks = try #require(menu.items.first { $0.title == "북마크" }?.submenu)
        let command = try #require(bookmarks.items.first)
        #expect(command.action == #selector(BrowserWindowController.toggleBookmarkAction(_:)))
        #expect(command.keyEquivalent == "d" && command.keyEquivalentModifierMask == .command)
        #expect(bookmarks.delegate is BookmarksMenu)
    }

    @Test func toolbarHasBookmarkStar() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (browser, _) = makeBrowser()
        let toolbar = try #require(browser.window?.toolbar)
        let identifier = NSToolbarItem.Identifier("bookmark")
        #expect(browser.toolbarDefaultItemIdentifiers(toolbar).contains(identifier))
        let star = try #require(browser.toolbar(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: true))
        #expect(star.action == #selector(BrowserWindowController.toggleBookmarkAction(_:)))
        #expect(star.target === browser)
    }

    @Test func menuEntriesOpenAndDelete() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (browser, store) = makeBrowser()
        let saved = try #require(URL(string: "https://example.org/saved"))
        store.add(saved, title: "저장한 곳")
        let current = try #require(URL(string: "https://example.com/"))
        browser.openTab(current)

        let entries = BookmarksMenu.items(for: store.bookmarks)
        browser.openBookmark(entries[0])
        #expect(browser.activeTab?.displayURL == saved)
        #expect(browser.tabs.count == 1, "opens in the current tab")

        browser.deleteBookmark(entries[1])
        #expect(store.bookmarks.isEmpty)
    }
}
