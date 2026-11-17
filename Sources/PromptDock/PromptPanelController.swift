import AppKit
import PromptDockCore
import SwiftUI

/// 不抢占前台应用激活状态、但能接收键盘输入的浮动面板（spec 8.2 第 2 步）。
final class FloatingPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { standardWindowButton($0)?.isHidden = true }
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class PromptPanelController: NSObject, NSWindowDelegate {
    let model = PanelModel()
    /// 回车 / ⌘回车：由调用方根据当前模式与阶段决定行为。
    var onCommand: (PanelCommand) -> Void = { _ in }
    /// 面板关闭（Esc、点击外部、被隐藏）时调用，用于取消进行中的请求。
    var onClose: () -> Void = {}

    private let panel = FloatingPanel()
    private var keyMonitor: Any?

    var isVisible: Bool { panel.isVisible }

    override init() {
        super.init()
        panel.delegate = self
        let host = NSHostingView(rootView: PromptPanelView(model: model) { [weak self] command in
            self?.handle(command)
        })
        // 透明标题栏区域默认算作安全区，内容会让出这一条，露出白色窗口底色；让内容铺满整个窗口
        host.safeAreaRegions = []
        panel.contentView = host
    }

    func show(mode: PanelMode, prompts: [Prompt], frecency: [String: Double], notice: String?) {
        model.prepare(mode: mode, prompts: prompts, frecency: frecency, notice: notice)
        position()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        removeKeyMonitor()
        onClose()
    }

    func update(prompts: [Prompt]) {
        model.update(prompts: prompts)
    }

    // 失去焦点（点到别处）时关闭
    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { hide() }
    }

    private func handle(_ command: PanelCommand) {
        switch command {
        case .moveUp: if model.phase == .choosing { model.move(-1) }
        case .moveDown: if model.phase == .choosing { model.move(1) }
        case .close: hide()
        case .paste, .copy: onCommand(command)
        }
    }

    /// 在鼠标所在屏幕水平居中、偏上显示。
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + frame.height * 0.72 - size.height / 2
        ))
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let composing = (self.panel.firstResponder as? NSTextView)?.hasMarkedText() ?? false
            guard let command = PanelKeyRouter.command(
                keyCode: event.keyCode,
                commandKey: event.modifierFlags.contains(.command),
                hasMarkedText: composing
            ) else { return event }
            self.handle(command)
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
