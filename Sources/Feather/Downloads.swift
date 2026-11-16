import AppKit
import CoreServices
import WebKit

/// One download, as listed in the downloads popover.
struct DownloadRecord: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case downloading, finished, failed, cancelled
    }

    var id = UUID()
    var fileName: String
    var file: URL?
    var source: URL?
    var date = Date()
    var state = State.downloading
    var receivedBytes: Int64 = 0
    /// 0 while the size is unknown.
    var totalBytes: Int64 = 0
    var isPrivate = false

    var fraction: Double? {
        totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : nil
    }

    /// The line under the file name: progress, size or what went wrong.
    func detail(fileExists: Bool) -> String {
        let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        switch state {
        case .downloading:
            guard let fraction else { return "받는 중 · \(size(receivedBytes))" }
            return "받는 중 \(Int(fraction * 100))% · \(size(receivedBytes)) / \(size(totalBytes))"
        case .finished: return fileExists ? size(receivedBytes) : "파일이 옮겨졌거나 삭제됨"
        case .failed: return "실패"
        case .cancelled: return "취소됨"
        }
    }
}

/// Saves downloads to ~/Downloads with the quarantine flag set, so Gatekeeper still checks
/// downloaded apps and documents (an unsandboxed app's files aren't quarantined otherwise),
/// and keeps a local history for the downloads popover. Secret tabs' downloads are listed only
/// until the app quits; they're never written to the history file.
@MainActor
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads(historyFile: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Feather/downloads.json"))

    /// Posted when a download starts, progresses, ends, or the list changes.
    static let didChange = Notification.Name("FeatherDownloadsDidChange")
    /// Posted when a file starts coming in, so the front window can show the list.
    static let didStart = Notification.Name("FeatherDownloadDidStart")
    static let maxRecords = 100

    var onFinish: ((URL) -> Void)?
    /// Where files go; tests use their own folder.
    var folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    /// Newest first.
    private(set) var records: [DownloadRecord] = []
    private let historyFile: URL?
    private var recordIDs: [ObjectIdentifier: UUID] = [:]
    private var active: [ObjectIdentifier: WKDownload] = [:]
    private var privateDownloads: Set<ObjectIdentifier> = []
    private var cancelling: Set<ObjectIdentifier> = []
    private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var lastProgressPost = Date.distantPast

    init(historyFile: URL?) {
        self.historyFile = historyFile
        super.init()
        guard let historyFile, let data = try? Data(contentsOf: historyFile),
              let saved = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return }
        // A download still running when the app quit didn't finish.
        records = saved.map { record in
            var record = record
            if record.state == .downloading { record.state = .failed }
            return record
        }
    }

    var activeCount: Int { records.filter { $0.state == .downloading }.count }

    /// Overall progress of running downloads; nil if none is running or no size is known.
    var activeFraction: Double? {
        let running = records.filter { $0.state == .downloading && $0.totalBytes > 0 }
        let total = running.reduce(0) { $0 + $1.totalBytes }
        return total > 0 ? min(1, Double(running.reduce(0) { $0 + $1.receivedBytes }) / Double(total)) : nil
    }

    func track(_ download: WKDownload, isPrivate: Bool = false) {
        download.delegate = self
        let id = ObjectIdentifier(download)
        active[id] = download
        if isPrivate { privateDownloads.insert(id) }
    }

    func cancel(_ recordID: UUID) {
        guard let (id, download) = active.first(where: { recordIDs[$0.key] == recordID }) else { return }
        cancelling.insert(id)
        download.cancel { _ in }
        // WebKit may not call back for a download that hadn't really started.
        finish(id, state: .cancelled)
    }

    /// Clears everything but running downloads. Files stay where they are.
    func clear() {
        records.removeAll { $0.state != .downloading }
        changed()
    }

    func remove(_ recordID: UUID) {
        records.removeAll { $0.id == recordID && $0.state != .downloading }
        changed()
    }

    /// Saves a copy of a file Feather already has (a previewed document) like a download.
    @discardableResult
    func saveCopy(of source: URL, from address: URL?, isPrivate: Bool = false) throws -> URL {
        let file = Self.uniqueFile(named: source.lastPathComponent, in: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: file)
        Self.quarantine(file, from: address)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        let record = DownloadRecord(fileName: file.lastPathComponent, file: file, source: address, state: .finished,
                                    receivedBytes: size, totalBytes: size, isPrivate: isPrivate)
        records.insert(record, at: 0)
        if records.count > Self.maxRecords { records.removeLast(records.count - Self.maxRecords) }
        changed()
        onFinish?(file)
        return file
    }

    private static func quarantine(_ file: URL, from source: URL?) {
        var file = file
        var quarantine: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "Feather",
        ]
        if let source { quarantine[kLSQuarantineDataURLKey as String] = source }
        var values = URLResourceValues()
        values.quarantineProperties = quarantine
        try? file.setResourceValues(values)
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        let id = ObjectIdentifier(download)
        let file = Self.uniqueFile(named: suggestedFilename, in: folder)
        var record = DownloadRecord(fileName: file.lastPathComponent, file: file, source: download.originalRequest?.url,
                                    isPrivate: privateDownloads.contains(id))
        record.totalBytes = max(0, response.expectedContentLength)
        records.insert(record, at: 0)
        if records.count > Self.maxRecords {
            let finished = records.indices.reversed().filter { records[$0].state != .downloading }
            for index in finished.prefix(records.count - Self.maxRecords) { records.remove(at: index) }
        }
        recordIDs[id] = record.id
        observations[id] = download.progress.observe(\.completedUnitCount) { [weak self] progress, _ in
            let done = progress.completedUnitCount, total = progress.totalUnitCount
            Task { @MainActor in self?.progressed(id, done: done, total: total) }
        }
        changed()
        NotificationCenter.default.post(name: Self.didStart, object: self)
        completionHandler(file)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        guard let index = index(of: id), let file = records[index].file else { return finish(id, state: .finished) }
        Self.quarantine(file, from: download.originalRequest?.url)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil
        records[index].receivedBytes = size ?? max(records[index].receivedBytes, download.progress.completedUnitCount)
        records[index].totalBytes = records[index].receivedBytes
        finish(id, state: .finished)
        // Bounces the Downloads stack in the Dock, as Safari does.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: file.path)
        onFinish?(file)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let id = ObjectIdentifier(download)
        if let index = index(of: id), let file = records[index].file {
            try? FileManager.default.removeItem(at: file)  // a partial file is of no use
        }
        finish(id, state: cancelling.contains(id) ? .cancelled : .failed)
        NSLog("Feather: download failed: \(error.localizedDescription)")
    }

    // MARK: Private

    private func index(of id: ObjectIdentifier) -> Int? {
        recordIDs[id].flatMap { recordID in records.firstIndex { $0.id == recordID } }
    }

    private func progressed(_ id: ObjectIdentifier, done: Int64, total: Int64) {
        guard let index = index(of: id), records[index].state == .downloading else { return }
        records[index].receivedBytes = done
        if total > 0 { records[index].totalBytes = total }
        // Many small chunks: redraw a few times a second at most.
        guard Date().timeIntervalSince(lastProgressPost) > 0.2 else { return }
        lastProgressPost = Date()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func finish(_ id: ObjectIdentifier, state: DownloadRecord.State) {
        if let index = index(of: id), records[index].state == .downloading {
            records[index].state = state
            if state == .cancelled, let file = records[index].file { try? FileManager.default.removeItem(at: file) }
        }
        active[id] = nil
        recordIDs[id] = nil
        observations[id] = nil
        privateDownloads.remove(id)
        cancelling.remove(id)
        changed()
    }

    private func changed() {
        save()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func save() {
        guard let historyFile else { return }
        let kept = records.filter { !$0.isPrivate }
        try? FileManager.default.createDirectory(at: historyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(kept) { try? data.write(to: historyFile, options: .atomic) }
    }

    private static func uniqueFile(named suggested: String, in folder: URL) -> URL {
        let name = (suggested as NSString).lastPathComponent
        let safeName = name.isEmpty || name.hasPrefix(".") ? "download" : name
        let base = (safeName as NSString).deletingPathExtension
        let ext = (safeName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(safeName)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = "\(base) (\(counter))" + (ext.isEmpty ? "" : ".\(ext)")
            candidate = folder.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }
}
