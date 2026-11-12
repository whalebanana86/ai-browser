import CryptoKit
import Foundation

/// Downloads the translation model once, only after the user agrees. The files come from one
/// fixed commit of the official MLX conversion on Hugging Face and are checked against SHA-256
/// hashes recorded here, so a changed or corrupted file is never used. Nothing from the user's
/// pages is sent; the download uses its own session with no cookies or cache.
@MainActor
final class ModelDownloader {
    struct File: Equatable, Sendable {
        var name: String
        var size: Int64
        var sha256: String
    }

    enum Failure: LocalizedError, Equatable {
        case network(String)
        case mismatch(String)

        var errorDescription: String? {
            switch self {
            case .network(let reason): return "번역 모델을 내려받지 못했습니다: \(reason)"
            case .mismatch(let name): return "내려받은 번역 모델 파일이 맞지 않습니다(\(name)). 받은 파일은 지웠습니다"
            }
        }
    }

    nonisolated static let repository = "mlx-community/Hy-MT2-1.8B-4bit"
    /// The commit the hashes below were taken from (checked against AITranslate's copy).
    nonisolated static let revision = "e5c6fe56c7b3bc77fae5ae92db31f2178f1e6912"
    nonisolated static let files = [
        File(name: "config.json", size: 1_688, sha256: "63180daf56cf2ca15223b358eae0bcb5252b7fd4bfa2b2882b36e82f4c410da8"),
        File(name: "generation_config.json", size: 221, sha256: "0e28667f1cb4c7b880b9223b2d87978f88e79ed7ae037de1021f826c18d4ed6f"),
        File(name: "chat_template.jinja", size: 654, sha256: "b7491ec0e9c869dfce20f2176758099bf248d979dd05530ede99deb21698acee"),
        File(name: "tokenizer_config.json", size: 359, sha256: "9c8fad86305966b62964ad3f4b56d00fb3234141028a31710ca312ba3e417cd9"),
        File(name: "tokenizer.json", size: 9_527_287, sha256: "b475bbef1b0b2fd57dcb865332b546475bd1ede2deb3bb91bafd0c047a8a530a"),
        File(name: "model.safetensors.index.json", size: 57_380, sha256: "6026955be1656bf6cf7b9ffd56aac91c88287ba13fbab8b9f140655464b9de4b"),
        File(name: "LICENSE.txt", size: 11_629, sha256: "1af3c6dc0c697277cbb6b68720787c1caa43a79c5626bf9f19cd8c00de9c8cd4"),
        File(name: "model.safetensors", size: 1_007_776_125, sha256: "a9cecbc77050b86b2fa3df3a8941d34ed3585cdbcce07bd64b3da289d50537c6"),
    ]

    nonisolated static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    nonisolated static var destination: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Feather/Models/hy-mt2-1.8b-4bit")
    }

    nonisolated static func url(for file: File, base: URL = URL(string: "https://huggingface.co")!) -> URL {
        base.appendingPathComponent(repository).appendingPathComponent("resolve").appendingPathComponent(revision)
            .appendingPathComponent(file.name)
    }

    let destination: URL
    let files: [File]
    private let base: URL
    private let configuration: URLSessionConfiguration
    private(set) var isRunning = false

    init(destination: URL = ModelDownloader.destination, files: [File] = ModelDownloader.files,
         base: URL = URL(string: "https://huggingface.co")!, configuration: URLSessionConfiguration = .ephemeral) {
        self.destination = destination
        self.files = files
        self.base = base
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        self.configuration = configuration
    }

    /// Downloads every file into a temporary folder next to `destination`, checks each hash,
    /// and only then moves the folder into place. On any failure nothing is left behind.
    /// `progress` gets (bytes so far, total bytes).
    func download(progress: @escaping (Int64, Int64) -> Void) async throws -> URL {
        isRunning = true
        defer { isRunning = false }
        let fileManager = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let total = files.reduce(0) { $0 + $1.size }
        var done: Int64 = 0
        let delegate = DownloadDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for file in files {
            let target = staging.appendingPathComponent(file.name)
            let finishedBefore = done
            delegate.onProgress = { written in
                Task { @MainActor in progress(finishedBefore + written, total) }
            }
            try await delegate.download(Self.url(for: file, base: base), to: target, in: session)
            guard try Self.sha256(of: target) == file.sha256 else { throw Failure.mismatch(file.name) }
            done += file.size
            progress(done, total)
        }
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: staging, to: destination)
        return destination
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One file at a time: moves the finished download to its target and reports bytes written.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var onProgress: ((Int64) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var target: URL?
    private var moveError: Error?

    func download(_ url: URL, to target: URL, in session: URLSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            self.target = target
            self.moveError = nil
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress?(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let target else { return }
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            moveError = ModelDownloader.Failure.network("HTTP \(status)")
            return
        }
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = self.continuation
        self.continuation = nil
        if let error {
            continuation?.resume(throwing: ModelDownloader.Failure.network(error.localizedDescription))
        } else if let moveError {
            continuation?.resume(throwing: moveError)
        } else {
            continuation?.resume()
        }
    }
}
