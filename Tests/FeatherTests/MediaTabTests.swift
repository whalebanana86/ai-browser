import AppKit
import Foundation
import Testing
import WebKit

@testable import Feather

/// Music or a video left playing in another tab must keep playing.
@MainActor
@Suite(.serialized)
struct MediaTabTests {
    private func page(_ html: String, in browser: BrowserWindowController) async throws -> Tab {
        let url = try #require(URL(string: "data:text/html;charset=utf-8," + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")))
        let tab = browser.openTab(url, activate: false)
        // Wait for the load itself, not `onLoadFinished`: that also waits for a paint-timing
        // script, whose timers WebKit throttles in off-screen views when many tests run at once.
        let webView = tab.wake()
        for _ in 0..<100 where webView.isLoading || webView.url == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        return tab
    }

    private func check(_ governor: MemoryGovernor, pressure: DispatchSource.MemoryPressureEvent) async {
        for _ in 0..<50 {
            if let running = governor.check(pressure: pressure) {
                await running.value
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @Test func playingTabSurvivesEvenFarOverTheMemoryBudget() async throws {
        _ = NSApplication.shared
        let browser = BrowserWindowController()
        browser.persistsSession = false
        browser.governor.stop()
        browser.governor.maxLiveTabs = { 1 }
        browser.governor.memoryBudget = { 1 }  // every byte is over budget, far past the old hard limit
        defer { browser.governor.memoryBudget = { Settings.memoryBudget } }
        // Set before loading: every finished load triggers a check of its own.
        browser.governor.isPlayingMedia = { $0.displayURL?.absoluteString.contains("playing") == true }
        let music = try await page("<p>A video playing with sound.</p>", in: browser)
        let plain = try await page("<p>Just an article.</p>", in: browser)
        _ = try await page("<p>The tab being looked at.</p>", in: browser)
        browser.selectTab(at: browser.tabs.count - 1)

        await check(browser.governor, pressure: [])
        #expect(music.isLive, "keeps playing in the background")
        #expect(!plain.isLive)

        await check(browser.governor, pressure: .critical)
        #expect(!music.isLive, "critical memory pressure still wins")
    }

    /// The media check really sees a page playing sound.
    @Test func soundPlayingIsDetected() async throws {
        // One second of a 440 Hz tone, as a WAV data URL.
        var samples = Data()
        for index in 0..<8_000 {
            let value = Int16(sin(Double(index) * 2 * .pi * 440 / 8_000) * 12_000)
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        append(UInt32(36 + samples.count))
        wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))  // fmt chunk size
        append(UInt16(1))  // PCM
        append(UInt16(1))  // mono
        append(UInt32(8_000))  // sample rate
        append(UInt32(16_000))  // byte rate
        append(UInt16(2))  // block align
        append(UInt16(16))  // bits per sample
        wav.append(Data("data".utf8))
        append(UInt32(samples.count))
        wav.append(samples)

        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WebKitEnvironment.shared.makeWebView(configuration: configuration)
        // Autoplay needs a web view in a window, as a tab on screen is.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        webView.frame = window.contentView!.bounds
        window.contentView!.addSubview(webView)
        let tab = Tab(webView: webView)
        #expect(await !tab.isUsingMedia())
        webView.loadHTMLString("<audio loop src='data:audio/wav;base64,\(wav.base64EncodedString())'></audio>", baseURL: URL(string: "https://example.com/"))
        try await Task.sleep(nanoseconds: 500_000_000)
        _ = try? await webView.callAsyncJavaScript("await document.querySelector('audio').play()", contentWorld: .page)
        var playing = false
        for _ in 0..<40 where !playing {
            try await Task.sleep(nanoseconds: 100_000_000)
            playing = await tab.isUsingMedia()
        }
        #expect(playing)
        _ = try? await webView.evaluateJavaScript("document.querySelector('audio').pause()")
    }
}
