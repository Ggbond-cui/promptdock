import AVFoundation

/// 系统语音合成（spec 8.1）：朗读选中原文与模型输出。
/// 中英按文本主体语言自动选择声音，取该语言下音质最高的系统声音。
@MainActor
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {

    private let synthesizer = AVSpeechSynthesizer()
    private(set) var isSpeaking = false
    /// 朗读状态变化（开始/结束/取消）通知面板切换按钮形态（主线程回调）。
    var onStateChanged: (@MainActor (Bool) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// 正在朗读则停止，否则朗读文本（两个 🔊 按钮共用）。
    func toggle(_ text: String) {
        isSpeaking ? stop() : speak(text)
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.voice(for: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        setState(true)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        setState(false)
    }

    private func setState(_ speaking: Bool) {
        guard speaking != isSpeaking else { return }
        isSpeaking = speaking
        onStateChanged?(speaking)
    }

    /// 含 CJK 字符视为中文文本，否则英文；同语言里选音质最高的声音。
    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let hasCJK = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let language = hasCJK ? "zh-CN" : "en-US"
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
        return candidates.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: language)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    // delegate 回调线程没有文档保证，不能 assumeIsolated（非主线程会直接崩溃）
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in setState(false) }
    }
}
