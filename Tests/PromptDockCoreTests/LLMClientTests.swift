import Foundation
import Testing
@testable import PromptDockCore

/// 模拟网络层：按 host 返回预设的状态码和分片数据，测试并行时互不干扰。
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: (status: Int, chunks: [Data])] = [:]

    static func stub(status: Int, chunks: [String]) -> URL {
        let host = "mock-\(UUID().uuidString.lowercased()).test"
        lock.withLock { stubs[host] = (status, chunks.map { Data($0.utf8) }) }
        return URL(string: "https://\(host)")!
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        guard let stub = Self.lock.withLock({ Self.stubs[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["content-type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        stub.chunks.forEach { client?.urlProtocol(self, didLoad: $0) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct LLMClientTests {

    private static let mockConfig: @Sendable () -> URLSessionConfiguration = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return config
    }

    private func run(_ base: URL, _ proto: LLMProtocol) async throws -> [StreamEvent] {
        let provider = ProviderConfig(name: "mock", protocolType: proto, baseURL: base, model: "m")
        let request = try LLMRequestBuilder.build(
            RenderedAction(system: "", userMessage: "hi", output: .show),
            target: LLMTarget(provider: provider, model: "m"), apiKey: "k", defaultEffort: "medium")
        var events: [StreamEvent] = []
        for try await event in LLMClient.stream(request, protocol: proto, configuration: Self.mockConfig) {
            events.append(event)
        }
        return events
    }

    @Test func streamsOpenAIEventsAcrossChunks() async throws {
        let url = MockURLProtocol.stub(status: 200, chunks: [
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hel",
            "lo\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
            "data: [DONE]\n\n",
        ])
        #expect(try await run(url, .openai) == [.text("Hello"), .stop(reason: "end_turn")])
    }

    @Test func streamsAnthropicEvents() async throws {
        let url = MockURLProtocol.stub(status: 200, chunks: [
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"你好\"}}\n\n",
            "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n",
        ])
        #expect(try await run(url, .anthropic) == [.text("你好"), .stop(reason: "end_turn")])
    }

    @Test func surfacesHTTPErrorWithServerMessage() async {
        let url = MockURLProtocol.stub(status: 404, chunks: [#"{"error":{"message":"Model Not Exist"}}"#])
        do {
            _ = try await run(url, .openai)
            Issue.record("应当抛出错误")
        } catch let error as LLMError {
            #expect(error.message.contains("HTTP 404"))
            #expect(error.message.contains("Model Not Exist"))
        } catch {
            Issue.record("错误类型不对：\(error)")
        }
    }
}

/// 真实调用本机 Ollama：设置 PROMPTDOCK_LIVE_OLLAMA_MODEL 环境变量时才运行。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PROMPTDOCK_LIVE_OLLAMA_MODEL"] != nil))
struct LiveOllamaTests {

    @Test(.timeLimit(.minutes(3)))
    func translatesViaLocalOllama() async throws {
        let model = ProcessInfo.processInfo.environment["PROMPTDOCK_LIVE_OLLAMA_MODEL"]!
        let provider = ProviderConfig(name: "ollama", protocolType: .openai,
                                      baseURL: URL(string: "http://localhost:11434/v1")!, model: model)
        let prompt = Prompt(id: "t", title: "翻译", type: .action, content: "把下面的文字翻译成英文：\n{selection}")
        let rendered = PromptRenderer.render(prompt, selection: "今天天气很好")
        let request = try LLMRequestBuilder.build(rendered, target: LLMTarget(provider: provider, model: model),
                                                  apiKey: nil, defaultEffort: "medium")

        let started = Date()
        var text = ""
        var thinking = false
        var stop: String?
        var firstToken: TimeInterval?
        for try await event in LLMClient.stream(request, protocol: .openai, configuration: { LLMClient.sessionConfiguration(proxy: nil) }) {
            switch event {
            case .text(let t):
                if firstToken == nil { firstToken = Date().timeIntervalSince(started) }
                text += t
            case .thinking: thinking = true
            case .stop(let r): stop = r
            case .error(_, let m): Issue.record("stream error: \(m)")
            }
        }
        print("LIVE ollama → \(text.debugDescription) | thinking=\(thinking) stop=\(stop ?? "-") ttft=\(firstToken.map { String(format: "%.1fs", $0) } ?? "-") total=\(String(format: "%.1fs", Date().timeIntervalSince(started)))")
        #expect(stop == "end_turn")
        #expect(text.lowercased().contains("weather"))
        #expect(!text.contains("<think>"))
    }
}
