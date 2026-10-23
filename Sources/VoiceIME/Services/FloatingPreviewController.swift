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

/// キーボード入力・テキスト編集を受け取れるように canBecomeKey / canBecomeMain をオーバーライドしたフローティングパネル
final class KeyableFloatingPanel: NSPanel {
    override var canBecomeKey: Bool {
        return true
    }
    override var canBecomeMain: Bool {
        return true
    }
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
    @Published public var isPinned: Bool = false
    @Published public var isQuickAskQuestionEditing: Bool = false
    public var onQuickAskSubmit: ((String) -> Void)?
    public private(set) var originalTextForCorrection: String = ""
    private var isRegisteredInCurrentSession: Bool = false
    private var noticeResetTimer: Timer?
    private var hasPipelineText: Bool = false
    private var targetApp: NSRunningApplication?

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
    private var workspaceObserver: Any?
    private var globalKeyMonitor: Any?

    private init() {
        installCarbonEventHandler()
        setupKeyMonitors()
        setupWorkspaceNotifications()
    }

    deinit {
        dismissTimer?.invalidate()
        copyResetTimer?.invalidate()
        clipboardExpiryTimer?.invalidate()
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
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
        recordFrontmostApp()

        self.mode = mode
        self.phase = .liveRecording
        self.currentText = ""
        self.copySuccess = false
        self.hasPipelineText = false
        self.isPinned = false

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
        dismissTimer?.invalidate()
        dismissTimer = nil
        self.currentText = text
        self.originalTextForCorrection = text
        self.isRegisteredInCurrentSession = false
        self.phase = .ready
        self.copySuccess = false

        if isVisible {
            panel?.alphaValue = 1.0
            panel?.orderFrontRegardless()
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
        self.originalTextForCorrection = text
        self.isRegisteredInCurrentSession = false
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

    /// 指定した遅延秒数（デフォルト0.35秒）をおいて自然に非表示（ユーザーが確定テキストを目視確認できるようにする）
    public func hideWithDelay(seconds: Double = 0.35) {
        // ピン留め（修正モード固定）中は勝手に消去しない
        guard !isPinned else { return }
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: max(0.05, seconds), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isPinned else { return }
                self.hide()
            }
        }
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
        self.isPinned = false
        self.isQuickAskQuestionEditing = false
        self.onQuickAskSubmit = nil

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

    /// 最前面アプリケーションのアクティブ化変更通知を監視
    private func setupWorkspaceNotifications() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                MainActor.assumeIsolated {
                    self.targetApp = app
                }
                NSLog("[VoiceIME] 🎯 最前面アプリ変更を検知・記録: [%@]", app.localizedName ?? "")
            }
        }
    }

    /// 直前の作業アプリケーションを記録（VoiceIME自身以外）
    public func recordFrontmostApp() {
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            self.targetApp = frontApp
            NSLog("[VoiceIME] 🎯 ペースト対象の直前アプリを記録: [%@]", frontApp.localizedName ?? "")
        }
    }

    /// 直前に作業していたアプリを安全にアクティブ化（最前面化）してフォーカスを復元
    /// アクティベーションを実行した場合はフォーカスが安定するまでディレイ（120ms）を置き、
    /// すでに最前面だった場合でもわずかな安定マージン（20ms）を置いてから completion を実行
    public func activateTargetAppIfNeeded(completion: (@MainActor () -> Void)? = nil) {
        guard let app = self.targetApp, !app.isTerminated else {
            completion?()
            return
        }
        let currentFront = NSWorkspace.shared.frontmostApplication
        if currentFront?.bundleIdentifier != app.bundleIdentifier {
            NSLog("[VoiceIME] 🎯 ペースト前に直前アプリ [%@] をアクティブ化してフォーカス復元", app.localizedName ?? "")
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
            // macOS WindowServer によるウィンドウフォーカス切り替えが完了するのを確実に待つ (120ms)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                completion?()
            }
        } else {
            // すでに最前面の場合でも、キーストローク受け付けの安定マージン (20ms)
            if let completion = completion {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    completion()
                }
            }
        }
    }

    /// 最前面のアクティブアプリケーションへテキストを挿入（ペースト）
    public func insertTextToFrontmostApp() {
        // AIクイック質問の質問文修正中の場合は、ペーストではなくAIへの送信を実行
        if isQuickAskQuestionEditing {
            submitQuickAskQuestion()
            return
        }

        guard phase == .ready || isPinned else { return }
        let textToInsert = currentText
        guard !textToInsert.isEmpty else {
            hide()
            return
        }

        NSLog("[VoiceIME] ⚡️ フローティングプレビューから挿入実行: [%@]", textToInsert)

        // 🌟 修正モードで編集した後に別の入力欄や別アプリをクリックした場合への対応:
        // 現在すでに VoiceIME 以外の別アプリが最前面にある場合は、その「今ユーザーがクリックしたアプリ」を最優先でペースト先とする！
        let currentFrontApp = NSWorkspace.shared.frontmostApplication
        let myBundleId = Bundle.main.bundleIdentifier

        let appToActivate: NSRunningApplication?
        if let current = currentFrontApp, current.bundleIdentifier != myBundleId {
            appToActivate = current
            self.targetApp = current
            NSLog("[VoiceIME] 🎯 ユーザーがクリックした現在の前面アプリ [%@] をペースト先として採用", current.localizedName ?? "")
        } else {
            appToActivate = self.targetApp
            NSLog("[VoiceIME] 🎯 記録済みの直前アプリ [%@] をアクティブ化して復元", appToActivate?.localizedName ?? "")
        }

        saveCorrectionStockIfNeeded()
        if isPinned || currentText != originalTextForCorrection {
            PipelineLogger.shared.logUserCorrection(text: textToInsert, originalText: originalTextForCorrection)
        }
        hide()

        // 1. 必要に応じてアプリを最前面にアクティブ化して入力フォーカスを戻す
        // ※すでにそのアプリが最前面になっているなら再度 activate を呼ばずフォーカスを維持する
        if let app = appToActivate, !app.isTerminated {
            if currentFrontApp?.bundleIdentifier != app.bundleIdentifier {
                NSLog("[VoiceIME] 🚀 直前のアプリ [%@] をアクティブ化してフォーカスを復元", app.localizedName ?? "")
                if #available(macOS 14.0, *) {
                    app.activate()
                } else {
                    app.activate(options: [.activateIgnoringOtherApps])
                }
            }
        }

        // 2. アプリがアクティブ化され入力カーソルが安定するのを確実に待ってペースト (180ms)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            TextPasterService.shared.paste(
                text: textToInsert,
                restoreClipboard: AppSettings.shared.restoreClipboard
            )
        }
    }

    /// AIクイック質問の質問文を修正用に表示
    public func showQuickAskQuestionForEditing(question: String, onSubmit: @escaping (String) -> Void) {
        self.mode = .quickAsk
        self.phase = .ready
        self.isPinned = true
        self.isQuickAskQuestionEditing = true
        self.currentText = question
        self.originalTextForCorrection = question
        self.isRegisteredInCurrentSession = false
        self.onQuickAskSubmit = onSubmit
        let noticeSuffix = AppSettings.shared.correctionStockEnabled ? " / - で単語登録" : ""
        self.customNotice = "質問を修正 ➔ ⌘↩ でAIに送信\(noticeSuffix) / + で閉じる"

        if panel == nil {
            setupPanel()
        }

        updatePanelPosition()

        if !isVisible {
            panel?.alphaValue = 0.0
            panel?.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                self.panel?.animator().alphaValue = 1.0
            }
            self.isVisible = true
        }

        registerHotkeys()
        activateAndFocusForEditing()
        NSLog("[VoiceIME] 🟣 AIクイック質問: 送信前修正モード表示 (文字数: %d)", question.count)
    }

    /// 修正された質問を AI に送信
    public func submitQuickAskQuestion() {
        guard isQuickAskQuestionEditing, let onSubmit = onQuickAskSubmit else { return }
        let questionToSubmit = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !questionToSubmit.isEmpty else {
            hide()
            return
        }

        self.isQuickAskQuestionEditing = false
        self.onQuickAskSubmit = nil
        self.phase = .processing
        NSLog("[VoiceIME] 🟣 AIクイック質問: 修正後質問をAIへ送信実行: [%@]", questionToSubmit)
        onSubmit(questionToSubmit)
    }

    // MARK: - Panel Setup & Layout

    private func setupPanel() {
        let hostingView = NSHostingView(rootView: FloatingPreviewView(controller: self))

        let panel = KeyableFloatingPanel(
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
        panel.becomesKeyOnlyIfNeeded = false
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

        // ピン留め（固定保持モード）中は自動消去タイマーを動かさない
        if isPinned { return }

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

    // MARK: - Pin & Editing Mode (+ Key Support)

    /// + キー等による固定（ピン留め・キーリリース時維持）のトグル
    public func togglePinned() {
        isPinned.toggle()
        if isPinned {
            dismissTimer?.invalidate()
            dismissTimer = nil
            NSLog("[VoiceIME] 📌 フローティングウィンドウをピン留め固定（キーを離しても維持・修正モード有効化）")
            if phase == .ready {
                activateAndFocusForEditing()
            }
        } else {
            NSLog("[VoiceIME] 📌 フローティングウィンドウのピン留め固定を解除")
            if phase == .ready {
                resetDismissTimer()
            }
        }
    }

    /// フローティングウィンドウを前面アクティブ化し、テキスト編集フィールドにフォーカスを当てる
    public func activateAndFocusForEditing() {
        guard let panel = panel, isVisible else { return }

        // VoiceIME がアクティブになる直前の最前面作業アプリを保持（ペースト復元先）
        recordFrontmostApp()

        // アプリケーションおよびパネルをキーウィンドウとして前面アクティブ化
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // SwiftUIのビュー階層が確実に描画・更新されるよう微小遅延を置いてフォーカスを適用
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self = self, let panel = self.panel else { return }
            panel.makeKeyAndOrderFront(nil)
            if let hostingView = panel.contentView, let textView = self.findTextView(in: hostingView) {
                panel.makeFirstResponder(textView)
                let length = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: length, length: 0))
                NSLog("[VoiceIME] ✏️ テキスト編集欄（NSTextView）にフォーカスを設定しました（文字数: %d）", length)
            } else {
                NSLog("[VoiceIME] ⚠️ NSTextView が見つかりませんでした")
            }
        }
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView {
            return tv
        }
        if let sv = view as? NSScrollView, let tv = sv.documentView as? NSTextView {
            return tv
        }
        for subview in view.subviews {
            if let found = findTextView(in: subview) {
                return found
            }
        }
        return nil
    }

    /// 修正モード終了・+ キーによるウィンドウ消去（編集後テキストをクリップボードに退避し、ピン留め解除して消去）
    public func dismissAfterEditing() {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            setTemporaryClipboard(text: currentText, duration: 45.0)
            AppState.shared.lastProcessedText = currentText
            if currentText != originalTextForCorrection {
                PipelineLogger.shared.logUserCorrection(text: currentText, originalText: originalTextForCorrection)
            }
            NSLog("[VoiceIME] 📝 修正後テキストをクリップボードに保持してプレビューを消去: [%@]", currentText)
        }
        saveCorrectionStockIfNeeded()
        isPinned = false
        hide()
    }

    /// 編集差分を検知し、未登録であれば ~/.voiceime/corrections.json にストック保存
    private func saveCorrectionStockIfNeeded() {
        guard AppSettings.shared.correctionStockEnabled else { return }
        let orig = originalTextForCorrection.trimmingCharacters(in: .whitespacesAndNewlines)
        let corr = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orig.isEmpty, orig != corr else { return }

        if let diff = CorrectionStockService.detectWordDiff(original: orig, corrected: corr) {
            CorrectionStockService.shared.recordCorrection(
                original: orig,
                corrected: corr,
                diffBefore: diff.before,
                diffAfter: diff.after,
                isRegistered: isRegisteredInCurrentSession
            )
        }
    }

    /// -（マイナスキー）の押下判定（テンキー78、メインキーボードJIS44/US27等）
    private func isMinusKey(event: NSEvent) -> Bool {
        // Command / Option が押されている場合は別コマンドなので除外
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.option) {
            return false
        }

        // テンキーの - (keyCode: 78)
        if event.keyCode == 78 {
            return true
        }

        // 入力文字が "-" (Shiftなし)
        if let chars = event.characters, chars == "-" {
            return true
        }

        // JIS配列 (keyCode 44: -) または US配列 (keyCode 27: -) かつ Shift なし
        if (event.keyCode == 44 || event.keyCode == 27) && !flags.contains(.shift) {
            return true
        }

        return false
    }

    /// - キーによる差分単語予測・単語登録処理
    @discardableResult
    private func handleMinusKeyForVocabulary() -> Bool {
        guard AppSettings.shared.correctionStockEnabled else { return false }
        guard isPinned || phase == .ready else { return false }

        let orig = originalTextForCorrection.trimmingCharacters(in: .whitespacesAndNewlines)
        let corr = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if let diff = CorrectionStockService.detectWordDiff(original: orig, corrected: corr), !diff.after.isEmpty {
            let success = CorrectionStockService.shared.registerVocabularyWord(diff.after)
            if success {
                isRegisteredInCurrentSession = true
                CorrectionStockService.shared.recordCorrection(
                    original: orig,
                    corrected: corr,
                    diffBefore: diff.before,
                    diffAfter: diff.after,
                    isRegistered: true
                )
                showTemporaryNotice("✨ 単語登録完了: [\(diff.after)]")
            }
            return true
        } else {
            showTemporaryNotice("⚠️ 修正差分が見つかりません")
            return true
        }
    }

    /// 一時的なトースト案内を表示
    public func showTemporaryNotice(_ notice: String) {
        noticeResetTimer?.invalidate()
        let previousNotice = customNotice
        customNotice = notice
        noticeResetTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.customNotice = previousNotice
            }
        }
    }

    /// +（プラスキー）の押下判定（テンキー、JIS Shift+;、US Shift+=等に全対応）
    private func isPlusKey(event: NSEvent) -> Bool {
        // Command / Option が押されている場合は別コマンドなので除外
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.option) {
            return false
        }

        // テンキーの + (keyCode: 69)
        if event.keyCode == 69 {
            return true
        }

        // 入力文字が "+" (Shift+; や Shift+= など)
        if let chars = event.characters, chars == "+" {
            return true
        }

        // JIS配列 (keyCode 41: ;) または US配列 (keyCode 24: =) かつ Shift 押下
        if (event.keyCode == 41 || event.keyCode == 24) && flags.contains(.shift) {
            return true
        }

        return false
    }

    /// 挿入（ペースト）ホットキー判定（⌘+Enter等、Return(36)とテンキーEnter(76)の両方に対応）
    private func isPasteShortcutEvent(_ event: NSEvent) -> Bool {
        let targetCode = AppSettings.shared.pasteShortcutKeyCode
        let targetMods = AppSettings.shared.pasteShortcutModifiers

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCmd = flags.contains(.command)
        let isShift = flags.contains(.shift)
        let isOpt = flags.contains(.option)
        let isCtrl = flags.contains(.control)

        let targetCmd = (targetMods & UInt32(cmdKey)) != 0
        let targetShift = (targetMods & UInt32(shiftKey)) != 0
        let targetOpt = (targetMods & UInt32(optionKey)) != 0
        let targetCtrl = (targetMods & UInt32(controlKey)) != 0

        guard isCmd == targetCmd && isShift == targetShift && isOpt == targetOpt && isCtrl == targetCtrl else {
            return false
        }

        // Return (36) と テンキーEnter (76) は同等に扱う
        if targetCode == 36 || targetCode == 76 {
            return event.keyCode == 36 || event.keyCode == 76
        }

        return UInt32(event.keyCode) == targetCode
    }

    private func setupKeyMonitors() {
        // パネルにフォーカスがある場合のキーハンドリング
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return event }

            // Esc キー (keyCode 53) で即座にキャンセル & クリップボード消去
            if event.keyCode == 53 {
                self.cancel()
                return nil
            }

            // + キー押下時のハンドリング
            if self.isPlusKey(event: event) {
                if self.isPinned || self.phase == .ready {
                    // すでにピン留め中または確定表示中に再度 + が押されたらウィンドウを消去
                    self.dismissAfterEditing()
                    return nil // テキスト入力欄に "+" が入力されないよう消費
                } else {
                    self.togglePinned()
                    return nil
                }
            }

            // - キー押下時の単語登録ハンドリング（修正履歴ストックが有効な場合）
            if self.isMinusKey(event: event) && AppSettings.shared.correctionStockEnabled {
                if self.isPinned || self.phase == .ready {
                    if self.handleMinusKeyForVocabulary() {
                        return nil // テキスト入力欄に "-" が入力されないよう消費
                    }
                }
            }

            // ユーザー設定のペーストキー（⌘+Enter等）判定
            if self.isPasteShortcutEvent(event) {
                NSLog("[VoiceIME] ⚡️ localKeyMonitor: 挿入ショートカット（⌘+Enter等）を検知 ➔ テキスト挿入実行")
                self.insertTextToFrontmostApp()
                return nil // テキスト欄に改行が入らないよう消費
            }

            return event
        }

        // 他アプリにフォーカスがある状態でも、ウィンドウ表示中は Esc / + / 挿入キーを監視
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }

            // Esc キー (keyCode 53)
            if event.keyCode == 53 {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.isVisible else { return }
                    self.cancel()
                }
                return
            }

            // + キー
            if self.isPlusKey(event: event) {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.isVisible else { return }
                    if self.isPinned && self.phase == .ready {
                        self.dismissAfterEditing()
                    } else {
                        self.togglePinned()
                    }
                }
                return
            }

            // - キー（単語登録）
            if self.isMinusKey(event: event) && AppSettings.shared.correctionStockEnabled {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.isVisible else { return }
                    if self.isPinned || self.phase == .ready {
                        self.handleMinusKeyForVocabulary()
                    }
                }
                return
            }

            // ユーザー設定のペーストキー（⌘+Enter等）判定
            if self.isPasteShortcutEvent(event) {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.isVisible else { return }
                    NSLog("[VoiceIME] ⚡️ globalKeyMonitor: 挿入ショートカット（⌘+Enter等）を検知 ➔ テキスト挿入実行")
                    self.insertTextToFrontmostApp()
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
