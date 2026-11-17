import Foundation
import Testing
@testable import PromptDockCore

@Suite struct PromptLibraryParserTests {

    @Test func parsesFullDocument() throws {
        let yaml = """
        version: 1
        settings:
          hotkeys:
            prompt_panel: "control+space"
            action_panel: "control+shift+space"
          paste:
            restore_clipboard: false
            restore_delay_ms: 800
        prompts:
          - id: code-review
            title: 代码审查
            type: snippet
            keywords: [review, cr]
            tags: [dev]
            content: |
              请审查以下代码
          - id: polish-zh
            title: 中文润色
            type: action
            model: claude-sonnet-5-5
            system: 你是编辑
            output: replace
            content: "润色：{selection}"
        """
        let result = try PromptLibraryParser.parse(yaml)
        #expect(result.warnings.isEmpty)

        let lib = result.library
        #expect(lib.version == 1)
        #expect(lib.settings.hotkeys.promptPanel == "control+space")
        #expect(lib.settings.hotkeys.actionPanel == "control+shift+space")
        #expect(lib.settings.paste.restoreClipboard == false)
        #expect(lib.settings.paste.restoreDelayMs == 800)

        #expect(lib.prompts.count == 2)
        let first = lib.prompts[0]
        #expect(first.id == "code-review")
        #expect(first.title == "代码审查")
        #expect(first.type == .snippet)
        #expect(first.keywords == ["review", "cr"])
        #expect(first.tags == ["dev"])
        #expect(first.content == "请审查以下代码\n")

        let second = lib.prompts[1]
        #expect(second.type == .action)
        #expect(second.model == "claude-sonnet-5-5")
        #expect(second.system == "你是编辑")
        #expect(second.output == .replace)
    }

    @Test func appliesDefaultsWhenSettingsMissing() throws {
        let result = try PromptLibraryParser.parse("""
        version: 1
        prompts:
          - id: a
            title: A
            content: hello
        """)
        let lib = result.library
        #expect(lib.settings == Settings())
        #expect(lib.settings.hotkeys.promptPanel == "option+space")
        #expect(lib.settings.hotkeys.actionPanel == "option+shift+space")
        #expect(lib.settings.paste.restoreClipboard == true)
        #expect(lib.settings.paste.restoreDelayMs == 500)
        #expect(lib.prompts.first?.type == .snippet)   // type 缺省为 snippet
        #expect(lib.prompts.first?.keywords == [])
        #expect(result.warnings.isEmpty)
    }

    @Test func emptyDocumentYieldsEmptyLibrary() throws {
        for yaml in ["", "   \n", "# only comment\n"] {
            let result = try PromptLibraryParser.parse(yaml)
            #expect(result.library.prompts.isEmpty)
            #expect(result.library.settings == Settings())
        }
    }

    @Test func skipsEntriesMissingRequiredFields() throws {
        let result = try PromptLibraryParser.parse("""
        version: 1
        prompts:
          - title: 没有 id
            content: x
          - id: no-title
            content: x
          - id: no-content
            title: 没有内容
          - id: ok
            title: 正常
            content: x
        """)
        #expect(result.library.prompts.map(\.id) == ["ok"])
        #expect(result.warnings.count == 3)
    }

    @Test func skipsDuplicateIdKeepingFirst() throws {
        let result = try PromptLibraryParser.parse("""
        prompts:
          - id: dup
            title: 第一个
            content: x
          - id: dup
            title: 第二个
            content: y
        """)
        #expect(result.library.prompts.count == 1)
        #expect(result.library.prompts[0].title == "第一个")
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message.contains("dup"))
    }

    @Test func skipsUnknownTypeWithWarning() throws {
        let result = try PromptLibraryParser.parse("""
        prompts:
          - id: future
            title: 未来类型
            type: workflow
            content: x
        """)
        #expect(result.library.prompts.isEmpty)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message.contains("workflow"))
    }

    @Test func keepsEntryWithUnknownFieldButWarns() throws {
        let result = try PromptLibraryParser.parse("""
        prompts:
          - id: a
            title: A
            content: x
            colour: red
        """)
        #expect(result.library.prompts.count == 1)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message.contains("colour"))
    }

    @Test func coercesScalarValuesToStrings() throws {
        let result = try PromptLibraryParser.parse("""
        prompts:
          - id: 42
            title: 2026
            keywords: [123, true, abc]
            content: yes
        """)
        let p = try #require(result.library.prompts.first)
        #expect(p.id == "42")
        #expect(p.title == "2026")
        #expect(p.keywords == ["123", "true", "abc"])
        #expect(p.content == "true" || p.content == "yes")
    }

    @Test func invalidOutputFallsBackWithWarning() throws {
        let result = try PromptLibraryParser.parse("""
        prompts:
          - id: a
            title: A
            type: action
            content: x
            output: explode
        """)
        #expect(result.library.prompts.first?.output == nil)
        #expect(result.warnings.count == 1)
    }

    @Test func syntaxErrorReportsLineNumber() {
        let yaml = """
        version: 1
        prompts:
          - id: a
            title: "未闭合的引号
            content: x
        """
        do {
            _ = try PromptLibraryParser.parse(yaml)
            Issue.record("应当抛出语法错误")
        } catch let PromptLibraryError.syntax(line, _) {
            #expect(line != nil)
            #expect((line ?? 0) >= 4)
        } catch {
            Issue.record("错误类型不对：\(error)")
        }
    }

    @Test func rejectsUnsupportedVersion() {
        #expect(throws: PromptLibraryError.unsupportedVersion(2)) {
            try PromptLibraryParser.parse("version: 2\nprompts: []\n")
        }
    }

    @Test func rejectsNonMappingRoot() {
        #expect(throws: PromptLibraryError.self) {
            try PromptLibraryParser.parse("- a\n- b\n")
        }
    }

    @Test func bundledExampleParsesWithoutWarnings() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/prompts.example.yaml")
        let yaml = try String(contentsOf: url, encoding: .utf8)
        let result = try PromptLibraryParser.parse(yaml)
        #expect(result.warnings.isEmpty, "\(result.warnings)")
        #expect(result.library.prompts.count >= 3)
    }
}

@Suite struct LLMSettingsParserTests {

    @Test func defaultsToBuiltInAnthropic() throws {
        let s = try PromptLibraryParser.parse("prompts: []").library.settings
        #expect(s.llm.provider == "anthropic")
        #expect(s.llm.effort == "medium")
        #expect(s.providers["anthropic"]?.model == "claude-opus-5-5")
        #expect(s.providers["anthropic"]?.isOfficialAnthropic == true)
        #expect(s.network.proxy == nil)
    }

    @Test func parsesProvidersAndDefault() throws {
        let result = try PromptLibraryParser.parse("""
        settings:
          llm:
            provider: deepseek
            effort: low
          providers:
            claude:
              protocol: anthropic
              base_url: https://api.anthropic.com
              model: claude-opus-5-5
            deepseek:
              protocol: openai
              base_url: https://api.deepseek.com
              model: deepseek-flash
              max_tokens: 8192
              extra_body:
                thinking:
                  type: disabled
          network:
            proxy: "http://127.0.0.1:7890"
        prompts:
          - id: a
            title: A
            type: action
            provider: claude
            model: claude-sonnet-5-5
            content: x
        """)
        #expect(result.warnings.isEmpty, "\(result.warnings)")
        let s = result.library.settings
        #expect(s.llm.provider == "deepseek")
        #expect(s.llm.effort == "low")
        #expect(s.providers.keys.sorted() == ["claude", "deepseek"])   // 配置了 providers 就不再内置 anthropic

        let ds = try #require(s.providers["deepseek"])
        #expect(ds.protocolType == .openai)
        #expect(ds.baseURL.absoluteString == "https://api.deepseek.com")
        #expect(ds.maxTokens == 8192)
        let extra = try #require(ds.extraBody)
        let json = try #require(try JSONSerialization.jsonObject(with: extra) as? [String: [String: String]])
        #expect(json["thinking"]?["type"] == "disabled")

        #expect(s.network.proxy == ProxySetting(host: "127.0.0.1", port: 7890))
        #expect(result.library.prompts[0].provider == "claude")
        #expect(result.library.prompts[0].model == "claude-sonnet-5-5")
    }

    @Test func invalidProvidersAreSkippedWithWarnings() throws {
        let result = try PromptLibraryParser.parse("""
        settings:
          llm:
            provider: ok
          providers:
            ok:
              protocol: openai
              base_url: http://localhost:11434/v1
              model: qwen
            bad-protocol:
              protocol: gemini
              base_url: https://x.com
              model: m
            bad-url:
              protocol: openai
              base_url: ftp://x
              model: m
            no-model:
              protocol: openai
              base_url: https://x.com
            typo:
              protocol: openai
              base_url: https://x.com
              model: m
              modle: n
        prompts: []
        """)
        #expect(result.library.settings.providers.keys.sorted() == ["ok", "typo"])
        #expect(result.warnings.count == 4)
    }

    @Test func warnsWhenDefaultProviderMissing() throws {
        let result = try PromptLibraryParser.parse("""
        settings:
          llm:
            provider: nope
        prompts: []
        """)
        #expect(result.warnings.contains { $0.message.contains("nope") })
    }

    @Test func deprecatedLLMModelWarns() throws {
        let result = try PromptLibraryParser.parse("""
        settings:
          llm:
            model: claude-sonnet-5-5
        prompts: []
        """)
        #expect(result.warnings.count == 1)
        #expect(result.library.settings.providers["anthropic"]?.model == "claude-opus-5-5")
    }

    @Test func invalidEffortAndProxyWarn() throws {
        let result = try PromptLibraryParser.parse("""
        settings:
          llm:
            effort: turbo
          network:
            proxy: "socks5://x"
        prompts: []
        """)
        #expect(result.library.settings.llm.effort == "medium")
        #expect(result.library.settings.network.proxy == nil)
        #expect(result.warnings.count == 2)
    }
}
