import Foundation

/// User-tunable limits. Override permanently with
/// `defaults write local.feather.browser maxLiveTabs -int 8`, or per launch with `-maxLiveTabs 8`.
enum Settings {
    /// Background tabs beyond this many are suspended (their web process is released).
    static var maxLiveTabs: Int { positive("maxLiveTabs") ?? 6 }
    /// Soft ceiling for the browser's total footprint: the app plus every WebKit process.
    static var memoryBudget: UInt64 { UInt64(positive("memoryBudgetMB") ?? 1024) * 1_048_576 }
    /// Background tabs left untouched this long are suspended.
    static var idleSuspendAfter: TimeInterval { TimeInterval(positive("idleSuspendMinutes") ?? 15) * 60 }
    /// Tracker blocking; turn off only to check whether it's what breaks a site.
    static var blocksTrackers: Bool { enabledUnlessTurnedOff("blockTrackers") }
    /// Ad blocking, separate from trackers so ads can be allowed without allowing tracking.
    static var blocksAds: Bool { enabledUnlessTurnedOff("blockAds") }
    /// Search engine; `%s` is replaced by the query.
    static var searchTemplate: String { UserDefaults.standard.string(forKey: "searchURL") ?? "https://duckduckgo.com/?q=%s" }

    private static func enabledUnlessTurnedOff(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil || UserDefaults.standard.bool(forKey: key)
    }

    private static func positive(_ key: String) -> Int? {
        let value = UserDefaults.standard.integer(forKey: key)
        return value > 0 ? value : nil
    }
}

/// Runs `work` on the main actor after `seconds`.
func onMain(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(work) }
}
