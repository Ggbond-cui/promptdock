import Testing
@testable import PromptDockCore

@Suite struct LibraryStateTests {

    private func load(_ yaml: String) -> Result<LoadResult, PromptLibraryError> {
        do { return .success(try PromptLibraryParser.parse(yaml)) }
        catch let e as PromptLibraryError { return .failure(e) }
        catch { return .failure(.unreadable("\(error)")) }
    }

    private let good = """
    prompts:
      - id: a
        title: A
        content: x
      - id: a
        title: dup
        content: y
    """

    @Test func successReplacesLibraryAndWarnings() {
        var state = LibraryState()
        state.apply(load(good))
        #expect(state.library.prompts.map(\.id) == ["a"])
        #expect(state.warnings.count == 1)
        #expect(state.error == nil)
    }

    @Test func failureKeepsLastGoodLibrary() {
        var state = LibraryState()
        state.apply(load(good))
        state.apply(load("prompts: [\n"))
        #expect(state.library.prompts.map(\.id) == ["a"])
        #expect(state.error != nil)
        #expect(state.errorSummary?.hasPrefix("第 ") == true)
    }

    @Test func recoveryClearsError() {
        var state = LibraryState()
        state.apply(.failure(.unreadable("no such file")))
        #expect(state.errorSummary == "无法读取文件：no such file")
        state.apply(load(good))
        #expect(state.error == nil)
        #expect(state.errorSummary == nil)
    }

    @Test func summariesForEachErrorKind() {
        var state = LibraryState()
        state.apply(.failure(.unsupportedVersion(2)))
        #expect(state.errorSummary == "不支持的 version：2（当前只支持 1）")
        state.apply(.failure(.invalidStructure("prompts 必须是列表")))
        #expect(state.errorSummary == "prompts 必须是列表")
        state.apply(.failure(.syntax(line: nil, message: "bad")))
        #expect(state.errorSummary == "YAML 语法错误：bad")
        state.apply(.failure(.syntax(line: 4, message: "bad")))
        #expect(state.errorSummary == "第 4 行：YAML 语法错误：bad")
    }
}
