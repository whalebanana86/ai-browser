import CoreServices
import WebKit

/// Saves downloads to ~/Downloads with the quarantine flag set, so Gatekeeper still checks
/// downloaded apps and documents (an unsandboxed app's files aren't quarantined otherwise).
@MainActor
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()
    var onFinish: ((URL) -> Void)?

    private var destinations: [ObjectIdentifier: URL] = [:]
    private var active: [ObjectIdentifier: WKDownload] = [:]

    func track(_ download: WKDownload) {
        download.delegate = self
        active[ObjectIdentifier(download)] = download
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let file = Self.uniqueFile(named: suggestedFilename, in: folder)
        destinations[ObjectIdentifier(download)] = file
        completionHandler(file)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        active[id] = nil
        guard var file = destinations.removeValue(forKey: id) else { return }
        var quarantine: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "Feather",
        ]
        if let source = download.originalRequest?.url { quarantine[kLSQuarantineDataURLKey as String] = source }
        var values = URLResourceValues()
        values.quarantineProperties = quarantine
        try? file.setResourceValues(values)
        // Bounces the Downloads stack in the Dock, as Safari does.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: file.path)
        onFinish?(file)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let id = ObjectIdentifier(download)
        active[id] = nil
        destinations[id] = nil
        NSLog("Feather: download failed: \(error.localizedDescription)")
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
