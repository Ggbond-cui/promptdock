import Foundation

/// 粘贴后光标的位置：先从文本末尾向左移动 moveLeft 个字符，再按住 Shift 向左选中 selectLength 个字符。
public struct CursorPlacement: Sendable, Equatable {
    public var moveLeft: Int
    public var selectLength: Int
    public init(moveLeft: Int, selectLength: Int) {
        self.moveLeft = moveLeft
        self.selectLength = selectLength
    }
}

public struct RenderedSnippet: Sendable, Equatable {
    public var text: String
    public var cursor: CursorPlacement?
}

/// 提示词占位符（spec 8.6）：`{{说明}}` 粘贴时去掉花括号，光标停在第一个占位符并选中其中文字；
/// `{{}}` 只定位光标。其余占位符只去掉花括号。
public enum SnippetTemplate {

    /// 光标需要移动的字符数超过此值时不再定位（按键事件过多会明显卡顿）。
    public static let maxCursorMoves = 3000

    public static func render(_ content: String) -> RenderedSnippet {
        var output = ""
        var first: (end: Int, length: Int)?
        var outputCount = 0
        var rest = Substring(content)

        while let open = rest.range(of: "{{") {
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else { break }
            let inner = afterOpen[..<close.lowerBound]
            // 占位符内不允许换行和花括号，避免误伤代码里的 {{ }}
            guard !inner.contains(where: { $0.isNewline || $0 == "{" || $0 == "}" }) else {
                let skip = rest[..<open.upperBound]
                output += skip
                outputCount += skip.count
                rest = afterOpen
                continue
            }
            let before = rest[..<open.lowerBound]
            output += before
            outputCount += before.count
            output += inner
            outputCount += inner.count
            if first == nil { first = (outputCount, inner.count) }
            rest = afterOpen[close.upperBound...]
        }
        output += rest
        outputCount += rest.count

        guard let first else { return RenderedSnippet(text: output, cursor: nil) }
        // 有占位符时去掉末尾换行：单行输入框会吞掉换行，导致光标位置算错一位
        while let last = output.last, last.isNewline, outputCount > first.end {
            output.removeLast()
            outputCount -= 1
        }
        let cursor = CursorPlacement(moveLeft: outputCount - first.end, selectLength: first.length)
        guard cursor.moveLeft + cursor.selectLength <= maxCursorMoves else { return RenderedSnippet(text: output, cursor: nil) }
        return RenderedSnippet(text: output, cursor: cursor)
    }
}
