import AppKit

/// 剪贴板完整快照：保存所有条目的所有类型，用于粘贴后恢复用户原来的剪贴板。
public struct PasteboardSnapshot: Sendable {
    private let items: [[(type: String, data: Data)]]

    public var isEmpty: Bool { items.isEmpty }

    @MainActor
    public static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } }
        }
        return PasteboardSnapshot(items: items)
    }

    @MainActor
    public func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entries in
            let item = NSPasteboardItem()
            for entry in entries { item.setData(entry.data, forType: .init(entry.type)) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
