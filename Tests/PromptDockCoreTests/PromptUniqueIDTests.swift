import Foundation
import Testing
@testable import PromptDockCore

@Suite struct PromptUniqueIDTests {

    @Test func 英文标题生成kebab() {
        #expect(Prompt.uniqueID(title: "Slow PR Analysis", existing: []) == "slow-pr-analysis")
        #expect(Prompt.uniqueID(title: "code review", existing: []) == "code-review")
    }

    @Test func 数字保留() {
        #expect(Prompt.uniqueID(title: "GPT 4o Rewrite", existing: []) == "gpt-4o-rewrite")
    }

    @Test func 中文标题回退到prompt() {
        #expect(Prompt.uniqueID(title: "中文润色", existing: []) == "prompt")
    }

    @Test func 混合标题只取英文数字段() {
        #expect(Prompt.uniqueID(title: "用 GPT 解释", existing: []) == "gpt")
        #expect(Prompt.uniqueID(title: "PR 分析 v2", existing: []) == "pr-v2")
    }

    @Test func 冲突时追加序号() {
        #expect(Prompt.uniqueID(title: "code-review", existing: ["code-review"]) == "code-review-2")
        #expect(
            Prompt.uniqueID(title: "code-review", existing: ["code-review", "code-review-2"])
                == "code-review-3"
        )
    }

    @Test func 中文标题冲突也递增() {
        #expect(Prompt.uniqueID(title: "润色", existing: ["prompt", "prompt-2"]) == "prompt-3")
    }

    @Test func 空标题() {
        #expect(Prompt.uniqueID(title: "", existing: []) == "prompt")
        #expect(Prompt.uniqueID(title: "！！！", existing: []) == "prompt")
    }

    @Test func 连续分隔符压缩() {
        #expect(Prompt.uniqueID(title: "a -- b", existing: []) == "a-b")
    }
}
