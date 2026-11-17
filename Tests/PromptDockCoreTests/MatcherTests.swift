import Testing
@testable import PromptDockCore

@Suite struct MatcherFieldScoreTests {

    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    @Test func exactMatch() {
        #expect(Matcher.fieldScore(query: "review", text: "review") == 1.0)
    }

    @Test func prefixMatch() {
        #expect(Matcher.fieldScore(query: "code", text: "code review") == 0.9)
    }

    @Test func substringMatch() {
        #expect(Matcher.fieldScore(query: "view", text: "code review") == 0.75)
        #expect(Matcher.fieldScore(query: "审查", text: "代码审查") == 0.75)
    }

    @Test func subsequenceMatchScaledByCompactness() {
        // c(0) … r(5)：跨度 6，紧凑度 2/6
        #expect(close(Matcher.fieldScore(query: "cr", text: "code review"), 0.5 * 2 / 6))
    }

    @Test func subsequencePicksTightestSpan() {
        // a(0)…b(3) 跨度 4；a(4)…b(6) 跨度 3，取更紧凑的
        #expect(close(Matcher.fieldScore(query: "ab", text: "axxbaxb"), 0.5 * 2 / 3))
    }

    @Test func caseInsensitiveAndTrimmed() {
        #expect(Matcher.fieldScore(query: "  Code ", text: "CODE review") == 0.9)
    }

    @Test func noMatch() {
        #expect(Matcher.fieldScore(query: "xyz", text: "code review") == 0)
        #expect(Matcher.fieldScore(query: "longer than text", text: "short") == 0)
    }
}

@Suite struct MatcherRankTests {

    private func p(_ id: String, title: String, keywords: [String] = [], tags: [String] = [], content: String = "-") -> Prompt {
        Prompt(id: id, title: title, keywords: keywords, tags: tags, content: content)
    }

    @Test func titleOutweighsContent() {
        let inTitle = p("t", title: "review")
        let inContent = p("c", title: "other", content: "review")
        #expect(Matcher.matchScore(query: "review", prompt: inTitle) == 1.0)
        #expect(Matcher.matchScore(query: "review", prompt: inContent) == 0.3)
    }

    @Test func matchScoreTakesBestField() {
        let prompt = p("a", title: "代码审查", keywords: ["cr", "review"], tags: ["dev"])
        #expect(Matcher.matchScore(query: "review", prompt: prompt) == 0.9)   // keyword 完全相等 1.0 × 0.9
        #expect(Matcher.matchScore(query: "dev", prompt: prompt) == 0.6)      // tag 完全相等 1.0 × 0.6
    }

    @Test func emptyQuerySortsByFrecencyThenTitle() {
        let prompts = [p("a", title: "Charlie"), p("b", title: "Alpha"), p("c", title: "Bravo")]
        let ranked = Matcher.rank(prompts: prompts, frecency: ["a": 2.0], query: "  ")
        #expect(ranked.map(\.prompt.id) == ["a", "b", "c"])
    }

    @Test func nonEmptyQueryFiltersNonMatching() {
        let prompts = [p("a", title: "code review"), p("b", title: "translate")]
        let ranked = Matcher.rank(prompts: prompts, frecency: [:], query: "review")
        #expect(ranked.map(\.prompt.id) == ["a"])
    }

    @Test func frecencyBreaksEqualMatches() {
        let prompts = [p("a", title: "review one"), p("b", title: "review two")]
        let ranked = Matcher.rank(prompts: prompts, frecency: ["b": 1.0], query: "review")
        #expect(ranked.map(\.prompt.id) == ["b", "a"])
        #expect(abs(ranked[0].score - (0.9 + 0.3)) < 1e-9)
        #expect(ranked[1].score == 0.9)
    }

    @Test func frecencyBonusIsNormalizedWithinResults() {
        // 最大 frecency 为 4，2 分的条目只拿一半加成
        let prompts = [p("a", title: "review a"), p("b", title: "review b")]
        let ranked = Matcher.rank(prompts: prompts, frecency: ["a": 4, "b": 2], query: "review")
        #expect(abs(ranked[1].score - (0.9 + 0.15)) < 1e-9)
    }

    @Test func frecencyCannotLiftContentMatchAboveTitlePrefix() {
        // 只在内容里命中（最高 0.3）+ 最大加成 0.3 = 0.6 < 标题前缀 0.9
        let prompts = [p("hot", title: "x", content: "review"), p("cold", title: "review it")]
        let ranked = Matcher.rank(prompts: prompts, frecency: ["hot": 100], query: "review")
        #expect(ranked.map(\.prompt.id) == ["cold", "hot"])
    }

    @Test func noFrecencyAvoidsDivisionByZero() {
        let ranked = Matcher.rank(prompts: [p("a", title: "review")], frecency: [:], query: "review")
        #expect(ranked.first?.score == 1.0)
    }

    @Test func tiesBrokenByTitleThenID() {
        let prompts = [p("z", title: "review"), p("y", title: "review")]
        let ranked = Matcher.rank(prompts: prompts, frecency: [:], query: "review")
        #expect(ranked.map(\.prompt.id) == ["y", "z"])
    }
}

@Suite struct MatcherSubsequenceEquivalenceTests {

    /// 暴力解：枚举所有起点与终点，找包含查询子序列的最短窗口。
    private func bruteForceSpan(_ q: [Character], _ t: [Character]) -> Int? {
        var best: Int?
        for s in t.indices {
            for e in s..<t.count {
                var qi = 0
                for c in t[s...e] where qi < q.count && c == q[qi] { qi += 1 }
                if qi == q.count {
                    let span = e - s + 1
                    if best == nil || span < best! { best = span }
                    break
                }
            }
        }
        return best
    }

    @Test func matchesBruteForceOnRandomInputs() {
        var rng = SystemRandomNumberGenerator()
        let alphabet: [Character] = ["a", "b", "c", "的"]
        for _ in 0..<2000 {
            let t = String((0..<Int.random(in: 1...14, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
            let q = String((0..<Int.random(in: 1...4, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
            let actual = Matcher.fieldScore(query: q, text: t)

            let expected: Double
            if t == q { expected = 1.0 }
            else if t.hasPrefix(q) { expected = 0.9 }
            else if t.contains(q) { expected = 0.75 }
            else if let span = bruteForceSpan(Array(q), Array(t)) { expected = 0.5 * Double(q.count) / Double(span) }
            else { expected = 0 }

            #expect(abs(actual - expected) < 1e-9, "q=\(q) t=\(t)")
        }
    }
}
