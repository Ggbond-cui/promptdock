import Foundation

/// 发送流式请求并逐个产出事件。取消迭代即取消网络请求。
public enum LLMClient {

    /// 默认跟随系统代理；显式指定时对本机地址不走代理（本地 Ollama）。
    public static func sessionConfiguration(proxy: ProxySetting?) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120    // 两次收到数据之间的最长间隔（本地大模型首字可能较慢）
        config.timeoutIntervalForResource = 600
        if let proxy {
            config.connectionProxyDictionary = [
                "HTTPEnable": 1, "HTTPProxy": proxy.host, "HTTPPort": proxy.port,
                "HTTPSEnable": 1, "HTTPSProxy": proxy.host, "HTTPSPort": proxy.port,
                "ExceptionsList": ["localhost", "127.0.0.1", "*.local"],
            ]
        }
        return config
    }

    public static func stream(
        _ request: URLRequest,
        protocol proto: LLMProtocol,
        configuration: @escaping @Sendable () -> URLSessionConfiguration
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let session = URLSession(configuration: configuration())
                defer { session.finishTasksAndInvalidate() }
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 64_000 { break }
                        }
                        throw LLMError(LLMRequestBuilder.errorMessage(status: status, body: body))
                    }

                    let parser: any StreamLineParser = proto == .anthropic ? AnthropicStreamParser() : OpenAIStreamParser()
                    for try await line in bytes.lines {
                        for event in parser.events(forLine: line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch let error as URLError {
                    continuation.finish(throwing: LLMError(
                        "网络错误：\(error.localizedDescription)（请检查 base_url 与代理）"))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
