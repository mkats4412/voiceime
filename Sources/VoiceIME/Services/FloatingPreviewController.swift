import AppKit
import SwiftUI
import Carbon

public enum FloatingPreviewPhase: Equatable {
    case liveRecording // 録音・リアルタイム音声認識中
    case processing    // クラウドWhisper/AI推敲中
    case ready         // 完了・保留中 (⌘+Enterで挿入可能)
}

@MainActor
public final class FloatingPreviewController: ObservableObject {
    public static let shared = FloatingPreviewController()

    @Published public var phase: FloatingPreviewPhase = .ready
    @Published public var currentText: String = ""
    @Published public var isVisible: Bool = false
    @Published public var copySuccess: Bool = false

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var copyResetTimer: Timer?

    // Carbon ホットキー (⌘+Return) 関連
    private let signature = OSType(0x56505354) // 'VPST'
    private let hotKeyIDValue: UInt32 = 2
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var localKeyMonitor: Any?

    private init() {
        installCarbonEventHandler()
        setupLocalKeyMonitor()
    }

    deinit {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let eventHandlerRef = eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// 録音開始時のリアルタイムプレビュー表示
    public func showLiveRecording() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        unregisterCmdEnterHotkey()

        self.phase = .liveRecording
        self.currentText = ""
        self.copySuccess = false

        if panel == nil {
            setupPanel()
        }

        updatePanelPosition()

        if !isVisible {
            panel?.alphaValue = 0.0
            panel?.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel?.animator().alphaValue = 1.0
            }
            self.isVisible = true
        } else {
            panel?.alphaValue = 1.0
            panel?.orderFrontRegardless()
        }
    }

    /// リアルタイム音声認識テキストの逐次更新
    public func updateLiveText(_ text: String) {
        guard phase == .liveRecording else { return }
        self.currentText = text
    }

    /// 録音停止・AI推敲中へのステータス変更
    public func setProcessing() {
        self.phase = .processing
    }

    /// 認識・推敲完了後の確定テキスト表示
    public func show(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hide()
            return
        }

        self.phase = .ready
        self.currentText = text
        self.copySuccess = false

        if panel == nil {
            setupPanel()
        }

        updatePanelPosition()

        if !isVisible {
            panel?.alphaValue = 0.0
            panel?.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel?.animator().alphaValue = 1.0
            }
            self.isVisible = true
        }

        // ⌘+Enter グローバルホットキーを有効化
        registerCmdEnterHotkey()

        // 自動非表示タイマーの開始（設定が0より大きい場合）
        resetDismissTimer()
        NSLog("[VoiceIME] 💬 フローティングプレビュー確定表示: [%@]", text)
    }

    /// フローティングプレビューを非表示
    public func hide() {
        guard isVisible, let panel = panel else { return }

        dismissTimer?.invalidate()
        dismissTimer = nil
        unregisterCmdEnterHotkey()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.panel?.orderOut(nil)
                self.isVisible = false
                self.phase = .ready
            }
        })
    }

    /// テキストをクリップボードにコピー
    public func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(currentText, forType: .string)

        copySuccess = true
        copyResetTimer?.invalidate()
        copyResetTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.copySuccess = false
            }
        }
        NSLog("[VoiceIME] 📋 テキストをクリップボードにコピーしました")
    }

    /// 最前面のアクティブアプリケーションへテキストを挿入（ペースト）
    public func insertTextToFrontmostApp() {
        guard phase == .ready else { return }
        let textToInsert = currentText
        guard !textToInsert.isEmpty else {
            hide()
            return
        }

        NSLog("[VoiceIME] ⚡️ フローティングプレビューから挿入実行: [%@]", textToInsert)
        hide()

        // パネルが退いて前のアクティブ入力欄へフォーカスが確実に通るよう微小遅延を入れてペースト
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            TextPasterService.shared.paste(
                text: textToInsert,
                restoreClipboard: AppSettings.shared.restoreClipboard
            )
        }
    }

    // MARK: - Panel Setup & Layout

    private func setupPanel() {
        let hostingView = NSHostingView(rootView: FloatingPreviewView(controller: self))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 180),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = hostingView

        self.panel = panel
    }

    private func updatePanelPosition() {
        guard let panel = panel else { return }

        // マウスカーソルがあるスクリーン、またはメインスクリーンを基準にする
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first

        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let contentSize = panel.contentView?.fittingSize ?? NSSize(width: 440, height: 180)
        let panelWidth = contentSize.width > 100 ? contentSize.width : 440.0
        let panelHeight = contentSize.height > 50 ? contentSize.height : 180.0

        // 画面中央下部（ドックや下端から 64px 上）
        let posX = screenFrame.midX - (panelWidth / 2.0)
        let posY = screenFrame.minY + 64.0

        panel.setFrame(NSRect(x: posX, y: posY, width: panelWidth, height: panelHeight), display: true)
    }

    private func resetDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = nil

        let duration = AppSettings.shared.floatingPreviewDuration
        guard duration > 0 else { return }

        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hide()
            }
        }
    }

    // MARK: - Carbon HotKey & Keyboard Handling

    private func installCarbonEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, _) -> OSStatus in
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
                if status == noErr && hotKeyID.signature == OSType(0x56505354) && hotKeyID.id == 2 {
                    DispatchQueue.main.async {
                        FloatingPreviewController.shared.insertTextToFrontmostApp()
                    }
                    return noErr
                }
                return OSStatus(eventNotHandledErr)
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
    }

    private func registerCmdEnterHotkey() {
        unregisterCmdEnterHotkey()
        let hotKeyID = EventHotKeyID(signature: signature, id: hotKeyIDValue)
        // ⌘ + Return (keyCode: kVK_Return = 36, modifiers: cmdKey)
        let status = RegisterEventHotKey(
            UInt32(kVK_Return),
            UInt32(cmdKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            NSLog("[VoiceIME] ⚠️ ⌘+Return ホットキー登録失敗: %d", status)
        }
    }

    private func unregisterCmdEnterHotkey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func setupLocalKeyMonitor() {
        // パネルにフォーカスがある場合の Esc / ⌘+Return キーハンドリング
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return event }

            // Esc キー (keyCode 53) で閉じる
            if event.keyCode == 53 {
                self.hide()
                return nil
            }

            // ⌘ + Return キー (keyCode 36) で挿入
            if event.keyCode == 36 && event.modifierFlags.contains(.command) {
                self.insertTextToFrontmostApp()
                return nil
            }

            return event
        }
    }
}
