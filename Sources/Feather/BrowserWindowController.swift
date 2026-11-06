import AppKit
import WebKit

private extension NSToolbarItem.Identifier {
    static let back = Self("back")
    static let forward = Self("forward")
    static let reload = Self("reload")
    static let address = Self("address")
    static let status = Self("status")
}

/// The browser window: toolbar, tab strip and the active tab's page. Only the active tab's
/// web view is ever in the view hierarchy; WebKit throttles the rest, and `MemoryGovernor`
/// suspends them when memory is needed.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation, TabDelegate, TabHost {
    private(set) var tabs: [Tab] = []
    private var activeIndex = -1
    var activeTab: Tab? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }
    let governor = MemoryGovernor()
    /// Off in benchmark runs so they don't overwrite the user's open tabs.
    var persistsSession = true

    private var closedTabs: [Tab] = []
    private let tabStrip = TabStripView(frame: NSRect(x: 0, y: 0, width: 800, height: 34))
    private let addressField = AddressField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let content = NSView()
    private let placeholder = PlaceholderView()
    private let progressBar = ProgressBar()
    private let findBar = FindBar(frame: NSRect(x: 0, y: 0, width: 300, height: 36))
    private var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private var memory: MemoryMeter.Sample?
    private var flashText: String?
    private var flashGeneration = 0
    private var saveScheduled = false

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.minSize = NSSize(width: 560, height: 360)
        super.init(window: window)
        window.delegate = self
        buildToolbar(in: window)
        buildContent(in: window)
        if !window.setFrameUsingName("FeatherBrowser") { window.center() }
        window.setFrameAutosaveName("FeatherBrowser")

        governor.host = self
        governor.onSample = { [weak self] sample in
            self?.memory = sample
            self?.updateStatus()
            self?.reloadTabStrip()
        }
        governor.start()
        Downloads.shared.onFinish = { [weak self] file in self?.flash("다운로드 완료 · \(file.lastPathComponent)") }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Tabs

    @discardableResult
    func openTab(_ url: URL?, upgraded: Bool = false, activate: Bool = true, after opener: Tab? = nil) -> Tab {
        let tab = Tab(url: url, upgraded: upgraded)
        insert(tab, after: opener, activate: activate)
        if !activate, url != nil { tab.wake() }
        return tab
    }

    private func insert(_ tab: Tab, after opener: Tab?, activate: Bool) {
        tab.delegate = self
        let index = opener.flatMap { opener in tabs.firstIndex { $0 === opener } }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: index)
        if activate {
            selectTab(at: index)
        } else {
            if index <= activeIndex { activeIndex += 1 }
            reloadTabStrip()
        }
        governor.setNeedsCheck()
        scheduleSave()
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        if let previous = activeTab, previous !== tabs[index] {
            previous.lastActive = Date()
            previous.webView?.removeFromSuperview()
            previous.didMoveToBackground()
        }
        activeIndex = index
        tabs[index].lastActive = Date()
        findBar.isHidden = true
        showActiveTab()
        reloadTabStrip()
        updateToolbar()
        updateStatus()
        governor.setNeedsCheck()
    }

    /// Puts the active tab's web view on screen, waking the tab if it was suspended.
    private func showActiveTab() {
        guard let tab = activeTab else { return }
        if tab.isBlank {
            placeholder.isHidden = false
            window?.makeFirstResponder(addressField)
            return
        }
        let webView = tab.wake()
        if webView.superview !== content {
            webView.frame = content.bounds
            content.addSubview(webView, positioned: .below, relativeTo: progressBar)
        }
        placeholder.isHidden = true
        if window?.firstResponder !== addressField.currentEditor() { window?.makeFirstResponder(webView) }
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs.remove(at: index)
        tab.delegate = nil
        tab.suspend()
        if !tab.isBlank {
            closedTabs.append(tab)
            if closedTabs.count > 20 { closedTabs.removeFirst() }
        }
        if tabs.isEmpty {
            activeIndex = -1
            openTab(nil)
        } else if index == activeIndex {
            activeIndex = -1
            selectTab(at: min(index, tabs.count - 1))
        } else {
            if index < activeIndex { activeIndex -= 1 }
            reloadTabStrip()
        }
        scheduleSave()
    }

    private func navigate(to text: String) {
        guard let resolved = URLTools.resolve(text) else { return }
        if let tab = activeTab {
            tab.load(resolved.url, upgraded: resolved.upgraded)
            showActiveTab()
        } else {
            openTab(resolved.url, upgraded: resolved.upgraded)
        }
        focusPage()
    }

    private func focusPage() {
        if let webView = activeTab?.webView { window?.makeFirstResponder(webView) }
    }

    private func cycleTabs(by step: Int) {
        guard !tabs.isEmpty else { return }
        selectTab(at: (activeIndex + step + tabs.count) % tabs.count)
    }

    // MARK: - TabDelegate

    func tabDidChange(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabStrip.update(at: index, with: tab)
        if tab === activeTab {
            updateToolbar()
            updateStatus()
        }
        scheduleSave()
    }

    func tabDidFinishLoading(_ tab: Tab) {
        governor.setNeedsCheck()
    }

    func tab(_ tab: Tab, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction) -> WKWebView? {
        let webView = WebKitEnvironment.shared.makeWebView(configuration: configuration)
        let background = action.modifierFlags.contains(.command) || [2, 4].contains(action.buttonNumber)
        insert(Tab(webView: webView), after: tab, activate: !background)
        return webView
    }

    func tab(_ tab: Tab, openInBackground url: URL) {
        openTab(url, activate: false, after: tab)
    }

    func tabDidRequestClose(_ tab: Tab) {
        if let index = tabs.firstIndex(where: { $0 === tab }) { closeTab(at: index) }
    }

    // MARK: - Chrome

    private func buildToolbar(in window: NSWindow) {
        let toolbar = NSToolbar(identifier: "FeatherToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.back, .forward, .reload, .address, .status]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.autovalidates = false
        switch itemIdentifier {
        case .back: configureButton(item, symbol: "chevron.left", label: "뒤로", action: #selector(goBackAction(_:)))
        case .forward: configureButton(item, symbol: "chevron.right", label: "앞으로", action: #selector(goForwardAction(_:)))
        case .reload: configureButton(item, symbol: "arrow.clockwise", label: "새로고침", action: #selector(reloadOrStop(_:)))
        case .address:
            item.label = "주소"
            item.view = addressField
            // A min/max range makes the toolbar treat the item as flexible and stretch it.
            addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
            addressField.widthAnchor.constraint(lessThanOrEqualToConstant: 4000).isActive = true
        case .status:
            item.label = "상태"
            item.view = statusLabel
            statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            statusLabel.alignment = .right
            statusLabel.lineBreakMode = .byTruncatingHead
            statusLabel.widthAnchor.constraint(equalToConstant: 140).isActive = true
        default:
            return nil
        }
        toolbarItems[itemIdentifier] = item
        return item
    }

    private func configureButton(_ item: NSToolbarItem, symbol: String, label: String, action: Selector) {
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.isBordered = true
        item.target = self
        item.action = action
    }

    private func buildContent(in window: NSWindow) {
        window.contentView = content
        placeholder.frame = content.bounds
        placeholder.autoresizingMask = [.width, .height]
        content.addSubview(placeholder)
        progressBar.frame = NSRect(x: 0, y: content.bounds.height - 2, width: content.bounds.width, height: 2)
        progressBar.autoresizingMask = [.width, .minYMargin]
        progressBar.isHidden = true
        content.addSubview(progressBar)
        findBar.frame.origin = NSPoint(x: content.bounds.width - findBar.frame.width - 16,
                                       y: content.bounds.height - findBar.frame.height - 12)
        findBar.autoresizingMask = [.minXMargin, .minYMargin]
        findBar.isHidden = true
        content.addSubview(findBar)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .bottom
        accessory.view = tabStrip
        window.addTitlebarAccessoryViewController(accessory)

        tabStrip.onSelect = { [weak self] in self?.selectTab(at: $0) }
        tabStrip.onClose = { [weak self] in self?.closeTab(at: $0) }
        tabStrip.onNewTab = { [weak self] in self?.openTab(nil) }
        addressField.onSubmit = { [weak self] in self?.navigate(to: $0) }
        addressField.onCancel = { [weak self] in
            self?.updateAddressField(force: true)
            self?.focusPage()
        }
        addressField.onEndEditing = { [weak self] in self?.updateAddressField(force: true) }
        findBar.onFind = { [weak self] text, backwards in self?.find(text, backwards: backwards) }
        findBar.onClose = { [weak self] in
            self?.findBar.isHidden = true
            self?.focusPage()
        }
    }

    private func reloadTabStrip() {
        tabStrip.setTabs(tabs, active: activeIndex)
    }

    private func updateToolbar() {
        let tab = activeTab
        let loading = tab?.isLoading ?? false
        toolbarItems[.back]?.isEnabled = tab?.canGoBack ?? false
        toolbarItems[.forward]?.isEnabled = tab?.canGoForward ?? false
        if let reload = toolbarItems[.reload] {
            reload.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise", accessibilityDescription: nil)
            reload.toolTip = loading ? "중단" : "새로고침 (⌘R)"
        }
        progressBar.isHidden = !loading
        progressBar.progress = tab?.progress ?? 0
        updateAddressField()
        window?.title = tab?.displayTitle ?? "Feather"
    }

    private func updateAddressField(force: Bool = false) {
        guard force || addressField.currentEditor() == nil else { return }
        addressField.stringValue = URLTools.displayString(activeTab?.displayURL)
    }

    private func updateStatus() {
        var parts: [String] = []
        var details: [String] = []
        if let tab = activeTab, let timing = tab.timing, !tab.isLoading {
            let shown = timing.firstPaint ?? timing.loaded
            parts.append(String(format: "%.2f초", shown))
            details.append(String(format: "첫 화면 표시 %.2f초 · 전체 로드 %.2f초", shown, timing.loaded))
        }
        if let memory {
            parts.append(Self.format(memory.total))
            let live = tabs.filter(\.isLive).count
            details.append("메모리 \(Self.format(memory.total)) — 앱과 WebKit 프로세스 \(memory.processCount)개 합계")
            details.append("탭 \(tabs.count)개 중 \(live)개 실행 중 · 나머지는 일시 중단되어 메모리를 쓰지 않음")
        }
        statusLabel.stringValue = flashText ?? parts.joined(separator: " · ")
        statusLabel.toolTip = details.joined(separator: "\n")
        statusLabel.textColor = (memory?.total ?? 0) > Settings.memoryBudget ? .systemOrange : .secondaryLabelColor
    }

    private func flash(_ text: String) {
        flashText = text
        flashGeneration += 1
        let generation = flashGeneration
        updateStatus()
        onMain(after: 3) { [weak self] in
            guard let self, self.flashGeneration == generation else { return }
            self.flashText = nil
            self.updateStatus()
        }
    }

    static func format(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        return megabytes < 1024 ? String(format: "%.0f MB", megabytes) : String(format: "%.2f GB", megabytes / 1024)
    }

    // MARK: - Find

    private func showFindBar() {
        guard activeTab?.webView != nil else { return }
        findBar.isHidden = false
        window?.makeFirstResponder(findBar.field)
    }

    private func find(_ text: String, backwards: Bool) {
        guard let webView = activeTab?.webView, !text.isEmpty else { return findBar.setFound(true) }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        webView.find(text, configuration: configuration) { [weak self] result in
            self?.findBar.setFound(result.matchFound)
        }
    }

    private func findAgain(backwards: Bool) {
        if findBar.isHidden { showFindBar() } else { find(findBar.field.stringValue, backwards: backwards) }
    }

    // MARK: - Actions

    @objc func newTabAction(_ sender: Any?) { openTab(nil) }
    @objc func closeTabAction(_ sender: Any?) { closeTab(at: activeIndex) }
    @objc func focusAddressBar(_ sender: Any?) { window?.makeFirstResponder(addressField) }
    @objc func reloadAction(_ sender: Any?) { activeTab?.reload() }
    @objc func reloadFromOriginAction(_ sender: Any?) { activeTab?.reload(fromOrigin: true) }
    @objc func goBackAction(_ sender: Any?) { activeTab?.webView?.goBack() }
    @objc func goForwardAction(_ sender: Any?) { activeTab?.webView?.goForward() }
    @objc func zoomInAction(_ sender: Any?) { zoom(by: 0.1) }
    @objc func zoomOutAction(_ sender: Any?) { zoom(by: -0.1) }
    @objc func actualSizeAction(_ sender: Any?) { activeTab?.webView?.pageZoom = 1 }
    @objc func findAction(_ sender: Any?) { showFindBar() }
    @objc func findNextAction(_ sender: Any?) { findAgain(backwards: false) }
    @objc func findPreviousAction(_ sender: Any?) { findAgain(backwards: true) }
    @objc func nextTabAction(_ sender: Any?) { cycleTabs(by: 1) }
    @objc func previousTabAction(_ sender: Any?) { cycleTabs(by: -1) }
    @objc func selectTabByNumber(_ sender: NSMenuItem) { selectTab(at: sender.tag == 9 ? tabs.count - 1 : sender.tag - 1) }

    @objc func reloadOrStop(_ sender: Any?) {
        guard let tab = activeTab else { return }
        if tab.isLoading { tab.webView?.stopLoading() } else { tab.reload() }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        guard let tab = closedTabs.popLast() else { return }
        insert(tab, after: activeTab, activate: true)
    }

    @objc func clearBrowsingData(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "쿠키와 캐시를 모두 지울까요?"
        alert.informativeText = "모든 웹사이트에서 로그아웃되고, 닫은 탭 목록도 지워집니다."
        alert.addButton(withTitle: "지우기")
        alert.addButton(withTitle: "취소")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.closedTabs.removeAll()
            WebKitEnvironment.shared.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                         modifiedSince: .distantPast) {
                self?.flash("쿠키와 캐시를 지웠습니다")
            }
        }
    }

    private func zoom(by delta: CGFloat) {
        guard let webView = activeTab?.webView else { return }
        webView.pageZoom = min(3, max(0.3, webView.pageZoom + delta))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBackAction(_:)): return activeTab?.canGoBack ?? false
        case #selector(goForwardAction(_:)): return activeTab?.canGoForward ?? false
        case #selector(reopenClosedTab(_:)): return !closedTabs.isEmpty
        case #selector(reloadAction(_:)), #selector(reloadFromOriginAction(_:)), #selector(findAction(_:)),
             #selector(findNextAction(_:)), #selector(findPreviousAction(_:)), #selector(zoomInAction(_:)),
             #selector(zoomOutAction(_:)), #selector(actualSizeAction(_:)):
            return activeTab?.webView != nil
        case #selector(selectTabByNumber(_:)): return item.tag == 9 || item.tag <= tabs.count
        default: return true
        }
    }

    func windowWillClose(_ notification: Notification) { saveSession() }

    // MARK: - Session
    // Only the open tabs' addresses and titles are kept, locally, so they come back after a
    // restart. There is no browsing history.

    private struct Session: Codable {
        struct Entry: Codable {
            var url: URL
            var title: String
        }
        var tabs: [Entry]
        var active: Int
    }

    private static var sessionFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Feather/session.json")
    }

    /// Restores last session's tabs, all suspended except the one that was active.
    func restoreSession() -> Bool {
        guard let data = try? Data(contentsOf: Self.sessionFile),
              let session = try? JSONDecoder().decode(Session.self, from: data), !session.tabs.isEmpty else { return false }
        for entry in session.tabs {
            let tab = Tab(url: entry.url, title: entry.title)
            tab.delegate = self
            tabs.append(tab)
        }
        selectTab(at: min(max(session.active, 0), tabs.count - 1))
        return true
    }

    func saveSession() {
        guard persistsSession else { return }
        var entries: [Session.Entry] = []
        var active = 0
        for (index, tab) in tabs.enumerated() {
            guard let url = tab.displayURL else { continue }
            if index == activeIndex { active = entries.count }
            entries.append(.init(url: url, title: tab.title))
        }
        guard let data = try? JSONEncoder().encode(Session(tabs: entries, active: active)) else { return }
        let file = Self.sessionFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func scheduleSave() {
        guard persistsSession, !saveScheduled else { return }
        saveScheduled = true
        onMain(after: 2) { [weak self] in
            self?.saveScheduled = false
            self?.saveSession()
        }
    }
}
