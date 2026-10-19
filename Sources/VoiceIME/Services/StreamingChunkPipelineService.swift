import Foundation
import AVFoundation

/// リアルタイム累積・紙芝居ストリーミングパイプライン
/// - 録音開始（0秒）からの音声を累積バッファに保持
/// - 話者の「息継ぎ（無音 0.28秒以上）」を検知したタイミングでトリガー
/// - 1分間に最大18〜19回（約3.2秒間隔）のレート制限でAPIクォータを厳格に保護
/// - 毎回「0秒から現在の息継ぎまで」の累積音声をWhisperに送信（文頭からの文脈が100%維持される）
/// - 返ってきたテキストで画面（フローティングプレビュー）を丸ごと上書き（紙芝居のように更新され、前後の文脈で漢字が自動修正される）
/// - キー解放（録音終了）時は、最後の発話を含めて即座に最終確定
public final class StreamingChunkPipelineService: @unchecked Sendable {
    public static let shared = StreamingChunkPipelineService()

    private let queue = DispatchQueue(label: "com.voiceime.streaming.pipeline", qos: .userInitiated)

    // オーディオ累積バッファ (Int16 PCM)
    private var pcmDataBuffer = Data()
    private var sampleRate: Double = 16000.0
    private var isRunning: Bool = false

    // 息継ぎ検知 & レート制限パラメータ
    private let minIntervalSeconds: Double = 3.2 // 1分間に最大約18〜19回 (60 / 18.5 ≈ 3.24秒)
    private var silenceThresholdRMS: Float = 0.015 // 音声入力しきい値と連動（デフォルト約 -36 dBFS）
    private let minSilenceDuration: Double = 0.28 // 約0.28秒以上の無音（息継ぎ）
    private var speechThresholdDB: Float = -38.0

    // 状態管理
    private var lastTriggerTime: CFAbsoluteTime = 0.0
    private var lastTriggerSampleCount: Int = 0
    private var recentRMS: Float = 0.0
    private var silentFrameCount: Int = 0
    private var isTranscribing: Bool = false
    private var currentProcessingTask: Task<Void, Never>?

    // 中間LLM推敲のレート制限（10秒に1回。6 RPMのAPI制限を遵守し、最終リリース時の確定推敲枠を確保）
    private var lastLLMRefineTime: CFAbsoluteTime = 0.0
    private let minLLMRefineIntervalSeconds: Double = 10.0

    // 紙芝居テキスト管理
    public private(set) var latestRefinedText: String = ""
    public private(set) var lastWhisperBaseText: String = ""

    // 設定
    private var currentWhisperConfig: (baseURL: String, apiKey: String?, model: String)?
    private var currentLLMConfig: (baseURL: String, apiKey: String?, model: String, isCustom: Bool)?
    private var refinementStyle: RefinementStyle = .casual
    private var isLLMEnabled: Bool = true
    private var whisperPrompt: String? = nil
    private var language: String? = "ja"

    private init() {}

    /// パイプラインの開始
    public func start(
        whisperConfig: (baseURL: String, apiKey: String?, model: String),
        llmConfig: (baseURL: String, apiKey: String?, model: String, isCustom: Bool),
        style: RefinementStyle,
        isLLMEnabled: Bool = true,
        whisperPrompt: String? = nil,
        language: String? = "ja",
        speechThresholdDB: Float = -38.0
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.currentProcessingTask?.cancel()
            self.currentProcessingTask = nil
            self.pcmDataBuffer.removeAll(keepingCapacity: true)
            self.lastTriggerTime = CFAbsoluteTimeGetCurrent()
            self.lastTriggerSampleCount = 0
            self.recentRMS = 0.0
            self.silentFrameCount = 0
            self.latestRefinedText = ""
            self.lastWhisperBaseText = ""
            self.lastLLMRefineTime = 0.0
            self.isTranscribing = false
            self.currentWhisperConfig = whisperConfig
            self.currentLLMConfig = llmConfig
            self.refinementStyle = style
            self.isLLMEnabled = isLLMEnabled
            self.whisperPrompt = whisperPrompt
            self.language = language
            self.speechThresholdDB = speechThresholdDB
            // 音声入力しきい値（dBFS）から息継ぎ判定用の無音RMSを自動連動
            // （発話判定しきい値より約4dB低い音量を「無音・息継ぎ区間」として判定）
            let silenceDB = min(speechThresholdDB - 4.0, -34.0)
            self.silenceThresholdRMS = pow(10.0, silenceDB / 20.0)
            self.isRunning = true
            NSLog("[VoiceIME] 🎭 累積・紙芝居ストリーミングパイプラインを開始しました (発話しきい値: %.1f dB, 無音息継ぎしきい値: %.1f dB / RMS %.4f, 制限: 3.2秒/最大18回毎分)", speechThresholdDB, silenceDB, self.silenceThresholdRMS)
        }
    }

    /// マイク入力バッファの受信と蓄積・息継ぎスキャン
    public func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self = self, self.isRunning else { return }

            let bufSampleRate = buffer.format.sampleRate
            if bufSampleRate > 0 && self.sampleRate != bufSampleRate {
                self.sampleRate = bufSampleRate
            }

            // 1. PCM Float ➔ Int16 変換＆RMS計算
            guard let floatData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            var sumSquares: Float = 0.0
            var int16Data = Data(capacity: frameLength * 2)

            for i in 0..<frameLength {
                let sample = floatData[i]
                sumSquares += sample * sample
                let clamped = max(-1.0, min(1.0, sample))
                var int16 = Int16(clamped * 32767.0)
                withUnsafeBytes(of: &int16) { int16Data.append(contentsOf: $0) }
            }

            let rms = sqrt(sumSquares / Float(frameLength))
            self.recentRMS = rms
            self.pcmDataBuffer.append(int16Data)

            if rms < self.silenceThresholdRMS {
                self.silentFrameCount += frameLength
            } else {
                self.silentFrameCount = 0
            }

            // 2. 息継ぎ（無音 0.28秒以上）＆ レート制限（3.2秒間隔）の判定
            let totalSamples = self.pcmDataBuffer.count / 2
            let silentDuration = Double(self.silentFrameCount) / self.sampleRate
            let now = CFAbsoluteTimeGetCurrent()
            let timeSinceLastTrigger = now - self.lastTriggerTime
            let newAudioDuration = Double(totalSamples - self.lastTriggerSampleCount) / self.sampleRate
            let totalAudioDuration = Double(totalSamples) / self.sampleRate

            // トリガー条件:
            // A. 録音開始から最低2.0秒以上経過（話し始めの無音による誤送信を防止）
            // B. 息継ぎ（無音）を検知（0.28秒以上）
            // C. 前回の送信から3.2秒以上経過（1分間18〜19回制限）
            // D. 前回送信時から新しい発話が1.2秒以上存在
            // E. 現在通信中（isTranscribing）でない
            let hasMinimumInitialAudio = (totalAudioDuration >= 2.0)
            let isBreathPause = (silentDuration >= self.minSilenceDuration)
            let isRateLimitSatisfied = (timeSinceLastTrigger >= self.minIntervalSeconds)
            let hasSufficientNewAudio = (newAudioDuration >= 1.2)

            if hasMinimumInitialAudio && isBreathPause && isRateLimitSatisfied && hasSufficientNewAudio && !self.isTranscribing {
                self.lastTriggerTime = now
                self.lastTriggerSampleCount = totalSamples
                self.processCumulativePaperTheater(to: totalSamples)
            }
        }
    }

    /// 0秒〜endSample までの累積音声を丸ごと送信し、紙芝居のように画面を上書き更新
    private func processCumulativePaperTheater(to endSample: Int) {
        guard let whisperConfig = currentWhisperConfig else { return }
        let llmConfig = currentLLMConfig

        let endByte = min(endSample * 2, pcmDataBuffer.count)
        guard endByte > 0 else { return }

        // 🌟 核心: 常に「0秒（発話の最初）」から現在までの音声を取り出し、前後の無音をトリミング！
        let cumulativeBytes = pcmDataBuffer.subdata(in: 0..<endByte)
        let trimmedBytes = Self.trimSilence(pcmData: cumulativeBytes, sampleRate: sampleRate, speechThresholdDB: speechThresholdDB)
        guard trimmedBytes.count >= Int(sampleRate * 0.2) * 2 else { return }
        let wavData = createWAV(from: trimmedBytes, sampleRate: Int(sampleRate))

        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("theater_\(UUID().uuidString).wav")
        do {
            try wavData.write(to: tempFile)
        } catch {
            NSLog("[VoiceIME] ⚠️ 一時ファイル保存失敗: %@", error.localizedDescription)
            return
        }

        let totalDuration = Double(endSample) / sampleRate
        let threshold = self.speechThresholdDB

        // VAD（声が含まれているか）
        let metrics = AudioAnalysisService.shared.analyze(audioFileURL: tempFile, thresholdDB: threshold)
        if metrics.isSilence || !metrics.hasSpeech {
            try? FileManager.default.removeItem(at: tempFile)
            return
        }

        self.isTranscribing = true
        let whisperPrompt = self.whisperPrompt
        let language = self.language
        let style = self.refinementStyle

        NSLog("[VoiceIME] 🎭 紙芝居トリガー (0〜%.2f秒, 息継ぎ検知) ➔ Whisper累積送信開始", totalDuration)

        self.currentProcessingTask?.cancel()
        self.currentProcessingTask = Task.detached { [weak self] in
            defer {
                try? FileManager.default.removeItem(at: tempFile)
                self?.queue.async {
                    self?.isTranscribing = false
                }
            }

            if Task.isCancelled { return }

            do {
                // 1. Whisper API に 0秒からの全音声を送信
                let transcribed = try await WhisperAPIService.shared.transcribe(
                    audioFileURL: tempFile,
                    baseURL: whisperConfig.baseURL,
                    apiKey: whisperConfig.apiKey,
                    model: whisperConfig.model,
                    mode: .transcriptions,
                    prompt: whisperPrompt,
                    language: language
                )

                if Task.isCancelled { return }

                let cleanTranscribed = transcribed.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanTranscribed.isEmpty else { return }

                // 🌟 ログ: 1. Whisperから逐次送られてきた文字列
                PipelineLogger.shared.logWhisperReceived(type: "途中息継ぎ速報", text: cleanTranscribed)

                // 🌟 【ステップ1 & ステップ3: 差分表示】
                // すでに前回の推敲テキスト(latestRefinedText)がある場合：
                // 前回の推敲テキストをそのまま残し、今回のWhisperとの差分(delta)だけを後ろに繋げて表示！
                // 差分が安全に抽出できない（文頭から書き直された等）場合は、無理に連結せず最新Whisper全文を表示！
                var textToRefine = cleanTranscribed
                self?.queue.sync {
                    guard let self = self, self.isRunning else { return }
                    if self.isLLMEnabled && !self.latestRefinedText.isEmpty && !self.lastWhisperBaseText.isEmpty {
                        if let delta = Self.extractDelta(newText: cleanTranscribed, baseText: self.lastWhisperBaseText), !delta.isEmpty {
                            let combined = Self.combineRefinedWithDelta(refined: self.latestRefinedText, delta: delta)
                            textToRefine = combined
                            NSLog("[VoiceIME] ⚡ Whisper差分連結表示 (ステップ3): [推敲済み: %@ + 差分: %@]", self.latestRefinedText, delta)
                        } else {
                            textToRefine = cleanTranscribed
                            NSLog("[VoiceIME] ⚡ Whisper全文表示 (差分特定不可または大幅更新): [%@]", cleanTranscribed)
                        }
                    } else {
                        self.latestRefinedText = cleanTranscribed
                        NSLog("[VoiceIME] ⚡ 初回Whisper速報表示 (ステップ1): [%@]", cleanTranscribed)
                    }

                    // ユーザー辞書・音声記号置換を適用して即座にプレビュー表示
                    let preprocessed = Self.applyDictionaryRules(to: textToRefine)
                    Task { @MainActor in
                        FloatingPreviewController.shared.updatePipelineText(preprocessed)
                    }
                }

                if Task.isCancelled { return }

                // 辞書置換済みのテキストを中間推敲および表示のベースにする
                let preprocessedBase = Self.applyDictionaryRules(to: textToRefine)
                var finalText = preprocessedBase

                // 🌟 【ステップ2: 息継ぎ時の中間推敲】
                // 1. 極端に短い断片（12文字未満）はLLMが文脈不足でハルシネーションを起こしやすいため推敲しない
                // 2. Sarashina等のレート制限（6 RPM等）に配慮し、中間推敲は最低10秒間隔で実行する（キー解放時の確定推敲枠を確実に温存）
                let now = CFAbsoluteTimeGetCurrent()
                var shouldRunIntermediateLLM = false
                self?.queue.sync {
                    guard let self = self, self.isRunning else { return }
                    let timeSinceLastLLM = now - self.lastLLMRefineTime
                    if self.isLLMEnabled && preprocessedBase.count >= 12 && timeSinceLastLLM >= self.minLLMRefineIntervalSeconds {
                        self.lastLLMRefineTime = now
                        shouldRunIntermediateLLM = true
                        NSLog("[VoiceIME] ⏱️ 10秒間隔トリガー到達 (前回到達から%.1f秒経過) ➔ 中間LLM推敲を実行します", timeSinceLastLLM)
                    }
                }

                if shouldRunIntermediateLLM, let llmCfg = llmConfig, !llmCfg.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // 🌟 ログ: 2. Whisperから推敲LLMへ送られる文字列 (辞書置換済み)
                    PipelineLogger.shared.logLLMInput(type: "途中息継ぎ推敲", text: preprocessedBase)
                    do {
                        let refined = try await LLMService.shared.refine(
                            text: preprocessedBase,
                            baseURL: llmCfg.baseURL,
                            apiKey: llmCfg.apiKey,
                            model: llmCfg.model,
                            promptHint: whisperPrompt,
                            style: style,
                            isCustom: llmCfg.isCustom
                        )
                        let cleanRefined = refined.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleanRefined.isEmpty {
                            // LLM推敲後にもセーフティとして辞書置換を適用
                            finalText = Self.applyDictionaryRules(to: cleanRefined)
                            // 🌟 ログ: 3. 推敲LLMから修正され戻される文字列
                            PipelineLogger.shared.logLLMOutput(type: "途中息継ぎ推敲", text: finalText)
                        }
                    } catch {
                        NSLog("[VoiceIME] ⚠️ 紙芝居推敲スキップ: %@", error.localizedDescription)
                        PipelineLogger.shared.logLLMOutput(type: "途中息継ぎ推敲[失敗]", text: "[推敲エラー: \(error)]")
                    }
                }

                if Task.isCancelled { return }

                let capturedFinalText = finalText
                self?.queue.async {
                    guard let self = self, self.isRunning else { return }
                    self.latestRefinedText = capturedFinalText
                    self.lastWhisperBaseText = cleanTranscribed
                    Task { @MainActor in
                        FloatingPreviewController.shared.updatePipelineText(capturedFinalText)
                        NSLog("[VoiceIME] 🎭 推敲完了全置換 (ステップ2/4): [%@]", capturedFinalText)
                    }
                }
            } catch {
                NSLog("[VoiceIME] ⚠️ 紙芝居Whisper送信失敗: %@", error.localizedDescription)
            }
        }
    }

    /// 録音停止時の完了処理（キー解放時: 最後の一つが戻ってくるのを確実に待ってからペースト）
    public func finishAndFinalize(completion: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self = self else {
                completion("")
                return
            }
            self.isRunning = false

            let totalSamples = self.pcmDataBuffer.count / 2
            guard totalSamples > 0, let whisperConfig = self.currentWhisperConfig else {
                completion(self.latestRefinedText)
                return
            }

            // 0秒からキー解放の瞬間までの完全な累積音声を取り出し、前後の無音を確実にカット！
            let cumulativeBytes = self.pcmDataBuffer
            let trimmedBytes = Self.trimSilence(pcmData: cumulativeBytes, sampleRate: self.sampleRate, speechThresholdDB: self.speechThresholdDB)
            let wavData = self.createWAV(from: trimmedBytes, sampleRate: Int(self.sampleRate))

            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent("final_theater_\(UUID().uuidString).wav")
            do {
                try wavData.write(to: tempFile)
            } catch {
                completion(self.latestRefinedText)
                return
            }

            let whisperPrompt = self.whisperPrompt
            let language = self.language
            let isLLMEnabled = self.isLLMEnabled
            let style = self.refinementStyle
            let llmConfig = self.currentLLMConfig
            let totalDuration = Double(totalSamples) / self.sampleRate

            NSLog("[VoiceIME] 🏁 録音終了: キーがリリースされました。最後の一つが戻ってくるまで待機中 (0〜%.2f秒の音声を無音カット後に最終送信)", totalDuration)

            self.currentProcessingTask?.cancel()
            self.currentProcessingTask = nil

            Task.detached { [weak self] in
                guard let self = self else { return }
                defer { try? FileManager.default.removeItem(at: tempFile) }

                do {
                    // Whisper API に全音声を送信し、最後の一つの完了を確実に待つ
                    let transcribed = try await WhisperAPIService.shared.transcribe(
                        audioFileURL: tempFile,
                        baseURL: whisperConfig.baseURL,
                        apiKey: whisperConfig.apiKey,
                        model: whisperConfig.model,
                        mode: .transcriptions,
                        prompt: whisperPrompt,
                        language: language
                    )
                    let clean = transcribed.trimmingCharacters(in: .whitespacesAndNewlines)

                    // 1. 最終 Whisper 完了時の速報表示（前回の推敲文字列があれば差分連結して表示）
                    let capturedFinalWhisper = clean
                    // 🌟 ログ: 1. Whisperから逐次送られてきた文字列
                    PipelineLogger.shared.logWhisperReceived(type: "最終確定速報", text: capturedFinalWhisper)

                    var textToRefine = clean
                    self.queue.sync {
                        if self.isLLMEnabled && !self.latestRefinedText.isEmpty && !self.lastWhisperBaseText.isEmpty {
                            if let delta = Self.extractDelta(newText: capturedFinalWhisper, baseText: self.lastWhisperBaseText), !delta.isEmpty {
                                let combined = Self.combineRefinedWithDelta(refined: self.latestRefinedText, delta: delta)
                                textToRefine = combined
                                NSLog("[VoiceIME] ⚡ 最終Whisper差分連結表示 (ステップ3): [推敲済み: %@ + 差分: %@]", self.latestRefinedText, delta)
                            } else {
                                textToRefine = capturedFinalWhisper
                                NSLog("[VoiceIME] ⚡ 最終Whisper全文表示 (差分特定不可または大幅更新): [%@]", capturedFinalWhisper)
                            }
                        } else {
                            self.latestRefinedText = capturedFinalWhisper
                            NSLog("[VoiceIME] ⚡ 最終Whisper速報表示 (ステップ1): [%@]", capturedFinalWhisper)
                        }
                        // ユーザー辞書・音声記号置換を適用して即座にプレビュー表示
                        let preprocessedPreview = Self.applyDictionaryRules(to: textToRefine)
                        Task { @MainActor in
                            FloatingPreviewController.shared.updatePipelineText(preprocessedPreview)
                        }
                    }

                    // 🌟 最終確定時は、最初から最後まで通しで認識された完全なWhisper結果（capturedFinalWhisper）を最優先で使用！
                    let rawBaseForLLM = !capturedFinalWhisper.isEmpty ? capturedFinalWhisper : textToRefine
                    let preprocessedForLLM = Self.applyDictionaryRules(to: rawBaseForLLM)
                    var finalText = preprocessedForLLM

                    // 2. 推敲が有効な場合は LLM の推敲完了も確実に待つ（ステップ4）
                    if isLLMEnabled, let llmCfg = llmConfig, !preprocessedForLLM.isEmpty, !llmCfg.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // 🌟 ログ: 2. Whisperから推敲LLMへ送られる文字列（辞書置換済み）
                        PipelineLogger.shared.logLLMInput(type: "最終確定推敲", text: preprocessedForLLM)
                        do {
                            let refined = try await LLMService.shared.refine(
                                text: preprocessedForLLM,
                                baseURL: llmCfg.baseURL,
                                apiKey: llmCfg.apiKey,
                                model: llmCfg.model,
                                promptHint: whisperPrompt,
                                style: style,
                                isCustom: llmCfg.isCustom
                            )
                            let cleanRefined = refined.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !cleanRefined.isEmpty {
                                // LLM推敲後にもセーフティとして辞書置換を適用
                                finalText = Self.applyDictionaryRules(to: cleanRefined)
                                NSLog("[VoiceIME] ✨ 最終推敲成功 (ステップ4): [%@]", finalText)
                                // 🌟 ログ: 3. 推敲LLMから修正され戻される文字列
                                PipelineLogger.shared.logLLMOutput(type: "最終確定推敲", text: finalText)
                            }
                        } catch {
                            NSLog("[VoiceIME] ⚠️ 最終LLM推敲失敗 (%@): %@。辞書置換済みWhisperテキストを使用します", llmCfg.model, error.localizedDescription)
                            PipelineLogger.shared.logLLMOutput(type: "最終確定推敲[失敗]", text: "[推敲エラー: \(error)]")
                        }
                    }

                    let result = !finalText.isEmpty ? finalText : preprocessedForLLM
                    self.queue.async {
                        // 次回録音セッションへの残留を防ぐため、バッファと前回の推敲状態を完全リセット
                        self.latestRefinedText = ""
                        self.lastWhisperBaseText = ""
                        self.pcmDataBuffer.removeAll(keepingCapacity: false)
                    }
                    NSLog("[VoiceIME] ✅ 最後の一つが到着しました: [%@]", result)

                    Task { @MainActor in
                        FloatingPreviewController.shared.updatePipelineText(result)
                    }

                    // 🌟 ログ: セッション完了（確定出力テキスト）
                    PipelineLogger.shared.logSessionEnd(finalText: result)

                    completion(result)
                } catch {
                    let fallbackResult = Self.applyDictionaryRules(to: self.latestRefinedText)
                    NSLog("[VoiceIME] ⚠️ 最終送信失敗、手持ちの最新テキストで完了: [%@]", fallbackResult)
                    PipelineLogger.shared.logSessionEnd(finalText: fallbackResult)
                    completion(fallbackResult)
                }
            }
        }
    }

    /// パイプラインの中断・破棄
    public func cancel() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.currentProcessingTask?.cancel()
            self.currentProcessingTask = nil
            self.isRunning = false
            self.pcmDataBuffer.removeAll(keepingCapacity: false)
            self.latestRefinedText = ""
            self.lastWhisperBaseText = ""
            self.isTranscribing = false
        }
    }

    /// Int16 PCMデータの前後の無音・微小ノイズ区間を高速にトリミング（VAD）
    /// - 開始前の静寂（0.5〜1.5秒）をカットして Whisperの冒頭英語ハルシネーション（Thank you等）を防止
    /// - 終了後の静寂（0.4〜0.8秒）をカットして Whisperの「ご視聴ありがとうございました」ハルシネーションを防止
    /// - 語尾の自然なフェードアウト（250ms）は確実に保護
    public static func trimSilence(pcmData: Data, sampleRate: Double, speechThresholdDB: Float) -> Data {
        let totalSamples = pcmData.count / 2
        guard totalSamples > 0 else { return pcmData }

        let windowSize = Int(sampleRate * 0.05) // 50ms ウィンドウ
        let stepSize = Int(sampleRate * 0.025)  // 25ms ステップ
        guard windowSize > 0, totalSamples >= windowSize else { return pcmData }

        // 発話開始判定しきい値
        let startThresholdLinear = pow(10.0, speechThresholdDB / 20.0) * 32767.0
        // 語尾終了判定しきい値（語尾の減衰を救うため、開始しきい値より約6dB低い音量まで拾う。最大でも -42 dBFS）
        let trailingFloorDB = min(speechThresholdDB - 6.0, -42.0)
        let trailingThresholdLinear = pow(10.0, trailingFloorDB / 20.0) * 32767.0

        var firstSpeechSample: Int? = nil
        var lastSpeechSample: Int? = nil

        pcmData.withUnsafeBytes { rawPtr in
            guard let int16Ptr = rawPtr.bindMemory(to: Int16.self).baseAddress else { return }

            var pos = 0
            while pos + windowSize <= totalSamples {
                var sumSq: Double = 0.0
                for i in pos..<(pos + windowSize) {
                    let s = Double(int16Ptr[i])
                    sumSq += s * s
                }
                let rms = sqrt(sumSq / Double(windowSize))
                if rms >= Double(startThresholdLinear) {
                    if firstSpeechSample == nil {
                        firstSpeechSample = pos
                    }
                }
                if rms >= Double(trailingThresholdLinear) && firstSpeechSample != nil {
                    lastSpeechSample = pos + windowSize
                }
                pos += stepSize
            }
        }

        guard let first = firstSpeechSample, let last = lastSpeechSample else {
            return pcmData
        }

        // 先頭マージン 120ms、末尾マージン 250ms を確保
        let leadingMargin = Int(sampleRate * 0.12)
        let trailingMargin = Int(sampleRate * 0.25)

        let startSample = max(0, first - leadingMargin)
        let endSample = min(totalSamples, last + trailingMargin)
        guard endSample > startSample else { return pcmData }

        let startByte = startSample * 2
        let endByte = endSample * 2
        let trimmed = pcmData.subdata(in: startByte..<endByte)
        let originalSec = Double(totalSamples) / sampleRate
        let trimmedSec = Double(trimmed.count / 2) / sampleRate
        NSLog("[VoiceIME] ✂️ PCM無音トリミング: %.2f秒 ➔ %.2f秒 (先頭カット: %.2f秒, 末尾カット: %.2f秒)",
              originalSec, trimmedSec, Double(startSample) / sampleRate, Double(totalSamples - endSample) / sampleRate)
        return trimmed
    }

    /// PCM データから RIFF WAVE ヘッダー付き Data を生成
    private func createWAV(from pcmData: Data, sampleRate: Int) -> Data {
        var wav = Data()
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate * Int(channels) * Int(bitsPerSample) / 8)
        let blockAlign = UInt16(channels * bitsPerSample / 8)
        let totalDataLen = UInt32(pcmData.count)
        let totalFileLen = totalDataLen + 36

        wav.append(Data("RIFF".utf8))
        var fileLen = totalFileLen
        wav.append(Data(bytes: &fileLen, count: 4))
        wav.append(Data("WAVE".utf8))
        wav.append(Data("fmt ".utf8))
        var subchunk1Size: UInt32 = 16
        wav.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat: UInt16 = 1 // PCM
        wav.append(Data(bytes: &audioFormat, count: 2))
        var numChannels = channels
        wav.append(Data(bytes: &numChannels, count: 2))
        var sRate = UInt32(sampleRate)
        wav.append(Data(bytes: &sRate, count: 4))
        var bRate = byteRate
        wav.append(Data(bytes: &bRate, count: 4))
        var bAlign = blockAlign
        wav.append(Data(bytes: &bAlign, count: 2))
        var bps = bitsPerSample
        wav.append(Data(bytes: &bps, count: 2))
        wav.append(Data("data".utf8))
        var dataLen = totalDataLen
        wav.append(Data(bytes: &dataLen, count: 4))
        wav.append(pcmData)
        return wav
    }

    // MARK: - 差分抽出および連結ロジック (ステップ3: 推敲済み + 新規Whisper差分)

    /// 新しく到着した累積Whisperテキストから、前回の推敲済みベースとなったWhisperテキストとの差分を取り出す
    /// 安全に差分が抽出できない（文頭から書き直された、または不整合の）場合は nil を返す
    /// （※絶対に全文を差分と誤認して返さないことで、文章の二重重複を100%防止）
    public static func extractDelta(newText: String, baseText: String) -> String? {
        let cleanNew = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBase = baseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBase.isEmpty else { return cleanNew }
        guard !cleanNew.isEmpty else { return nil }

        func cleanLeadingPunctuation(_ s: String) -> String {
            var res = s.trimmingCharacters(in: .whitespacesAndNewlines)
            while let first = res.first, "、，,。.\t 　".contains(first) {
                res.removeFirst()
                res = res.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return res
        }

        // 1. 完全な前方一致
        if cleanNew.hasPrefix(cleanBase) {
            let delta = String(cleanNew.dropFirst(cleanBase.count))
            return cleanLeadingPunctuation(delta)
        }

        // 2. 句読点・空白を無視した前方一致（Whisperが中間に読点を補ったり空白を挿入したケース）
        let baseChars = Array(cleanBase.filter { !$0.isWhitespace && !$0.isPunctuation })
        if !baseChars.isEmpty {
            var newCharIndices: [String.Index] = []
            var filteredNewChars: [Character] = []
            for idx in cleanNew.indices {
                let c = cleanNew[idx]
                if !c.isWhitespace && !c.isPunctuation {
                    filteredNewChars.append(c)
                    newCharIndices.append(idx)
                }
            }

            if filteredNewChars.count > baseChars.count {
                var matches = true
                for i in 0..<baseChars.count {
                    if filteredNewChars[i] != baseChars[i] {
                        matches = false
                        break
                    }
                }
                if matches {
                    let lastMatchedIdx = newCharIndices[baseChars.count - 1]
                    let nextIdx = cleanNew.index(after: lastMatchedIdx)
                    let delta = String(cleanNew[nextIdx...])
                    return cleanLeadingPunctuation(delta)
                }
            }
        }

        // 3. あいまいアンカー検索（Whisperが文頭の漢字認識を変えた場合の耐性）
        // cleanBase が短すぎる場合（10文字未満）は誤マッチしやすいためスキップ
        if cleanBase.count >= 10 {
            let anchorLengths = [12, 10, 8, 6]
            for len in anchorLengths {
                if cleanBase.count >= len {
                    let anchor = String(cleanBase.suffix(len))
                    if let range = cleanNew.range(of: anchor) {
                        let delta = String(cleanNew[range.upperBound...])
                        let cleanedDelta = cleanLeadingPunctuation(delta)
                        let matchOffset = cleanNew.distance(from: cleanNew.startIndex, to: range.lowerBound)
                        // アンカー出現位置が cleanNew の先頭から cleanBase の半分以上進んだ位置にあること
                        if matchOffset >= (cleanBase.count / 2) && !cleanedDelta.isEmpty {
                            return cleanedDelta
                        }
                    }
                }
            }
        }

        // 4. 一致が確認できない場合は安全のため nil（全体を差分として連結しない！）
        return nil
    }

    /// 推敲済みテキストと、新しく喋ったWhisper差分テキストをスマートに連結
    public static func combineRefinedWithDelta(refined: String, delta: String) -> String {
        let cleanRefined = refined.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanDelta.isEmpty else { return cleanRefined }
        guard !cleanRefined.isEmpty else { return cleanDelta }

        // 日本語・英語の区切り調整（末尾・先頭がASCII文字/記号の場合はスペースを挟む）
        if let lastChar = cleanRefined.last, let firstChar = cleanDelta.first,
           lastChar.isASCII && firstChar.isASCII {
            return "\(cleanRefined) \(cleanDelta)"
        }
        return "\(cleanRefined)\(cleanDelta)"
    }

    // MARK: - ユーザー辞書・記号置換ヘルパー

    /// Whisper認識テキストまたは推敲テキストに対し、音声コマンド正規化（「開業」「かいぎょう」「改行」➔ \n、ピリオド、括弧等）およびユーザー辞書ルールを完全適用
    public static func applyDictionaryRules(to text: String, isJapanese: Bool = true) -> String {
        guard !text.isEmpty else { return "" }
        // 1. PunctuationService による音声コマンド正規化（「開業」「かいぎょう」「改行」の改行変換、ピリオド、括弧、びっくりマークなど）および辞書置換
        let formatted = PunctuationService.shared.format(text: text, isJapanese: isJapanese)
        // 2. 句読点の正規化
        return LLMService.normalizePunctuation(for: formatted)
    }
}

