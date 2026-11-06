import Foundation
import Testing

@testable import Feather

struct URLToolsTests {
    @Test func bareHostGetsHTTPS() throws {
        let resolved = try #require(URLTools.resolve("naver.com"))
        #expect(resolved.url.absoluteString == "https://naver.com")
        #expect(resolved.upgraded)
    }

    @Test func localAddressesStayHTTP() throws {
        let local = try #require(URLTools.resolve("localhost:3000"))
        #expect(local.url.absoluteString == "http://localhost:3000")
        #expect(!local.upgraded)
        let ip = try #require(URLTools.resolve("192.168.0.1/admin"))
        #expect(ip.url.absoluteString == "http://192.168.0.1/admin")
        #expect(!ip.upgraded)
    }

    @Test func explicitSchemeIsKept() throws {
        let resolved = try #require(URLTools.resolve("  http://example.com/a?b=1  "))
        #expect(resolved.url.absoluteString == "http://example.com/a?b=1")
        #expect(!resolved.upgraded)
    }

    @Test func textBecomesSearch() throws {
        let resolved = try #require(URLTools.resolve("네이버 날씨"))
        let components = try #require(URLComponents(url: resolved.url, resolvingAgainstBaseURL: false))
        #expect(components.host == "duckduckgo.com")
        #expect(components.queryItems?.first { $0.name == "q" }?.value == "네이버 날씨")
    }

    @Test func searchEncodesPlusSigns() throws {
        let resolved = try #require(URLTools.resolve("c++ 문법"))
        #expect(resolved.url.absoluteString.contains("q=c%2B%2B%20"))
    }

    @Test func notAHostBecomesSearch() throws {
        for input in ["foo", "1.2.3.999", "readme.md5"] {
            let resolved = try #require(URLTools.resolve(input))
            #expect(resolved.url.host == "duckduckgo.com", "\(input)")
        }
    }

    @Test func emptyInputIsIgnored() {
        #expect(URLTools.resolve("   ") == nil)
    }

    @Test func stripsTrackingParameters() throws {
        let url = try #require(URL(string: "https://example.com/p?id=7&utm_source=news&fbclid=abc&gclid=x&q=a%2Bb"))
        let stripped = try #require(URLTools.strippingTrackingParameters(url))
        #expect(stripped.absoluteString == "https://example.com/p?id=7&q=a%2Bb")
    }

    @Test func strippingEveryParameterDropsTheQuery() throws {
        let url = try #require(URL(string: "https://example.com/?utm_medium=email"))
        #expect(URLTools.strippingTrackingParameters(url)?.absoluteString == "https://example.com/")
    }

    @Test func cleanURLIsLeftAlone() throws {
        let url = try #require(URL(string: "https://example.com/p?id=7"))
        #expect(URLTools.strippingTrackingParameters(url) == nil)
    }

    @Test func displayStringDecodesKoreanButKeepsASCIIEscapes() throws {
        let url = try #require(URL(string: "https://ko.wikipedia.org/wiki/%EB%8C%80%ED%95%9C%EB%AF%BC%EA%B5%AD?a=%2F"))
        #expect(URLTools.displayString(url) == "https://ko.wikipedia.org/wiki/대한민국?a=%2F")
        #expect(URLTools.displayString(URL(string: "about:blank")) == "")
        #expect(URLTools.displayString(nil) == "")
    }
}
