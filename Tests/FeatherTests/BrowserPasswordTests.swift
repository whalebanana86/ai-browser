import AppKit
import Foundation
import Testing

@testable import Feather

/// The window's account commands on a real (unshown) browser window, with an in-memory
/// store and throwaway settings: the user's keychain and files are never touched.
@MainActor
struct BrowserPasswordTests {
    private let credential = Credential(host: "login.example.com", username: "me", password: "s3cret")

    private func makeBrowser() -> (BrowserWindowController, MemoryCredentialStore, () -> Void) {
        _ = NSApplication.shared
        let browser = BrowserWindowController()
        browser.persistsSession = false
        let store = MemoryCredentialStore()
        let (defaults, cleanUp) = throwawayDefaults()
        browser.passwords = PasswordManager(store: store, defaults: defaults)
        return (browser, store, cleanUp)
    }

    @Test func mainMenuHasAccountsMenu() throws {
        let menu = MainMenu.build()
        let accounts = try #require(menu.items.first { $0.title == "계정" }?.submenu)
        let fill = try #require(accounts.items.first)
        #expect(fill.action == #selector(BrowserWindowController.fillPasswordAction(_:)))
        #expect(fill.keyEquivalent == "\\" && fill.keyEquivalentModifierMask == .command)
        #expect(accounts.items.contains { $0.action == #selector(BrowserWindowController.clearNeverSaveAction(_:)) })
        #expect(accounts.delegate is AccountsMenu)
    }

    @Test func toolbarHasKeyButton() throws {
        let (browser, _, cleanUp) = makeBrowser()
        defer { cleanUp() }
        let toolbar = try #require(browser.window?.toolbar)
        let identifier = NSToolbarItem.Identifier("password")
        #expect(browser.toolbarDefaultItemIdentifiers(toolbar).contains(identifier))
        let key = try #require(browser.toolbar(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: true))
        #expect(key.action == #selector(BrowserWindowController.fillPasswordAction(_:)) && key.target === browser)
    }

    @Test func savingAnswersDoWhatTheySay() {
        let (browser, store, cleanUp) = makeBrowser()
        defer { cleanUp() }
        browser.answer(.save(credential), with: .alertSecondButtonReturn)  // 나중에
        #expect(store.items.isEmpty && browser.passwords.neverSaveHosts.isEmpty)
        browser.answer(.save(credential), with: .alertFirstButtonReturn)  // 저장
        #expect(store.items[Account(host: credential.host, username: "me")] == "s3cret")
        browser.answer(.update(Credential(host: credential.host, username: "me", password: "n3w")), with: .alertFirstButtonReturn)
        #expect(store.items[Account(host: credential.host, username: "me")] == "n3w")
        browser.answer(.save(Credential(host: "other.example.com", username: "x", password: "y")), with: .alertThirdButtonReturn)
        #expect(browser.passwords.neverSaveHosts == ["other.example.com"])
        #expect(store.accounts(for: "other.example.com").isEmpty, "저장 안 함 doesn't save")
    }

    @Test func menuCommandsAreEnabledOnlyWhenUseful() {
        let (browser, _, cleanUp) = makeBrowser()
        defer { cleanUp() }
        browser.openTab(nil)
        let fill = NSMenuItem(title: "", action: #selector(BrowserWindowController.fillPasswordAction(_:)), keyEquivalent: "")
        let clear = NSMenuItem(title: "", action: #selector(BrowserWindowController.clearNeverSaveAction(_:)), keyEquivalent: "")
        #expect(!browser.validateMenuItem(fill), "nothing to fill on a blank tab")
        #expect(!browser.validateMenuItem(clear))
        browser.passwords.neverSave("example.com")
        #expect(browser.validateMenuItem(clear))
        browser.clearNeverSaveAction(nil)
        #expect(browser.passwords.neverSaveHosts.isEmpty)
    }

    @Test func removingAnAccountDeletesIt() throws {
        let (browser, store, cleanUp) = makeBrowser()
        defer { cleanUp() }
        try store.save(credential)
        browser.removeAccount(Account(host: credential.host, username: "me"))
        #expect(store.items.isEmpty)
    }

    @Test func accountsMenuListsWithDeleteAlternates() {
        let accounts = [Account(host: "a.com", username: "me"), Account(host: "b.com", username: "")]
        let items = AccountsMenu.items(for: accounts)
        #expect(items.map(\.title) == ["저장된 계정", "a.com — me", "삭제: a.com — me", "b.com — (아이디 없음)", "삭제: b.com — (아이디 없음)"])
        #expect(!items[0].isEnabled)
        #expect(items[1].action == #selector(BrowserWindowController.openAccountSite(_:)) && !items[1].isAlternate)
        #expect(items[2].action == #selector(BrowserWindowController.deleteAccount(_:)) && items[2].isAlternate)
        #expect(items[2].keyEquivalentModifierMask == .option && items[1].keyEquivalentModifierMask.isEmpty)
        #expect(items[2].representedObject as? Account == accounts[0])
        #expect(AccountsMenu.items(for: []).map(\.title) == ["저장된 계정 없음"])
    }

    /// The menu never reads passwords: listing accounts only needs host and name.
    @Test func accountsMenuDoesNotReadPasswords() throws {
        let store = MemoryCredentialStore()
        try store.save(credential)
        let (defaults, cleanUp) = throwawayDefaults()
        defer { cleanUp() }
        let menu = NSMenu()
        AccountsMenu(manager: PasswordManager(store: store, defaults: defaults)).menuNeedsUpdate(menu)
        #expect(menu.items.count == 3)
        #expect(store.passwordReads == 0)
    }
}
