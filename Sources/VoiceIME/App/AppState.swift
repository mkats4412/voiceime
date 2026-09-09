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

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    @Published public var phase: RecordingPhase = .idle
    @Published public var statusMessage: String = "準備完了"
    @Published public var lastTranscribedText: String = ""
    @Published public var lastProcessedText: String = ""
    @Published public var errorMessage: String? = nil

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
                stopRecordingAndTranscribe()
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
        }
    }

    /// 録音停止と文字起こし・AI推敲・自動ペースト処理
    public func stopRecordingAndTranscribe() {
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil

        guard let audioURL = recorder.stopRecording() else {
            phase = .idle
            statusMessage = "録音データがありません。"
            return
        }

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
        let rules = settings.dictionaryRules
        let restoreClipboard = settings.restoreClipboard

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer {
                try? FileManager.default.removeItem(at: targetAudioURL)
            }

            let totalStartTime = CFAbsoluteTimeGetCurrent()
            var whisperDuration: Double = 0.0
            var llmDuration: Double = 0.0

            do {
                // ==========================================
                // 1. Whisper API にリクエスト送信（音声 ➔ テキスト）
                // ==========================================
                var rawText: String
                var fallbackNotice: String? = nil

                let whisperStart = CFAbsoluteTimeGetCurrent()
                do {
                    rawText = try await self.api.transcribe(
                        audioFileURL: targetAudioURL,
                        baseURL: baseURL,
                        apiKey: apiKey,
                        model: model,
                        mode: mode,
                        prompt: prompt,
                        language: language
                    )
                    whisperDuration = CFAbsoluteTimeGetCurrent() - whisperStart
                } catch {
                    // メインプロバイダが失敗し、バックアッププロバイダのキーが存在する場合に自動再試行
                    if let backup = self.settings.backupProvider,
                       let backupKey = self.keychain.loadAPIKey(for: backup) {
                        let config = self.settings.config(for: backup)

                        self.statusMessage = "\(backup.displayName) で音声認識を自動再試行中..."
                        do {
                            rawText = try await self.api.transcribe(
                                audioFileURL: targetAudioURL,
                                baseURL: config.baseURL,
                                apiKey: backupKey,
                                model: config.modelName,
                                mode: mode,
                                prompt: prompt,
                                language: language
                            )
                            whisperDuration = CFAbsoluteTimeGetCurrent() - whisperStart
                            fallbackNotice = " (\(backup.displayName) 音声認識)"
                        } catch let backupError {
                            throw backupError
                        }
                    } else {
                        throw error
                    }
                }

                let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedText.isEmpty else {
                    self.phase = .idle
                    self.statusMessage = "音声が検出されませんでした。"
                    return
                }

                self.lastTranscribedText = trimmedText

                // ==========================================
                // 2. LLM による文章の意味理解・推敲（テキスト ➔ テキスト）
                // ==========================================
                var refinedText = trimmedText

                if isLLMEnabled && mode == .transcriptions {
                    self.phase = .refining
                    self.statusMessage = "AI推敲中..."

                    let llmStart = CFAbsoluteTimeGetCurrent()
                    do {
                        refinedText = try await self.llm.refine(
                            text: trimmedText,
                            baseURL: currentLLMConfig.baseURL,
                            apiKey: apiKey,
                            model: currentLLMConfig.modelName,
                            promptHint: prompt
                        )
                        llmDuration = CFAbsoluteTimeGetCurrent() - llmStart
                    } catch {
                        // メインLLMが失敗した場合、バックアッププロバイダでLLM推敲を自動試行
                        if let backup = self.settings.backupProvider,
                           let backupKey = self.keychain.loadAPIKey(for: backup) {
                            let backupLLMConfig = self.settings.llmConfig(for: backup)
                            self.statusMessage = "\(backup.displayName) でAI推敲を再試行中..."

                            do {
                                refinedText = try await self.llm.refine(
                                    text: trimmedText,
                                    baseURL: backupLLMConfig.baseURL,
                                    apiKey: backupKey,
                                    model: backupLLMConfig.modelName,
                                    promptHint: prompt
                                )
                                llmDuration = CFAbsoluteTimeGetCurrent() - llmStart
                                fallbackNotice = (fallbackNotice ?? "") + " (\(backup.displayName) AI推敲)"
                            } catch {
                                // バックアップも失敗した場合は、生テキスト（Whisper出力）にフォールバックして処理を継続
                                refinedText = trimmedText
                            }
                        } else {
                            // バックアップキーがない場合は生テキストを使用
                            refinedText = trimmedText
                        }
                    }
                }

                // ==========================================
                // 3. ユーザー独自の辞書置換ルールを適用
                // ==========================================
                let processedText = self.dictionary.apply(
                    text: refinedText,
                    rules: rules
                )
                self.lastProcessedText = processedText

                // ==========================================
                // 4. テキスト自動挿入（ペースト）
                // ==========================================
                self.phase = .pasting
                self.statusMessage = "入力中..."

                let totalElapsed = CFAbsoluteTimeGetCurrent() - totalStartTime
                let timeStr = String(format: "%.1f秒", totalElapsed)
                NSLog("[VoiceIME] 完了: 計 %.2f秒 (音声認識: %.2f秒, AI推敲: %.2f秒)", totalElapsed, whisperDuration, llmDuration)

                self.paster.paste(text: processedText, restoreClipboard: restoreClipboard) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.phase = .idle
                        self.statusMessage = fallbackNotice != nil ? "完了 (\(timeStr))\(fallbackNotice!)" : "完了 (\(timeStr))"
                    }
                }

            } catch {
                self.phase = .error(error.localizedDescription)
                self.statusMessage = "エラーが発生しました。"
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// 録音を中断・破棄
    public func cancelRecording() {
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil

        recorder.cancelRecording()
        phase = .idle
        statusMessage = "録音をキャンセルしました。"
    }
}
