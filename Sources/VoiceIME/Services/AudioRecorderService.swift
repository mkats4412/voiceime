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

        // WhisperおよびmacOS CoreAudioネイティブ入力に最適化されたAACモノラル44.1kHz設定
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
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
    /// - Note: エンコードエラー等で delegate 経由で isRecording が false になっていても、
    ///   recorder を保持している限りは確実に stop/解放し、ファイルURLを返す（リーク・データ消失防止）。
    @discardableResult
    public func stopRecording() -> URL? {
        guard let recorder = audioRecorder else {
            isRecording = false
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

    /// 録音を一時停止（ファイルを閉じずにマイクを休止）
    public func pauseRecording() {
        audioRecorder?.pause()
        isRecording = false
    }

    /// 一時停止中の録音を同一ファイルへ再開
    @discardableResult
    public func resumeRecording() -> Bool {
        guard let recorder = audioRecorder else { return false }
        if recorder.record() {
            isRecording = true
            return true
        }
        return false
    }

    /// 録音を破棄して一時ファイルを削除
    public func cancelRecording() {
        // isRecording フラグに依存せず、保持している recorder は必ず停止・解放する
        if let recorder = audioRecorder {
            recorder.delegate = nil
            recorder.stop()
            audioRecorder = nil
        }
        isRecording = false

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
    // delegate は任意スレッドから呼ばれ得るため、状態変更はメインスレッドに集約してデータ競合を防ぐ。
    // 対象 recorder が現在保持中のものである場合のみフラグを落とす（古い recorder からの遅延通知を無視）。
    public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.audioRecorder === recorder else { return }
            self.isRecording = false
        }
    }

    public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.audioRecorder === recorder else { return }
            self.isRecording = false
        }
    }
}
