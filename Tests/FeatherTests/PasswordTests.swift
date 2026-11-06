import AppKit
import Foundation
import Testing
import WebKit

@testable import Feather

/// A store that lives only in memory, for everything except the keychain itself.
@MainActor
final class MemoryCredentialStore: CredentialStore {
    var items: [Account: String] = [:]
    /// How often a password was read, to check Feather doesn't fetch one it won't use.
    private(set) var passwordReads = 0

    func accounts(for host: String) -> [Account] { allAccounts().filter { $0.host == host } }
    func allAccounts() -> [Account] { items.keys.sorted { ($0.host, $0.username) < ($1.host, $1.username) } }
    func password(for account: Account) -> String? {
        passwordReads += 1
        return items[account]
    }
    func save(_ credential: Credential) throws { items[Account(host: credential.host, username: credential.username)] = credential.password }
    func delete(_ account: Account) throws { items[account] = nil }
}

/// Settings that disappear after the test.
func throwawayDefaults() -> (UserDefaults, () -> Void) {
    let name = "FeatherTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    return (defaults, { defaults.removePersistentDomain(forName: name) })
}

/// A keychain file of its own for each test: never in the user's search list, deleted after.
/// `SecKeychainCreate`/`SecKeychainDelete` are deprecated (there's no replacement for
/// file-based keychains), so they're looked up at run time instead of linked.
@MainActor
final class TemporaryKeychain {
    private typealias Create = @convention(c) (UnsafePointer<CChar>, UInt32, UnsafeRawPointer?, UInt8, OpaquePointer?,
                                               UnsafeMutablePointer<Unmanaged<SecKeychain>?>) -> OSStatus
    private typealias Delete = @convention(c) (OpaquePointer) -> OSStatus

    let keychain: SecKeychain
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("feather-test-\(UUID().uuidString).keychain-db").path

    init() throws {
        let create = unsafeBitCast(try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainCreate")), to: Create.self)
        let password = "feather-test"
        var created: Unmanaged<SecKeychain>?
        let status = create(path, UInt32(password.utf8.count), password, 0, nil, &created)
        keychain = try #require(status == errSecSuccess ? created?.takeRetainedValue() : nil, "SecKeychainCreate \(status)")
    }

    func delete() {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainDelete") else { return }
        _ = unsafeBitCast(symbol, to: Delete.self)(OpaquePointer(Unmanaged.passUnretained(keychain).toOpaque()))
    }
}

/// The real keychain code, against a temporary keychain.
@MainActor
struct KeychainTests {
    private let host = "login.example.com"

    @Test func savesReadsUpdatesAndDeletes() throws {
        let temporary = try TemporaryKeychain()
        defer { temporary.delete() }
        let store = KeychainCredentialStore(creator: "FtTs", keychain: temporary.keychain)
        let account = Account(host: host, username: "me@example.com")
        try store.save(Credential(host: host, username: account.username, password: "first-한글"))
        #expect(store.password(for: account) == "first-한글")
        #expect(store.accounts(for: host) == [account])
        #expect(store.allAccounts() == [account])

        try store.save(Credential(host: host, username: account.username, password: "second"))
        #expect(store.password(for: account) == "second")
        #expect(store.accounts(for: host).count == 1, "updating doesn't add a second item")

        try store.save(Credential(host: host, username: "", password: "no-name"))
        #expect(store.accounts(for: host).map(\.username) == ["", "me@example.com"])
        try store.delete(Account(host: host, username: ""))
        try store.delete(account)
        #expect(store.accounts(for: host).isEmpty && store.password(for: account) == nil)
        try store.delete(account)  // deleting what's gone is fine
    }

    @Test func onlySeesItsOwnItems() throws {
        let temporary = try TemporaryKeychain()
        defer { temporary.delete() }
        let store = KeychainCredentialStore(creator: "FtTs", keychain: temporary.keychain)
        let other = KeychainCredentialStore(creator: "FtTx", keychain: temporary.keychain)
        let account = Account(host: host, username: "someone")
        try other.save(Credential(host: host, username: account.username, password: "not-yours"))
        #expect(store.accounts(for: host).isEmpty)
        #expect(store.allAccounts().isEmpty)
        #expect(store.password(for: account) == nil)
        try store.delete(account)
        #expect(other.password(for: account) == "not-yours", "another creator's item survives")
    }

    /// Items go into the temporary keychain only, so the user's keychains never see test data.
    @Test func temporaryKeychainIsSeparateFromTheUsers() throws {
        let temporary = try TemporaryKeychain()
        defer { temporary.delete() }
        let host = "feather-test-\(UUID().uuidString.lowercased()).invalid"
        try KeychainCredentialStore(creator: "FtTs", keychain: temporary.keychain).save(Credential(host: host, username: "me", password: "pw"))
        #expect(KeychainCredentialStore(creator: "FtTs").accounts(for: host).isEmpty)
        #expect(FileManager.default.fileExists(atPath: temporary.path))
        temporary.delete()
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
    }
}

/// A login page in a real web view with the password script installed.
@MainActor
final class LoginPage: NSObject, WKNavigationDelegate {
    let store = MemoryCredentialStore()
    let manager: PasswordManager
    let webView: WKWebView
    private(set) var offers: [PasswordManager.Offer] = []
    private let cleanUp: () -> Void
    private var loaded: CheckedContinuation<Void, Never>?

    nonisolated static let form = """
        <form id="login" onsubmit="return false">
          <input id="user" type="text" name="id">
          <input id="pass" type="password" name="pw">
          <button id="go" type="submit">로그인</button>
          <button id="eye" type="button">보기</button>
        </form>
        <script>window.inputs = 0; document.addEventListener('input', () => window.inputs++);</script>
        """

    override init() {
        let (defaults, cleanUp) = throwawayDefaults()
        self.cleanUp = cleanUp
        manager = PasswordManager(store: store, defaults: defaults)
        let config = WKWebViewConfiguration()
        manager.install(in: config.userContentController)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        super.init()
        webView.navigationDelegate = self
        manager.onOffer = { [weak self] offer, _ in self?.offers.append(offer) }
    }

    deinit { cleanUp() }

    func load(_ html: String = LoginPage.form, at base: String = "https://login.example.com/") async {
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(html, baseURL: URL(string: base))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            loaded?.resume()
            loaded = nil
        }
    }

    /// Runs as the site's own scripts (or the user's typing) would.
    @discardableResult
    func page(_ script: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, contentWorld: .page)
    }

    func type(_ username: String, _ password: String) async throws {
        try await page("document.getElementById('user').value = \(Self.quoted(username)); document.getElementById('pass').value = \(Self.quoted(password));")
    }

    /// Lets queued script messages arrive.
    func settle() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
    }
}

@MainActor
struct PasswordFormTests {
    private let expected = Credential(host: "login.example.com", username: "me", password: "s3cret")

    @Test func submittingOffersToSave() async throws {
        let page = LoginPage()
        await page.load()
        try await page.type("me", "s3cret")
        try await page.page("document.getElementById('login').requestSubmit()")
        await page.settle()
        #expect(page.offers == [.save(expected)])
    }

    @Test func loginButtonAndEnterKeyAlsoCount() async throws {
        let clicked = LoginPage()
        await clicked.load()
        try await clicked.type("me", "s3cret")
        try await clicked.page("document.getElementById('go').click()")
        await clicked.settle()
        #expect(clicked.offers == [.save(expected)], "reported once even though click and submit both fire")

        let entered = LoginPage()
        await entered.load()
        try await entered.type("me", "s3cret")
        try await entered.page("document.getElementById('pass').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))")
        await entered.settle()
        #expect(entered.offers == [.save(expected)])
    }

    @Test func showPasswordToggleDoesNotCount() async throws {
        let page = LoginPage()
        await page.load()
        try await page.type("me", "s3cr")
        try await page.page("document.getElementById('eye').click()")
        await page.settle()
        #expect(page.offers.isEmpty)
    }

    @Test func signUpFormOffersTheNewPassword() async throws {
        let page = LoginPage()
        await page.load("""
            <form id="signup" onsubmit="return false">
              <input type="email" id="mail"><input type="password" id="a"><input type="password" id="b">
            </form>
            """)
        try await page.page("""
            mail.value = 'new@example.com'; a.value = 'fresh-pass'; b.value = 'fresh-pass';
            document.getElementById('signup').requestSubmit();
            """)
        await page.settle()
        #expect(page.offers == [.save(Credential(host: "login.example.com", username: "new@example.com", password: "fresh-pass"))])

        let change = LoginPage()
        await change.load("""
            <form id="change" onsubmit="return false">
              <input type="text" id="name"><input type="password" id="old"><input type="password" id="new1"><input type="password" id="new2">
            </form>
            """)
        try await change.page("""
            const set = (id, value) => { document.getElementById(id).value = value; };
            set('name', 'me'); set('old', 'old-pass'); set('new1', 'new-pass'); set('new2', 'new-pass');
            document.getElementById('change').requestSubmit();
            """)
        await change.settle()
        #expect(change.offers == [.save(Credential(host: "login.example.com", username: "me", password: "new-pass"))])
    }

    @Test func formScriptRunsOnlyInTopLevelPages() {
        let controller = WKUserContentController()
        let (defaults, cleanUp) = throwawayDefaults()
        defer { cleanUp() }
        PasswordManager(store: MemoryCredentialStore(), defaults: defaults).install(in: controller)
        #expect(controller.userScripts.count == 1)
        #expect(controller.userScripts.allSatisfy { $0.isForMainFrameOnly })
    }

    @Test func insecurePagesAndFramesAreIgnored() async throws {
        let http = LoginPage()
        await http.load(at: "http://login.example.com/")
        try await http.type("me", "s3cret")
        try await http.page("document.getElementById('login').requestSubmit()")
        await http.settle()
        #expect(http.offers.isEmpty, "http page")

        let framed = LoginPage()
        await framed.load(#"<iframe id="f" srcdoc='<form id="login" onsubmit="return false"><input id="user"><input id="pass" type="password"></form>'></iframe>"#)
        try await framed.page("""
            const doc = document.getElementById('f').contentDocument;
            doc.getElementById('user').value = 'me'; doc.getElementById('pass').value = 's3cret';
            doc.getElementById('login').requestSubmit();
            """)
        await framed.settle()
        #expect(framed.offers.isEmpty, "form inside a frame")
    }

    @Test func neverSaveSitesAreNotAsked() async throws {
        let page = LoginPage()
        page.manager.neverSave("login.example.com")
        await page.load()
        try await page.type("me", "s3cret")
        try await page.page("document.getElementById('login').requestSubmit()")
        await page.settle()
        #expect(page.offers.isEmpty)
        page.manager.clearNeverSave()
        #expect(page.manager.neverSaveHosts.isEmpty)
    }

    @Test func knownPasswordIsNotAskedAndChangedOneOffersUpdate() async throws {
        let same = LoginPage()
        try same.store.save(expected)
        await same.load()
        try await same.type("me", "s3cret")
        try await same.page("document.getElementById('login').requestSubmit()")
        await same.settle()
        #expect(same.offers.isEmpty)

        let changed = LoginPage()
        try changed.store.save(expected)
        await changed.load()
        try await changed.type("me", "n3w")
        try await changed.page("document.getElementById('login').requestSubmit()")
        await changed.settle()
        #expect(changed.offers == [.update(Credential(host: "login.example.com", username: "me", password: "n3w"))])
    }

    @Test func pageScriptsCannotReachTheHandler() async throws {
        let page = LoginPage()
        await page.load()
        #expect(try await page.page("return typeof window.webkit?.messageHandlers?.featherPasswords") as? String == "undefined")
        _ = try? await page.page("window.webkit.messageHandlers.featherPasswords.postMessage({ username: 'x', password: 'y' })")
        await page.settle()
        #expect(page.offers.isEmpty)
    }

    @Test func printingNeverShowsThePassword() {
        let credential = Credential(host: "a.com", username: "me", password: "hunter2")
        let offer = PasswordManager.Offer.save(credential)
        for text in [String(describing: credential), String(reflecting: credential), "\(offer)", String(reflecting: [offer])] {
            #expect(!text.contains("hunter2") && text.contains("me"), "\(text)")
        }
    }

    @Test func trustedHostNeedsTopLevelHTTPS() {
        #expect(PasswordManager.trustedHost(isMainFrame: true, scheme: "https", host: "Login.Example.com") == "login.example.com")
        #expect(PasswordManager.trustedHost(isMainFrame: false, scheme: "https", host: "login.example.com") == nil)
        #expect(PasswordManager.trustedHost(isMainFrame: true, scheme: "http", host: "login.example.com") == nil)
        #expect(PasswordManager.trustedHost(isMainFrame: true, scheme: "https", host: "") == nil)
    }
}

@MainActor
struct PasswordFillTests {
    private let account = Account(host: "login.example.com", username: "me")

    private func pageWithSavedAccount(_ html: String = LoginPage.form, at base: String = "https://login.example.com/") async throws -> LoginPage {
        let page = LoginPage()
        try page.store.save(Credential(host: account.host, username: account.username, password: "s3cret"))
        await page.load(html, at: base)
        return page
    }

    private func values(_ page: LoginPage) async throws -> [String] {
        try #require(try await page.page("return [document.getElementById('user')?.value ?? '', document.getElementById('pass')?.value ?? '']") as? [String])
    }

    @Test func fillsUsernameAndPasswordAndTellsThePage() async throws {
        let page = try await pageWithSavedAccount()
        #expect(await page.manager.fill(account, in: page.webView) == .filled)
        #expect(try await values(page) == ["me", "s3cret"])
        #expect(try await page.page("return window.inputs") as? Int ?? 0 >= 2, "frameworks see input events")
    }

    @Test func refusesOtherHostsAndInsecurePages() async throws {
        let elsewhere = try await pageWithSavedAccount(at: "https://evil.example.net/")
        #expect(await elsewhere.manager.fill(account, in: elsewhere.webView) == .nothing)
        #expect(try await values(elsewhere) == ["", ""])
        #expect(elsewhere.store.passwordReads == 0, "the password isn't even read for another site")

        let insecure = try await pageWithSavedAccount(at: "http://login.example.com/")
        #expect(await insecure.manager.fill(account, in: insecure.webView) == .nothing)
        #expect(try await values(insecure) == ["", ""])
    }

    /// The script checks the page's host itself too, in case the page changed after Feather looked.
    @Test func fillScriptChecksTheHostItself() async throws {
        let page = try await pageWithSavedAccount(at: "https://evil.example.net/")
        let result = try await page.webView.callAsyncJavaScript(PasswordManager.fillScript,
                                                                arguments: ["host": "login.example.com", "username": "me", "password": "s3cret"],
                                                                in: nil, contentWorld: PasswordManager.world)
        #expect(result as? String == "nothing")
        #expect(try await values(page) == ["", ""])
    }

    @Test func firstStepOfTwoStepLoginGetsOnlyTheUsername() async throws {
        let step = try await pageWithSavedAccount(#"<input id="user" type="email" autocomplete="username">"#)
        #expect(await step.manager.fill(account, in: step.webView) == .usernameOnly)
        #expect(try await values(step) == ["me", ""])

        let search = try await pageWithSavedAccount(#"<input id="user" type="search" placeholder="검색">"#)
        #expect(await search.manager.fill(account, in: search.webView) == .nothing)
        #expect(try await values(search) == ["", ""], "a search box is not a login field")
    }
}
