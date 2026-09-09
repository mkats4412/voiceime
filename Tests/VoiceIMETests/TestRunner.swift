import Foundation
import AVFoundation

@main
struct TestRunner {
    static func main() {
        print("=== Running VoiceIME Tests ===")

        testDictionaryService()
        testKeychainService()
        testLaunchAtLoginService()
        testLLMService()
        testAudioAnalysisService()

        print("=== All Tests Passed Successfully! ===")
    }

    static func testDictionaryService() {
        print("[TEST] DictionaryService...")
        let service = DictionaryService.shared

        // 1. プレーン置換
        let rules1 = [
            DictionaryRule(pattern: "改行", replacement: "\\n", isRegex: false, isEnabled: true),
            DictionaryRule(pattern: "株式会社テスト", replacement: "Test Corp.", isRegex: false, isEnabled: true)
        ]
        let out1 = service.apply(text: "こんにちは改行株式会社テストです", rules: rules1)
        assert(out1 == "こんにちは\nTest Corp.です", "Plain replacement failed: got \(out1)")

        // 2. 無効ルール
        let rules2 = [
            DictionaryRule(pattern: "テスト", replacement: "本番", isRegex: false, isEnabled: false)
        ]
        let out2 = service.apply(text: "これはテストです", rules: rules2)
        assert(out2 == "これはテストです", "Disabled rule test failed: got \(out2)")

        // 3. 正規表現置換
        let rules3 = [
            DictionaryRule(pattern: "([0-9]+)円", replacement: "¥$1", isRegex: true, isEnabled: true)
        ]
        let out3 = service.apply(text: "お会計は500円と1200円です", rules: rules3)
        assert(out3 == "お会計は¥500と¥1200です", "Regex test failed: got \(out3)")

        // 4. デフォルトの置換ルール (改行、Apple macOS、Microsoft Windows)
        let defaultRules = AppSettings.defaultDictionaryRules
        let out4 = service.apply(text: "マックとウインドウズを使って開発します改行よろしくお願いいたします", rules: defaultRules)
        assert(out4 == "Apple macOSとMicrosoft Windowsを使って開発します\nよろしくお願いいたします", "Default rules replacement failed: got \(out4)")

        // 5. 単語登録（customVocabulary）とプロンプトヒントの連動テスト
        let settings = AppSettings.shared
        let originalVocab = settings.customVocabulary
        settings.clearVocabulary()
        assert(settings.customVocabulary.isEmpty, "Vocabulary should be empty")

        settings.addVocabularyWord("VoiceIME")
        settings.addVocabularyWord("Kubernetes, 齋藤\nDocker")
        assert(settings.customVocabulary.contains("VoiceIME"), "Should contain VoiceIME")
        assert(settings.customVocabulary.contains("Kubernetes"), "Should contain Kubernetes")
        assert(settings.customVocabulary.contains("齋藤"), "Should contain 齋藤")
        assert(settings.customVocabulary.contains("Docker"), "Should contain Docker")
        assert(settings.promptHint.contains("VoiceIME"), "promptHint should synchronize with vocabulary")

        settings.removeVocabularyWord("Kubernetes")
        assert(!settings.customVocabulary.contains("Kubernetes"), "Should not contain Kubernetes after removal")

        // 状態復元
        settings.customVocabulary = originalVocab

        print("  -> DictionaryService passed!")
    }

    static func testKeychainService() {
        print("[TEST] KeychainService (isolated test service)...")
        let keychain = KeychainService(service: "com.voiceime.test.apikey")
        let testKey = "sk-test-key-\(UUID().uuidString)"

        // 1. 保存
        assert(keychain.saveAPIKey(testKey), "Keychain save failed")
        assert(keychain.hasAPIKey(), "hasAPIKey should be true")

        // 2. 取得
        let loaded = keychain.loadAPIKey()
        assert(loaded == testKey, "Loaded key doesn't match: \(String(describing: loaded))")

        // 3. 更新
        let updatedKey = "sk-updated-key-\(UUID().uuidString)"
        assert(keychain.saveAPIKey(updatedKey), "Keychain update failed")
        assert(keychain.loadAPIKey() == updatedKey, "Updated key doesn't match")

        // 4. 削除
        assert(keychain.deleteAPIKey(), "Keychain delete failed")
        assert(!keychain.hasAPIKey(), "hasAPIKey should be false after delete")

        // 5. プロバイダ別（Groq と OpenAI）の個別保存・独立性テスト
        let groqKey = "gsk_test_\(UUID().uuidString)"
        let openAIKey = "sk_test_\(UUID().uuidString)"

        assert(keychain.saveAPIKey(groqKey, for: .groq), "Save Groq key failed")
        assert(keychain.saveAPIKey(openAIKey, for: .openai), "Save OpenAI key failed")

        assert(keychain.loadAPIKey(for: .groq) == groqKey, "Groq key mismatch")
        assert(keychain.loadAPIKey(for: .openai) == openAIKey, "OpenAI key mismatch")

        assert(keychain.hasAPIKey(for: .groq), "hasAPIKey for groq should be true")
        assert(keychain.hasAPIKey(for: .openai), "hasAPIKey for openai should be true")

        // Groqキーだけ削除してもOpenAIキーは残る
        assert(keychain.deleteAPIKey(for: .groq), "Delete Groq key failed")
        assert(!keychain.hasAPIKey(for: .groq), "Groq key should be deleted")
        assert(keychain.hasAPIKey(for: .openai), "OpenAI key should still exist")

        keychain.deleteAPIKey(for: .openai)

        print("  -> KeychainService passed!")
    }

    @MainActor
    static func testLaunchAtLoginService() {
        print("[TEST] LaunchAtLoginService...")
        let service = LaunchAtLoginService.shared
        service.refresh()
        assert(service.statusMessage != "", "Status message should not be empty")
        print("  -> LaunchAtLoginService passed! (status: \(service.statusMessage))")
    }

    static func testLLMService() {
        print("[TEST] LLMService URL Construction...")
        let llm = LLMService.shared

        // 1. Groq URL
        let groqURL = llm.constructChatURL(from: "https://api.groq.com/openai/v1")
        assert(groqURL?.absoluteString == "https://api.groq.com/openai/v1/chat/completions",
               "Groq URL mismatch: \(String(describing: groqURL))")

        // 2. OpenAI URL
        let openAIURL = llm.constructChatURL(from: "https://api.openai.com/v1")
        assert(openAIURL?.absoluteString == "https://api.openai.com/v1/chat/completions",
               "OpenAI URL mismatch: \(String(describing: openAIURL))")

        // 3. 末尾スラッシュ・末尾パス付きURLの正規化
        let trailingSlashURL = llm.constructChatURL(from: "https://api.groq.com/openai/v1/")
        assert(trailingSlashURL?.absoluteString == "https://api.groq.com/openai/v1/chat/completions",
               "Trailing slash URL mismatch: \(String(describing: trailingSlashURL))")

        let fullEndpointURL = llm.constructChatURL(from: "https://api.groq.com/openai/v1/chat/completions")
        assert(fullEndpointURL?.absoluteString == "https://api.groq.com/openai/v1/chat/completions",
               "Full endpoint URL mismatch: \(String(describing: fullEndpointURL))")

        // 4. sanitizeLLMOutput のテスト（前置きラベルや引用符の除去）
        let out1 = llm.sanitizeLLMOutput("整形後：こんにちは、明日の天気はどうですか？", fallback: "元の文")
        assert(out1 == "こんにちは、明日の天気はどうですか？", "Prefix removal failed: \(out1)")

        let out2 = llm.sanitizeLLMOutput("「テストの文章です。」", fallback: "元の文")
        assert(out2 == "テストの文章です。", "Bracket removal failed: \(out2)")

        let out3 = llm.sanitizeLLMOutput("   \n\n  ", fallback: "フォールバック")
        assert(out3 == "フォールバック", "Empty fallback failed: \(out3)")

        print("  -> LLMService URL Construction and Sanitization passed!")
    }

    static func testAudioAnalysisService() {
        print("[TEST] AudioAnalysisService...")
        let service = AudioAnalysisService.shared
        let settings = AppSettings.shared

        // 1. AppSettings デフォルト値確認
        assert(settings.audioThresholdEnabled == true, "audioThresholdEnabled should be true by default")
        assert(settings.audioThresholdDB == -32.0, "audioThresholdDB should be -32.0 by default")
        assert(settings.audioTrimmingEnabled == true, "audioTrimmingEnabled should be true by default")

        let tempDir = FileManager.default.temporaryDirectory
        let silenceURL = tempDir.appendingPathComponent("test_silence_\(UUID().uuidString).m4a")
        let speechURL = tempDir.appendingPathComponent("test_speech_\(UUID().uuidString).m4a")

        let audioSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        defer {
            try? FileManager.default.removeItem(at: silenceURL)
            try? FileManager.default.removeItem(at: speechURL)
        }

        // 2. 微小音／環境音のみのファイル生成 (振幅 0.001 = 約 -60dB)
        do {
            let file = try AVAudioFile(forWriting: silenceURL, settings: audioSettings)
            let pcmFormat = file.processingFormat
            let frameCount: AVAudioFrameCount = 16000 // 1.0秒
            let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount)!
            buffer.frameLength = frameCount
            for i in 0..<Int(frameCount) {
                buffer.floatChannelData![0][i] = 0.001 * sin(Float(i) * 0.1)
            }
            try file.write(from: buffer)
        } catch {
            assertionFailure("Failed to write silence test audio: \(error)")
        }

        // 小さな音の判定テスト: hasSpeech が false になること
        let silenceMetrics = service.analyze(audioFileURL: silenceURL, thresholdDB: -32.0)
        assert(!silenceMetrics.hasSpeech, "Silence/small sound should NOT be recognized as speech! Got maxRMS=\(silenceMetrics.maxWindowRMS_DB)dB")
        assert(silenceMetrics.maxWindowRMS_DB < -32.0, "Silence RMS should be below -32dB")
        print("  -> Small sound rejection passed: maxRMS=\(String(format: "%.1f", silenceMetrics.maxWindowRMS_DB))dB < -32.0dB")

        // 3. 発話音声を含むファイル生成 (無音 0.4s + 音声 0.8s (振幅 0.1 = 約 -20dB) + 無音 0.4s)
        do {
            let file = try AVAudioFile(forWriting: speechURL, settings: audioSettings)
            let pcmFormat = file.processingFormat
            let frameCount: AVAudioFrameCount = 25600 // 1.6秒
            let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount)!
            buffer.frameLength = frameCount
            for i in 0..<Int(frameCount) {
                if i >= 6400 && i < 19200 {
                    // 発話シミュレーション（-20dB）
                    buffer.floatChannelData![0][i] = 0.1 * sin(Float(i) * 0.1)
                } else {
                    // 無音・キー打鍵音
                    buffer.floatChannelData![0][i] = 0.001
                }
            }
            try file.write(from: buffer)
        } catch {
            assertionFailure("Failed to write speech test audio: \(error)")
        }

        // 音声の判定テスト: hasSpeech が true になること
        let speechMetrics = service.analyze(audioFileURL: speechURL, thresholdDB: -32.0)
        assert(speechMetrics.hasSpeech, "Simulated speech should be recognized as speech!")
        assert(speechMetrics.maxWindowRMS_DB >= -32.0, "Speech RMS should be >= -32dB")
        print("  -> Speech detection passed: maxRMS=\(String(format: "%.1f", speechMetrics.maxWindowRMS_DB))dB >= -32.0dB")

        // 4. トリミングテスト: 発話前後の不要な微小音区間がトリミングされること
        if let trimmedURL = service.trimLeadingTrailingNoise(audioFileURL: speechURL, thresholdDB: -32.0) {
            defer { try? FileManager.default.removeItem(at: trimmedURL) }
            if let trimmedFile = try? AVAudioFile(forReading: trimmedURL) {
                let trimmedDuration = Double(trimmedFile.length) / trimmedFile.processingFormat.sampleRate
                assert(trimmedDuration < speechMetrics.totalDurationSeconds, "Trimmed duration should be shorter than original")
                print("  -> Noise trimming passed: original=\(String(format: "%.2f", speechMetrics.totalDurationSeconds))s -> trimmed=\(String(format: "%.2f", trimmedDuration))s")
            } else {
                assertionFailure("Failed to read trimmed file")
            }
        } else {
            assertionFailure("Trimming should succeed on padded audio")
        }

        print("  -> AudioAnalysisService passed!")
    }
}
