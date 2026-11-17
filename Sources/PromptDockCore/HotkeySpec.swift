import Foundation

/// 快捷键配置，例如 "option+space"。keyCode 为 macOS 虚拟键码（ANSI 布局）。
public struct HotkeySpec: Sendable, Equatable {

    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var keyCode: UInt32
    public var modifiers: Modifiers
    public var keyName: String

    /// 按 macOS 惯例顺序显示：⌃⌥⇧⌘ + 键名。
    public var displayString: String { Self.symbols(modifiers) + keyName }

    /// 修饰键符号，按 ⌃⌥⇧⌘ 顺序；录制时实时显示已按住的修饰键。
    public static func symbols(_ modifiers: Modifiers) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s
    }

    public static func parse(_ text: String) throws(HotkeyParseError) -> HotkeySpec {
        let tokens = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw .empty }

        var modifiers: Modifiers = []
        var key: (code: UInt32, name: String)?
        for token in tokens {
            if let m = modifierAliases[token] {
                modifiers.insert(m)
            } else if let code = keyCodes[token] {
                guard key == nil else { throw .multipleKeys }
                key = (code, displayName(token))
            } else {
                throw .unknownToken(token)
            }
        }
        guard let key else { throw .missingKey }
        guard !modifiers.isEmpty else { throw .missingModifier }
        return HotkeySpec(keyCode: key.code, modifiers: modifiers, keyName: key.name)
    }

    /// 写回 YAML 的配置字符串，修饰键按 control、option、shift、command 顺序，例如 "option+shift+space"。
    public var configString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("control") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("command") }
        parts.append(Self.keyTokens[keyCode] ?? keyName.lowercased())
        return parts.joined(separator: "+")
    }

    /// 由设置窗口录到的按键生成快捷键；支持的按键与 parse 相同。
    public static func recorded(keyCode: UInt32, modifiers: Modifiers) throws(HotkeyParseError) -> HotkeySpec {
        guard let token = keyTokens[keyCode] else { throw .unsupportedKey }
        guard !modifiers.isEmpty else { throw .missingModifier }
        return HotkeySpec(keyCode: keyCode, modifiers: modifiers, keyName: displayName(token))
    }

    private static let keyTokens: [UInt32: String] = Dictionary(uniqueKeysWithValues: keyCodes.map { ($1, $0) })

    private static let modifierAliases: [String: Modifiers] = [
        "cmd": .command, "command": .command,
        "opt": .option, "option": .option, "alt": .option,
        "ctrl": .control, "control": .control,
        "shift": .shift,
    ]

    private static func displayName(_ token: String) -> String {
        switch token {
        case "space": "Space"
        case "return": "Return"
        case "tab": "Tab"
        case "escape": "Esc"
        default: token.uppercased()
        }
    }

    // kVK_* 常量（Carbon HIToolbox/Events.h）
    private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "space": 49, "return": 36, "tab": 48, "escape": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
}

public enum HotkeyParseError: Error, Equatable, CustomStringConvertible {
    case empty
    case unknownToken(String)
    case missingKey
    case multipleKeys
    case missingModifier
    case unsupportedKey

    public var description: String {
        switch self {
        case .empty: "快捷键为空"
        case .unknownToken(let t): "无法识别「\(t)」"
        case .missingKey: "缺少按键（只有修饰键）"
        case .multipleKeys: "只能有一个非修饰键"
        case .missingModifier: "至少需要一个修饰键（cmd/option/ctrl/shift）"
        case .unsupportedKey: "不支持该按键（可用字母、数字、F1–F12、Space、Return、Tab、Esc）"
        }
    }
}
