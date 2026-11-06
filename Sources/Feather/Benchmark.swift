import AppKit

/// `Feather --bench [--browse N] [url …]`: opens 20 popular sites (or the given URLs) one after
/// another, each in a new tab, then prints per-site load times and the browser's total memory
/// footprint, and quits. `--browse N` also follows N links within each site, the way people
/// actually use a tab. The saved session is left untouched.
@MainActor
enum Benchmark {
    static var isRequested: Bool { CommandLine.arguments.contains("--bench") }

    private static let defaultSites = [
        "https://www.naver.com", "https://www.daum.net", "https://www.google.com", "https://www.youtube.com",
        "https://ko.wikipedia.org/wiki/%EB%8C%80%ED%95%9C%EB%AF%BC%EA%B5%AD", "https://news.naver.com",
        "https://www.coupang.com", "https://github.com", "https://www.apple.com/kr/", "https://www.amazon.com",
        "https://www.nytimes.com", "https://www.bbc.com", "https://www.reddit.com", "https://stackoverflow.com",
        "https://www.chosun.com", "https://www.yna.co.kr", "https://www.11st.co.kr", "https://www.instagram.com",
        "https://x.com", "https://www.netflix.com/kr/",
    ]

    private static var browseDepth: Int {
        guard let flag = CommandLine.arguments.firstIndex(of: "--browse"),
              CommandLine.arguments.indices.contains(flag + 1) else { return 0 }
        return Int(CommandLine.arguments[flag + 1]) ?? 0
    }

    private static var sites: [String] {
        let given = CommandLine.arguments.drop { $0 != "--bench" }.filter { $0.hasPrefix("http") }
        return given.isEmpty ? defaultSites : Array(given)
    }

    static func run(in browser: BrowserWindowController) {
        Task { @MainActor in
            let sites = self.sites
            let depth = browseDepth
            log("Feather 벤치마크 · 탭 \(sites.count)개\(depth > 0 ? " · 탭마다 링크 \(depth)번 이동" : "") · 실행 탭 상한 \(Settings.maxLiveTabs)개 · 메모리 예산 \(Settings.memoryBudget / 1_048_576) MB · 추적 차단 \(Settings.blocksTrackers ? "켬" : "끔")\n")
            var firstPaints: [Double] = []
            var peak: UInt64 = 0
            for (number, site) in sites.enumerated() {
                guard let url = URL(string: site) else {
                    log("\(number + 1). 잘못된 주소: \(site)")
                    continue
                }
                let started = CFAbsoluteTimeGetCurrent()
                let tab = browser.openTab(url)
                let finished = await waitForLoad(of: tab, timeout: 20)
                let wall = CFAbsoluteTimeGetCurrent() - started
                let moves = await browse(tab, depth: depth)
                let memory = MemoryGovernor.measure(browser.tabs)
                peak = max(peak, memory.total)
                let paint = tab.timing?.firstPaint
                if let paint { firstPaints.append(paint) }
                let name = (url.host ?? site).padding(toLength: 20, withPad: " ", startingAt: 0)
                let paintText = paint.map { String(format: "%5.2fs", $0) } ?? "    - "
                let note = (finished ? (tab.timing == nil ? "  (오류)" : "") : "  (20초 초과)")
                    + (depth > 0 ? "  (링크 \(moves)번 이동)" : "")
                let title = String(tab.displayTitle.prefix(24))
                log(String(format: "%2d. %@ 첫 화면 %@ · 로드 완료 %5.2fs · 메모리 %@  %@%@",
                           number + 1, name, paintText, wall, BrowserWindowController.format(memory.total), title, note))
            }

            log("\n정리 대기 중…")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            browser.governor.check()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            let final = MemoryGovernor.measure(browser.tabs)
            peak = max(peak, browser.governor.peak)

            let sorted = firstPaints.sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            let underOne = sorted.filter { $0 <= 1 }.count
            let live = browser.tabs.filter(\.isLive).count
            log(String(format: "\n첫 화면(FCP) 중앙값 %.2fs · 1초 이내 %d/%d", median, underOne, sorted.count))
            log("탭 \(browser.tabs.count)개 열림 · 실행 중 \(live)개 · 일시 중단 \(browser.tabs.count - live)개")
            log("최종 메모리 \(BrowserWindowController.format(final.total)) (앱 + WebKit 프로세스 \(final.processCount)개) · 최고 \(BrowserWindowController.format(peak))")
            for (pid, bytes) in final.byPID.sorted(by: { $0.value > $1.value }) {
                log("    \(BrowserWindowController.format(bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(processName(pid)) (\(pid))")
            }
            for tab in browser.tabs where tab.isLive {
                log("    실행 중: \(tab.displayTitle.prefix(30))\(tab === browser.activeTab ? " (현재 탭)" : "")")
            }
            NSApp.terminate(nil)
        }
    }

    /// Scrolls to the bottom (so lazy images and ads load) and follows a link on the same site,
    /// `depth` times. Returns how many links were followed.
    private static func browse(_ tab: Tab, depth: Int) async -> Int {
        var visited: Set<String> = []
        for move in 0..<depth {
            guard let webView = tab.webView else { return move }
            visited.insert(webView.url?.absoluteString ?? "")
            let script = """
                window.scrollTo(0, document.body.scrollHeight);
                await new Promise(resolve => setTimeout(resolve, 1000));
                const links = [...document.querySelectorAll('a[href]')].map(a => a.href).filter(href => {
                    try {
                        const url = new URL(href);
                        return url.host === location.host && url.pathname !== location.pathname && !visited.includes(href);
                    } catch { return false; }
                });
                return links[Math.floor(links.length / 2)] ?? null;
                """
            let result = try? await webView.callAsyncJavaScript(script, arguments: ["visited": Array(visited)],
                                                                 contentWorld: .defaultClient)
            guard let next = (result as? String).flatMap(URL.init(string:)) else { return move }
            tab.load(next)
            guard await waitForLoad(of: tab, timeout: 20) else { return move + 1 }
        }
        return depth
    }

    private static func waitForLoad(of tab: Tab, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            var resumed = false
            let finish: @MainActor (Bool) -> Void = { finished in
                guard !resumed else { return }
                resumed = true
                tab.onLoadFinished = nil
                continuation.resume(returning: finished)
            }
            tab.onLoadFinished = { _ in finish(true) }
            onMain(after: timeout) { finish(false) }
        }
    }

    private static func processName(_ pid: pid_t) -> String {
        URL(fileURLWithPath: MemoryMeter.path(of: pid)).lastPathComponent
    }

    private static func log(_ line: String) {
        print(line)
        fflush(stdout)
    }
}
