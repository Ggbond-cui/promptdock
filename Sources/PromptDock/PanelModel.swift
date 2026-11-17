import Combine
import Foundation
import PromptDockCore

enum PanelMode: Equatable {
    /// ⌥Space：检索并粘贴 snippet。
    case prompts
    /// ⌥⇧Space：对选中文字执行 action。
    case actions(selection: String)
}

enum ActionPhase: Equatable {
    case choosing
    case running
    case done
    case failed(String)
}

@MainActor
final class PanelModel: ObservableObject {
    @Published var query = "" { didSet { recompute() } }
    @Published private(set) var results: [RankedPrompt] = []
    @Published var selection = 0
    @Published var notice: String?
    /// 每次面板显示时递增，触发搜索框重新获得焦点。
    @Published private(set) var focusRequest = 0

    @Published private(set) var mode: PanelMode = .prompts
    @Published var phase: ActionPhase = .choosing
    @Published var output = ""
    @Published private(set) var activePrompt: Prompt?
    @Published private(set) var activeOutputMode: OutputMode = .replace
    /// 当前调用的「服务 · 模型」，显示在结果面板标题栏。
    @Published private(set) var activeTargetLabel = ""
    /// 模型正在思考、尚未输出正文。
    @Published var isThinking = false

    private var allPrompts: [Prompt] = []
    private var frecency: [String: Double] = [:]

    var selected: RankedPrompt? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    var selectionText: String {
        if case .actions(let text) = mode { return text }
        return ""
    }

    func prepare(mode: PanelMode, prompts: [Prompt], frecency: [String: Double], notice: String?) {
        self.mode = mode
        self.allPrompts = prompts
        self.frecency = frecency
        self.notice = notice
        phase = .choosing
        output = ""
        activePrompt = nil
        query = ""          // 触发 recompute
        recompute()
        focusRequest += 1
    }

    func update(prompts: [Prompt]) {
        allPrompts = prompts
        recompute()
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    func beginAction(_ prompt: Prompt, output mode: OutputMode, targetLabel: String) {
        activePrompt = prompt
        activeOutputMode = mode
        activeTargetLabel = targetLabel
        isThinking = false
        output = ""
        phase = .running
    }

    private func recompute() {
        let wanted: PromptType = mode == .prompts ? .snippet : .action
        let visible = allPrompts.filter { $0.type == wanted }
        results = Matcher.rank(prompts: visible, frecency: frecency, query: query)
        selection = 0
    }
}
