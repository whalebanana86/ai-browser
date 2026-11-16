import AppKit
import Foundation
import Network
import Testing
import WebKit

@testable import Feather

/// Gmail's attachment button downloads through a hidden frame. Such a download goes through
/// right after the user's click; one a frame starts on its own (an ad pushing a file) doesn't.
@MainActor
@Suite(.serialized)
struct FrameDownloadTests {
    /// A button filling the top-left corner (where `UserInput` clicks) that loads `path` in a hidden frame.
    private static func page(loading path: String, onLoad: Bool = false) -> String {
        let load = "const i = document.createElement('iframe'); i.style.display = 'none'; i.src = '\(path)'; document.body.append(i);"
        let button = "<button id=\"f\" style=\"position:absolute;left:0;top:0;width:300px;height:80px\" onclick=\"\(load)\">Download</button>"
        return button + (onLoad ? "<script>\(load)</script>" : "")
    }

    private func run(_ html: String, click: Bool) async throws -> [String] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("feather-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try await LocalServer(routes: [
            "/": ("text/html", nil, Data(html.utf8)),
            "/pdf": ("application/pdf", "attachment; filename=\"payslip.pdf\"", Data("%PDF-1.1\n%%EOF".utf8)),
            "/html": ("text/html", "attachment; filename=\"payslip.html\"", Data("<p>secure mail</p>".utf8)),
        ])
        defer { server.stop() }

        _ = NSApplication.shared
        let browser = BrowserWindowController()
        browser.persistsSession = false
        browser.governor.stop()
        let previousFolder = Downloads.shared.folder
        Downloads.shared.folder = folder
        defer { Downloads.shared.folder = previousFolder }

        let tab = browser.openTab(server.url, activate: false)
        let webView = tab.wake()
        for _ in 0..<100 where webView.isLoading || webView.url == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        let user = try UserInput(tab)
        if click {
            await user.click()
        } else {
            _ = try? await webView.evaluateJavaScript("document.getElementById('f').click(); 0")  // the page itself, no user
        }
        for _ in 0..<30 {  // up to 3 s
            if !(try FileManager.default.contentsOfDirectory(atPath: folder.path)).isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    @Test func attachmentInAFrameRightAfterAClickIsSaved() async throws {
        #expect(try await run(Self.page(loading: "/pdf"), click: true) == ["payslip.pdf"])
        #expect(try await run(Self.page(loading: "/html"), click: true) == ["payslip.html"], "Gmail's secure-mail HTML attachments too")
    }

    @Test func attachmentAFramePushesWithoutTheUserIsNot() async throws {
        #expect(try await run(Self.page(loading: "/pdf", onLoad: true), click: false) == [], "started while loading")
        #expect(try await run(Self.page(loading: "/pdf"), click: false) == [], "a button the page pressed itself")

        BrowserWebView.userActionWindow = 1
        defer { BrowserWebView.userActionWindow = 10 }
        #expect(try await run(Self.page(loading: "/pdf"), click: true) == ["payslip.pdf"], "within the window")
        // The page answers the click 1.5 s later, past the (shortened) window.
        #expect(try await run("<div id=\"f\" style=\"position:absolute;left:0;top:0;width:300px;height:80px\"></div>"
            + "<button id=\"b\" onclick=\"const i = document.createElement('iframe'); i.style.display = 'none'; i.src = '/pdf'; document.body.append(i);\"></button>"
            + "<script>document.getElementById('f').onmousedown = () => setTimeout(() => document.getElementById('b').click(), 1500)</script>",
            click: true) == [], "long after the user's last click")
    }
}

/// A one-file-per-path HTTP server on 127.0.0.1, for headers a data: URL can't carry.
final class LocalServer: @unchecked Sendable {
    typealias Route = (type: String, disposition: String?, body: Data)
    let url: URL
    private let listener: NWListener

    init(routes: [String: Route]) async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                var head = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                var body = Data()
                if let route = routes[path] {
                    body = route.body
                    head = "HTTP/1.1 200 OK\r\nContent-Type: \(route.type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
                        + (route.disposition.map { "Content-Disposition: \($0)\r\n" } ?? "") + "\r\n"
                }
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state, let port = listener.port?.rawValue {
                    continuation.yield(port)
                    continuation.finish()
                }
            }
        }
        listener.start(queue: .global())
        var port: UInt16 = 0
        for await value in ready { port = value }
        self.listener = listener
        url = URL(string: "http://127.0.0.1:\(port)/")!
    }

    func stop() { listener.cancel() }
}
