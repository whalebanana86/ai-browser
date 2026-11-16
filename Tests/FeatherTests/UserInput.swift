import AppKit
import Foundation
import Testing
import WebKit

@testable import Feather

/// Real AppKit events sent to a tab's web view, which reach the page as the user's own input
/// (`isTrusted`), the same way a key press, click or scroll in the app does.
@MainActor
struct UserInput {
    private static var windows: [NSWindow] = []  // kept open: closing them mid-run crashes WebKit
    let webView: WKWebView
    let window: NSWindow

    init(_ tab: Tab) throws {
        _ = NSApplication.shared
        webView = try #require(tab.webView)
        window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 600, height: 400), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        webView.frame = window.contentView!.bounds
        window.contentView!.addSubview(webView)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
        Self.windows.append(window)
    }

    /// A point inside the field, in window coordinates.
    private var point: NSPoint { webView.convert(NSPoint(x: 20, y: 20), to: nil) }

    func click() async {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            if type == .leftMouseDown { webView.mouseDown(with: event) } else { webView.mouseUp(with: event) }
        }
        await settle()
    }

    func focusWithoutClicking() async {
        _ = try? await webView.evaluateJavaScript("document.getElementById('f').focus(); 0")
        await settle()
    }

    func type(_ character: String) async {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: character,
                                               charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0) else { continue }
            if type == .keyDown { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
        }
        await settle()
    }

    func scroll() async {
        let screen = window.convertPoint(toScreen: point)
        for _ in 0..<3 {
            guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0)
            else { continue }
            wheel.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
            if let event = NSEvent(cgEvent: wheel) { webView.scrollWheel(with: event) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await settle()
    }

    /// The page itself changes the field (after running `script`), firing an input event.
    func pageChange(after script: String = "") async {
        _ = try? await webView.evaluateJavaScript(script + "const f = document.getElementById('f');"
            + "f.value = 'set by the page'; f.dispatchEvent(new Event('input', {bubbles: true})); 0")
    }

    func value() async throws -> String? {
        try await webView.evaluateJavaScript("document.getElementById('f').value") as? String
    }

    /// Lets the web process handle the events.
    private func settle() async {
        _ = try? await webView.evaluateJavaScript("0")
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
}
