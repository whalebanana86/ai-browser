/// Trackers, ad exchanges, data brokers and session-replay services blocked on every site.
/// Requests to these hosts (and their subdomains) are blocked only when loaded as a third
/// party, so the services' own websites keep working.
enum TrackerList {
    static let domains: [String] = [
        // Google ads & analytics
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagmanager.com", "googletagservices.com", "adservice.google.com", "app-measurement.com",
        "adtrafficquality.google", "fundingchoicesmessages.google.com",
        // Social & platform pixels
        "connect.facebook.net", "analytics.twitter.com", "ads-twitter.com", "px.ads.linkedin.com",
        "snap.licdn.com", "analytics.tiktok.com", "ads.tiktok.com", "ct.pinterest.com", "tr.snapchat.com",
        "sc-static.net", "events.redditmedia.com", "alb.reddit.com", "bat.bing.com", "clarity.ms",
        // Ad exchanges, DSPs, SSPs
        "amazon-adsystem.com", "adnxs.com", "rubiconproject.com", "pubmatic.com", "openx.net",
        "casalemedia.com", "indexww.com", "adsrvr.org", "bidswitch.net", "smartadserver.com", "teads.tv",
        "triplelift.com", "3lift.com", "sharethrough.com", "media.net", "contextweb.com", "lijit.com",
        "gumgum.com", "adform.net", "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "adroll.com",
        "rfihub.com", "serving-sys.com", "mathtag.com", "advertising.com", "yieldmo.com", "33across.com",
        "sonobi.com", "emxdgt.com", "rhythmone.com", "spotxchange.com", "springserve.com", "zemanta.com",
        "revcontent.com", "mgid.com", "adsterra.com", "popads.net", "propellerads.com", "exoclick.com",
        "yieldlab.net", "adition.com", "smaato.net", "inmobi.com", "unityads.unity3d.com",
        // Data brokers & ID syncing
        "demdex.net", "everesttech.net", "omtrdc.net", "2o7.net", "bluekai.com", "krxd.net", "rlcdn.com",
        "tapad.com", "crwdcntrl.net", "agkn.com", "exelator.com", "eyeota.net", "id5-sync.com",
        "liveintent.com", "adsymptotic.com", "bounceexchange.com", "bouncex.net", "addthis.com",
        "sharethis.com", "quantserve.com", "quantcount.com", "scorecardresearch.com", "imrworldwide.com",
        "moatads.com", "doubleverify.com", "adsafeprotected.com", "chartbeat.com", "chartbeat.net",
        "pixel.parsely.com",
        // Product analytics, session replay, fingerprinting
        "hotjar.com", "hotjar.io", "fullstory.com", "mouseflow.com", "crazyegg.com", "luckyorange.com",
        "luckyorange.net", "inspectlet.com", "smartlook.com", "lr-ingest.io", "lr-in-prod.com",
        "heapanalytics.com", "mixpanel.com", "mxpnl.com", "segment.io", "cdn.segment.com", "amplitude.com",
        "kissmetrics.io", "woopra.com", "statcounter.com", "getclicky.com", "nr-data.net",
        "browser-intake-datadoghq.com", "cloudflareinsights.com", "logx.optimizely.com", "track.hubspot.com",
        "hs-analytics.net", "munchkin.marketo.net", "pi.pardot.com", "websdk.appsflyer.com", "pixel.wp.com",
        "stats.wp.com", "fpjs.io", "fpcdn.io",
        // Regional analytics
        "mc.yandex.ru", "mc.yandex.com", "hm.baidu.com", "cnzz.com", "umeng.com", "top-fwz1.mail.ru",
        // Korea
        "wcs.naver.net", "wcs.naver.com", "wcs.pstatic.net", "lcs.naver.com", "ad.daum.net",
        "tiara.kakao.com", "tiara.daum.net", "dable.io", "mobon.net", "mediacategory.com",
        "realclick.co.kr", "acecounter.com", "logger.co.kr", "wisetracker.co.kr", "tenping.kr",
        "clickmon.co.kr", "adop.cc", "cauly.co.kr",
    ]

    /// Tracking endpoints on hosts that also serve real content, in WebKit content-rule regex
    /// syntax (everything after the host prefix).
    static let pathPatterns: [String] = [
        #"facebook\.com/tr[/?]"#,
        #"google\.com/pagead/"#,
        #"daumcdn\.net/kas/"#,
        #"pinimg\.com/ct/"#,
    ]
}
