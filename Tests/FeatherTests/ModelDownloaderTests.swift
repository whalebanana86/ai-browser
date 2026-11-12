import AppKit
import CryptoKit
import Foundation
import Testing
import WebKit

@testable import Feather

/// Serves made-up model files instead of Hugging Face.
final class FakeHub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var files: [String: Data] = [:]
    nonisolated(unsafe) static var failing: Set<String> = []
    nonisolated(unsafe) static var requested: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        Self.requested.append(url)
        let name = url.lastPathComponent
        let status = Self.failing.contains(name) ? 500 : (Self.files[name] == nil ? 404 : 200)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status == 200, let data = Self.files[name] { client.urlProtocol(self, didLoad: data) }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
@Suite(.serialized)
struct ModelDownloaderTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherModel-\(UUID().uuidString)")
    private var destination: URL { folder.appendingPathComponent("hy-mt2-1.8b-4bit") }

    private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func downloader(_ contents: [String: String], hashes: [String: String] = [:]) -> ModelDownloader {
        FakeHub.files = contents.mapValues { Data($0.utf8) }
        FakeHub.failing = []
        FakeHub.requested = []
        let files = contents.keys.sorted().map { name in
            ModelDownloader.File(name: name, size: Int64(contents[name]!.utf8.count), sha256: hashes[name] ?? hex(Data(contents[name]!.utf8)))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeHub.self]
        return ModelDownloader(destination: destination, files: files, base: URL(string: "https://huggingface.co")!, configuration: configuration)
    }

    private func leftovers() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    @Test func downloadsChecksAndMovesIntoPlace() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = downloader(["config.json": #"{"model_type":"hunyuan_v1_dense"}"#, "model.safetensors": String(repeating: "w", count: 5000)])
        var reports: [Int64] = []
        let result = try await model.download { done, _ in reports.append(done) }
        #expect(result.path == destination.path)
        #expect(try String(contentsOf: destination.appendingPathComponent("config.json"), encoding: .utf8).contains("hunyuan"))
        #expect(leftovers() == ["hy-mt2-1.8b-4bit"], "no temporary folder left")
        #expect(reports.last == 5000 + 33 && reports == reports.sorted(), "progress only grows, ends at the total")
        #expect(FakeHub.requested.allSatisfy { $0.path.contains("/resolve/\(ModelDownloader.revision)/") }, "fixed commit")
    }

    @Test func wrongHashLeavesNothingBehind() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = downloader(["config.json": "{}", "model.safetensors": "tampered"],
                               hashes: ["model.safetensors": String(repeating: "0", count: 64)])
        await #expect(throws: ModelDownloader.Failure.mismatch("model.safetensors")) { _ = try await model.download { _, _ in } }
        #expect(leftovers().isEmpty, "neither the model folder nor the partial one")
    }

    @Test func serverErrorLeavesNothingBehind() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = downloader(["config.json": "{}", "tokenizer.json": "{}"])
        FakeHub.failing = ["tokenizer.json"]
        await #expect(throws: ModelDownloader.Failure.network("HTTP 500")) { _ = try await model.download { _, _ in } }
        #expect(leftovers().isEmpty)
    }

    @Test func pinnedManifestIsTheOfficialModel() {
        #expect(ModelDownloader.repository == "mlx-community/Hy-MT2-1.8B-4bit")
        #expect(ModelDownloader.revision.count == 40)
        for file in ModelDownloader.files {
            #expect(file.sha256.count == 64 && file.sha256.allSatisfy(\.isHexDigit), "\(file.name)")
            let url = ModelDownloader.url(for: file)
            #expect(url.scheme == "https" && url.host == "huggingface.co", "\(url)")
        }
        let names = Set(ModelDownloader.files.map(\.name))
        #expect(names.isSuperset(of: ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"]))
    }

    /// Without a yes, not a single request goes out.
    @Test func missingModelAsksFirstAndDecliningDownloadsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = NSApplication.shared
        let browser = BrowserWindowController()
        browser.persistsSession = false
        browser.translationModelAvailable = { false }
        browser.modelDownloader = downloader(["config.json": "{}"])
        var asked = 0
        browser.askToDownloadModel = { reply in
            asked += 1
            reply(false)
        }
        let page = TranslationPage()
        await page.load(TranslationPage.article)
        browser.offerModelDownload(for: page.webView)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(asked == 1)
        #expect(FakeHub.requested.isEmpty, "nothing downloaded without a yes")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func agreeingDownloadsThenTranslates() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = NSApplication.shared
        let browser = BrowserWindowController()
        browser.persistsSession = false
        var available = false
        browser.translationModelAvailable = { available }
        browser.modelDownloader = downloader(["config.json": "{}"])
        browser.askToDownloadModel = { reply in reply(true) }
        let page = TranslationPage()
        await page.load(TranslationPage.article)
        browser.offerModelDownload(for: page.webView)
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: destination.appendingPathComponent("config.json").path) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        available = true
        #expect(FakeHub.requested.count == 1)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("config.json").path))
    }

    @Test func helperFindsAModelThatAppearsLater() async throws {
        var model: URL?
        let helper = TranslatorProcess(executable: URL(fileURLWithPath: "/usr/bin/true")) { model }
        #expect(!helper.hasModel)
        model = folder
        #expect(helper.hasModel, "looked up again, no restart needed")
    }
}

/// The real download from Hugging Face (~1 GB) into a temporary folder, then a real translation
/// with it. Only when asked: `FEATHER_REAL_DOWNLOAD=1 swift test --filter RealDownloadTests`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FEATHER_REAL_DOWNLOAD"] == "1"))
struct RealDownloadTests {
    @Test func downloadsTheOfficialModelAndTranslatesWithIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherRealModel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("hy-mt2-1.8b-4bit")
        let started = Date()
        var lastPercent = -10
        let model = try await ModelDownloader(destination: destination).download { done, total in
            let percent = Int(done * 100 / max(total, 1))
            if percent >= lastPercent + 25 {
                lastPercent = percent
                print("REAL DOWNLOAD \(percent)%")
            }
        }
        print("REAL DOWNLOAD done in \(Int(Date().timeIntervalSince(started))) s")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = TranslatorProcess(executable: root.appendingPathComponent("build/Feather.app/Contents/Helpers/FeatherTranslator"), model: model)
        defer { helper.stop() }
        let output = try await helper.translate(prompt: HyMTPrompt.prompt(for: "The download worked.", target: "Korean"), maxTokens: 64, timeLimit: 60)
        print("REAL DOWNLOAD translation: \(HyMTPrompt.clean(output))")
        #expect(ScriptCheck.scripts(in: output).contains(.hangul))
    }
}

struct ModelLocationTests {
    private func makeModel(at folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
    }

    /// Only Feather's own folder (or the user's setting) counts; another app's copy does not.
    @Test func onlyFeathersOwnModelIsUsed() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherSupport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        try makeModel(at: support.appendingPathComponent("AITranslate/Models/hy-mt2-1.8b-4bit"))
        #expect(Settings.translationModel(support: support, override: nil) == nil, "AITranslate's copy is not used")
        let own = support.appendingPathComponent("Feather/Models/hy-mt2-1.8b-4bit")
        try makeModel(at: own)
        #expect(Settings.translationModel(support: support, override: nil)?.path == own.path)
        let custom = support.appendingPathComponent("elsewhere")
        try makeModel(at: custom)
        #expect(Settings.translationModel(support: support, override: custom.path)?.path == custom.path)
    }
}

/// First use on a Mac without the model, through the window's own path: ask, agree, download
/// into Feather's real models folder, translate. Leaves the model in place. Only when asked:
/// `FEATHER_REAL_FIRST_USE=1 swift test --filter RealFirstUseTests` (after `./build.sh translator`).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FEATHER_REAL_FIRST_USE"] == "1"))
struct RealFirstUseTests {
    @Test func firstTranslationAsksDownloadsAndTranslates() async throws {
        try #require(Settings.translationModel == nil, "this Mac already has the model")
        _ = NSApplication.shared
        let browser = BrowserWindowController()
        browser.persistsSession = false
        var asked = 0
        browser.askToDownloadModel = { reply in
            asked += 1
            reply(true)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = TranslatorProcess(executable: root.appendingPathComponent("build/Feather.app/Contents/Helpers/FeatherTranslator")) { Settings.translationModel }
        defer { helper.stop() }
        browser.translationModelAvailable = { helper.hasModel }
        browser.translator = browser.makeTranslator { p, t, l in try await helper.translate(prompt: p, maxTokens: t, timeLimit: l) }
        let html = "<p id='p'>The first translation downloads the model and then translates this sentence.</p>"
        let address = try #require(URL(string: "data:text/html;charset=utf-8," + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")))
        let tab = browser.openTab(address)
        await withCheckedContinuation { continuation in tab.onLoadFinished = { _ in continuation.resume() } }
        let webView = try #require(tab.webView)

        let started = Date()
        browser.toggleTranslationAction(nil)
        var text = ""
        for _ in 0..<600 {
            try await Task.sleep(nanoseconds: 250_000_000)
            text = (try? await webView.evaluateJavaScript("document.getElementById('p').textContent") as? String) ?? ""
            if ScriptCheck.scripts(in: text).contains(.hangul) { break }
        }
        let model = try #require(Settings.translationModel)
        print("REAL FIRST USE: asked \(asked)x, model at \(model.path), \(Int(Date().timeIntervalSince(started))) s to translated text: \(text)")
        #expect(asked == 1)
        #expect(model.path.hasSuffix("Feather/Models/hy-mt2-1.8b-4bit"))
        #expect(ScriptCheck.scripts(in: text).contains(.hangul))
        for file in ModelDownloader.files {
            #expect(try ModelDownloader.sha256(of: model.appendingPathComponent(file.name)) == file.sha256, "\(file.name)")
        }
    }
}
