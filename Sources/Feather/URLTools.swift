import Foundation

enum URLTools {
    /// Turns address-bar input into a URL. Bare hosts get `https://` (`upgraded` is then true,
    /// so a failed load can fall back to http); anything that isn't an address becomes a search.
    static func resolve(_ input: String) -> (url: URL, upgraded: Bool)? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if ["http://", "https://", "file://", "about:", "data:"].contains(where: lower.hasPrefix),
           let url = makeURL(text) {
            return (url, false)
        }
        if !text.contains(" "), let host = hostPart(of: text), looksLikeHost(host) {
            let secure = !(host == "localhost" || isIPv4(host))
            if let url = makeURL((secure ? "https://" : "http://") + text) { return (url, secure) }
        }
        return (searchURL(for: text), false)
    }

    static func searchURL(for query: String) -> URL {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return URL(string: Settings.searchTemplate.replacingOccurrences(of: "%s", with: encoded))
            ?? URL(string: "https://duckduckgo.com/?q=" + encoded)!
    }

    private static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "igshid", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id",
        "rb_clickid", "s_cid", "srsltid", "_ga", "_gl", "ref_src",
    ]

    /// `url` without click-tracking parameters (utm_*, fbclid, gclid, …), or nil if it has none.
    static func strippingTrackingParameters(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems, !items.isEmpty else { return nil }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !trackingParameters.contains(name)
        }
        guard kept.count < items.count else { return nil }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url
    }

    /// Address-bar text for `url`. Percent-encoded non-ASCII text (e.g. Korean paths) is shown
    /// readably; ASCII escapes like %2F stay so the URL keeps its meaning if re-submitted.
    static func displayString(_ url: URL?) -> String {
        guard let url, url.absoluteString != "about:blank" else { return "" }
        let text = url.absoluteString
        guard text.contains("%") else { return text }
        var output = ""
        var bytes: [UInt8] = []
        var raw = ""
        func flush() {
            if !bytes.isEmpty { output += String(bytes: bytes, encoding: .utf8) ?? raw }
            bytes = []
            raw = ""
        }
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "%",
               let end = text.index(index, offsetBy: 3, limitedBy: text.endIndex),
               let byte = UInt8(text[text.index(after: index)..<end], radix: 16), byte >= 0x80 {
                bytes.append(byte)
                raw += text[index..<end]
                index = end
            } else {
                flush()
                output.append(text[index])
                index = text.index(after: index)
            }
        }
        flush()
        return output
    }

    // MARK: - Helpers

    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// Printable ASCII that may appear in a URL as-is.
    private static let urlCharacters = CharacterSet(charactersIn: "!#$%&'()*+,-./0123456789:;=?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]_abcdefghijklmnopqrstuvwxyz~")

    private static func makeURL(_ text: String) -> URL? {
        URL(string: text) ?? text.addingPercentEncoding(withAllowedCharacters: urlCharacters).flatMap(URL.init(string:))
    }

    private static func hostPart(of text: String) -> String? {
        var host = Substring(text)
        if let end = host.firstIndex(where: { "/?#".contains($0) }) { host = host[..<end] }
        if let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
            host = host[..<colon]
        }
        return host.isEmpty ? nil : host.lowercased()
    }

    private static func looksLikeHost(_ host: String) -> Bool {
        if host == "localhost" || isIPv4(host) { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }),
              let tld = labels.last else { return false }
        return tld.count >= 2 && (tld.allSatisfy(\.isLetter) || tld.hasPrefix("xn--"))
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            (1...3).contains(part.count) && part.allSatisfy({ ("0"..."9").contains($0) }) && Int(part)! <= 255
        }
    }
}
