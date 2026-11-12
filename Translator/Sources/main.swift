import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

// FeatherTranslator --model <folder>
//
// Runs the Hy-MT2 model and nothing else. Feather writes one JSON request per line to stdin,
// {"id": 1, "prompt": "<full prompt with chat tokens>", "maxTokens": 256}, and reads one JSON
// line per request from stdout: {"id": 1, "text": "..."} or {"id": 1, "error": "..."}.
// The first line is {"ready": true} once the model is loaded, or {"fatal": "..."}.
// Prompts are built by Feather (Sources/Feather/Translation.swift); this process only generates.

struct Request: Decodable {
    let id: Int
    let prompt: String
    let maxTokens: Int
}

func send(_ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

/// swift-transformers' tokenizer behind mlx-swift-lm's protocol (as in AITranslate).
struct TokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}

func generate(_ container: ModelContainer, prompt: String, maxTokens: Int) async throws -> String {
    // The prompt already carries the chat tokens; don't let the tokenizer add more.
    let tokens = await container.perform { context in context.tokenizer.encode(text: prompt, addSpecialTokens: false) }
    // Sampling the model card recommends.
    let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0.7, topP: 0.6, topK: 20, repetitionPenalty: 1.05)
    var output = ""
    for await event in try await container.generate(input: LMInput(tokens: MLXArray(tokens)), parameters: parameters) {
        if let chunk = event.chunk { output += chunk }
    }
    return output
}

let arguments = CommandLine.arguments
guard let flag = arguments.firstIndex(of: "--model"), arguments.indices.contains(flag + 1) else {
    send(["fatal": "usage: FeatherTranslator --model <folder>"])
    exit(2)
}
let folder = URL(fileURLWithPath: arguments[flag + 1])
let container: ModelContainer
do {
    container = try await loadModelContainer(from: folder, using: TokenizerLoader())
    // The first generation compiles GPU kernels; do it now rather than on the first paragraph.
    _ = try await generate(container, prompt: "<｜hy_begin▁of▁sentence｜><｜hy_User｜>Hello<｜hy_Assistant｜>", maxTokens: 4)
} catch {
    send(["fatal": "\(error)"])
    exit(1)
}
send(["ready": true])

let decoder = JSONDecoder()
while let line = readLine() {
    guard let request = try? decoder.decode(Request.self, from: Data(line.utf8)) else { continue }
    do {
        send(["id": request.id, "text": try await generate(container, prompt: request.prompt, maxTokens: request.maxTokens)])
    } catch {
        send(["id": request.id, "error": "\(error)"])
    }
}
