import AppKit
import UniformTypeIdentifiers

/// The toolbar's download icon; while files are coming in, a ring around it fills up.
enum DownloadIcon {
    static func image(activeCount: Int, fraction: Double?) -> NSImage {
        let symbol = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "다운로드")!
        guard activeCount > 0 else { return symbol }
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            // The arrow alone (no circle), with the progress ring drawn in its place.
            let arrow = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            if let arrow {
                let tinted = NSImage(size: arrow.size, flipped: false) { inner in
                    arrow.draw(in: inner)
                    NSColor.labelColor.set()
                    inner.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: (rect.width - arrow.size.width) / 2, y: (rect.height - arrow.size.height) / 2,
                                       width: arrow.size.width, height: arrow.size.height))
            }
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let track = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            track.lineWidth = 2
            NSColor.tertiaryLabelColor.setStroke()
            track.stroke()
            // Unknown size: a short arc that still shows something is happening.
            let done = fraction ?? 0.15
            let ring = NSBezierPath()
            ring.appendArc(withCenter: center, radius: rect.width / 2 - 2, startAngle: 90, endAngle: 90 - 360 * done, clockwise: true)
            ring.lineWidth = 2
            ring.lineCapStyle = .round
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
            return true
        }
        image.accessibilityDescription = "다운로드 \(activeCount)개 받는 중"
        return image
    }

    static func toolTip(activeCount: Int, fraction: Double?) -> String {
        guard activeCount > 0 else { return "다운로드 (⌥⌘L)" }
        let percent = fraction.map { " · \(Int($0 * 100))%" } ?? ""
        return "다운로드 \(activeCount)개 받는 중\(percent) (⌥⌘L)"
    }
}

/// The downloads popover: newest first; click a finished file to open it.
@MainActor
final class DownloadsViewController: NSViewController {
    let downloads: Downloads
    private let list = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "다운로드 기록이 없습니다")
    private let clearButton = NSButton(title: "목록 지우기", target: nil, action: nil)
    private var observer: NSObjectProtocol?
    private(set) var rows: [DownloadRowView] = []

    init(downloads: Downloads) {
        self.downloads = downloads
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let title = NSTextField(labelWithString: "다운로드")
        title.font = .boldSystemFont(ofSize: 13)
        let folderButton = NSButton(title: "다운로드 폴더 열기", target: self, action: #selector(openFolder))
        clearButton.target = self
        clearButton.action = #selector(clearList)
        for button in [folderButton, clearButton] {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
        }

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        let footer = NSStackView(views: [folderButton, NSView(), clearButton])
        let root = NSStackView(views: [title, scroll, emptyLabel, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        root.spacing = 8
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 380),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            footer.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        scrollHeight?.isActive = true
        view = root
        reload()
        observer = NotificationCenter.default.addObserver(forName: Downloads.didChange, object: downloads, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private var scrollHeight: NSLayoutConstraint?

    func reload() {
        let records = downloads.records
        // Reuse rows so a running download's progress updates in place.
        while rows.count > records.count { rows.removeLast().removeFromSuperview() }
        while rows.count < records.count {
            let row = DownloadRowView(controller: self)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            rows.append(row)
        }
        for (row, record) in zip(rows, records) { row.show(record) }
        emptyLabel.isHidden = !records.isEmpty
        clearButton.isEnabled = records.contains { $0.state != .downloading }
        scrollHeight?.constant = min(CGFloat(records.count) * DownloadRowView.height + CGFloat(max(0, records.count - 1)) * 2, 380)
    }

    fileprivate func open(_ record: DownloadRecord) {
        guard record.state == .finished, let file = record.file, FileManager.default.fileExists(atPath: file.path) else { return }
        NSWorkspace.shared.open(file)
    }

    fileprivate func reveal(_ record: DownloadRecord) {
        guard let file = record.file else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    fileprivate func cancel(_ record: DownloadRecord) { downloads.cancel(record.id) }

    @objc private func openFolder() { NSWorkspace.shared.open(downloads.folder) }

    @objc private func clearList() { downloads.clear() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One file: icon, name, progress or size, and buttons to show it in Finder or cancel.
@MainActor
final class DownloadRowView: NSView {
    static let height: CGFloat = 46
    private weak var controller: DownloadsViewController?
    private let icon = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    let revealButton = NSButton()
    let cancelButton = NSButton()
    private(set) var record: DownloadRecord?

    init(controller: DownloadsViewController) {
        self.controller = controller
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.font = .systemFont(ofSize: 12)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        for (button, symbol, tip, action) in [
            (revealButton, "magnifyingglass", "Finder에서 보기", #selector(revealClicked)),
            (cancelButton, "xmark.circle.fill", "다운로드 취소", #selector(cancelClicked)),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.isBordered = false
            button.toolTip = tip
            button.target = self
            button.action = action
        }
        let text = NSStackView(views: [nameLabel, bar, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [icon, text, revealButton, cancelButton])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            bar.widthAnchor.constraint(equalTo: text.widthAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ record: DownloadRecord) {
        let exists = record.file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        self.record = record
        nameLabel.stringValue = record.fileName
        nameLabel.textColor = record.state == .finished && exists ? .labelColor : .secondaryLabelColor
        detailLabel.stringValue = record.detail(fileExists: exists)
        let downloading = record.state == .downloading
        bar.isHidden = !downloading
        bar.isIndeterminate = record.fraction == nil
        if let fraction = record.fraction { bar.doubleValue = fraction } else if downloading { bar.startAnimation(nil) }
        cancelButton.isHidden = !downloading
        revealButton.isHidden = downloading || !exists
        icon.image = exists && !downloading ? NSWorkspace.shared.icon(forFile: record.file!.path)
            : NSWorkspace.shared.icon(for: .init(filenameExtension: (record.fileName as NSString).pathExtension) ?? .data)
        toolTip = [record.fileName, record.source?.absoluteString].compactMap { $0 }.joined(separator: "\n")
    }

    override func mouseUp(with event: NSEvent) {
        if let record, event.clickCount >= 1 { controller?.open(record) }
    }

    @objc private func revealClicked() { record.map { controller?.reveal($0) } }

    @objc private func cancelClicked() { record.map { controller?.cancel($0) } }
}
