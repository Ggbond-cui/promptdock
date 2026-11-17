import Foundation
import Testing
@testable import PromptDockCore

@Suite struct ProviderFormTests {

    private func valid() -> ProviderForm {
        ProviderForm(name: "deepseek", protocolType: .openai, baseURL: "https://api.deepseek.com", model: "deepseek-flash")
    }

    @Test func 有效表单() throws {
        var f = valid()
        f.maxTokens = " 4096 "
        f.effort = "low"
        f.extraBody = "{\"thinking\": {\"type\": \"disabled\"}}"
        let p = try f.validated()
        #expect(p.name == "deepseek")
        #expect(p.maxTokens == 4096)
        #expect(p.effort == "low")
        #expect(String(decoding: p.extraBody!, as: UTF8.self) == "{\"thinking\":{\"type\":\"disabled\"}}")
    }

    @Test func 空的可选字段不设置() throws {
        let p = try valid().validated()
        #expect(p.maxTokens == nil && p.effort == nil && p.extraBody == nil)
    }

    @Test(arguments: [
        ("", "https://x.com", "m", "", ""),
        ("有中文", "https://x.com", "m", "", ""),
        ("a b", "https://x.com", "m", "", ""),
        ("a", "ftp://x.com", "m", "", ""),
        ("a", "x.com", "m", "", ""),
        ("a", "https://x.com", " ", "", ""),
        ("a", "https://x.com", "m", "0", ""),
        ("a", "https://x.com", "m", "abc", ""),
        ("a", "https://x.com", "m", "", "[1]"),
        ("a", "https://x.com", "m", "", "{bad"),
    ])
    func 无效表单(name: String, url: String, model: String, tokens: String, body: String) {
        let f = ProviderForm(name: name, baseURL: url, model: model, maxTokens: tokens, extraBody: body)
        #expect(throws: SettingsWriterError.self) { try f.validated() }
    }

    @Test func 配置转表单再转回不变() throws {
        let body = try JSONSerialization.data(withJSONObject: ["reasoning_effort": "none"], options: [.sortedKeys])
        let p = ProviderConfig(name: "ollama", protocolType: .openai, baseURL: URL(string: "http://localhost:11434/v1")!,
                               model: "qwen3.8:27b-mlx", maxTokens: 100, effort: "high", extraBody: body)
        #expect(try ProviderForm(p).validated() == p)
    }

    @Test func 服务列表合并() throws {
        var s = Settings()
        var other = valid()
        other.name = "ollama"
        try ProviderListValidator.apply([valid(), other], defaultProvider: "ollama", to: &s)
        #expect(Set(s.providers.keys) == ["deepseek", "ollama"])
        #expect(s.llm.provider == "ollama")

        #expect(throws: SettingsWriterError.self) {
            try ProviderListValidator.apply([valid(), valid()], defaultProvider: "deepseek", to: &s)
        }
        #expect(throws: SettingsWriterError.self) {
            try ProviderListValidator.apply([valid()], defaultProvider: "missing", to: &s)
        }
    }
}

@Suite struct GeneralFormTests {

    @Test func 应用到设置() throws {
        var s = Settings()
        var f = GeneralForm(s)
        f.promptPanel = "control+option+p"
        f.restoreClipboard = false
        f.restoreDelayMs = 900
        f.effort = "high"
        f.proxy = "http://127.0.0.1:7890"
        try f.apply(to: &s)
        #expect(s.hotkeys.promptPanel == "control+option+p")
        #expect(s.paste.restoreClipboard == false && s.paste.restoreDelayMs == 900)
        #expect(s.llm.effort == "high")
        #expect(s.network.proxy == ProxySetting(host: "127.0.0.1", port: 7890))
        #expect(GeneralForm(s) == f)
    }

    @Test func 代理留空表示跟随系统() throws {
        var s = Settings()
        s.network.proxy = ProxySetting(host: "h", port: 1)
        var f = GeneralForm(s)
        f.proxy = " "
        try f.apply(to: &s)
        #expect(s.network.proxy == nil)
    }

    @Test func 无效输入不修改设置() {
        let original = Settings()
        for change in [
            { (f: inout GeneralForm) in f.promptPanel = "option+nokey" },
            { (f: inout GeneralForm) in f.actionPanel = f.promptPanel },
            { (f: inout GeneralForm) in f.restoreDelayMs = -1 },
            { (f: inout GeneralForm) in f.proxy = "socks5://127.0.0.1:1080" },
        ] {
            var s = original
            var f = GeneralForm(s)
            change(&f)
            #expect(throws: SettingsWriterError.self) { try f.apply(to: &s) }
            #expect(s == original)
        }
    }
}

@Suite struct PromptFormTests {

    @Test func 原条目转表单再转回不变() throws {
        let prompts = [
            Prompt(id: "a", title: "甲", keywords: ["x", "中文"], tags: ["t"], content: "内容\n"),
            Prompt(id: "b", title: "乙", type: .action, content: "{selection}", provider: "deepseek",
                   model: "m", system: "s", output: .copy),
            Prompt(id: "c", title: "丙", type: .script, content: "~/bin/x.sh"),
        ]
        for p in prompts {
            #expect(try PromptForm(p).validated(providers: ["deepseek"]) == p)
        }
    }

    @Test func 关键词支持中英文逗号() {
        #expect(PromptForm.splitList(" a, b，c ,, ") == ["a", "b", "c"])
    }

    @Test(arguments: [
        PromptForm(id: " ", title: "t", content: "c"),
        PromptForm(id: "a", title: " ", content: "c"),
        PromptForm(id: "a", title: "t", content: " \n"),
        PromptForm(id: "a", title: "t", type: .action, content: "c", provider: "missing"),
    ])
    func 无效表单(form: PromptForm) {
        #expect(throws: SettingsWriterError.self) { try form.validated(providers: ["deepseek"]) }
    }

    @Test func id重复() {
        let forms = [PromptForm(id: "a", title: "t", content: "c"), PromptForm(id: "a", title: "t2", content: "c")]
        #expect(throws: SettingsWriterError.self) { try PromptListValidator.validate(forms, providers: []) }
    }
}
