/// Ad servers and ad slots, blocked while `Settings.blocksAds` is on (the default). Kept apart
/// from `TrackerList` so ads can be allowed again without letting trackers in. Built into the
/// app: Feather never downloads filter lists.
enum AdBlockList {
    /// Ad networks that place ads on other sites. Blocked only when loaded as a third party,
    /// so the companies' own websites keep working.
    static let networks: [String] = [
        // Header bidding, exchanges, ad servers
        "openxcdn.net", "creativecdn.com", "360yield.com", "onetag-sys.com", "adkernel.com", "admixer.net",
        "the-ozone-project.com", "flashtalking.com", "innovid.com", "lkqd.net", "seedtag.com", "ntv.io",
        "vntsm.com", "vntsm.io", "venatusmedia.com", "atmtd.com", "ccgateway.net", "innity.net",
        // Ad targeting IDs
        "liadm.com", "intentiq.com", "affec.tv",
        // Ad reinsertion for ad-block users
        "btloader.com",
        // Korea
        "contentsfeed.com", "widerplanet.com",
    ]

    /// Hosts that serve nothing but ads, including portals' own ad servers. Blocked even on
    /// their own site; opening one directly (clicking an ad) still works.
    static let adHosts: [String] = [
        "veta.naver.com", "ader.naver.com", "searchad-phinf.pstatic.net",  // 네이버 광고
        "ad.daum.net", "ads-api.daum.net", "serv.ds.kakao.com",  // 다음·카카오 애드핏
        "ads-partners.coupang.com",  // 쿠팡 파트너스 배너
    ]

    /// Ad-only paths on hosts that also serve real content, as WebKit content-rule regexes
    /// matched anywhere in the URL. Blocked everywhere except as the page itself.
    static let adPaths: [String] = [
        #"/RealMedia/ads/"#,  // Open AdStream ad server (인벤, 연합뉴스 등)
        #"\.pstatic\.net/tveta/"#, #"\.pstatic\.net/melona/libs/gfp"#,  // 네이버 광고 SDK
        #"\.kakaocdn\.net/kas/"#,  // 카카오 애드핏 SDK
        #"\.google\.[a-z.]+/ads/ga-audiences"#,  // Google 광고 리마케팅
        #"cdn\.jsdelivr\.net/gh/prebid/"#, #"cdn\.jsdelivr\.net/npm/prebid"#,  // Prebid 광고 경매
        #"ruliweb\.com/banneriframe"#,  // 루리웹 자체 배너
    ]

    /// Ad slots hidden on every page, so blocked ads don't leave empty frames behind.
    /// Only selectors that never match real content.
    static let hiddenSelectors: [String] = [
        "ins.adsbygoogle", #"[id^="google_ads_iframe_"]"#, #"[id^="div-gpt-ad"]"#,
        "ins.kakao_ad_area", #"iframe[src*="kakaocdn.net/kas/"]"#, #"iframe[src*="daumcdn.net/kas/"]"#,
        #"iframe[src*="veta.naver.com"]"#, #"iframe[src*="/RealMedia/ads/"]"#,
        #"iframe[src*="ads-partners.coupang.com"]"#,
        #"[id^="taboola-"]"#, ".trc_related_container", ".OUTBRAIN", #"[id^="dablewidget"]"#,
    ]

    /// Ad slots whose names only mean "ad" on one site, hidden on that site and its subdomains.
    static let siteHiddenSelectors: [String: [String]] = [
        "ruliweb.com": [#"[id^="ad_"]"#, ".ad", #"iframe[src*="/banneriframe"]"#],
    ]
}
