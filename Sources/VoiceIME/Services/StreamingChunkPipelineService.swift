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
    private var preRollByteCount: Int = 0
    private var sampleRate: Double = 16000.0
    private var isRunning: Bool = false
    private var hasPreStartedCapture: Bool = false
    private var isStreamingTriggerEnabled: Bool = true

    // 息継ぎ検知 & レート制限パラメータ（nanoの60 RPMを活かし1.5秒間隔で発話後に送信、無音放置時は完全停止）
    private let minIntervalSeconds: Double = 1.5 // 途中Whisperの最低インターバル (1.5秒空いたら投げる)
    private var silenceThresholdRMS: Float = 0.015 // 音声入力しきい値と連動（デフォルト約 -36 dBFS）
    private let minSilenceDuration: Double = 0.12 // 約0.12秒以上の小休止・息継ぎ
    private var speechThresholdDB: Float = -38.0

    // 状態管理
    private var lastTriggerTime: CFAbsoluteTime = 0.0
    private var lastTriggerSampleCount: Int = 0
    private var speechFramesSinceLastTrigger: Int = 0
    private var quietTailFramesSinceLastTrigger: Int = 0
    private var totalSpeechFrameCount: Int = 0
    private var recentRMS: Float = 0.0
    private var silentFrameCount: Int = 0
    private var isCapturePaused: Bool = false
    private var isTranscribing: Bool = false {
        didSet {
            let val = isTranscribing
            DispatchQueue.main.async { [weak self] in
                self?.onTranscriptionStateChanged?(val)
            }
        }
    }
    public var onTranscriptionStateChanged: ((Bool) -> Void)?

    private var hasPendingRetry: Bool = false
    private var lastTriggerHadPause: Bool = true
    private var activeTaskID: UUID = UUID()
    private var currentProcessingTask: Task<Void, Never>?
    private var currentLLMTask: Task<Void, Never>?
    private var quietTailCatchUpCount: Int = 0 // 実発話を挟まない小声語尾キャッチアップの連続回数（環境ノイズ暴走防止）
    private var isRefiningLLM: Bool = false {
        didSet {
            let val = isRefiningLLM
            DispatchQueue.main.async { [weak self] in
                self?.onRefinementStateChanged?(val)
            }
        }
    }
    public var onRefinementStateChanged: ((Bool) -> Void)?

    public var isRefining: Bool {
        return queue.sync { isRefiningLLM }
    }

    public var isTranscribingAudio: Bool {
        return queue.sync { isTranscribing }
    }
    private var isLatestTextRefinedByLLM: Bool = false
    private var lastRefinedSampleCount: Int = 0
    private var lastAttemptedLLMInput: String = ""

    // ホールド中LLM推敲のインターバル（Sarashinaの6 RPM制限を厳守するため最低10.5秒間隔とし、言い終わり時はクールダウン明けに自動実行）
    private var lastLLMRefineTime: CFAbsoluteTime = 0.0
    private let minLLMRefineIntervalSeconds: Double = 10.5

    // 紙芝居テキスト管理
    private var latestRefinedText: String = ""
    private var lastWhisperBaseText: String = ""

    // 設定
    private var primaryWhisperConfig: WhisperAPIService.TranscribeConfig?
    private var backupWhisperConfig: WhisperAPIService.TranscribeConfig?
    private var currentWhisperConfig: (baseURL: String, apiKey: String?, model: String)? {
        guard let p = primaryWhisperConfig else { return nil }
        return (p.baseURL, p.apiKey, p.model)
    }
    private var currentLLMConfig: (baseURL: String, apiKey: String?, model: String, isCustom: Bool)?
    private var refinementStyle: RefinementStyle = .casual
    private var isLLMEnabled: Bool = true
    private var whisperPrompt: String? = nil
    private var language: String? = "ja"
    private var isJapanese: Bool {
        if let lang = self.language?.lowercased() {
            return !lang.starts(with: "en")
        }
        return true
    }

    private init() {}

    /// キー押下の瞬間（0ms）に最優先で録音バッファの受け入れを開始する
    /// （APIキー取得・プロンプト構築・UI表示よりも前にマイク波形を1サンプルも漏らさず蓄積開始する）
    public func prepareImmediateCapture(speechThresholdDB: Float, isStreamingTriggerEnabled: Bool = true) {
        queue.sync {
            self.currentProcessingTask?.cancel()
            self.currentProcessingTask = nil
            self.currentLLMTask?.cancel()
            self.currentLLMTask = nil
            self.quietTailCatchUpCount = 0
            self.pcmDataBuffer.removeAll(keepingCapacity: true)
            self.preRollByteCount = 0
            self.lastTriggerTime = 0.0
            self.lastTriggerSampleCount = 0
            self.speechFramesSinceLastTrigger = 0
            self.quietTailFramesSinceLastTrigger = 0
            self.totalSpeechFrameCount = 0
            self.recentRMS = 0.0
            self.silentFrameCount = 0
            self.latestRefinedText = ""
            self.lastWhisperBaseText = ""
            self.lastLLMRefineTime = 0.0
            self.isTranscribing = false
            self.isRefiningLLM = false
            self.isLatestTextRefinedByLLM = false
            self.lastRefinedSampleCount = 0
            self.lastAttemptedLLMInput = ""
            self.hasPendingRetry = false
            self.lastTriggerHadPause = true
            self.speechThresholdDB = speechThresholdDB
            self.silenceThresholdRMS = pow(10.0, speechThresholdDB / 20.0)
            self.isStreamingTriggerEnabled = isStreamingTriggerEnabled
            self.isRunning = true
            self.hasPreStartedCapture = true
        }
    }

    /// パイプラインの開始
    public func start(
        whisperConfig: (baseURL: String, apiKey: String?, model: String),
        primaryProvider: APIProvider = .groq,
        backupWhisperConfig: (provider: APIProvider, baseURL: String, apiKey: String?, model: String)? = nil,
        llmConfig: (baseURL: String, apiKey: String?, model: String, isCustom: Bool),
        style: RefinementStyle,
        isLLMEnabled: Bool = true,
        whisperPrompt: String? = nil,
        language: String? = "ja",
        speechThresholdDB: Float = -38.0
    ) {
        PipelineLogger.shared.logDebug("🎭 StreamingChunkPipelineService.start() 呼び出し (baseURL: \(whisperConfig.baseURL), model: \(whisperConfig.model), hasKey: \(whisperConfig.apiKey != nil), backup: \(backupWhisperConfig?.provider.displayName ?? "なし"))")
        queue.async { [weak self] in
            guard let self = self else { return }
            if !self.hasPreStartedCapture {
                self.currentProcessingTask?.cancel()
                self.currentProcessingTask = nil
                self.currentLLMTask?.cancel()
                self.currentLLMTask = nil
                self.quietTailCatchUpCount = 0
                self.pcmDataBuffer.removeAll(keepingCapacity: true)
                self.preRollByteCount = 0
                self.lastTriggerTime = 0.0
                self.lastTriggerSampleCount = 0
                self.speechFramesSinceLastTrigger = 0
                self.quietTailFramesSinceLastTrigger = 0
                self.totalSpeechFrameCount = 0
                self.recentRMS = 0.0
                self.silentFrameCount = 0
                self.latestRefinedText = ""
                self.lastWhisperBaseText = ""
                self.lastLLMRefineTime = 0.0
                self.isTranscribing = false
                self.isRefiningLLM = false
                self.isLatestTextRefinedByLLM = false
                self.lastRefinedSampleCount = 0
                self.lastAttemptedLLMInput = ""
                self.hasPendingRetry = false
                self.lastTriggerHadPause = true
            }
            self.hasPreStartedCapture = false
            self.primaryWhisperConfig = WhisperAPIService.TranscribeConfig(
                provider: primaryProvider,
                baseURL: whisperConfig.baseURL,
                apiKey: whisperConfig.apiKey,
                model: whisperConfig.model
            )
            if let backup = backupWhisperConfig {
                self.backupWhisperConfig = WhisperAPIService.TranscribeConfig(
                    provider: backup.provider,
                    baseURL: backup.baseURL,
                    apiKey: backup.apiKey,
                    model: backup.model
                )
            } else {
                self.backupWhisperConfig = nil
            }
            self.currentLLMConfig = llmConfig
            self.refinementStyle = style
            self.isLLMEnabled = isLLMEnabled
            self.whisperPrompt = whisperPrompt
            self.language = language
            self.speechThresholdDB = speechThresholdDB
            // ユーザー設定の音声入力しきい値（settings.audioThresholdDB）に直接結びつけ
            self.silenceThresholdRMS = pow(10.0, speechThresholdDB / 20.0)
            self.isCapturePaused = false
            self.isStreamingTriggerEnabled = true
            self.isRunning = true
            NSLog("[VoiceIME] 🎭 累積・紙芝居ストリーミングパイプラインを開始しました (音声しきい値: %.1f dB / RMS %.4f, 先行蓄積バイト数: %d)", speechThresholdDB, self.silenceThresholdRMS, self.pcmDataBuffer.count)
        }
    }

    /// マイク入力バッファの受信と蓄積・息継ぎスキャン
    public func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, isPreRoll: Bool = false) {
        queue.async { [weak self] in
            guard let self = self, self.isRunning, !self.isCapturePaused else { return }

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

            // プリロール（キー押下直前のリングバッファ音声）は波形データとして先頭に保持しつつ、
            // 無音放置時の誤トリガーを防ぐため発話フレーム時間カウントやトリガー判定は行わない
            if isPreRoll {
                self.preRollByteCount += int16Data.count
                return
            }

            let isSpeech = (rms >= self.silenceThresholdRMS)
            // 語尾の自然な減衰（「〜ました」「〜ない」「〜です」「〜ございます」等）も取りこぼさないよう、
            // 発話開始後の直近350ms以内の減衰音（しきい値 -6.0dB 相当 = RMS * 0.50）は発話フレームに加算する（無音フレームカウント自体は阻害しない）
            // また、少し息継ぎした後でも小声で語尾（「ございます」等）が発声された場合（RMS * 0.50 以上かつノイズフロア -45dB 以上）は quietTailFramesSinceLastTrigger として捕捉する
            let noiseFloorRMS = pow(10.0, Float(-45.0) / 20.0)
            let isTrailingSpeech = (!isSpeech && self.totalSpeechFrameCount > 0 && self.silentFrameCount < Int(self.sampleRate * 0.35) && rms >= self.silenceThresholdRMS * 0.50)
            let isQuietTailSpeech = (!isSpeech && self.totalSpeechFrameCount > 0 && rms >= max(self.silenceThresholdRMS * 0.50, noiseFloorRMS))
            if isSpeech {
                self.silentFrameCount = 0
                self.quietTailCatchUpCount = 0
                self.speechFramesSinceLastTrigger += frameLength
                self.totalSpeechFrameCount += frameLength
            } else if isTrailingSpeech {
                self.silentFrameCount = 0
                self.speechFramesSinceLastTrigger += frameLength
                self.totalSpeechFrameCount += frameLength
            } else if isQuietTailSpeech {
                self.silentFrameCount = 0
                self.quietTailCatchUpCount = 0
                self.quietTailFramesSinceLastTrigger += frameLength
            } else {
                self.silentFrameCount += frameLength
            }

            guard self.isStreamingTriggerEnabled, self.currentWhisperConfig != nil else { return }

            // 2. 息継ぎ（無音・小休止）＆ レート制限＆新発話の判定
            let totalSamples = self.pcmDataBuffer.count / 2
            let totalAudioDuration = Double(totalSamples) / self.sampleRate
            let totalSpeechDuration = Double(self.totalSpeechFrameCount) / self.sampleRate
            let newSpeechDuration = Double(self.speechFramesSinceLastTrigger) / self.sampleRate
            let quietTailDuration = Double(self.quietTailFramesSinceLastTrigger) / self.sampleRate
            let silentDuration = Double(self.silentFrameCount) / self.sampleRate
            let now = CFAbsoluteTimeGetCurrent()
            let timeSinceLastTrigger = now - self.lastTriggerTime

            // 前回トリガーが語中（息継ぎなし: silent < 0.18s）で発火した後に話し終えて小休止（silent >= 0.25s）に入った場合、
            // または前回トリガー後に小声の語尾（quietTailDuration >= 0.08s）が発声されて小休止（silent >= 0.25s）に入った場合の語尾キャッチアップ判定
            let needsQuietTailCatchUp = (quietTailDuration >= 0.08 && silentDuration >= 0.25 && self.quietTailCatchUpCount < 1)
            let needsNormalTailCatchUp = (!self.lastTriggerHadPause && silentDuration >= 0.25)

            // 🌟 5.0秒言い終わり待機フラッシュ（Flush Trigger）:
            // 通常の会話中の句読点や思考の間（数秒程度）で誤判定することを防ぎつつ、
            // 話し終えてキーを押したまま 5.0秒 待機した場合、未送信音声があれば言い終わりと判定して Whisper へ累積送信！
            let hasUnsentAudioSinceLast = (newSpeechDuration > 0 || quietTailDuration >= 0.08)
            let needsWaitingFlush = (hasUnsentAudioSinceLast && silentDuration >= 5.0 && timeSinceLastTrigger >= self.minIntervalSeconds)
            let needsTailCatchUp = (needsNormalTailCatchUp || needsQuietTailCatchUp || needsWaitingFlush)

            let isFirstTrigger = (self.lastTriggerSampleCount == 0)
            let shouldTrigger = Self.evaluateTrigger(
                isFirstTrigger: isFirstTrigger,
                totalSpeechDuration: totalSpeechDuration,
                newSpeechDuration: newSpeechDuration,
                silentDuration: silentDuration,
                timeSinceLastTrigger: timeSinceLastTrigger,
                minIntervalSeconds: self.minIntervalSeconds,
                minSilenceDuration: self.minSilenceDuration,
                isTranscribing: self.isTranscribing,
                hasPendingRetry: self.hasPendingRetry,
                needsTailCatchUp: needsTailCatchUp
            )

            if shouldTrigger {
                let consumedSpeechFrames = self.speechFramesSinceLastTrigger
                let hadPause = (silentDuration >= 0.18)
                self.lastTriggerTime = now
                self.lastTriggerSampleCount = totalSamples
                self.speechFramesSinceLastTrigger = 0
                self.quietTailFramesSinceLastTrigger = 0
                if needsQuietTailCatchUp || needsWaitingFlush { self.quietTailCatchUpCount += 1 }
                self.hasPendingRetry = false
                self.lastTriggerHadPause = hadPause
                PipelineLogger.shared.logDebug("⚡ 紙芝居トリガー成立! (totalAudio: \(String(format: "%.2f", totalAudioDuration))s, totalSpeech: \(String(format: "%.2f", totalSpeechDuration))s, newSpeech: \(String(format: "%.2f", newSpeechDuration))s, quietTail: \(String(format: "%.2f", quietTailDuration))s, silent: \(String(format: "%.2f", silentDuration))s, isFirst: \(isFirstTrigger), tailCatchUp: \(needsTailCatchUp))")
                self.processCumulativePaperTheater(to: totalSamples, consumedSpeechFrames: consumedSpeechFrames)
            } else if !self.isTranscribing && !self.isRefiningLLM && !self.isLatestTextRefinedByLLM && self.speechFramesSinceLastTrigger == 0 && quietTailDuration < 0.08 && silentDuration >= 5.0 && !self.latestRefinedText.isEmpty {
                // 話し終えて5.0秒以上ホールドしたまま落ち着いた時点で、未推敲のテキストがあれば最終LLM推敲を走らせ、ホールド中に最終文字列まで整える
                self.startHoldTimeLLMRefinementIfNeeded(
                    whisperSnapshot: self.lastWhisperBaseText,
                    textToRefine: self.latestRefinedText,
                    endSample: self.lastTriggerSampleCount,
                    forceImmediate: true
                )
            }
        }
    }

    /// 0秒〜endSample までの累積音声を丸ごと送信し、紙芝居のように画面を上書き更新
    private func processCumulativePaperTheater(to endSample: Int, consumedSpeechFrames: Int = 0) {
        guard primaryWhisperConfig != nil else {
            PipelineLogger.shared.logDebug("⚠️ primaryWhisperConfig が nil のためスキップ")
            return
        }
        guard !isTranscribing else {
            PipelineLogger.shared.logDebug("⏳ 直前のWhisperリクエストが送信中のため完了を待機 (キャンセル防止)")
            return
        }

        let endByte = min(endSample * 2, pcmDataBuffer.count)
        guard endByte > 0 else { return }

        // 🌟 核心: 常に「0秒（発話の最初）」から現在までの音声を取り出し、前後の無音をトリミング！
        let cumulativeBytes = pcmDataBuffer.subdata(in: 0..<endByte)
        let trimmedBytes = Self.trimSilence(pcmData: cumulativeBytes, sampleRate: sampleRate, speechThresholdDB: speechThresholdDB)
        guard trimmedBytes.count >= Int(sampleRate * 0.15) * 2 else {
            PipelineLogger.shared.logDebug("⚠️ トリミング後の音声が短すぎるためスキップ (\(trimmedBytes.count) bytes)")
            return
        }
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

        // VAD（完全な無音・ノイズのみをガード）
        let metrics = AudioAnalysisService.shared.analyze(audioFileURL: tempFile, thresholdDB: threshold)
        if metrics.isSilence {
            PipelineLogger.shared.logDebug("🔇 VADにより無音判定されたためスキップ (peak: \(metrics.peakPowerDB)dB)")
            try? FileManager.default.removeItem(at: tempFile)
            return
        }

        let taskID = UUID()
        self.activeTaskID = taskID
        self.isTranscribing = true
        let whisperPrompt = self.whisperPrompt
        let language = self.language

        PipelineLogger.shared.logDebug("🚀 Whisper API へ累積送信開始! (長さ: \(String(format: "%.2f", totalDuration))s)")
        NSLog("[VoiceIME] 🎭 紙芝居トリガー (0〜%.2f秒, 息継ぎ検知) ➔ Whisper累積送信開始", totalDuration)

        self.currentProcessingTask = Task.detached { [weak self] in
            defer {
                try? FileManager.default.removeItem(at: tempFile)
                self?.queue.async {
                    guard let self = self else { return }
                    if self.activeTaskID == taskID {
                        self.isTranscribing = false
                    }
                }
            }

            if Task.isCancelled { return }

            do {
                // 1. Whisper API に 0秒からの全音声を送信（動的タイムアウト & ヘッジド・フォールバック付き）
                guard let primary = self?.primaryWhisperConfig else { return }
                let (transcribed, effectiveProvider, fallbackRecord) = try await WhisperAPIService.shared.transcribeWithFallback(
                    audioFileURL: tempFile,
                    audioDuration: totalDuration,
                    primaryConfig: primary,
                    backupConfig: self?.backupWhisperConfig,
                    mode: .transcriptions,
                    prompt: whisperPrompt,
                    language: language
                )

                if let fallback = fallbackRecord {
                    await MainActor.run {
                        AppState.shared.lastFallbackRecord = fallback
                        AppState.shared.lastUsedWhisperProvider = effectiveProvider
                    }
                    PipelineLogger.shared.logDebug("🔄 [バックアップSTT発動] \(fallback.displayNotice)")
                } else {
                    await MainActor.run {
                        AppState.shared.lastUsedWhisperProvider = effectiveProvider
                    }
                }

                // Whisper通信自体は完了したため、中間LLM推敲の待機中に次の発話トリガーがブロックされないよう解除
                self?.queue.async {
                    guard let self = self else { return }
                    if self.activeTaskID == taskID {
                        self.isTranscribing = false
                    }
                }

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
                var previewToDisplay = ""
                var hasNewUnrefinedDelta = true
                self?.queue.sync {
                    guard let self = self, self.isRunning else { return }
                    if self.isLLMEnabled && !self.latestRefinedText.isEmpty && !self.lastWhisperBaseText.isEmpty {
                        if let delta = Self.extractDelta(newText: cleanTranscribed, baseText: self.lastWhisperBaseText) {
                            if delta.isEmpty {
                                // 🌟 差分が空（前回と同じ発話内容）の場合は、すでに推敲済みの latestRefinedText を絶対に生のWhisperで上書きしない！
                                textToRefine = self.latestRefinedText
                                hasNewUnrefinedDelta = !self.isLatestTextRefinedByLLM
                                NSLog("[VoiceIME] ⚡ Whisper差分なし (推敲済みテキストを保護維持): %d文字", self.latestRefinedText.count)
                            } else {
                                let combined = Self.combineRefinedWithDelta(refined: self.latestRefinedText, delta: delta)
                                textToRefine = combined
                                self.isLatestTextRefinedByLLM = false
                                hasNewUnrefinedDelta = true
                                NSLog("[VoiceIME] ⚡ Whisper差分連結表示 (ステップ3): 推敲済み%d文字 + 差分%d文字", self.latestRefinedText.count, delta.count)
                            }
                        } else if let rev = Self.extractDeltaWithTailRevision(newText: cleanTranscribed, baseText: self.lastWhisperBaseText) {
                            // 🌟 前回Whisper末尾の数文字が文脈修正された場合（例: 「動画が成長します」➔「動画が正常に再生できます」）：
                            // 前半の推敲済み箇所（「上記環境でも」等）を維持したまま末尾のみ差し替える
                            // LLMが付与した末尾の句読点を除去してから、Whisper側の差し替え文字数分だけ末尾を削る
                            var trimmedRefined = self.latestRefinedText.trimmingCharacters(in: .whitespacesAndNewlines)
                            while let last = trimmedRefined.last, "。、，．.,".contains(last) { trimmedRefined.removeLast() }
                            let baseRefined = trimmedRefined.count > rev.droppedBaseTailCount
                                ? String(trimmedRefined.dropLast(rev.droppedBaseTailCount))
                                : self.latestRefinedText
                            let combined = Self.combineRefinedWithDelta(refined: baseRefined, delta: rev.delta)
                            textToRefine = combined
                            self.isLatestTextRefinedByLLM = false
                            hasNewUnrefinedDelta = true
                            NSLog("[VoiceIME] ⚡ Whisper末尾修正付き差分連結 (前半推敲を維持、末尾%d文字差替): 計%d文字", rev.droppedBaseTailCount, combined.count)
                        } else if cleanTranscribed.count < self.lastWhisperBaseText.count {
                            // 🌟 Whisperが再認識時に末尾を欠落させた場合（前回より文字数が減った場合）は、既存の長いテキストを絶対に上書きしない！
                            textToRefine = self.latestRefinedText
                            hasNewUnrefinedDelta = !self.isLatestTextRefinedByLLM
                            NSLog("[VoiceIME] 🛡️ Whisper末尾欠落ガード発動 (前回%d文字 > 今回%d文字): 既存テキストを保護維持", self.lastWhisperBaseText.count, cleanTranscribed.count)
                        } else {
                            textToRefine = cleanTranscribed
                            self.isLatestTextRefinedByLLM = false
                            hasNewUnrefinedDelta = true
                            NSLog("[VoiceIME] ⚡ Whisper全文表示 (差分特定不可または大幅更新): %d文字", cleanTranscribed.count)
                        }
                    } else {
                        self.isLatestTextRefinedByLLM = !self.isLLMEnabled
                        hasNewUnrefinedDelta = self.isLLMEnabled
                        NSLog("[VoiceIME] ⚡ 初回Whisper速報表示 (ステップ1): %d文字", cleanTranscribed.count)
                    }

                    // ユーザー辞書・音声記号置換を適用して即座にプレビュー表示・最新状態に同期
                    let preprocessed = Self.applyDictionaryRules(to: textToRefine, isJapanese: self.isJapanese)
                    self.latestRefinedText = preprocessed
                    if cleanTranscribed.count >= self.lastWhisperBaseText.count {
                        self.lastWhisperBaseText = cleanTranscribed
                    }
                    previewToDisplay = preprocessed
                }

                if !previewToDisplay.isEmpty {
                    let textForUI = previewToDisplay
                    await MainActor.run {
                        FloatingPreviewController.shared.updatePipelineText(textForUI)
                    }
                }

                if Task.isCancelled { return }

                // 🌟 【ステップ2: ホールド中（Ctrl+Space押下中）のリアルタイムLLM推敲】
                // Whisperタスクとは独立した currentLLMTask で実行し、次の息継ぎWhisperトリガーによってキャンセルされないようにする。
                // また、小休止中（話し終えて画面を見ている時）は即座に推敲を走らせ、Ctrl+Spaceを離す前に最終文字列まで整える。
                if hasNewUnrefinedDelta {
                    let shouldForce = self?.isCapturePaused == true
                    self?.startHoldTimeLLMRefinementIfNeeded(
                        whisperSnapshot: cleanTranscribed,
                        textToRefine: textToRefine,
                        endSample: endSample,
                        forceImmediate: shouldForce
                    )
                }
            } catch {
                NSLog("[VoiceIME] ⚠️ 紙芝居Whisper送信失敗: %@", error.localizedDescription)
                PipelineLogger.shared.logDebug("⚠️ 紙芝居Whisper送信失敗 (自動リトライ予約): \(error.localizedDescription)")
                self?.queue.async {
                    guard let self = self, self.isRunning else { return }
                    if self.activeTaskID == taskID {
                        self.speechFramesSinceLastTrigger += consumedSpeechFrames
                        self.hasPendingRetry = true
                    }
                }
            }
        }
    }

    /// Ctrl+Space ホールド中に、Whisperタスクと干渉せず独立してLLM推敲を実行し、キーを離す前に最終文字列をウィンドウへ反映する
    private func startHoldTimeLLMRefinementIfNeeded(
        whisperSnapshot: String,
        textToRefine: String,
        endSample: Int,
        forceImmediate: Bool
    ) {
        queue.async { [weak self] in
            guard let self = self, self.isRunning, self.isLLMEnabled else { return }
            guard let llmCfg = self.currentLLMConfig, !llmCfg.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard !self.isRefiningLLM else { return }

            let isJapanese = self.isJapanese
            let language = self.language
            let llmInputBase = Self.applyDictionaryRulesForLLMInput(to: textToRefine, isJapanese: isJapanese)
            guard !llmInputBase.isEmpty else { return }
            // 同一テキストに対する重複リクエスト（特にHTTP 429発生時の100msループ）を完全防止
            guard llmInputBase != self.lastAttemptedLLMInput else { return }

            let now = CFAbsoluteTimeGetCurrent()
            let timeSinceLastLLM = now - self.lastLLMRefineTime
            let silentDuration = Double(self.silentFrameCount) / self.sampleRate
            // 🌟 5.0秒言い終わり待機判定: 通常会話の句読点や思考の間（数秒程度）で早漏推敲が走るのを防止し、じっくり5秒間空いた時点で1回だけ最終推敲
            let isUserPausedAtEnd = (silentDuration >= 5.0 && self.speechFramesSinceLastTrigger == 0 && !self.isTranscribing)

            // モデルに応じた最適インターバル判定:
            // 1) sarashina3-nano (60 RPM) や Groq 等: 最低1.2秒間隔で息継ぎ・Whisper受信ごとに即時nano推敲を実行
            // 2) sarashina3-mini (6 RPM): 10.5秒間隔を厳守
            let isNanoOrFast = llmCfg.model.lowercased().contains("nano") || llmCfg.model.lowercased().contains("gpt-4o-mini")

            let shouldRun: Bool
            if isNanoOrFast {
                shouldRun = !self.isLatestTextRefinedByLLM && (timeSinceLastLLM >= 1.2 || self.lastLLMRefineTime == 0.0)
            } else if forceImmediate || isUserPausedAtEnd {
                // sarashina3-mini 等の 6 RPM モデル:
                // 発話途中では貴重なクォータを温存し、話し終えて小休止に入った瞬間または一時停止時に1回だけ確実に最終推敲を実行！
                shouldRun = !self.isLatestTextRefinedByLLM && (forceImmediate || timeSinceLastLLM >= 3.5 || self.lastLLMRefineTime == 0.0)
            } else {
                // 15文字以上かつ10.5秒以上の間隔が空いている場合のみ、長文中間推敲を許可
                shouldRun = !self.isLatestTextRefinedByLLM && llmInputBase.count >= 20 && timeSinceLastLLM >= self.minLLMRefineIntervalSeconds && self.lastLLMRefineTime > 0.0
            }

            guard shouldRun else { return }

            self.isRefiningLLM = true
            self.lastLLMRefineTime = now
            self.lastAttemptedLLMInput = llmInputBase
            let whisperPrompt = self.whisperPrompt
            let style = self.refinementStyle

            NSLog("[VoiceIME] 🧠 ホールド中LLM推敲を開始 (経過: %.1fs, 言い終わり小休止: %d, 文字数: %d)", timeSinceLastLLM, isUserPausedAtEnd ? 1 : 0, llmInputBase.count)

            self.currentLLMTask = Task.detached { [weak self] in
                PipelineLogger.shared.logLLMInput(type: "途中息継ぎ推敲", text: llmInputBase)
                do {
                    let refined = try await LLMService.shared.refine(
                        text: llmInputBase,
                        baseURL: llmCfg.baseURL,
                        apiKey: llmCfg.apiKey,
                        model: llmCfg.model,
                        promptHint: whisperPrompt,
                        style: style,
                        isCustom: llmCfg.isCustom,
                        language: language
                    )
                    let cleanRefined = refined.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanRefined.isEmpty, !Task.isCancelled else {
                        self?.queue.async {
                            self?.isRefiningLLM = false
                        }
                        return
                    }

                    let finalText = Self.applyDictionaryRules(to: cleanRefined, isJapanese: isJapanese)
                    PipelineLogger.shared.logLLMOutput(type: "途中息継ぎ推敲", text: finalText)

                    self?.queue.async {
                        guard let self = self else { return }
                        self.isRefiningLLM = false
                        self.lastLLMRefineTime = CFAbsoluteTimeGetCurrent()

                        // 推敲中に新しいWhisper結果が到着していた場合は、推敲結果に新しい差分を繋げる
                        if self.lastWhisperBaseText == whisperSnapshot || self.lastWhisperBaseText.isEmpty {
                            self.latestRefinedText = finalText
                            self.isLatestTextRefinedByLLM = true
                            self.lastRefinedSampleCount = endSample
                            let textForUI = finalText
                            Task { @MainActor in
                                FloatingPreviewController.shared.updatePipelineText(textForUI)
                                NSLog("[VoiceIME] 🎭 ホールド中LLM推敲完了・最終文字列反映: %d文字", textForUI.count)
                            }
                        } else if let newerDelta = Self.extractDelta(newText: self.lastWhisperBaseText, baseText: whisperSnapshot) {
                            if newerDelta.isEmpty {
                                self.latestRefinedText = finalText
                                self.isLatestTextRefinedByLLM = true
                                self.lastRefinedSampleCount = endSample
                                let textForUI = finalText
                                Task { @MainActor in
                                    FloatingPreviewController.shared.updatePipelineText(textForUI)
                                    NSLog("[VoiceIME] 🎭 ホールド中LLM推敲完了・最終文字列反映(差分空): %d文字", textForUI.count)
                                }
                            } else {
                                let merged = Self.applyDictionaryRules(to: Self.combineRefinedWithDelta(refined: finalText, delta: newerDelta), isJapanese: isJapanese)
                                self.latestRefinedText = merged
                                self.isLatestTextRefinedByLLM = false
                                let textForUI = merged
                                let latestWhisper = self.lastWhisperBaseText
                                let latestSample = self.lastTriggerSampleCount
                                Task { @MainActor in
                                    FloatingPreviewController.shared.updatePipelineText(textForUI)
                                }
                                // 推敲中に追加された末尾差分についても、ホールド中に続けて推敲を完了させる
                                if self.isRunning {
                                    self.startHoldTimeLLMRefinementIfNeeded(
                                        whisperSnapshot: latestWhisper,
                                        textToRefine: merged,
                                        endSample: latestSample,
                                        forceImmediate: true
                                    )
                                }
                            }
                        }
                    }
                } catch {
                    NSLog("[VoiceIME] ⚠️ ホールド中LLM推敲スキップ: %@", error.localizedDescription)
                    PipelineLogger.shared.logLLMOutput(type: "途中息継ぎ推敲[失敗]", text: "[推敲エラー: \(error)]")
                    self?.queue.async {
                        self?.isRefiningLLM = false
                    }
                }
            }
        }
    }

    /// 録音停止時の完了処理（キー解放時: ホールド中に推敲完了済みなら0msで即時確定し、リリース後の文字変化を防止）
    public func finishAndFinalize(completion: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self = self else {
                completion("")
                return
            }
            self.isRunning = false
            self.isCapturePaused = false

            let totalSamples = self.pcmDataBuffer.count / 2
            guard totalSamples > 0, self.primaryWhisperConfig != nil else {
                completion(self.latestRefinedText)
                return
            }

            // 🌟 ケース1: Ctrl+Space ホールド中に最後の発話までWhisper認識が完了している場合（未送信の有声フレームが0かつ未送信の小声語尾が0.08秒未満）
            // 前回トリガー後に有声フレーム・小声語尾が残っている場合のみケース2へ進み、最終音声をWhisperへ送信する。
            // ※ 単なる経過サンプル数（無音の蓄積）は「未送信の発話」と見なさない（無音ホールド後のリリースで冗長な再送信を防ぐ）
            let hasUnsentAudioActivity = (self.speechFramesSinceLastTrigger > 0 || self.quietTailFramesSinceLastTrigger >= Int(self.sampleRate * 0.08))

            if self.isCapturePaused || (!hasUnsentAudioActivity && !self.hasPendingRetry) {
                if self.isTranscribing || self.isRefiningLLM {
                    // 1B: ホールド中または一時停止中に開始されたWhisper/LLM推敲が通信中の場合は、それをキャンセルせず完了を待ってそのまま確定する
                    NSLog("[VoiceIME] ⏳ 一時停止中/認識推敲中確定: 進行中のWhisper/LLMタスクの完了を待機して0msペーストへ移行します...")
                    let activeWhisper = self.currentProcessingTask
                    let activeLLM = self.currentLLMTask
                    Task.detached { [weak self] in
                        _ = await activeWhisper?.value
                        _ = await activeLLM?.value
                        guard let self = self else {
                            completion("")
                            return
                        }
                        var result = ""
                        self.queue.sync {
                            result = self.latestRefinedText
                            self.latestRefinedText = ""
                            self.lastWhisperBaseText = ""
                            self.preRollByteCount = 0
                            self.hasPreStartedCapture = false
                            self.isLatestTextRefinedByLLM = false
                            self.lastRefinedSampleCount = 0
                            self.lastAttemptedLLMInput = ""
                            self.pcmDataBuffer.removeAll(keepingCapacity: false)
                        }
                        NSLog("[VoiceIME] ✅ 一時停止中タスク待機完了 ➔ 確定出力: %d文字", result.count)
                        Task { @MainActor in
                            FloatingPreviewController.shared.updateConfirmedText(result)
                        }
                        PipelineLogger.shared.logSessionEnd(finalText: result)
                        completion(result)
                    }
                    return
                } else if !self.latestRefinedText.isEmpty {
                    if self.isLatestTextRefinedByLLM || !self.isLLMEnabled {
                        // 1A: ホールド中にLLM推敲まで完了済み ➔ 0msでそのまま確定！
                        let result = self.latestRefinedText
                        self.latestRefinedText = ""
                        self.lastWhisperBaseText = ""
                        self.preRollByteCount = 0
                        self.hasPreStartedCapture = false
                        self.isLatestTextRefinedByLLM = false
                        self.lastRefinedSampleCount = 0
                        self.lastAttemptedLLMInput = ""
                        self.pcmDataBuffer.removeAll(keepingCapacity: false)
                        NSLog("[VoiceIME] ⚡ ホールド中に最終推敲まで完了済み！リリース後の再通信なしでウィンドウ表示文字列をそのまま即時確定: %d文字", result.count)
                        PipelineLogger.shared.logDebug("⚡ ホールド中に最終推敲まで完了済みのため即時確定 (リリース後の文字変化なし)")
                        Task { @MainActor in
                            FloatingPreviewController.shared.updateConfirmedText(result)
                        }
                        PipelineLogger.shared.logSessionEnd(finalText: result)
                        completion(result)
                        return
                    } else {
                        // 1C: Whisper認識はホールド中に完了しているが、話し終えて0.6秒未満でキーを離したため最終LLM推敲のみ未実行の場合
                    // Whisper再送信はスキップし、ホールド中の認識テキストに対して最終LLM推敲のみを1回実行する（ただし直前に同一文で429等になっていればスキップ）
                    let isJapanese = self.isJapanese
                    let language = self.language
                    let capturedText = self.latestRefinedText
                    let llmInputForRefine = Self.applyDictionaryRulesForLLMInput(to: capturedText, isJapanese: isJapanese)
                    let alreadyAttempted = (llmInputForRefine == self.lastAttemptedLLMInput)
                    let llmConfig = self.currentLLMConfig
                    let whisperPrompt = self.whisperPrompt
                    let style = self.refinementStyle
                    self.latestRefinedText = ""
                    self.lastWhisperBaseText = ""
                    self.preRollByteCount = 0
                    self.hasPreStartedCapture = false
                    self.isLatestTextRefinedByLLM = false
                    self.lastRefinedSampleCount = 0
                    self.lastAttemptedLLMInput = ""
                    self.pcmDataBuffer.removeAll(keepingCapacity: false)

                    if !alreadyAttempted, let llmCfg = llmConfig, !llmInputForRefine.isEmpty, !llmCfg.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Task.detached {
                            await MainActor.run {
                                FloatingPreviewController.shared.setProcessing()
                            }
                            var finalText = capturedText
                            PipelineLogger.shared.logLLMInput(type: "最終確定推敲", text: llmInputForRefine)
                            do {
                                let refined = try await LLMService.shared.refine(
                                    text: llmInputForRefine,
                                    baseURL: llmCfg.baseURL,
                                    apiKey: llmCfg.apiKey,
                                    model: llmCfg.model,
                                    promptHint: whisperPrompt,
                                    style: style,
                                    isCustom: llmCfg.isCustom,
                                    language: language
                                )
                                let cleanRefined = refined.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !cleanRefined.isEmpty {
                                    finalText = Self.applyDictionaryRules(to: cleanRefined, isJapanese: isJapanese)
                                    PipelineLogger.shared.logLLMOutput(type: "最終確定推敲", text: finalText)
                                }
                            } catch {
                                PipelineLogger.shared.logLLMOutput(type: "最終確定推敲[失敗]", text: "[推敲エラー: \(error)]")
                            }
                            Task { @MainActor in
                                FloatingPreviewController.shared.updateConfirmedText(finalText)
                            }
                            PipelineLogger.shared.logSessionEnd(finalText: finalText)
                            completion(finalText)
                        }
                    } else {
                        Task { @MainActor in
                            FloatingPreviewController.shared.updateConfirmedText(capturedText)
                        }
                        PipelineLogger.shared.logSessionEnd(finalText: capturedText)
                        completion(capturedText)
                    }
                    return
                }
            }
        }

            // 🌟 ケース2: 発話の真っ最中に即座にキーを離した場合（未送信の発話フレームが残っている場合）
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
            let isJapanese = self.isJapanese
            let totalDuration = Double(totalSamples) / self.sampleRate

            NSLog("[VoiceIME] 🏁 録音終了: キーがリリースされました。最後の一つが戻ってくるまで待機中 (0〜%.2f秒の音声を無音カット後に最終送信)", totalDuration)

            self.currentProcessingTask?.cancel()
            self.currentProcessingTask = nil
            self.currentLLMTask?.cancel()
            self.currentLLMTask = nil
            self.isRefiningLLM = false

            Task.detached { [weak self] in
                guard let self = self else { return }
                defer { try? FileManager.default.removeItem(at: tempFile) }

                do {
                    // Whisper API に全音声を送信し、最後の一つの完了を確実に待つ（動的タイムアウト & ヘッジド・フォールバック付き）
                    guard let primary = self.primaryWhisperConfig else { return }
                    let (transcribed, effectiveProvider, fallbackRecord) = try await WhisperAPIService.shared.transcribeWithFallback(
                        audioFileURL: tempFile,
                        audioDuration: totalDuration,
                        primaryConfig: primary,
                        backupConfig: self.backupWhisperConfig,
                        mode: .transcriptions,
                        prompt: whisperPrompt,
                        language: language
                    )

                    if let fallback = fallbackRecord {
                        await MainActor.run {
                            AppState.shared.lastFallbackRecord = fallback
                            AppState.shared.lastUsedWhisperProvider = effectiveProvider
                        }
                        PipelineLogger.shared.logDebug("🔄 [最終バックアップSTT発動] \(fallback.displayNotice)")
                    } else {
                        await MainActor.run {
                            AppState.shared.lastUsedWhisperProvider = effectiveProvider
                        }
                    }
                    let clean = transcribed.trimmingCharacters(in: .whitespacesAndNewlines)

                    // 1. 最終 Whisper 完了時の速報表示（前回の推敲文字列があれば差分連結して表示）
                    let capturedFinalWhisper = clean
                    // 🌟 ログ: 1. Whisperから逐次送られてきた文字列
                    PipelineLogger.shared.logWhisperReceived(type: "最終確定速報", text: capturedFinalWhisper)

                    var textToRefine = clean
                    var previewToDisplay = ""
                    var alreadyRefinedWithZeroDelta = false
                    self.queue.sync {
                        if self.isLLMEnabled && !self.latestRefinedText.isEmpty && !self.lastWhisperBaseText.isEmpty {
                            if let delta = Self.extractDelta(newText: capturedFinalWhisper, baseText: self.lastWhisperBaseText) {
                                if delta.isEmpty {
                                    textToRefine = self.latestRefinedText
                                    alreadyRefinedWithZeroDelta = self.isLatestTextRefinedByLLM
                                    NSLog("[VoiceIME] ⚡ 最終Whisper差分なし (ホールド中の推敲済みテキストを維持): [%@]", self.latestRefinedText)
                                } else {
                                    let combined = Self.combineRefinedWithDelta(refined: self.latestRefinedText, delta: delta)
                                    textToRefine = combined
                                    NSLog("[VoiceIME] ⚡ 最終Whisper差分連結表示 (ステップ3): 推敲済み%d文字 + 差分%d文字", self.latestRefinedText.count, delta.count)
                                }
                            } else if capturedFinalWhisper.count < self.lastWhisperBaseText.count {
                                textToRefine = self.latestRefinedText
                                alreadyRefinedWithZeroDelta = self.isLatestTextRefinedByLLM
                                NSLog("[VoiceIME] 🛡️ 最終Whisper末尾欠落ガード発動 (前回%d文字 > 今回%d文字): ホールド中のテキストを保護維持", self.lastWhisperBaseText.count, capturedFinalWhisper.count)
                            } else {
                                textToRefine = capturedFinalWhisper
                                NSLog("[VoiceIME] ⚡ 最終Whisper全文表示 (差分特定不可または大幅更新): %d文字", capturedFinalWhisper.count)
                            }
                        } else {
                            NSLog("[VoiceIME] ⚡ 最終Whisper速報表示 (ステップ1): %d文字", capturedFinalWhisper.count)
                        }
                        // ユーザー辞書・音声記号置換を適用して即座にプレビュー表示・最新状態に同期
                        let preprocessedPreview = Self.applyDictionaryRules(to: textToRefine, isJapanese: isJapanese)
                        self.latestRefinedText = preprocessedPreview
                        self.lastWhisperBaseText = capturedFinalWhisper
                        previewToDisplay = preprocessedPreview
                    }

                    // 語尾まで含めた最終Whisperテキストを、LLM推敲の完了を待つ前に即座に画面へ反映
                    if !previewToDisplay.isEmpty {
                        let textForUI = previewToDisplay
                        await MainActor.run {
                            FloatingPreviewController.shared.updatePipelineText(textForUI)
                        }
                    }

                    // ホールド中にすでに推敲済みテキストがあり差分を追加した textToRefine をベースにすることで、前半の推敲結果を維持しつつ末尾まで整える
                    let rawBaseForLLM = !textToRefine.isEmpty ? textToRefine : capturedFinalWhisper
                    let fallbackFormatted = Self.applyDictionaryRules(to: rawBaseForLLM, isJapanese: isJapanese)
                    let llmInputForRefine = Self.applyDictionaryRulesForLLMInput(to: rawBaseForLLM, isJapanese: isJapanese)
                    var finalText = fallbackFormatted

                    // 2. 推敲が有効かつ未推敲差分がある場合は LLM の推敲完了も確実に待つ（ステップ4）
                    if isLLMEnabled, !alreadyRefinedWithZeroDelta, let llmCfg = llmConfig, !llmInputForRefine.isEmpty, !llmCfg.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await MainActor.run {
                            FloatingPreviewController.shared.setProcessing()
                        }
                        // 🌟 ログ: 2. Whisperから推敲LLMへ送られる文字列（辞書・音声コマンド置換済み、機械的句点未挿入）
                        PipelineLogger.shared.logLLMInput(type: "最終確定推敲", text: llmInputForRefine)
                        do {
                            let refined = try await LLMService.shared.refine(
                                text: llmInputForRefine,
                                baseURL: llmCfg.baseURL,
                                apiKey: llmCfg.apiKey,
                                model: llmCfg.model,
                                promptHint: whisperPrompt,
                                style: style,
                                isCustom: llmCfg.isCustom,
                                language: language
                            )
                            let cleanRefined = refined.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !cleanRefined.isEmpty {
                                // LLM推敲後にもセーフティとして辞書置換を適用
                                finalText = Self.applyDictionaryRules(to: cleanRefined, isJapanese: isJapanese)
                                NSLog("[VoiceIME] ✨ 最終推敲成功 (ステップ4): %d文字", finalText.count)
                                // 🌟 ログ: 3. 推敲LLMから修正され戻される文字列
                                PipelineLogger.shared.logLLMOutput(type: "最終確定推敲", text: finalText)
                            }
                        } catch {
                            NSLog("[VoiceIME] ⚠️ 最終LLM推敲失敗 (%@): %@。辞書置換済みWhisperテキストを使用します", llmCfg.model, error.localizedDescription)
                            PipelineLogger.shared.logLLMOutput(type: "最終確定推敲[失敗]", text: "[推敲エラー: \(error)]")
                        }
                    }

                    let result = !finalText.isEmpty ? finalText : fallbackFormatted
                    self.queue.async {
                        // 次回録音セッションへの残留を防ぐため、バッファと前回の推敲状態を完全リセット
                        self.latestRefinedText = ""
                        self.lastWhisperBaseText = ""
                        self.preRollByteCount = 0
                        self.hasPreStartedCapture = false
                        self.isLatestTextRefinedByLLM = false
                        self.lastRefinedSampleCount = 0
                        self.lastAttemptedLLMInput = ""
                        self.pcmDataBuffer.removeAll(keepingCapacity: false)
                    }
                    NSLog("[VoiceIME] ✅ 最後の一つが到着しました: %d文字", result.count)

                    Task { @MainActor in
                        FloatingPreviewController.shared.updateConfirmedText(result)
                    }

                    // 🌟 ログ: セッション完了（確定出力テキスト）
                    PipelineLogger.shared.logSessionEnd(finalText: result)

                    completion(result)
                } catch {
                    let fallbackResult = Self.applyDictionaryRules(to: self.latestRefinedText, isJapanese: isJapanese)
                    NSLog("[VoiceIME] ⚠️ 最終送信失敗、手持ちの最新テキストで完了: %d文字", fallbackResult.count)
                    PipelineLogger.shared.logSessionEnd(finalText: fallbackResult)
                    completion(fallbackResult)
                }
            }
        }
    }

    /// 一時停止（思考中・マイク休止時）:
    /// 未送信の音声（直前トリガー以降の発話）があれば即座に Whisper API へ累積送信し、
    /// プレビュー画面に現在までのすべての言葉を完全に表示させた上でキャプチャを一時休止する
    public func pauseCapture() {
        queue.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.isCapturePaused = true
            self.silentFrameCount = 0

            let totalSamples = self.pcmDataBuffer.count / 2
            let unsentSpeech = (self.speechFramesSinceLastTrigger > 0 || self.quietTailFramesSinceLastTrigger >= Int(self.sampleRate * 0.08))
            let hasNewSamples = totalSamples > self.lastTriggerSampleCount && (totalSamples - self.lastTriggerSampleCount) >= Int(self.sampleRate * 0.15)

            if (unsentSpeech || hasNewSamples) && self.currentWhisperConfig != nil {
                let consumedSpeechFrames = self.speechFramesSinceLastTrigger
                self.lastTriggerTime = CFAbsoluteTimeGetCurrent()
                self.lastTriggerSampleCount = totalSamples
                self.speechFramesSinceLastTrigger = 0
                self.quietTailFramesSinceLastTrigger = 0
                self.hasPendingRetry = false
                NSLog("[VoiceIME] ⏸️ 一時停止突入: 未送信音声を即時Whisper送信してプレビューに全文字表示 (サンプル数: %d)", totalSamples)
                self.processCumulativePaperTheater(to: totalSamples, consumedSpeechFrames: consumedSpeechFrames)
            } else {
                NSLog("[VoiceIME] ⏸️ StreamingChunkPipelineService: 一時停止 (データ・最新テキストを保持)")
                if !self.isLatestTextRefinedByLLM && !self.latestRefinedText.isEmpty {
                    self.startHoldTimeLLMRefinementIfNeeded(
                        whisperSnapshot: self.lastWhisperBaseText,
                        textToRefine: self.latestRefinedText,
                        endSample: totalSamples,
                        forceImmediate: true
                    )
                }
            }
        }
    }

    /// 一時停止からの再開（メインキー再押下時）: 既存の音声バッファに続きを追記し、録音を再開
    /// ※ 推敲中または認識中の場合は完了を待機し、整ったテキストを安全に確定させてから再開する（競合・巻き戻り防止）
    public func resumeCapture(completion: @escaping () -> Void = {}) {
        queue.async { [weak self] in
            guard let self = self, self.isRunning else {
                DispatchQueue.main.async { completion() }
                return
            }
            self.isCapturePaused = false
            self.silentFrameCount = 0
            self.lastTriggerTime = CFAbsoluteTimeGetCurrent()

            let activeWhisperTask = self.currentProcessingTask
            let activeLLMTask = self.currentLLMTask
            let isBusy = self.isRefiningLLM || self.isTranscribing

            if isBusy {
                NSLog("[VoiceIME] ⏳ resumeCapture: 推敲・認識処理中のため完了を待機...")
                Task.detached { [weak self] in
                    _ = await activeWhisperTask?.value
                    _ = await activeLLMTask?.value

                    self?.queue.async {
                        guard let self = self, self.isRunning else {
                            DispatchQueue.main.async { completion() }
                            return
                        }
                        NSLog("[VoiceIME] ▶️ resumeCapture: 推敲完了後に録音再開 (最新テキスト保持・続き追記)")
                        DispatchQueue.main.async { completion() }
                    }
                }
            } else {
                NSLog("[VoiceIME] ▶️ StreamingChunkPipelineService: 録音再開 (既存バッファ・最新テキストを保持して続きを追記)")
                DispatchQueue.main.async { completion() }
            }
        }
    }

    /// 蓄積された完全なPCM音声（プリロール＋0秒からの録音波形）を一時WAVファイルとして書き出して返す
    /// （一括送信モードやフォールバック時、および無音解析時にAVAudioRecorderの起動遅延による語頭欠落をゼロにする）
    public func exportFullAudioWAV() -> URL? {
        return queue.sync {
            let totalBytes = self.pcmDataBuffer.count
            guard totalBytes > 0, self.sampleRate > 0 else { return nil }

            let liveBytes = max(0, totalBytes - self.preRollByteCount)
            let liveDuration = Double(liveBytes / 2) / self.sampleRate

            let targetPCM: Data
            if liveDuration < 0.25 && self.preRollByteCount > 0 && self.preRollByteCount <= totalBytes {
                // キー押下時間が0.25秒未満の極短タップ時はプリロール分を含めず、実押下時間のみで無音判定させる
                targetPCM = self.pcmDataBuffer.subdata(in: self.preRollByteCount..<totalBytes)
            } else {
                targetPCM = self.pcmDataBuffer
            }

            guard targetPCM.count >= 2 else { return nil }
            let wavData = self.createWAV(from: targetPCM, sampleRate: Int(self.sampleRate))
            let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("voiceime_full_\(UUID().uuidString).wav")
            do {
                try wavData.write(to: tempFile)
                return tempFile
            } catch {
                return nil
            }
        }
    }

    /// パイプラインの中断・破棄
    public func cancel() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.currentProcessingTask?.cancel()
            self.currentProcessingTask = nil
            self.currentLLMTask?.cancel()
            self.currentLLMTask = nil
            self.isRunning = false
            self.isCapturePaused = false
            self.hasPreStartedCapture = false
            self.preRollByteCount = 0
            self.pcmDataBuffer.removeAll(keepingCapacity: false)
            self.latestRefinedText = ""
            self.lastWhisperBaseText = ""
            self.isTranscribing = false
            self.isRefiningLLM = false
            self.isLatestTextRefinedByLLM = false
            self.lastRefinedSampleCount = 0
            self.lastAttemptedLLMInput = ""
            self.hasPendingRetry = false
            self.lastTriggerHadPause = true
            self.primaryWhisperConfig = nil
            self.backupWhisperConfig = nil
        }
    }

    /// 紙芝居トリガー成立条件の純粋判定（テストおよび堅牢性担保用）
    public static func evaluateTrigger(
        isFirstTrigger: Bool,
        totalSpeechDuration: Double,
        newSpeechDuration: Double,
        silentDuration: Double,
        timeSinceLastTrigger: Double,
        minIntervalSeconds: Double,
        minSilenceDuration: Double,
        isTranscribing: Bool,
        hasPendingRetry: Bool = false,
        needsTailCatchUp: Bool = false
    ) -> Bool {
        if isTranscribing { return false }

        if isFirstTrigger {
            // A. 初回トリガー:
            // 1) 通常発話: 0.30秒以上の有声発話があり、息継ぎ(0.10秒以上)または0.8秒以上の連続発話
            // 2) 短い発話（「はい」「うん」等の極短発話）: 0.10秒以上の有声発話があり、言い終わり小休止(0.20秒以上)
            let isNormalSpeechReady = (totalSpeechDuration >= 0.30 && (silentDuration >= 0.10 || totalSpeechDuration >= 0.8))
            let isShortSpeechEnding = (totalSpeechDuration >= 0.10 && silentDuration >= 0.20)
            return (isNormalSpeechReady || isShortSpeechEnding || hasPendingRetry)
        } else {
            // B. 2回目以降のトリガー:
            // 1) 通常の連続発話進行中: 前回送信から新たな有声発話が0.20秒以上あり、1.5秒以上のインターバル経過（息継ぎ0.10秒以上または1.5秒以上の連続発話）
            // 2) 語尾・言い終わり（「〜します」「〜です」「〜ました」「〜だよね」等）: 前回送信から新たな有声発話が0.06秒以上あり、言い終わりの小休止(0.15秒以上)
            // 3) 語中トリガー後の語尾キャッチアップ (needsTailCatchUp) または前回通信失敗時の自動リトライ (hasPendingRetry)
            // 🚨 重要ガード: newSpeechDuration == 0（音が出ていない沈黙中）の時は絶対に投げない（無音放置時の投げ続け・連続ループ完全防止）
            let isRateLimitSatisfied = (timeSinceLastTrigger >= minIntervalSeconds)
            let isNormalAdditionReady = (newSpeechDuration >= 0.20 && (silentDuration >= minSilenceDuration || timeSinceLastTrigger >= 1.5))
            let isTailEndingDetected = (newSpeechDuration >= 0.06 && silentDuration >= 0.15)
            let hasValidSpeechActivity = (isNormalAdditionReady || isTailEndingDetected || hasPendingRetry || needsTailCatchUp)
            let hasActualSoundSinceLast = (newSpeechDuration > 0 || hasPendingRetry || needsTailCatchUp)
            return isRateLimitSatisfied && hasValidSpeechActivity && hasActualSoundSinceLast
        }
    }

    /// Int16 PCMデータの前後の無音・微小ノイズ区間を高速にトリミング（VAD）
    /// - 開始前の静寂（0.5〜1.5秒）をカットして Whisperの冒頭英語ハルシネーション（Thank you等）を防止
    /// - 終了後の静寂（0.4〜0.8秒）をカットして Whisperの「ご視聴ありがとうございました」ハルシネーションを防止
    /// - 語頭の子音・主語・出だしの第一声（先頭650msマージン）および語尾の自然なフェードアウト（300ms）を確実に保護
    public static func trimSilence(pcmData: Data, sampleRate: Double, speechThresholdDB: Float) -> Data {
        let totalSamples = pcmData.count / 2
        guard totalSamples > 0 else { return pcmData }

        let windowSize = Int(sampleRate * 0.05) // 50ms ウィンドウ
        let stepSize = Int(sampleRate * 0.025)  // 25ms ステップ
        guard windowSize > 0, totalSamples >= windowSize else { return pcmData }

        // 発話開始判定しきい値（語頭の微弱な子音 k/s/t/h や小声の第一声も絶対に漏らさず拾えるよう、しきい値より8dB低くかつ最低-45dB以下に設定）
        let speechStartFloorDB = min(speechThresholdDB - 8.0, -45.0)
        let startThresholdLinear = pow(10.0, speechStartFloorDB / 20.0) * 32767.0
        // 語尾終了判定しきい値（「ございます」などの微小な語尾減衰音も確実に保護するため、開始しきい値と同じ-8.0dBフロアまで拾う）
        let trailingFloorDB = min(speechThresholdDB - 8.0, -45.0)
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

        // 先頭マージン 650ms、末尾マージン 450ms を確保（出だしの声や語尾「ございます」の微弱音フェードアウトを完全保護）
        let leadingMargin = Int(sampleRate * 0.65)
        let trailingMargin = Int(sampleRate * 0.45)

        // 発話開始位置が先頭650ms以内の場合は、先頭を一切カットせずそのまま0サンプル目から保持
        let startSample = first <= leadingMargin ? 0 : max(0, first - leadingMargin)
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

        func normalizeCharForMatch(_ c: Character) -> Character {
            switch c {
            case "一", "１": return "1"
            case "二", "２": return "2"
            case "三", "３": return "3"
            case "四", "４": return "4"
            case "五", "５": return "5"
            case "六", "６": return "6"
            case "七", "７": return "7"
            case "八", "８": return "8"
            case "九", "９": return "9"
            case "零", "〇", "０": return "0"
            default: return c
            }
        }

        // 2. 句読点・空白・漢数字/算用数字の表記ゆれを無視した前方一致（Whisperが「一頭↔1頭」や読点・空白を変えたケース）
        let baseChars = Array(cleanBase.filter { !$0.isWhitespace && !$0.isPunctuation }.map(normalizeCharForMatch))
        if !baseChars.isEmpty {
            var newCharIndices: [String.Index] = []
            var filteredNewChars: [Character] = []
            for idx in cleanNew.indices {
                let c = cleanNew[idx]
                if !c.isWhitespace && !c.isPunctuation {
                    filteredNewChars.append(normalizeCharForMatch(c))
                    newCharIndices.append(idx)
                }
            }

            if filteredNewChars.count >= baseChars.count {
                var matches = true
                for i in 0..<baseChars.count {
                    if filteredNewChars[i] != baseChars[i] {
                        matches = false
                        break
                    }
                }
                if matches {
                    if filteredNewChars.count == baseChars.count {
                        return ""
                    }
                    let lastMatchedIdx = newCharIndices[baseChars.count - 1]
                    let nextIdx = cleanNew.index(after: lastMatchedIdx)
                    let delta = String(cleanNew[nextIdx...])
                    return cleanLeadingPunctuation(delta)
                }
            }
        }

        // 3. あいまいアンカー検索（Whisperが文頭の漢字認識を変えた場合の耐性）
        // cleanBase が短すぎる場合（6文字未満）は誤マッチしやすいためスキップ
        if cleanBase.count >= 6 {
            let anchorLengths = [12, 10, 8, 6, 4]
            for len in anchorLengths {
                if cleanBase.count >= len {
                    let anchor = String(cleanBase.suffix(len))
                    if let range = cleanNew.range(of: anchor, options: .backwards) {
                        let delta = String(cleanNew[range.upperBound...])
                        let cleanedDelta = cleanLeadingPunctuation(delta)
                        let matchOffset = cleanNew.distance(from: cleanNew.startIndex, to: range.lowerBound)
                        // アンカー出現位置が cleanNew の先頭から cleanBase の半分以上進んだ位置にあること
                        if matchOffset >= (cleanBase.count / 2) {
                            return cleanedDelta
                        }
                    }
                }
            }
        }

        // 4. 一致が確認できない場合は安全のため nil（全体を差分として連結しない！）
        return nil
    }

    /// 直前のWhisper認識の末尾数文字が文脈で微修正された場合（例: 「動画が成長します」➔「動画が正常に再生できます」）、
    /// さかのぼって一致するアンカー位置を見つけ、差し替えるべき末尾文字数と新規差分を返す
    public static func extractDeltaWithTailRevision(newText: String, baseText: String) -> (delta: String, droppedBaseTailCount: Int)? {
        let cleanNew = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBase = baseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanBase.count >= 8, cleanNew.count >= 8 else { return nil }

        // baseText の末尾から最大 12文字さかのぼりながらアンカーを探索
        for offset in 2...min(12, cleanBase.count - 4) {
            let subBase = String(cleanBase.dropLast(offset))
            let anchorLengths = [10, 8, 6, 4]
            for len in anchorLengths {
                if subBase.count >= len {
                    let anchor = String(subBase.suffix(len))
                    if let range = cleanNew.range(of: anchor, options: .backwards) {
                        let matchOffset = cleanNew.distance(from: cleanNew.startIndex, to: range.lowerBound)
                        if matchOffset >= (cleanBase.count / 3) {
                            var delta = String(cleanNew[range.upperBound...])
                            while let first = delta.first, "、，,。.\t 　".contains(first) {
                                delta.removeFirst()
                            }
                            return (delta: delta, droppedBaseTailCount: offset)
                        }
                    }
                }
            }
        }
        return nil
    }

    /// 推敲済みテキストと、新しく喋ったWhisper差分テキストをスマートに連結
    public static func combineRefinedWithDelta(refined: String, delta: String) -> String {
        let cleanRefined = refined.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanDelta.isEmpty else { return cleanRefined }
        guard !cleanRefined.isEmpty else { return cleanDelta }

        // 🌟 中間推敲LLMが文末と勘違いして句点（。や.）を付与した後に発話が継続した場合、
        // 文の途中に勝手な句点が混入して「〜十分な。エラーがありません」のような画面とペーストの乖離を防ぐため、
        // 後続フレーズ（delta）が存在する場合は refined 末尾の不要な句点（。や.）を確実にトリミング
        var baseRefined = cleanRefined
        while let last = baseRefined.last, "。.".contains(last) {
            baseRefined.removeLast()
            baseRefined = baseRefined.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 日本語・英語の区切り調整（末尾・先頭がASCII文字/記号の場合はスペースを挟む）
        if let lastChar = baseRefined.last, let firstChar = cleanDelta.first,
           lastChar.isASCII && firstChar.isASCII {
            return "\(baseRefined) \(cleanDelta)"
        }
        return "\(baseRefined)\(cleanDelta)"
    }

    // MARK: - ユーザー辞書・記号置換ヘルパー

    /// Whisper認識テキストまたは推敲テキストに対し、音声コマンド正規化（「開業」「かいぎょう」「改行」➔ \n、ピリオド、括弧等）およびユーザー辞書ルールを完全適用
    public static func applyDictionaryRules(to text: String, isJapanese: Bool = true) -> String {
        guard !text.isEmpty else { return "" }
        // 1. PunctuationService による音声コマンド正規化（「開業」「かいぎょう」「改行」の改行変換、ピリオド、括弧、びっくりマークなど）および辞書置換
        let formatted = PunctuationService.shared.format(text: text, isJapanese: isJapanese)
        // 2. 句読点の正規化
        return LLMService.normalizePunctuation(for: formatted, isJapanese: isJapanese)
    }

    /// LLM推敲へ入力するテキストの前処理（機械的な正規表現による句点・読点の推測挿入を行わず、ユーザー辞書と音声コマンドのみ適用）
    public static func applyDictionaryRulesForLLMInput(to text: String, isJapanese: Bool = true) -> String {
        guard !text.isEmpty else { return "" }
        let formatted = PunctuationService.shared.formatVoiceCommandsAndDictionaryOnly(text: text, isJapanese: isJapanese)
        return LLMService.normalizePunctuation(for: formatted, isJapanese: isJapanese)
    }
}

