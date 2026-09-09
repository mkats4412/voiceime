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

    private var audioRecorder: AVAudioRecorder?
    private var tempFileURL: URL?
    private var meteringTimer: Timer?
    private var currentThreshold: Float = -32.0

    private init() {}

    deinit {
        // バックグラウンドでタイマーと録音を破棄
        meteringTimer?.invalidate()
        audioRecorder?.stop()
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

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

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "voiceime_mictest_\(UUID().uuidString).m4a"
        let fileURL = tempDir.appendingPathComponent(fileName)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
            AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                try? FileManager.default.removeItem(at: fileURL)
                errorMessage = "マイクのテスト録音を開始できませんでした。"
                return
            }

            self.audioRecorder = recorder
            self.tempFileURL = fileURL
            self.isTesting = true
            self.currentLevelDB = -60.0
            self.peakLevelDB = -60.0

            meteringTimer?.invalidate()
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateMetering()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.meteringTimer = timer

        } catch {
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
        meteringTimer?.invalidate()
        meteringTimer = nil

        if let recorder = audioRecorder {
            recorder.stop()
            self.audioRecorder = nil
        }

        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            self.tempFileURL = nil
        }

        self.isTesting = false
        self.currentLevelDB = -60.0
        self.peakLevelDB = -60.0
        self.isSpeechDetected = false
    }

    private func updateMetering() {
        guard isTesting, let recorder = audioRecorder, recorder.isRecording else { return }
        recorder.updateMeters()

        let avg = recorder.averagePower(forChannel: 0)
        let peak = recorder.peakPower(forChannel: 0)

        // なめらかなメーター追従（減衰時は少しスムーズに下げる）
        let clampedAvg = max(-60.0, min(0.0, avg))
        let clampedPeak = max(-60.0, min(0.0, peak))

        self.currentLevelDB = clampedAvg
        self.peakLevelDB = clampedPeak
        self.isSpeechDetected = (clampedAvg >= currentThreshold || clampedPeak >= currentThreshold + 2.0)
    }
}
