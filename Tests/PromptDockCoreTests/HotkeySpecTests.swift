import Testing
@testable import PromptDockCore

@Suite struct HotkeySpecTests {

    @Test func parsesDefaultHotkeys() throws {
        let a = try HotkeySpec.parse("option+space")
        #expect(a.keyCode == 49)
        #expect(a.modifiers == [.option])

        let b = try HotkeySpec.parse("option+shift+space")
        #expect(b.keyCode == 49)
        #expect(b.modifiers == [.option, .shift])
    }

    @Test func acceptsAliasesCaseAndSpaces() throws {
        let spec = try HotkeySpec.parse(" Cmd + Ctrl + Alt + K ")
        #expect(spec.keyCode == 40)
        #expect(spec.modifiers == [.command, .control, .option])
    }

    @Test(arguments: [("a", UInt32(0)), ("z", 6), ("0", 29), ("9", 25), ("f1", 122), ("f12", 111), ("return", 36), ("tab", 48)])
    func mapsKeys(key: String, code: UInt32) throws {
        #expect(try HotkeySpec.parse("command+\(key)").keyCode == code)
    }

    @Test func displayStringUsesMacSymbolsInStandardOrder() throws {
        #expect(try HotkeySpec.parse("shift+option+space").displayString == "⌥⇧Space")
        #expect(try HotkeySpec.parse("cmd+ctrl+k").displayString == "⌃⌘K")
    }

    @Test func rejectsInvalidSpecs() {
        #expect(throws: HotkeyParseError.empty) { try HotkeySpec.parse("  ") }
        #expect(throws: HotkeyParseError.missingModifier) { try HotkeySpec.parse("space") }
        #expect(throws: HotkeyParseError.missingKey) { try HotkeySpec.parse("option+shift") }
        #expect(throws: HotkeyParseError.multipleKeys) { try HotkeySpec.parse("option+a+b") }
        #expect(throws: HotkeyParseError.unknownToken("hyper")) { try HotkeySpec.parse("hyper+a") }
    }
}
