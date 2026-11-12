import WebKit

@MainActor
protocol TabDelegate: AnyObject {
    func tabDidChange(_ tab: Tab)
    func tabDidFinishLoading(_ tab: Tab)
    func tab(_ tab: Tab, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction) -> WKWebView?
    func tab(_ tab: Tab, openInBackground url: URL)
    func tabDidRequestClose(_ tab: Tab)
}

/// One browser tab. A tab is *live* while it has a web view, and *suspended* once
/// `suspend()` releases the web view (and the web process behind it), keeping only its URL,
/// title and WebKit's interaction state: back/forward list and scroll position, a few KB.
@MainActor
final class Tab: NSObject {
    struct Timing {
        /// First contentful paint, from the page's Paint Timing API.
        var firstPaint: Double?
        /// From navigation start to the load event.
        var loaded: Double
    }

    weak var delegate: TabDelegate?
    private(set) var webView: WKWebView?
    private(set) var url: URL?
    private(set) var title = ""
    private(set) var timing: Timing?
    var lastActive = Date()
    /// Called once the page finished (or failed) loading and `timing` is final.
    var onLoadFinished: ((Tab) -> Void)?

    private var savedState: Any?
    private var observations: [NSKeyValueObservation] = []
    private var navigationStart: CFAbsoluteTime = 0
    private var autoUpgradedURL: URL?
    private var lastStrippedURL: URL?
    private var errorURL: URL?
    private var errorNavigation: WKNavigation?

    /// A secret tab's own in-memory cookie and cache store, shared only with the tabs and
    /// windows it opens. Kept while the tab is suspended, so its logins survive; dropped with
    /// the tab, which discards everything the site stored. Nil for ordinary tabs.
    let privateStore: WKWebsiteDataStore?
    var isPrivate: Bool { privateStore != nil }

    var isLive: Bool { webView != nil }
    var isBlank: Bool { webView == nil && url == nil }
    var isLoading: Bool { webView?.isLoading ?? false }
    var progress: Double { webView?.estimatedProgress ?? 0 }
    var canGoBack: Bool { webView?.canGoBack ?? false }
    var canGoForward: Bool { webView?.canGoForward ?? false }
    /// The address to show: on an error page, the one that failed.
    var displayURL: URL? { errorURL ?? url }
    var displayTitle: String {
        if !title.isEmpty { return title }
        guard let url = displayURL else { return isPrivate ? "시크릿 탭" : "새 탭" }
        return url.host ?? URLTools.displayString(url)
    }

    init(url: URL? = nil, title: String = "", upgraded: Bool = false, privateStore: WKWebsiteDataStore? = nil) {
        self.url = url
        self.title = title
        self.autoUpgradedURL = upgraded ? url : nil
        self.privateStore = privateStore
        super.init()
    }

    /// Adopts a web view WebKit asked for (window.open, target=_blank). One opened from a
    /// secret tab comes with that tab's store and stays secret.
    init(webView: WKWebView) {
        let store = webView.configuration.websiteDataStore
        privateStore = store.isPersistent ? nil : store
        super.init()
        attach(webView)
    }

    // MARK: - Lifecycle

    /// The live web view, created (and restored or loaded) if the tab is suspended.
    @discardableResult
    func wake() -> WKWebView {
        if let webView { return webView }
        let webView = WebKitEnvironment.shared.makeWebView(dataStore: privateStore)
        attach(webView)
        if let savedState {
            webView.interactionState = savedState
        } else if let url {
            open(url, in: webView)
        }
        savedState = nil
        return webView
    }

    func suspend() {
        guard let webView else { return }
        if errorURL == nil, webView.backForwardList.currentItem != nil {
            savedState = webView.interactionState
        }
        url = errorURL ?? webView.url ?? url
        if let pageTitle = webView.title, !pageTitle.isEmpty { title = pageTitle }
        errorURL = nil
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
        delegate?.tabDidChange(self)
    }

    /// Called when another tab is selected. WebKit keeps recently left pages alive for instant
    /// Back (in this tab's process, or in a whole extra process after a cross-site navigation);
    /// a background tab doesn't need that, and on heavy sites it can double the tab's memory.
    /// (WebKit SPI; does nothing if unavailable.)
    func didMoveToBackground() {
        let clear = NSSelectorFromString("_clearBackForwardCache")
        if let webView, webView.responds(to: clear) { webView.perform(clear) }
    }

    // MARK: - Navigation

    func load(_ url: URL, upgraded: Bool = false) {
        autoUpgradedURL = upgraded ? url : nil
        self.url = url
        if let webView {
            open(url, in: webView)
        } else {
            savedState = nil
            wake()
        }
    }

    func reload(fromOrigin: Bool = false) {
        guard let webView else { return }
        // Error pages are local HTML: retry the real address instead.
        if let target = errorURL ?? (webView.url == nil ? url : nil) {
            open(target, in: webView)
        } else if fromOrigin {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
    }

    /// True while the page plays sound or uses the camera or microphone. Muted autoplay
    /// videos don't count.
    func isUsingMedia() async -> Bool {
        guard let webView else { return false }
        if webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none { return true }
        let audible = NSSelectorFromString("_isPlayingAudio")  // WebKit SPI behind Safari's speaker icon
        if webView.responds(to: audible) { return (webView.value(forKey: "_isPlayingAudio") as? Bool) ?? false }
        return await webView.requestMediaPlaybackState() == .playing
    }

    /// True while the page is in the middle of something a reload would throw away: a login
    /// (a visible password or one-time-code field) or text the user typed. Only whether a field
    /// changed is checked, never what's in it, and in a world page scripts can't reach.
    func hasWorkInProgress() async -> Bool {
        guard let webView else { return false }
        let result = try? await webView.callAsyncJavaScript(Self.workInProgressScript, arguments: [:], in: nil, contentWorld: .defaultClient)
        return result as? Bool ?? false
    }

    static let workInProgressScript = #"""
        const shown = el => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
        const codeName = /otp|one.?time|code|verif|pin\b|2fa|mfa|totp|passcode|인증|보안.?코드/i;
        const fields = [...document.querySelectorAll('input, textarea')].filter(shown);
        const describes = f => [f.name, f.id, f.placeholder, f.getAttribute('aria-label'), f.autocomplete].join(' ');
        const login = fields.some(f => f.type === 'password' || /one-time-code/.test(f.autocomplete || '')
            || (['text', 'tel', 'number', ''].includes(f.type) && codeName.test(describes(f))));
        const typed = fields.some(f => f.type !== 'search' && f.type !== 'hidden' && f.value !== f.defaultValue);
        return login || typed;
        """#

    private func open(_ url: URL, in webView: WKWebView) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    private func attach(_ webView: WKWebView) {
        self.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let sync: (WKWebView) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.syncFromWebView() } }
        observations = [
            webView.observe(\.title) { view, _ in sync(view) },
            webView.observe(\.url) { view, _ in sync(view) },
            webView.observe(\.estimatedProgress) { view, _ in sync(view) },
            webView.observe(\.isLoading) { view, _ in sync(view) },
            webView.observe(\.canGoBack) { view, _ in sync(view) },
            webView.observe(\.canGoForward) { view, _ in sync(view) },
        ]
    }

    private func syncFromWebView() {
        guard let webView else { return }
        if let current = webView.url { url = current }
        title = webView.title ?? title
        delegate?.tabDidChange(self)
    }

    private func finishLoad(with timing: Timing?) {
        self.timing = timing
        delegate?.tabDidChange(self)
        delegate?.tabDidFinishLoading(self)
        onLoadFinished?(self)
    }

    private static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript"]

    /// Fast pages can fire `load` before their first paint, so wait briefly for the entry.
    private static let firstPaintScript = """
        const read = () => (performance.getEntriesByName('first-contentful-paint')[0] || {}).startTime || 0;
        if (read()) return read();
        return await new Promise(resolve => {
            const observer = new PerformanceObserver(() => { if (read()) { observer.disconnect(); resolve(read()); } });
            try { observer.observe({ type: 'paint', buffered: true }); } catch (e) {}
            setTimeout(() => { observer.disconnect(); resolve(read()); }, 1500);
        });
        """

    private static func errorPage(for url: URL, message: String) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        return """
        <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <title>\(escape(url.host ?? "오류"))</title>
        <body style="font:15px -apple-system,sans-serif;max-width:520px;margin:18vh auto;padding:0 24px;line-height:1.5">
        <h2 style="font-weight:600">페이지를 열 수 없습니다</h2>
        <p style="opacity:.75">\(escape(message))</p>
        <p style="opacity:.5;word-break:break-all">\(escape(url.absoluteString))</p>
        <p style="opacity:.5">⌘R 을 눌러 다시 시도하세요.</p>
        """
    }
}

// MARK: - WKNavigationDelegate

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let target = action.request.url else { return decisionHandler(.allow) }

        // ⌘-click or middle-click on a link opens it in a background tab.
        if action.navigationType == .linkActivated,
           action.modifierFlags.contains(.command) || [2, 4].contains(action.buttonNumber) {
            delegate?.tab(self, openInBackground: target)
            return decisionHandler(.cancel)
        }

        // Drop click-tracking parameters from page loads. Remembering the last stripped URL
        // stops a server that redirects back to the tracked URL from looping forever.
        if action.targetFrame?.isMainFrame == true,
           action.navigationType != .backForward, action.navigationType != .reload,
           (action.request.httpMethod ?? "GET") == "GET", target != lastStrippedURL,
           let clean = URLTools.strippingTrackingParameters(target) {
            lastStrippedURL = target
            decisionHandler(.cancel)
            webView.load(URLRequest(url: clean))
            return
        }

        // mailto:, tel:, app links… hand off to macOS; ask first unless the user clicked.
        if let scheme = target.scheme?.lowercased(), !Self.webSchemes.contains(scheme) {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated {
                NSWorkspace.shared.open(target)
            } else if let window = webView.window {
                let alert = NSAlert()
                alert.messageText = "외부 앱에서 열까요?"
                alert.informativeText = target.absoluteString
                alert.addButton(withTitle: "열기")
                alert.addButton(withTitle: "취소")
                alert.beginSheetModal(for: window) { response in
                    if response == .alertFirstButtonReturn { NSWorkspace.shared.open(target) }
                }
            }
            return
        }

        decisionHandler(action.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let isAttachment = response.isForMainFrame && disposition.lowercased().hasPrefix("attachment")
        decisionHandler(!response.canShowMIMEType || isAttachment ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        Downloads.shared.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        Downloads.shared.track(download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard navigation !== errorNavigation else { return }
        errorURL = nil
        errorNavigation = nil
        timing = nil
        navigationStart = CFAbsoluteTimeGetCurrent()
        delegate?.tabDidChange(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation !== errorNavigation else { return }
        let loaded = CFAbsoluteTimeGetCurrent() - navigationStart
        webView.callAsyncJavaScript(Self.firstPaintScript, in: nil, in: .defaultClient) { [weak self] result in
            var firstPaint: Double?
            if case .success(let value) = result, let ms = value as? Double, ms > 0 { firstPaint = ms / 1000 }
            self?.finishLoad(with: Timing(firstPaint: firstPaint, loaded: loaded))
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        let interrupted = (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            || (nsError.domain == "WebKitErrorDomain" && [102, 204].contains(nsError.code))
        guard !interrupted, let failed = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? url else { return }

        // We guessed https for a bare host; the site may only speak http.
        if let upgraded = autoUpgradedURL, failed.scheme == "https", failed.host == upgraded.host,
           var components = URLComponents(url: failed, resolvingAgainstBaseURL: false) {
            autoUpgradedURL = nil
            components.scheme = "http"
            if let http = components.url { return open(http, in: webView) }
        }

        errorURL = failed
        errorNavigation = webView.loadHTMLString(Self.errorPage(for: failed, message: nsError.localizedDescription), baseURL: failed)
        finishLoad(with: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation !== errorNavigation else { return }
        finishLoad(with: nil)
    }

    /// The page's process crashed or was killed under memory pressure: reload it if it's on
    /// screen, otherwise suspend so it reloads when selected.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView.window != nil { reload() } else { suspend() }
    }
}

// MARK: - WKUIDelegate

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        delegate?.tab(self, createWebViewWith: configuration, for: action)
    }

    func webViewDidClose(_ webView: WKWebView) {
        delegate?.tabDidRequestClose(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        guard let window = webView.window else { return completionHandler() }
        Self.alert(message, from: frame, buttons: ["확인"]).beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        guard let window = webView.window else { return completionHandler(false) }
        Self.alert(message, from: frame, buttons: ["확인", "취소"]).beginSheetModal(for: window) {
            completionHandler($0 == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        guard let window = webView.window else { return completionHandler(nil) }
        let alert = Self.alert(prompt, from: frame, buttons: ["확인", "취소"])
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) {
            completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        let finish: (NSApplication.ModalResponse) -> Void = { completionHandler($0 == .OK ? panel.urls : nil) }
        if let window = webView.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    private static func alert(_ message: String, from frame: WKFrameInfo, buttons: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "웹 페이지" : frame.securityOrigin.host
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert
    }
}
