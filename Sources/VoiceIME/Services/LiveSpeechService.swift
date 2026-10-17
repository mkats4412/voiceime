import Foundation
import Speech
import AVFoundation

@MainActor
public final class LiveSpeechService: ObservableObject {
    public static let shared = LiveSpeechService()

    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var partialText: String = ""
    @Published public private(set) var detectedLanguageIsJapanese: Bool = true

    private var audioEngine: AVAudioEngine?
    private var speechRecognizerJa: SFSpeechRecognizer?
    private var speechRecognizerEn: SFSpeechRecognizer?
    private var recognitionRequestJa: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionRequestEn: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTaskJa: SFSpeechRecognitionTask?
    private var recognitionTaskEn: SFSpeechRecognitionTask?

    private var latestJaText: String = ""
    private var latestEnText: String = ""
    private var isDualRecognition: Bool = false

    private var onTextUpdate: ((String) -> Void)?

    private init() {
        // 起動時ブロッキングを防ぐため、初回録音時に非同期で権限要求を行う
    }

    /// 音声認識の権限をリクエスト
    public func requestAuthorizationIfNeeded() {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in }
        }
    }

    /// リアルタイム音声認識を開始
    public func startLiveRecognition(
        languageCode: String = "",
        contextualStrings: [String] = [],
        onUpdate: @escaping (String) -> Void
    ) {
        stopLiveRecognition()

        let trimmedLang = languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isAuto = trimmedLang.isEmpty || trimmedLang == "auto"
        let isExplicitEnglish = trimmedLang.starts(with: "en")

        self.onTextUpdate = onUpdate
        self.partialText = ""
        self.latestJaText = ""
        self.latestEnText = ""
        self.detectedLanguageIsJapanese = !isExplicitEnglish
        self.isDualRecognition = isAuto

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // 入力フォーマットが有効か確認
        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            NSLog("[VoiceIME] ⚠️ 無効なオーディオ入力フォーマット: %@", recordingFormat.description)
            return
        }

        // 1. 日本語認識器の初期化（自動または日本語明示指定時）
        if isAuto || !isExplicitEnglish {
            if let recognizerJa = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")), recognizerJa.isAvailable {
                self.speechRecognizerJa = recognizerJa
                let reqJa = SFSpeechAudioBufferRecognitionRequest()
                reqJa.shouldReportPartialResults = true
                reqJa.taskHint = .dictation
                if !contextualStrings.isEmpty { reqJa.contextualStrings = contextualStrings }
                if #available(macOS 13.0, *) { reqJa.addsPunctuation = true }
                if #available(macOS 10.15, *), recognizerJa.supportsOnDeviceRecognition {
                    reqJa.requiresOnDeviceRecognition = false
                }
                self.recognitionRequestJa = reqJa

                self.recognitionTaskJa = recognizerJa.recognitionTask(with: reqJa) { [weak self] result, error in
                    Task { @MainActor [weak self] in
                        guard let self = self, self.isRunning else { return }
                        if let result = result {
                            self.latestJaText = result.bestTranscription.formattedString
                            self.handleTranscriptionUpdate()
                        }
                    }
                }
            }
        }

        // 2. 英語認識器の初期化（自動または英語明示指定時）
        if isAuto || isExplicitEnglish {
            if let recognizerEn = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizerEn.isAvailable {
                self.speechRecognizerEn = recognizerEn
                let reqEn = SFSpeechAudioBufferRecognitionRequest()
                reqEn.shouldReportPartialResults = true
                reqEn.taskHint = .dictation
                if !contextualStrings.isEmpty { reqEn.contextualStrings = contextualStrings }
                if #available(macOS 13.0, *) { reqEn.addsPunctuation = true }
                if #available(macOS 10.15, *), recognizerEn.supportsOnDeviceRecognition {
                    reqEn.requiresOnDeviceRecognition = false
                }
                self.recognitionRequestEn = reqEn

                self.recognitionTaskEn = recognizerEn.recognitionTask(with: reqEn) { [weak self] result, error in
                    Task { @MainActor [weak self] in
                        guard let self = self, self.isRunning else { return }
                        if let result = result {
                            self.latestEnText = result.bestTranscription.formattedString
                            self.handleTranscriptionUpdate()
                        }
                    }
                }
            }
        }

        guard self.recognitionRequestJa != nil || self.recognitionRequestEn != nil else {
            NSLog("[VoiceIME] ⚠️ 有効な SFSpeechRecognizer がありません")
            return
        }

        self.audioEngine = engine

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.recognitionRequestJa?.append(buffer)
            self.recognitionRequestEn?.append(buffer)
        }

        do {
            try engine.start()
            self.isRunning = true
            let modeDesc = isAuto ? "日英デュアル自動認識 (ja-JP & en-US)" : (isExplicitEnglish ? "英語固定 (en-US)" : "日本語固定 (ja-JP)")
            NSLog("[VoiceIME] 🎙️ リアルタイム音声認識エンジン開始: %@", modeDesc)
        } catch {
            NSLog("[VoiceIME] ⚠️ AVAudioEngine 開始失敗: %@", error.localizedDescription)
            stopLiveRecognition()
        }
    }

    /// 部分認識結果が更新された際の統合・言語自動選択
    private func handleTranscriptionUpdate() {
        if !isDualRecognition {
            // 単一言語モード
            let text = speechRecognizerJa != nil ? latestJaText : latestEnText
            let isJp = speechRecognizerJa != nil
            self.detectedLanguageIsJapanese = isJp
            let formatted = Self.formatLivePunctuation(text: text, isJapanese: isJp)
            self.partialText = formatted
            self.onTextUpdate?(formatted)
            return
        }

        // 日英デュアル認識モード: 発話内容からどちらの認識結果を採用するか動的に切り替え
        let ja = latestJaText.trimmingCharacters(in: .whitespacesAndNewlines)
        let en = latestEnText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !ja.isEmpty || !en.isEmpty else { return }

        let chosenText: String
        let isJp: Bool

        if ja.isEmpty {
            chosenText = en
            isJp = false
        } else if en.isEmpty {
            chosenText = ja
            isJp = true
        } else {
            // 両方ある場合の判定:
            // 日本語認識側がカタカナ音訳（英語発話のカタカナ化）かつ英語認識側に有効テキストがある場合は英語を採用
            if Self.isPhoneticEnglishTransliteration(ja) && !en.isEmpty {
                chosenText = en
                isJp = false
            } else {
                chosenText = ja
                isJp = true
            }
        }

        self.detectedLanguageIsJapanese = isJp
        let formatted = Self.formatLivePunctuation(text: chosenText, isJapanese: isJp)
        self.partialText = formatted
        self.onTextUpdate?(formatted)
    }

    /// 日本語エンジンが英語の発話を無理やりカタカナで音訳している状態（例: 「ディド ユー フィニッシュ イット」）を判定
    nonisolated public static func isPhoneticEnglishTransliteration(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }

        var kanjiCount = 0
        var hiraganaCount = 0
        var katakanaCount = 0

        for scalar in cleaned.unicodeScalars {
            // ひらがな: 3040〜309F
            if (0x3040...0x309F).contains(scalar.value) {
                hiraganaCount += 1
            }
            // カタカナ: 30A0〜30FF
            else if (0x30A0...0x30FF).contains(scalar.value) {
                katakanaCount += 1
            }
            // 漢字: 4E00〜9FAF
            else if (0x4E00...0x9FAF).contains(scalar.value) {
                kanjiCount += 1
            }
        }

        // 漢字が1文字でもあれば通常の日本語
        if kanjiCount > 0 { return false }

        // ひらがなが2文字以上あれば通常の日本語文（「です」「ます」など）
        if hiraganaCount >= 2 { return false }

        // カタカナが主体で、ひらがながほぼ無い場合は英語のカタカナ音訳とみなす
        if katakanaCount > 0 && hiraganaCount <= 1 {
            return true
        }

        return false
    }

    /// リアルタイム音声認識を停止
    public func stopLiveRecognition() {
        if isRunning || audioEngine != nil {
            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine = nil

            recognitionRequestJa?.endAudio()
            recognitionRequestJa = nil
            recognitionTaskJa?.cancel()
            recognitionTaskJa = nil

            recognitionRequestEn?.endAudio()
            recognitionRequestEn = nil
            recognitionTaskEn?.cancel()
            recognitionTaskEn = nil

            speechRecognizerJa = nil
            speechRecognizerEn = nil

            latestJaText = ""
            latestEnText = ""
            isRunning = false
            onTextUpdate = nil
            NSLog("[VoiceIME] ⏹️ リアルタイム音声認識エンジン停止")
        }
    }

    /// リアルタイム表示用の句読点補完と辞書置換
    nonisolated public static func formatLivePunctuation(text: String, isJapanese: Bool) -> String {
        return PunctuationService.shared.format(text: text, isJapanese: isJapanese)
    }
}
