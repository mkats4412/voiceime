import Foundation
import SwiftUI
import Combine
import Carbon

public enum RecordingPhase: Equatable {
    case idle
    case recording
    case transcribing
    case refining
    case pasting
    case error(String)
}

/// メインプロバイダ障害時のフォールバック記録
public struct FallbackRecord: Identifiable, Equatable {
    public let id = UUID()
    public let timestamp: Date
    public let primaryProvider: APIProvider
    public let backupProvider: APIProvider
    public let step: String // "音声認識" または "AI推敲"
    public let reasonSummary: String
    public let detail: String

    public var displayNotice: String {
        "[\(primaryProvider.displayName)\(step)失敗: \(reasonSummary) ➔ \(backupProvider.displayName)で実行]"
    }
}

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    @Published public var phase: RecordingPhase = .idle
    @Published public var statusMessage: String = "準備完了"
    @Published public var lastTranscribedText: String = ""
    @Published public var lastProcessedText: String = ""
    @Published public var lastUsedWhisperProvider: APIProvider? = nil
    @Published public var lastUsedLLMProvider: APIProvider? = nil

    /// 直前の入力で最終的に出力（認識・推敲）を担当したプロバイダ
    public var lastEffectiveProvider: APIProvider? {
        lastUsedLLMProvider ?? lastUsedWhisperProvider
    }
    @Published public var errorMessage: String? = nil
    @Published public var lastFallbackRecord: FallbackRecord? = nil
    @Published public var isRecentTextCopied: Bool = false

    private var copyFeedbackTimer: Timer?

    /// 直前の入力テキストをクリップボードにコピー
    public func copyRecentProcessedText() {
        guard !lastProcessedText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lastProcessedText, forType: .string)

        isRecentTextCopied = true
        copyFeedbackTimer?.invalidate()
        copyFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isRecentTextCopied = false
            }
        }
    }

    private let settings = AppSettings.shared
    private let keychain = KeychainService.shared
    private let recorder = AudioRecorderService.shared
    private let api = WhisperAPIService.shared
    private let llm = LLMService.shared
    private let dictionary = DictionaryService.shared
    private let paster = TextPasterService.shared
    private let permissions = PermissionService.shared
    private let hotkey = HotkeyManager.shared

    private var recordingStartTime: Date?
    private var maxRecordingTimer: Timer?
    /// 文字起こし〜ペーストまでの非同期処理。キャンセル可能にするためハンドルを保持する
    private var processingTask: Task<Void, Never>?
    private var processingTaskToken: UUID?

    // MARK: - AI クイック質問 (Quick Ask) 状態管理
    @Published public private(set) var isQuickAskActive: Bool = false
    private var quickAskHistory: [LLMService.ChatMessage] = []
    private var isQuickAskModifierHeld: Bool = false
    private var modifierKeyMonitorLocal: Any?
    private var modifierKeyMonitorGlobal: Any?
    private var keyUpMonitorLocal: Any?
    private var keyUpMonitorGlobal: Any?

    // MARK: - 一時停止 (Push-to-Talk 思考サポート) 状態管理
    @Published public private(set) var isRecordingPaused: Bool = false

    private init() {
        setupHotkey()
        setupModifierKeyMonitors()
        setupKeyUpMonitors()
        logSystemStartupConfiguration()
        // アプリ起動とAppKitランループの開始完了後に、Keychainアクセスの事前案内とウォームアップ、
        // ならびにフローティングパネルの事前描画準備を実行（※マイクは録音開始時のみ完全オンデマンドで起動）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.promptKeychainWarmupIfNeeded()
            FloatingPreviewController.shared.warmUpPanelIfNeeded()
            self.permissions.checkPermissions()
        }
    }

    /// アプリ起動時のシステム構成・LLM推敲設定・STTプロバイダ状態をログに記録
    public func logSystemStartupConfiguration() {
        let stt = "\(settings.selectedProvider.displayName) (\(settings.config(for: settings.selectedProvider).modelName))"
        let isRefine = settings.isLLMRefinementActive
        let llm = isRefine
            ? "有効 (ON) - \(settings.resolvedLLMProvider.displayName) (\(settings.effectiveLLMConfig.modelName)) [スタイル: \(settings.refinementStyle.rawValue)]"
            : (settings.llmRefinementEnabled ? "OFF (モデル未指定)" : "無効 (OFF)")
        let quickAsk = "\(settings.effectiveQuickAskConfig.provider.displayName) (\(settings.effectiveQuickAskConfig.modelName))"
        let backup = settings.backupProvider?.displayName ?? "なし"
        let mcp = settings.mcpAgentEditingEnabled ? "有効 (ON - ユーザー責任)" : "無効 (OFF - デフォルト)"
        let pipeLog = settings.pipelineLoggingEnabled ? "有効 (ON - ユーザー同意)" : "無効 (OFF - プライバシー保護・デフォルト)"

        SystemLogger.shared.logInfo("==================================================")
        SystemLogger.shared.logInfo("VoiceIME 起動完了")
        SystemLogger.shared.logInfo("音声認識 (STT): \(stt)")
        SystemLogger.shared.logInfo("AI推敲: \(llm)")
        SystemLogger.shared.logInfo("AIクイック質問: \(quickAsk)")
        SystemLogger.shared.logInfo("バックアップSTT: \(backup)")
        SystemLogger.shared.logInfo("MCP連携: \(mcp)")
        SystemLogger.shared.logInfo("パイプラインログ (~/.voiceime/pipeline.log): \(pipeLog)")
        SystemLogger.shared.logInfo("==================================================")
    }

    deinit {
        if let m = modifierKeyMonitorLocal { NSEvent.removeMonitor(m) }
        if let m = modifierKeyMonitorGlobal { NSEvent.removeMonitor(m) }
        if let m = keyUpMonitorLocal { NSEvent.removeMonitor(m) }
        if let m = keyUpMonitorGlobal { NSEvent.removeMonitor(m) }
    }

    /// クイック質問用およびPush-to-Talk用修飾キー（例: Ctrl, Shift）の押下・離脱を監視
    private func setupModifierKeyMonitors() {
        let handleFlagsChanged: (NSEvent) -> Void = { [weak self] event in
            guard let self = self else { return }

            // 1. クイック質問用修飾キーの追跡
            let quickAskMods = self.settings.quickAskHotkeyModifiers
            let isHoldingQuickAsk = self.matchesModifiers(event.modifierFlags, carbonModifiers: quickAskMods)
            if !isHoldingQuickAsk {
                self.isQuickAskModifierHeld = false
                // クイック質問録音中に修飾キーが離されたら確実に録音停止
                if self.isQuickAskActive && self.phase == .recording {
                    if self.isRecordingPaused {
                        NSLog("[VoiceIME] 🛡️ flagsChanged: クイック質問一時停止中に修飾キー離脱 ➔ stopQuickAskAndProcess")
                        self.isRecordingPaused = false
                        self.stopQuickAskAndProcess()
                    } else {
                        NSLog("[VoiceIME] 🛡️ flagsChanged: クイック質問修飾キーの離脱を検知 ➔ handleQuickAskKeyUp")
                        self.handleQuickAskKeyUp()
                    }
                }
            }

            // 2. 通常のPush-to-Talk音声入力用修飾キーの追跡
            if self.settings.triggerMode == .pushToTalk && self.phase == .recording && !self.isQuickAskActive {
                let requiredMods = self.settings.hotkeyModifiers
                if requiredMods != 0 {
                    let isHoldingSpeechMods = self.matchesModifiers(event.modifierFlags, carbonModifiers: requiredMods)
                    if !isHoldingSpeechMods {
                        if self.isRecordingPaused {
                            NSLog("[VoiceIME] 🛡️ flagsChanged: Push-to-Talk 一時停止中に修飾キー離脱 ➔ stopRecordingAndTranscribe")
                            self.isRecordingPaused = false
                            self.stopRecordingAndTranscribe()
                        } else {
                            NSLog("[VoiceIME] 🛡️ flagsChanged: Push-to-Talk 修飾キーの離脱を検知 ➔ handleHotKeyUp")
                            self.handleHotKeyUp()
                        }
                    }
                }
            }
        }

        modifierKeyMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlagsChanged(event)
            return event
        }

        modifierKeyMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlagsChanged(event)
        }
    }

    /// 物理キー（Space等）の離脱（KeyUp）を監視し、Push-to-Talkのキー離脱見逃しを完全防止
    private func setupKeyUpMonitors() {
        let handleKeyUp: (NSEvent) -> Void = { [weak self] event in
            guard let self = self, self.phase == .recording else { return }

            let keyCode = UInt32(event.keyCode)

            // クイック質問中の場合
            if self.isQuickAskActive {
                if keyCode == self.settings.quickAskHotkeyCode {
                    NSLog("[VoiceIME] 🛡️ keyUp: クイック質問キー (%d) の離脱を検知 ➔ handleQuickAskKeyUp", keyCode)
                    self.handleQuickAskKeyUp()
                }
                return
            }

            // 通常のPush-to-Talkの場合
            if self.settings.triggerMode == .pushToTalk {
                if keyCode == self.settings.hotkeyCode {
                    NSLog("[VoiceIME] 🛡️ keyUp: Push-to-Talkキー (%d) の離脱を検知 ➔ handleHotKeyUp", keyCode)
                    self.handleHotKeyUp()
                }
            }
        }

        keyUpMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            handleKeyUp(event)
            return event
        }

        keyUpMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { event in
            handleKeyUp(event)
        }
    }

    private func matchesModifiers(_ flags: NSEvent.ModifierFlags, carbonModifiers: UInt32) -> Bool {
        let hasCmd = carbonModifiers & UInt32(cmdKey) != 0
        let hasShift = carbonModifiers & UInt32(shiftKey) != 0
        let hasOpt = carbonModifiers & UInt32(optionKey) != 0
        let hasCtrl = carbonModifiers & UInt32(controlKey) != 0

        if hasCmd && !flags.contains(.command) { return false }
        if hasShift && !flags.contains(.shift) { return false }
        if hasOpt && !flags.contains(.option) { return false }
        if hasCtrl && !flags.contains(.control) { return false }
        return true
    }

    /// グローバルホットキーのセットアップ
    public func setupHotkey() {
        // 1. 音声入力ホットキー
        hotkey.register(
            type: .speechInput,
            keyCode: settings.hotkeyCode,
            modifiers: settings.hotkeyModifiers,
            onKeyDown: { [weak self] in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.handleHotKeyDown()
                    }
                } else {
                    Task { @MainActor in
                        self?.handleHotKeyDown()
                    }
                }
            },
            onKeyUp: { [weak self] in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.handleHotKeyUp()
                    }
                } else {
                    Task { @MainActor in
                        self?.handleHotKeyUp()
                    }
                }
            }
        )

        // 2. AI クイック質問ホットキー
        hotkey.register(
            type: .quickAsk,
            keyCode: settings.quickAskHotkeyCode,
            modifiers: settings.quickAskHotkeyModifiers,
            onKeyDown: { [weak self] in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.handleQuickAskKeyDown()
                    }
                } else {
                    Task { @MainActor in
                        self?.handleQuickAskKeyDown()
                    }
                }
            },
            onKeyUp: { [weak self] in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.handleQuickAskKeyUp()
                    }
                } else {
                    Task { @MainActor in
                        self?.handleQuickAskKeyUp()
                    }
                }
            }
        )
    }

    /// ホットキーが押されたときのハンドラ
    public func handleHotKeyDown() {
        if settings.triggerMode == .pushToTalk {
            if phase == .recording && isRecordingPaused && !isQuickAskActive {
                // 一時停止からの再開！
                resumeRecording()
            } else if phase == .idle || isErrorPhase() {
                startRecording()
            }
        } else {
            // トグルモード
            if phase == .recording {
                stopRecordingAndTranscribe()
            } else if phase == .idle || isErrorPhase() {
                startRecording()
            }
        }
    }

    /// ホットキーが離されたときのハンドラ
    public func handleHotKeyUp() {
        if settings.triggerMode == .pushToTalk {
            if phase == .recording && !isQuickAskActive {
                // すでに一時停止中の場合、SpaceのKeyUpは無視（修飾キーの離脱で確定する）
                if isRecordingPaused {
                    return
                }

                // 誤タップ（0.15秒未満）の誤動作ガード
                if let startTime = recordingStartTime, Date().timeIntervalSince(startTime) < 0.15 {
                    cancelRecording()
                    return
                }

                // 修飾キー（Ctrl等）がまだ押されているか確認
                let requiredMods = settings.hotkeyModifiers
                let isHoldingMods = requiredMods != 0 && matchesModifiers(NSEvent.modifierFlags, carbonModifiers: requiredMods)

                if isHoldingMods {
                    // 修飾キーを押したままSpaceが離された ➔ 一時停止（思考サポート）
                    pauseRecording()
                } else {
                    // キーを離した瞬間に視覚的フィードバック（処理中アニメーション）を即座に開始
                    if settings.floatingPreviewEnabled {
                        FloatingPreviewController.shared.setProcessing(mode: .speechInput)
                    }
                    // 発話末尾の単語・語尾・余韻（「〜でしょう」「〜出ている」「〜ですよね」等）がマイクバッファから欠落するのを防ぐため、
                    // キー離脱から約420ms遅延させて録音を停止する
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
                        guard let self = self, self.phase == .recording, !self.isQuickAskActive, !self.isRecordingPaused else { return }
                        self.stopRecordingAndTranscribe()
                    }
                }
            }
        }
    }

    /// AIクイック質問ホットキー押下時
    public func handleQuickAskKeyDown() {
        if isQuickAskActive && phase == .recording && isRecordingPaused {
            resumeQuickAskRecording()
            return
        }

        // 修飾キーが前回の回答時から維持されているか判定
        let currentlyHolding = matchesModifiers(NSEvent.modifierFlags, carbonModifiers: settings.quickAskHotkeyModifiers)
        if !isQuickAskModifierHeld || !currentlyHolding {
            // 修飾キーが一旦離されていたので、新しい会話としてリセット
            quickAskHistory.removeAll()
            NSLog("[VoiceIME] 🟣 AIクイック質問: 新規セッション開始 (会話履歴リセット)")
        } else {
            NSLog("[VoiceIME] 🟣 AIクイック質問: 連続セッション継続 (履歴数: %d)", quickAskHistory.count)
        }
        isQuickAskModifierHeld = true

        if phase == .idle || isErrorPhase() {
            startQuickAskRecording()
        }
    }

    /// AIクイック質問ホットキー離脱時
    public func handleQuickAskKeyUp() {
        if isQuickAskActive && phase == .recording {
            if isRecordingPaused {
                return
            }

            // 誤タップガード
            if let startTime = recordingStartTime, Date().timeIntervalSince(startTime) < 0.15 {
                cancelRecording()
                return
            }

            let quickAskMods = settings.quickAskHotkeyModifiers
            let isHoldingMods = quickAskMods != 0 && matchesModifiers(NSEvent.modifierFlags, carbonModifiers: quickAskMods)

            if isHoldingMods {
                pauseQuickAskRecording()
            } else {
                FloatingPreviewController.shared.setProcessing(mode: .quickAsk)

                // 音声末尾の欠落防止のため約200ms遅延して停止・質問処理
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                    guard let self = self, self.isQuickAskActive, self.phase == .recording, !self.isRecordingPaused else { return }
                    self.stopQuickAskAndProcess()
                }
            }
        }
    }

    /// ホットキー設定変更時の再登録
    public func updateHotkey(keyCode: UInt32, modifiers: UInt32, displayString: String) {
        settings.hotkeyCode = keyCode
        settings.hotkeyModifiers = modifiers
        settings.hotkeyDisplayString = displayString
        setupHotkey()
    }

    /// クイック質問ホットキー設定変更時
    public func updateQuickAskHotkey(keyCode: UInt32, modifiers: UInt32, displayString: String) {
        settings.quickAskHotkeyCode = keyCode
        settings.quickAskHotkeyModifiers = modifiers
        settings.quickAskHotkeyDisplayString = displayString
        setupHotkey()
    }

    /// プレビューペーストショートカット設定変更時
    public func updatePasteShortcut(keyCode: UInt32, modifiers: UInt32, displayString: String) {
        settings.pasteShortcutKeyCode = keyCode
        settings.pasteShortcutModifiers = modifiers
        settings.pasteShortcutDisplayString = displayString
        FloatingPreviewController.shared.reloadHotkeys()
    }

    /// 録音のトグル（開始 / 終了と文字起こし）
    public func toggleRecording() {
        if phase == .recording {
            stopRecordingAndTranscribe()
        } else if phase == .idle || isErrorPhase() {
            startRecording()
        }
    }

    public func isErrorPhase() -> Bool {
        if case .error = phase { return true }
        return false
    }

    /// エラー状態をクリアして準備完了（通常アイコン）に戻す
    public func resetError() {
        if isErrorPhase() {
            phase = .idle
            statusMessage = "準備完了"
            errorMessage = nil
        }
    }

    // MARK: - 一時停止・再開（思考サポート）

    /// Push-to-Talkで修飾キーを押したままメインキーを離した際の一時停止処理
    public func pauseRecording() {
        guard phase == .recording, !isRecordingPaused else { return }
        isRecordingPaused = true

        // セキュリティ最優先: 一時停止中はマイクを完全に停止（オレンジの点灯を消灯）
        LiveSpeechService.shared.stopLiveRecognition()
        recorder.pauseRecording()
        StreamingChunkPipelineService.shared.pauseCapture()

        if settings.floatingPreviewEnabled {
            FloatingPreviewController.shared.setPaused(mode: .speechInput)
        }
        let mainKey = settings.hotkeyMainKeyDisplayString
        let modKey = settings.hotkeyModifiersDisplayString
        statusMessage = "一時停止中 (\(mainKey)で再開 / \(modKey)離して入力)"
        NSLog("[VoiceIME] ⏸️ 音声入力 一時停止 (マイク停止中・未送信音声をWhisper同期・思考待機)")
    }

    /// 一時停止中からメインキーを再度押した際の再開処理
    public func resumeRecording() {
        guard phase == .recording, isRecordingPaused else { return }
        isRecordingPaused = false

        // キャプチャの再開
        recorder.resumeRecording()
        StreamingChunkPipelineService.shared.resumeCapture()
        _ = LiveSpeechService.shared.startImmediateCapture()
        LiveSpeechService.shared.startLiveRecognition(
            languageCode: settings.language,
            contextualStrings: []
        ) { _ in }

        if settings.floatingPreviewEnabled {
            FloatingPreviewController.shared.resumeLiveRecording(mode: .speechInput)
        }
        statusMessage = settings.triggerMode == .pushToTalk ? "録音中... (キーを離すと入力)" : "録音中... (もう一度キーを押して停止)"
        NSLog("[VoiceIME] ▶️ 音声入力 再開 (マイクキャプチャ再開・続きを描画)")
    }

    /// AIクイック質問の一時停止処理
    public func pauseQuickAskRecording() {
        guard isQuickAskActive, phase == .recording, !isRecordingPaused else { return }
        isRecordingPaused = true

        LiveSpeechService.shared.stopLiveRecognition()
        recorder.pauseRecording()
        StreamingChunkPipelineService.shared.pauseCapture()

        FloatingPreviewController.shared.setPaused(mode: .quickAsk)
        let mainKey = settings.quickAskMainKeyDisplayString
        let modKey = settings.quickAskModifiersDisplayString
        statusMessage = "一時停止中 (\(mainKey)で再開 / \(modKey)離して送信)"
        NSLog("[VoiceIME] ⏸️ AIクイック質問 一時停止 (マイク停止中・未送信音声をWhisper同期・思考待機)")
    }

    /// AIクイック質問の再開処理
    public func resumeQuickAskRecording() {
        guard isQuickAskActive, phase == .recording, isRecordingPaused else { return }
        isRecordingPaused = false

        recorder.resumeRecording()
        StreamingChunkPipelineService.shared.resumeCapture()
        _ = LiveSpeechService.shared.startImmediateCapture()
        LiveSpeechService.shared.startLiveRecognition(languageCode: settings.language) { _ in }

        FloatingPreviewController.shared.resumeLiveRecording(mode: .quickAsk)
        statusMessage = "AI質問中... (キーを離すと回答)"
        NSLog("[VoiceIME] ▶️ AIクイック質問 再開 (マイクキャプチャ再開)")
    }

    // MARK: - AI クイック質問 (Quick Ask) 録音・処理フロー

    /// AIクイック質問の録音開始
    public func startQuickAskRecording() {
        isRecordingPaused = false
        if MicrophoneLevelTester.shared.isTesting {
            MicrophoneLevelTester.shared.stopTesting()
        }

        if !permissions.isMicrophoneAuthorized {
            permissions.checkPermissions()
        }
        guard permissions.isMicrophoneAuthorized else {
            phase = .error("マイクへのアクセス権限が必要です。")
            statusMessage = "マイク権限エラー"
            permissions.requestMicrophoneAccess()
            return
        }

        // 🌟 最優先: UI表示・アプリ検出・Keychain読込より先にマイク録音キャプチャを開始！
        // （非録音時はセキュリティのためマイクOFF。ホットキー押下時のみ即座に起動）
        isQuickAskActive = true
        phase = .recording
        recordingStartTime = Date()
        StreamingChunkPipelineService.shared.prepareImmediateCapture(
            speechThresholdDB: settings.audioThresholdDB,
            isStreamingTriggerEnabled: true
        )
        let micStarted = LiveSpeechService.shared.startImmediateCapture()

        // バックアップ録音も開始（万が一のAVAudioEngine失敗時のフォールバック用）
        let recorderStarted = (try? recorder.startRecording()) != nil
        guard micStarted || recorderStarted else {
            isQuickAskActive = false
            phase = .error("録音の開始に失敗しました。")
            statusMessage = "録音開始に失敗しました。"
            errorMessage = "マイク入力の初期化に失敗しました。"
            SystemLogger.shared.logError("クイック質問 録音開始失敗: マイク入力初期化エラー")
            NSLog("[VoiceIME] ❌ クイック質問 録音開始失敗")
            return
        }

        statusMessage = "AI質問中... (キーを離すと回答)"
        errorMessage = nil
        NSLog("[VoiceIME] 🟣 AIクイック質問 録音開始 (即時キャプチャ完了)")

        // AI会話でもWhisperからプレビューをリアルタイム更新（中間推敲は不要なのでisLLMEnabled: false）
        let currentProvider = settings.selectedProvider
        let currentConfig = settings.config(for: currentProvider)
        let apiKey = keychain.loadAPIKey(for: currentProvider)
        let effectiveLanguage = settings.language.isEmpty ? "ja" : settings.language

        StreamingChunkPipelineService.shared.start(
            whisperConfig: (baseURL: currentConfig.baseURL, apiKey: apiKey, model: currentConfig.modelName),
            llmConfig: (baseURL: "", apiKey: nil, model: "", isCustom: false),
            style: .casual,
            isLLMEnabled: false,
            whisperPrompt: "質問です。日本語で質問します。",
            language: effectiveLanguage,
            speechThresholdDB: settings.audioThresholdDB
        )

        LiveSpeechService.shared.startLiveRecognition(languageCode: settings.language) { _ in
            // Apple Speech のフェイク推論は画面に出さず、Whisperから戻ってきた本物の結果のみを表示する
        }

        // マイクが確実に回り始めた後に、前面アプリ記録とフローティングウィンドウ表示を実行
        FloatingPreviewController.shared.recordFrontmostApp()
        FloatingPreviewController.shared.showLiveRecording(mode: .quickAsk)

        maxRecordingTimer?.invalidate()
        maxRecordingTimer = Timer.scheduledTimer(withTimeInterval: 45.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.isQuickAskActive == true && self?.phase == .recording {
                    NSLog("[VoiceIME] ⏱️ クイック質問最大録音時間（45秒）に達したため自動停止")
                    self?.stopQuickAskAndProcess()
                }
            }
        }
    }

    /// AIクイック質問の録音停止・認識・回答生成処理
    public func stopQuickAskAndProcess() {
        isRecordingPaused = false
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil

        LiveSpeechService.shared.stopLiveRecognition()
        FloatingPreviewController.shared.setProcessing(mode: .quickAsk)

        let recorderURL = recorder.stopRecording()
        let pipelineWAVURL = StreamingChunkPipelineService.shared.exportFullAudioWAV()
        if let _ = pipelineWAVURL, let recURL = recorderURL {
            try? FileManager.default.removeItem(at: recURL)
        }

        guard let audioURL = pipelineWAVURL ?? recorderURL else {
            isQuickAskActive = false
            phase = .idle
            statusMessage = "録音データがありません。"
            FloatingPreviewController.shared.hide()
            return
        }

        // 音声しきい値・無音判定
        let metrics = AudioAnalysisService.shared.analyze(
            audioFileURL: audioURL,
            thresholdDB: settings.audioThresholdDB
        )

        // 設定のON/OFFに関わらず、無音（または短時間のクリック音・打鍵ノイズ）はAPIへ送信しない
        if metrics.isSilence {
            NSLog("[VoiceIME] 🔇 AIクイック質問 無音検知: 送信をスキップしました (maxRMS: %.1f dB, peak: %.1f dB, 可聴時間: %.2f秒, 録音長: %.2f秒)",
                  metrics.maxWindowRMS_DB, metrics.peakPowerDB, metrics.audibleDurationSeconds, metrics.totalDurationSeconds)
            try? FileManager.default.removeItem(at: audioURL)
            self.isQuickAskActive = false
            self.phase = .idle
            self.statusMessage = "無音のため質問をスキップしました"
            FloatingPreviewController.shared.hide()
            return
        }

        var targetAudioURL = audioURL
        if settings.audioThresholdEnabled {
            if !metrics.hasSpeech {
                NSLog("[VoiceIME] AIクイック質問 音声除外: 音量レベルがしきい値未満 (maxRMS: %.1f dB, peak: %.1f dB, しきい値: %.1f dB)",
                      metrics.maxWindowRMS_DB, metrics.peakPowerDB, settings.audioThresholdDB)
                try? FileManager.default.removeItem(at: audioURL)
                self.isQuickAskActive = false
                self.phase = .idle
                self.statusMessage = "小さな音を検知したため無視しました"
                FloatingPreviewController.shared.hide()
                return
            }

            if settings.audioTrimmingEnabled,
               let trimmedURL = AudioAnalysisService.shared.trimLeadingTrailingNoise(
                   audioFileURL: audioURL,
                   thresholdDB: settings.audioThresholdDB,
                   leadingMarginSeconds: 0.60
               ) {
                try? FileManager.default.removeItem(at: audioURL)
                targetAudioURL = trimmedURL
            }
        }

        phase = .refining
        statusMessage = "AI回答生成中..."

        let currentProvider = settings.selectedProvider
        let currentConfig = settings.config(for: currentProvider)
        let apiKey = keychain.loadAPIKey(for: currentProvider)
        let language = settings.language.isEmpty ? nil : settings.language

        processingTask?.cancel()
        let taskToken = UUID()
        processingTaskToken = taskToken
        processingTask = Task { @MainActor [weak self] in
            guard let self = self else {
                try? FileManager.default.removeItem(at: targetAudioURL)
                return
            }
            defer {
                try? FileManager.default.removeItem(at: targetAudioURL)
                if self.processingTaskToken == taskToken {
                    self.processingTask = nil
                    self.processingTaskToken = nil
                }
            }

            do {
                // 1. パイプラインの最終確定テキスト（Whisperで即座にプレビューへ表示されたテキスト）を優先取得
                var trimmedQuestion = ""
                await withCheckedContinuation { continuation in
                    StreamingChunkPipelineService.shared.finishAndFinalize { pipelineText in
                        trimmedQuestion = pipelineText.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume()
                    }
                }

                // パイプラインが空だった場合のフォールバック（一括transcribe）
                if trimmedQuestion.isEmpty {
                    let questionText = try await self.api.transcribe(
                        audioFileURL: targetAudioURL,
                        baseURL: currentConfig.baseURL,
                        apiKey: apiKey,
                        model: currentConfig.modelName,
                        mode: .transcriptions,
                        prompt: "質問です。日本語で質問します。",
                        language: language
                    )
                    trimmedQuestion = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                // ユーザー辞書・音声記号置換を適用（「教えて、はてなマーク」➔「教えて？」等）
                trimmedQuestion = self.dictionary.apply(
                    text: LLMService.normalizePunctuation(for: trimmedQuestion),
                    rules: self.settings.dictionaryRules
                )

                guard !trimmedQuestion.isEmpty else {
                    self.isQuickAskActive = false
                    self.phase = .idle
                    self.statusMessage = "質問が聞き取れませんでした。"
                    FloatingPreviewController.shared.hide()
                    return
                }

                // ＋キーによる固定（質問送信前の修正モード）が有効な場合
                if FloatingPreviewController.shared.isPinned {
                    FloatingPreviewController.shared.showQuickAskQuestionForEditing(question: trimmedQuestion) { [weak self] editedQuestion in
                        Task { @MainActor [weak self] in
                            await self?.processQuickAskQuestion(editedQuestion)
                        }
                    }
                    self.phase = .idle
                    self.statusMessage = "AI質問修正中: ⌘↩で送信"
                    NSLog("[VoiceIME] 🟣 ＋キー固定モードのためAI質問送信を保留し修正モードに移行: %d文字", trimmedQuestion.count)
                    return
                }

                await self.processQuickAskQuestion(trimmedQuestion)
            } catch {
                self.isQuickAskActive = false
                self.phase = .idle
                self.statusMessage = "AI質問エラー: \(error.localizedDescription)"
                FloatingPreviewController.shared.show(text: "[回答エラー: \(error.localizedDescription)]", notice: "Esc で閉じる", mode: .quickAsk)
                SystemLogger.shared.logError("クイック質問エラー", error: error)
                NSLog("[VoiceIME] ❌ クイック質問エラー: %@", error.localizedDescription)
            }
        }
    }

    /// 確定または修正された質問を AI へ送信し、回答を取得・表示
    public func processQuickAskQuestion(_ question: String) async {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            isQuickAskActive = false
            phase = .idle
            FloatingPreviewController.shared.hide()
            return
        }

        let quickAskConfig = settings.effectiveQuickAskConfig
        let quickAskApiKey = keychain.loadAPIKey(for: quickAskConfig.provider)

        FloatingPreviewController.shared.updateLiveText(trimmedQuestion)
        FloatingPreviewController.shared.setProcessing(mode: .quickAsk)
        phase = .refining
        statusMessage = "AI回答生成中..."
        NSLog("[VoiceIME] 🟣 AIクイック質問 送信開始 (%d文字) 送信先: [%@] モデル: [%@]", trimmedQuestion.count, quickAskConfig.baseURL, quickAskConfig.modelName)

        do {
            let answer = try await self.llm.quickAsk(
                question: trimmedQuestion,
                history: self.quickAskHistory,
                baseURL: quickAskConfig.baseURL,
                apiKey: quickAskApiKey,
                model: quickAskConfig.modelName,
                isCustom: quickAskConfig.isCustom
            )

            // 会話履歴を更新（連続質問用）
            self.quickAskHistory.append(LLMService.ChatMessage(role: "user", content: trimmedQuestion))
            self.quickAskHistory.append(LLMService.ChatMessage(role: "assistant", content: answer))
            while self.quickAskHistory.count > 20 {
                self.quickAskHistory.removeFirst()
            }

            self.lastProcessedText = answer
            self.phase = .idle
            self.isQuickAskActive = false
            self.statusMessage = "AI回答完了: \(answer)"

            // ユーザー要望「質問を削除し、答えだけにしてほしい」
            let notice = "\(self.settings.pasteShortcutDisplayString) で挿入 / \(self.settings.quickAskHotkeyDisplayString) で続けて質問"
            FloatingPreviewController.shared.show(text: answer, notice: notice, mode: .quickAsk)

            // 一時クリップボードにもセット（即座に手動⌘Vも可能）
            FloatingPreviewController.shared.setTemporaryClipboard(text: answer, duration: 45.0)

            NSLog("[VoiceIME] 🟣 AIクイック回答完了 (%d文字)", answer.count)
        } catch {
            self.isQuickAskActive = false
            self.phase = .idle
            self.statusMessage = "AI質問エラー: \(error.localizedDescription)"
            FloatingPreviewController.shared.show(text: "[回答エラー: \(error.localizedDescription)]", notice: "Esc で閉じる", mode: .quickAsk)
            SystemLogger.shared.logError("AIクイック回答取得エラー", error: error)
            NSLog("[VoiceIME] ❌ クイック質問エラー: %@", error.localizedDescription)
        }
    }

    /// 録音開始
    public func startRecording() {
        // 通常の音声入力開始時は確実にクイック質問フラグおよび一時停止フラグを解除
        self.isQuickAskActive = false
        self.isRecordingPaused = false

        // マイクレベルテストが実行中の場合は停止して競合を防止
        if MicrophoneLevelTester.shared.isTesting {
            MicrophoneLevelTester.shared.stopTesting()
        }

        if !permissions.isMicrophoneAuthorized {
            permissions.checkPermissions()
        }
        guard permissions.isMicrophoneAuthorized else {
            phase = .error("マイクへのアクセス権限が必要です。")
            statusMessage = "マイク権限エラー"
            permissions.requestMicrophoneAccess()
            return
        }

        // 🌟 0. 何よりも最優先でマイク音声キャプチャをオンデマンド即座起動！
        // （待機中はセキュリティ保護のためマイク完全OFF。ホットキー押下時のみ起動）
        phase = .recording
        recordingStartTime = Date()
        StreamingChunkPipelineService.shared.prepareImmediateCapture(
            speechThresholdDB: settings.audioThresholdDB,
            isStreamingTriggerEnabled: true
        )
        let micStarted = LiveSpeechService.shared.startImmediateCapture()
        let recorderStarted = (try? recorder.startRecording()) != nil

        guard micStarted || recorderStarted else {
            phase = .error("録音の開始に失敗しました。")
            statusMessage = "録音の開始に失敗しました。"
            errorMessage = "マイク入力の初期化に失敗しました。"
            SystemLogger.shared.logError("音声入力 録音開始失敗: マイク入力初期化エラー")
            NSLog("[VoiceIME] ❌ 録音開始失敗")
            return
        }

        PipelineLogger.shared.logSessionStart()
        statusMessage = settings.triggerMode == .pushToTalk ? "録音中... (キーを離すと入力)" : "録音中... (もう一度キーを押して停止)"
        errorMessage = nil
        NSLog("[VoiceIME] 🎤 録音開始 (動作モード: %@, 即時キャプチャ完了)", settings.triggerMode.rawValue)

        // 🌟 1. ストリーミングパイプラインの設定反映とマイクタップ認識の接続
        let currentProvider = settings.selectedProvider
        let currentConfig = settings.config(for: currentProvider)
        let currentLLMConfig = settings.effectiveLLMConfig
        let resolvedLLMProvider = settings.resolvedLLMProvider
        let llmApiKey = keychain.loadAPIKey(for: resolvedLLMProvider)
        let apiKey = keychain.loadAPIKey(for: currentProvider)

        let effectiveLanguage = settings.language.isEmpty ? "ja" : settings.language
        let isLLM = settings.isLLMRefinementActive
        let prompt: String?
        if let custom = settings.promptHint.isEmpty ? nil : settings.promptHint {
            prompt = custom
        } else if effectiveLanguage == "ja" {
            // 主語や冒頭の語句がWhisperによって脱落するのを防ぐ自然な日本語文頭コンテキスト
            prompt = isLLM ? (settings.refinementStyle == .casual ? "私は、本日の件についてお話しします。そうですね、承知いたしました。" : "本日は、本件についてご報告いたします。よろしくお願いいたします。") : "日本語の音声入力です。文頭の主語や言葉を正確にそのまま文字起こしします。"
        } else {
            prompt = nil
        }

        StreamingChunkPipelineService.shared.start(
            whisperConfig: (baseURL: currentConfig.baseURL, apiKey: apiKey, model: currentConfig.modelName),
            llmConfig: (baseURL: currentLLMConfig.baseURL, apiKey: llmApiKey, model: currentLLMConfig.modelName, isCustom: currentLLMConfig.isCustom),
            style: settings.refinementStyle,
            isLLMEnabled: isLLM,
            whisperPrompt: prompt,
            language: effectiveLanguage,
            speechThresholdDB: settings.audioThresholdDB
        )

        // マイクタップ（LiveSpeechService）の認識タスクを接続
        LiveSpeechService.shared.startLiveRecognition(
            languageCode: settings.language,
            contextualStrings: []
        ) { _ in
            // Apple Speech のフェイク推論は画面に出さず、Whisperから戻ってきた本物の結果のみを表示する
        }

        // 🌟 2. マイクが完全に回り出した後に、直前アプリ記録と UI（フローティングウィンドウ）表示を行う
        FloatingPreviewController.shared.recordFrontmostApp()
        if settings.floatingPreviewEnabled {
            FloatingPreviewController.shared.showLiveRecording()
        } else {
            FloatingPreviewController.shared.hide()
        }

        // 最大録音時間セーフティ（Push-to-Talk・トグル共に120秒＝2分間。長文音声入力での強制切断を完全防止）
        let maxDuration: TimeInterval = 120.0
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = Timer.scheduledTimer(withTimeInterval: maxDuration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.phase == .recording {
                    NSLog("[VoiceIME] ⏱️ 最大録音時間（%.0f秒）に達したため自動停止して文字起こしへ移行", maxDuration)
                    self?.stopRecordingAndTranscribe()
                }
            }
        }
    }

    /// 録音停止と文字起こし・AI推敲・自動ペースト処理
    public func stopRecordingAndTranscribe() {
        isRecordingPaused = false
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil

        let isJapanese: Bool
        if settings.language == "ja" {
            isJapanese = true
        } else if settings.language.lowercased().starts(with: "en") {
            isJapanese = false
        } else {
            isJapanese = true
        }

        // リアルタイム音声取得を停止
        LiveSpeechService.shared.stopLiveRecognition()

        if settings.floatingPreviewEnabled {
            FloatingPreviewController.shared.setProcessing()
        }

        let recorderURL = recorder.stopRecording()
        let pipelineWAVURL = StreamingChunkPipelineService.shared.exportFullAudioWAV()
        if let _ = pipelineWAVURL, let recURL = recorderURL {
            try? FileManager.default.removeItem(at: recURL)
        }

        guard let audioURL = pipelineWAVURL ?? recorderURL else {
            phase = .idle
            statusMessage = "録音データがありません。"
            if settings.floatingPreviewEnabled {
                FloatingPreviewController.shared.hide()
            }
            NSLog("[VoiceIME] ⚠️ 録音停止: 音声データが存在しません")
            return
        }

        NSLog("[VoiceIME] ⏹️ 録音停止 (しきい値: %.1f dB, 有効: %d)", settings.audioThresholdDB, settings.audioThresholdEnabled ? 1 : 0)

        // ==========================================
        // 0. 音声解析および無音・環境雑音判定
        // ==========================================
        let metrics = AudioAnalysisService.shared.analyze(
            audioFileURL: audioURL,
            thresholdDB: settings.audioThresholdDB
        )

        // A. 絶対的な無音判定（ユーザー設定に関わらず、完全な無音・打鍵ノイズ・誤操作はWhisperに送らない）
        if metrics.isSilence {
            NSLog("[VoiceIME] 🔇 無音検知: Whisper送信をスキップしました (maxRMS: %.1f dB, peak: %.1f dB, 可聴時間: %.2f秒, 録音長: %.2f秒)",
                  metrics.maxWindowRMS_DB, metrics.peakPowerDB, metrics.audibleDurationSeconds, metrics.totalDurationSeconds)
            try? FileManager.default.removeItem(at: audioURL)
            self.phase = .idle
            self.statusMessage = "無音のため送信をスキップしました"
            if self.settings.floatingPreviewEnabled {
                FloatingPreviewController.shared.hide()
            }
            return
        }

        // B. ユーザー設定のしきい値判定
        var targetAudioURL = audioURL
        if settings.audioThresholdEnabled {
            if !metrics.hasSpeech {
                NSLog("[VoiceIME] 音声除外: 音量レベルがしきい値未満 (maxRMS: %.1f dB, peak: %.1f dB, しきい値: %.1f dB)",
                      metrics.maxWindowRMS_DB, metrics.peakPowerDB, settings.audioThresholdDB)
                try? FileManager.default.removeItem(at: audioURL)
                self.phase = .idle
                self.statusMessage = "小さな音を検知したため無視しました"
                if self.settings.floatingPreviewEnabled {
                    FloatingPreviewController.shared.hide()
                }
                return
            }

            // 発話前後の無音・微小音トリミング
            if settings.audioTrimmingEnabled,
               let trimmedURL = AudioAnalysisService.shared.trimLeadingTrailingNoise(
                   audioFileURL: audioURL,
                   thresholdDB: settings.audioThresholdDB,
                   leadingMarginSeconds: 0.60
               ) {
                try? FileManager.default.removeItem(at: audioURL)
                targetAudioURL = trimmedURL
            }
        }

        phase = .transcribing
        statusMessage = settings.apiMode == .translations ? "英語翻訳中..." : "文字起こし中..."

        StreamingChunkPipelineService.shared.finishAndFinalize { [weak self] pipelineText in
            Task { @MainActor [weak self] in
                guard let self = self else {
                    try? FileManager.default.removeItem(at: targetAudioURL)
                    return
                }
                try? FileManager.default.removeItem(at: targetAudioURL)
                let clean = pipelineText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    self.finalizeAndPaste(
                        text: clean,
                        livePreviewText: clean,
                        isJapanese: isJapanese,
                        totalStartTime: CFAbsoluteTimeGetCurrent(),
                        fallbackNotices: []
                    )
                } else {
                    self.phase = .idle
                    self.statusMessage = "音声が認識できませんでした。"
                    if self.settings.floatingPreviewEnabled {
                        FloatingPreviewController.shared.hide()
                    }
                    NSLog("[VoiceIME] ⚠️ 音声認識テキストが空のため入力をキャンセル")
                }
            }
        }
    }

    /// 録音を中断・破棄
    public func cancelRecording() {
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil

        // 進行中の文字起こし処理があればキャンセル（URLSession の await も中断される）
        processingTask?.cancel()
        LiveSpeechService.shared.stopLiveRecognition()
        FloatingPreviewController.shared.hide()

        recorder.cancelRecording()
        StreamingChunkPipelineService.shared.cancel()
        isQuickAskActive = false
        isRecordingPaused = false
        phase = .idle
        statusMessage = "録音をキャンセルしました。"
    }

    /// エラーから要約表示用の理由と詳細メッセージを抽出
    public func extractErrorSummary(_ error: Error) -> (summary: String, detail: String) {
        if let apiError = error as? WhisperAPIService.APIError {
            let detail = apiError.errorDescription ?? error.localizedDescription
            return (apiError.summary, detail)
        }
        if let llmError = error as? LLMService.LLMError {
            let detail = llmError.errorDescription ?? error.localizedDescription
            return (llmError.summary, detail)
        }
        if let urlError = error as? URLError {
            if urlError.code == .timedOut {
                return ("タイムアウト (応答なし)", "リクエストがタイムアウトしました。")
            }
            return ("通信エラー", urlError.localizedDescription)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            return ("タイムアウト (応答なし)", "リクエストがタイムアウトしました。")
        }
        return ("エラー", error.localizedDescription)
    }

    /// アプリ更新後や初回起動時に、macOSのキーチェーンアクセス認証について親切に事前案内する
    @MainActor
    public func promptKeychainWarmupIfNeeded() {
        guard keychain.hasAnyAPIKey() else { return }

        let currentModDate = fetchExecutableModificationTimestamp()
        let lastModDate = UserDefaults.standard.string(forKey: "voiceime_last_executable_mod_date")

        let isRecompiledOrNew = (lastModDate == nil || lastModDate != currentModDate)

        if isRecompiledOrNew {
            let alert = NSAlert()
            alert.messageText = "VoiceIME: macOS キーチェーン認証のご案内"
            alert.informativeText = """
VoiceIME は、登録された APIキー（Groq / OpenAI / カスタムLLM）を安全に暗号化保護するため、macOSのキーチェーンを使用しています。

アプリの更新・起動に伴い、この直後に macOS のシステムダイアログが表示されます。

【入力するパスワード】
お手元の Mac のログインパスワード（画面ロック解除用パスワード）を入力してください。

【推奨する選択】
『常に許可』を選択いただくと、今後の起動時や音声入力時にパスワード入力を省略できます。
"""
            alert.alertStyle = .informational
            alert.addButton(withTitle: "了解して認証へ進む")
            alert.window.level = .floating
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()

            UserDefaults.standard.set(currentModDate, forKey: "voiceime_last_executable_mod_date")
        }

        // 事前認証を実行（OSのダイアログが表示される）
        keychain.warmUp()
    }

    /// 実行可能バイナリの最終更新日時文字列を取得
    private func fetchExecutableModificationTimestamp() -> String {
        guard let exePath = Bundle.main.executablePath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: exePath),
              let modDate = attrs[.modificationDate] as? Date else {
            return "\(Date().timeIntervalSince1970)"
        }
        return "\(modDate.timeIntervalSince1970)"
    }

    /// 確定テキストの最終整形（辞書適用・正規化）と対象アプリへのペースト
    public func finalizeAndPaste(
        text: String,
        livePreviewText: String = "",
        isJapanese: Bool,
        totalStartTime: CFAbsoluteTime,
        fallbackNotices: [String] = []
    ) {
        let alignedText: String
        if self.settings.isLLMRefinementActive {
            // LLM推敲有効時は、LLMが文脈に基づいて配置した句読点や語尾表現を機械的な正規表現で再分割しないよう保護
            alignedText = PunctuationService.shared.formatVoiceCommandsAndDictionaryOnly(
                text: text,
                isJapanese: isJapanese
            )
        } else {
            alignedText = PunctuationService.shared.alignPunctuation(
                text: text,
                referenceLiveText: livePreviewText,
                isJapanese: isJapanese
            )
        }
        let normalizedText = LLMService.normalizePunctuation(for: alignedText)
        let processedText = self.dictionary.apply(
            text: normalizedText,
            rules: self.settings.dictionaryRules
        )
        self.lastProcessedText = processedText

        if self.settings.floatingPreviewEnabled {
            FloatingPreviewController.shared.updateConfirmedText(processedText)
        }

        let totalElapsed = CFAbsoluteTimeGetCurrent() - totalStartTime
        let timeStr = String(format: "%.1f秒", totalElapsed)
        let completionNotice = fallbackNotices.isEmpty ? "" : " " + fallbackNotices.joined(separator: " ")
        let completionMessage = "完了 (\(timeStr))" + completionNotice

        let focusState = FocusDetectionService.shared.checkCurrentFocus()
        NSLog("[VoiceIME] 🎯 フォーカス状態判定: %@", focusState.description)

        // ＋キーによる固定（消えないように維持・修正モード）が有効な場合
        if FloatingPreviewController.shared.isPinned {
            let tempDuration = self.settings.floatingPreviewDuration > 0 ? min(self.settings.floatingPreviewDuration, 45.0) : 45.0
            FloatingPreviewController.shared.setTemporaryClipboard(text: processedText, duration: tempDuration)
            if self.settings.floatingPreviewEnabled {
                let minusHint = self.settings.correctionStockEnabled ? " / - で単語登録" : ""
                FloatingPreviewController.shared.show(
                    text: processedText,
                    notice: "修正可能 ➔\(minusHint) + で閉じる / \(self.settings.pasteShortcutDisplayString) で挿入"
                )
                FloatingPreviewController.shared.activateAndFocusForEditing()
            }
            self.phase = .idle
            self.statusMessage = "\(completionMessage) [修正モード: +で閉じる]"
            NSLog("[VoiceIME] 📌 ＋キー固定モードのため自動ペーストを保留し編集・修正可能にしました")
            return
        }

        switch focusState {
        case .editableText(let role, let detail):
            if self.settings.autoPasteEnabled {
                NSLog("[VoiceIME] 🚀 確実な入力欄へ自動ペースト準備 (\(role): \(detail)): %d文字", processedText.count)
                performAutoPaste(text: processedText, completionMessage: completionMessage, autoHidePreview: true)
            } else {
                if self.settings.floatingPreviewEnabled {
                    FloatingPreviewController.shared.show(text: processedText, notice: "入力先を選択 ➔ \(self.settings.pasteShortcutDisplayString)")
                }
                self.phase = .idle
                self.statusMessage = completionMessage + " [\(self.settings.pasteShortcutDisplayString)で入力]"
            }

        case .notEditable(let role, let detail):
            let tempDuration = self.settings.floatingPreviewDuration > 0 ? min(self.settings.floatingPreviewDuration, 45.0) : 45.0
            FloatingPreviewController.shared.setTemporaryClipboard(text: processedText, duration: tempDuration)
            if self.settings.floatingPreviewEnabled {
                FloatingPreviewController.shared.show(text: processedText, notice: "45秒間コピー有効: ⌘V または \(self.settings.pasteShortcutDisplayString)")
            }
            if self.settings.autoPasteEnabled {
                // Webブラウザ（AXWebArea）や独自UIでAXがnotEditableと誤判定した場合でも、ユーザーの自動ペースト希望を尊重してペースト試行
                NSLog("[VoiceIME] 🚀 非入力判定（\(role): \(detail)）だがWeb/独自入力欄の可能性があるためペースト試行＋ウィンドウ保留: %d文字", processedText.count)
                performAutoPaste(text: processedText, completionMessage: completionMessage, autoHidePreview: false)
            } else {
                self.phase = .idle
                self.statusMessage = "\(completionMessage) [45秒限定コピー: ⌘V/\(self.settings.pasteShortcutDisplayString)で入力]"
                NSLog("[VoiceIME] ⚠️ 非入力要素（\(role): \(detail)）を検出。45秒限定でクリップボードに退避しウィンドウを残します")
            }

        case .ambiguous(let role, let detail):
            let tempDuration = self.settings.floatingPreviewDuration > 0 ? min(self.settings.floatingPreviewDuration, 45.0) : 45.0
            FloatingPreviewController.shared.setTemporaryClipboard(text: processedText, duration: tempDuration)
            if self.settings.floatingPreviewEnabled {
                FloatingPreviewController.shared.show(text: processedText, notice: "45秒間コピー有効: ⌘V または \(self.settings.pasteShortcutDisplayString)")
            }
            if self.settings.autoPasteEnabled {
                NSLog("[VoiceIME] 🚀 判定微妙（\(role): \(detail)）のためペースト試行＋ウィンドウ保留: %d文字", processedText.count)
                performAutoPaste(text: processedText, completionMessage: completionMessage, autoHidePreview: false)
            } else {
                self.phase = .idle
                self.statusMessage = "\(completionMessage) [45秒限定コピー: ⌘V/\(self.settings.pasteShortcutDisplayString)で入力]"
            }
        }
    }

    /// ターゲット作業アプリのフォーカスを安定化させ、確実に自動ペーストを実行
    private func performAutoPaste(
        text: String,
        completionMessage: String,
        autoHidePreview: Bool
    ) {
        self.phase = .pasting
        self.statusMessage = "入力中..."

        // 確定テキスト（推敲・辞書適用後の最終結果）を画面にハッキリと描画し、
        // ユーザーが目視確認できる表示猶予（LLM推敲時は0.22秒、通常は0.05秒）を設けてからペーストを実行
        let pasteDelay: Double = self.settings.isLLMRefinementActive ? 0.22 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) { [weak self] in
            guard let self = self else { return }
            // 直前アプリをアクティブ化し、フォーカスが確実に安定（120ms）してからペーストを実行
            FloatingPreviewController.shared.activateTargetAppIfNeeded { [weak self] in
                guard let self = self else { return }
                self.paster.paste(text: text, restoreClipboard: self.settings.restoreClipboard) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.phase = .idle
                        self.statusMessage = completionMessage
                        if autoHidePreview && self.settings.floatingPreviewEnabled {
                            // ウィンドウに表示された最終文字列（語尾まで含む）とペーストされた文字列が100%一致していることを
                            // ユーザーがしっかり目視確認できるよう、自動ペースト完了後も2.5秒間ウィンドウを表示維持する
                            FloatingPreviewController.shared.customNotice = "✅ 自動入力完了 (+で維持)"
                            FloatingPreviewController.shared.hideWithDelay(seconds: 2.5)
                            NSLog("[VoiceIME] ✅ 入力完了・プレビューウィンドウ消去予約 (目視確認余韻2.5s)")
                        } else {
                            NSLog("[VoiceIME] ✅ ペースト試行完了（ウィンドウは保留維持）")
                        }
                    }
                }
            }
        }
    }
}
