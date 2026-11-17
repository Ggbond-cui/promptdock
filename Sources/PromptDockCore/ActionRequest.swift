import Foundation

/// 渲染后的 action：发给模型的 system 与 user 消息。
public struct RenderedAction: Sendable, Equatable {
    public var system: String
    public var userMessage: String
    public var output: OutputMode

    public init(system: String, userMessage: String, output: OutputMode) {
        self.system = system
        self.userMessage = userMessage
        self.output = output
    }
}

/// 把 action 条目与选中文本组合成请求内容（spec 9.3）。
public enum PromptRenderer {
    public static let placeholder = "{selection}"

    /// replace / copy 模式下追加到 system 的约束：结果要直接替换原文，不能带解释。
    public static let plainOutputInstruction =
        "只输出处理后的文本本身。不要添加任何解释、前言、结语，不要用引号或 Markdown 代码块包裹。"

    public static func render(_ prompt: Prompt, selection: String) -> RenderedAction {
        let output = prompt.output ?? .replace

        let user: String
        if prompt.content.contains(placeholder) {
            // 一次性替换，选中文本里即使含有 {selection} 也不会被再次展开
            user = prompt.content.components(separatedBy: placeholder).joined(separator: selection)
        } else {
            user = prompt.content.trimmingCharacters(in: .newlines) + "\n\n" + selection
        }

        var systemParts: [String] = []
        if let s = prompt.system?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { systemParts.append(s) }
        if output != .show { systemParts.append(plainOutputInstruction) }

        return RenderedAction(system: systemParts.joined(separator: "\n\n"), userMessage: user, output: output)
    }
}

public struct LLMError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// 一次调用最终使用的服务与模型。
public struct LLMTarget: Sendable, Equatable {
    public var provider: ProviderConfig
    public var model: String
}

public enum LLMTargetResolver {
    /// 条目的 provider / model 优先，其次是全局默认服务及其 model。
    public static func resolve(prompt: Prompt, settings: Settings) throws(LLMError) -> LLMTarget {
        let name = prompt.provider ?? settings.llm.provider
        guard let provider = settings.providers[name] else {
            throw LLMError("服务「\(name)」未在 settings.providers 中定义")
        }
        return LLMTarget(provider: provider, model: prompt.model ?? provider.model)
    }
}

/// 两种协议的请求构造（raw HTTP；Swift 没有官方 SDK）。
public enum LLMRequestBuilder {
    public static let anthropicVersion = "2026-10-21"
    /// 服务端拒答时自动切换到备用模型（fallbacks: "default" 需要该 beta）。
    public static let fallbackBeta = "server-side-fallback-2026-07-01"
    public static let defaultAnthropicMaxTokens = 64000

    public static func endpoint(for provider: ProviderConfig) -> URL {
        var base = provider.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let path = provider.protocolType == .anthropic ? "/v1/messages" : "/chat/completions"
        return URL(string: base + path)!
    }

    public static func build(
        _ action: RenderedAction, target: LLMTarget, apiKey: String?, defaultEffort: String
    ) throws -> URLRequest {
        let provider = target.provider
        if provider.isInsecureRemote, let apiKey, !apiKey.isEmpty {
            throw LLMError("服务「\(provider.name)」的地址是明文 http，为防止 API Key 泄露已拒绝发送；请改用 https，或清除该服务的 Key")
        }
        var request = URLRequest(url: endpoint(for: provider))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any]
        switch provider.protocolType {
        case .anthropic:
            guard let apiKey, !apiKey.isEmpty else {
                throw LLMError("服务「\(provider.name)」未设置 API Key：菜单栏 → API Key")
            }
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
            body = [
                "model": target.model,
                "max_tokens": provider.maxTokens ?? defaultAnthropicMaxTokens,
                "stream": true,
                "messages": [["role": "user", "content": action.userMessage]],
            ]
            if !action.system.isEmpty { body["system"] = action.system }
            if provider.isOfficialAnthropic {
                request.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
                body["output_config"] = ["effort": provider.effort ?? defaultEffort]
            } else if let effort = provider.effort {
                body["output_config"] = ["effort": effort]
            }

        case .openai:
            // 未设置 Key 时不带鉴权头（本地 Ollama 等无需 Key）
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
            }
            var messages: [[String: Any]] = []
            if !action.system.isEmpty { messages.append(["role": "system", "content": action.system]) }
            messages.append(["role": "user", "content": action.userMessage])
            body = ["model": target.model, "stream": true, "messages": messages]
            if let maxTokens = provider.maxTokens { body["max_tokens"] = maxTokens }
        }

        if let extra = provider.extraBody,
           let dict = try? JSONSerialization.jsonObject(with: extra) as? [String: Any] {
            body.merge(dict) { _, new in new }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// 非 200 响应转成面向用户的一行说明。两种协议的错误体都是 {"error": {"message": ...}}。
    public static func errorMessage(status: Int, body: Data) -> String {
        let detail = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
            .flatMap { $0["error"] as? [String: Any] }
            .flatMap { $0["message"] as? String }
        let suffix = detail.map { "：\($0)" } ?? ""
        switch status {
        case 401: return "API Key 无效或未设置（HTTP 401）"
        case 403: return "API Key 无权访问该模型（HTTP 403）" + suffix
        case 404: return "接口地址或模型不存在（HTTP 404），请检查 base_url 与 model" + suffix
        case 429: return "请求被限流或额度不足，请稍后再试（HTTP 429）" + suffix
        case 529: return "模型服务过载，请稍后再试（HTTP 529）"
        case 500...599: return "模型服务异常（HTTP \(status)）" + suffix
        default: return "请求失败（HTTP \(status)）" + suffix
        }
    }
}

// MARK: - 流式响应解析

public enum StreamEvent: Sendable, Equatable {
    case text(String)
    /// 模型正在思考（不携带内容，仅用于界面状态）。
    case thinking
    /// 统一的结束原因：end_turn / max_tokens / refusal，其他值原样透传。
    case stop(reason: String)
    case error(type: String, message: String)
}

public protocol StreamLineParser: Sendable {
    /// 处理一整行（不含换行符）。
    func events(forLine line: String) -> [StreamEvent]
}

extension StreamLineParser {
    /// 取出 SSE 的 data 行内容；非 data 行返回 nil。
    fileprivate func dataPayload(_ raw: String) -> String? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        guard line.hasPrefix("data:") else { return nil }
        return line.dropFirst(5).trimmingCharacters(in: .whitespaces)
    }

    fileprivate func jsonObject(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Anthropic Messages API 的 SSE。每个 data 行是一个完整 JSON，不依赖空行分隔
/// （URLSession 的按行读取会丢弃空行）。
public struct AnthropicStreamParser: StreamLineParser {
    public init() {}

    public func events(forLine raw: String) -> [StreamEvent] {
        guard let payload = dataPayload(raw), let json = jsonObject(payload),
              let type = json["type"] as? String else { return [] }

        switch type {
        case "content_block_start":
            let block = json["content_block"] as? [String: Any]
            return block?["type"] as? String == "thinking" ? [.thinking] : []
        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta":
                guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
                return [.text(text)]
            case "thinking_delta":
                return [.thinking]
            default:
                return []
            }
        case "message_delta":
            guard let reason = (json["delta"] as? [String: Any])?["stop_reason"] as? String else { return [] }
            return [.stop(reason: reason)]
        case "error":
            let error = json["error"] as? [String: Any]
            return [.error(type: error?["type"] as? String ?? "unknown", message: error?["message"] as? String ?? "")]
        default:
            // message_start / fallback 块 / ping / message_stop 等无需处理
            return []
        }
    }
}

/// OpenAI Chat Completions 兼容接口的 SSE（DeepSeek、Ollama 等）。
public struct OpenAIStreamParser: StreamLineParser {
    public init() {}

    public func events(forLine raw: String) -> [StreamEvent] {
        guard let payload = dataPayload(raw), payload != "[DONE]", let json = jsonObject(payload) else { return [] }

        if let error = json["error"] as? [String: Any] {
            return [.error(type: error["type"] as? String ?? "error", message: error["message"] as? String ?? "")]
        }
        guard let choice = (json["choices"] as? [[String: Any]])?.first else { return [] }

        var events: [StreamEvent] = []
        if let delta = choice["delta"] as? [String: Any] {
            // 思考内容：DeepSeek 用 reasoning_content，Ollama 用 reasoning
            let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String) ?? ""
            if !reasoning.isEmpty { events.append(.thinking) }
            if let text = delta["content"] as? String, !text.isEmpty { events.append(.text(text)) }
        }
        if let finish = choice["finish_reason"] as? String {
            events.append(.stop(reason: Self.normalize(finish)))
        }
        return events
    }

    static func normalize(_ finish: String) -> String {
        switch finish {
        case "stop": "end_turn"
        case "length": "max_tokens"
        case "content_filter": "refusal"
        default: finish
        }
    }
}

/// 把任意分片的文本切成整行。Swift 把 "\r\n" 视为一个字符，按 isNewline 切分可同时兼容 \n、\r\n、\r。
public struct LineSplitter: Sendable {
    private var buffer = ""
    public init() {}

    public mutating func feed(_ chunk: String) -> [String] {
        buffer += chunk
        var lines: [String] = []
        while let index = buffer.firstIndex(where: \.isNewline) {
            lines.append(String(buffer[buffer.startIndex..<index]))
            buffer.removeSubrange(buffer.startIndex...index)
        }
        return lines
    }
}
