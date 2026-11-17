import AppKit

/// 菜单栏 App（LSUIElement）默认没有主菜单，输入框里的 ⌘V / ⌘C / ⌘A 等快捷键
/// 是由「编辑」菜单项的 keyEquivalent 分发到第一响应者的，缺了它这些快捷键全部失效。
/// 这里装一个不可见的主菜单，只为让 API Key 输入框、面板搜索框支持标准编辑快捷键。
enum MainMenu {
    @MainActor
    static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        // 不绑定 ⌘Q：面板打开时误按会直接退出 App；退出请用菜单栏图标里的「退出」
        appMenu.addItem(withTitle: "退出 PromptDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
