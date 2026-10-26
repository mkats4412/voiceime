import Foundation
import Speech
import AVFoundation

@MainActor
public final class LiveSpeechService: ObservableObject {
    public static let shared = LiveSpeechService()

    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var hasReceivedFirstBuffer: Bool = false
    @Published public private(set) var partialText: String = ""
    @Published public private(set) var detectedLanguageIsJapanese: Bool = true

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // 事前キャッシュ済みの音声認識インスタンス（ホットキー押下時の初期化遅延を排除）
    private lazy var jaRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private lazy var enRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    // オーディオレンダースレッドとメインスレッド間で安全に共有するロックと状態
    private let tapLock = NSLock()
    private var isTapCapturing: Bool = false
    private var firstBufferNotified: Bool = false
    private var activeRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var activeHelperStdinPipe: Pipe?
    private var activeIsDualMode: Bool = false

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

    // 本クラスは shared シングルトンとしてアプリ常駐するため deinit は呼ばれません。
    // 停止は @MainActor の stopLiveRecognition() を明示的に呼び出します。

    /// 音声認識の権限をリクエスト
    public func requestAuthorizationIfNeeded() {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in }
        }
    }

    /// ホットキー押下時（録音開始時のみ）に何よりも最優先でAVAudioEngineとマイクタップを起動する。
    /// ※待機中（非録音時）はセキュリティ・プライバシー保護のためマイクを一切稼働させない。
    @discardableResult
    public func startImmediateCapture() -> Bool {
        stopLiveRecognition()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            NSLog("[VoiceIME] ⚠️ 無効なオーディオ入力フォーマット: %@", recordingFormat.description)
            return false
        }

        let audioQueue = self.helperAudioQueue

        tapLock.lock()
        isTapCapturing = true
        firstBufferNotified = false
        activeRecognitionRequest = nil
        activeIsDualMode = false
        activeHelperStdinPipe = nil
        tapLock.unlock()

        self.isRunning = true
        self.hasReceivedFirstBuffer = false

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            self.tapLock.lock()
            let capturing = self.isTapCapturing
            let shouldNotifyFirst = !self.firstBufferNotified
            if shouldNotifyFirst && capturing {
                self.firstBufferNotified = true
            }
            let req = self.activeRecognitionRequest
            let dual = self.activeIsDualMode
            let pipe = self.activeHelperStdinPipe
            self.tapLock.unlock()

            guard capturing else { return }

            // 最初の音声バッファがマイクから届いた瞬間にUIインジケーターをグリーン（発話可能）に切り替え
            if shouldNotifyFirst {
                Task { @MainActor [weak self] in
                    guard let self = self, self.isRunning else { return }
                    self.hasReceivedFirstBuffer = true
                    FloatingPreviewController.shared.setMicReady()
                }
            }

            // 1. ストリーミングパイプラインおよび全体録音バッファへ最優先供給
            StreamingChunkPipelineService.shared.appendAudioBuffer(buffer, isPreRoll: false)

            // 2. 親プロセスの認識器へバッファ供給
            req?.append(buffer)

            // 3. 英語ヘルパープロセスの stdin へ PCM Float32 を非同期シリアルキューで送信
            if dual, let pipe = pipe,
               let channelData = buffer.floatChannelData, buffer.frameLength > 0 {
                let byteCount = Int(buffer.frameLength) * MemoryLayout<Float>.size
                let data = Data(bytes: channelData[0], count: byteCount)
                audioQueue.async {
                    try? pipe.fileHandleForWriting.write(contentsOf: data)
                }
            }
        }

        do {
            try engine.start()
            self.audioEngine = engine
            PipelineLogger.shared.logDebug("🎙️ AVAudioEngine 正常起動完了 (マイクタップ開始)")
            return true
        } catch {
            tapLock.lock()
            isTapCapturing = false
            tapLock.unlock()
            self.isRunning = false
            inputNode.removeTap(onBus: 0)
            engine.stop()
            self.audioEngine = nil
            PipelineLogger.shared.logDebug("❌ AVAudioEngine 開始失敗: \(error.localizedDescription)")
            NSLog("[VoiceIME] ⚠️ AVAudioEngine 開始失敗: %@", error.localizedDescription)
            return false
        }
    }

    /// リアルタイム音声認識を開始
    public func startLiveRecognition(
        languageCode: String = "",
        contextualStrings: [String] = [],
        onUpdate: @escaping (String) -> Void
    ) {
        let alreadyCapturing: Bool = {
            tapLock.lock()
            defer { tapLock.unlock() }
            return isTapCapturing && audioEngine != nil
        }()

        if !alreadyCapturing {
            guard startImmediateCapture() else { return }
        } else {
            cleanupRecognitionTasksOnly()
        }

        let trimmedLang = languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isAuto = trimmedLang.isEmpty || trimmedLang == "auto"
        let isExplicitEnglish = trimmedLang.starts(with: "en")

        // 英語明示時以外（自動判定または日本語指定）は日本語エンジン（ja-JP）を使用
        let localeIdentifier = isExplicitEnglish ? "en-US" : "ja-JP"
        let recognizer = (isExplicitEnglish ? enRecognizer : jaRecognizer)
            ?? SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))

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

        guard let engine = self.audioEngine, engine.isRunning else {
            return
        }
        let recordingFormat = engine.inputNode.outputFormat(forBus: 0)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if !contextualStrings.isEmpty { request.contextualStrings = contextualStrings }
        if #available(macOS 13.0, *) { request.addsPunctuation = true }
        if #available(macOS 10.15, *), recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = false
        }

        self.recognitionRequest = request
        self.isRunning = true

        tapLock.lock()
        self.activeRecognitionRequest = request
        self.activeIsDualMode = isAuto
        tapLock.unlock()

        NSLog("[VoiceIME] 🎙️ リアルタイム音声認識エンジン開始 (%@, isAuto: %d)", localeIdentifier, isAuto ? 1 : 0)

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
            tapLock.lock()
            self.activeHelperStdinPipe = inPipe
            tapLock.unlock()
            NSLog("[VoiceIME] 🚀 英語認識ヘルパー子プロセス起動完了 (PID: %d)", process.processIdentifier)
        } catch {
            NSLog("[VoiceIME] ⚠️ 英語認識ヘルパー起動失敗: %@", error.localizedDescription)
            outPipe.fileHandleForReading.readabilityHandler = nil
            try? inPipe.fileHandleForWriting.close()
            try? outPipe.fileHandleForReading.close()
            self.helperStdinPipe = nil
            self.helperStdoutPipe = nil
            self.helperProcess = nil
            tapLock.lock()
            self.activeHelperStdinPipe = nil
            tapLock.unlock()
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

    /// 音声認識タスクとヘルパープロセスのみをクリーンアップ（AVAudioEngineのマイクタップは維持）
    private func cleanupRecognitionTasksOnly() {
        tapLock.lock()
        activeRecognitionRequest = nil
        activeIsDualMode = false
        activeHelperStdinPipe = nil
        tapLock.unlock()

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil

        speechRecognizer = nil

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
                DispatchQueue.global(qos: .utility).async {
                    process.waitUntilExit()
                }
            }
        }
    }

    /// リアルタイム音声認識を停止（セキュリティ・プライバシー保護のためマイク入力を完全に停止・解放する）
    public func stopLiveRecognition() {
        let wasCapturing: Bool = {
            tapLock.lock()
            defer { tapLock.unlock() }
            let prev = isTapCapturing
            isTapCapturing = false
            firstBufferNotified = false
            activeRecognitionRequest = nil
            activeIsDualMode = false
            activeHelperStdinPipe = nil
            return prev
        }()

        if isRunning || wasCapturing || audioEngine != nil || recognitionRequest != nil || helperProcess != nil {
            // 1. オーディオ入力の完全停止とタップ解除（非録音時はマイクを完全にOFFにする）
            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine = nil

            // 2. 音声認識タスク・ヘルパープロセスの終了
            cleanupRecognitionTasksOnly()

            isRunning = false
            hasReceivedFirstBuffer = false
            isDualMode = false
            latestJaText = ""
            latestEnText = ""
            onTextUpdate = nil
            NSLog("[VoiceIME] ⏹️ リアルタイム音声認識エンジン完全停止 (マイク解放完了)")
        }
    }

    /// リアルタイム表示用の句読点補完と辞書置換
    nonisolated public static func formatLivePunctuation(text: String, isJapanese: Bool) -> String {
        return PunctuationService.shared.format(text: text, isJapanese: isJapanese)
    }
}
