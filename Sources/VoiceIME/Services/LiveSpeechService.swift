import Foundation
import Speech
import AVFoundation

@MainActor
public final class LiveSpeechService: ObservableObject {
    public static let shared = LiveSpeechService()

    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var partialText: String = ""

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var onTextUpdate: ((String) -> Void)?

    private init() {
        requestAuthorizationIfNeeded()
    }

    /// 音声認識の権限をリクエスト
    public func requestAuthorizationIfNeeded() {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in }
        }
    }

    /// リアルタイム音声認識を開始
    public func startLiveRecognition(
        languageCode: String = "ja",
        onUpdate: @escaping (String) -> Void
    ) {
        stopLiveRecognition()

        let isJapanese = !languageCode.lowercased().starts(with: "en")
        let localeIdentifier = isJapanese ? "ja-JP" : "en-US"
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))

        guard let recognizer = recognizer, recognizer.isAvailable else {
            NSLog("[VoiceIME] ⚠️ SFSpeechRecognizer が利用できません (言語: %@)", localeIdentifier)
            return
        }

        self.speechRecognizer = recognizer
        self.onTextUpdate = onUpdate
        self.partialText = ""

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // 入力フォーマットが有効か確認
        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            NSLog("[VoiceIME] ⚠️ 無効なオーディオ入力フォーマット: %@", recordingFormat.description)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        // 句読点（。、！？）の自動付与を有効化 (macOS 13.0+)
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        // オンデバイス認識が可能なら優先して低遅延化
        if #available(macOS 10.15, *) {
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = false // 精度向上のため柔軟に設定
            }
        }

        self.recognitionRequest = request
        self.audioEngine = engine

        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self = self, self.isRunning else { return }

                if let result = result {
                    let rawText = result.bestTranscription.formattedString
                    // リアルタイム句読点補正および辞書置換を適用
                    let formattedText = Self.formatLivePunctuation(text: rawText, isJapanese: isJapanese)
                    self.partialText = formattedText
                    self.onTextUpdate?(formattedText)
                }

                if let error = error {
                    let nsError = error as NSError
                    if nsError.domain != "kAFAssistantErrorDomain" || nsError.code != 203 {
                        NSLog("[VoiceIME] ℹ️ SFSpeechRecognitionTask 停止/通知: %@", error.localizedDescription)
                    }
                }
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        do {
            try engine.start()
            self.isRunning = true
            NSLog("[VoiceIME] 🎙️ リアルタイム音声認識エンジン開始 (%@, addsPunctuation: true)", localeIdentifier)
        } catch {
            NSLog("[VoiceIME] ⚠️ AVAudioEngine 開始失敗: %@", error.localizedDescription)
            stopLiveRecognition()
        }
    }

    /// リアルタイム音声認識を停止
    public func stopLiveRecognition() {
        if isRunning || audioEngine != nil {
            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine = nil

            recognitionRequest?.endAudio()
            recognitionRequest = nil

            recognitionTask?.cancel()
            recognitionTask = nil

            isRunning = false
            onTextUpdate = nil
            NSLog("[VoiceIME] ⏹️ リアルタイム音声認識エンジン停止")
        }
    }

    /// リアルタイム表示用の句読点補完と辞書置換
    nonisolated public static func formatLivePunctuation(text: String, isJapanese: Bool) -> String {
        guard !text.isEmpty else { return text }

        // 辞書ルールのリアルタイム適用（例: 「改行」➔ \n）
        var formatted = DictionaryService.shared.apply(
            text: text,
            rules: AppSettings.shared.dictionaryRules
        )

        guard isJapanese else { return formatted }

        // 文末表現の後に続く空白・発話の区切りに「。」を補完
        let sentenceEndings = [
            "です", "ます", "でした", "ました", "ません", "ませんでした",
            "ですね", "ですよ", "でしょうか", "ございます", "ございました",
            "と思います", "と考えます", "とのことです"
        ]

        for ending in sentenceEndings {
            // 文末表現の直後に空白がある場合、句点「。」に置換
            formatted = formatted.replacingOccurrences(of: "\(ending) ", with: "\(ending)。")
            formatted = formatted.replacingOccurrences(of: "\(ending)　", with: "\(ending)。")
        }

        // 接続詞・節の切れ目の空白を読点「、」に補正
        let clauseEndings = [
            "ですが ", "ですので ", "ですから ", "けれども ", "けれど ",
            "ただし ", "一方で ", "また ", "そして "
        ]
        for ending in clauseEndings {
            let clean = ending.trimmingCharacters(in: .whitespaces)
            formatted = formatted.replacingOccurrences(of: ending, with: "\(clean)、")
        }

        return formatted
    }
}
