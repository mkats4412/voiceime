import Foundation
import AVFoundation

public final class AudioRecorderService: NSObject, AVAudioRecorderDelegate {
    public static let shared = AudioRecorderService()

    private var audioRecorder: AVAudioRecorder?
    private var currentFileURL: URL?

    public private(set) var isRecording: Bool = false

    private override init() {
        super.init()
    }

    deinit {
        cancelRecording()
    }

    /// 録音を開始し、録音ファイルURLを返す
    public func startRecording() throws -> URL {
        // 既存の録音があれば停止・破棄（stopRecording が返す旧ファイルは削除して一時ファイルリークを防止）
        if let oldURL = stopRecording() {
            try? FileManager.default.removeItem(at: oldURL)
        } else if let leftover = currentFileURL {
            // isRecording==false だが currentFileURL が残っている稀なケース（ delegate エラー等）
            try? FileManager.default.removeItem(at: leftover)
            currentFileURL = nil
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "voiceime_\(UUID().uuidString).m4a"
        let fileURL = tempDir.appendingPathComponent(fileName)

        // Whisperに最適化されたAACモノラル16kHz設定
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true

        guard recorder.record() else {
            recorder.delegate = nil
            try? FileManager.default.removeItem(at: fileURL)
            throw NSError(
                domain: "AudioRecorderService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start audio recording."]
            )
        }

        self.audioRecorder = recorder
        self.currentFileURL = fileURL
        self.isRecording = true

        return fileURL
    }

    /// 録音を停止し、録音されたファイルのURLを返す
    @discardableResult
    public func stopRecording() -> URL? {
        guard isRecording, let recorder = audioRecorder else {
            return nil
        }

        recorder.delegate = nil
        recorder.stop()
        isRecording = false
        audioRecorder = nil

        let url = currentFileURL
        currentFileURL = nil
        return url
    }

    /// 録音を破棄して一時ファイルを削除
    public func cancelRecording() {
        if isRecording {
            audioRecorder?.delegate = nil
            audioRecorder?.stop()
            isRecording = false
            audioRecorder = nil
        }

        if let url = currentFileURL {
            try? FileManager.default.removeItem(at: url)
            currentFileURL = nil
        }
    }

    /// 現在の平均音量パワーを取得 (-160dB ... 0dB)
    public func averagePower() -> Float {
        guard isRecording, let recorder = audioRecorder else { return -160.0 }
        recorder.updateMeters()
        return recorder.averagePower(forChannel: 0)
    }

    // MARK: - AVAudioRecorderDelegate
    public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        isRecording = false
    }

    public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        isRecording = false
    }
}
