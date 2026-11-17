import Foundation
import Testing
@testable import PromptDockCore

// MARK: - 提示词组装

@Suite struct PromptRendererTests {

    private func action(_ content: String, system: String? = nil, output: OutputMode? = nil) -> Prompt {
        Prompt(id: "a", title: "A", type: .action, content: content, system: system, output: output)
    }

    @Test func substitutesSelectionPlaceholder() {
        let r = PromptRenderer.render(action("润色：\n{selection}\n谢谢"), selection: "原文")
        #expect(r.userMessage == "润色：\n原文\n谢谢")
    }

    @Test func substitutesEveryOccurrence() {
        #expect(PromptRenderer.render(action("{selection} / {selection}"), selection: "x").userMessage == "x / x")
    }

    @Test func appendsSelectionWhenPlaceholderMissing() {
        #expect(PromptRenderer.render(action("翻译成英文："), selection: "你好").userMessage == "翻译成英文：\n\n你好")
    }

    @Test func selectionContainingPlaceholderIsNotExpandedAgain() {
        #expect(PromptRenderer.render(action("A {selection} B"), selection: "{selection}").userMessage == "A {selection} B")
    }

    @Test func replaceModeAddsPlainOutputInstruction() {
        let r = PromptRenderer.render(action("x", system: "你是编辑"), selection: "s")
        #expect(r.system.hasPrefix("你是编辑"))
        #expect(r.system.contains(PromptRenderer.plainOutputInstruction))
        #expect(r.output == .replace)
    }

    @Test func showModeDoesNotForcePlainOutput() {
        let r = PromptRenderer.render(action("x", output: .show), selection: "s")
        #expect(r.system.isEmpty)
        #expect(r.output == .show)
    }
}

// MARK: - 服务选择

@Suite struct LLMTargetResolverTests {

    private func settings() -> Settings {
        var s = Settings()
        s.providers = [
            "claude": .defaultAnthropic,
            "ollama": ProviderConfig(name: "ollama", protocolType: .openai,
                                     baseURL: URL(string: "http://localhost:11434/v1")!, model: "qwen"),
        ]
        s.llm.provider = "claude"
        return s
    }

    @Test func usesDefaultProviderAndModel() throws {
        let t = try LLMTargetResolver.resolve(prompt: Prompt(id: "a", title: "A", content: "x"), settings: settings())
        #expect(t.provider.name == "anthropic")
        #expect(t.model == "claude-opus-5-5")
    }

    @Test func promptOverridesProviderAndModel() throws {
        let p = Prompt(id: "a", title: "A", content: "x", provider: "ollama", model: "llama")
        let t = try LLMTargetResolver.resolve(prompt: p, settings: settings())
        #expect(t.provider.name == "ollama")
        #expect(t.model == "llama")
    }

    @Test func unknownProviderThrows() {
        let p = Prompt(id: "a", title: "A", content: "x", provider: "nope")
        #expect(throws: LLMError.self) { try LLMTargetResolver.resolve(prompt: p, settings: settings()) }
    }
}

// MARK: - 请求构造

@Suite struct LLMRequestBuilderTests {

    private let rendered = RenderedAction(system: "sys", userMessage: "hello", output: .replace)

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func provider(_ proto: LLMProtocol, _ url: String, maxTokens: Int? = nil, effort: String? = nil,
                          extra: [String: Any]? = nil) -> ProviderConfig {
        ProviderConfig(name: "p", protocolType: proto, baseURL: URL(string: url)!, model: "m",
                       maxTokens: maxTokens, effort: effort,
                       extraBody: extra.map { try! JSONSerialization.data(withJSONObject: $0) })
    }

    @Test func endpointsFollowSDKConventions() {
        #expect(LLMRequestBuilder.endpoint(for: provider(.anthropic, "https://api.anthropic.com")).absoluteString
                == "https://api.anthropic.com/v1/messages")
        #expect(LLMRequestBuilder.endpoint(for: provider(.openai, "https://api.deepseek.com/")).absoluteString
                == "https://api.deepseek.com/chat/completions")
        #expect(LLMRequestBuilder.endpoint(for: provider(.openai, "http://localhost:11434/v1")).absoluteString
                == "http://localhost:11434/v1/chat/completions")
    }

    @Test func officialAnthropicRequest() throws {
        let target = LLMTarget(provider: .defaultAnthropic, model: "claude-opus-5-5")
        let req = try LLMRequestBuilder.build(rendered, target: target, apiKey: "k", defaultEffort: "medium")
        let h = req.allHTTPHeaderFields ?? [:]
        #expect(h["x-api-key"] == "k")
        #expect(h["anthropic-version"] == "2026-10-21")
        #expect(h["anthropic-beta"] == "server-side-fallback-2026-07-01")

        let b = try body(req)
        #expect(b["model"] as? String == "claude-opus-5-5")
        #expect(b["stream"] as? Bool == true)
        #expect(b["max_tokens"] as? Int == 64000)
        #expect(b["system"] as? String == "sys")
        #expect(b["fallbacks"] as? String == "default")
        #expect((b["output_config"] as? [String: Any])?["effort"] as? String == "medium")
        #expect(b["thinking"] == nil)
        #expect(b["temperature"] == nil)
        let messages = try #require(b["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["content"] as? String == "hello")
    }

    @Test func thirdPartyAnthropicOmitsOfficialOnlyParameters() throws {
        let p = provider(.anthropic, "https://api.deepseek.com/anthropic", maxTokens: 8192)
        let req = try LLMRequestBuilder.build(rendered, target: LLMTarget(provider: p, model: "m"),
                                              apiKey: "k", defaultEffort: "medium")
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == nil)
        let b = try body(req)
        #expect(b["fallbacks"] == nil)
        #expect(b["output_config"] == nil)
        #expect(b["max_tokens"] as? Int == 8192)
    }

    @Test func anthropicRequiresKey() {
        let target = LLMTarget(provider: .defaultAnthropic, model: "m")
        #expect(throws: LLMError.self) {
            try LLMRequestBuilder.build(rendered, target: target, apiKey: nil, defaultEffort: "medium")
        }
    }

    @Test func openAIRequest() throws {
        let p = provider(.openai, "https://api.deepseek.com", extra: ["thinking": ["type": "disabled"]])
        let req = try LLMRequestBuilder.build(rendered, target: LLMTarget(provider: p, model: "deepseek-flash"),
                                              apiKey: "sk", defaultEffort: "medium")
        #expect(req.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(req.value(forHTTPHeaderField: "authorization") == "Bearer sk")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == nil)

        let b = try body(req)
        #expect(b["model"] as? String == "deepseek-flash")
        #expect(b["stream"] as? Bool == true)
        #expect(b["max_tokens"] == nil)
        #expect((b["thinking"] as? [String: String])?["type"] == "disabled")
        let messages = try #require(b["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(messages[0]["content"] as? String == "sys")
    }

    @Test func openAIWithoutKeySendsNoAuthorization() throws {
        let p = provider(.openai, "http://localhost:11434/v1", maxTokens: 512)
        let shown = RenderedAction(system: "", userMessage: "hi", output: .show)
        let req = try LLMRequestBuilder.build(shown, target: LLMTarget(provider: p, model: "qwen"),
                                              apiKey: nil, defaultEffort: "medium")
        #expect(req.value(forHTTPHeaderField: "authorization") == nil)
        let b = try body(req)
        #expect(b["max_tokens"] as? Int == 512)
        #expect((b["messages"] as? [[String: Any]])?.count == 1)   // 空 system 不发送
    }

    @Test func extraBodyOverridesDefaults() throws {
        let p = provider(.openai, "https://x.com", extra: ["stream": false, "model": "other"])
        let req = try LLMRequestBuilder.build(rendered, target: LLMTarget(provider: p, model: "m"),
                                              apiKey: nil, defaultEffort: "medium")
        #expect(try body(req)["model"] as? String == "other")
    }

    @Test func errorMessages() {
        let body = Data(#"{"error":{"type":"x","message":"Model Not Exist"}}"#.utf8)
        #expect(LLMRequestBuilder.errorMessage(status: 401, body: body).contains("API Key"))
        #expect(LLMRequestBuilder.errorMessage(status: 404, body: body).contains("Model Not Exist"))
        #expect(LLMRequestBuilder.errorMessage(status: 429, body: Data()).contains("限流"))
        #expect(LLMRequestBuilder.errorMessage(status: 400, body: body).contains("Model Not Exist"))
    }
}

// MARK: - 流式解析

private func parse(_ parser: some StreamLineParser, _ text: String, chunkSize: Int = .max) -> [StreamEvent] {
    var splitter = LineSplitter()
    var events: [StreamEvent] = []
    let chars = Array(text)
    var i = 0
    while i < chars.count {
        let end = chunkSize == .max ? chars.count : min(i + chunkSize, chars.count)
        for line in splitter.feed(String(chars[i..<end])) { events += parser.events(forLine: line) }
        i = end
    }
    return events
}

@Suite struct AnthropicStreamParserTests {

    private let sample = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5"}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

    event: ping
    data: {"type":"ping"}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"你好"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"，世界"}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

    event: message_stop
    data: {"type":"message_stop"}


    """
    private let expected: [StreamEvent] = [.thinking, .text("你好"), .text("，世界"), .stop(reason: "end_turn")]

    @Test func extractsEvents() {
        #expect(parse(AnthropicStreamParser(), sample) == expected)
    }

    @Test(arguments: [1, 3, 7, 50])
    func handlesArbitraryChunkBoundaries(size: Int) {
        #expect(parse(AnthropicStreamParser(), sample, chunkSize: size) == expected)
    }

    @Test func handlesCRLF() {
        #expect(parse(AnthropicStreamParser(), sample.replacingOccurrences(of: "\n", with: "\r\n")) == expected)
    }

    @Test func refusalAndError() {
        let events = parse(AnthropicStreamParser(), """
        data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

        """)
        #expect(events == [.stop(reason: "refusal"), .error(type: "overloaded_error", message: "Overloaded")])
    }

    @Test func ignoresFallbackBlocksAndMalformedData() {
        let events = parse(AnthropicStreamParser(), """
        data: {"type":"content_block_start","index":2,"content_block":{"type":"fallback"}}
        data: {not json
        data: {"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"续写"}}

        """)
        #expect(events == [.text("续写")])
    }
}

@Suite struct OpenAIStreamParserTests {

    /// 取自本机 Ollama 0.32.14 的真实输出格式（思考内容在 reasoning 字段）。
    private let ollama = """
    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"","reasoning":"用户"},"finish_reason":null}]}

    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"The weather"},"finish_reason":null}]}

    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":" is nice."},"finish_reason":null}]}

    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

    data: [DONE]


    """

    @Test func parsesOllamaStream() {
        #expect(parse(OpenAIStreamParser(), ollama) ==
                [.thinking, .text("The weather"), .text(" is nice."), .stop(reason: "end_turn")])
    }

    @Test(arguments: [1, 5, 33])
    func handlesArbitraryChunkBoundaries(size: Int) {
        #expect(parse(OpenAIStreamParser(), ollama, chunkSize: size) ==
                [.thinking, .text("The weather"), .text(" is nice."), .stop(reason: "end_turn")])
    }

    @Test func deepSeekReasoningContent() {
        let events = parse(OpenAIStreamParser(), """
        data: {"choices":[{"index":0,"delta":{"reasoning_content":"思考"},"finish_reason":null}]}
        data: {"choices":[{"index":0,"delta":{"content":"答案"},"finish_reason":"stop"}]}

        """)
        #expect(events == [.thinking, .text("答案"), .stop(reason: "end_turn")])
    }

    @Test(arguments: [("length", "max_tokens"), ("content_filter", "refusal"), ("stop", "end_turn"), ("tool_calls", "tool_calls")])
    func normalizesFinishReason(raw: String, normalized: String) {
        #expect(OpenAIStreamParser.normalize(raw) == normalized)
    }

    @Test func streamError() {
        let events = parse(OpenAIStreamParser(), #"data: {"error":{"type":"server_error","message":"boom"}}"# + "\n")
        #expect(events == [.error(type: "server_error", message: "boom")])
    }
}


@Suite struct InsecureTransportTests {
    private func target(_ url: String) -> LLMTarget {
        LLMTarget(provider: ProviderConfig(name: "p", protocolType: .openai, baseURL: URL(string: url)!, model: "m"), model: "m")
    }
    private let action = RenderedAction(system: "", userMessage: "hi", output: .replace)

    @Test(arguments: ["http://192.168.1.10:11434/v1", "http://example.com", "http://ollama.local:11434/v1"])
    func 明文远程地址拒绝发送Key(url: String) {
        #expect(throws: LLMError.self) {
            try LLMRequestBuilder.build(action, target: target(url), apiKey: "secret", defaultEffort: "medium")
        }
    }

    @Test(arguments: ["http://localhost:11434/v1", "http://127.0.0.1:8080", "http://[::1]:11434/v1", "https://example.com"])
    func 本机或https允许发送Key(url: String) throws {
        let request = try LLMRequestBuilder.build(action, target: target(url), apiKey: "secret", defaultEffort: "medium")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer secret")
    }

    @Test func 明文远程地址不带Key可以请求() throws {
        let request = try LLMRequestBuilder.build(action, target: target("http://192.168.1.10:11434/v1"), apiKey: nil, defaultEffort: "medium")
        #expect(request.value(forHTTPHeaderField: "authorization") == nil)
    }
}
