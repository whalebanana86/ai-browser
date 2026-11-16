import AppKit
import Foundation
import Testing
import WebKit

@testable import Feather

/// Hovering over a tab shows how much memory it uses, so the heavy one is easy to find.
@MainActor
@Suite(.serialized)
struct TabMemoryTests {
    private func page(_ html: String, in browser: BrowserWindowController) async throws -> Tab {
        let url = try #require(URL(string: "data:text/html;charset=utf-8," + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")))
        let tab = browser.openTab(url, activate: false)
        let webView = tab.wake()
        for _ in 0..<100 where webView.isLoading || webView.url == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return tab
    }

    private func browser() -> BrowserWindowController {
        _ = NSApplication.shared
        let browser = BrowserWindowController()
        browser.persistsSession = false
        browser.governor.stop()
        browser.governor.maxLiveTabs = { 100 }
        browser.governor.memoryBudget = { .max }  // measure only, never suspend
        return browser
    }

    @Test func eachLiveTabGetsItsMemoryFromTheRegularCheck() async throws {
        let browser = browser()
        let first = try await page("<h1>First</h1>", in: browser)
        let second = try await page("<h1>Second</h1>", in: browser)
        await browser.governor.check()?.value  // the same 5-second check that updates the status bar

        for tab in [first, second] {
            let bytes = try #require(tab.memoryFootprint, "\(tab.displayTitle)")
            #expect(bytes > 1_048_576)
            #expect(BrowserWindowController.toolTip(for: tab).contains("메모리 \(BrowserWindowController.format(bytes))"))
        }

        second.suspend()
        #expect(second.memoryFootprint == nil)
        #expect(BrowserWindowController.toolTip(for: second).contains("일시 중단됨"))
        #expect(!BrowserWindowController.toolTip(for: second).contains("메모리"))
    }

    /// A tab opened by a page (window.open) shares its opener's process; the shown figure is the
    /// whole process, so the tooltip says it's shared instead of pretending each tab uses it all.
    @Test func sharedProcessesAreSaidToBeShared() async throws {
        let browser = browser()
        let opener = try await page("<h1>Opener</h1>", in: browser)
        _ = try await opener.webView?.evaluateJavaScript("window.open('about:blank'); 0")
        let sharing = { browser.tabs.first { $0 !== opener && $0.webView?.processIdentifier == opener.webView?.processIdentifier } }
        for _ in 0..<50 where sharing() == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        let popup = try #require(sharing())
        await browser.governor.check()?.value

        #expect(opener.processSharedBy == 2)
        #expect(popup.processSharedBy == 2)
        #expect(BrowserWindowController.toolTip(for: opener).contains("탭 2개가 함께 쓰는 프로세스"))

        let alone = try await page("<h1>Alone</h1>", in: browser)
        await browser.governor.check()?.value
        #expect(alone.processSharedBy == 1)
        #expect(!BrowserWindowController.toolTip(for: alone).contains("함께"))
    }
}
