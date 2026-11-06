import AppKit
import Security
import WebKit

struct Credential: Equatable {
    var host: String
    var username: String
    var password: String
}

/// Printing a credential (debug output, test failures, crash logs) never shows the password.
extension Credential: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "Credential(host: \(host), username: \(username), password: ••••••)" }
    var debugDescription: String { description }
}

struct Account: Equatable, Hashable {
    var host: String
    var username: String
}

/// Where passwords live: the macOS keychain in the app, a throwaway store in tests.
@MainActor
protocol CredentialStore: AnyObject {
    func accounts(for host: String) -> [Account]
    func allAccounts() -> [Account]
    func password(for account: Account) -> String?
    func save(_ credential: Credential) throws
    func delete(_ account: Account) throws
}

/// Internet-password items in the login keychain, tagged with a creator code so Feather only
/// ever lists or changes the items it made. They also show up in Keychain Access.
@MainActor
final class KeychainCredentialStore: CredentialStore {
    static let shared = KeychainCredentialStore(creator: "Fthr")

    private let creator: FourCharCode
    private let keychain: SecKeychain?

    /// `creator` is four ASCII letters. `keychain` is nil for the user's keychains; tests pass
    /// a temporary one so they never touch the user's passwords.
    init(creator: String, keychain: SecKeychain? = nil) {
        self.creator = creator.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
        self.keychain = keychain
    }

    private func query(_ account: Account? = nil, host: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
                                    kSecAttrCreator as String: creator,
                                    kSecAttrProtocol as String: kSecAttrProtocolHTTPS]
        if let server = account?.host ?? host { query[kSecAttrServer as String] = server }
        if let account { query[kSecAttrAccount as String] = account.username }
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        return query
    }

    private func list(_ base: [String: Any]) -> [Account] {
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let host = item[kSecAttrServer as String] as? String else { return nil }
            return Account(host: host, username: item[kSecAttrAccount as String] as? String ?? "")
        }
        .sorted { ($0.host, $0.username) < ($1.host, $1.username) }
    }

    func accounts(for host: String) -> [Account] { list(query(host: host)) }

    func allAccounts() -> [Account] { list(query()) }

    func password(for account: Account) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ credential: Credential) throws {
        let account = Account(host: credential.host, username: credential.username)
        let secret = Data(credential.password.utf8)
        var status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: secret] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecMatchSearchList as String] = nil
            if let keychain { item[kSecUseKeychain as String] = keychain }
            item[kSecValueData as String] = secret
            item[kSecAttrLabel as String] = "\(credential.host) (Feather)"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete(_ account: Account) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

struct KeychainError: LocalizedError {
    var status: OSStatus
    var errorDescription: String? { SecCopyErrorMessageString(status, nil) as String? ?? "키체인 오류 \(status)" }
}

/// Offers to save what's typed into login forms, and fills it back when asked. The form
/// script runs in its own content world, so page scripts can neither see its messages nor
/// send fake ones, and only top-level https pages are trusted, by the origin WebKit reports.
/// Nothing is filled until the user asks: a page can't silently harvest saved passwords.
@MainActor
final class PasswordManager: NSObject, WKScriptMessageHandler {
    static let shared = PasswordManager(store: KeychainCredentialStore.shared, defaults: .standard)
    static let world = WKContentWorld.world(name: "FeatherPasswords")
    static let handlerName = "featherPasswords"

    enum Offer: Equatable {
        case save(Credential)
        case update(Credential)
    }

    var store: CredentialStore {
        didSet { cache = [:] }
    }
    /// Accounts per host, for the toolbar, which asks on every page update.
    private var cache: [String: [Account]] = [:]
    /// Shows the "save this account?" question; set by the browser window.
    var onOffer: ((Offer, WKWebView?) -> Void)?
    private let defaults: UserDefaults
    private static let neverSaveKey = "neverSavePasswordHosts"

    init(store: CredentialStore, defaults: UserDefaults) {
        self.store = store
        self.defaults = defaults
    }

    func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: Self.formScript, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: Self.world))
        controller.add(self, contentWorld: Self.world, name: Self.handlerName)
    }

    // MARK: Saving

    var neverSaveHosts: [String] { (defaults.stringArray(forKey: Self.neverSaveKey) ?? []).sorted() }

    func neverSave(_ host: String) {
        defaults.set(Array(Set(neverSaveHosts + [host])), forKey: Self.neverSaveKey)
    }

    func clearNeverSave() {
        defaults.removeObject(forKey: Self.neverSaveKey)
    }

    /// The host a frame may save or fill passwords for: top-level https pages only.
    static func trustedHost(_ frame: WKFrameInfo) -> String? {
        trustedHost(isMainFrame: frame.isMainFrame, scheme: frame.securityOrigin.protocol, host: frame.securityOrigin.host)
    }

    static func trustedHost(isMainFrame: Bool, scheme: String, host: String) -> String? {
        guard isMainFrame, scheme.lowercased() == "https", !host.isEmpty else { return nil }
        return host.lowercased()
    }

    /// What to ask about a submitted login, if anything.
    func offer(for credential: Credential) -> Offer? {
        guard !credential.password.isEmpty, !neverSaveHosts.contains(credential.host) else { return nil }
        let account = Account(host: credential.host, username: credential.username)
        guard store.accounts(for: credential.host).contains(account) else { return .save(credential) }
        return store.password(for: account) == credential.password ? nil : .update(credential)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let host = Self.trustedHost(message.frameInfo),
              let body = message.body as? [String: Any],
              let username = body["username"] as? String, username.count <= 256,
              let password = body["password"] as? String, password.count <= 1024 else { return }
        let credential = Credential(host: host, username: username.trimmingCharacters(in: .whitespaces), password: password)
        if let offer = offer(for: credential) { onOffer?(offer, message.webView) }
    }

    func accept(_ offer: Offer) throws {
        switch offer {
        case .save(let credential), .update(let credential):
            cache[credential.host] = nil
            try store.save(credential)
        }
    }

    func delete(_ account: Account) throws {
        cache[account.host] = nil
        try store.delete(account)
    }

    // MARK: Filling

    enum FillResult: String {
        case filled, usernameOnly, nothing
    }

    /// The account's details, typed into the page's login form, if the page is still the
    /// account's site. Runs in Feather's content world with the values passed as arguments.
    func fill(_ account: Account, in webView: WKWebView) async -> FillResult {
        guard let url = webView.url, url.scheme?.lowercased() == "https", url.host?.lowercased() == account.host,
              let password = store.password(for: account) else { return .nothing }
        let result = try? await webView.callAsyncJavaScript(Self.fillScript,
                                                            arguments: ["host": account.host, "username": account.username,
                                                                        "password": password],
                                                            in: nil, contentWorld: Self.world)
        return (result as? String).flatMap(FillResult.init(rawValue:)) ?? .nothing
    }

    /// Saved accounts for the page in `webView`, if it's a page passwords may be filled on.
    func accounts(for webView: WKWebView?) -> [Account] {
        guard let url = webView?.url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return [] }
        if let cached = cache[host] { return cached }
        let found = store.accounts(for: host)
        cache[host] = found
        return found
    }

    // MARK: Scripts

    /// Shared by both scripts: which inputs hold the username and password.
    private static let fieldFinders = #"""
        const shown = el => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
        const passwordFields = scope => [...scope.querySelectorAll('input[type="password"]')];
        const usernameField = (password, scope) => {
            const inputs = [...(password?.form || scope).querySelectorAll('input')];
            const named = inputs.find(i => /\busername\b/i.test(i.autocomplete || '') && i.type !== 'password');
            if (named) return named;
            const index = password ? inputs.indexOf(password) : inputs.length;
            for (let i = index - 1; i >= 0; i--) {
                if (['text', 'email', 'tel'].includes((inputs[i].type || 'text').toLowerCase()) && shown(inputs[i])) return inputs[i];
            }
            return null;
        };
        """#

    /// Reports a login when a form with a filled password is submitted, its button clicked,
    /// or Enter pressed in the password field. Sign-up and change forms report the new password.
    static let formScript = "(() => {\n" + fieldFinders + #"""
        const handler = window.webkit.messageHandlers.featherPasswords;
        let last = '';
        const report = origin => {
            const scope = origin?.form || document;
            const filled = passwordFields(scope).filter(f => f.value);
            if (!filled.length) return;
            const password = filled.length >= 2 ? filled[filled.length - 1] : filled[0];
            const username = usernameField(filled[0], scope)?.value || '';
            const key = username + '\n' + password.value;
            if (key === last) return;
            last = key;
            handler.postMessage({ username, password: password.value });
        };
        document.addEventListener('submit', event => report(event.target.querySelector('input[type="password"]') || event.target), true);
        // Submit buttons, or buttons named like a login: not "show password" toggles.
        const loginButton = /로그인|로그 인|다음|계속|확인|log ?in|sign ?in|next|continue|submit/i;
        document.addEventListener('click', event => {
            const button = event.target.closest?.('button, input[type="submit"], input[type="button"], [role="button"]');
            if (!button) return;
            const submits = button.type === 'submit' && (button.tagName === 'BUTTON' || button.tagName === 'INPUT');
            const label = button.innerText || button.value || button.getAttribute('aria-label') || '';
            if (submits || loginButton.test(label)) report(button);
        }, true);
        document.addEventListener('keydown', event => {
            if (event.key === 'Enter' && event.target?.type === 'password') report(event.target);
        }, true);
    })();
    """#

    static let fillScript = fieldFinders + #"""
        if (location.protocol !== 'https:' || location.hostname.toLowerCase() !== host) return 'nothing';
        const set = (input, value) => {
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, value);
            input.dispatchEvent(new Event('input', { bubbles: true }));
            input.dispatchEvent(new Event('change', { bubbles: true }));
        };
        const field = passwordFields(document).find(shown);
        // Without a password field (the first step of a two-step login), only a field that is
        // clearly the login name, never just any text box such as a search field.
        const user = field ? usernameField(field, document)
            : [...document.querySelectorAll('input')].find(i => shown(i) && (/\busername\b/i.test(i.autocomplete || '') || i.type === 'email'));
        if (user && username) set(user, username);
        if (!field) return user && username ? 'usernameOnly' : 'nothing';
        set(field, password);
        return 'filled';
        """#
}

/// The 계정 menu's list of saved accounts, rebuilt each time it opens. Each entry opens the
/// site; holding ⌥ turns it into "삭제".
@MainActor
final class AccountsMenu: NSObject, NSMenuDelegate {
    static let listTag = 8_000

    private let manager: PasswordManager

    init(manager: PasswordManager) {
        self.manager = manager
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        while let last = menu.items.last, last.tag >= Self.listTag { menu.removeItem(last) }
        Self.items(for: manager.store.allAccounts()).forEach(menu.addItem)
    }

    static func items(for accounts: [Account]) -> [NSMenuItem] {
        let header = NSMenuItem(title: accounts.isEmpty ? "저장된 계정 없음" : "저장된 계정", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.tag = listTag
        return [header] + accounts.flatMap { account -> [NSMenuItem] in
            let name = "\(account.host) — \(account.username.isEmpty ? "(아이디 없음)" : account.username)"
            let open = NSMenuItem(title: name, action: #selector(BrowserWindowController.openAccountSite(_:)), keyEquivalent: "")
            open.representedObject = account
            open.keyEquivalentModifierMask = []
            open.tag = listTag
            let delete = NSMenuItem(title: "삭제: \(name)", action: #selector(BrowserWindowController.deleteAccount(_:)), keyEquivalent: "")
            delete.representedObject = account
            delete.isAlternate = true
            delete.keyEquivalentModifierMask = .option
            delete.tag = listTag
            return [open, delete]
        }
    }
}
