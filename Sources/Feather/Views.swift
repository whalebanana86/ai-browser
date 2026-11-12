import AppKit

/// Tab strip under the toolbar. Tabs share the width evenly, so 20+ tabs stay visible.
final class TabStripView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?

    private var items: [TabItemView] = []
    private lazy var newTabButton: NSButton = {
        let button = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "새 탭")!,
                              target: self, action: #selector(newTabClicked))
        button.isBordered = false
        button.toolTip = "새 탭 (⌘T)"
        return button
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(newTabButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setTabs(_ tabs: [Tab], active: Int) {
        while items.count < tabs.count {
            let item = TabItemView(strip: self)
            addSubview(item)
            items.append(item)
        }
        while items.count > tabs.count { items.removeLast().removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            items[index].index = index
            items[index].isActive = index == active
            items[index].show(tab)
        }
        needsLayout = true
    }

    func update(at index: Int, with tab: Tab) {
        if items.indices.contains(index) { items[index].show(tab) }
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 6, gap: CGFloat = 2, buttonSize: CGFloat = 24
        newTabButton.frame = NSRect(x: bounds.maxX - buttonSize - inset, y: (bounds.height - buttonSize) / 2,
                                    width: buttonSize, height: buttonSize)
        guard !items.isEmpty else { return }
        let available = newTabButton.frame.minX - inset * 2
        let count = CGFloat(items.count)
        let width = max(28, min(220, (available - gap * (count - 1)) / count))
        for (index, item) in items.enumerated() {
            item.frame = NSRect(x: inset + CGFloat(index) * (width + gap), y: 3,
                                width: width, height: bounds.height - 6).integral
        }
    }

    @objc private func newTabClicked() { onNewTab?() }
    fileprivate func select(_ index: Int) { onSelect?(index) }
    fileprivate func close(_ index: Int) { onClose?(index) }
}

private final class TabItemView: NSView {
    var index = 0
    var isActive = false {
        didSet { if oldValue != isActive { refresh() } }
    }

    private weak var strip: TabStripView?
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var isSuspended = false
    private var isPrivate = false
    private var isHovered = false {
        didSet { refresh() }
    }

    init(strip: TabStripView) {
        self.strip = strip
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "탭 닫기")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "탭 닫기 (⌘W)"
        addSubview(label)
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ tab: Tab) {
        label.stringValue = tab.displayTitle
        toolTip = tab.isLive || tab.isBlank ? tab.displayTitle : "\(tab.displayTitle)\n(일시 중단됨 · 선택하면 다시 불러옵니다)"
        isSuspended = !tab.isLive && !tab.isBlank
        isPrivate = tab.isPrivate
        refresh()
    }

    private func refresh() {
        label.textColor = isActive ? .labelColor : (isSuspended ? .tertiaryLabelColor : .secondaryLabelColor)
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        closeButton.isHidden = !(isActive || isHovered) || bounds.width < 48
        closeButton.frame = NSRect(x: bounds.width - 22, y: (height - 16) / 2, width: 16, height: 16)
        let right = closeButton.isHidden ? bounds.width - 8 : closeButton.frame.minX - 2
        let labelHeight = label.intrinsicContentSize.height
        label.frame = NSRect(x: 10, y: (height - labelHeight) / 2, width: max(0, right - 10), height: labelHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Secret tabs are always tinted, so they're told apart at a glance.
        if isPrivate {
            NSColor.systemPurple.withAlphaComponent(isActive ? 0.28 : 0.14).setFill()
        } else {
            guard isActive || isHovered else { return }
            NSColor.labelColor.withAlphaComponent(isActive ? 0.1 : 0.05).setFill()
        }
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !closeButton.isHidden, closeButton.frame.contains(local) { return closeButton }
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { strip?.select(index) }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { strip?.close(index) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    @objc private func closeClicked() { strip?.close(index) }
}

/// Address bar: selects everything on focus, submits on Return, reverts on Escape.
final class AddressField: NSTextField, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onEndEditing: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 24))
        delegate = self
        bezelStyle = .roundedBezel
        placeholderString = "검색 또는 주소 입력"
        font = .systemFont(ofSize: 13)
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        cell?.isScrollable = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        // After the click that focused us has been handled, or it would place the caret.
        if accepted { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.currentEditor()?.selectAll(nil) } } }
        return accepted
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?(textView.string)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) { onEndEditing?() }
}

/// Thin load-progress line across the top of the page.
final class ProgressBar: NSView {
    var progress: Double = 0 {
        didSet { if progress != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Shown for a new, empty tab. No web view exists until the user goes somewhere.
final class PlaceholderView: NSView {
    /// A blank secret tab says what it is.
    var isPrivate = false {
        didSet {
            title.stringValue = isPrivate ? "시크릿 탭" : "Feather"
            hint.stringValue = isPrivate ? "이 탭을 닫으면 쿠키·캐시·사이트 데이터가 모두 지워집니다  ·  ⌘L" : Self.normalHint
        }
    }
    private static let normalHint = "검색어나 주소를 입력하세요  ·  ⌘L"
    private let title = NSTextField(labelWithString: "Feather")
    private let hint = NSTextField(labelWithString: PlaceholderView.normalHint)

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 34, weight: .light)
        title.textColor = .tertiaryLabelColor
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [title, hint])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// Find-in-page panel. Searches as you type; Return finds next, ⇧Return previous, Esc closes.
final class FindBar: NSVisualEffectView, NSSearchFieldDelegate {
    let field = NSSearchField()
    var onFind: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .menu
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        field.placeholderString = "페이지에서 찾기"
        field.delegate = self
        field.frame = NSRect(x: 8, y: (frame.height - 24) / 2, width: frame.width - 40, height: 24)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "닫기")!,
                             target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.frame = NSRect(x: frame.width - 28, y: (frame.height - 20) / 2, width: 20, height: 20)
        addSubview(field)
        addSubview(close)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setFound(_ found: Bool) { field.textColor = found ? .labelColor : .systemRed }

    func controlTextDidChange(_ notification: Notification) { onFind?(field.stringValue, false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onFind?(textView.string, NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    @objc private func closeClicked() { onClose?() }
}
