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

    // 日英デュアル認識用の英語ヘルパープロセス
    private var helperProcess: Process?
    private var helperStdinPipe: Pipe?
    private var helperStdoutPipe: Pipe?
    private var isDualMode: Bool = false
    private var latestJaText: String = ""
    private var latestEnText: String = ""

    // オーディオレンダースレッドをブロックさせないための専用書き込みシリアルキュー
    private let helperAudioQueue = DispatchQueue(label: "com.voiceime.livespeech.helperaudio", qos: .userInteractive)
    // 子プロセス標準出力の行結合・UTF-8デコード用シリアルキュー
    private let helperStdoutQueue = DispatchQueue(label: "com.voiceime.livespeech.helperstdout", qos: .userInitiated)

    private var onTextUpdate: ((String) -> Void)?

    private init() {
        // パイプ破断時の SIGPIPE による異常クラッシュを防止
        signal(SIGPIPE, SIG_IGN)
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
        self.latestJaText = ""
        self.latestEnText = ""
        self.detectedLanguageIsJapanese = !isExplicitEnglish
        self.isDualMode = isAuto

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

        let audioQueue = self.helperAudioQueue

        // 🌟 核心: 何よりも最優先でマイクタップの設置とAVAudioEngineの起動を直ちに実行！
        // （別プロセス起動やタスク初期化による出だしの音声・主語の取りこぼしを完全防止）
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self, weak request] buffer, _ in
            guard let self = self, self.isRunning else { return }

            // 1. 親プロセスの認識器へバッファ供給（ゼロ遅延リアルタイム出力）
            request?.append(buffer)

            // 2. 英語ヘルパープロセスの stdin へ PCM Float32 を非同期シリアルキューで送信
            if self.isDualMode, let pipe = self.helperStdinPipe,
               let channelData = buffer.floatChannelData, buffer.frameLength > 0 {
                let byteCount = Int(buffer.frameLength) * MemoryLayout<Float>.size
                let data = Data(bytes: channelData[0], count: byteCount)
                audioQueue.async {
                    try? pipe.fileHandleForWriting.write(contentsOf: data)
                }
            }

            // 3. 一括送信がOFFの場合、ストリーミングパイプラインへ供給
            if !AppSettings.shared.batchTranscriptionEnabled {
                StreamingChunkPipelineService.shared.appendAudioBuffer(buffer)
            }
        }

        do {
            try engine.start()
            self.isRunning = true
            PipelineLogger.shared.logDebug("🎙️ AVAudioEngine 正常起動完了 (マイクタップ開始)")
            NSLog("[VoiceIME] 🎙️ リアルタイム音声認識エンジン開始 (%@, isAuto: %d)", localeIdentifier, isAuto ? 1 : 0)
        } catch {
            PipelineLogger.shared.logDebug("❌ AVAudioEngine 開始失敗: \(error.localizedDescription)")
            NSLog("[VoiceIME] ⚠️ AVAudioEngine 開始失敗: %@", error.localizedDescription)
            stopLiveRecognition()
            return
        }

        // 親プロセスの音声認識タスク（マイク起動後に非同期で開始）
        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self = self, self.isRunning else { return }

                if let result = result {
                    let rawText = result.bestTranscription.formattedString
                    let cleanText = Self.cleanTranscriptionText(rawText)

                    if self.isDualMode {
                        self.latestJaText = cleanText
                        self.handleDualTranscriptionUpdate()
                    } else {
                        guard !cleanText.isEmpty else { return }
                        let isJp = !isExplicitEnglish
                        self.detectedLanguageIsJapanese = isJp
                        let formatted = isJp ? Self.formatLivePunctuation(text: cleanText, isJapanese: true) : cleanText
                        self.partialText = formatted
                        self.onTextUpdate?(formatted)
                    }
                }

                if let error = error {
                    let nsError = error as NSError
                    if nsError.domain != "kAFAssistantErrorDomain" || nsError.code != 203 {
                        NSLog("[VoiceIME] ℹ️ SFSpeechRecognitionTask 停止/通知: %@", error.localizedDescription)
                    }
                }
            }
        }

        // 自動判定モードの場合: マイク起動完了後に英語認識ヘルパー子プロセスを立ち上げ
        if isAuto, let execPath = Bundle.main.executablePath, FileManager.default.isExecutableFile(atPath: execPath) {
            Task { @MainActor [weak self] in
                guard let self = self, self.isRunning else { return }
                self.startEnglishHelperProcess(executablePath: execPath, format: recordingFormat)
            }
        }
    }

    /// 英語認識ヘルパー子プロセスの起動
    private func startEnglishHelperProcess(executablePath: String, format: AVAudioFormat) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "--live-speech-helper",
            "--locale", "en-US",
            "--sample-rate", "\(format.sampleRate)",
            "--channels", "1"
        ]

        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        let stdoutQueue = self.helperStdoutQueue
        var lineBuffer = Data()

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }

            stdoutQueue.async { [weak self] in
                lineBuffer.append(chunk)
                // 改行バイト (0x0A) 単位で完全な行のみを切り出してデコード（UTF-8分断・行途中分断の完全防止）
                while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
                    let lineData = lineBuffer.subdata(in: 0..<newlineIndex)
                    lineBuffer.removeSubrange(0...newlineIndex)

                    guard let line = String(data: lineData, encoding: .utf8),
                          line.hasPrefix("TEXT:") else { continue }

                    let text = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    Task { @MainActor [weak self] in
                        guard let self = self, self.isRunning, self.isDualMode else { return }
                        self.latestEnText = Self.cleanTranscriptionText(text)
                        self.handleDualTranscriptionUpdate()
                    }
                }
            }
        }

        do {
            try process.run()
            self.helperProcess = process
            self.helperStdinPipe = inPipe
            self.helperStdoutPipe = outPipe
            NSLog("[VoiceIME] 🚀 英語認識ヘルパー子プロセス起動完了 (PID: %d)", process.processIdentifier)
        } catch {
            NSLog("[VoiceIME] ⚠️ 英語認識ヘルパー起動失敗: %@", error.localizedDescription)
            outPipe.fileHandleForReading.readabilityHandler = nil
            try? inPipe.fileHandleForWriting.close()
            try? outPipe.fileHandleForReading.close()
            self.helperStdinPipe = nil
            self.helperStdoutPipe = nil
            self.helperProcess = nil
        }
    }

    /// デュアル認識（ja-JP と en-US）の認識結果を照合し、最適な言語とテキストを選択
    private func handleDualTranscriptionUpdate() {
        guard let decision = Self.decideBestTranscription(
            jaText: latestJaText,
            enText: latestEnText
        ) else { return }

        self.detectedLanguageIsJapanese = decision.isJapanese
        let formatted = decision.isJapanese
            ? Self.formatLivePunctuation(text: decision.text, isJapanese: true)
            : decision.text
        self.partialText = formatted
        self.onTextUpdate?(formatted)
    }

    /// 判定ロジック構造体
    public struct ScriptCounts {
        public let kanji: Int
        public let hiragana: Int
        public let katakana: Int
        public let latin: Int
    }

    /// 文字種カウント（漢字、ひらがな、カタカナ、ラテン文字）
    nonisolated public static func analyzeScriptCounts(_ text: String) -> ScriptCounts {
        var kanji = 0
        var hiragana = 0
        var katakana = 0
        var latin = 0

        for scalar in text.unicodeScalars {
            // ひらがな: 3040〜309F
            if (0x3040...0x309F).contains(scalar.value) {
                hiragana += 1
            }
            // 全角カタカナ: 30A0〜30FF または 半角カタカナ: FF66〜FF9F
            else if (0x30A0...0x30FF).contains(scalar.value) || (0xFF66...0xFF9F).contains(scalar.value) {
                katakana += 1
            }
            // 漢字（CJK統合漢字）: 4E00〜9FAF
            else if (0x4E00...0x9FAF).contains(scalar.value) {
                kanji += 1
            }
            // ASCII ラテン文字: A-Z, a-z
            else if (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) {
                latin += 1
            }
        }
        return ScriptCounts(kanji: kanji, hiragana: hiragana, katakana: katakana, latin: latin)
    }

    /// 日本語（JA）と英語（EN）の部分認識テキストから、リアルタイム表示に最適なテキストと判定言語を決定
    nonisolated public static func decideBestTranscription(
        jaText: String,
        enText: String
    ) -> (text: String, isJapanese: Bool)? {
        let ja = cleanTranscriptionText(jaText)
        let en = cleanTranscriptionText(enText)

        guard !ja.isEmpty || !en.isEmpty else { return nil }

        let counts = analyzeScriptCounts(ja)

        // 1. 漢字が1文字でもある、またはひらがなが1文字でもある（例: 「こ」「ん」「こんにちは」「お疲れ様です」「はい」「今日」など）
        // ➔ 100% 日本語（JA）を採用！
        if counts.kanji > 0 || counts.hiragana >= 1 {
            return (ja, true)
        }

        // 2. 日本語テキストが存在する場合（崩れ英字「A ロ had ゥ ー in グ」やカタカナ音訳「ハローハード」など）:
        // 英語側に有効な英文フレーズがあれば英語を採用！
        if !ja.isEmpty {
            if !en.isEmpty && isValidEnglishPhrase(en) && !containsRomajiJapanese(en) {
                return (en, false)
            }
            if counts.katakana > 0 && KatakanaEnglishConverter.shared.hasConversion(for: ja) {
                let converted = KatakanaEnglishConverter.shared.convertToEnglish(ja)
                return (converted, false)
            }
            return (ja, true)
        }

        // 3. 日本語側（ja）がまだ空の初期段階:
        // 英語側の初動1単語（例: "Kak", "Can" 等）はノイズ誤認の可能性があるため、
        // 2単語以上の明確な英文フレーズ（例: "Hello, how are you", "did you finish it" 等）でない限り、
        // 日本語エンジンの初動テキストが届くまで待機する！
        let words = en.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if words.count >= 2 && isValidEnglishPhrase(en) && !containsRomajiJapanese(en) {
            return (en, false)
        }

        return nil
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

    /// 自然な英単語フレーズ（ASCIIアルファベットと英語標準記号で構成された有効な英文）かどうかを判定
    nonisolated public static func isValidEnglishPhrase(_ text: String) -> Bool {
        let cleaned = cleanTranscriptionText(text)
        guard !cleaned.isEmpty else { return false }

        // ASCIIアルファベットと英語標準記号のみに厳格限定（日本語Unicode文字の混入を完全遮断）
        let englishAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ',.-?! ")
        guard cleaned.unicodeScalars.allSatisfy({ englishAllowed.contains($0) }) else {
            return false
        }

        // 少なくとも1文字以上の英字を含んでいること
        let hasLatinLetter = cleaned.unicodeScalars.contains { scalar in
            (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
        }
        guard hasLatinLetter else { return false }

        let words = cleaned.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }

        return true
    }

    /// 英語認識器が日本語の音を聞いた際に誤って出力する代表的なローマ字単語を検知
    nonisolated public static func containsRomajiJapanese(_ text: String) -> Bool {
        let lower = text.lowercased()
        let romajiKeywords = [
            "konnichiwa", "konnichwa", "konichiwa",
            "arigato", "arigatou",
            "ohayo", "ohayou",
            "sayonara", "sayounara",
            "kudasai", "onegaishimasu",
            "otsukare", "otsukaresama",
            "desu", "masu", "mashita", "deshita",
            "hai", "iie", "chotto", "sugoi", "deki"
        ]
        for kw in romajiKeywords {
            if lower.contains(kw) {
                return true
            }
        }
        return false
    }

    /// 日本語エンジンが英語の発話を無理やりカタカナで音訳している状態（例: 「ディド ユー フィニッシュ イット」）を判定
    nonisolated public static func isPhoneticEnglishTransliteration(_ text: String) -> Bool {
        let counts = analyzeScriptCounts(text)
        if counts.kanji > 0 { return false }
        if counts.hiragana >= 2 { return false }
        if counts.katakana > 0 && counts.hiragana <= 1 {
            return true
        }
        return false
    }

    /// リアルタイム音声認識を停止
    public func stopLiveRecognition() {
        if isRunning || audioEngine != nil || helperProcess != nil {
            // 1. オーディオ入力の停止とタップ解除
            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine = nil

            // 2. 音声認識リクエストの終了
            recognitionRequest?.endAudio()
            recognitionRequest = nil

            recognitionTask?.cancel()
            recognitionTask = nil

            speechRecognizer = nil

            // 3. 英語ヘルパープロセスの安全な終了とリソース解放
            // helperAudioQueue 内の未処理 write とのデータ競合を防ぐため、同一シリアルキュー上で close する
            if let inPipe = helperStdinPipe {
                helperStdinPipe = nil
                helperAudioQueue.async {
                    try? inPipe.fileHandleForWriting.close()
                }
            }
            if let outPipe = helperStdoutPipe {
                outPipe.fileHandleForReading.readabilityHandler = nil
                try? outPipe.fileHandleForReading.close()
                helperStdoutPipe = nil
            }
            if let process = helperProcess {
                helperProcess = nil
                if process.isRunning {
                    process.terminate()
                    // ゾンビプロセス化を防ぐためバックグラウンドで回収待ち
                    DispatchQueue.global(qos: .utility).async {
                        process.waitUntilExit()
                    }
                }
            }

            isRunning = false
            isDualMode = false
            latestJaText = ""
            latestEnText = ""
            onTextUpdate = nil
            NSLog("[VoiceIME] ⏹️ リアルタイム音声認識エンジン停止")
        }
    }

    /// リアルタイム表示用の句読点補完と辞書置換
    nonisolated public static func formatLivePunctuation(text: String, isJapanese: Bool) -> String {
        return PunctuationService.shared.format(text: text, isJapanese: isJapanese)
    }
}
