import AppKit

@MainActor
enum MainMenu {
    private typealias Browser = BrowserWindowController

    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("Feather", [
            item("Feather에 관하여", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("쿠키 및 캐시 지우기…", #selector(Browser.clearBrowsingData(_:))),
            .separator(),
            item("Feather 가리기", #selector(NSApplication.hide(_:)), "h"),
            item("기타 가리기", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("모두 보기", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Feather 종료", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("파일", [
            item("새 탭", #selector(Browser.newTabAction(_:)), "t"),
            item("닫은 탭 다시 열기", #selector(Browser.reopenClosedTab(_:)), "t", [.command, .shift]),
            item("주소창으로 이동", #selector(Browser.focusAddressBar(_:)), "l"),
            .separator(),
            item("탭 닫기", #selector(Browser.closeTabAction(_:)), "w"),
        ]))
        main.addItem(submenu("편집", [
            item("실행 취소", Selector(("undo:")), "z"),
            item("실행 복귀", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("오려두기", #selector(NSText.cut(_:)), "x"),
            item("복사하기", #selector(NSText.copy(_:)), "c"),
            item("붙여넣기", #selector(NSText.paste(_:)), "v"),
            item("붙여넣기 및 스타일 일치", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("모두 선택", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("찾기…", #selector(Browser.findAction(_:)), "f"),
            item("다음 찾기", #selector(Browser.findNextAction(_:)), "g"),
            item("이전 찾기", #selector(Browser.findPreviousAction(_:)), "g", [.command, .shift]),
        ]))
        main.addItem(submenu("보기", [
            item("새로고침", #selector(Browser.reloadAction(_:)), "r"),
            item("캐시 무시하고 새로고침", #selector(Browser.reloadFromOriginAction(_:)), "r", [.command, .shift]),
            .separator(),
            item("확대", #selector(Browser.zoomInAction(_:)), "="),
            item("축소", #selector(Browser.zoomOutAction(_:)), "-"),
            item("실제 크기", #selector(Browser.actualSizeAction(_:)), "0"),
            .separator(),
            item("전체 화면", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        main.addItem(submenu("방문", [
            item("뒤로", #selector(Browser.goBackAction(_:)), "["),
            item("앞으로", #selector(Browser.goForwardAction(_:)), "]"),
        ]))
        let windowMenu = submenu("윈도우", [
            item("최소화", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("확대/축소", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("다음 탭", #selector(Browser.nextTabAction(_:)), "}", [.command, .shift]),
            item("이전 탭", #selector(Browser.previousTabAction(_:)), "{", [.command, .shift]),
            .separator(),
        ] + (1...9).map { number in
            let entry = item(number == 9 ? "마지막 탭" : "탭 \(number)", #selector(Browser.selectTabByNumber(_:)), "\(number)")
            entry.tag = number
            return entry
        })
        main.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu
        return main
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
