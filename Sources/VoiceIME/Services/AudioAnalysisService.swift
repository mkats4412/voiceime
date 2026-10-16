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
    /// 発話開始位置（秒）
    public let speechStartSeconds: Double?
    /// 発話終了位置（秒）
    public let speechEndSeconds: Double?
    /// 音声全体の長さ（秒）
    public let totalDurationSeconds: Double
}

public final class AudioAnalysisService {
    public static let shared = AudioAnalysisService()

    private init() {}

    /// 録音ファイルの音量を解析し、声としての音量（しきい値）に達しているかを判定する
    public func analyze(audioFileURL: URL, thresholdDB: Float) -> AudioAnalysisMetrics {
        guard let file = try? AVAudioFile(forReading: audioFileURL) else {
            // ファイル読み込みに失敗した場合は、誤って発話を遮断しないよう安全に hasSpeech: true でフォールバック
            return AudioAnalysisMetrics(
                hasSpeech: true,
                maxWindowRMS_DB: 0,
                peakPowerDB: 0,
                averageRMS_DB: 0,
                speechStartSeconds: nil,
                speechEndSeconds: nil,
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
                totalDurationSeconds: 0
            )
        }

        guard format.channelCount > 0,
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData else {
            return AudioAnalysisMetrics(
                hasSpeech: true,
                maxWindowRMS_DB: 0,
                peakPowerDB: 0,
                averageRMS_DB: 0,
                speechStartSeconds: nil,
                speechEndSeconds: nil,
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

        if totalFrames <= windowSize {
            maxRMS = avgRMS_DB
            if maxRMS >= thresholdDB {
                firstSpeechFrame = 0
                lastSpeechFrame = totalFrames
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
                pos += stepSize
            }
        }

        let hasSpeech = (firstSpeechFrame != nil)
        let startSec = firstSpeechFrame.map { Double($0) / Double(sampleRate) }
        let endSec = lastSpeechFrame.map { Double($0) / Double(sampleRate) }

        return AudioAnalysisMetrics(
            hasSpeech: hasSpeech,
            maxWindowRMS_DB: maxRMS,
            peakPowerDB: peakDB,
            averageRMS_DB: avgRMS_DB,
            speechStartSeconds: startSec,
            speechEndSeconds: endSec,
            totalDurationSeconds: totalDuration
        )
    }

    /// 発話前後の無音・微小環境音を自然にトリミングした新ファイルを生成する（不要な場合は nil）
    public func trimLeadingTrailingNoise(
        audioFileURL: URL,
        thresholdDB: Float,
        leadingMarginSeconds: Double = 0.15,
        trailingMarginSeconds: Double = 0.35
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

        var pos = 0
        while pos + windowSize <= totalFrames {
            var sumSq: Float = 0.0
            for i in pos..<(pos + windowSize) {
                let s = channel0[i]
                sumSq += s * s
            }
            let rms = sqrt(sumSq / Float(windowSize))
            let rmsDB = rms > 1e-5 ? 20.0 * log10(rms) : -100.0
            if rmsDB >= thresholdDB {
                if firstSpeechFrame == nil { firstSpeechFrame = pos }
                lastSpeechFrame = pos + windowSize
            }
            pos += stepSize
        }

        guard let first = firstSpeechFrame, let last = lastSpeechFrame else {
            return nil
        }

        // 先頭（150ms）と末尾（350ms）のマージンを確保。
        // 特に語尾の終助詞（〜ね、〜よ等）のフェードアウトや息づかいが脱落しないよう末尾マージンを十分に確保する。
        let leadingMarginFrames = Int(sampleRate * Float(leadingMarginSeconds))
        let trailingMarginFrames = Int(sampleRate * Float(trailingMarginSeconds))
        let startFrame = max(0, first - leadingMarginFrames)
        let endFrame = min(totalFrames, last + trailingMarginFrames)
        let trimmedLength = endFrame - startFrame

        // 削る部分が前後合計で 150ms 未満なら、再エンコードのコストを避けて元のファイルをそのまま使用
        let totalTrimmedFrames = startFrame + (totalFrames - endFrame)
        let minTrimFramesToJustify = Int(sampleRate * 0.15)
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
