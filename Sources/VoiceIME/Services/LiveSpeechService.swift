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
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

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

        // 英語明示時以外（自動判定または日本語指定）は日本語エンジン（ja-JP）を使用
        let localeIdentifier = isExplicitEnglish ? "en-US" : "ja-JP"
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))

        guard let recognizer = recognizer, recognizer.isAvailable else {
            NSLog("[VoiceIME] ⚠️ SFSpeechRecognizer が利用できません (言語: %@)", localeIdentifier)
            return
        }

        self.speechRecognizer = recognizer
        self.onTextUpdate = onUpdate
        self.partialText = ""
        self.detectedLanguageIsJapanese = !isExplicitEnglish

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            NSLog("[VoiceIME] ⚠️ 無効なオーディオ入力フォーマット: %@", recordingFormat.description)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if !contextualStrings.isEmpty { request.contextualStrings = contextualStrings }
        if #available(macOS 13.0, *) { request.addsPunctuation = true }
        if #available(macOS 10.15, *), recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = false
        }

        self.recognitionRequest = request
        self.audioEngine = engine

        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self = self, self.isRunning else { return }

                if let result = result {
                    let rawText = result.bestTranscription.formattedString
                    let cleanText = Self.cleanTranscriptionText(rawText)
                    guard !cleanText.isEmpty else { return }

                    let chosenText: String
                    let isJp: Bool

                    if isExplicitEnglish {
                        chosenText = cleanText
                        isJp = false
                    } else if isAuto {
                        // 自動判定モード:
                        // カタカナ音訳（例: 「ディド ユー フィニッシュ イット」）の場合は即座に英語（"Did you finish it?"）に変換！
                        if Self.isPhoneticEnglishTransliteration(cleanText) {
                            chosenText = KatakanaEnglishConverter.shared.convertToEnglish(cleanText)
                            isJp = false
                        } else {
                            // 通常の日本語文（「こんにちは」「お疲れ様です」等）は100%リアルタイムに日本語出力
                            chosenText = cleanText
                            isJp = true
                        }
                    } else {
                        chosenText = cleanText
                        isJp = true
                    }

                    self.detectedLanguageIsJapanese = isJp
                    let formatted = isJp ? Self.formatLivePunctuation(text: chosenText, isJapanese: true) : chosenText
                    self.partialText = formatted
                    self.onTextUpdate?(formatted)
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
            NSLog("[VoiceIME] 🎙️ リアルタイム音声認識エンジン開始 (%@, isAuto: %d)", localeIdentifier, isAuto ? 1 : 0)
        } catch {
            NSLog("[VoiceIME] ⚠️ AVAudioEngine 開始失敗: %@", error.localizedDescription)
            stopLiveRecognition()
        }
    }

    /// 音声認識結果のクリーンアップ（"Dictate " プレフィックスの除去等）
    nonisolated public static func cleanTranscriptionText(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().starts(with: "dictate ") {
            cleaned = String(cleaned.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if cleaned.lowercased() == "dictate" {
            cleaned = ""
        }
        return cleaned
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

            recognitionRequest?.endAudio()
            recognitionRequest = nil

            recognitionTask?.cancel()
            recognitionTask = nil

            speechRecognizer = nil

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
