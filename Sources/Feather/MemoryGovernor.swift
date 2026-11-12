import Foundation

@MainActor
protocol TabHost: AnyObject {
    var tabs: [Tab] { get }
    var activeTab: Tab? { get }
}

/// Keeps the browser's real memory use (app + every WebKit process working for it) under
/// budget by suspending background tabs. A suspended tab keeps its URL, title, back/forward
/// list and scroll position (a few KB) and reloads when selected.
///
/// A background tab is suspended when any of these hold:
/// - more than `Settings.maxLiveTabs` tabs are live,
/// - total footprint is over `Settings.memoryBudget`,
/// - it hasn't been looked at for `Settings.idleSuspendAfter`,
/// - macOS signals memory pressure.
/// A tab in the middle of a login or with typed text is never suspended (a reload would lose
/// it, e.g. a sign-in code page left open while fetching the code from mail), unless macOS
/// reports critical pressure.
/// Over budget, the biggest background tabs go first, so as few tabs as possible need reloading;
/// otherwise the least recently used. Tabs playing audio or using the camera/microphone are
/// spared, unless macOS reports critical pressure or memory passes the hard limit (budget + 25%).
@MainActor
final class MemoryGovernor {
    weak var host: TabHost?
    var onSample: ((MemoryMeter.Sample) -> Void)?
    private(set) var peak: UInt64 = 0
    /// Live-tab limit; tests set their own instead of changing the shared setting.
    var maxLiveTabs: () -> Int = { Settings.maxLiveTabs }

    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var checking = false
    private var checkScheduled = false

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.check() }
        }
        timer?.tolerance = 1
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.pressureSource?.data else { return }
                self.check(pressure: event)
            }
        }
        source.resume()
        pressureSource = source
    }

    /// Coalesces bursts (several tabs finishing at once) into one check.
    func setNeedsCheck(after delay: TimeInterval = 0.5) {
        guard !checkScheduled else { return }
        checkScheduled = true
        onMain(after: delay) { [weak self] in
            self?.checkScheduled = false
            self?.check()
        }
    }

    /// Returns the running check, so tests can wait for it.
    @discardableResult
    func check(pressure: DispatchSource.MemoryPressureEvent = []) -> Task<Void, Never>? {
        guard let host, !checking else { return nil }
        let sample = Self.measure(host.tabs)
        peak = max(peak, sample.total)
        onSample?(sample)

        let now = Date()
        let footprint = { (tab: Tab) in tab.webView?.processIdentifier.flatMap { sample.byPID[$0] } ?? 0 }
        let short = sample.total > Settings.memoryBudget || !pressure.isEmpty
        let candidates = host.tabs
            .filter { $0.isLive && $0 !== host.activeTab }
            .sorted { short ? footprint($0) > footprint($1) : $0.lastActive < $1.lastActive }
        guard !candidates.isEmpty else { return nil }

        checking = true
        return Task { @MainActor in
            defer { checking = false }
            var live = host.tabs.filter(\.isLive).count
            var projected = sample.total
            var suspendedAny = false
            for tab in candidates {
                let idle = now.timeIntervalSince(tab.lastActive) > Settings.idleSuspendAfter
                let overCount = live > maxLiveTabs()
                let overBudget = projected > Settings.memoryBudget
                guard idle || overCount || overBudget || !pressure.isEmpty else { continue }
                let hardLimit = Settings.memoryBudget + Settings.memoryBudget / 4
                let spareMedia = !pressure.contains(.critical) && projected <= hardLimit
                if spareMedia, await tab.isUsingMedia() { continue }
                if !pressure.contains(.critical), await tab.hasWorkInProgress() { continue }
                // The user may have switched to this tab while we were waiting.
                guard tab.isLive, tab !== host.activeTab else { continue }
                let freed = footprint(tab)
                tab.suspend()
                suspendedAny = true
                live -= 1
                projected -= min(freed, projected)
                // Without a per-tab figure, free one tab at a time and re-measure.
                if freed == 0, overBudget, !overCount, !idle, pressure.isEmpty { break }
            }
            // Web processes exit asynchronously; measure again once they're gone.
            if suspendedAny { setNeedsCheck(after: 1.5) }
        }
    }

    static func measure(_ tabs: [Tab]) -> MemoryMeter.Sample {
        let webViews = tabs.compactMap(\.webView)
        let pids = webViews.compactMap(\.processIdentifier) + (webViews.first?.sharedProcessIdentifiers ?? [])
        return MemoryMeter.sample(including: pids, excluding: TranslatorProcess.shared.pid.map { [$0] } ?? [])
    }
}
