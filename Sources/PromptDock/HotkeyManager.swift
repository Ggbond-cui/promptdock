import Carbon.HIToolbox
import PromptDockCore

/// 基于 Carbon RegisterEventHotKey 的全局快捷键（系统自带，无需辅助功能权限）。
@MainActor
final class HotkeyManager {
    private static let signature: OSType = 0x5044_636B   // "PDck"

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?

    /// 注册快捷键；返回 nil 表示成功，否则为失败原因。
    func register(id: UInt32, spec: HotkeySpec, action: @escaping () -> Void) -> String? {
        installHandlerIfNeeded()
        unregister(id: id)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            spec.keyCode, Self.carbonModifiers(spec.modifiers),
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            return status == eventHotKeyExistsErr
                ? "\(spec.displayString) 已被其他应用占用"
                : "\(spec.displayString) 注册失败（OSStatus \(status)）"
        }
        refs[id] = ref
        actions[id] = action
        return nil
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
    }

    fileprivate func fire(id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            let address = UInt(bitPattern: userData)
            // Carbon 事件在主线程分发
            MainActor.assumeIsolated {
                let manager = Unmanaged<HotkeyManager>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue()
                manager.fire(id: id)
            }
            return noErr
        }, 1, &eventType, userData, &handlerRef)
    }

    private static func carbonModifiers(_ m: HotkeySpec.Modifiers) -> UInt32 {
        var result: UInt32 = 0
        if m.contains(.command) { result |= UInt32(cmdKey) }
        if m.contains(.option) { result |= UInt32(optionKey) }
        if m.contains(.control) { result |= UInt32(controlKey) }
        if m.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
