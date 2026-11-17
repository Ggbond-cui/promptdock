import Testing
import Foundation
@testable import PromptDockCore

struct VocabularyNotebookTests {

    /// 固定日期（本地时区 2077-03-05），测试不依赖运行当天。
    private var date: Date {
        Calendar.current.date(from: DateComponents(year: 2077, month: 3, day: 5, hour: 14, minute: 30))!
    }

    // MARK: - 文件名与模板

    @Test func monthlyFileName() {
        #expect(VocabularyNotebook.fileName(for: date) == "2077-03.md")
    }

    @Test func templateHasFrontmatterTitleAndAnchor() {
        let text = VocabularyNotebook.template(for: date)
        #expect(text.contains("type: vocabulary"))
        #expect(text.contains("# 📚 词汇表 · 2077 年 3 月"))
        #expect(text.contains("<!-- promptdock:insert -->"))
    }

    // MARK: - 词条标题

    @Test func titleUsesFirstNonEmptyLine() {
        #expect(VocabularyNotebook.title(for: "\n  \nrecap is short\nsecond line") == "recap is short")
    }

    @Test func titleTruncatedToForty() {
        let long = String(repeating: "a", count: 50)
        #expect(VocabularyNotebook.title(for: long) == String(repeating: "a", count: 40) + "…")
    }

    @Test func titleFallsBackWhenEmpty() {
        #expect(VocabularyNotebook.title(for: " \n ") == "未命名")
    }

    // MARK: - 词条内容

    @Test func entryContainsHeadingPhoneticAndCallouts() {
        let info = PhoneticInfo(ipa: "/ˈriːkæp/", gloss: "扼要重述")
        let text = VocabularyNotebook.entry(
            title: "recap", phonetic: info, source: "the recap of the meeting", explanation: "扼要重述\n\n- 分点一")
        #expect(text.contains("### recap `/ˈriːkæp/` 扼要重述"))
        #expect(text.contains("> [!quote]- 📖 原文"))
        #expect(text.contains("> the recap of the meeting"))
        #expect(text.contains("> [!tip] 💡 中文解释"))
        #expect(text.contains("> 扼要重述"))
        #expect(text.contains("> - 分点一"))
    }

    @Test func entryWithoutPhoneticOmitsBackticks() {
        let text = VocabularyNotebook.entry(
            title: "回顾", phonetic: nil, source: "原文", explanation: "解释")
        #expect(text.contains("### 回顾\n"))
        #expect(!text.contains("`"))
    }

    @Test func headingsInExplanationDemotedToBold() {
        let text = VocabularyNotebook.entry(
            title: "recap", phonetic: nil, source: "recap", explanation: "# 一句话结论\n正文")
        #expect(text.contains("> **一句话结论**"))
        #expect(!text.contains("> # "))
    }

    @Test func hashLinesInsideCodeFenceKept() {
        let text = VocabularyNotebook.entry(
            title: "code", phonetic: nil, source: "s", explanation: "```swift\n# 注释\n```")
        #expect(text.contains("> # 注释"))
        #expect(!text.contains("> **注释**"))
    }

    // MARK: - 插入

    @Test func firstEntryCreatesDaySectionAfterAnchor() {
        let file = VocabularyNotebook.template(for: date)
        let updated = VocabularyNotebook.insert(entry: "ENTRY", into: file, date: date)
        #expect(updated.contains("## 📅 2077-03-05"))
        // 当天节插在锚点之后
        let anchor = updated.range(of: "<!-- promptdock:insert -->")!.upperBound
        #expect(updated[anchor...].contains("## 📅 2077-03-05"))
        #expect(updated[anchor...].contains("ENTRY"))
    }

    @Test func secondEntrySameDayInsertedAtTopOfSection() {
        let file = VocabularyNotebook.insert(entry: "FIRST", into: VocabularyNotebook.template(for: date), date: date)
        let updated = VocabularyNotebook.insert(entry: "SECOND", into: file, date: date)
        let first = updated.range(of: "FIRST")!.lowerBound
        let second = updated.range(of: "SECOND")!.lowerBound
        #expect(second < first)   // 最新在最上
    }

    @Test func newDaySectionStaysAboveOldDays() {
        let older = Calendar.current.date(from: DateComponents(year: 2077, month: 3, day: 1))!
        var file = VocabularyNotebook.template(for: date)
        file = VocabularyNotebook.insert(entry: "OLD", into: file, date: older)
        file = VocabularyNotebook.insert(entry: "NEW", into: file, date: date)
        let old = file.range(of: "## 📅 2077-03-01")!.lowerBound
        let new = file.range(of: "## 📅 2077-03-05")!.lowerBound
        #expect(new < old)   // 月内倒序：晚的一天靠上
    }

    @Test func missingAnchorAppendsToEnd() {
        let updated = VocabularyNotebook.insert(entry: "ENTRY", into: "# 只有标题", date: date)
        #expect(updated.hasSuffix("ENTRY"))
        #expect(updated.contains("## 📅 2077-03-05"))
    }
}
