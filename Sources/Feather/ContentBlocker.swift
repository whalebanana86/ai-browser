import WebKit

/// Compiles `TrackerList` into a WebKit content rule list. The rules run inside WebKit's
/// network layer: blocked requests never leave the machine and cost no JavaScript.
/// The compiled list is cached on disk, so later launches only look it up.
enum ContentBlocker {
    private static let hostPrefix = #"^[^:]+://+([^:/]+\.)?"#

    static func load(_ completion: @escaping (WKContentRuleList?) -> Void) {
        let json = rulesJSON()
        let identifier = "feather-trackers-" + fnv1a(json)
        guard let store = WKContentRuleListStore.default() else { return completion(nil) }
        store.lookUpContentRuleList(forIdentifier: identifier) { cached, _ in
            if let cached { return completion(cached) }
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let error { NSLog("Feather: tracker rules failed to compile: \(error)") }
                completion(list)
                store.getAvailableContentRuleListIdentifiers { identifiers in
                    for old in identifiers ?? [] where old != identifier {
                        store.removeContentRuleList(forIdentifier: old) { _ in }
                    }
                }
            }
        }
    }

    static func rulesJSON() -> String {
        var rules: [[String: Any]] = []
        func blockThirdParty(_ filter: String) {
            rules.append(["trigger": ["url-filter": hostPrefix + filter, "load-type": ["third-party"]],
                          "action": ["type": "block"]])
        }
        for domain in TrackerList.domains {
            blockThirdParty(domain.replacingOccurrences(of: ".", with: #"\."#) + "[:/]")
        }
        TrackerList.pathPatterns.forEach(blockThirdParty)
        // <a ping> and navigator.sendBeacon exist to report clicks and page exits.
        rules.append(["trigger": ["url-filter": ".*", "resource-type": ["ping"]],
                      "action": ["type": "block"]])
        // Never send or store cookies on third-party requests.
        rules.append(["trigger": ["url-filter": ".*", "load-type": ["third-party"]],
                      "action": ["type": "block-cookies"]])
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }
}
