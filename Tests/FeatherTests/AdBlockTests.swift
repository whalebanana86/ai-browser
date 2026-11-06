import Foundation
import Testing
import WebKit

@testable import Feather

struct AdBlockTests {
    private typealias Rule = [String: [String: Any]]

    private func rules(trackers: Bool = false, ads: Bool = true) throws -> [Rule] {
        let data = Data(ContentBlocker.rulesJSON(trackers: trackers, ads: ads).utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [Rule])
    }

    private func blockRules() throws -> [Rule] {
        try rules().filter { $0["action"]?["type"] as? String == "block" }
    }

    /// The registrable domain, roughly (enough for the hosts below): naver.com, inven.co.kr.
    private func site(of url: String) throws -> String {
        let labels = try #require(URL(string: url)?.host).split(separator: ".")
        let keep = labels.count >= 3 && ["co", "or", "go", "ne"].contains(labels[labels.count - 2]) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    private func matches(_ pattern: String, _ text: String) throws -> Bool {
        try NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Whether `page` loading `url` would have it blocked, checked the way WebKit does:
    /// url-filter, third-party load type and unless-top-url.
    private func isBlocked(_ url: String, on page: String) throws -> Bool {
        let thirdParty = try site(of: url) != site(of: page)
        return try blockRules().contains { rule in
            let trigger = rule["trigger"] ?? [:]
            guard try matches(try #require(trigger["url-filter"] as? String), url) else { return false }
            if trigger["load-type"] as? [String] == ["third-party"], !thirdParty { return false }
            let exceptions = trigger["unless-top-url"] as? [String] ?? []
            return try !exceptions.contains { try matches($0, page) }
        }
    }

    @Test func adListIsClean() {
        let all = AdBlockList.networks + AdBlockList.adHosts
        #expect(Set(all).count == all.count, "duplicate hosts")
        for host in all {
            #expect(host == host.lowercased() && host.contains(".") && !host.contains("/"), "\(host)")
        }
        let tracked = Set(TrackerList.domains)
        #expect(AdBlockList.networks.allSatisfy { !tracked.contains($0) }, "already blocked by TrackerList")
    }

    @Test func blocksAdsInsidePages() throws {
        for (url, page) in [
            ("https://siape.veta.naver.com/fxshow?su=1", "https://www.naver.com/"),
            ("https://nam.veta.naver.com/nac/1", "https://news.naver.com/"),
            ("https://ader.naver.com/collection/gfa/e", "https://www.naver.com/"),
            ("https://ads-api.daum.net/api/v1/shopping/naver", "https://www.daum.net/"),
            ("https://display.ad.daum.net/sdk/native", "https://www.daum.net/"),
            ("https://t1.kakaocdn.net/kas/static/ba.min.js", "https://www.dcinside.com/"),
            ("https://zicf.inven.co.kr/RealMedia/ads/adstream_sx.ads/inven/webzine@x72", "https://www.inven.co.kr/"),
            ("https://ad.yna.co.kr/RealMedia/ads/adstream_sx.ads/yna/main@x55", "https://www.yna.co.kr/"),
            ("https://ssl.pstatic.net/tveta/libs/glad/prod/gfp-core.js", "https://www.daum.net/"),
            ("https://hb.vntsm.com/v4/live/vms/sites/namu.wiki/index.js", "https://namu.wiki/w/x"),
            ("https://bbs.ruliweb.com/banneriframe?id=ad_main_ti_new", "https://bbs.ruliweb.com/"),
            ("https://oa.openxcdn.net/esp.js", "https://www.chosun.com/"),
            ("https://www.google.co.kr/ads/ga-audiences?v=1", "https://www.hankyung.com/"),
        ] {
            #expect(try isBlocked(url, on: page), "\(url) on \(page)")
        }
    }

    @Test func leavesContentAlone() throws {
        for (url, page) in [
            ("https://www.naver.com/", "https://www.naver.com/"),
            ("https://shopping-phinf.pstatic.net/main_886/1.jpg", "https://search.shopping.naver.com/"),
            ("https://ssl.pstatic.net/static/pwe/address/img_logo.png", "https://www.naver.com/"),
            ("https://myveta.naver.com/", "https://www.naver.com/"),
            ("https://veta.naver.com.example.org/", "https://example.org/"),
            ("https://t1.kakaocdn.net/kakaoapp/icon.png", "https://www.daum.net/"),
            ("https://www.inven.co.kr/webzine/news/?news=1", "https://www.inven.co.kr/"),
            ("https://www.google.com/ads/", "https://example.com/"),
            ("https://www.innovid.com/", "https://www.innovid.com/"),
        ] {
            #expect(try !isBlocked(url, on: page), "\(url) on \(page)")
        }
    }

    /// Clicking an ad opens the ad server's address as the page; that must still work.
    @Test func adAddressesStillOpenDirectly() throws {
        for url in [
            "https://ader.naver.com/v1/click?x=1", "https://ads-partners.coupang.com/widgets.html?id=1",
            "https://ad.yna.co.kr/RealMedia/ads/click_lx.ads/yna/main",
        ] {
            #expect(try !isBlocked(url, on: url), "\(url)")
        }
    }

    @Test func adNetworksAreBlockedOnlyAsThirdParty() throws {
        #expect(try isBlocked("https://cdn.contentsfeed.com/x.js", on: "https://www.yna.co.kr/"))
        #expect(try !isBlocked("https://www.contentsfeed.com/", on: "https://www.contentsfeed.com/"))
    }

    @Test func hidesLeftoverAdSlots() throws {
        let hiding = try rules().filter { $0["action"]?["type"] as? String == "css-display-none" }
        let everywhere = try #require(hiding.first { $0["trigger"]?["if-domain"] == nil })
        let selector = try #require(everywhere["action"]?["selector"] as? String)
        for expected in ["ins.adsbygoogle", "ins.kakao_ad_area", #"iframe[src*="veta.naver.com"]"#] {
            #expect(selector.contains(expected), "\(expected)")
        }
    }

    /// Selectors like `.ad` are only safe where the site uses them for ads.
    @Test func siteSpecificSlotsAreHiddenOnlyOnThatSite() throws {
        let hiding = try rules().filter { $0["action"]?["type"] as? String == "css-display-none" }
        let ruliweb = try #require(hiding.first { $0["trigger"]?["if-domain"] as? [String] == ["*ruliweb.com"] })
        #expect((ruliweb["action"]?["selector"] as? String)?.contains(".ad") == true)
        let everywhere = hiding.filter { $0["trigger"]?["if-domain"] == nil }
        #expect(everywhere.count == 1)
        #expect(everywhere.allSatisfy { ($0["action"]?["selector"] as? String)?.contains(#"[id^="ad_"]"#) == false })
    }

    /// WebKit compiles any string as a selector, but one invalid selector makes the browser
    /// drop the whole comma-joined list. Check every selector with WebKit's own CSS parser.
    @MainActor
    @Test func hidingSelectorsAreValidCSS() async throws {
        let joined = try rules().compactMap { $0["action"]?["type"] as? String == "css-display-none" ? $0["action"]?["selector"] as? String : nil }
        let selectors = AdBlockList.hiddenSelectors + AdBlockList.siteHiddenSelectors.values.flatMap { $0 } + joined
        let webView = WKWebView()
        let result = try await webView.callAsyncJavaScript("""
            return selectors.filter(s => { try { document.querySelector(s); return false; } catch { return true; } });
            """, arguments: ["selectors": selectors], contentWorld: .defaultClient)
        let invalid = try #require(result as? [String])
        #expect(invalid.isEmpty, "\(invalid)")
    }

    @Test func adsAndTrackersAreSeparateSwitches() {
        let trackersOnly = ContentBlocker.rulesJSON(trackers: true, ads: false)
        #expect(trackersOnly.contains("google-analytics") && !trackersOnly.contains("veta") && !trackersOnly.contains("css-display-none"))
        let adsOnly = ContentBlocker.rulesJSON(trackers: false, ads: true)
        #expect(adsOnly.contains("veta") && !adsOnly.contains("google-analytics") && !adsOnly.contains("block-cookies"))
        #expect(ContentBlocker.rulesJSON(trackers: false, ads: false) == "[]")
    }
}
