public enum PanelCommand: Sendable, Equatable {
    case moveUp, moveDown, paste, copy, close, back
}

/// 面板内按键到命令的映射（spec 8.1）。
public enum PanelKeyRouter {
    /// - Parameter hasMarkedText: 输入法是否正在组字。组字时所有按键交给输入法处理。
    public static func command(keyCode: UInt16, commandKey: Bool, hasMarkedText: Bool) -> PanelCommand? {
        guard !hasMarkedText else { return nil }
        switch keyCode {
        case 126: return .moveUp
        case 125: return .moveDown
        case 36, 76: return commandKey ? .copy : .paste   // Return / 小键盘 Enter
        case 53: return .close
        case 123: return .back                             // ←：动作结果页返回列表，其余场景放行
        default: return nil
        }
    }
}
