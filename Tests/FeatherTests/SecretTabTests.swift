import AppKit
import Foundation
import Testing
import WebKit

@testable import Feather

/// Secret tabs on a real (unshown) browser window. The default cookie store is only read,
/// never written, and session saving is off.
@MainActor
struct SecretTabTests {
    private func makeBrowser() -> BrowserWindowController {
        _ = NSApplication.shared
        let browser = BrowserWindowController()
        browser.persistsSession = false
        browser.passwords = PasswordManager(store: MemoryCredentialStore(), defaults: Self.settings)
        return browser
    }

    private static let settings = UserDefaults(suiteName: "FeatherTests-SecretTab") ?? .standard

    private func url(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    private func cookies(in store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    @Test func secretTabsHaveTheirOwnInMemoryStore() throws {
        let browser = makeBrowser()
        let normal = browser.openTab(try url("https://example.com/"))
        let first = browser.openTab(try url("https://example.com/"), privateStore: .nonPersistent())
        let second = browser.openTab(try url("https://example.com/"), privateStore: .nonPersistent())
        let normalStore = normal.wake().configuration.websiteDataStore
        let firstStore = first.wake().configuration.websiteDataStore
        let secondStore = second.wake().configuration.websiteDataStore
        #expect(normalStore.isPersistent && normalStore === WebKitEnvironment.shared.dataStore)
        #expect(!firstStore.isPersistent && !secondStore.isPersistent)
        #expect(firstStore !== secondStore, "secret tabs don't share cookies with each other")
        #expect(first.isPrivate && !normal.isPrivate)
    }

    @Test func cookiesStayInsideTheSecretTab() async throws {
        let secret = WKWebsiteDataStore.nonPersistent()
        let other = WKWebsiteDataStore.nonPersistent()
        let name = "feather-secret-\(UUID().uuidString)"
        let cookie = try #require(HTTPCookie(properties: [.name: name, .value: "1", .domain: "example.com", .path: "/"]))
        await withCheckedContinuation { continuation in
            secret.httpCookieStore.setCookie(cookie) { continuation.resume() }
        }
        #expect(await cookies(in: secret).contains { $0.name == name })
        #expect(await !cookies(in: other).contains { $0.name == name })
        #expect(await !cookies(in: WebKitEnvironment.shared.dataStore).contains { $0.name == name })
    }

    @Test func suspendingKeepsTheStoreAndOpenedTabsInheritIt() throws {
        let browser = makeBrowser()
        let store = WKWebsiteDataStore.nonPersistent()
        let tab = browser.openTab(try url("https://example.com/"), privateStore: store)
        tab.wake()
        tab.suspend()
        #expect(tab.wake().configuration.websiteDataStore === store, "logins survive suspension")

        browser.tab(tab, openInBackground: try url("https://example.com/next"))
        let opened = try #require(browser.tabs.first { $0 !== tab && $0.displayURL?.path == "/next" })
        #expect(opened.privateStore === store)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        let popup = Tab(webView: WebKitEnvironment.shared.makeWebView(configuration: config))
        #expect(popup.isPrivate && popup.privateStore === store, "window.open from a secret tab stays secret")
        #expect(!Tab(webView: WebKitEnvironment.shared.makeWebView()).isPrivate)
    }

    @Test func secretTabsAreNotSavedOrReopenable() throws {
        let browser = makeBrowser()
        browser.openTab(try url("https://example.com/kept"))
        browser.openTab(try url("https://example.com/secret"), privateStore: .nonPersistent())
        #expect(browser.savedSessionURLs == [try url("https://example.com/kept")])

        let reopen = NSMenuItem(title: "", action: #selector(BrowserWindowController.reopenClosedTab(_:)), keyEquivalent: "")
        browser.closeTab(at: browser.tabs.firstIndex { $0.isPrivate } ?? 0)
        #expect(!browser.validateMenuItem(reopen), "a closed secret tab can't come back")
        browser.closeTab(at: 0)
        #expect(browser.validateMenuItem(reopen), "ordinary tabs still can")
    }

    @Test func secretTabsNeverAskToSaveAccounts() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        #expect(!BrowserWindowController.offersPasswordSaving(in: WKWebView(frame: .zero, configuration: config)))
        #expect(BrowserWindowController.offersPasswordSaving(in: WebKitEnvironment.shared.makeWebView()))
    }

    @Test func menuOpensSecretTab() throws {
        let file = try #require(MainMenu.build().items.first { $0.title == "파일" }?.submenu)
        let item = try #require(file.items.first { $0.action == #selector(BrowserWindowController.newPrivateTabAction(_:)) })
        #expect(item.keyEquivalent == "n" && item.keyEquivalentModifierMask == [.command, .shift])

        let browser = makeBrowser()
        browser.newPrivateTabAction(nil)
        let first = try #require(browser.activeTab)
        #expect(first.isPrivate && first.displayTitle == "시크릿 탭")
        #expect(first.privateStore?.isPersistent == false, "the menu's secret tab keeps nothing on disk")
        browser.newPrivateTabAction(nil)
        #expect(browser.activeTab?.privateStore !== first.privateStore, "each secret tab gets its own store")
    }
}
