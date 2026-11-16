import AppKit
import Quartz
import WebKit

/// A document shown in a tab instead of being downloaded.
struct DocumentPreview: Equatable {
    var file: URL
    var source: URL?
    var name: String { file.lastPathComponent }
}

/// Documents a page links to (PDF, Office, iWork, images, text, HWP) open in the tab, using
/// macOS's own Quick Look previews: nothing is sent anywhere, and the file lives in a private
/// cache folder until the preview is closed. The user can still save or open it elsewhere.
@MainActor
enum DocumentViewer {
    static let quickLookExtensions: Set<String> = [
        "pdf", "doc", "docx", "dot", "dotx", "xls", "xlsx", "xlsm", "ppt", "pptx", "pps", "ppsx",
        "rtf", "txt", "csv", "pages", "numbers", "key", "odt", "ods", "odp",
        "jpg", "jpeg", "png", "gif", "heic", "webp", "tif", "tiff", "bmp",
    ]
    /// Read by Feather itself (`HWPDocument`); macOS has no previewer for them.
    static var ownExtensions: Set<String> = []

    /// Tests point this elsewhere.
    static var cacheFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Feather/Documents")

    static func canView(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return quickLookExtensions.contains(ext) || ownExtensions.contains(ext)
    }

    /// A page navigation becomes a preview when it would otherwise be downloaded: an attachment,
    /// or a type WebKit can't show (Word, Excel, HWP…). Frames keep downloading (Gmail's button).
    static func shouldPreview(fileName: String, isMainFrame: Bool, isAttachment: Bool, canShow: Bool) -> Bool {
        isMainFrame && (isAttachment || !canShow) && canView(fileName: fileName)
    }

    /// A fresh folder for one document.
    static func newFolder() -> URL {
        cacheFolder.appendingPathComponent(UUID().uuidString)
    }

    /// Leftovers from an earlier run (a crash, or the app quit with a preview open).
    static func purgeCache() {
        try? FileManager.default.removeItem(at: cacheFolder)
    }
}

/// Fetches one document for a preview into its own cache folder.
@MainActor
final class PreviewDownload: NSObject, WKDownloadDelegate {
    private let folder = DocumentViewer.newFolder()
    private var file: URL?
    private let completion: (URL?) -> Void

    init(_ download: WKDownload, completion: @escaping (URL?) -> Void) {
        self.completion = completion
        super.init()
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        let name = (suggestedFilename as NSString).lastPathComponent
        let file = folder.appendingPathComponent(name.isEmpty || name.hasPrefix(".") ? "document" : name)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.file = file
        completionHandler(file)
    }

    func downloadDidFinish(_ download: WKDownload) {
        completion(file)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        try? FileManager.default.removeItem(at: folder)
        NSLog("Feather: document preview failed: \(error.localizedDescription)")
        completion(nil)
    }
}

/// The viewer over a tab's page: a bar with the file name and what to do with it, and the
/// document below. Back (⌘[) or 닫기 returns to the page.
@MainActor
final class DocumentViewerView: NSView {
    var onSave: ((DocumentPreview) -> Void)?
    var onOpenElsewhere: ((DocumentPreview) -> Void)?
    var onClose: (() -> Void)?

    private(set) var document: DocumentPreview?
    private let bar = NSVisualEffectView()
    private let icon = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    private lazy var saveButton = button("다운로드", symbol: "arrow.down.circle", action: #selector(save))
    private lazy var openButton = button("다른 앱에서 열기", symbol: "arrow.up.forward.app", action: #selector(openElsewhere))
    private lazy var closeButton = button("닫기", symbol: "xmark", action: #selector(close))
    private(set) var quickLook: QLPreviewView?
    private(set) var ownView: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        bar.material = .headerView
        bar.blendingMode = .withinWindow
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let row = NSStackView(views: [icon, nameLabel, NSView(), saveButton, openButton, closeButton])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        addSubview(bar)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
        ])
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static let barHeight: CGFloat = 34

    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 0, y: bounds.height - Self.barHeight, width: bounds.width, height: Self.barHeight)
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - Self.barHeight))
        quickLook?.frame = body
        ownView?.frame = body
    }

    func show(_ document: DocumentPreview) {
        guard document != self.document else { return }
        clear()
        self.document = document
        nameLabel.stringValue = document.name
        icon.image = NSWorkspace.shared.icon(forFile: document.file.path)
        toolTip = document.source?.absoluteString
        if let view = OwnDocumentReader.view(for: document.file) {
            ownView = view
            addSubview(view, positioned: .below, relativeTo: bar)
        } else if let preview = QLPreviewView(frame: .zero, style: .normal) {
            preview.shouldCloseWithWindow = false
            preview.previewItem = document.file as NSURL
            quickLook = preview
            addSubview(preview, positioned: .below, relativeTo: bar)
        }
        needsLayout = true
    }

    func clear() {
        quickLook?.close()
        quickLook?.removeFromSuperview()
        quickLook = nil
        ownView?.removeFromSuperview()
        ownView = nil
        document = nil
    }

    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!,
                              target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.imagePosition = .imageLeading
        return button
    }

    @objc private func save() { document.map { onSave?($0) } }
    @objc private func openElsewhere() { document.map { onOpenElsewhere?($0) } }
    @objc private func close() { onClose?() }

    /// For tests.
    func press(_ title: String) {
        [saveButton, openButton, closeButton].first { $0.title == title }?.performClick(nil)
    }
}

/// Formats Feather reads itself; filled in by the HWP reader.
@MainActor
enum OwnDocumentReader {
    static var makeView: ((URL) -> NSView?)?

    static func view(for file: URL) -> NSView? {
        guard DocumentViewer.ownExtensions.contains(file.pathExtension.lowercased()) else { return nil }
        return makeView?(file)
    }
}
