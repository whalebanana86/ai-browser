import WebKit

/// What every web view shares: one cookie/cache store (one Networking process), one
/// compiled set of tracker rules, and a user agent identical to Safari's, so Feather
/// doesn't stand out to fingerprinting scripts.
@MainActor
final class WebKitEnvironment {
    static let shared = WebKitEnvironment()

    let dataStore = WKWebsiteDataStore.default()
    private let contentController = WKUserContentController()
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

    func makeWebView(configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        let webView = BrowserWebView(frame: .zero, configuration: configuration ?? makeConfiguration())
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.autoresizingMask = [.width, .height]
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        return webView
    }

    private func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.userContentController = contentController
        config.applicationNameForUserAgent = applicationName
        config.mediaTypesRequiringUserActionForPlayback = .audio
        config.upgradeKnownHostsToHTTPS = true
        config.preferences.isElementFullscreenEnabled = true
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
        super.willOpenMenu(menu, with: event)
    }
}
