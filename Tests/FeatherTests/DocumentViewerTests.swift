import AppKit
import Foundation
import Quartz
import Testing
import WebKit

@testable import Feather

/// Document links open in the tab instead of landing in Downloads.
@MainActor
@Suite(.serialized)
struct DocumentViewerTests {
    @Test func whichNavigationsBecomePreviews() {
        #expect(DocumentViewer.shouldPreview(fileName: "보고서.docx", isMainFrame: true, isAttachment: true, canShow: false))
        #expect(DocumentViewer.shouldPreview(fileName: "sheet.XLSX", isMainFrame: true, isAttachment: false, canShow: false))
        #expect(DocumentViewer.shouldPreview(fileName: "paper.pdf", isMainFrame: true, isAttachment: true, canShow: true))
        #expect(!DocumentViewer.shouldPreview(fileName: "paper.pdf", isMainFrame: true, isAttachment: false, canShow: true),
                "a PDF WebKit shows by itself stays a normal page")
        #expect(!DocumentViewer.shouldPreview(fileName: "files.zip", isMainFrame: true, isAttachment: true, canShow: false))
        #expect(!DocumentViewer.shouldPreview(fileName: "payslip.pdf", isMainFrame: false, isAttachment: true, canShow: true),
                "frame downloads (Gmail's button) still download")
    }

    @Test func documentsOpenInTheTabAndCanBeSaved() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("feather-docs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache"), downloadsFolder = folder.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloadsFolder, withIntermediateDirectories: true)
        let previousCache = DocumentViewer.cacheFolder
        DocumentViewer.cacheFolder = cache
        defer { DocumentViewer.cacheFolder = previousCache }
        let downloads = Downloads(historyFile: nil)
        downloads.folder = downloadsFolder

        let word = try NSAttributedString(string: "Quarterly report").data(
            from: NSRange(location: 0, length: 16), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        let server = try await LocalServer(routes: [
            "/": ("text/html", nil, Data("<h1>Notices</h1>".utf8)),
            "/letter.docx": ("application/octet-stream", "attachment; filename=\"letter.docx\"", word),
            "/sheet.xlsx": ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", nil, Data("not really a sheet".utf8)),
            "/files.zip": ("application/zip", "attachment; filename=\"files.zip\"", Data("PK".utf8)),
        ])
        defer { server.stop() }

        _ = NSApplication.shared
        let browser = BrowserWindowController()
        browser.persistsSession = false
        browser.governor.stop()
        browser.downloads = downloads
        browser.openTab(server.url, activate: true)
        let tab = try #require(browser.activeTab)
        let webView = try #require(tab.webView)
        for _ in 0..<100 where webView.isLoading || webView.url == nil { try await Task.sleep(nanoseconds: 50_000_000) }

        func open(_ path: String) async throws {
            webView.load(URLRequest(url: server.url.appendingPathComponent(path)))
            for _ in 0..<100 where tab.document?.name != path { try await Task.sleep(nanoseconds: 50_000_000) }
        }

        // An attached Word file: shown in the tab, not saved anywhere the user sees.
        try await open("letter.docx")
        let document = try #require(tab.document)
        #expect(document.name == "letter.docx")
        #expect(try Data(contentsOf: document.file) == word)
        #expect(document.file.path.hasPrefix(cache.path), "kept in Feather's cache")
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloadsFolder.path).isEmpty)
        #expect(!browser.documentViewer.isHidden)
        let layers = browser.documentViewer.superview?.subviews ?? []
        #expect((layers.firstIndex(of: browser.documentViewer) ?? -1) > (layers.firstIndex(of: webView) ?? .max), "over the page, not under it")
        #expect(browser.documentViewer.nameLabel.stringValue == "letter.docx")
        #expect((browser.documentViewer.quickLook?.previewItem as? URL) == document.file, "Quick Look shows it")
        #expect(tab.displayURL == server.url.appendingPathComponent("letter.docx"))
        #expect(tab.displayTitle == "letter.docx")
        #expect(tab.canGoBack)

        // 다운로드: a copy goes to Downloads and the download list.
        browser.documentViewer.press("다운로드")
        #expect(downloads.records.first?.fileName == "letter.docx")
        #expect(try Data(contentsOf: downloadsFolder.appendingPathComponent("letter.docx")) == word)

        // Back returns to the page and throws the cached copy away.
        browser.goBackAction(nil)
        #expect(tab.document == nil)
        #expect(browser.documentViewer.isHidden)
        #expect(browser.documentViewer.quickLook == nil)
        #expect(!FileManager.default.fileExists(atPath: document.file.path))
        #expect(tab.displayURL == server.url)

        // A type WebKit can't show, even without "attachment".
        try await open("sheet.xlsx")
        #expect(tab.document?.name == "sheet.xlsx")
        let sheet = try #require(tab.document)
        browser.documentViewer.press("닫기")
        #expect(tab.document == nil)
        #expect(!FileManager.default.fileExists(atPath: sheet.file.path))

        // Not a document: a normal download.
        webView.load(URLRequest(url: server.url.appendingPathComponent("files.zip")))
        for _ in 0..<100 where downloads.records.first?.fileName != "files.zip" { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(downloads.records.first?.fileName == "files.zip")
        #expect(tab.document == nil)
    }
}
