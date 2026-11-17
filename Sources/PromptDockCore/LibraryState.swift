/// 提示词库的加载状态。解析失败时保留上一次成功加载的数据（spec 6.2 第 3 条）。
public struct LibraryState: Sendable, Equatable {
    public private(set) var library = PromptLibrary()
    public private(set) var warnings: [LoadWarning] = []
    public private(set) var error: PromptLibraryError?

    public init() {}

    public mutating func apply(_ result: Result<LoadResult, PromptLibraryError>) {
        switch result {
        case .success(let loaded):
            library = loaded.library
            warnings = loaded.warnings
            error = nil
        case .failure(let e):
            error = e
        }
    }

    /// 面向用户的一行错误说明；无错误时为 nil。
    public var errorSummary: String? {
        guard let error else { return nil }
        switch error {
        case let .syntax(line?, message): return "第 \(line) 行：YAML 语法错误：\(message)"
        case let .syntax(nil, message): return "YAML 语法错误：\(message)"
        case let .unsupportedVersion(v): return "不支持的 version：\(v)（当前只支持 \(PromptLibrary.supportedVersion)）"
        case let .invalidStructure(message): return message
        case let .unreadable(message): return "无法读取文件：\(message)"
        }
    }
}
