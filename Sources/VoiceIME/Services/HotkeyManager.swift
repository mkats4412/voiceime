import AppKit
import Carbon

public enum HotkeyType: UInt32, CaseIterable {
    case speechInput = 1
    case quickAsk = 2
}

public final class HotkeyManager {
    public static let shared = HotkeyManager()

    private let signature = OSType(0x56494D45) // 'VIME'

    private var hotKeyRefs: [HotkeyType: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?

    private var onKeyDownHandlers: [HotkeyType: () -> Void] = [:]
    private var onKeyUpHandlers: [HotkeyType: () -> Void] = [:]

    private init() {
        installCarbonEventHandler()
    }

    deinit {
        unregisterAll()
        if let eventHandlerRef = eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    /// 指定タイプのホットキーを登録（KeyDownとKeyUpの両方を検知）
    @discardableResult
    public func register(
        type: HotkeyType = .speechInput,
        keyCode: UInt32,
        modifiers: UInt32,
        onKeyDown: @escaping () -> Void,
        onKeyUp: (() -> Void)? = nil
    ) -> Bool {
        unregister(type: type)

        self.onKeyDownHandlers[type] = onKeyDown
        self.onKeyUpHandlers[type] = onKeyUp

        let carbonModifiers = convertToCarbonModifiers(modifiers: modifiers)
        var newRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: type.rawValue)

        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &newRef
        )

        if status == noErr, let ref = newRef {
            self.hotKeyRefs[type] = ref
            NSLog("[VoiceIME] ✅ ホットキー登録成功 (type: %@, keyCode: %d, modifiers: %d)", String(describing: type), keyCode, modifiers)
            return true
        } else {
            self.onKeyDownHandlers.removeValue(forKey: type)
            self.onKeyUpHandlers.removeValue(forKey: type)
            NSLog("[VoiceIME] ❌ ホットキー登録失敗 (type: %@, OSStatus: %d, keyCode: %d)", String(describing: type), status, keyCode)
            return false
        }
    }

    /// 指定タイプのホットキーの解除
    public func unregister(type: HotkeyType) {
        if let ref = hotKeyRefs[type] {
            UnregisterEventHotKey(ref)
            hotKeyRefs.removeValue(forKey: type)
        }
        onKeyDownHandlers.removeValue(forKey: type)
        onKeyUpHandlers.removeValue(forKey: type)
    }

    /// すべてのホットキーを解除
    public func unregisterAll() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        onKeyDownHandlers.removeAll()
        onKeyUpHandlers.removeAll()
    }

    /// 後方互換用: 音声入力ホットキーの解除
    public func unregister() {
        unregister(type: .speechInput)
    }

    // MARK: - Private Helpers

    private func installCarbonEventHandler() {
        var eventTypes: [EventTypeSpec] = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let callback: EventHandlerUPP = { _, event, _ -> OSStatus in
            HotkeyManager.shared.handleHotKeyEvent(event)
            return noErr
        }

        InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            eventTypes.count,
            &eventTypes,
            nil,
            &eventHandlerRef
        )
    }

    private func handleHotKeyEvent(_ event: EventRef?) {
        guard let event = event else { return }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        if status == noErr && hotKeyID.signature == self.signature {
            if let type = HotkeyType(rawValue: hotKeyID.id) {
                let eventKind = GetEventKind(event)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if eventKind == UInt32(kEventHotKeyPressed) {
                        self.onKeyDownHandlers[type]?()
                    } else if eventKind == UInt32(kEventHotKeyReleased) {
                        self.onKeyUpHandlers[type]?()
                    }
                }
            }
        }
    }

    private func convertToCarbonModifiers(modifiers: UInt32) -> UInt32 {
        var carbonMods: UInt32 = 0
        if modifiers & UInt32(cmdKey) != 0 { carbonMods |= UInt32(cmdKey) }
        if modifiers & UInt32(shiftKey) != 0 { carbonMods |= UInt32(shiftKey) }
        if modifiers & UInt32(optionKey) != 0 { carbonMods |= UInt32(optionKey) }
        if modifiers & UInt32(controlKey) != 0 { carbonMods |= UInt32(controlKey) }
        return carbonMods
    }
}
