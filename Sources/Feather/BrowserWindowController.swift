import AppKit
import WebKit

private extension NSToolbarItem.Identifier {
    static let back = Self("back")
    static let forward = Self("forward")
    static let reload = Self("reload")
    static let address = Self("address")
    static let bookmark = Self("bookmark")
    static let password = Self("password")
    static let translate = Self("translate")
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
    /// Tests swap in a store backed by a temporary file.
    var bookmarks = BookmarkStore.shared
    /// Tests swap in one backed by a fake model.
    lazy var translator = makeTranslator { prompt, tokens, limit in
        try await TranslatorProcess.shared.translate(prompt: prompt, maxTokens: tokens, timeLimit: limit)
    }

    func makeTranslator(_ translate: @escaping PageTranslator.Translate) -> PageTranslator {
        let translator = PageTranslator(translate: translate)
        translator.onProgress = { [weak self] webView, done, total in
            guard self?.activeTab?.webView === webView else { return }
            self?.flash("번역 중 \(done)/\(total)")
        }
        translator.onStopped = { [weak self] _, reason in
            self?.flash("번역을 껐습니다 · \(reason)")
            self?.updateToolbar()
        }
        return translator
    }

    /// Tests swap in a manager with a throwaway store.
    var passwords = PasswordManager.shared {
        didSet { connectPasswords() }
    }

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
        NotificationCenter.default.addObserver(forName: BookmarkStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateToolbar() }
        }
        connectPasswords()
    }

    private func connectPasswords() {
        passwords.onOffer = { [weak self] offer, webView in
            guard Self.offersPasswordSaving(in: webView) else { return }
            self?.askToSave(offer)
        }
    }

    /// Secret tabs never ask to save an account: nothing from them should outlive the tab.
    static func offersPasswordSaving(in webView: WKWebView?) -> Bool {
        webView?.configuration.websiteDataStore.isPersistent ?? true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Tabs

    @discardableResult
    func openTab(_ url: URL?, upgraded: Bool = false, activate: Bool = true, after opener: Tab? = nil,
                 privateStore: WKWebsiteDataStore? = nil) -> Tab {
        let tab = Tab(url: url, upgraded: upgraded, privateStore: privateStore)
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
            placeholder.isPrivate = tab.isPrivate
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
        // A closed secret tab is gone for good: nothing to reopen, its store goes with it.
        if !tab.isBlank, !tab.isPrivate {
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
        openTab(url, activate: false, after: tab, privateStore: tab.privateStore)
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
        [.back, .forward, .reload, .address, .translate, .bookmark, .password, .status]
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
        case .bookmark: configureButton(item, symbol: "star", label: "북마크", action: #selector(toggleBookmarkAction(_:)))
        case .translate: configureButton(item, symbol: "character.bubble", label: "번역", action: #selector(toggleTranslationAction(_:)))
        case .password: configureButton(item, symbol: "key", label: "계정 채우기", action: #selector(fillPasswordAction(_:)))
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
        if let star = toolbarItems[.bookmark] {
            let url = tab?.displayURL
            let marked = url.map(bookmarks.contains) ?? false
            star.isEnabled = BookmarkStore.canBookmark(url)
            star.image = NSImage(systemSymbolName: marked ? "star.fill" : "star", accessibilityDescription: nil)
            star.toolTip = marked ? "북마크에서 제거 (⌘D)" : "이 페이지 북마크 (⌘D)"
        }
        if let button = toolbarItems[.translate] {
            let on = tab?.webView.map(translator.isTranslated) ?? false
            button.isEnabled = tab?.webView != nil
            button.image = NSImage(systemSymbolName: on ? "character.bubble.fill" : "character.bubble", accessibilityDescription: nil)
            button.toolTip = on ? "원문 보기 (⌥⌘T) · 이 탭은 번역이 켜져 있습니다" : "이 페이지 번역 (⌥⌘T)"
        }
        if let key = toolbarItems[.password] {
            let saved = passwords.accounts(for: tab?.webView).count
            key.isEnabled = saved > 0
            key.toolTip = saved > 0 ? "저장된 계정 채우기 (⌘\\)" : "이 사이트에 저장된 계정 없음"
        }
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
            let model = TranslatorProcess.shared.footprint
            if model > 0 { details.append("번역 모델 \(Self.format(model)) (탭 메모리와 별도, 2분 동안 안 쓰면 해제)") }
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
    @objc func newPrivateTabAction(_ sender: Any?) { openTab(nil, privateStore: .nonPersistent()) }
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

    @objc func toggleBookmarkAction(_ sender: Any?) {
        guard let tab = activeTab, let url = tab.displayURL, BookmarkStore.canBookmark(url) else { return }
        let marked = bookmarks.toggle(url, title: tab.displayTitle)
        flash(marked ? "북마크에 추가했습니다" : "북마크에서 제거했습니다")
    }

    /// Opens in this tab, or in a new background tab with ⌘ held.
    @objc func openBookmark(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            openTab(url, activate: false, after: activeTab)
        } else if let tab = activeTab {
            tab.load(url)
            showActiveTab()
            focusPage()
        } else {
            openTab(url)
        }
    }

    @objc func deleteBookmark(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        bookmarks.remove(url)
        flash("북마크를 삭제했습니다")
    }

    // MARK: Accounts

    private func askToSave(_ offer: PasswordManager.Offer) {
        guard let window else { return }
        let alert = NSAlert()
        switch offer {
        case .save(let credential):
            alert.messageText = "\(credential.host)의 계정을 저장할까요?"
            alert.informativeText = Self.accountName(credential.username) + "\n비밀번호는 macOS 키체인에 저장되고, 계정 채우기(⌘\\)를 누를 때만 입력됩니다."
            alert.addButton(withTitle: "저장")
            alert.addButton(withTitle: "나중에")
            alert.addButton(withTitle: "이 사이트는 저장 안 함")
        case .update(let credential):
            alert.messageText = "\(credential.host)의 \(Self.accountName(credential.username)) 비밀번호를 바꿀까요?"
            alert.informativeText = "키체인에 저장된 비밀번호를 방금 입력한 것으로 바꿉니다."
            alert.addButton(withTitle: "업데이트")
            alert.addButton(withTitle: "나중에")
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated { self?.answer(offer, with: response) }
        }
    }

    /// The user's answer to `askToSave`. The password is kept only until this returns.
    func answer(_ offer: PasswordManager.Offer, with response: NSApplication.ModalResponse) {
        switch response {
        case .alertFirstButtonReturn:
            do {
                try passwords.accept(offer)
                flash("계정을 키체인에 저장했습니다")
                updateToolbar()
            } catch {
                flash("저장하지 못했습니다: \(error.localizedDescription)")
            }
        case .alertThirdButtonReturn:
            if case .save(let credential) = offer { passwords.neverSave(credential.host) }
        default:
            break
        }
    }

    private static func accountName(_ username: String) -> String {
        username.isEmpty ? "(아이디 없음)" : username
    }

    /// Fills the page's login form with a saved account; asks which one if there are several.
    @objc func fillPasswordAction(_ sender: Any?) {
        let accounts = passwords.accounts(for: activeTab?.webView)
        guard let first = accounts.first else { return flash("이 사이트에 저장된 계정이 없습니다") }
        guard accounts.count > 1, let view = window?.contentView else { return fill(first) }
        let menu = NSMenu()
        for account in accounts {
            let item = NSMenuItem(title: Self.accountName(account.username), action: #selector(fillAccount(_:)), keyEquivalent: "")
            item.representedObject = account
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX - 220, y: view.bounds.maxY - 8), in: view)
    }

    @objc func fillAccount(_ sender: NSMenuItem) {
        if let account = sender.representedObject as? Account { fill(account) }
    }

    private func fill(_ account: Account) {
        guard let webView = activeTab?.webView else { return }
        Task { @MainActor in
            switch await passwords.fill(account, in: webView) {
            case .filled: flash("계정을 채웠습니다")
            case .usernameOnly: flash("아이디를 채웠습니다 · 다음 단계에서 다시 ⌘\\")
            case .nothing: flash("채울 로그인 칸을 찾지 못했습니다")
            }
        }
    }

    @objc func openAccountSite(_ sender: NSMenuItem) {
        guard let account = sender.representedObject as? Account, let url = URL(string: "https://\(account.host)/") else { return }
        if let tab = activeTab {
            tab.load(url)
            showActiveTab()
        } else {
            openTab(url)
        }
    }

    @objc func deleteAccount(_ sender: NSMenuItem) {
        guard let account = sender.representedObject as? Account, let window else { return }
        let alert = NSAlert()
        alert.messageText = "\(account.host)의 \(Self.accountName(account.username)) 계정을 삭제할까요?"
        alert.informativeText = "키체인에서 이 비밀번호를 지웁니다."
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.removeAccount(account) }
        }
    }

    func removeAccount(_ account: Account) {
        do {
            try passwords.delete(account)
            flash("계정을 삭제했습니다")
            updateToolbar()
        } catch {
            flash("삭제하지 못했습니다: \(error.localizedDescription)")
        }
    }

    @objc func clearNeverSaveAction(_ sender: Any?) {
        passwords.clearNeverSave()
        flash("모든 사이트에서 다시 계정 저장을 묻습니다")
    }

    /// Translates the page on the device, or shows the original again.
    @objc func toggleTranslationAction(_ sender: Any?) {
        guard let webView = activeTab?.webView else { return }
        let showing = translator.isTranslated(webView)
        if !showing { flash(TranslatorProcess.shared.isRunning ? "번역 중…" : "번역 모델 불러오는 중…") }
        Task { @MainActor in
            let outcome = await translator.toggle(webView)
            updateToolbar()
            switch outcome {
            case .translated(let blocks): flash("번역 \(blocks)문단 · 새 글과 다음 페이지도 계속 번역 (⌥⌘T 끄기)")
            case .alreadyInTargetLanguage: flash("이미 번역할 언어입니다 · 다른 언어 글이 나오면 번역합니다")
            case .nothingToTranslate: flash("아직 번역할 글이 없습니다 · 글이 생기면 번역합니다")
            case .stopped: flash(showing ? "번역을 끄고 원문으로 되돌렸습니다" : "번역을 멈췄습니다")
            case .failed(let reason): flash(reason)
            }
        }
    }

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
        case #selector(fillPasswordAction(_:)): return !passwords.accounts(for: activeTab?.webView).isEmpty
        case #selector(clearNeverSaveAction(_:)): return !passwords.neverSaveHosts.isEmpty
        case #selector(toggleTranslationAction(_:)):
            let webView = activeTab?.webView
            item.title = webView.map(translator.isTranslated) == true ? "원문 보기" : "이 페이지 번역"
            return webView != nil
        case #selector(toggleBookmarkAction(_:)):
            let url = activeTab?.displayURL
            item.title = url.map(bookmarks.contains) == true ? "북마크에서 제거" : "이 페이지 북마크"
            return BookmarkStore.canBookmark(url)
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
        guard let data = try? JSONEncoder().encode(sessionToSave()) else { return }
        let file = Self.sessionFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The tabs to bring back after a restart. Secret tabs are never written down.
    private func sessionToSave() -> Session {
        var entries: [Session.Entry] = []
        var active = 0
        for (index, tab) in tabs.enumerated() where !tab.isPrivate {
            guard let url = tab.displayURL else { continue }
            if index == activeIndex { active = entries.count }
            entries.append(.init(url: url, title: tab.title))
        }
        return Session(tabs: entries, active: active)
    }

    /// Addresses `saveSession` would write, for tests.
    var savedSessionURLs: [URL] { sessionToSave().tabs.map(\.url) }

    private func scheduleSave() {
        guard persistsSession, !saveScheduled else { return }
        saveScheduled = true
        onMain(after: 2) { [weak self] in
            self?.saveScheduled = false
            self?.saveSession()
        }
    }
}
