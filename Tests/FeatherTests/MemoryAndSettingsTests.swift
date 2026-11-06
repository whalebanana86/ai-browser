import Foundation
import Testing

@testable import Feather

struct MemoryMeterTests {
    @Test func measuresOwnFootprint() {
        #expect(MemoryMeter.footprint(of: getpid()) > 1_048_576)
    }

    @Test func missingProcessCountsAsZero() {
        #expect(MemoryMeter.footprint(of: 99_999) == 0)
    }

    @Test func sampleIncludesTheApp() throws {
        let sample = MemoryMeter.sample()
        let own = try #require(sample.byPID[getpid()])
        #expect(own > 0)
        #expect(sample.total >= own)
        #expect(sample.processCount == sample.byPID.count)
    }
}

/// The defaults the README promises; the 20-tabs-under-2GB result depends on them.
struct SettingsTests {
    @Test func defaults() {
        #expect(Settings.maxLiveTabs == 6)
        #expect(Settings.memoryBudget == 1024 * 1_048_576)
        #expect(Settings.idleSuspendAfter == 15 * 60)
        #expect(Settings.blocksTrackers)
        #expect(Settings.blocksAds)
        #expect(Settings.searchTemplate == "https://duckduckgo.com/?q=%s")
    }
}
