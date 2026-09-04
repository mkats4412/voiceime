import AppKit
import Carbon

public final class HotkeyManager {
    public static let shared = HotkeyManager()

    private let signature = OSType(0x56494D45) // 'VIME'
    private let hotKeyIDValue: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private var onKeyDown: (() -> Void)?
    private var onKeyUp: (() -> Void)?

    private init() {
        installCarbonEventHandler()
    }

    deinit {
        unregister()
        if let eventHandlerRef = eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    /// ホットキーを登録（KeyDownとKeyUpの両方を検知）
    @discardableResult
    public func register(
        keyCode: UInt32,
        modifiers: UInt32,
        onKeyDown: @escaping () -> Void,
        onKeyUp: (() -> Void)? = nil
    ) -> Bool {
        unregister()

        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp

        let carbonModifiers = convertToCarbonModifiers(modifiers: modifiers)
        var newRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: hotKeyIDValue)

        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &newRef
        )

        if status == noErr {
            self.hotKeyRef = newRef
            return true
        } else {
            self.onKeyDown = nil
            self.onKeyUp = nil
            return false
        }
    }

    /// ホットキーの解除
    public func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        onKeyDown = nil
        onKeyUp = nil
    }

    // MARK: - Private Helpers

    private func installCarbonEventHandler() {
        var eventTypes: [EventTypeSpec] = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        // singleton であるため userData に unsafe pointer を渡さず shared 経由で処理。
        // 従来の Unmanaged.passUnretained 方式だと HotkeyManager が解放後に
        // Carbon側からコールバックされた際に dangling pointer でクラッシュするため。
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

        if status == noErr && hotKeyID.signature == self.signature && hotKeyID.id == hotKeyIDValue {
            let eventKind = GetEventKind(event)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if eventKind == UInt32(kEventHotKeyPressed) {
                    self.onKeyDown?()
                } else if eventKind == UInt32(kEventHotKeyReleased) {
                    self.onKeyUp?()
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
