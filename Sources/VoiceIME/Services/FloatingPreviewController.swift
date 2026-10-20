import AppKit
import SwiftUI
import Carbon

public enum FloatingPreviewPhase: Equatable {
    case liveRecording // 録音・リアルタイム音声認識中
    case processing    // クラウドWhisper/AI推敲中
    case ready         // 完了・保留中 (ペースト可能)
}

public enum FloatingPreviewMode: Equatable {
    case speechInput   // 通常の音声入力
    case quickAsk      // AIクイック質問
}

@MainActor
public final class FloatingPreviewController: ObservableObject {
    public static let shared = FloatingPreviewController()

    @Published public var phase: FloatingPreviewPhase = .ready
    @Published public var mode: FloatingPreviewMode = .speechInput
    @Published public var currentText: String = ""
    @Published public var isVisible: Bool = false
    @Published public var copySuccess: Bool = false
    @Published public var customNotice: String? = nil
    private var hasPipelineText: Bool = false

    private struct PasteboardBackupItem {
        let types: [NSPasteboard.PasteboardType]
        let dataMap: [NSPasteboard.PasteboardType: Data]
    }

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var copyResetTimer: Timer?
    private var clipboardExpiryTimer: Timer?
    private var temporaryClipboardBackup: [PasteboardBackupItem]? = nil
    private var temporaryChangeCount: Int = -1

    // Carbon ホットキー (⌘+Return & Esc) 関連
    private let signature = OSType(0x56505354) // 'VPST'
    private let hotKeyIDValue: UInt32 = 2
    private let hotKeyIDEscValue: UInt32 = 3
    private var hotKeyRef: EventHotKeyRef?
    private var escHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    private init() {
        installCarbonEventHandler()
        setupKeyMonitors()
    }

    deinit {
        dismissTimer?.invalidate()
        copyResetTimer?.invalidate()
        clipboardExpiryTimer?.invalidate()
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let ref = escHotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let eventHandlerRef = eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// 録音開始時のリアルタイムプレビュー表示
    public func showLiveRecording(mode: FloatingPreviewMode = .speechInput) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        registerHotkeys()

        self.mode = mode
        self.phase = .liveRecording
        self.currentText = ""
        self.copySuccess = false
        self.hasPipelineText = false

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

    /// リアルタイム音声認識テキストの逐次更新（Appleローカル音声認識等）
    public func updateLiveText(_ text: String) {
        guard phase == .liveRecording else { return }
        self.currentText = text
    }

    /// 累積紙芝居ストリーミングパイプラインからのリアルタイム＆処理中テキスト更新（Whisper API からの速報・確定テキスト）
    public func updatePipelineText(_ text: String) {
        guard phase == .liveRecording || phase == .processing else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.currentText = text
    }

    /// 確定テキストの同期・更新（推敲・辞書適用後の最終確定成果物を即座に反映）
    public func updateConfirmedText(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        self.currentText = text
        self.phase = .ready
        self.copySuccess = false

        if isVisible {
            updatePanelPosition()
            registerHotkeys()
        }
        NSLog("[VoiceIME] 💬 フローティングプレビュー確定テキスト同期: %d文字", text.count)
    }

    /// 録音停止・AI推敲中へのステータス変更
    public func setProcessing(mode: FloatingPreviewMode? = nil) {
        if let mode = mode {
            self.mode = mode
        }
        self.phase = .processing
    }

    /// 認識・推敲完了後の確定テキスト表示
    public func show(text: String, notice: String? = nil, mode: FloatingPreviewMode? = nil) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hide()
            return
        }

        if let mode = mode {
            self.mode = mode
        }
        self.phase = .ready
        self.currentText = text
        self.copySuccess = false
        self.customNotice = notice

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

        // ⌘+Enter および Esc グローバルホットキーを有効化
        registerHotkeys()

        // 自動非表示タイマーの開始（設定が0より大きい場合）
        resetDismissTimer()
        NSLog("[VoiceIME] 💬 フローティングプレビュー確定表示: [%@]", text)
    }

    /// 一時的にクリップボードにセット（最大45秒間保持、時間経過またはウィンドウ消去時に元のクリップボードへ復元・消去）
    public func setTemporaryClipboard(text: String, duration: TimeInterval = 45.0) {
        let pasteboard = NSPasteboard.general
        clipboardExpiryTimer?.invalidate()
        clipboardExpiryTimer = nil

        // 前回の時限クリップボード有効期間中に連続で呼ばれた場合は、最初に退避した本来のクリップボード内容を上書きしない
        if temporaryChangeCount <= 0 || pasteboard.changeCount != temporaryChangeCount {
            self.temporaryClipboardBackup = backupPasteboard(pasteboard)
        }

        // クリップボードにセット（外部履歴ツールへの永続記録を防止するマーカー付き）
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)

        let markerData = Data()
        item.setData(markerData, forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(markerData, forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setData(markerData, forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))

        pasteboard.writeObjects([item])
        self.temporaryChangeCount = pasteboard.changeCount

        // 45秒後に自動消去・復元するタイマー
        let expiryDuration = duration > 0 ? duration : 45.0
        clipboardExpiryTimer = Timer.scheduledTimer(withTimeInterval: expiryDuration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.clearTemporaryClipboard()
            }
        }
        NSLog("[VoiceIME] 🔒 セキュリティ時限クリップボードにセット (%.0f秒後に自動消去)", expiryDuration)
    }

    /// 一時クリップボードを消去し、元のクリップボード内容を安全に復元
    public func clearTemporaryClipboard() {
        clipboardExpiryTimer?.invalidate()
        clipboardExpiryTimer = nil

        let pasteboard = NSPasteboard.general
        // ユーザーがその後別の内容を手動コピーしていなければ復元
        if temporaryChangeCount > 0 && pasteboard.changeCount == temporaryChangeCount {
            if let backup = temporaryClipboardBackup, !backup.isEmpty {
                restorePasteboard(pasteboard, from: backup)
                NSLog("[VoiceIME] 🔒 セキュリティ保護: 45秒経過またはウィンドウ消去のため元のクリップボードを復元しました")
            } else {
                pasteboard.clearContents()
                NSLog("[VoiceIME] 🔒 セキュリティ保護: 45秒経過またはウィンドウ消去のため一時クリップボードを消去しました")
            }
        }
        temporaryClipboardBackup = nil
        temporaryChangeCount = -1
    }

    private func backupPasteboard(_ pasteboard: NSPasteboard) -> [PasteboardBackupItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.compactMap { item in
            var dataMap: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataMap[type] = data
                }
            }
            return PasteboardBackupItem(types: item.types, dataMap: dataMap)
        }
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, from backup: [PasteboardBackupItem]) {
        guard !backup.isEmpty else { return }
        pasteboard.clearContents()
        var newItems: [NSPasteboardItem] = []
        for backupItem in backup {
            let item = NSPasteboardItem()
            for (type, data) in backupItem.dataMap {
                item.setData(data, forType: type)
            }
            newItems.append(item)
        }
        pasteboard.writeObjects(newItems)
    }

    /// Esc キーなどによるキャンセル（ウィンドウを即座に非表示にし、クリップボードの中身も完全に消去・復元）
    public func cancel() {
        guard isVisible else { return }
        NSLog("[VoiceIME] 🛑 Esc キーによるキャンセル実行: ウィンドウを閉じクリップボードを完全に消去")

        // 1. 一時クリップボードを消去し、元のクリップボードへ復元
        clearTemporaryClipboard()

        // 2. 万が一手動コピーや他経路で現在のプレビューテキストがクリップボードに残っていれば完全にクリア
        let pasteboard = NSPasteboard.general
        if let rawClip = pasteboard.string(forType: .string) {
            let clipString = rawClip.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedCurrent = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedRecent = AppState.shared.lastProcessedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clipString.isEmpty && (clipString == trimmedCurrent || (!trimmedRecent.isEmpty && clipString == trimmedRecent)) {
                pasteboard.clearContents()
                NSLog("[VoiceIME] 🔒 クリップボードから音声入力テキストを消去しました")
            }
        }

        // 3. 録音中の場合は録音も中止
        if phase == .liveRecording {
            AppState.shared.cancelRecording()
        }

        hide()
    }

    /// フローティングプレビューを非表示
    public func hide() {
        clearTemporaryClipboard()
        unregisterHotkeys()
        guard isVisible, let panel = panel else { return }

        dismissTimer?.invalidate()
        dismissTimer = nil
        copyResetTimer?.invalidate()
        copyResetTimer = nil

        // アニメーション完了を待たずに状態フラグを先行して落とし、再表示とのレースコンディションを防ぐ
        self.isVisible = false
        self.phase = .ready

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // アニメーション中に再表示（isVisible == true）されていない場合のみ非表示化を確定
                if !self.isVisible {
                    self.panel?.orderOut(nil)
                }
            }
        })
    }

    /// テキストをクリップボードにコピー（ユーザーによる明示的な手動コピー）
    public func copyToClipboard() {
        clipboardExpiryTimer?.invalidate()
        clipboardExpiryTimer = nil
        temporaryClipboardBackup = nil
        temporaryChangeCount = -1

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
        NSLog("[VoiceIME] 📋 テキストを手動でクリップボードにコピーしました")
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
                if status == noErr && hotKeyID.signature == OSType(0x56505354) {
                    if hotKeyID.id == 2 {
                        DispatchQueue.main.async {
                            FloatingPreviewController.shared.insertTextToFrontmostApp()
                        }
                        return noErr
                    } else if hotKeyID.id == 3 {
                        DispatchQueue.main.async {
                            FloatingPreviewController.shared.cancel()
                        }
                        return noErr
                    }
                }
                return OSStatus(eventNotHandledErr)
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
    }

    /// ペーストキー変更時にホットキーを再登録
    public func reloadHotkeys() {
        if isVisible {
            registerHotkeys()
        }
    }

    private func registerHotkeys() {
        unregisterHotkeys()

        // 1. ユーザー設定のペースト（挿入）ホットキー
        let pasteCode = AppSettings.shared.pasteShortcutKeyCode
        let pasteMods = AppSettings.shared.pasteShortcutModifiers
        let carbonMods = convertToCarbonModifiers(modifiers: pasteMods)

        let enterHotKeyID = EventHotKeyID(signature: signature, id: hotKeyIDValue)
        let statusEnter = RegisterEventHotKey(
            pasteCode,
            carbonMods,
            enterHotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        if statusEnter != noErr {
            NSLog("[VoiceIME] ⚠️ ペーストホットキー登録失敗 (code: %d, mods: %d): %d", pasteCode, pasteMods, statusEnter)
        }

        // 2. Escape (keyCode: kVK_Escape = 53, modifiers: 0)
        let escHotKeyID = EventHotKeyID(signature: signature, id: hotKeyIDEscValue)
        let statusEsc = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            escHotKeyID,
            GetEventDispatcherTarget(),
            0,
            &escHotKeyRef
        )
        if statusEsc != noErr {
            NSLog("[VoiceIME] ⚠️ Esc ホットキー登録結果: %d (globalMonitorで補完)", statusEsc)
        }
    }

    private func unregisterHotkeys() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = escHotKeyRef {
            UnregisterEventHotKey(ref)
            escHotKeyRef = nil
        }
    }

    private func setupKeyMonitors() {
        // パネルにフォーカスがある場合の Esc / 挿入キーハンドリング
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return event }

            // Esc キー (keyCode 53) で即座にキャンセル & クリップボード消去
            if event.keyCode == 53 {
                self.cancel()
                return nil
            }

            // ユーザー設定のペーストキー判定
            let targetCode = AppSettings.shared.pasteShortcutKeyCode
            let targetMods = AppSettings.shared.pasteShortcutModifiers
            if UInt32(event.keyCode) == targetCode && self.matchesModifiers(event.modifierFlags, carbonModifiers: targetMods) {
                self.insertTextToFrontmostApp()
                return nil
            }

            return event
        }

        // 他アプリにフォーカスがある状態でも、ウィンドウ表示中は Esc キーで即座にキャンセル & クリップボード消去
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Esc キー (keyCode 53)
            if event.keyCode == 53 {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.isVisible else { return }
                    self.cancel()
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

    private func matchesModifiers(_ flags: NSEvent.ModifierFlags, carbonModifiers: UInt32) -> Bool {
        let hasCmd = carbonModifiers & UInt32(cmdKey) != 0
        let hasShift = carbonModifiers & UInt32(shiftKey) != 0
        let hasOpt = carbonModifiers & UInt32(optionKey) != 0
        let hasCtrl = carbonModifiers & UInt32(controlKey) != 0

        if flags.contains(.command) != hasCmd { return false }
        if flags.contains(.shift) != hasShift { return false }
        if flags.contains(.option) != hasOpt { return false }
        if flags.contains(.control) != hasCtrl { return false }
        return true
    }
}
