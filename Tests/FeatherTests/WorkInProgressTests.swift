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
        // Wait for the load itself, not `onLoadFinished`: that also waits for a paint-timing
        // script, whose timers WebKit throttles in off-screen views when many tests run at once.
        let webView = tab.wake()
        for _ in 0..<100 where webView.isLoading || webView.url == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        return tab
    }

    @Test func loginPagesCountAsWorkInProgress() async throws {
        for html in [
            #"<form><input name="user"><input type="password"></form>"#,
            #"<input autocomplete="one-time-code" inputmode="numeric">"#,
            #"<label>Enter your code <input name="verification_code"></label>"#,
            #"<input placeholder="인증번호 6자리">"#,
        ] {
            #expect(try await loaded(html).hasWorkInProgress(), "\(html)")
        }
    }

    @Test func textTheUserTypedCounts() async throws {
        let typed = try await loaded(Self.field("textarea"))
        let user = try UserInput(typed)
        #expect(await !typed.hasWorkInProgress())
        await user.focusWithoutClicking()  // so only the key press can count
        await user.type("a")
        #expect(try await user.value() == "a", "the key really reached the field")
        #expect(await typed.hasWorkInProgress(), "typed text")
    }

    /// Fields a page fills in by itself (dashboards, editors restoring settings) are not the
    /// user's work, even when the page fires input events or fake key presses.
    @Test func fieldsThePageFillsDoNotCount() async throws {
        let filled = try await loaded(Self.field("input") + "<script>document.getElementById('f').value = 'from the page'</script>")
        _ = try UserInput(filled)
        #expect(await !filled.hasWorkInProgress(), "filled while loading")

        let faked = try await loaded(Self.field("textarea"))
        let page = try UserInput(faked)
        await page.pageChange(after: "document.dispatchEvent(new KeyboardEvent('keydown', {key: 'a', bubbles: true}));"
            + "document.dispatchEvent(new MouseEvent('mousedown', {bubbles: true}));"
            + "document.dispatchEvent(new WheelEvent('wheel', {deltaY: 50, bubbles: true}));")
        #expect(await !faked.hasWorkInProgress(), "events made by the page aren't the user's")
    }

    /// A click (picking a suggestion, pasting from the menu) or a scroll followed at once by a
    /// change counts; a change long after the user's last input doesn't.
    @Test func changesRightAfterAClickOrScrollCount() async throws {
        let clicked = try await loaded(Self.field("input"))
        let afterClick = try UserInput(clicked)
        await afterClick.click()
        await afterClick.pageChange()
        #expect(await clicked.hasWorkInProgress(), "changed right after a click")

        let scrolled = try await loaded(Self.field("textarea"))
        let afterScroll = try UserInput(scrolled)
        await afterScroll.scroll()
        await afterScroll.pageChange()
        #expect(await scrolled.hasWorkInProgress(), "changed right after a scroll")

        let later = try await loaded(Self.field("input"))
        let afterWait = try UserInput(later)
        await afterWait.click()
        try await Task.sleep(nanoseconds: 1_300_000_000)
        await afterWait.pageChange()
        #expect(await !later.hasWorkInProgress(), "changed well after the user's last input")
    }

    @Test func ordinaryPagesDoNot() async throws {
        #expect(try await !loaded("<h1>News</h1><p>An article.</p>").hasWorkInProgress())
        #expect(try await !loaded(#"<input type="hidden" name="csrf" value="x"><p>Hi</p>"#).hasWorkInProgress())
        let search = try await loaded(Self.field("input", type: "search"))
        let user = try UserInput(search)
        await user.click()
        await user.type("w")
        #expect(try await user.value() == "w")
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

    /// One field filling the top-left corner, where `UserInput` clicks.
    private static func field(_ tag: String, type: String? = nil) -> String {
        let style = "position:absolute;left:0;top:0;width:300px;height:80px;margin:0"
        let typeAttribute = type.map { " type=\"\($0)\"" } ?? ""
        let close = tag == "input" ? "" : "</\(tag)>"
        return "<\(tag) id=\"f\"\(typeAttribute) style=\"\(style)\">\(close)<div style=\"height:3000px\"></div>"
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
