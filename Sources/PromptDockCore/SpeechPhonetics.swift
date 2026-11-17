import Foundation

/// 🔊 朗读音标（spec 9.4）：判断哪些文本值得查音标，并把模型返回整理成干净的 IPA。
public enum SpeechPhonetics {

    /// 只对短英文文本查音标：中文（要的是拼音，暂不做）与整段长文本不给音标。
    public static func shouldLookup(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return false }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace || ",，、;；.。!！?？".contains($0) })
        guard (1...4).contains(words.count) else { return false }
        return words.contains { $0.contains(where: \.isLetter) }
    }

    /// 从模型输出里取出第一段 `/.../` 音标；没有斜杠、内容过长或含中文都视为无效，返回 nil。
    public static func normalize(_ output: String) -> String? {
        guard let range = output.range(of: #"/[^/\n]{1,60}/"#, options: .regularExpression) else { return nil }
        let ipa = String(output[range])
        guard !ipa.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return nil }
        return ipa
    }
}
