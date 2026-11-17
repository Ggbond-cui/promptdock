import Foundation
import Testing
@testable import PromptDockCore

@Suite struct FrecencyTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
    private func event(_ id: String, _ daysAgo: Double) -> UsageEvent {
        UsageEvent(promptID: id, usedAt: ago(daysAgo), kind: .paste)
    }

    @Test func defaultHalfLifeIsSevenDays() {
        #expect(Frecency.defaultHalfLifeDays == 7)
    }

    @Test(arguments: [(0.0, 1.0), (7.0, 0.5), (14.0, 0.25), (3.5, 0.7071067811865476)])
    func singleEventDecaysByHalfLife(daysAgo: Double, expected: Double) {
        let scores = Frecency.scores(events: [event("a", daysAgo)], now: now)
        #expect(abs((scores["a"] ?? -1) - expected) < 1e-9)
    }

    @Test func sumsEventsPerPrompt() {
        let scores = Frecency.scores(
            events: [event("a", 0), event("a", 7), event("b", 14)],
            now: now
        )
        #expect(abs(scores["a"]! - 1.5) < 1e-9)
        #expect(abs(scores["b"]! - 0.25) < 1e-9)
    }

    @Test func futureEventsAreClampedToNow() {
        // 时钟回拨等情况下，事件时间可能晚于当前时间，按 0 天计，不允许超过 1 分
        let scores = Frecency.scores(events: [event("a", -3)], now: now)
        #expect(scores["a"] == 1.0)
    }

    @Test func emptyEventsYieldEmptyScores() {
        #expect(Frecency.scores(events: [], now: now).isEmpty)
    }

    @Test func customHalfLife() {
        let scores = Frecency.scores(events: [event("a", 1)], now: now, halfLifeDays: 1)
        #expect(abs(scores["a"]! - 0.5) < 1e-9)
    }

    @Test func recentSingleUseBeatsOldRepeatedUse() {
        // 今天用 1 次（1.0）> 14 天前用 3 次（0.75）
        let scores = Frecency.scores(
            events: [event("recent", 0), event("old", 14), event("old", 14), event("old", 14)],
            now: now
        )
        #expect(scores["recent"]! > scores["old"]!)
    }
}
