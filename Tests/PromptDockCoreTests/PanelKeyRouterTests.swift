import Testing
@testable import PromptDockCore

@Suite struct PanelKeyRouterTests {

    @Test func mapsNavigationAndActions() {
        #expect(PanelKeyRouter.command(keyCode: 126, commandKey: false, hasMarkedText: false) == .moveUp)
        #expect(PanelKeyRouter.command(keyCode: 125, commandKey: false, hasMarkedText: false) == .moveDown)
        #expect(PanelKeyRouter.command(keyCode: 36, commandKey: false, hasMarkedText: false) == .paste)
        #expect(PanelKeyRouter.command(keyCode: 76, commandKey: false, hasMarkedText: false) == .paste)
        #expect(PanelKeyRouter.command(keyCode: 36, commandKey: true, hasMarkedText: false) == .copy)
        #expect(PanelKeyRouter.command(keyCode: 53, commandKey: false, hasMarkedText: false) == .close)
    }

    @Test func ignoresOtherKeys() {
        #expect(PanelKeyRouter.command(keyCode: 0, commandKey: false, hasMarkedText: false) == nil)
    }

    @Test func passesThroughWhileInputMethodIsComposing() {
        // 中文输入法组字时，回车/方向键/Esc 交给输入法，不能触发粘贴
        for code: UInt16 in [36, 76, 125, 126, 53] {
            #expect(PanelKeyRouter.command(keyCode: code, commandKey: false, hasMarkedText: true) == nil)
        }
    }
}
