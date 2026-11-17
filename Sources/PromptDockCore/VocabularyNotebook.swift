import Foundation

/// 收藏到 Obsidian 词汇表（spec 9.4）：每月一个 Markdown 文件，按日期倒序追加词条。
/// 纯文本拼装与插入逻辑，文件读写由调用方（App 层）完成。
public enum VocabularyNotebook {

    /// 词汇表在 vault 中的目录名。
    public static let folderName = "词汇表"

    /// 月度文件名，如 `2026-11.md`。
    public static func fileName(for date: Date = Date(), calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d.md", comps.year ?? 0, comps.month ?? 0)
    }

    /// 月度文件初始模板：frontmatter + 标题 + 说明 + 插入锚点。锚点之后是词条区（最新在最上）。
    public static func template(for date: Date = Date(), calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month], from: date)
        let created = Self.dateFormatter.string(from: date)
        return """
            ---
            created: \(created)
            type: vocabulary
            month: \(String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0))
            tags: [词汇表]
            ---

            # 📚 词汇表 · \(comps.year ?? 0) 年 \(comps.month ?? 0) 月

            > [!info] 阅读积累
            > 由 PromptDock 收藏的词汇与段落，**最新在最上**。折叠的引用块是原文，展开即中文解释。

            <!-- promptdock:insert -->
            """
    }

    /// 单个词条的 Markdown：三级标题（词 + 音标 + 中文释义）+ 收藏时间 + 折叠原文 + 解释 callout。
    /// - Parameters:
    ///   - title: 词汇或段落摘要（原文首行截断），已由调用方清洗。
    ///   - phonetic: 朗读时查到的音标与释义，可为 nil。
    ///   - source: 被解释的原文全文。
    ///   - explanation: 模型输出的中文解释。
    public static func entry(
        title: String, phonetic: PhoneticInfo?, source: String, explanation: String, date: Date = Date()
    ) -> String {
        var head = title
        if let phonetic {
            head += " `\(phonetic.ipa)`"
            if let gloss = phonetic.gloss { head += " " + gloss }
        }
        let time = Self.dateTimeFormatter.string(from: date)
        return """
            ### \(head)

            🕐 \(time) · 来自 PromptDock

            > [!quote]- 📖 原文
            \(calloutBody(source))

            > [!tip] 💡 中文解释
            \(calloutBody(explanation))
            """
    }

    /// 把词条插入既有文件内容，返回新内容（不写盘）。规则：
    /// 1. 有当天日期节 → 词条插到该节标题块之后（当天最新在最上）；
    /// 2. 没有当天节 → 在插入锚点后新建当天节（保证月内倒序）；
    /// 3. 锚点也找不到（用户手工清过模板）→ 追加到文件末尾。
    public static func insert(entry: String, into content: String, date: Date = Date()) -> String {
        var lines = content.components(separatedBy: "\n")
        let dayHeading = "## 📅 \(Self.dateFormatter.string(from: date))"

        if let index = lines.firstIndex(where: { $0.hasPrefix(dayHeading) }) {
            // 当天节存在：跳过标题行及其后的空行，插到第一个词条前
            var insertAt = index + 1
            while insertAt < lines.count, lines[insertAt].isEmpty { insertAt += 1 }
            lines.insert(contentsOf: entry.components(separatedBy: "\n"), at: insertAt)
        } else if let anchor = lines.firstIndex(where: { $0.contains("<!-- promptdock:insert -->") }) {
            // 新的一天：锚点后空一行接当天节，节与后续旧内容之间也留空行
            let block = ["", dayHeading, ""] + entry.components(separatedBy: "\n") + [""]
            lines.insert(contentsOf: block, at: anchor + 1)
        } else {
            // 兜底：追加末尾
            lines.append("")
            lines.append(dayHeading)
            lines.append("")
            lines.append(contentsOf: entry.components(separatedBy: "\n"))
        }
        return lines.joined(separator: "\n")
    }

    /// 原文首行（去掉空白）截断作词条标题；空原文回退"未命名"。
    public static func title(for source: String) -> String {
        let firstLine = source
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !firstLine.isEmpty else { return "未命名" }
        return firstLine.count > 40 ? String(firstLine.prefix(40)) + "…" : firstLine
    }

    /// callout 正文：每行加 `> ` 前缀；空行保持 `>`，保证渲染时段落结构不散。
    /// 模型输出里的 Markdown 标题降级为粗体——callout 内大标题突兀，还会污染 Obsidian 大纲；
    /// 代码围栏内的 `#` 注释原样保留。
    private static func calloutBody(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var inFence = false
        return trimmed
            .components(separatedBy: "\n")
            .map { line -> String in
                if line.hasPrefix("```") { inFence.toggle() }
                var body = line.isEmpty ? ">" : "> " + line
                if !inFence, line.count <= 40, line.hasPrefix("#") {
                    let heading = line.drop(while: { $0 == "#" })
                    if heading.hasPrefix(" ") {
                        let title = heading.drop(while: { $0 == " " })
                        if !title.isEmpty { body = "> **\(title)**" }
                    }
                }
                return body
            }
            .joined(separator: "\n")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
