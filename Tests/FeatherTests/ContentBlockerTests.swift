import Foundation
import Testing
import WebKit

@testable import Feather

struct ContentBlockerTests {
    private typealias Rule = [String: [String: Any]]

    private func rules() throws -> [Rule] {
        let data = Data(ContentBlocker.rulesJSON().utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [Rule])
    }

    /// Third-party block rules, as compiled regular expressions.
    private func blockFilters() throws -> [NSRegularExpression] {
        try rules()
            .filter { $0["action"]?["type"] as? String == "block" && $0["trigger"]?["resource-type"] == nil }
            .map { try NSRegularExpression(pattern: try #require($0["trigger"]?["url-filter"] as? String)) }
    }

    private func isBlocked(_ url: String, by filters: [NSRegularExpression]) -> Bool {
        let range = NSRange(url.startIndex..., in: url)
        return filters.contains { $0.firstMatch(in: url, range: range) != nil }
    }

    @Test func trackerListIsClean() {
        let domains = TrackerList.domains
        #expect(Set(domains).count == domains.count, "duplicate domains")
        for domain in domains {
            #expect(domain == domain.lowercased() && domain.contains(".") && !domain.contains("/"), "\(domain)")
        }
    }

    @Test func blocksTrackersAndTheirSubdomains() throws {
        let filters = try blockFilters()
        for url in [
            "https://www.google-analytics.com/collect", "https://stats.g.doubleclick.net:443/x",
            "https://wcs.naver.net/wcslog.js", "https://connect.facebook.net/en_US/fbevents.js",
            "https://www.facebook.com/tr?id=1&ev=PageView",
        ] {
            #expect(isBlocked(url, by: filters), "\(url)")
        }
    }

    @Test func leavesLookalikeHostsAlone() throws {
        let filters = try blockFilters()
        for url in [
            "https://example.com/", "https://notdoubleclick.net/", "https://doubleclick.net.example.com/",
            "https://example.com/?ref=google-analytics.com/x", "https://www.facebook.com/trending",
        ] {
            #expect(!isBlocked(url, by: filters), "\(url)")
        }
    }

    @Test func blockingIsThirdPartyOnly() throws {
        for rule in try rules() where rule["trigger"]?["resource-type"] == nil {
            #expect(rule["trigger"]?["load-type"] as? [String] == ["third-party"])
        }
    }

    @Test func blocksPingsAndThirdPartyCookies() throws {
        let rules = try rules()
        #expect(rules.contains { $0["trigger"]?["resource-type"] as? [String] == ["ping"] && $0["action"]?["type"] as? String == "block" })
        #expect(rules.contains {
            $0["trigger"]?["load-type"] as? [String] == ["third-party"] && $0["action"]?["type"] as? String == "block-cookies"
        })
    }

    /// WebKit accepts only a subset of regular expressions; one bad rule fails the whole list.
    @MainActor
    @Test func webKitCompilesTheRules() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try #require(WKContentRuleListStore(url: folder))
        let json = ContentBlocker.rulesJSON()
        let list: WKContentRuleList? = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: "test", encodedContentRuleList: json) { list, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: list) }
            }
        }
        #expect(list != nil)
    }
}
