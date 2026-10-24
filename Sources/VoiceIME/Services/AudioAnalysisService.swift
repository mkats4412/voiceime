import Foundation
import AVFoundation

public struct AudioAnalysisMetrics {
    /// しきい値以上の声（発話区間）が含まれていたかどうか
    public let hasSpeech: Bool
    /// 100ms スライディングウィンドウにおける最大 RMS 音量 (dBFS)
    public let maxWindowRMS_DB: Float
    /// 音声全体の最大ピーク音量 (dBFS)
    public let peakPowerDB: Float
    /// 音声全体の平均 RMS 音量 (dBFS)
    public let averageRMS_DB: Float
    /// 発話開始位置（秒、thresholdDB 基準）
    public let speechStartSeconds: Double?
    /// 発話終了位置（秒、thresholdDB 基準）
    public let speechEndSeconds: Double?
    /// 発話持続時間（秒、thresholdDB 基準）
    public let speechDurationSeconds: Double
    /// 可聴音声持続時間（秒、絶対フロア -48.0 dBFS 基準）
    public let audibleDurationSeconds: Double
    /// 音声全体の長さ（秒）
    public let totalDurationSeconds: Double

    /// 無音・極小環境音・打鍵ノイズパルス・極短時間録音など、発話が存在しない状態かどうか
    /// （ユーザーのしきい値設定に関わらず、Whisper API への送信を防止する絶対ガード判定）
    public var isSilence: Bool {
        // 1. 録音時間が極端に短い（0.25秒未満 = キーの誤押し・チョン押し）
        if totalDurationSeconds < 0.25 {
            return true
        }
        // 2. 音声全体のピーク音量が極小（-48.0 dBFS 未満 = 静寂・環境ノイズフロア）
        if peakPowerDB < -48.0 {
            return true
        }
        // 3. 最大RMS音量が極小（-50.0 dBFS 未満）
        if maxWindowRMS_DB < -50.0 {
            return true
        }
        // 4. -48dBFS を超える持続的な音が 0.12秒未満（単発クリック・打鍵音のみ）
        if audibleDurationSeconds < 0.12 {
            return true
        }
        return false
    }
}

public final class AudioAnalysisService {
    public static let shared = AudioAnalysisService()

    private init() {}

    /// 録音ファイルの音量を解析し、声としての音量（しきい値）に達しているかを判定する
    public func analyze(audioFileURL: URL, thresholdDB: Float) -> AudioAnalysisMetrics {
        guard let file = try? AVAudioFile(forReading: audioFileURL) else {
            // ファイル読み込みに失敗した場合は、無駄な API 送信を行わないよう安全に無音として扱う
            return AudioAnalysisMetrics(
                hasSpeech: false,
                maxWindowRMS_DB: -100,
                peakPowerDB: -100,
                averageRMS_DB: -100,
                speechStartSeconds: nil,
                speechEndSeconds: nil,
                speechDurationSeconds: 0,
                audibleDurationSeconds: 0,
                totalDurationSeconds: 0
            )
        }

        let format = file.processingFormat
        // Int64 → UInt32 の変換は範囲外だとトラップ（クラッシュ）するため exactly で安全に変換
        let frameCount = AVAudioFrameCount(exactly: max(0, file.length)) ?? 0
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return AudioAnalysisMetrics(
                hasSpeech: false,
                maxWindowRMS_DB: -100,
                peakPowerDB: -100,
                averageRMS_DB: -100,
                speechStartSeconds: nil,
                speechEndSeconds: nil,
                speechDurationSeconds: 0,
                audibleDurationSeconds: 0,
                totalDurationSeconds: 0
            )
        }

        guard format.channelCount > 0,
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData else {
            return AudioAnalysisMetrics(
                hasSpeech: false,
                maxWindowRMS_DB: -100,
                peakPowerDB: -100,
                averageRMS_DB: -100,
                speechStartSeconds: nil,
                speechEndSeconds: nil,
                speechDurationSeconds: 0,
                audibleDurationSeconds: 0,
                totalDurationSeconds: 0
            )
        }

        let sampleRate = Float(format.sampleRate)
        let channel0 = channels[0]
        let totalFrames = Int(buffer.frameLength)
        let totalDuration = Double(totalFrames) / Double(sampleRate)

        // 1. 全体ピークと全体エネルギーの算出
        var maxPeak: Float = 0.0
        var totalSumSq: Float = 0.0
        for i in 0..<totalFrames {
            let s = channel0[i]
            let absVal = abs(s)
            if absVal > maxPeak { maxPeak = absVal }
            totalSumSq += s * s
        }
        let peakDB = maxPeak > 1e-5 ? 20.0 * log10(maxPeak) : -100.0
        let avgRMS = totalFrames > 0 ? sqrt(totalSumSq / Float(totalFrames)) : 0.0
        let avgRMS_DB = avgRMS > 1e-5 ? 20.0 * log10(avgRMS) : -100.0

        // 2. 100ms ウィンドウによる局所 RMS の算出（打鍵音や短パルスノイズと人間の持続音声を分離）
        let windowSize = max(1, Int(sampleRate * 0.10)) // 100ms
        let stepSize = max(1, windowSize / 2)           // 50ms overlap

        var maxRMS: Float = -100.0
        var firstSpeechFrame: Int?
        var lastSpeechFrame: Int?
        var firstAudibleFrame: Int?
        var lastAudibleFrame: Int?

        let absoluteAudibleFloorDB: Float = -48.0

        if totalFrames <= windowSize {
            maxRMS = avgRMS_DB
            if maxRMS >= thresholdDB {
                firstSpeechFrame = 0
                lastSpeechFrame = totalFrames
            }
            if maxRMS >= absoluteAudibleFloorDB {
                firstAudibleFrame = 0
                lastAudibleFrame = totalFrames
            }
        } else {
            var pos = 0
            while pos + windowSize <= totalFrames {
                var sumSq: Float = 0.0
                for i in pos..<(pos + windowSize) {
                    let s = channel0[i]
                    sumSq += s * s
                }
                let rms = sqrt(sumSq / Float(windowSize))
                let rmsDB = rms > 1e-5 ? 20.0 * log10(rms) : -100.0
                if rmsDB > maxRMS {
                    maxRMS = rmsDB
                }
                if rmsDB >= thresholdDB {
                    if firstSpeechFrame == nil { firstSpeechFrame = pos }
                    lastSpeechFrame = pos + windowSize
                }
                if rmsDB >= absoluteAudibleFloorDB {
                    if firstAudibleFrame == nil { firstAudibleFrame = pos }
                    lastAudibleFrame = pos + windowSize
                }
                pos += stepSize
            }
        }

        let speechDuration: Double
        if let first = firstSpeechFrame, let last = lastSpeechFrame, last > first {
            speechDuration = Double(last - first) / Double(sampleRate)
        } else {
            speechDuration = 0.0
        }

        let audibleDuration: Double
        if let first = firstAudibleFrame, let last = lastAudibleFrame, last > first {
            audibleDuration = Double(last - first) / Double(sampleRate)
        } else {
            audibleDuration = 0.0
        }

        // hasSpeech は指定された thresholdDB を超え、かつ単発打鍵パルス（0.10s未満）ではないこと
        let hasSpeech = (firstSpeechFrame != nil) && (speechDuration >= 0.10)
        let startSec = firstSpeechFrame.map { Double($0) / Double(sampleRate) }
        let endSec = lastSpeechFrame.map { Double($0) / Double(sampleRate) }

        return AudioAnalysisMetrics(
            hasSpeech: hasSpeech,
            maxWindowRMS_DB: maxRMS,
            peakPowerDB: peakDB,
            averageRMS_DB: avgRMS_DB,
            speechStartSeconds: startSec,
            speechEndSeconds: endSec,
            speechDurationSeconds: speechDuration,
            audibleDurationSeconds: audibleDuration,
            totalDurationSeconds: totalDuration
        )
    }

    /// 発話前後の無音・微小環境音を自然にトリミングした新ファイルを生成する（不要な場合は nil）
    public func trimLeadingTrailingNoise(
        audioFileURL: URL,
        thresholdDB: Float,
        leadingMarginSeconds: Double = 0.25,
        trailingMarginSeconds: Double = 0.70
    ) -> URL? {
        guard let file = try? AVAudioFile(forReading: audioFileURL) else { return nil }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(exactly: max(0, file.length)) ?? 0
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        guard format.channelCount > 0,
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData else { return nil }

        let sampleRate = Float(format.sampleRate)
        let channel0 = channels[0]
        let totalFrames = Int(buffer.frameLength)
        let windowSize = max(1, Int(sampleRate * 0.10))
        let stepSize = max(1, windowSize / 2)

        var firstSpeechFrame: Int?
        var lastSpeechFrame: Int?

        // 語頭の微弱な子音（主語・第一声）を逃さないよう、開始判定はしきい値より8dB低くかつ最低-45dB以下に設定
        let leadingThresholdDB = min(thresholdDB - 8.0, -45.0)
        // 語尾（「〜でしょう」「〜出ている」「〜ですよね」等）の減衰・息づかいを確実に拾うため、
        // 終了判定の感度は -48.0 dBFS まで高感度に設定
        let trailingThresholdDB = min(thresholdDB, -48.0)

        var pos = 0
        while pos + windowSize <= totalFrames {
            var sumSq: Float = 0.0
            for i in pos..<(pos + windowSize) {
                let s = channel0[i]
                sumSq += s * s
            }
            let rms = sqrt(sumSq / Float(windowSize))
            let rmsDB = rms > 1e-5 ? 20.0 * log10(rms) : -100.0
            if rmsDB >= leadingThresholdDB {
                if firstSpeechFrame == nil { firstSpeechFrame = pos }
            }
            if rmsDB >= trailingThresholdDB && firstSpeechFrame != nil {
                lastSpeechFrame = pos + windowSize
            }
            pos += stepSize
        }

        guard let first = firstSpeechFrame, let last = lastSpeechFrame else {
            return nil
        }

        // 先頭（400ms）と末尾（700ms）のマージンを確保。
        // 主語や語頭子音、語尾の終助詞（〜でしょう、〜ね等）の息づかいが脱落しないよう十分に確保する。
        let leadingMarginFrames = Int(sampleRate * Float(leadingMarginSeconds))
        let trailingMarginFrames = Int(sampleRate * Float(trailingMarginSeconds))
        let startFrame = first <= leadingMarginFrames ? 0 : max(0, first - leadingMarginFrames)
        let endFrame = min(totalFrames, last + trailingMarginFrames)
        let trimmedLength = endFrame - startFrame

        // 削る部分が前後合計で 100ms 未満なら、再エンコードのコストを避けて元のファイルをそのまま使用
        let totalTrimmedFrames = startFrame + (totalFrames - endFrame)
        let minTrimFramesToJustify = Int(sampleRate * 0.10)
        if totalTrimmedFrames < minTrimFramesToJustify {
            return nil
        }

        // トリミング後の長さが極端に短い（0.2秒未満）場合はトリミングしない
        if trimmedLength < Int(sampleRate * 0.20) {
            return nil
        }

        // 生ポインタアクセスの前提条件（非インターリーブ・範囲内）を明示的に検証
        guard !format.isInterleaved,
              startFrame >= 0, endFrame <= totalFrames, trimmedLength > 0 else {
            return nil
        }

        let trimmedURL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceime_trimmed_\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        // AVAudioFile(forWriting:) の時点でファイルが作成されるため、
        // 以降のどの失敗経路でも一時ファイルを確実に削除する（一時ファイルリーク防止）
        var succeeded = false
        defer {
            if !succeeded {
                try? FileManager.default.removeItem(at: trimmedURL)
            }
        }

        do {
            // writer をスコープ内に閉じ込め、URL を返す前に確実に解放（= flush/close）させる
            try autoreleasepool {
                let outFile = try AVAudioFile(forWriting: trimmedURL, settings: settings)
                let outFormat = outFile.processingFormat
                guard !outFormat.isInterleaved,
                      let trimBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(trimmedLength)),
                      let trimChannels = trimBuffer.floatChannelData else {
                    throw CocoaError(.fileWriteUnknown)
                }
                trimBuffer.frameLength = AVAudioFrameCount(trimmedLength)

                let srcChannelCount = Int(buffer.format.channelCount)
                let outChannels = Int(outFormat.channelCount)
                for ch in 0..<outChannels {
                    let srcCh = min(ch, srcChannelCount - 1)
                    let src = channels[srcCh]
                    let dst = trimChannels[ch]
                    for i in 0..<trimmedLength {
                        dst[i] = src[startFrame + i]
                    }
                }

                try outFile.write(from: trimBuffer)
            }
            succeeded = true
            return trimmedURL
        } catch {
            return nil
        }
    }
}
