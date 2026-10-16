import Foundation
import SwiftUI
import Combine

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

    private init() {
        setupHotkey()
        // 起動時にKeychainアクセスを事前ウォームアップ（音声入力中のダイアログ遮断を防止）
        keychain.warmUp()
    }

    /// グローバルホットキーのセットアップ
    public func setupHotkey() {
        hotkey.register(
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
            if phase == .recording {
                // 誤タップ（0.15秒未満）の誤動作ガード
                if let startTime = recordingStartTime, Date().timeIntervalSince(startTime) < 0.15 {
                    cancelRecording()
                    return
                }
                // キーを離した瞬間に視覚的フィードバック（処理中アニメーション）を即座に開始
                if settings.floatingPreviewEnabled {
                    FloatingPreviewController.shared.setProcessing()
                }
                // 発話末尾の単語・語尾・余韻（「〜と言及した」「〜ですよね」等）がマイクバッファから欠落するのを防ぐため、
                // キー離脱から約220ms遅延させて録音を停止する
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                    guard let self = self, self.phase == .recording else { return }
                    self.stopRecordingAndTranscribe()
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
            statusMessage = settings.triggerMode == .pushToTalk ? "録音中... (キーを離すと入力)" : "録音中... (もう一度キーを押して停止)"
            errorMessage = nil
            recordingStartTime = Date()
            NSLog("[VoiceIME] 🎤 録音開始 (動作モード: %@)", settings.triggerMode.rawValue)

            // フローティングプレビューが有効な場合、リアルタイム音声認識とプレビューウィンドウを開始
            if settings.floatingPreviewEnabled {
                FloatingPreviewController.shared.showLiveRecording()
                LiveSpeechService.shared.startLiveRecognition(languageCode: settings.language) { text in
                    FloatingPreviewController.shared.updateLiveText(text)
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

        // リアルタイムプレビューで最後に表示されていたテキストを取得・句読点補正を確定
        let rawLive = LiveSpeechService.shared.partialText
        let isJapanese = (settings.language.isEmpty || settings.language.lowercased().starts(with: "ja"))
        let livePreviewText = PunctuationService.shared.format(text: rawLive, isJapanese: isJapanese)

        // プレビューのテキストを最新の句読点付きに更新
        if settings.floatingPreviewEnabled && !livePreviewText.isEmpty {
            FloatingPreviewController.shared.updateLiveText(livePreviewText)
        }

        // リアルタイム音声認識を停止し、プレビューを処理中フェーズへ
        LiveSpeechService.shared.stopLiveRecognition()
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
        // 0. 音声しきい値判定（小さな音・環境雑音の除外）
        // ==========================================
        var targetAudioURL = audioURL
        if settings.audioThresholdEnabled {
            let metrics = AudioAnalysisService.shared.analyze(
                audioFileURL: audioURL,
                thresholdDB: settings.audioThresholdDB
            )

            if !metrics.hasSpeech {
                NSLog("[VoiceIME] 音声除外: 音量レベルがしきい値未満 (maxRMS: %.1f dB, peak: %.1f dB, しきい値: %.1f dB)", metrics.maxWindowRMS_DB, metrics.peakPowerDB, settings.audioThresholdDB)
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
        let currentLLMConfig = settings.llmConfig(for: currentProvider)
        let apiKey = keychain.loadAPIKey(for: currentProvider)
        let baseURL = currentConfig.baseURL
        let model = currentConfig.modelName
        let prompt = settings.promptHint.isEmpty ? nil : settings.promptHint
        let language = settings.language.isEmpty ? nil : settings.language

        let isLLMEnabled = settings.llmRefinementEnabled
        let refinementStyle = settings.refinementStyle
        let rules = settings.dictionaryRules
        let restoreClipboard = settings.restoreClipboard

        // Whisper APIの初期プロンプト: 指定言語に応じた自然な句読点や語尾の脱落を防止
        let effectiveWhisperPrompt: String?
        if let customPrompt = prompt, !customPrompt.isEmpty {
            effectiveWhisperPrompt = customPrompt
        } else if language == "ja" {
            effectiveWhisperPrompt = (refinementStyle == .casual)
                ? "こんにちは。そうですね、承知いたしました。〜ですね。〜ですよ。〜と言及した。"
                : "こんにちは。本件について報告いたします。〜と言及した。〜である。"
        } else if language == "en" {
            effectiveWhisperPrompt = "Hello. Yes, I understand. Thank you."
        } else {
            // 言語自動検出時は特定言語へのバイアスを避けるため nil
            effectiveWhisperPrompt = nil
        }

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

            do {
                // ==========================================
                // 1. Whisper API にリクエスト送信（音声 ➔ テキスト）
                // ==========================================
                var rawText: String
                var fallbackNotices: [String] = []

                let whisperStart = CFAbsoluteTimeGetCurrent()
                // バックアッププロバイダが存在するか確認
                let backupProvider = self.settings.backupProvider
                let backupKey = backupProvider != nil ? self.keychain.loadAPIKey(for: backupProvider!) : nil

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

                // ==========================================
                // 2. LLM による文章の意味理解・推敲（テキスト ➔ テキスト）
                // ==========================================
                var refinedText = trimmedText

                if isLLMEnabled && mode == .transcriptions {
                    self.phase = .refining
                    self.statusMessage = refinementStyle == .casual ? "AI推敲中(口語)..." : "AI推敲中(文章)..."
                    NSLog("[VoiceIME] 🤖 AI推敲リクエスト送信 (%@, モデル: %@, スタイル: %@)", currentProvider.displayName, currentLLMConfig.modelName, refinementStyle.rawValue)

                    let llmStart = CFAbsoluteTimeGetCurrent()

                    if let backup = self.settings.backupProvider,
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
                                            text: trimmedText,
                                            baseURL: currentLLMConfig.baseURL,
                                            apiKey: apiKey,
                                            model: currentLLMConfig.modelName,
                                            promptHint: prompt,
                                            style: refinementStyle,
                                            livePreviewText: livePreviewText
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
                                        NSLog("[VoiceIME] ⚡️ メインLLM(%@)応答待ち1.5秒超過: バックアップ(%@)へ並行リクエスト発射", currentProvider.displayName, backup.displayName)

                                        let res = try await self.llm.refine(
                                            text: trimmedText,
                                            baseURL: backupLLMConfig.baseURL,
                                            apiKey: backupKey,
                                            model: backupLLMConfig.modelName,
                                            promptHint: prompt,
                                            style: refinementStyle,
                                            livePreviewText: livePreviewText
                                        )

                                        let record = FallbackRecord(
                                            timestamp: Date(),
                                            primaryProvider: currentProvider,
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
                                            NSLog("[VoiceIME] ⚠️ メインAI推敲エラー (%@): %@ (%@)", currentProvider.displayName, summary, detail)
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
                                self.lastUsedLLMProvider = currentProvider
                                NSLog("[VoiceIME] ✨ メインAI推敲成功 (%.2f秒): [%@]", llmDuration, refinedText)
                            case .backup(let text, var record, let primErr):
                                refinedText = text
                                self.lastUsedLLMProvider = backup

                                if let primErr = primErr {
                                    let (summary, detail) = self.extractErrorSummary(primErr)
                                    record = FallbackRecord(
                                        timestamp: Date(),
                                        primaryProvider: currentProvider,
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
                            NSLog("[VoiceIME] ⚠️ ヘッジドAI推敲両系失敗: %@。生テキストを使用します", error.localizedDescription)
                            refinedText = trimmedText
                            self.lastUsedLLMProvider = nil
                        }
                    } else {
                        // バックアップ未設定の場合は通常通りメインのみ実行
                        do {
                            refinedText = try await self.llm.refine(
                                text: trimmedText,
                                baseURL: currentLLMConfig.baseURL,
                                apiKey: apiKey,
                                model: currentLLMConfig.modelName,
                                promptHint: prompt,
                                style: refinementStyle,
                                livePreviewText: livePreviewText
                            )
                            llmDuration = CFAbsoluteTimeGetCurrent() - llmStart
                            self.lastUsedLLMProvider = currentProvider
                            NSLog("[VoiceIME] ✨ AI推敲成功 (%.2f秒): [%@]", llmDuration, refinedText)
                        } catch {
                            let (summary, detail) = self.extractErrorSummary(error)
                            NSLog("[VoiceIME] ⚠️ AI推敲エラー (%@): %@ (%@)。生テキストを使用します", currentProvider.displayName, summary, detail)
                            refinedText = trimmedText
                            self.lastUsedLLMProvider = nil
                        }
                    }
                } else {
                    self.lastUsedLLMProvider = nil
                }

                // ==========================================
                // 3. 画面プレビュー表示テキストとの句読点整合化・正規化
                // ==========================================
                let alignedText = PunctuationService.shared.alignPunctuation(
                    text: refinedText,
                    referenceLiveText: livePreviewText,
                    isJapanese: isJapanese
                )
                let normalizedText = LLMService.normalizePunctuation(for: alignedText)

                // ==========================================
                // 4. ユーザー独自の辞書置換ルールを適用
                // ==========================================
                let processedText = self.dictionary.apply(
                    text: normalizedText,
                    rules: rules
                )
                self.lastProcessedText = processedText

                // プレビューウィンドウの内容も最新の確定テキストに同期
                if self.settings.floatingPreviewEnabled {
                    FloatingPreviewController.shared.updateLiveText(processedText)
                }

                // ==========================================
                // 5. テキスト出力（自動ペースト & フローティングプレビュー保留）
                // ==========================================
                // キャンセル済みなら、ユーザーの意図しないタイミングでペーストしない
                if Task.isCancelled {
                    self.phase = .idle
                    self.statusMessage = "処理をキャンセルしました。"
                    return
                }

                let totalElapsed = CFAbsoluteTimeGetCurrent() - totalStartTime
                let timeStr = String(format: "%.1f秒", totalElapsed)
                let completionNotice = fallbackNotices.isEmpty ? "" : " " + fallbackNotices.joined(separator: " ")
                let completionMessage = "完了 (\(timeStr))" + completionNotice

                // ==========================================
                // 5. フォーカス状態の自動判定とテキスト出力
                // ==========================================
                let focusState = FocusDetectionService.shared.checkCurrentFocus()
                NSLog("[VoiceIME] 🎯 フォーカス状態判定: %@", focusState.description)

                switch focusState {
                case .editableText(let role, let detail):
                    // 【確実に入力エリア】
                    // 1. 自動ペーストを実行
                    // 2. ペースト完了時にウィンドウを非表示（閉じる）
                    if self.settings.autoPasteEnabled {
                        self.phase = .pasting
                        self.statusMessage = "入力中..."
                        NSLog("[VoiceIME] 🚀 確実な入力欄へ自動ペースト実行 (\(role): \(detail)): [%@]", processedText)

                        self.paster.paste(text: processedText, restoreClipboard: restoreClipboard) { [weak self] in
                            Task { @MainActor [weak self] in
                                guard let self = self else { return }
                                self.phase = .idle
                                self.statusMessage = completionMessage
                                // 入力欄へのペーストが完了したため、ウィンドウを自動で閉じる
                                if self.settings.floatingPreviewEnabled {
                                    FloatingPreviewController.shared.hide()
                                }
                                NSLog("[VoiceIME] ✅ 入力完了・プレビューウィンドウ消去")
                            }
                        }
                    } else {
                        if self.settings.floatingPreviewEnabled {
                            FloatingPreviewController.shared.show(text: processedText, notice: "入力先を選択 ➔ ⌘↩")
                        }
                        self.phase = .idle
                        self.statusMessage = completionMessage + " [⌘↩で入力]"
                    }

                case .notEditable(let role, let detail):
                    // 【明らかに入力不可（デスクトップ、ボタン、ブラウザWebページ全体等）】
                    // 1. 自動ペーストはスキップして空振りを防止
                    // 2. セキュリティ保護: 最大45秒間だけ一時クリップボードに保持（45秒後またはウィンドウ消去時に自動復元・消去）
                    let tempDuration = self.settings.floatingPreviewDuration > 0 ? min(self.settings.floatingPreviewDuration, 45.0) : 45.0
                    FloatingPreviewController.shared.setTemporaryClipboard(text: processedText, duration: tempDuration)

                    // 3. ウィンドウを画面に残して案内
                    if self.settings.floatingPreviewEnabled {
                        FloatingPreviewController.shared.show(text: processedText, notice: "45秒間コピー有効: ⌘V または ⌘↩")
                    }
                    self.phase = .idle
                    self.statusMessage = "\(completionMessage) [45秒限定コピー: ⌘V/⌘↩で入力]"
                    NSLog("[VoiceIME] ⚠️ 非入力要素（\(role): \(detail)）を検出。45秒限定でクリップボードに退避しウィンドウを残します")

                case .ambiguous(let role, let detail):
                    // 【判定微妙・Web/Slack/VSCode等】
                    // セキュリティ保護: 最大45秒間だけ一時クリップボードに保持
                    let tempDuration = self.settings.floatingPreviewDuration > 0 ? min(self.settings.floatingPreviewDuration, 45.0) : 45.0
                    FloatingPreviewController.shared.setTemporaryClipboard(text: processedText, duration: tempDuration)

                    if self.settings.floatingPreviewEnabled {
                        FloatingPreviewController.shared.show(text: processedText, notice: "45秒間コピー有効: ⌘V または ⌘↩")
                    }

                    if self.settings.autoPasteEnabled {
                        self.phase = .pasting
                        self.statusMessage = "入力中..."
                        NSLog("[VoiceIME] 🚀 判定微妙（\(role): \(detail)）のためペースト試行＋ウィンドウ保留: [%@]", processedText)

                        self.paster.paste(text: processedText, restoreClipboard: restoreClipboard) { [weak self] in
                            Task { @MainActor [weak self] in
                                guard let self = self else { return }
                                self.phase = .idle
                                self.statusMessage = completionMessage
                                NSLog("[VoiceIME] ✅ ペースト試行完了（ウィンドウは保留維持）")
                            }
                        }
                    } else {
                        self.phase = .idle
                        self.statusMessage = completionMessage + " [⌘↩で入力]"
                    }
                }

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
}
