import AppKit
import Foundation
import WebKit

/// Reads Hangul (한글) documents, which macOS can't preview: HWP 5 (a compound file of
/// deflated record streams) and HWPX (a zip of XML), following Hancom's published format
/// documents. Text and tables are shown; pictures and exact layout aren't. Everything
/// happens on the device.
enum HWPDocument {
    enum Failure: LocalizedError, Equatable {
        case notHWP
        case encrypted
        case oldFormat
        case damaged(String)

        var errorDescription: String? {
            switch self {
            case .notHWP: return "한글 문서가 아닙니다"
            case .encrypted: return "암호가 걸린 문서라 열 수 없습니다"
            case .oldFormat: return "HWP 3.0 이전의 옛 형식은 지원하지 않습니다"
            case .damaged(let what): return "문서를 읽지 못했습니다(\(what))"
            }
        }
    }

    struct Paragraph: Equatable {
        var text = ""
        var tables: [Table] = []
    }

    struct Table: Equatable {
        var cells: [Cell] = []
    }

    struct Cell: Equatable {
        var row = 0, column = 0, rowSpan = 1, columnSpan = 1
        var paragraphs: [Paragraph] = []
    }

    struct Content: Equatable {
        var paragraphs: [Paragraph] = []
        /// Shown above the text, e.g. that only the preview text of a distribution copy is available.
        var notice: String?
    }

    static func read(_ data: Data) throws -> Content {
        if data.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) { return try HWP5.read(data) }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return try HWPX.read(data) }
        if data.starts(with: Array("HWP Document File".utf8)) { throw Failure.oldFormat }
        throw Failure.notHWP
    }

    // MARK: HTML

    static func html(_ content: Content, title: String) -> String {
        var body = ""
        if let notice = content.notice { body += "<p class=\"notice\">\(escape(notice))</p>" }
        body += "<p class=\"notice\">Feather 간이 보기 · 글자와 표만 보여 줍니다. 원래 모양은 ‘다른 앱에서 열기’로 보세요.</p>"
        body += content.paragraphs.map(html).joined()
        return """
            <!doctype html><html lang="ko"><head><meta charset="utf-8"><title>\(escape(title))</title><style>
            :root { color-scheme: light dark; }
            body { font: 15px/1.6 -apple-system, "Apple SD Gothic Neo", sans-serif; max-width: 860px; margin: 24px auto; padding: 0 24px; }
            p { margin: 0 0 4px; min-height: 1.6em; white-space: pre-wrap; word-break: keep-all; overflow-wrap: anywhere; }
            .notice { color: GrayText; font-size: 12px; min-height: 0; margin-bottom: 12px; }
            table { border-collapse: collapse; margin: 8px 0 12px; max-width: 100%; }
            td { border: 1px solid #9998; padding: 4px 8px; vertical-align: top; }
            td p { margin: 0; }
            </style></head><body>\(body)</body></html>
            """
    }

    private static func html(_ paragraph: Paragraph) -> String {
        let text = paragraph.text.trimmingCharacters(in: .newlines)
        let tables = paragraph.tables.map(html).joined()
        if text.isEmpty, !tables.isEmpty { return tables }
        return "<p>\(escape(text))</p>" + tables
    }

    private static func html(_ table: Table) -> String {
        let rows = Dictionary(grouping: table.cells, by: \.row).sorted { $0.key < $1.key }
        let body = rows.map { _, cells in
            "<tr>" + cells.sorted { $0.column < $1.column }.map { cell in
                let span = (cell.columnSpan > 1 ? " colspan=\"\(cell.columnSpan)\"" : "") + (cell.rowSpan > 1 ? " rowspan=\"\(cell.rowSpan)\"" : "")
                return "<td\(span)>" + cell.paragraphs.map(html).joined() + "</td>"
            }.joined() + "</tr>"
        }.joined()
        return "<table>\(body)</table>"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Raw DEFLATE, as used inside HWP streams and zip entries.
    static func inflate(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return data }
        do {
            return try (data as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw Failure.damaged("압축")
        }
    }
}

// MARK: - HWP 5 (compound file)

private enum HWP5 {
    private static let paragraphHeader: UInt16 = 66, paragraphText: UInt16 = 67
    private static let controlHeader: UInt16 = 71, listHeader: UInt16 = 72
    private static let table = fourCC("tbl "), drawing = fourCC("gso ")

    private static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func read(_ data: Data) throws -> HWPDocument.Content {
        let file = try CompoundFile(data)
        guard let header = file.stream("FileHeader"), header.count >= 40,
              header.starts(with: Array("HWP Document File".utf8)) else { throw HWPDocument.Failure.notHWP }
        let properties = header.le32(36)
        if properties & 0b10 != 0 { throw HWPDocument.Failure.encrypted }
        let compressed = properties & 0b1 != 0
        let distribution = properties & 0b100 != 0

        var paragraphs: [HWPDocument.Paragraph] = []
        var index = 0
        while !distribution, let section = file.stream("BodyText/Section\(index)") {
            let records = Record.parse(compressed ? try HWPDocument.inflate(section) : section)
            var cursor = 0
            paragraphs += Self.paragraphs(records, &cursor, level: 0, limit: .max)
            index += 1
        }
        if index > 0 { return HWPDocument.Content(paragraphs: paragraphs) }
        // A distribution copy keeps its body encrypted; its preview text is the most we can show.
        if let preview = file.stream("PrvText") {
            let text = String(decoding: stride(from: 0, to: preview.count - 1, by: 2).map { preview.le16($0) }, as: UTF16.self)
            let lines = text.components(separatedBy: CharacterSet(charactersIn: "\r\n")).map { HWPDocument.Paragraph(text: $0) }
            let notice = distribution ? "배포용 문서라 본문이 잠겨 있어, 문서에 들어 있는 앞부분 미리보기 글만 보여 줍니다."
                : "본문을 찾지 못해 미리보기 글만 보여 줍니다."
            return HWPDocument.Content(paragraphs: lines, notice: notice)
        }
        throw HWPDocument.Failure.damaged("본문 없음")
    }

    /// Paragraphs whose headers sit at `level`, stopping at anything else at that level
    /// (the next cell of a table) or above it.
    private static func paragraphs(_ records: [Record], _ cursor: inout Int, level: Int, limit: Int) -> [HWPDocument.Paragraph] {
        var result: [HWPDocument.Paragraph] = []
        while cursor < records.count, result.count < limit, records[cursor].level == level,
              records[cursor].tag == paragraphHeader {
            cursor += 1
            var paragraph = HWPDocument.Paragraph()
            while cursor < records.count, records[cursor].level > level {
                let record = records[cursor]
                if record.level == level + 1, record.tag == paragraphText {
                    paragraph.text += text(record.data)
                    cursor += 1
                } else if record.level == level + 1, record.tag == controlHeader, record.data.count >= 4 {
                    let id = record.data.le32(0)
                    cursor += 1
                    if id == table {
                        paragraph.tables.append(Self.table(records, &cursor, level: level + 2))
                    } else if id == drawing {
                        // A text box: its paragraphs follow its list header.
                        for cell in cells(records, &cursor, level: level + 2) { paragraph.tables.append(HWPDocument.Table(cells: [cell])) }
                    }
                } else {
                    cursor += 1
                }
            }
            result.append(paragraph)
        }
        return result
    }

    private static func table(_ records: [Record], _ cursor: inout Int, level: Int) -> HWPDocument.Table {
        HWPDocument.Table(cells: cells(records, &cursor, level: level))
    }

    /// List headers at `level`, each followed by its paragraphs at the same level.
    private static func cells(_ records: [Record], _ cursor: inout Int, level: Int) -> [HWPDocument.Cell] {
        var cells: [HWPDocument.Cell] = []
        while cursor < records.count, records[cursor].level >= level {
            let record = records[cursor]
            guard record.level == level, record.tag == listHeader else {
                cursor += 1
                continue
            }
            cursor += 1
            let data = record.data
            var cell = HWPDocument.Cell()
            let count = data.count >= 2 ? Int(data.le16(0)) : .max
            // List header: paragraph count, flags (8 bytes); a table cell adds its address and span.
            if data.count >= 16 {
                cell.column = Int(data.le16(8))
                cell.row = Int(data.le16(10))
                cell.columnSpan = max(1, Int(data.le16(12)))
                cell.rowSpan = max(1, Int(data.le16(14)))
            }
            cell.paragraphs = paragraphs(records, &cursor, level: level, limit: count == 0 ? .max : count)
            cells.append(cell)
        }
        return cells
    }

    /// Paragraph text: UTF-16 with control characters; most controls take 8 code units.
    private static func text(_ data: Data) -> String {
        var units: [UInt16] = []
        var index = 0
        let count = data.count / 2
        while index < count {
            let unit = data.le16(index * 2)
            switch unit {
            case 9:
                units.append(9)
                index += 8
            case 10, 13:
                units.append(10)
                index += 1
            case 24, 30, 31:
                units.append(32)
                index += 1
            case 0..<32:
                // 0 and 25–29 are single characters; the rest carry 7 more units of data.
                index += [0, 25, 26, 27, 28, 29].contains(unit) ? 1 : 8
            default:
                units.append(unit)
                index += 1
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    private struct Record {
        var tag: UInt16
        var level: Int
        var data: Data

        static func parse(_ data: Data) -> [Record] {
            var records: [Record] = []
            var offset = 0
            while offset + 4 <= data.count {
                let header = data.le32(offset)
                offset += 4
                var size = Int(header >> 20)
                if size == 0xFFF {
                    guard offset + 4 <= data.count else { break }
                    size = Int(data.le32(offset))
                    offset += 4
                }
                guard size >= 0, offset + size <= data.count else { break }
                records.append(Record(tag: UInt16(header & 0x3FF), level: Int((header >> 10) & 0x3FF),
                                      data: data.subdata(in: data.startIndex + offset..<data.startIndex + offset + size)))
                offset += size
            }
            return records
        }
    }
}

/// Microsoft's Compound File Binary format, read-only: enough to get named streams out.
struct CompoundFile {
    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniCutoff: Int
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private let miniStream: Data
    private var entries: [String: (start: UInt32, size: Int)] = [:]

    private static let endOfChain: UInt32 = 0xFFFF_FFFE, noStream: UInt32 = 0xFFFF_FFFF

    init(_ data: Data) throws {
        let data = Data(data)  // zero-based indices
        guard data.count >= 512 else { throw HWPDocument.Failure.damaged("머리글") }
        self.data = data
        sectorSize = 1 << Int(data.le16(0x1E))
        miniSectorSize = 1 << Int(data.le16(0x20))
        miniCutoff = Int(data.le32(0x38))
        guard (512...4096).contains(sectorSize), miniSectorSize <= sectorSize else { throw HWPDocument.Failure.damaged("머리글") }

        // The FAT's own sectors: 109 listed in the header, the rest in a DIFAT chain.
        var fatSectors = (0..<109).map { data.le32(0x4C + $0 * 4) }.filter { $0 < 0xFFFF_FFFA }
        var difat = data.le32(0x44)
        var guardCount = 0
        while difat < 0xFFFF_FFFA, guardCount < 10_000 {
            let base = 512 + Int(difat) * sectorSize
            guard base + sectorSize <= data.count else { break }
            let perSector = sectorSize / 4 - 1
            fatSectors += (0..<perSector).map { data.le32(base + $0 * 4) }.filter { $0 < 0xFFFF_FFFA }
            difat = data.le32(base + perSector * 4)
            guardCount += 1
        }
        let sectorSize = sectorSize
        fat = fatSectors.flatMap { sector -> [UInt32] in
            let base = 512 + Int(sector) * sectorSize
            guard base + sectorSize <= data.count else { return [] }
            return (0..<sectorSize / 4).map { data.le32(base + $0 * 4) }
        }

        let directory = try Self.chain(data.le32(0x30), fat: fat, in: data, sectorSize: sectorSize)
        let miniFATData = data.le32(0x3C) < 0xFFFF_FFFA
            ? try Self.chain(data.le32(0x3C), fat: fat, in: data, sectorSize: sectorSize) : Data()
        miniFAT = (0..<miniFATData.count / 4).map { miniFATData.le32($0 * 4) }

        // Directory: 128-byte entries linked as red-black trees of siblings.
        let count = directory.count / 128
        func entry(_ index: Int) -> (name: String, type: UInt8, left: UInt32, right: UInt32, child: UInt32, start: UInt32, size: Int) {
            let base = index * 128
            let nameLength = max(0, min(64, Int(directory.le16(base + 64))) - 2)
            let name = String(decoding: (0..<nameLength / 2).map { directory.le16(base + $0 * 2) }, as: UTF16.self)
            return (name, directory[base + 66], directory.le32(base + 68), directory.le32(base + 72), directory.le32(base + 76),
                    directory.le32(base + 116), Int(directory.le32(base + 120)))
        }
        guard count > 0 else { throw HWPDocument.Failure.damaged("목록") }
        let root = entry(0)
        miniStream = root.start < 0xFFFF_FFFA
            ? try Self.chain(root.start, fat: fat, in: data, sectorSize: sectorSize).prefix(root.size) : Data()

        var found: [String: (UInt32, Int)] = [:]
        var visited = Set<UInt32>()
        func walk(_ index: UInt32, prefix: String) {
            guard index != Self.noStream, Int(index) < count, visited.insert(index).inserted else { return }
            let item = entry(Int(index))
            walk(item.left, prefix: prefix)
            let path = prefix.isEmpty ? item.name : prefix + "/" + item.name
            if item.type == 2 { found[path] = (item.start, item.size) }
            if item.type == 1 { walk(item.child, prefix: path) }
            walk(item.right, prefix: prefix)
        }
        walk(root.child, prefix: "")
        entries = found.mapValues { (start: $0.0, size: $0.1) }
    }

    func stream(_ path: String) -> Data? {
        guard let entry = entries[path] else { return nil }
        if entry.size < miniCutoff {
            var result = Data()
            var sector = entry.start
            var steps = 0
            while sector < 0xFFFF_FFFA, result.count < entry.size, steps <= miniFAT.count {
                let base = Int(sector) * miniSectorSize
                guard base + miniSectorSize <= miniStream.count else { return nil }
                result += miniStream[miniStream.startIndex + base..<miniStream.startIndex + base + miniSectorSize]
                guard Int(sector) < miniFAT.count else { break }
                sector = miniFAT[Int(sector)]
                steps += 1
            }
            return result.count >= entry.size ? result.prefix(entry.size) : nil
        }
        guard let all = try? Self.chain(entry.start, fat: fat, in: data, sectorSize: sectorSize), all.count >= entry.size else { return nil }
        return all.prefix(entry.size)
    }

    private static func chain(_ start: UInt32, fat: [UInt32], in data: Data, sectorSize: Int) throws -> Data {
        var result = Data()
        var sector = start
        var steps = 0
        while sector < 0xFFFF_FFFA {
            let base = 512 + Int(sector) * sectorSize
            guard base + sectorSize <= data.count, steps <= fat.count else { throw HWPDocument.Failure.damaged("연결") }
            result += data[base..<base + sectorSize]
            guard Int(sector) < fat.count else { break }
            sector = fat[Int(sector)]
            steps += 1
        }
        return result
    }
}

// MARK: - HWPX (zip of XML)

private enum HWPX {
    static func read(_ data: Data) throws -> HWPDocument.Content {
        let zip = try ZipArchive(data)
        let sections = zip.names
            .compactMap { name -> (Int, String)? in
                guard name.hasPrefix("Contents/section"), name.hasSuffix(".xml") else { return nil }
                return Int(name.dropFirst("Contents/section".count).dropLast(4)).map { ($0, name) }
            }
            .sorted { $0.0 < $1.0 }
        guard !sections.isEmpty else { throw HWPDocument.Failure.notHWP }
        var paragraphs: [HWPDocument.Paragraph] = []
        for (_, name) in sections {
            guard let xml = try zip.file(name) else { continue }
            let reader = SectionReader()
            let parser = XMLParser(data: xml)
            parser.delegate = reader
            guard parser.parse() else { throw HWPDocument.Failure.damaged("XML") }
            paragraphs += reader.paragraphs
        }
        return HWPDocument.Content(paragraphs: paragraphs)
    }

    /// Builds paragraphs and tables from `hp:p`, `hp:t`, `hp:tbl`, `hp:tc` and friends.
    private final class SectionReader: NSObject, XMLParserDelegate {
        private(set) var paragraphs: [HWPDocument.Paragraph] = []
        /// Open paragraphs (innermost last) and the tables/cells they're nested in.
        private var paragraphStack: [HWPDocument.Paragraph] = []
        private var tableStack: [HWPDocument.Table] = []
        private var cellStack: [HWPDocument.Cell] = []
        private var rowIndex: [Int] = []
        private var columnIndex: [Int] = []
        private var inText = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            switch local(name) {
            case "p": paragraphStack.append(HWPDocument.Paragraph())
            case "t": inText = true
            case "tab": append("\t")
            case "lineBreak": append("\n")
            case "tbl":
                tableStack.append(HWPDocument.Table())
                rowIndex.append(-1)
                columnIndex.append(0)
            case "tr":
                if !rowIndex.isEmpty {
                    rowIndex[rowIndex.count - 1] += 1
                    columnIndex[columnIndex.count - 1] = 0
                }
            case "tc":
                var cell = HWPDocument.Cell()
                cell.row = max(0, rowIndex.last ?? 0)
                cell.column = columnIndex.last ?? 0
                if !columnIndex.isEmpty { columnIndex[columnIndex.count - 1] += 1 }
                cellStack.append(cell)
                cellDepth.append(paragraphStack.count)
            case "cellAddr":
                guard !cellStack.isEmpty else { break }
                if let column = attributes["colAddr"].flatMap(Int.init) { cellStack[cellStack.count - 1].column = column }
                if let row = attributes["rowAddr"].flatMap(Int.init) { cellStack[cellStack.count - 1].row = row }
            case "cellSpan":
                guard !cellStack.isEmpty else { break }
                cellStack[cellStack.count - 1].columnSpan = max(1, attributes["colSpan"].flatMap(Int.init) ?? 1)
                cellStack[cellStack.count - 1].rowSpan = max(1, attributes["rowSpan"].flatMap(Int.init) ?? 1)
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { append(string) }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch local(name) {
            case "t": inText = false
            case "p":
                guard let paragraph = paragraphStack.popLast() else { break }
                // A paragraph inside a cell belongs to the cell, unless it opened after the cell did.
                if !cellStack.isEmpty, paragraphStack.count == cellDepth.last {
                    cellStack[cellStack.count - 1].paragraphs.append(paragraph)
                } else if paragraphStack.isEmpty {
                    paragraphs.append(paragraph)
                } else {
                    paragraphStack[paragraphStack.count - 1].text += paragraph.text
                    paragraphStack[paragraphStack.count - 1].tables += paragraph.tables
                }
            case "tc":
                guard let cell = cellStack.popLast(), !tableStack.isEmpty else { break }
                cellDepth.removeLast()
                tableStack[tableStack.count - 1].cells.append(cell)
            case "tbl":
                guard let table = tableStack.popLast() else { break }
                rowIndex.removeLast()
                columnIndex.removeLast()
                if paragraphStack.isEmpty {
                    paragraphs.append(HWPDocument.Paragraph(tables: [table]))
                } else {
                    paragraphStack[paragraphStack.count - 1].tables.append(table)
                }
            default: break
            }
        }

        /// How many paragraphs were open when each cell started.
        private var cellDepth: [Int] = []

        private func append(_ text: String) {
            guard !paragraphStack.isEmpty else { return }
            paragraphStack[paragraphStack.count - 1].text += text
        }

        private func local(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }
    }
}

/// Reads entries of a zip file (stored or deflated); no writing, no encryption.
struct ZipArchive {
    private let data: Data
    private var entries: [String: (method: UInt16, compressed: Int, size: Int, offset: Int)] = [:]
    var names: [String] { Array(entries.keys) }

    init(_ data: Data) throws {
        let data = Data(data)
        self.data = data
        // End of central directory: within the last 64 KB + 22 bytes.
        let lowest = max(0, data.count - 65_557)
        guard data.count >= 22,
              let end = stride(from: data.count - 22, through: lowest, by: -1).first(where: { data.le32($0) == 0x0605_4B50 })
        else { throw HWPDocument.Failure.damaged("zip") }
        var offset = Int(data.le32(end + 16))
        for _ in 0..<Int(data.le16(end + 10)) {
            guard offset + 46 <= data.count, data.le32(offset) == 0x0201_4B50 else { throw HWPDocument.Failure.damaged("zip 목록") }
            let nameLength = Int(data.le16(offset + 28))
            let extra = Int(data.le16(offset + 30)), comment = Int(data.le16(offset + 32))
            guard offset + 46 + nameLength <= data.count else { throw HWPDocument.Failure.damaged("zip 목록") }
            let name = String(decoding: data[offset + 46..<offset + 46 + nameLength], as: UTF8.self)
            entries[name] = (data.le16(offset + 10), Int(data.le32(offset + 20)), Int(data.le32(offset + 24)), Int(data.le32(offset + 42)))
            offset += 46 + nameLength + extra + comment
        }
    }

    func file(_ name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        let local = entry.offset
        guard local + 30 <= data.count, data.le32(local) == 0x0403_4B50 else { throw HWPDocument.Failure.damaged("zip 항목") }
        let start = local + 30 + Int(data.le16(local + 26)) + Int(data.le16(local + 28))
        guard start + entry.compressed <= data.count else { throw HWPDocument.Failure.damaged("zip 항목") }
        let raw = data.subdata(in: start..<start + entry.compressed)
        switch entry.method {
        case 0: return raw
        case 8: return try HWPDocument.inflate(raw)
        default: throw HWPDocument.Failure.damaged("zip 압축 방식")
        }
    }
}

extension Data {
    func le16(_ offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    func le32(_ offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8 | UInt32(self[base + 2]) << 16 | UInt32(self[base + 3]) << 24
    }
}

/// The viewer's body for HWP files: the converted HTML in a web view that runs no scripts,
/// loads nothing from the network and keeps no data.
@MainActor
enum HWPView {
    static func make(for file: URL) -> NSView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let html: String
        do {
            let content = try HWPDocument.read(Data(contentsOf: file, options: .mappedIfSafe))
            html = HWPDocument.html(content, title: file.lastPathComponent)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            html = HWPDocument.html(HWPDocument.Content(paragraphs: [], notice: message), title: file.lastPathComponent)
        }
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }
}
