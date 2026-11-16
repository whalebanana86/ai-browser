import AppKit
import Foundation
import Testing
import WebKit

@testable import Feather

/// Hangul documents, built here byte by byte following Hancom's format documents, so the
/// tests don't depend on anyone's files.
@MainActor
struct HWPDocumentTests {
    // MARK: HWP 5

    @Test func readsTextTablesAndTextBoxesFromHWP5() throws {
        let content = try HWPDocument.read(HWPFixture.hwp5())
        let paragraphs = content.paragraphs
        #expect(content.notice == nil)
        try #require(paragraphs.count == 6)
        #expect(paragraphs[0].text == "안녕하세요\tFeather\n", "a tab control is 8 units long; 13 ends the paragraph")
        #expect(paragraphs[1].text == "표 앞\n", "the table's own control character is skipped")
        #expect(paragraphs[1].tables == [HWPDocument.Table(cells: [
            HWPDocument.Cell(row: 0, column: 0, rowSpan: 1, columnSpan: 2, paragraphs: [.init(text: "A1 병합")]),
            HWPDocument.Cell(row: 1, column: 0, paragraphs: [.init(text: "A2")]),
            HWPDocument.Cell(row: 1, column: 1, paragraphs: [.init(text: "B2"), .init(text: "B2 둘째 줄")]),
        ])])
        #expect(paragraphs[2].text == "글상자 밖")
        #expect(paragraphs[2].tables.first?.cells.first?.paragraphs.map(\.text) == ["글상자 안"])
        #expect(paragraphs[3].text == "<b>꺾쇠</b> & 끝")
        #expect(paragraphs[4].text == "", "an empty paragraph")
        #expect(paragraphs[5].text == HWPFixture.longText, "a second section, big enough for regular sectors and a long record")

        let html = HWPDocument.html(content, title: "test.hwp")
        #expect(html.contains("<tr><td colspan=\"2\"><p>A1 병합</p></td></tr><tr><td><p>A2</p></td><td><p>B2</p><p>B2 둘째 줄</p></td></tr>"))
        #expect(html.contains("<p>&lt;b&gt;꺾쇠&lt;/b&gt; &amp; 끝</p>"), "text is escaped, never markup")
        #expect(html.contains("글자와 표만 보여 줍니다"))
    }

    @Test func fixtureReallyUsesBothStreamKinds() throws {
        let streams = HWPFixture.hwp5Streams()
        #expect(streams.contains { $0.data.count < 4096 }, "mini stream")
        #expect(streams.contains { $0.data.count >= 4096 }, "regular sectors")
        let file = try CompoundFile(HWPFixture.hwp5())
        for stream in streams { #expect(file.stream(stream.path) == stream.data, "\(stream.path)") }
        #expect(file.stream("BodyText/Section9") == nil)
    }

    @Test func lockedAndForeignFilesSayWhy() throws {
        let distribution = try HWPDocument.read(HWPFixture.hwp5(properties: 0b101, body: false))
        #expect(distribution.paragraphs.map(\.text) == ["미리보기 글", "", "둘째 줄"])
        #expect(distribution.notice?.contains("배포용") == true)
        #expect(throws: HWPDocument.Failure.encrypted) { try HWPDocument.read(HWPFixture.hwp5(properties: 0b11)) }
        #expect(throws: HWPDocument.Failure.oldFormat) { try HWPDocument.read(Data("HWP Document File V3.00 \u{1A}\u{1}\u{2}".utf8)) }
        #expect(throws: HWPDocument.Failure.notHWP) { try HWPDocument.read(Data("%PDF-1.4".utf8)) }
        #expect(throws: (any Error).self) { try HWPDocument.read(HWPFixture.hwp5().prefix(1500)) }
    }

    /// Downloaded files can be anything: damaged ones give an error or less text, never a crash.
    @Test func damagedFilesNeverCrash() {
        for original in [HWPFixture.hwp5(), HWPFixture.hwpx(), HWPFixture.hwp5(properties: 0b101, body: false)] {
            var seed: UInt64 = 7
            for round in 0..<300 {
                var damaged = original
                for _ in 0..<(1 + round % 8) {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1
                    let index = Int(seed >> 33) % damaged.count
                    damaged[index] = UInt8(truncatingIfNeeded: seed >> 17)
                }
                if round % 10 == 0 { damaged = damaged.prefix(Int(seed >> 40) % damaged.count) }
                _ = try? HWPDocument.read(damaged)
            }
        }
    }

    // MARK: HWPX

    @Test func readsHWPX() throws {
        let content = try HWPDocument.read(HWPFixture.hwpx())
        #expect(content.paragraphs.map(\.text) == ["첫 문단\t탭 뒤", "표 앞", "둘째 구역 & 끝\n다음 줄"],
                "sections in order (section2 after section1), deflated and stored entries")
        try #require(content.paragraphs.count == 3)
        #expect(content.paragraphs[1].tables == [HWPDocument.Table(cells: [
            HWPDocument.Cell(row: 0, column: 0, rowSpan: 1, columnSpan: 2, paragraphs: [.init(text: "A1")]),
            HWPDocument.Cell(row: 1, column: 0, paragraphs: [.init(text: "A2")]),
            HWPDocument.Cell(row: 1, column: 1, paragraphs: [.init(text: "B2")]),
        ])])
    }

    // MARK: In the viewer

    @Test func hwpOpensInFeathersOwnScriptFreeView() async throws {
        #expect(DocumentViewer.shouldPreview(fileName: "공문.hwp", isMainFrame: true, isAttachment: true, canShow: false))
        #expect(DocumentViewer.shouldPreview(fileName: "공문.HWPX", isMainFrame: true, isAttachment: false, canShow: false))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("feather-hwp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("공문.hwp")
        try HWPFixture.hwp5().write(to: file)

        let viewer = DocumentViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        viewer.show(DocumentPreview(file: file, source: nil))
        #expect(viewer.quickLook == nil, "macOS can't preview HWP")
        let webView = try #require(viewer.ownView as? WKWebView)
        #expect(!webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(!webView.configuration.websiteDataStore.isPersistent)
        for _ in 0..<100 where webView.isLoading || webView.url == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let text = try await webView.evaluateJavaScript("document.body.innerText") as? String
        #expect(text?.contains("안녕하세요") == true)
        #expect(text?.contains("A1 병합") == true)
        viewer.clear()
        #expect(viewer.ownView == nil)
    }
}

/// Writes HWP 5 and HWPX files the way Hancom's format documents describe.
enum HWPFixture {
    struct Stream {
        var path: String
        var data: Data
    }

    /// Pseudo-random syllables: they compress poorly, so the section stays over 4 KB.
    static let longText: String = {
        var seed: UInt32 = 12_345
        return String((0..<4_000).map { _ -> Character in
            seed = seed &* 1_103_515_245 &+ 12_345
            return Character(UnicodeScalar(0xAC00 + (seed >> 8) % 11_172)!)
        })
    }()

    static func hwp5(properties: UInt32 = 0b1, body: Bool = true) -> Data {
        compoundFile(hwp5Streams(properties: properties, body: body))
    }

    static func hwp5Streams(properties: UInt32 = 0b1, body: Bool = true) -> [Stream] {
        var header = Data("HWP Document File".utf8)
        header += Data(count: 32 - header.count)
        header += Data([0, 3, 0, 5]) + le32(properties)
        header += Data(count: 256 - header.count)
        var streams = [Stream(path: "FileHeader", data: header),
                       Stream(path: "PrvText", data: utf16("미리보기 글\r\n둘째 줄"))]
        guard body else { return streams }

        var first = Data()
        first += paragraph(utf16("안녕하세요") + control(9) + utf16("Feather") + units([13]))
        first += paragraph(control(11) + utf16("표 앞") + units([13]))
        first += record(71, level: 1, fourCC("tbl ") + Data(count: 40))
        first += record(77, level: 2, Data(count: 20))  // the table's own properties
        first += cell(column: 0, row: 0, columnSpan: 2, ["A1 병합"])
        first += cell(column: 0, row: 1, ["A2"])
        first += cell(column: 1, row: 1, ["B2", "B2 둘째 줄"])
        first += paragraph(utf16("글상자 밖") + control(11))
        first += record(71, level: 1, fourCC("gso ") + Data(count: 40))
        first += record(76, level: 2, Data(count: 30))  // shape component
        first += record(72, level: 2, le16(1) + Data(count: 6))
        first += paragraph(utf16("글상자 안"), level: 2)
        first += paragraph(utf16("<b>꺾쇠</b> & 끝"))
        first += paragraph(Data())
        let second = paragraph(utf16(longText))
        streams.append(Stream(path: "BodyText/Section0", data: deflate(first)))
        streams.append(Stream(path: "BodyText/Section1", data: deflate(second)))
        streams.append(Stream(path: "DocInfo", data: deflate(Data(count: 100))))
        return streams
    }

    private static func cell(column: Int, row: Int, columnSpan: Int = 1, rowSpan: Int = 1, _ texts: [String]) -> Data {
        var header = le16(texts.count) + Data(count: 2) + Data(count: 4)
        header += le16(column) + le16(row) + le16(columnSpan) + le16(rowSpan) + Data(count: 20)
        return record(72, level: 2, header) + texts.map { paragraph(utf16($0), level: 2) }.reduce(Data(), +)
    }

    private static func paragraph(_ text: Data, level: UInt32 = 0) -> Data {
        record(66, level: level, Data(count: 22)) + (text.isEmpty ? Data() : record(67, level: level + 1, text))
    }

    /// An 8-unit control: the code, six units of data, the code again.
    private static func control(_ code: UInt16) -> Data {
        units([code, 0x7462, 0x206C, 0, 0, 0, 0, code])
    }

    private static func record(_ tag: UInt32, level: UInt32, _ data: Data) -> Data {
        if data.count < 0xFFF { return le32(tag | level << 10 | UInt32(data.count) << 20) + data }
        return le32(tag | level << 10 | 0xFFF << 20) + le32(UInt32(data.count)) + data
    }

    private static func fourCC(_ code: String) -> Data {
        le32(code.utf8.reduce(0) { $0 << 8 | UInt32($1) })
    }

    private static func utf16(_ text: String) -> Data { units(Array(text.utf16)) }
    private static func units(_ units: [UInt16]) -> Data { units.map { le16(Int($0)) }.reduce(Data(), +) }
    static func le16(_ value: Int) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]) }
    static func le32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8(value >> ($0 * 8) & 0xFF) }) }
    private static func le64(_ value: Int) -> Data { le32(UInt32(value)) + le32(0) }
    static func deflate(_ data: Data) -> Data { (try? (data as NSData).compressed(using: .zlib) as Data) ?? data }

    // MARK: Compound file

    /// 512-byte sectors; streams under 4096 bytes go into the mini stream, as Hancom's files do.
    static func compoundFile(_ streams: [Stream]) -> Data {
        let sector = 512, mini = 64, cutoff = 4096
        let free: UInt32 = 0xFFFF_FFFF, end: UInt32 = 0xFFFF_FFFE, fatMark: UInt32 = 0xFFFF_FFFD

        // Directory entries: root, storages, streams; each storage's children chained by `right`.
        struct Entry {
            var name: String, type: UInt8, data = Data(), child: UInt32 = 0xFFFF_FFFF, right: UInt32 = 0xFFFF_FFFF
            var start: UInt32 = 0xFFFF_FFFE, size = 0
        }
        var entries = [Entry(name: "Root Entry", type: 5)]
        var storageIndex: [String: Int] = ["": 0]
        func storage(_ path: String) -> Int {
            if let index = storageIndex[path] { return index }
            let parent = storage((path as NSString).deletingLastPathComponent)
            entries.append(Entry(name: (path as NSString).lastPathComponent, type: 1))
            link(entries.count - 1, under: parent)
            storageIndex[path] = entries.count - 1
            return entries.count - 1
        }
        func link(_ index: Int, under parent: Int) {
            if entries[parent].child == 0xFFFF_FFFF {
                entries[parent].child = UInt32(index)
                return
            }
            var last = Int(entries[parent].child)
            while entries[last].right != 0xFFFF_FFFF { last = Int(entries[last].right) }
            entries[last].right = UInt32(index)
        }
        for stream in streams {
            let parent = storage((stream.path as NSString).deletingLastPathComponent)
            entries.append(Entry(name: (stream.path as NSString).lastPathComponent, type: 2, data: stream.data, size: stream.data.count))
            link(entries.count - 1, under: parent)
        }

        // Mini stream and its FAT.
        var miniStream = Data(), miniFAT: [UInt32] = []
        for index in entries.indices where entries[index].type == 2 && entries[index].size < cutoff {
            let count = max(1, (entries[index].size + mini - 1) / mini)
            entries[index].start = UInt32(miniFAT.count)
            for step in 0..<count { miniFAT.append(step == count - 1 ? end : UInt32(miniFAT.count + 1)) }
            var padded = entries[index].data
            padded += Data(count: count * mini - padded.count)
            miniStream += padded
        }

        let sectors = { (bytes: Int) in (bytes + sector - 1) / sector }
        let directorySectors = sectors(entries.count * 128)
        let miniFATSectors = sectors(miniFAT.count * 4)
        let miniStreamSectors = sectors(miniStream.count)
        let bigSectors = entries.filter { $0.type == 2 && $0.size >= cutoff }.map { sectors($0.size) }.reduce(0, +)
        let others = directorySectors + miniFATSectors + miniStreamSectors + bigSectors
        var fatSectors = 1
        while fatSectors * (sector / 4) < others + fatSectors { fatSectors += 1 }

        var fat = [UInt32](repeating: free, count: fatSectors * (sector / 4))
        var next = 0
        func allocate(_ count: Int) -> UInt32 {
            guard count > 0 else { return end }
            let start = next
            for index in start..<start + count { fat[index] = index == start + count - 1 ? end : UInt32(index + 1) }
            next += count
            return UInt32(start)
        }
        for index in 0..<fatSectors { fat[index] = fatMark }
        next = fatSectors
        let directoryStart = allocate(directorySectors)
        let miniFATStart = allocate(miniFATSectors)
        entries[0].start = allocate(miniStreamSectors)
        entries[0].size = miniStream.count
        var body = Data()
        for index in entries.indices where entries[index].type == 2 && entries[index].size >= cutoff {
            entries[index].start = allocate(sectors(entries[index].size))
            var padded = entries[index].data
            padded += Data(count: sectors(padded.count) * sector - padded.count)
            body += padded
        }

        var header = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 16)
        header += le16(0x3E) + le16(3) + le16(0xFFFE) + le16(9) + le16(6) + Data(count: 6)
        header += le32(0) + le32(UInt32(fatSectors)) + le32(directoryStart) + le32(0) + le32(UInt32(cutoff))
        header += le32(miniFATSectors > 0 ? miniFATStart : end) + le32(UInt32(miniFATSectors)) + le32(end) + le32(0)
        header += (0..<109).map { $0 < fatSectors ? le32(UInt32($0)) : le32(free) }.reduce(Data(), +)

        var directory = Data()
        for entry in entries {
            var record = Data()
            let name = Array(entry.name.utf16)
            record += units(name) + Data(count: 64 - name.count * 2)
            record += le16((name.count + 1) * 2) + Data([entry.type, 1])
            record += le32(0xFFFF_FFFF) + le32(entry.right) + le32(entry.child) + Data(count: 16 + 4 + 16)
            record += le32(entry.start) + le64(entry.size)
            directory += record
        }
        directory += Data(count: directorySectors * sector - directory.count)
        var miniFATData = miniFAT.map(le32).reduce(Data(), +)
        miniFATData += Data(count: miniFATSectors * sector - miniFATData.count)
        miniStream += Data(count: miniStreamSectors * sector - miniStream.count)
        let fatData = fat.map(le32).reduce(Data(), +)
        return header + fatData + directory + miniFATData + miniStream + body
    }

    // MARK: HWPX

    static func hwpx() -> Data {
        let ns = #"xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph""#
        func tc(_ text: String, column: Int, row: Int, span: Int = 1) -> String {
            #"<hp:tc><hp:subList><hp:p><hp:run><hp:t>\#(text)</hp:t></hp:run></hp:p></hp:subList>"#
                + #"<hp:cellAddr colAddr="\#(column)" rowAddr="\#(row)"/><hp:cellSpan colSpan="\#(span)" rowSpan="1"/></hp:tc>"#
        }
        let first = #"<?xml version="1.0" encoding="UTF-8"?><hs:sec \#(ns)>"#
            + "<hp:p><hp:run><hp:t>첫 문단</hp:t><hp:tab/><hp:t>탭 뒤</hp:t></hp:run></hp:p>"
            + #"<hp:p><hp:run><hp:t>표 앞</hp:t><hp:tbl rowCnt="2" colCnt="2"><hp:tr>"# + tc("A1", column: 0, row: 0, span: 2)
            + "</hp:tr><hp:tr>" + tc("A2", column: 0, row: 1) + tc("B2", column: 1, row: 1) + "</hp:tr></hp:tbl></hp:run></hp:p></hs:sec>"
        let second = #"<?xml version="1.0" encoding="UTF-8"?><hs:sec \#(ns)>"#
            + "<hp:p><hp:run><hp:t>둘째 구역 &amp; 끝<hp:lineBreak/>다음 줄</hp:t></hp:run></hp:p></hs:sec>"
        return zip([
            ("mimetype", Data("application/hwp+zip".utf8), false),
            ("Contents/section2.xml", Data(second.utf8), false),
            ("Contents/section1.xml", Data(first.utf8), true),
            ("Contents/header.xml", Data("<head/>".utf8), true),
        ])
    }

    private static func zip(_ files: [(name: String, data: Data, deflated: Bool)]) -> Data {
        var archive = Data(), central = Data()
        for file in files {
            let stored = file.deflated ? deflate(file.data) : file.data
            let method = le16(file.deflated ? 8 : 0)
            let name = Data(file.name.utf8)
            let sizes = le32(0) + le32(UInt32(stored.count)) + le32(UInt32(file.data.count))  // CRC left 0
            central += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + method + le32(0) + sizes
            central += le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(UInt32(archive.count)) + name
            archive += le32(0x0403_4B50) + le16(20) + le16(0) + method + le32(0) + sizes + le16(name.count) + le16(0) + name + stored
        }
        let end = le32(0x0605_4B50) + le16(0) + le16(0) + le16(files.count) + le16(files.count)
            + le32(UInt32(central.count)) + le32(UInt32(archive.count)) + le16(0)
        return archive + central + end
    }
}
