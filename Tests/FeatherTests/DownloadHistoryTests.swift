import AppKit
import Foundation
import Testing
import WebKit

@testable import Feather

/// The toolbar's download icon and the list behind it, with real downloads from a local server.
@MainActor
@Suite(.serialized)
struct DownloadHistoryTests {
    private let folder: URL
    private let history: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("feather-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        history = folder.appendingPathComponent("state/downloads.json")
    }

    private func makeDownloads() -> Downloads {
        let downloads = Downloads(historyFile: history)
        downloads.folder = folder
        return downloads
    }

    private func server() async throws -> LocalServer {
        try await LocalServer(routes: [
            "/report.pdf": ("application/pdf", "attachment; filename=\"report.pdf\"", Data(count: 300_000)),
        ], stalling: ["/slow"])
    }

    /// Starts a real download in a web view and hands it to `downloads`.
    private func start(_ path: String, from server: LocalServer, into downloads: Downloads, isPrivate: Bool = false) async throws {
        let webView = WebKitEnvironment.shared.makeWebView()
        let request = URLRequest(url: server.url.appendingPathComponent(String(path.dropFirst())))
        // Handed over in the callback itself, as the app does: after an await, a fast
        // response could arrive before anyone is there to choose where the file goes.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            webView.startDownload(using: request) { download in
                downloads.track(download, isPrivate: isPrivate)
                done.resume()
            }
        }
        _ = Unmanaged.passRetained(webView)  // the web view must outlive the download
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    @Test func finishedDownloadIsRecordedAndRemembered() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try await server()
        defer { server.stop() }
        let downloads = makeDownloads()
        try await start("/report.pdf", from: server, into: downloads)
        try await waitUntil { downloads.records.first?.state == .finished }

        let record = try #require(downloads.records.first)
        #expect(record.state == .finished)
        #expect(record.fileName == "report.pdf")
        #expect(record.receivedBytes == 300_000)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("report.pdf").path))
        #expect(record.source?.path == "/report.pdf")
        #expect(record.detail(fileExists: true) == ByteCountFormatter.string(fromByteCount: 300_000, countStyle: .file))
        #expect(record.detail(fileExists: false) == "파일이 옮겨졌거나 삭제됨")

        let reopened = Downloads(historyFile: history)
        #expect(reopened.records.map(\.fileName) == ["report.pdf"], "the list survives a restart")
        #expect(reopened.records.first?.state == .finished)
    }

    @Test func secretTabDownloadsAreNeverWrittenDown() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try await server()
        defer { server.stop() }
        let downloads = makeDownloads()
        try await start("/report.pdf", from: server, into: downloads, isPrivate: true)
        try await waitUntil { downloads.records.first?.state == .finished }
        #expect(downloads.records.first?.isPrivate == true, "listed while the app runs")
        #expect(Downloads(historyFile: history).records.isEmpty, "but not kept on disk")
    }

    @Test func cancellingClearingAndInterruptedDownloads() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try await server()
        defer { server.stop() }
        let downloads = makeDownloads()
        try await start("/report.pdf", from: server, into: downloads)
        try await waitUntil { downloads.records.first?.state == .finished }
        try await start("/slow", from: server, into: downloads)
        try await waitUntil { downloads.activeCount == 1 && (downloads.records.first?.receivedBytes ?? 0) > 0 }
        let slow = try #require(downloads.records.first)
        #expect(slow.fileName == "slow.zip")
        #expect(slow.state == .downloading)
        #expect(downloads.activeFraction.map { $0 > 0 && $0 < 0.01 } == true, "4 KB of 10 MB")
        #expect(slow.detail(fileExists: true).hasPrefix("받는 중 0%"))

        downloads.clear()
        #expect(downloads.records.map(\.fileName) == ["slow.zip"], "clearing keeps what's still coming in")

        // Quitting mid-download: the next launch shows it as failed, not forever "downloading".
        let afterQuit = Downloads(historyFile: history)
        #expect(afterQuit.records.map(\.state) == [.failed])

        downloads.cancel(slow.id)
        try await waitUntil { downloads.activeCount == 0 }
        #expect(downloads.records.first?.state == .cancelled)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("slow.zip").path), "no half file left")
    }

    @Test func toolbarIconAndListFollowTheDownloads() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try await server()
        defer { server.stop() }
        _ = NSApplication.shared
        let browser = BrowserWindowController()
        browser.persistsSession = false
        browser.governor.stop()
        let downloads = makeDownloads()
        browser.downloads = downloads
        let item = try #require(browser.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "downloads" })
        #expect(item.toolTip == "다운로드 (⌥⌘L)")
        let idleImage = item.image

        let list = DownloadsViewController(downloads: downloads)
        _ = list.view
        #expect(list.rows.isEmpty)

        try await start("/slow", from: server, into: downloads)
        try await waitUntil { downloads.activeCount == 1 && item.toolTip?.contains("받는 중") == true }
        #expect(item.toolTip?.hasPrefix("다운로드 1개 받는 중 · 0%") == true)
        #expect(item.image !== idleImage, "the ring is drawn")
        #expect(list.rows.count == 1)
        let row = try #require(list.rows.first)
        #expect(row.nameLabel.stringValue == "slow.zip")
        #expect(row.detailLabel.stringValue.hasPrefix("받는 중"))
        #expect(!row.cancelButton.isHidden)
        #expect(row.revealButton.isHidden)

        row.cancelButton.performClick(nil)
        try await waitUntil { downloads.activeCount == 0 }
        #expect(item.toolTip == "다운로드 (⌥⌘L)", "back to the plain icon")
        #expect(row.detailLabel.stringValue == "취소됨")
        #expect(row.cancelButton.isHidden)

        try await start("/report.pdf", from: server, into: downloads)
        try await waitUntil { downloads.records.first?.state == .finished }
        #expect(list.rows.map(\.nameLabel.stringValue) == ["report.pdf", "slow.zip"], "newest first")
        #expect(!(list.rows.first?.revealButton.isHidden ?? true), "a finished file can be shown in Finder")
    }
}
