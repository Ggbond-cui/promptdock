import Foundation

/// 使用频率 + 最近使用时间的综合分。算法见 docs/spec.md 第 7.1 节：
///
///     frecency(p) = Σ 0.5 ^ (距今天数 / 半衰期)
///
/// 今天用一次记 1 分，一个半衰期前用的一次记 0.5 分。
public enum Frecency {
    public static let defaultHalfLifeDays: Double = 7

    /// 计算每个 prompt 的分数。没有使用记录的 prompt 不出现在结果中（视为 0 分）。
    public static func scores(
        events: [UsageEvent],
        now: Date,
        halfLifeDays: Double = defaultHalfLifeDays
    ) -> [String: Double] {
        var result: [String: Double] = [:]
        for event in events {
            let ageDays = max(0, now.timeIntervalSince(event.usedAt) / 86_400)
            result[event.promptID, default: 0] += pow(0.5, ageDays / halfLifeDays)
        }
        return result
    }
}
