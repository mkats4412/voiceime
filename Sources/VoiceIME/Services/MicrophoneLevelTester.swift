import Foundation
import AVFoundation
import Combine

@MainActor
public final class MicrophoneLevelTester: ObservableObject {
    public static let shared = MicrophoneLevelTester()

    @Published public var isTesting: Bool = false
    @Published public var currentLevelDB: Float = -60.0
    @Published public var peakLevelDB: Float = -60.0
    @Published public var isSpeechDetected: Bool = false
    @Published public var errorMessage: String? = nil

    private var audioEngine: AVAudioEngine?
    private var currentThreshold: Float = -32.0

    private init() {}

    /// マイク入力のリアルタイムテストを開始
    public func startTesting(thresholdDB: Float) {
        guard !isTesting else {
            self.currentThreshold = thresholdDB
            return
        }

        // 実際の音声入力録音が進行中の場合は競合を避けて開始しない
        if AudioRecorderService.shared.isRecording {
            return
        }

        let permissions = PermissionService.shared
        permissions.checkPermissions()
        guard permissions.isMicrophoneAuthorized else {
            errorMessage = "マイクへのアクセス権限が必要です。"
            permissions.requestMicrophoneAccess()
            return
        }

        self.currentThreshold = thresholdDB
        self.errorMessage = nil

        let engine = AVAudioEngine()

        // 選択されたマイク（またはシステムデフォルトへのフォールバック）を設定
        do {
            try AudioDeviceService.shared.setupInputDevice(for: engine)
        } catch {
            NSLog("[VoiceIME] ⚠️ レベルテスト用マイク設定エラー: %@", error.localizedDescription)
            // デバイス設定でエラーになってもデフォルト状態で続行を試みる
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0 && format.channelCount > 0 else {
            errorMessage = "無効なオーディオ入力フォーマットです。"
            return
        }

        var lastUpdateTime: CFAbsoluteTime = 0.0

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }

            let len = Int(buffer.frameLength)
            var sum: Float = 0.0
            var peak: Float = 0.0

            for i in 0..<len {
                let sample = channelData[i]
                let absVal = abs(sample)
                if absVal > peak { peak = absVal }
                sum += sample * sample
            }

            let rms = sqrt(sum / Float(len))
            let avgDB: Float = (rms > 0.00001) ? max(-60.0, min(0.0, 20.0 * log10(rms))) : -60.0
            let peakDB: Float = (peak > 0.00001) ? max(-60.0, min(0.0, 20.0 * log10(peak))) : -60.0

            // UIスレッドへの過剰なディスパッチを抑制（約35ms間隔 = 約28fps）
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastUpdateTime >= 0.035 else { return }
            lastUpdateTime = now

            Task { @MainActor [weak self] in
                guard let self = self, self.isTesting else { return }
                self.currentLevelDB = avgDB
                self.peakLevelDB = peakDB
                self.isSpeechDetected = (avgDB >= self.currentThreshold || peakDB >= self.currentThreshold + 2.0)
            }
        }

        do {
            try engine.start()
            self.audioEngine = engine
            self.isTesting = true
            self.currentLevelDB = -60.0
            self.peakLevelDB = -60.0
        } catch {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            self.audioEngine = nil
            self.errorMessage = error.localizedDescription
            self.isTesting = false
        }
    }

    /// しきい値の更新
    public func updateThreshold(_ thresholdDB: Float) {
        self.currentThreshold = thresholdDB
    }

    /// マイク入力テストを停止
    public func stopTesting() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.audioEngine = nil
        }

        self.isTesting = false
        self.currentLevelDB = -60.0
        self.peakLevelDB = -60.0
        self.isSpeechDetected = false
    }
}
