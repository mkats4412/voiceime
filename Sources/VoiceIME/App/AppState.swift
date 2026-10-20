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

    private init() {
        setupHotkey()
        setupModifierKeyMonitors()
    }

    deinit {
        if let m = modifierKeyMonitorLocal { NSEvent.removeMonitor(m) }
        if let m = modifierKeyMonitorGlobal { NSEvent.removeMonitor(m) }
    }

    /// クイック質問用修飾キー（例: Ctrl+Shift）の押下・離脱を監視
    private func setupModifierKeyMonitors() {
        let handleFlagsChanged: (NSEvent) -> Void = { [weak self] event in
            guard let self = self else { return }
            let requiredCarbonMods = self.settings.quickAskHotkeyModifiers
            let isHolding = self.matchesModifiers(event.modifierFlags, carbonModifiers: requiredCarbonMods)

            // 修飾キーが完全に離された場合、次回は新しい会話としてリセット
            if !isHolding {
                self.isQuickAskModifierHeld = false
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
                Task { @MainActor in
                    self?.handleHotKeyDown()
                }
            },
            onKeyUp: { [weak self] in
                Task { @MainActor in
                    self?.handleHotKeyUp()
                }
            }
        )

        // 2. AI クイック質問ホットキー
        hotkey.register(
            type: .quickAsk,
            keyCode: settings.quickAskHotkeyCode,
            modifiers: settings.quickAskHotkeyModifiers,
            onKeyDown: { [weak self] in
                Task { @MainActor in
                    self?.handleQuickAskKeyDown()
                }
            },
            onKeyUp: { [weak self] in
                Task { @MainActor in
                    self?.handleQuickAskKeyUp()
                }
            }
        )
    }

    /// ホットキーが押されたときのハンドラ
    public func handleHotKeyDown() {
        if settings.triggerMode == .pushToTalk {
            if phase == .idle || isErrorPhase() {
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
                // 誤タップ（0.15秒未満）の誤動作ガード
                if let startTime = recordingStartTime, Date().timeIntervalSince(startTime) < 0.15 {
                    cancelRecording()
                    return
                }
                // キーを離した瞬間に視覚的フィードバック（処理中アニメーション）を即座に開始
                if settings.floatingPreviewEnabled {
                    FloatingPreviewController.shared.setProcessing(mode: .speechInput)
                }
                // 発話末尾の単語・語尾・余韻（「〜でしょう」「〜出ている」「〜ですよね」等）がマイクバッファから欠落するのを防ぐため、
                // キー離脱から約420ms遅延させて録音を停止する
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
                    guard let self = self, self.phase == .recording, !self.isQuickAskActive else { return }
                    self.stopRecordingAndTranscribe()
                }
            }
        }
    }

    /// AIクイック質問ホットキー押下時
    public func handleQuickAskKeyDown() {
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
            // 誤タップガード
            if let startTime = recordingStartTime, Date().timeIntervalSince(startTime) < 0.15 {
                cancelRecording()
                return
            }

            FloatingPreviewController.shared.setProcessing(mode: .quickAsk)

            // 音声末尾の欠落防止のため約200ms遅延して停止・質問処理
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                guard let self = self, self.isQuickAskActive, self.phase == .recording else { return }
                self.stopQuickAskAndProcess()
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

    // MARK: - AI クイック質問 (Quick Ask) 録音・処理フロー

    /// AIクイック質問の録音開始
    public func startQuickAskRecording() {
        MicrophoneLevelTester.shared.stopTesting()
        FloatingPreviewController.shared.hide()

        permissions.checkPermissions()
        guard permissions.isMicrophoneAuthorized else {
            phase = .error("マイクへのアクセス権限が必要です。")
            statusMessage = "マイク権限エラー"
            permissions.requestMicrophoneAccess()
            return
        }

        do {
            _ = try recorder.startRecording()
            isQuickAskActive = true
            phase = .recording
            statusMessage = "AI質問中... (キーを離すと回答)"
            errorMessage = nil
            recordingStartTime = Date()
            NSLog("[VoiceIME] 🟣 AIクイック質問 録音開始")

            FloatingPreviewController.shared.showLiveRecording(mode: .quickAsk)

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

            maxRecordingTimer?.invalidate()
            maxRecordingTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    if self?.isQuickAskActive == true && self?.phase == .recording {
                        self?.stopQuickAskAndProcess()
                    }
                }
            }
        } catch {
            isQuickAskActive = false
            phase = .error(error.localizedDescription)
            statusMessage = "録音開始に失敗しました。"
            errorMessage = error.localizedDescription
            NSLog("[VoiceIME] ❌ クイック質問 録音開始失敗: %@", error.localizedDescription)
        }
    }

    /// AIクイック質問の録音停止・認識・回答生成処理
    public func stopQuickAskAndProcess() {
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil

        LiveSpeechService.shared.stopLiveRecognition()
        FloatingPreviewController.shared.setProcessing(mode: .quickAsk)

        guard let audioURL = recorder.stopRecording() else {
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
                   thresholdDB: settings.audioThresholdDB
               ) {
                try? FileManager.default.removeItem(at: audioURL)
                targetAudioURL = trimmedURL
            }
        }

        phase = .refining
        statusMessage = "AI回答生成中..."

        let currentProvider = settings.selectedProvider
        let currentConfig = settings.config(for: currentProvider)
        let quickAskConfig = settings.effectiveQuickAskConfig
        let quickAskApiKey = keychain.loadAPIKey(for: quickAskConfig.provider)
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

                // 確定した質問をプレビュー上に表示し、AI回答取得中を表示
                FloatingPreviewController.shared.updateLiveText(trimmedQuestion)
                FloatingPreviewController.shared.setProcessing(mode: .quickAsk)

                NSLog("[VoiceIME] 🟣 AIクイック質問 認識結果: [%@] 送信先: [%@] モデル: [%@]", trimmedQuestion, quickAskConfig.baseURL, quickAskConfig.modelName)

                // 2. AIへ質問送信
                let answer = try await self.llm.quickAsk(
                    question: trimmedQuestion,
                    history: self.quickAskHistory,
                    baseURL: quickAskConfig.baseURL,
                    apiKey: quickAskApiKey,
                    model: quickAskConfig.modelName,
                    isCustom: quickAskConfig.isCustom
                )

                // 3. 会話履歴を更新（連続質問用）
                self.quickAskHistory.append(LLMService.ChatMessage(role: "user", content: trimmedQuestion))
                self.quickAskHistory.append(LLMService.ChatMessage(role: "assistant", content: answer))
                while self.quickAskHistory.count > 20 {
                    self.quickAskHistory.removeFirst()
                }

                self.lastProcessedText = answer
                self.phase = .idle
                self.statusMessage = "AI回答完了: \(answer)"

                // 4. 重要: ユーザー要望「質問を削除し、答えだけにしてほしい」
                let notice = "\(self.settings.pasteShortcutDisplayString) で挿入 / \(self.settings.quickAskHotkeyDisplayString) で続けて質問"
                FloatingPreviewController.shared.show(text: answer, notice: notice, mode: .quickAsk)

                // 一時クリップボードにもセット（即座に手動⌘Vも可能）
                FloatingPreviewController.shared.setTemporaryClipboard(text: answer, duration: 45.0)

                NSLog("[VoiceIME] 🟣 AIクイック回答完了: [%@]", answer)
            } catch {
                self.isQuickAskActive = false
                self.phase = .idle
                self.statusMessage = "AI質問エラー: \(error.localizedDescription)"
                FloatingPreviewController.shared.show(text: "[回答エラー: \(error.localizedDescription)]", notice: "Esc で閉じる", mode: .quickAsk)
                NSLog("[VoiceIME] ❌ クイック質問エラー: %@", error.localizedDescription)
            }
        }
    }

    /// 録音開始
    public func startRecording() {
        // マイクレベルテストが実行中の場合は停止して競合を防止
        MicrophoneLevelTester.shared.stopTesting()
        FloatingPreviewController.shared.hide()

        permissions.checkPermissions()
        guard permissions.isMicrophoneAuthorized else {
            phase = .error("マイクへのアクセス権限が必要です。")
            statusMessage = "マイク権限エラー"
            permissions.requestMicrophoneAccess()
            return
        }

        do {
            _ = try recorder.startRecording()
            phase = .recording
            PipelineLogger.shared.logSessionStart()
            statusMessage = settings.triggerMode == .pushToTalk ? "録音中... (キーを離すと入力)" : "録音中... (もう一度キーを押して停止)"
            errorMessage = nil
            NSLog("[VoiceIME] 🎤 録音開始 (動作モード: %@, 一括送信: %d)", settings.triggerMode.rawValue, settings.batchTranscriptionEnabled ? 1 : 0)

            // 一括送信がOFF（累積紙芝居ストリーミングモード）の場合、パイプラインを開始
            if !settings.batchTranscriptionEnabled {
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
                    prompt = isLLM ? (settings.refinementStyle == .casual ? "こんにちは。そうですね、承知いたしました。" : "こんにちは。本件について報告いたします。") : "日本語の音声入力です。話された言葉を正確にそのまま文字起こしします。"
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
            }
            if settings.floatingPreviewEnabled {
                FloatingPreviewController.shared.showLiveRecording()

                var contextWords: [String] = []
                if settings.refinementStyle == .casual {
                    contextWords.append(contentsOf: ["えーっと", "あのー", "ええと", "うーん", "まあ", "えっと", "あの"])
                }
                for rule in settings.dictionaryRules where !rule.isRegex {
                    let w = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !w.isEmpty && !contextWords.contains(w) {
                        contextWords.append(w)
                    }
                }

                LiveSpeechService.shared.startLiveRecognition(
                    languageCode: settings.language,
                    contextualStrings: contextWords
                ) { _ in
                    // Apple Speech のフェイク推論は画面に出さず、Whisperから戻ってきた本物の結果のみを表示する
                }
            }

            // 最大録音時間セーフティ（最長120秒で自動カットオフし暴走を防止）
            maxRecordingTimer?.invalidate()
            maxRecordingTimer = Timer.scheduledTimer(withTimeInterval: 120.0, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    if self?.phase == .recording {
                        self?.stopRecordingAndTranscribe()
                    }
                }
            }
        } catch {
            phase = .error(error.localizedDescription)
            statusMessage = "録音の開始に失敗しました。"
            errorMessage = error.localizedDescription
            NSLog("[VoiceIME] ❌ 録音開始失敗: %@", error.localizedDescription)
        }
    }

    /// 録音停止と文字起こし・AI推敲・自動ペースト処理
    public func stopRecordingAndTranscribe() {
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

        // 画面のテキストは Whisper から戻ってきた本物の最新テキストを採用
        let livePreviewText = StreamingChunkPipelineService.shared.latestRefinedText

        if settings.floatingPreviewEnabled {
            FloatingPreviewController.shared.setProcessing()
        }

        guard let audioURL = recorder.stopRecording() else {
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
                   thresholdDB: settings.audioThresholdDB
               ) {
                try? FileManager.default.removeItem(at: audioURL)
                targetAudioURL = trimmedURL
            }
        }

        let mode = settings.apiMode
        phase = .transcribing
        statusMessage = mode == .translations ? "英語翻訳中..." : "文字起こし中..."

        let currentProvider = settings.selectedProvider
        let currentConfig = settings.config(for: currentProvider)
        let currentLLMConfig = settings.effectiveLLMConfig
        let resolvedLLMProvider = settings.resolvedLLMProvider
        let llmApiKey = keychain.loadAPIKey(for: resolvedLLMProvider)
        let llmProviderDisplayName = settings.effectiveLLMProviderDisplayName
        let apiKey = keychain.loadAPIKey(for: currentProvider)
        let baseURL = currentConfig.baseURL
        let model = currentConfig.modelName
        let prompt = settings.promptHint.isEmpty ? nil : settings.promptHint
        let language = settings.language.isEmpty ? "ja" : settings.language

        let isLLMEnabled = settings.isLLMRefinementActive
        let refinementStyle = settings.refinementStyle

        // Whisper APIの初期プロンプト: 指定言語に応じた自然な句読点や語尾の脱落を防止
        let effectiveWhisperPrompt: String?
        if let customPrompt = prompt, !customPrompt.isEmpty {
            effectiveWhisperPrompt = customPrompt
        } else if language == "ja" {
            if !isLLMEnabled {
                // 推敲OFF時は、話者が発話した語尾（「〜でしょう」「〜ですね」「〜と思います」等）を1文字も変えずに忠実に書き起こすニュートラルなプロンプト
                effectiveWhisperPrompt = "日本語の音声入力です。話された言葉や語尾を正確に、自然な句読点を含めてそのまま文字起こしします。"
            } else {
                effectiveWhisperPrompt = (refinementStyle == .casual)
                    ? "こんにちは。そうですね、承知いたしました。〜ですね。〜ですよ。〜と言及した。"
                    : "こんにちは。本件について報告いたします。〜と言及した。〜である。"
            }
        } else if language == "en" {
            effectiveWhisperPrompt = "Hello. Yes, I understand. Thank you."
        } else {
            // 言語自動検出時は特定言語へのバイアスを避けるため nil
            effectiveWhisperPrompt = nil
        }

        if !settings.batchTranscriptionEnabled {
            // 分割逐次送信モード
            StreamingChunkPipelineService.shared.finishAndFinalize { [weak self] pipelineText in
                Task { @MainActor [weak self] in
                    guard let self = self else {
                        try? FileManager.default.removeItem(at: targetAudioURL)
                        return
                    }
                    let clean = pipelineText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        try? FileManager.default.removeItem(at: targetAudioURL)
                        self.finalizeAndPaste(
                            text: clean,
                            livePreviewText: isLLMEnabled ? clean : livePreviewText,
                            isJapanese: isJapanese,
                            totalStartTime: CFAbsoluteTimeGetCurrent(),
                            fallbackNotices: []
                        )
                        return
                    }
                    // パイプライン結果が空の場合は一括送信へフォールバック
                    self.executeBatchTranscriptionTask(
                        targetAudioURL: targetAudioURL,
                        mode: mode,
                        currentProvider: currentProvider,
                        currentConfig: currentConfig,
                        currentLLMConfig: currentLLMConfig,
                        resolvedLLMProvider: resolvedLLMProvider,
                        llmApiKey: llmApiKey,
                        llmProviderDisplayName: llmProviderDisplayName,
                        apiKey: apiKey,
                        baseURL: baseURL,
                        model: model,
                        effectiveWhisperPrompt: effectiveWhisperPrompt,
                        language: language,
                        isLLMEnabled: isLLMEnabled,
                        refinementStyle: refinementStyle,
                        livePreviewText: livePreviewText,
                        isJapanese: isJapanese
                    )
                }
            }
            return
        }

        // 一括送信モード（推奨・文脈高精度）
        executeBatchTranscriptionTask(
            targetAudioURL: targetAudioURL,
            mode: mode,
            currentProvider: currentProvider,
            currentConfig: currentConfig,
            currentLLMConfig: currentLLMConfig,
            resolvedLLMProvider: resolvedLLMProvider,
            llmApiKey: llmApiKey,
            llmProviderDisplayName: llmProviderDisplayName,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            effectiveWhisperPrompt: effectiveWhisperPrompt,
            language: language,
            isLLMEnabled: isLLMEnabled,
            refinementStyle: refinementStyle,
            livePreviewText: livePreviewText,
            isJapanese: isJapanese
        )
    }

    /// 録音された音声をまとめて一括送信して文字起こし・推敲を実行するメインパイプライン
    private func executeBatchTranscriptionTask(
        targetAudioURL: URL,
        mode: SpeechAPIMode,
        currentProvider: APIProvider,
        currentConfig: (baseURL: String, modelName: String),
        currentLLMConfig: (baseURL: String, modelName: String, isCustom: Bool),
        resolvedLLMProvider: APIProvider,
        llmApiKey: String?,
        llmProviderDisplayName: String,
        apiKey: String?,
        baseURL: String,
        model: String,
        effectiveWhisperPrompt: String?,
        language: String?,
        isLLMEnabled: Bool,
        refinementStyle: RefinementStyle,
        livePreviewText: String,
        isJapanese: Bool
    ) {
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

            let totalStartTime = CFAbsoluteTimeGetCurrent()
            var whisperDuration: Double = 0.0
            var llmDuration: Double = 0.0
            let prompt = self.settings.promptHint.isEmpty ? nil : self.settings.promptHint

            do {
                // ==========================================
                // 1. Whisper API にリクエスト送信（音声 ➔ テキスト）
                // ==========================================
                var rawText: String
                var fallbackNotices: [String] = []

                let whisperStart = CFAbsoluteTimeGetCurrent()
                // バックアッププロバイダが存在するか確認
                let backupProvider = self.settings.backupProvider
                let backupKey = backupProvider.flatMap { self.keychain.loadAPIKey(for: $0) }

                if let backup = backupProvider, let bKey = backupKey {
                    // =========================================================
                    // 🚀 ヘッジド・リクエスト (Hedged Requests / 時間差レーシング)
                    // =========================================================
                    // 1. まずメイン（Groq等）にリクエスト送信
                    // 2. 1.8秒経過しても応答がない場合、バックアップ（OpenAI等）にも並列で投げる
                    // 3. どちらか早く成功した方の結果を採用する
                    let backupConfig = self.settings.config(for: backup)
                    let hedgedDelayNanoseconds: UInt64 = 1_800_000_000 // 1.8秒

                    enum TranscribeWinner {
                        case primary(String)
                        case backup(String, FallbackRecord, primaryError: Error?)
                    }

                    enum TaskResult {
                        case success(TranscribeWinner)
                        case failure(Error, isPrimary: Bool)
                    }

                    do {
                        let winner = try await withThrowingTaskGroup(of: TaskResult.self) { group -> TranscribeWinner in
                            // タスク1: メインプロバイダ
                            group.addTask {
                                do {
                                    let res = try await self.api.transcribe(
                                        audioFileURL: targetAudioURL,
                                        baseURL: baseURL,
                                        apiKey: apiKey,
                                        model: model,
                                        mode: mode,
                                        prompt: effectiveWhisperPrompt,
                                        language: language
                                    )
                                    return .success(.primary(res))
                                } catch {
                                    return .failure(error, isPrimary: true)
                                }
                            }

                            // タスク2: 1.8秒ディレイ後にバックアップを発射（メインが早く終わればキャンセルされる）
                            group.addTask {
                                do {
                                    try await Task.sleep(nanoseconds: hedgedDelayNanoseconds)
                                    try Task.checkCancellation()

                                    await MainActor.run {
                                        self.statusMessage = "\(backup.displayName) で並列認識中 (応答遅延)..."
                                    }
                                    NSLog("[VoiceIME] ⚡️ メイン(%@)応答待ち1.8秒超過: バックアップ(%@)へ並行リクエスト発射", currentProvider.displayName, backup.displayName)

                                    let res = try await self.api.transcribe(
                                        audioFileURL: targetAudioURL,
                                        baseURL: backupConfig.baseURL,
                                        apiKey: bKey,
                                        model: backupConfig.modelName,
                                        mode: mode,
                                        prompt: effectiveWhisperPrompt,
                                        language: language
                                    )

                                    let record = FallbackRecord(
                                        timestamp: Date(),
                                        primaryProvider: currentProvider,
                                        backupProvider: backup,
                                        step: "音声認識",
                                        reasonSummary: "応答遅延 (1.8秒超過)",
                                        detail: "メインプロバイダの応答が1.8秒以内に返らなかったため、バックアップを並行実行し最速応答を採用しました。"
                                    )
                                    return .success(.backup(res, record, primaryError: nil))
                                } catch {
                                    return .failure(error, isPrimary: false)
                                }
                            }

                            var primaryError: Error?
                            var backupError: Error?

                            for try await result in group {
                                switch result {
                                case .success(let win):
                                    group.cancelAll()
                                    if case .backup(let txt, let rec, _) = win, let pErr = primaryError {
                                        return .backup(txt, rec, primaryError: pErr)
                                    }
                                    return win
                                case .failure(let err, let isPrimary):
                                    if isPrimary {
                                        primaryError = err
                                        let (summary, detail) = self.extractErrorSummary(err)
                                        NSLog("[VoiceIME] ⚠️ メイン音声認識エラー (%@): %@ (%@)", currentProvider.displayName, summary, detail)
                                    } else {
                                        backupError = err
                                        NSLog("[VoiceIME] ⚠️ バックアップ音声認識エラー: %@", err.localizedDescription)
                                    }
                                }
                            }

                            if let err = primaryError {
                                throw err
                            } else if let bErr = backupError {
                                throw bErr
                            } else {
                                throw WhisperAPIService.APIError.invalidResponse
                            }
                        }

                        whisperDuration = CFAbsoluteTimeGetCurrent() - whisperStart
                        switch winner {
                        case .primary(let text):
                            rawText = text
                            self.lastUsedWhisperProvider = currentProvider
                            NSLog("[VoiceIME] 📝 メイン音声認識成功 (%.2f秒): [%@]", whisperDuration, rawText)
                        case .backup(let text, var record, let primErr):
                            rawText = text
                            self.lastUsedWhisperProvider = backup

                            // メインが明示的エラー（429や接続切断等）で落ちていた場合は、その具体的なエラー理由を記録
                            if let primErr = primErr {
                                let (summary, detail) = self.extractErrorSummary(primErr)
                                record = FallbackRecord(
                                    timestamp: Date(),
                                    primaryProvider: currentProvider,
                                    backupProvider: backup,
                                    step: "音声認識",
                                    reasonSummary: summary,
                                    detail: detail
                                )
                            }

                            self.lastFallbackRecord = record
                            fallbackNotices.append(record.displayNotice)
                            NSLog("[VoiceIME] 📝 バックアップ音声認識が勝利 (%.2f秒): [%@]", whisperDuration, rawText)
                        }
                    } catch {
                        let (summary, detail) = self.extractErrorSummary(error)
                        NSLog("[VoiceIME] ⚠️ ヘッジド音声認識両系失敗 (%@): %@ (%@)", currentProvider.displayName, summary, detail)
                        throw error
                    }
                } else {
                    // バックアップ未設定の場合は通常通りメインのみ実行
                    do {
                        rawText = try await self.api.transcribe(
                            audioFileURL: targetAudioURL,
                            baseURL: baseURL,
                            apiKey: apiKey,
                            model: model,
                            mode: mode,
                            prompt: effectiveWhisperPrompt,
                            language: language
                        )
                        whisperDuration = CFAbsoluteTimeGetCurrent() - whisperStart
                        self.lastUsedWhisperProvider = currentProvider
                        NSLog("[VoiceIME] 📝 音声認識成功 (%.2f秒): [%@]", whisperDuration, rawText)
                    } catch {
                        let (summary, detail) = self.extractErrorSummary(error)
                        NSLog("[VoiceIME] ⚠️ 音声認識エラー (%@): %@ (%@)", currentProvider.displayName, summary, detail)
                        throw error
                    }
                }

                let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedText.isEmpty else {
                    self.phase = .idle
                    self.statusMessage = "音声が検出されませんでした。"
                    NSLog("[VoiceIME] ⚠️ 音声認識テキストが空でした")
                    return
                }

                self.lastTranscribedText = trimmedText
                PipelineLogger.shared.logWhisperReceived(type: "一括送信認識", text: trimmedText)

                // 音声認識テキストをLLMへ渡す前に、音声コマンド（改行・記号・括弧等）を事前解決する。
                // これにより、LLMが「改行」や「びっくりマーク」を文字通りの日本語として
                // 誤校正（「開業、次の行」「ビックリマーク！」等）するのを防止する。
                let preprocessedText = PunctuationService.shared.format(
                    text: trimmedText,
                    isJapanese: isJapanese
                )
                var refinedText = preprocessedText

                if isLLMEnabled && mode == .transcriptions {
                    PipelineLogger.shared.logLLMInput(type: "一括送信推敲", text: preprocessedText)
                    self.phase = .refining
                    self.statusMessage = refinementStyle == .casual ? "AI推敲中(口語)..." : "AI推敲中(文章)..."
                    NSLog("[VoiceIME] 🤖 AI推敲リクエスト送信 (%@, モデル: %@, スタイル: %@)", llmProviderDisplayName, currentLLMConfig.modelName, refinementStyle.rawValue)

                    let llmStart = CFAbsoluteTimeGetCurrent()

                    let llmBackupProvider: APIProvider?
                    if !currentLLMConfig.isCustom && self.settings.autoFallbackEnabled {
                        switch resolvedLLMProvider {
                        case .groq:
                            llmBackupProvider = self.keychain.hasAPIKey(for: .openai) ? .openai : nil
                        case .openai:
                            llmBackupProvider = self.keychain.hasAPIKey(for: .groq) ? .groq : nil
                        case .sarashina, .custom:
                            llmBackupProvider = nil
                        }
                    } else {
                        llmBackupProvider = nil
                    }

                    if let backup = llmBackupProvider,
                       let backupKey = self.keychain.loadAPIKey(for: backup) {
                        // =========================================================
                        // 🚀 LLM ヘッジド・リクエスト (Hedged Requests / 時間差レーシング)
                        // =========================================================
                        // 1. まずメイン（Groq等）に推敲リクエスト送信
                        // 2. 1.5秒経過しても応答がない場合、バックアップ（OpenAI等）にも並列で投げる
                        // 3. どちらか早く成功した方の推敲結果を採用する
                        let backupLLMConfig = self.settings.llmConfig(for: backup)
                        let hedgedDelayNanoseconds: UInt64 = 1_500_000_000 // 1.5秒

                        enum RefineWinner {
                            case primary(String)
                            case backup(String, FallbackRecord, primaryError: Error?)
                        }

                        enum LLMTaskResult {
                            case success(RefineWinner)
                            case failure(Error, isPrimary: Bool)
                        }

                        do {
                            let winner = try await withThrowingTaskGroup(of: LLMTaskResult.self) { group -> RefineWinner in
                                // タスク1: メインLLM
                                group.addTask {
                                    do {
                                        let res = try await self.llm.refine(
                                            text: preprocessedText,
                                            baseURL: currentLLMConfig.baseURL,
                                            apiKey: llmApiKey,
                                            model: currentLLMConfig.modelName,
                                            promptHint: prompt,
                                            style: refinementStyle,
                                            livePreviewText: livePreviewText,
                                            isCustom: false
                                        )
                                        return .success(.primary(res))
                                    } catch {
                                        return .failure(error, isPrimary: true)
                                    }
                                }

                                // タスク2: 1.5秒ディレイ後にバックアップを発射
                                group.addTask {
                                    do {
                                        try await Task.sleep(nanoseconds: hedgedDelayNanoseconds)
                                        try Task.checkCancellation()

                                        await MainActor.run {
                                            self.statusMessage = "\(backup.displayName) で並列推敲中 (応答遅延)..."
                                        }
                                        NSLog("[VoiceIME] ⚡️ メインLLM(%@)応答待ち1.5秒超過: バックアップ(%@)へ並行リクエスト発射", resolvedLLMProvider.displayName, backup.displayName)

                                        let res = try await self.llm.refine(
                                            text: preprocessedText,
                                            baseURL: backupLLMConfig.baseURL,
                                            apiKey: backupKey,
                                            model: backupLLMConfig.modelName,
                                            promptHint: prompt,
                                            style: refinementStyle,
                                            livePreviewText: livePreviewText,
                                            isCustom: false
                                        )

                                        let record = FallbackRecord(
                                            timestamp: Date(),
                                            primaryProvider: resolvedLLMProvider,
                                            backupProvider: backup,
                                            step: "AI推敲",
                                            reasonSummary: "応答遅延 (1.5秒超過)",
                                            detail: "メインプロバイダの推敲応答が1.5秒以内に返らなかったため、バックアップを並行実行し最速応答を採用しました。"
                                        )
                                        return .success(.backup(res, record, primaryError: nil))
                                    } catch {
                                        return .failure(error, isPrimary: false)
                                    }
                                }

                                var primaryError: Error?
                                var backupError: Error?

                                for try await result in group {
                                    switch result {
                                    case .success(let win):
                                        group.cancelAll()
                                        if case .backup(let txt, let rec, _) = win, let pErr = primaryError {
                                            return .backup(txt, rec, primaryError: pErr)
                                        }
                                        return win
                                    case .failure(let err, let isPrimary):
                                        if isPrimary {
                                            primaryError = err
                                            let (summary, detail) = self.extractErrorSummary(err)
                                            NSLog("[VoiceIME] ⚠️ メインAI推敲エラー (%@): %@ (%@)", resolvedLLMProvider.displayName, summary, detail)
                                        } else {
                                            backupError = err
                                            NSLog("[VoiceIME] ⚠️ バックアップAI推敲エラー: %@", err.localizedDescription)
                                        }
                                    }
                                }

                                if let err = primaryError {
                                    throw err
                                } else if let bErr = backupError {
                                    throw bErr
                                } else {
                                    throw LLMService.LLMError.invalidResponse
                                }
                            }

                            llmDuration = CFAbsoluteTimeGetCurrent() - llmStart
                            switch winner {
                            case .primary(let text):
                                refinedText = text
                                self.lastUsedLLMProvider = resolvedLLMProvider
                                NSLog("[VoiceIME] ✨ メインAI推敲成功 (%.2f秒): [%@]", llmDuration, refinedText)
                            case .backup(let text, var record, let primErr):
                                refinedText = text
                                self.lastUsedLLMProvider = backup

                                if let primErr = primErr {
                                    let (summary, detail) = self.extractErrorSummary(primErr)
                                    record = FallbackRecord(
                                        timestamp: Date(),
                                        primaryProvider: resolvedLLMProvider,
                                        backupProvider: backup,
                                        step: "AI推敲",
                                        reasonSummary: summary,
                                        detail: detail
                                    )
                                }

                                self.lastFallbackRecord = record
                                fallbackNotices.append(record.displayNotice)
                                NSLog("[VoiceIME] ✨ バックアップAI推敲が勝利 (%.2f秒): [%@]", llmDuration, refinedText)
                            }
                        } catch {
                            NSLog("[VoiceIME] ⚠️ ヘッジドAI推敲両系失敗: %@。事前整形テキストを使用します", error.localizedDescription)
                            refinedText = preprocessedText
                            self.lastUsedLLMProvider = nil
                        }
                    } else {
                        // バックアップ未設定、またはカスタムLLMの場合は単独で実行
                        do {
                            refinedText = try await self.llm.refine(
                                text: preprocessedText,
                                baseURL: currentLLMConfig.baseURL,
                                apiKey: llmApiKey,
                                model: currentLLMConfig.modelName,
                                promptHint: prompt,
                                style: refinementStyle,
                                livePreviewText: livePreviewText,
                                isCustom: currentLLMConfig.isCustom
                            )
                            llmDuration = CFAbsoluteTimeGetCurrent() - llmStart
                            self.lastUsedLLMProvider = resolvedLLMProvider
                            NSLog("[VoiceIME] ✨ AI推敲成功 (%.2f秒): [%@]", llmDuration, refinedText)
                        } catch {
                            let (summary, detail) = self.extractErrorSummary(error)
                            NSLog("[VoiceIME] ⚠️ AI推敲エラー (%@): %@ (%@)。事前整形テキストを使用します", llmProviderDisplayName, summary, detail)
                            refinedText = preprocessedText
                            self.lastUsedLLMProvider = nil
                        }
                    }
                    PipelineLogger.shared.logLLMOutput(type: "一括送信推敲", text: refinedText)
                } else {
                    self.lastUsedLLMProvider = nil
                }

                // ==========================================
                // 3. 確定テキストの最終整形（辞書適用・正規化）と対象アプリへのペースト
                // ==========================================
                PipelineLogger.shared.logSessionEnd(finalText: refinedText)
                self.finalizeAndPaste(
                    text: refinedText,
                    livePreviewText: isLLMEnabled ? refinedText : livePreviewText,
                    isJapanese: isJapanese,
                    totalStartTime: totalStartTime,
                    fallbackNotices: fallbackNotices
                )
                return


            } catch {
                // URLSession のキャンセルは URLError(.cancelled) としてラップされて届くため、
                // エラー型ではなく Task のキャンセル状態で判定する
                if Task.isCancelled {
                    self.phase = .idle
                    self.statusMessage = "処理をキャンセルしました。"
                    return
                }
                self.phase = .error(error.localizedDescription)
                self.statusMessage = "エラーが発生しました。"
                self.errorMessage = error.localizedDescription
                NSLog("[VoiceIME] ❌ 処理中断エラー: %@", error.localizedDescription)
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

    /// 確定テキストの最終整形（辞書適用・正規化）と対象アプリへのペースト
    public func finalizeAndPaste(
        text: String,
        livePreviewText: String = "",
        isJapanese: Bool,
        totalStartTime: CFAbsoluteTime,
        fallbackNotices: [String] = []
    ) {
        let alignedText = PunctuationService.shared.alignPunctuation(
            text: text,
            referenceLiveText: livePreviewText,
            isJapanese: isJapanese
        )
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

        switch focusState {
        case .editableText(let role, let detail):
            if self.settings.autoPasteEnabled {
                self.phase = .pasting
                self.statusMessage = "入力中..."
                NSLog("[VoiceIME] 🚀 確実な入力欄へ自動ペースト実行 (\(role): \(detail)): [%@]", processedText)

                self.paster.paste(text: processedText, restoreClipboard: self.settings.restoreClipboard) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.phase = .idle
                        self.statusMessage = completionMessage
                        if self.settings.floatingPreviewEnabled {
                            FloatingPreviewController.shared.hide()
                        }
                        NSLog("[VoiceIME] ✅ 入力完了・プレビューウィンドウ消去")
                    }
                }
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
            self.phase = .idle
            self.statusMessage = "\(completionMessage) [45秒限定コピー: ⌘V/\(self.settings.pasteShortcutDisplayString)で入力]"
            NSLog("[VoiceIME] ⚠️ 非入力要素（\(role): \(detail)）を検出。45秒限定でクリップボードに退避しウィンドウを残します")

        case .ambiguous(let role, let detail):
            let tempDuration = self.settings.floatingPreviewDuration > 0 ? min(self.settings.floatingPreviewDuration, 45.0) : 45.0
            FloatingPreviewController.shared.setTemporaryClipboard(text: processedText, duration: tempDuration)
            if self.settings.floatingPreviewEnabled {
                FloatingPreviewController.shared.show(text: processedText, notice: "45秒間コピー有効: ⌘V または \(self.settings.pasteShortcutDisplayString)")
            }
            if self.settings.autoPasteEnabled {
                self.phase = .pasting
                self.statusMessage = "入力中..."
                NSLog("[VoiceIME] 🚀 判定微妙（\(role): \(detail)）のためペースト試行＋ウィンドウ保留: [%@]", processedText)
                self.paster.paste(text: processedText, restoreClipboard: self.settings.restoreClipboard) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.phase = .idle
                        self.statusMessage = completionMessage
                        NSLog("[VoiceIME] ✅ ペースト試行完了（ウィンドウは保留維持）")
                    }
                }
            } else {
                self.phase = .idle
                self.statusMessage = "\(completionMessage) [45秒限定コピー: ⌘V/\(self.settings.pasteShortcutDisplayString)で入力]"
            }
        }
    }
}
