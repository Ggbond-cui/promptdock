import Testing
@testable import PromptDockCore

struct SpeechPhoneticsTests {

    // MARK: - shouldLookup

    @Test func singleEnglishWordLooksUp() {
        #expect(SpeechPhonetics.shouldLookup("hallucination"))
    }

    @Test func acronymLooksUp() {
        #expect(SpeechPhonetics.shouldLookup("RAG"))
    }

    @Test func shortPhraseLooksUp() {
        #expect(SpeechPhonetics.shouldLookup("retrieval augmented generation"))
    }

    @Test func hyphenatedCountsAsOneWord() {
        #expect(SpeechPhonetics.shouldLookup("state-of-the-art"))
    }

    @Test func fourWordsIsTheLimit() {
        #expect(SpeechPhonetics.shouldLookup("a b c d"))
        #expect(!SpeechPhonetics.shouldLookup("a b c d e"))
    }

    @Test func longTextSkipped() {
        #expect(!SpeechPhonetics.shouldLookup("The quick brown fox jumps over the lazy dog"))
    }

    @Test func chineseSkipped() {
        #expect(!SpeechPhonetics.shouldLookup("检索增强生成"))
    }

    @Test func mixedWithChineseSkipped() {
        #expect(!SpeechPhonetics.shouldLookup("RAG 检索增强"))
    }

    @Test func emptyAndWhitespaceSkipped() {
        #expect(!SpeechPhonetics.shouldLookup(""))
        #expect(!SpeechPhonetics.shouldLookup("   \n "))
    }

    @Test func pureNumberSkipped() {
        #expect(!SpeechPhonetics.shouldLookup("42"))
    }

    @Test func wordWithDigitsLooksUp() {
        #expect(SpeechPhonetics.shouldLookup("GPT-4o"))
    }

    // MARK: - normalize

    @Test func plainIPAKept() {
        #expect(SpeechPhonetics.normalize("/ræɡ/") == "/ræɡ/")
    }

    @Test func prefixProseStripped() {
        #expect(SpeechPhonetics.normalize("音标：/ˌdʒiː piː ˈjuː/\n") == "/ˌdʒiː piː ˈjuː/")
    }

    @Test func firstOfMultiplePairsTaken() {
        #expect(SpeechPhonetics.normalize("/ræɡ/ /rɑːɡ/") == "/ræɡ/")
    }

    @Test func markdownWrapperStripped() {
        #expect(SpeechPhonetics.normalize("*/ˈtɒkənaɪzə/*") == "/ˈtɒkənaɪzə/")
    }

    @Test func noSlashesReturnsNil() {
        #expect(SpeechPhonetics.normalize("ræɡ") == nil)
    }

    @Test func chineseInsideSlashesReturnsNil() {
        #expect(SpeechPhonetics.normalize("/中文/") == nil)
    }

    @Test func overlongRunReturnsNil() {
        #expect(SpeechPhonetics.normalize("/" + String(repeating: "æ", count: 61) + "/") == nil)
    }
}
