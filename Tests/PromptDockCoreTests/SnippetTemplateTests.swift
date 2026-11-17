import Testing
@testable import PromptDockCore

@Suite struct SnippetTemplateTests {

    @Test func 没有占位符时原样输出() {
        #expect(SnippetTemplate.render("普通文本\n") == RenderedSnippet(text: "普通文本\n", cursor: nil))
    }

    @Test func 选中第一个占位符() {
        let r = SnippetTemplate.render("最近 {{XX}} 天的 PR\n\n")
        // 有占位符时去掉末尾换行
        #expect(r.text == "最近 XX 天的 PR")
        // 末尾向左移过「 天的 PR」6 个字符，再选中 XX
        #expect(r.cursor == CursorPlacement(moveLeft: 6, selectLength: 2))
    }

    @Test func 没有占位符时保留末尾换行() {
        #expect(SnippetTemplate.render("a\n").text == "a\n")
    }

    @Test func 占位符在末尾时也去掉末尾换行() {
        #expect(SnippetTemplate.render("a{{}}\n") == RenderedSnippet(text: "a", cursor: CursorPlacement(moveLeft: 0, selectLength: 0)))
    }

    @Test func 空占位符只定位光标() {
        let r = SnippetTemplate.render("前{{}}后")
        #expect(r.text == "前后")
        #expect(r.cursor == CursorPlacement(moveLeft: 1, selectLength: 0))
    }

    @Test func 多个占位符只选第一个() {
        let r = SnippetTemplate.render("{{a}}-{{bb}}")
        #expect(r.text == "a-bb")
        #expect(r.cursor == CursorPlacement(moveLeft: 3, selectLength: 1))
    }

    @Test func 按字符计数() {
        let r = SnippetTemplate.render("👨‍👩‍👧{{天数}}é\r\n末")
        #expect(r.text == "👨‍👩‍👧天数é\r\n末")
        #expect(r.cursor == CursorPlacement(moveLeft: 3, selectLength: 2))
    }

    @Test(arguments: ["{{a\nb}}", "{{ {x} }}", "只有开头 {{", "只有结尾 }}", "{selection}", "{{{x}}}"])
    func 不是占位符的写法不处理(text: String) {
        #expect(SnippetTemplate.render(text) == RenderedSnippet(text: text, cursor: nil))
    }

    @Test func 跨度过大时不定位() {
        let r = SnippetTemplate.render("{{x}}" + String(repeating: "a", count: SnippetTemplate.maxCursorMoves))
        #expect(r.cursor == nil)
        #expect(r.text.count == SnippetTemplate.maxCursorMoves + 1)
    }
}
