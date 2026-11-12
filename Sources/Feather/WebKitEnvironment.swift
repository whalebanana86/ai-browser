import WebKit

/// What every web view shares: one cookie/cache store (one Networking process), one
/// compiled set of tracker rules, the login-form script, and a user agent identical to
/// Safari's, so Feather doesn't stand out to fingerprinting scripts.
@MainActor
final class WebKitEnvironment {
    static let shared = WebKitEnvironment()

    let dataStore = WKWebsiteDataStore.default()
    private let contentController: WKUserContentController = {
        let controller = WKUserContentController()
        PasswordManager.shared.install(in: controller)
        return controller
    }()
    private let applicationName: String = {
        let safari = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        let version = safari?["CFBundleShortVersionString"] as? String ?? "26.0"
        return "Version/\(version) Safari/605.1.15"
    }()

    /// Loads the tracker and ad rules; web views must not be created before `completion` runs,
    /// or their first page would load unprotected.
    func prepare(_ completion: @escaping @MainActor () -> Void) {
        guard Settings.blocksTrackers || Settings.blocksAds else { return completion() }
        ContentBlocker.load { [contentController] list in
            MainActor.assumeIsolated {
                if let list { contentController.add(list) }
                completion()
            }
        }
    }

    /// `dataStore` is a secret tab's own store; ordinary tabs share `dataStore`.
    func makeWebView(configuration: WKWebViewConfiguration? = nil, dataStore: WKWebsiteDataStore? = nil) -> WKWebView {
        let webView = BrowserWebView(frame: .zero, configuration: configuration ?? makeConfiguration(dataStore: dataStore ?? self.dataStore))
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.autoresizingMask = [.width, .height]
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        return webView
    }

    private func makeConfiguration(dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.userContentController = contentController
        config.applicationNameForUserAgent = applicationName
        config.mediaTypesRequiringUserActionForPlayback = .audio
        config.upgradeKnownHostsToHTTPS = true
        config.preferences.isElementFullscreenEnabled = true
        // No grey inline predictions in pages' text inputs either.
        if #available(macOS 14, *) { config.allowsInlinePredictions = false }
        return config
    }
}

/// Retitles WebKit's "Open … in New Window" menu items: Feather opens them as tabs.
final class BrowserWebView: WKWebView {
    private static let newTabTitles = [
        "WKMenuItemIdentifierOpenLinkInNewWindow": "새 탭에서 링크 열기",
        "WKMenuItemIdentifierOpenImageInNewWindow": "새 탭에서 이미지 열기",
        "WKMenuItemIdentifierOpenMediaInNewWindow": "새 탭에서 동영상 열기",
        "WKMenuItemIdentifierOpenFrameInNewWindow": "새 탭에서 프레임 열기",
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        for item in menu.items {
            if let id = item.identifier?.rawValue, let title = Self.newTabTitles[id] { item.title = title }
        }
        // Translate from the page's own menu; the window sets the title (번역 / 원문 보기).
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "이 페이지 번역", action: #selector(BrowserWindowController.toggleTranslationAction(_:)), keyEquivalent: ""))
        super.willOpenMenu(menu, with: event)
    }
}
