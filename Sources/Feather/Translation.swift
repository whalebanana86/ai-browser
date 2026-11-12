import AppKit
import NaturalLanguage
import WebKit

/// Hy-MT2's translation prompt and chat format, from the model card. The rules below follow
/// AITranslate (MIT, same author), where they were measured.
enum HyMTPrompt {
    static let begin = "<｜hy_begin▁of▁sentence｜>"
    static let user = "<｜hy_User｜>"
    static let assistant = "<｜hy_Assistant｜>"

    /// `target` is the language's English name ("Korean").
    static func prompt(for text: String, target: String) -> String {
        begin + user + "Translate the following text into \(target). Note that you "
            + "should only output the translated result without any additional explanation:\n\n" + neutralized(text)
            + assistant
    }

    /// Page text that spells one of the model's special tokens (`<｜hy_…｜>`) would be read as a
    /// real token and could change the conversation. A plain bar makes it ordinary text.
    static func neutralized(_ text: String) -> String {
        guard text.contains("<｜") else { return text }
        return text.replacingOccurrences(of: #"<｜([^｜>]*)｜>"#, with: "<|$1|>", options: .regularExpression)
    }

    /// Translations are never far longer than the source; the cap stops runaway generation.
    static func maxTokens(for text: String) -> Int {
        min(2048, max(64, text.count * 3))
    }

    /// Generous enough never to cut a normal paragraph (measured ~104 tokens/s on an M5):
    /// 10 s plus the whole token cap at 10 tokens/s. Only a stuck generation hits it.
    static func timeLimit(for text: String) -> TimeInterval {
        10 + 0.1 * Double(maxTokens(for: text))
    }

    /// The model likes Markdown-style "two spaces before a line break".
    static func clean(_ output: String) -> String {
        output.replacingOccurrences(of: "  \n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Catches a known Hy-MT2 slip: letters from a writing system that's in neither the source nor
/// the target (measured: "파이어폭스" came out as "파이어ف렌", with an Arabic letter).
enum ScriptCheck {
    enum Script: CaseIterable {
        case latin, hangul, han, kana, cyrillic, greek, arabic, hebrew, thai, devanagari
    }

    static func script(of scalar: Unicode.Scalar) -> Script? {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: return .latin
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return .hangul
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: return .han
        case 0x3040...0x30FF: return .kana
        case 0x0400...0x04FF: return .cyrillic
        case 0x0370...0x03FF: return .greek
        case 0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
        case 0x0590...0x05FF: return .hebrew
        case 0x0E00...0x0E7F: return .thai
        case 0x0900...0x097F: return .devanagari
        default: return nil
        }
    }

    static func scripts(in text: String) -> Set<Script> {
        Set(text.unicodeScalars.compactMap(script(of:)))
    }

    /// The scripts a language is written in.
    static func scripts(of language: String) -> Set<Script> {
        switch language {
        case "Korean": return [.hangul, .han]
        case "Japanese": return [.kana, .han]
        case "Chinese": return [.han]
        case "Russian", "Ukrainian": return [.cyrillic]
        case "Greek": return [.greek]
        case "Arabic", "Persian": return [.arabic]
        case "Hebrew": return [.hebrew]
        case "Thai": return [.thai]
        case "Hindi": return [.devanagari]
        default: return [.latin]
        }
    }

    /// True when `output` uses a script found in neither `source` nor the target language.
    /// Latin is always allowed: names, units and code survive translation in any language.
    static func introducesForeignScript(source: String, output: String, target: String) -> Bool {
        let allowed = scripts(in: source).union(scripts(of: target)).union([.latin])
        return !scripts(in: output).isSubset(of: allowed)
    }
}

/// Which language to translate into and whether a page needs it.
enum TranslationLanguage {
    /// English names the model's prompt expects, by language code.
    static let names: [String: String] = [
        "ko": "Korean", "en": "English", "ja": "Japanese", "zh": "Chinese", "fr": "French", "de": "German",
        "es": "Spanish", "it": "Italian", "pt": "Portuguese", "ru": "Russian", "vi": "Vietnamese", "th": "Thai",
        "id": "Indonesian", "ar": "Arabic", "tr": "Turkish", "nl": "Dutch", "pl": "Polish", "uk": "Ukrainian",
    ]

    /// The user's first preferred language, as a code and a prompt name.
    static func target(preferred: [String] = Locale.preferredLanguages) -> (code: String, name: String) {
        for identifier in preferred {
            let code = String(identifier.prefix { $0 != "-" && $0 != "_" })
            if let name = names[code] { return (code, name) }
        }
        return ("en", "English")
    }

    /// Scripts only the target language uses, to tell its text from foreign text at a glance:
    /// on a Korean target, a block is Korean when Hangul is at least half its letters.
    static func ownScripts(of name: String) -> Set<ScriptCheck.Script> {
        switch name {
        case "Korean": return [.hangul]
        case "Japanese": return [.kana]
        case "Chinese": return [.han]
        case "Russian", "Ukrainian": return [.cyrillic]
        case "Greek": return [.greek]
        case "Arabic": return [.arabic]
        case "Hebrew": return [.hebrew]
        case "Thai": return [.thai]
        case "Hindi": return [.devanagari]
        default: return []
        }
    }

    /// Whether a block needs no translation: already in the target language, or a single Latin
    /// token (a name, @handle, hashtag, word of UI) that translating would only garble. Decided
    /// per block, so a Korean page's foreign posts are still translated.
    static func needsNoTranslation(_ text: String, target: (code: String, name: String)) -> Bool {
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return true }
        let scripts = letters.compactMap(ScriptCheck.script(of:))
        let latinOnly = scripts.allSatisfy { $0 == .latin }
        if latinOnly, !text.contains(where: \.isWhitespace) { return true }
        let own = ownScripts(of: target.name)
        if !own.isEmpty {
            return scripts.filter(own.contains).count * 2 >= letters.count
        }
        return latinOnly && (detect(text) ?? target.code) == target.code
    }

    /// The page's main language, or nil when the text is too short or mixed to tell.
    static func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage,
              let confidence = recognizer.languageHypotheses(withMaximum: 1)[language], confidence > 0.5 else { return nil }
        return String(language.rawValue.prefix { $0 != "-" })
    }
}

/// The model helper (`FeatherTranslator`), a separate process so the model's ~1.2-1.75 GB
/// never counts against the tabs' memory budget and goes away entirely when not in use.
/// Started on the first request, ended after `idleTimeout` without one.
@MainActor
final class TranslatorProcess {
    static let shared = TranslatorProcess(executable: TranslatorProcess.bundledHelper) { Settings.translationModel }

    enum Failure: LocalizedError, Equatable {
        case missingHelper, missingModel, timedOut, crashed
        case failedToStart(String)
        case generation(String)

        var errorDescription: String? {
            switch self {
            case .missingHelper: return "번역 도우미가 앱에 없습니다"
            case .missingModel: return "번역 모델(Hy-MT2-1.8B 4bit)을 찾지 못했습니다"
            case .failedToStart(let reason): return "번역 모델을 불러오지 못했습니다: \(reason)"
            case .timedOut: return "번역이 시간 안에 끝나지 않았습니다"
            case .crashed: return "번역 도우미가 멈췄습니다"
            case .generation(let reason): return "번역하지 못했습니다: \(reason)"
            }
        }
    }

    static var bundledHelper: URL? {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/FeatherTranslator")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    let executable: URL?
    /// Looked up each time the helper starts, so a model downloaded while Feather runs is found.
    private let locateModel: () -> URL?
    var idleTimeout: TimeInterval = 120
    /// The helper's pid while it runs, so memory accounting can leave it out of the tabs' total.
    private(set) var pid: pid_t?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var ready: [CheckedContinuation<Void, Error>] = []
    private var isReady = false
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var nextID = 1
    private var idleGeneration = 0

    init(executable: URL?, locateModel: @escaping () -> URL?) {
        self.executable = executable
        self.locateModel = locateModel
    }

    convenience init(executable: URL?, model: URL?) {
        self.init(executable: executable) { model }
    }

    var hasModel: Bool { locateModel() != nil }

    /// Model memory, separate from the tabs': the helper's physical footprint, 0 when not running.
    var footprint: UInt64 { pid.map(MemoryMeter.footprint(of:)) ?? 0 }

    func translate(prompt: String, maxTokens: Int, timeLimit: TimeInterval) async throws -> String {
        try await start()
        let id = nextID
        nextID += 1
        let request: [String: Any] = ["id": id, "prompt": prompt, "maxTokens": maxTokens]
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(0x0A)
        defer { scheduleIdleStop() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            input?.write(line)
            onMain(after: timeLimit) { [weak self] in
                guard let self, let waiting = self.pending.removeValue(forKey: id) else { return }
                waiting.resume(throwing: Failure.timedOut)
                // A stuck generation blocks every later request: start over.
                self.stop()
            }
        }
    }

    private func start() async throws {
        if isReady { return }
        if process == nil { try launch() }
        try await withCheckedThrowingContinuation { ready.append($0) }
    }

    private func launch() throws {
        guard let executable else { throw Failure.missingHelper }
        guard let model = locateModel() else { throw Failure.missingModel }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--model", model.path]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data, from: process) } }
        }
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(ended) } }
        }
        do {
            try process.run()
        } catch {
            throw Failure.failedToStart(error.localizedDescription)
        }
        self.process = process
        input = stdin.fileHandleForWriting
        pid = process.processIdentifier
    }

    private func received(_ data: Data, from sender: Process) {
        guard sender === process else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        if message["ready"] as? Bool == true {
            isReady = true
            ready.forEach { $0.resume() }
            ready = []
        } else if let fatal = message["fatal"] as? String {
            failAll(Failure.failedToStart(fatal))
            stop()
        } else if let id = message["id"] as? Int, let waiting = pending.removeValue(forKey: id) {
            if let text = message["text"] as? String {
                waiting.resume(returning: text)
            } else {
                waiting.resume(throwing: Failure.generation(message["error"] as? String ?? "?"))
            }
        }
    }

    private func ended(_ sender: Process) {
        guard sender === process else { return }
        failAll(Failure.crashed)
        reset()
    }

    private func failAll(_ error: Error) {
        ready.forEach { $0.resume(throwing: error) }
        ready = []
        let waiting = pending.values
        pending = [:]
        waiting.forEach { $0.resume(throwing: error) }
    }

    private func reset() {
        process?.standardOutput.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
        process = nil
        input = nil
        pid = nil
        isReady = false
        buffer = Data()
    }

    /// Ends the helper and frees the model's memory. Requests in flight fail.
    func stop() {
        guard let process else { return }
        failAll(Failure.crashed)
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        reset()
    }

    var isRunning: Bool { process != nil }

    private func scheduleIdleStop() {
        idleGeneration += 1
        let generation = idleGeneration
        onMain(after: idleTimeout) { [weak self] in
            guard let self, self.idleGeneration == generation, self.pending.isEmpty else { return }
            self.stop()
        }
    }
}

/// Collects a page's text blocks and swaps their text for translations, in its own content
/// world so page scripts can neither see nor tamper with it. Only text changes: every element
/// (images, links, styled spans) stays where it was, so nothing disappears or changes colour.
enum PageText {
    static let world = WKContentWorld.world(name: "FeatherTranslate")

    struct Block: Equatable {
        var id: Int
        var text: String
    }

    /// Up to `limit` blocks the user can see now (plus half a screen below), top of the screen
    /// first. Blocks are found by layout, not tag, so `div`-and-`span` sites (X, most web apps)
    /// work: a text's block is its nearest non-inline box, and a block's text is only what's
    /// directly in it, not in blocks inside it. Only what's on screen is taken; the rest waits
    /// until scrolling brings it near. Text in buttons, inputs, code and editable areas is left
    /// alone, as is anything not actually visible.
    static let nextScript = #"""
        const skip = 'pre, code, kbd, samp, script, style, noscript, textarea, input, select, button, [role="button"], svg, math, [contenteditable=""], [contenteditable="true"], [hidden], dialog:not([open])';
        window.__featherTranslate ??= { next: 1, originals: new Map(), texts: new Map(), done: new WeakSet() };
        const state = window.__featherTranslate;
        const isInline = el => { const display = getComputedStyle(el).display; return display === 'inline' || display === 'contents'; };
        const blockOf = node => {
            let el = node.parentElement;
            while (el && el !== document.body && isInline(el)) el = el.parentElement;
            return el;
        };
        // Whether it's on screen, not aria-hidden: CNN marks its visible paragraphs aria-hidden.
        const visible = el => el.getClientRects().length > 0
            && (!el.checkVisibility || el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true }));
        const blocks = new Map();
        const far = new Set();
        const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
            const node = walker.currentNode;
            if (!node.data.trim()) continue;
            const parent = node.parentElement;
            if (!parent || parent.closest(skip)) continue;
            const block = blockOf(node);
            if (!block || state.done.has(block) || far.has(block)) continue;
            if (!blocks.has(block)) {
                const rect = block.getBoundingClientRect();
                if (rect.width <= 0 || rect.height <= 0 || rect.bottom < 0 || rect.top > innerHeight * 1.5) { far.add(block); continue; }
                blocks.set(block, { top: rect.top, nodes: [] });
            }
            if (visible(parent)) blocks.get(block).nodes.push(node);
        }
        const near = [];
        for (const [block, info] of blocks) {
            const text = info.nodes.map(node => node.data).join('').replace(/\s+/g, ' ').trim();
            if (text.length < 2 || !/\p{L}/u.test(text)) continue;
            near.push({ block, text, nodes: info.nodes, top: info.top });
        }
        near.sort((a, b) => Math.max(a.top, 0) - Math.max(b.top, 0));
        return near.slice(0, limit).map(({ block, text, nodes }) => {
            const id = state.next++;
            state.done.add(block);
            block.dataset.featherTid = String(id);
            state.texts.set(id, nodes);
            return { id, text };
        });
        """#

    /// Puts the translation in place of the block's own text without touching a single element:
    /// images, links and styled spans stay, and the text keeps the colour and style of the run
    /// it lands in (the longest visible text directly in the block, else the longest visible
    /// text of the block). The block's other text is emptied; hidden text is not touched.
    static let applyScript = #"""
        const state = window.__featherTranslate;
        const nodes = state?.texts.get(id)?.filter(node => node.isConnected && node.data.trim());
        if (!nodes || !nodes.length) return false;
        if (!state.originals.has(id)) state.originals.set(id, nodes.map(node => [node, node.data]));
        const block = nodes[0].parentElement.closest(`[data-feather-tid="${id}"]`);
        // Longest by the words in it: markup indentation must not make a node look long.
        const length = node => node.data.trim().length;
        const direct = nodes.filter(node => node.parentNode === block);
        const target = (direct.length ? direct : nodes).reduce((a, b) => (length(b) > length(a) ? b : a));
        for (const node of nodes) node.data = node === target ? text : '';
        return true;
        """#

    static let restoreScript = #"""
        const state = window.__featherTranslate;
        if (!state) return 0;
        let restored = 0;
        for (const [, texts] of state.originals) {
            for (const [node, data] of texts) node.data = data;
            restored++;
        }
        for (const el of document.querySelectorAll('[data-feather-tid]')) delete el.dataset.featherTid;
        window.__featherTranslate = undefined;
        return restored;
        """#

    /// The next blocks to translate where the user is looking; empty when everything near the
    /// current scroll position is done.
    static func next(_ limit: Int, in webView: WKWebView) async throws -> [Block] {
        let result = try await webView.callAsyncJavaScript(nextScript, arguments: ["limit": limit], in: nil, contentWorld: world)
        return (result as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? Int, let text = item["text"] as? String else { return nil }
            return Block(id: id, text: text)
        }
    }

    @discardableResult
    static func apply(_ text: String, to id: Int, in webView: WKWebView) async throws -> Bool {
        let result = try await webView.callAsyncJavaScript(applyScript, arguments: ["id": id, "text": text], in: nil, contentWorld: world)
        return result as? Bool ?? false
    }

    @discardableResult
    static func restore(in webView: WKWebView) async throws -> Int {
        try await webView.callAsyncJavaScript(restoreScript, arguments: [:], in: nil, contentWorld: world) as? Int ?? 0
    }
}

/// Translates what the user is looking at, following the scroll position: the visible blocks
/// first, then whatever scrolling or the page brings into view. Once turned on for a tab it
/// stays on until turned off, across the pages the tab goes to next.
@MainActor
final class PageTranslator {
    typealias Translate = (_ prompt: String, _ maxTokens: Int, _ timeLimit: TimeInterval) async throws -> String

    enum Outcome: Equatable {
        case alreadyInTargetLanguage, nothingToTranslate, stopped
        case translated(blocks: Int)
        case failed(String)
    }

    private let translate: Translate
    private let target: (code: String, name: String)
    /// Tabs with translation on, and the loop that keeps translating new text in each.
    private var watching: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// How often a translated tab is checked for newly visible text.
    var pollInterval: TimeInterval = 0.5
    /// Blocks translated so far on the current page.
    var onProgress: ((WKWebView, Int) -> Void)?
    /// Translation turned itself off (the model failed while following page changes).
    var onStopped: ((WKWebView, String) -> Void)?

    init(target: (code: String, name: String) = TranslationLanguage.target(), translate: @escaping Translate) {
        self.target = target
        self.translate = translate
    }

    /// Whether translation is on for this web view.
    func isTranslated(_ webView: WKWebView) -> Bool {
        watching[ObjectIdentifier(webView)] != nil
    }

    /// Turns translation on (translating what's there now, then whatever comes later), or off,
    /// putting the original text back.
    @discardableResult
    func toggle(_ webView: WKWebView) async -> Outcome {
        let key = ObjectIdentifier(webView)
        if let loop = watching.removeValue(forKey: key) {
            loop.cancel()
            _ = try? await PageText.restore(in: webView)
            return .stopped
        }
        watching[key] = Task {}
        let outcome: Outcome
        do {
            outcome = try await translateNewText(in: webView, isFirstPass: true)
        } catch {
            watching[key] = nil
            _ = try? await PageText.restore(in: webView)
            return .failed(error.localizedDescription)
        }
        guard watching[key] != nil else { return .stopped }
        watching[key] = Task { [weak self, weak webView] in await self?.follow(webView, key: key) }
        return outcome
    }

    /// Keeps translating text that appears after the first pass, on this page and the next ones.
    private func follow(_ webView: WKWebView?, key: ObjectIdentifier) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let webView else {
                watching[key] = nil
                return
            }
            do {
                _ = try await translateNewText(in: webView, isFirstPass: false)
            } catch {
                guard !Task.isCancelled else { return }
                watching[key] = nil
                _ = try? await PageText.restore(in: webView)
                onStopped?(webView, error.localizedDescription)
                return
            }
        }
    }

    /// Translates the visible blocks not seen before, a few at a time so a scroll in between
    /// redirects the next ones. Blocks already in the target language are left as they are.
    private func translateNewText(in webView: WKWebView, isFirstPass: Bool) async throws -> Outcome {
        let key = ObjectIdentifier(webView)
        let page = webView.url
        var done = 0
        var skipped = 0
        while watching[key] != nil, webView.url == page {
            let blocks = try await PageText.next(3, in: webView)
            if blocks.isEmpty { break }
            for block in blocks {
                if TranslationLanguage.needsNoTranslation(block.text, target: target) {
                    skipped += 1
                    continue
                }
                guard watching[key] != nil, webView.url == page else { return .translated(blocks: done) }
                let text = try await translateChecked(block.text)
                guard watching[key] != nil, webView.url == page else { return .translated(blocks: done) }
                if !text.isEmpty { try await PageText.apply(text, to: block.id, in: webView) }
                done += 1
                onProgress?(webView, done)
            }
        }
        if done > 0 { return .translated(blocks: done) }
        return skipped > 0 ? .alreadyInTargetLanguage : .nothingToTranslate
    }

    /// One retry when the model slips letters from an unrelated writing system into the result.
    func translateChecked(_ source: String) async throws -> String {
        let prompt = HyMTPrompt.prompt(for: source, target: target.name)
        let limit = HyMTPrompt.timeLimit(for: source)
        let tokens = HyMTPrompt.maxTokens(for: source)
        var output = HyMTPrompt.clean(try await translate(prompt, tokens, limit))
        if ScriptCheck.introducesForeignScript(source: source, output: output, target: target.name) {
            output = HyMTPrompt.clean(try await translate(prompt, tokens, limit))
        }
        return output
    }
}
