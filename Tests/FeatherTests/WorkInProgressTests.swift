import AppKit
import Foundation
import Testing
import WebKit

@testable import Feather

/// A tab in the middle of a login (e.g. a sign-in code page, left open while the code is
/// fetched from mail in another tab) must survive memory saving.
@MainActor
@Suite(.serialized)
struct WorkInProgressTests {
    private func loaded(_ html: String, in browser: BrowserWindowController? = nil) async throws -> Tab {
        let url = try #require(URL(string: "data:text/html;charset=utf-8," + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")))
        let tab = browser?.openTab(url, activate: false) ?? Tab(url: url)
        await withCheckedContinuation { continuation in
            tab.onLoadFinished = { _ in continuation.resume() }
            tab.wake()
        }
        tab.onLoadFinished = nil
        return tab
    }

    @Test func loginAndTypedTextCountAsWorkInProgress() async throws {
        for html in [
            #"<form><input name="user"><input type="password"></form>"#,
            #"<input autocomplete="one-time-code" inputmode="numeric">"#,
            #"<label>Enter your code <input name="verification_code"></label>"#,
            #"<input placeholder="인증번호 6자리">"#,
        ] {
            #expect(try await loaded(html).hasWorkInProgress(), "\(html)")
        }
        let typed = try await loaded(#"<textarea id="t"></textarea>"#)
        #expect(await !typed.hasWorkInProgress())
        _ = try await typed.webView?.evaluateJavaScript("document.getElementById('t').value = 'half-written reply'")
        #expect(await typed.hasWorkInProgress(), "typed text")
    }

    @Test func ordinaryPagesDoNot() async throws {
        #expect(try await !loaded("<h1>News</h1><p>An article.</p>").hasWorkInProgress())
        #expect(try await !loaded(#"<input type="hidden" name="csrf" value="x"><p>Hi</p>"#).hasWorkInProgress())
        let search = try await loaded(#"<input type="search" id="q">"#)
        _ = try await search.webView?.evaluateJavaScript("document.getElementById('q').value = 'weather'")
        #expect(await !search.hasWorkInProgress(), "a search box isn't worth keeping a tab for")
        #expect(try await !loaded(#"<input type="password" style="display:none">"#).hasWorkInProgress(), "hidden fields don't count")
    }

    @Test func governorSparesTheLoginTabUntilCriticalPressure() async throws {
        _ = NSApplication.shared
        let browser = BrowserWindowController()
        browser.persistsSession = false
        browser.governor.maxLiveTabs = { 1 }
        let login = try await loaded(#"<p>Enter the code we sent you</p><input autocomplete="one-time-code">"#, in: browser)
        let plain = try await loaded("<p>Just an article.</p>", in: browser)
        _ = try await loaded("<p>The tab being looked at.</p>", in: browser)
        browser.selectTab(at: browser.tabs.count - 1)

        await check(browser.governor, pressure: [])
        #expect(login.isLive, "a sign-in code page is never suspended for memory")
        #expect(!plain.isLive, "an ordinary background tab still is")

        await check(browser.governor, pressure: .critical)
        #expect(!login.isLive, "critical memory pressure still wins")
    }

    /// Runs a governor check, waiting out one already in progress.
    private func check(_ governor: MemoryGovernor, pressure: DispatchSource.MemoryPressureEvent) async {
        for _ in 0..<50 {
            if let running = governor.check(pressure: pressure) {
                await running.value
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
