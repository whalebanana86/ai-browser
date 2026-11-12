import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var browser: BrowserWindowController?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        WebKitEnvironment.shared.prepare { [weak self] in self?.launchBrowser() }
    }

    private func launchBrowser() {
        let browser = BrowserWindowController()
        self.browser = browser
        if Benchmark.isRequested {
            browser.persistsSession = false
            browser.showWindow(nil)
            Benchmark.run(in: browser)
        } else {
            if !browser.restoreSession(), pendingURLs.isEmpty { browser.openTab(nil) }
            pendingURLs.forEach { browser.openTab($0) }
            pendingURLs = []
            browser.showWindow(nil)
        }
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Links opened from other apps when Feather is the default browser.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let browser else {
            pendingURLs += urls
            return
        }
        urls.forEach { browser.openTab($0) }
        browser.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        browser?.saveSession()
        TranslatorProcess.shared.stop()
    }
}
