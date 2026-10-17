import Foundation
import AVFoundation
import Carbon

@main
struct TestRunner {
    static func main() {
        print("=== Running VoiceIME Tests ===")

        testDictionaryService()
        testSymbolDictionaryRules()
        testVoiceIMEDiskSync()
        testKeychainService()
        testLaunchAtLoginService()
        testLLMService()
        testAudioAnalysisService()
        testFloatingPreviewSettings()
        testLivePunctuationFormatting()
        testDualLiveSpeechRecognition()
        testQuickAskAndPasteShortcuts()

        print("=== All Tests Passed Successfully! ===")
    }

    static func testDualLiveSpeechRecognition() {
        print("[TEST] Dual Live Speech Recognition & Phonetic Transliteration...")

        // 1. カタカナ音訳判定: 英語発話が日本語認識でカタカナになった場合の検知
        assert(LiveSpeechService.isPhoneticEnglishTransliteration("ディド ユー フィニッシュ イット") == true)
        assert(LiveSpeechService.isPhoneticEnglishTransliteration("ハロー ワールド") == true)
        assert(LiveSpeechService.isPhoneticEnglishTransliteration("サンキュー") == true)
        assert(LiveSpeechService.isPhoneticEnglishTransliteration("アイ ハブ ア ペン") == true)

        // 2. 通常の日本語文（漢字・ひらがな含む）は音訳と誤認しないこと
        assert(LiveSpeechService.isPhoneticEnglishTransliteration("本日の作業は完了しました") == false)
        assert(LiveSpeechService.isPhoneticEnglishTransliteration("お疲れ様です") == false)
        assert(LiveSpeechService.isPhoneticEnglishTransliteration("どうでしょうか") == false)
        assert(LiveSpeechService.isPhoneticEnglishTransliteration("こんにちは") == false)
        assert(LiveSpeechService.isPhoneticEnglishTransliteration("ありがとうございます") == false)

        print("  -> Dual Live Speech Recognition passed!")
    }

    static func testSymbolDictionaryRules() {
        print("[TEST] Symbol Dictionary Rules (音声入力用記号置換)...")
        let service = DictionaryService.shared
        let rules = AppSettings.symbolDictionaryRules

        // 1. 丸括弧 ()
        assert(service.apply(text: "ひらきまるかっこテストまるかっことじ", rules: rules) == "(テスト)")
        assert(service.apply(text: "まるかっこhelloまるかっことじ", rules: rules) == "(hello)")
        assert(service.apply(text: "Open parenthesisworldClose parenthesis", rules: rules) == "(world)")
        assert(service.apply(text: "open parenthesistestclose parenthesis", rules: rules) == "(test)")

        // 2. 角括弧 []
        assert(service.apply(text: "ひらきかくかっこ配列かくかっことじ", rules: rules) == "[配列]")
        assert(service.apply(text: "Open bracket0Close bracket", rules: rules) == "[0]")

        // 3. 波括弧 {}
        assert(service.apply(text: "ひらきなみかっこブロックなみかっことじ", rules: rules) == "{ブロック}")
        assert(service.apply(text: "Open bracebodyClose brace", rules: rules) == "{body}")

        // 4. 鍵括弧 「」
        assert(service.apply(text: "ひらきかぎかっこ重要かぎかっことじ", rules: rules) == "「重要」")
        assert(service.apply(text: "かぎかっこ発言かぎかっことじ", rules: rules) == "「発言」")
        assert(service.apply(text: "Open quotespeechClose quote", rules: rules) == "「speech」")

        // 5. ダブルクォート ""
        assert(service.apply(text: "ひらきダブルクォート引用ダブルクォートとじ", rules: rules) == "\"引用\"")
        assert(service.apply(text: "Open double quotetextClose double quote", rules: rules) == "\"text\"")

        // 6. シングルクォート ''
        assert(service.apply(text: "ひらきシングルクォート単語シングルクォートとじ", rules: rules) == "'単語'")
        assert(service.apply(text: "Open single quotecharClose single quote", rules: rules) == "'char'")

        // 7. 感嘆符 (!) / びっくりマーク（勝手に入った「。」「、」を巻き込んで「！」に置換）
        assert(service.apply(text: "頑張ります!。", rules: rules) == "頑張ります！")
        assert(service.apply(text: "頑張ります！。", rules: rules) == "頑張ります！")
        assert(service.apply(text: "頑張ります。！", rules: rules) == "頑張ります！")
        assert(service.apply(text: "頑張ります。びっくりマーク", rules: rules) == "頑張ります！")
        assert(service.apply(text: "頑張ります! 。", rules: rules) == "頑張ります！")

        // 8. 疑問符 (?) / はてなマーク（勝手に入った「。」「、」を巻き込んで「？」に置換）
        assert(service.apply(text: "本当ですか?。", rules: rules) == "本当ですか？")
        assert(service.apply(text: "本当ですか？。", rules: rules) == "本当ですか？")
        assert(service.apply(text: "本当ですか。？", rules: rules) == "本当ですか？")
        assert(service.apply(text: "本当ですか。はてなマーク", rules: rules) == "本当ですか？")

        // 9. 英語の感嘆符 (!) / 疑問符 (?) のピリオド・カンマ巻き込み置換
        assert(service.apply(text: "Great!.", rules: rules) == "Great!")
        assert(service.apply(text: "Great.!", rules: rules) == "Great!")
        assert(service.apply(text: "Thank you. exclamation mark", rules: rules) == "Thank you!")
        assert(service.apply(text: "Really?.", rules: rules) == "Really?")
        assert(service.apply(text: "Really.?", rules: rules) == "Really?")
        assert(service.apply(text: "Are you sure. question mark", rules: rules) == "Are you sure?")

        // 10. 初期ルール (defaultDictionaryRules) に全記号ルールが最初から登録・有効化されていることを検証
        let defaultRules = AppSettings.defaultDictionaryRules
        for symbol in AppSettings.symbolDictionaryRules {
            let found = defaultRules.first(where: { $0.pattern == symbol.pattern })
            assert(found != nil, "Default rules must include symbol pattern: \(symbol.pattern)")
            assert(found!.isEnabled == true, "Symbol rule must be enabled by default: \(symbol.pattern)")
        }

        print("  -> Symbol Dictionary Rules passed!")
    }

    static func testVoiceIMEDiskSync() {
        print("[TEST] VoiceIMEDiskSyncService (~/.voiceime 同期 & JSON復元)...")
        let syncService = VoiceIMEDiskSyncService.shared
        syncService.ensureDirectoryExists()
        assert(FileManager.default.fileExists(atPath: syncService.baseDirectory.path), "Base dir must exist")

        // テストデータ
        let testRules = [
            DictionaryRule(pattern: "テスト置換", replacement: "TestReplace", isRegex: false, isEnabled: true)
        ]
        let testVocab = ["テスト単語A", "テスト単語B"]

        syncService.exportToDisk(rules: testRules, vocabulary: testVocab)
        assert(FileManager.default.fileExists(atPath: syncService.dictionaryFileURL.path), "dictionary.json should exist")
        assert(FileManager.default.fileExists(atPath: syncService.vocabularyFileURL.path), "vocabulary.json should exist")

        // 読み込みテスト
        let loadedRules = syncService.importDictionaryFromDisk()
        assert(loadedRules != nil && loadedRules!.contains(where: { $0.pattern == "テスト置換" }), "Should decode rules from JSON")

        let loadedVocab = syncService.importVocabularyFromDisk()
        assert(loadedVocab != nil && loadedVocab!.contains("テスト単語A"), "Should decode vocab from JSON")

        // AI Agent が手動で ID やオプションを省略した最小限の JSON を書いた場合の互換デコードテスト
        let minimalJSON = """
        [
            {
                "pattern": "AI略称",
                "replacement": "Artificial Intelligence"
            }
        ]
        """.data(using: .utf8)!

        let decodedMinimal = try? JSONDecoder().decode([DictionaryRule].self, from: minimalJSON)
        assert(decodedMinimal != nil && decodedMinimal!.count == 1, "Minimal JSON should decode successfully")
        let firstRule = decodedMinimal!.first!
        assert(firstRule.pattern == "AI略称")
        assert(firstRule.replacement == "Artificial Intelligence")
        assert(firstRule.isEnabled == true, "isEnabled should default to true")
        // 外部リロード通知の送受信テスト
        VoiceIMEDiskSyncService.postReloadNotification()

        print("  -> VoiceIMEDiskSync passed!")
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

        // 4. デフォルトの置換ルール (改行: 有効、郵便番号: チェックオフ無効)
        let defaultRules = AppSettings.defaultDictionaryRules
        let out4 = service.apply(text: "東京都千代田区1000001改行よろしくお願いいたします", rules: defaultRules)
        assert(out4 == "東京都千代田区1000001\nよろしくお願いいたします", "Default rules replacement failed (郵便番号 should be disabled by default): got \(out4)")

        // 郵便番号を有効化した場合のテスト
        let enabledRules = defaultRules.map { rule -> DictionaryRule in
            var r = rule
            if r.pattern.contains("[0-9]{3}") { r.isEnabled = true }
            return r
        }
        let out4Enabled = service.apply(text: "東京都千代田区1000001改行よろしくお願いいたします", rules: enabledRules)
        assert(out4Enabled == "東京都千代田区〒100-0001\nよろしくお願いいたします", "Enabled rule replacement failed: got \(out4Enabled)")

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

        // 5. 口語モード vs 文章モードのプロンプト生成テスト
        let casualPrompt = llm.generateSystemPrompt(style: .casual, promptHint: "用語A, 用語B")
        assert(casualPrompt.contains("口語モード"), "Casual prompt should specify 口語モード")
        assert(casualPrompt.contains("文体（常体・敬体）および時制の完全維持"), "Casual prompt must contain style/tense rule")
        assert(casualPrompt.contains("語尾・終助詞・口語ニュアンスの完全維持"), "Casual prompt must contain trailing particle preservation rule")
        assert(casualPrompt.contains("言及した"), "Casual prompt must mention 言及した example")
        assert(casualPrompt.contains("〇〇でありませんね"), "Casual prompt should include explicit negative example")
        assert(casualPrompt.contains("言語と約物の整合性"), "Casual prompt should include language punctuation rule")
        assert(casualPrompt.contains("用語A, 用語B"), "Casual prompt should contain prompt hint")

        let formalPrompt = llm.generateSystemPrompt(style: .formal, promptHint: nil)
        assert(formalPrompt.contains("文章モード"), "Formal prompt should specify 文章モード")
        assert(formalPrompt.contains("文体（常体・敬体）および時制の完全維持"), "Formal prompt must contain style/tense rule")
        assert(formalPrompt.contains("勝手な言い換え・語句改変の厳禁"), "Formal prompt must prohibit paraphrasing")
        assert(formalPrompt.contains("入力文末・語尾の完全保持"), "Formal prompt must contain ending preservation rule")
        assert(formalPrompt.contains("端正な書き言葉への推敲"), "Formal prompt should specify formal rewriting")
        assert(formalPrompt.contains("言語と約物の整合性"), "Formal prompt should include language punctuation rule")

        // 6. 英文句読点の正規化テスト (英語で入力した際に末尾が「。」でなく「.」になること等の検証)
        let enOut1 = LLMService.normalizePunctuation(for: "This is a test。")
        assert(enOut1 == "This is a test.", "English trailing period normalization failed: got '\(enOut1)'")

        let enOut2 = LLMService.normalizePunctuation(for: "How are you doing？")
        assert(enOut2 == "How are you doing?", "English trailing question mark normalization failed: got '\(enOut2)'")

        let enOut3 = LLMService.normalizePunctuation(for: "Hello world、how is it going。")
        assert(enOut3 == "Hello world, how is it going.", "English comma and period normalization failed: got '\(enOut3)'")

        let enOut4 = LLMService.normalizePunctuation(for: "Great job！")
        assert(enOut4 == "Great job!", "English exclamation mark normalization failed: got '\(enOut4)'")

        let enOut5 = llm.sanitizeLLMOutput("整形後：Thank you very much。", fallback: "fallback")
        assert(enOut5 == "Thank you very much.", "LLM output sanitize with English trailing period failed: got '\(enOut5)'")

        // 日本語文が維持されることの確認
        let jaOut1 = LLMService.normalizePunctuation(for: "明日の打ち合わせは10時からです。")
        assert(jaOut1 == "明日の打ち合わせは10時からです。", "Japanese trailing period should be preserved: got '\(jaOut1)'")

        let jaOut2 = LLMService.normalizePunctuation(for: "おすすめのPCはMacです。")
        assert(jaOut2 == "おすすめのPCはMacです。", "Japanese text with English word should preserve Japanese period: got '\(jaOut2)'")

        // 最後の文が英語の節で終わる場合の救済確認
        let mixedOut = LLMService.normalizePunctuation(for: "メモを作成しました。\nThank you for your help。")
        assert(mixedOut == "メモを作成しました。\nThank you for your help.", "Trailing English clause should have period normalized: got '\(mixedOut)'")

        // 7. AppSettings refinementStyle テスト
        let settings = AppSettings.shared
        let originalStyle = settings.refinementStyle
        settings.refinementStyle = .formal
        assert(settings.refinementStyle == .formal, "RefinementStyle should be formal")
        settings.refinementStyle = .casual
        assert(settings.refinementStyle == .casual, "RefinementStyle should be casual")
        settings.refinementStyle = originalStyle

        // 8. カスタムLLM URL 構築テスト (Ollama, LM Studio 等)
        let ollamaURL = llm.constructChatURL(from: "http://localhost:11434/v1")
        assert(ollamaURL?.absoluteString == "http://localhost:11434/v1/chat/completions",
               "Ollama custom URL mismatch: \(String(describing: ollamaURL))")

        let lmStudioURL = llm.constructChatURL(from: "http://localhost:1234/v1/")
        assert(lmStudioURL?.absoluteString == "http://localhost:1234/v1/chat/completions",
               "LM Studio custom URL mismatch: \(String(describing: lmStudioURL))")

        // 9. LLMProviderMode および effectiveLLMConfig 切り離し動作テスト
        let originalLLMMode = settings.llmProviderMode
        let originalSelectedProvider = settings.selectedProvider

        settings.selectedProvider = .groq
        settings.llmProviderMode = .sameAsSpeech
        assert(settings.resolvedLLMProvider == .groq, "resolvedLLMProvider should match selectedProvider when sameAsSpeech")
        assert(settings.effectiveLLMConfig.isCustom == false, "isCustom should be false for sameAsSpeech")
        assert(settings.effectiveLLMConfig.modelName == settings.groqLLMModel, "modelName should match groqLLMModel")

        settings.llmProviderMode = .openai
        assert(settings.resolvedLLMProvider == .openai, "resolvedLLMProvider should be openai")
        assert(settings.effectiveLLMConfig.isCustom == false, "isCustom should be false for openai")
        assert(settings.effectiveLLMConfig.modelName == settings.openAILLMModel, "modelName should match openAILLMModel")

        settings.llmProviderMode = .custom
        assert(settings.resolvedLLMProvider == .custom, "resolvedLLMProvider should be custom")
        assert(settings.effectiveLLMConfig.isCustom == true, "isCustom should be true for custom")
        assert(settings.effectiveLLMConfig.baseURL == settings.customLLMBaseURL, "baseURL should match customLLMBaseURL")
        assert(settings.effectiveLLMConfig.modelName == settings.customLLMModel, "modelName should match customLLMModel")

        // 状態復元
        settings.llmProviderMode = originalLLMMode
        settings.selectedProvider = originalSelectedProvider

        print("  -> LLMService URL Construction, Sanitization, Punctuation Normalization, Prompt Modes, and LLMProviderMode passed!")
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

    @MainActor
    static func testFloatingPreviewSettings() {
        print("[TEST] FloatingPreview Settings & Confirmed Text Sync...")
        let settings = AppSettings.shared

        // 初期値・型チェック
        assert(settings.floatingPreviewEnabled == true, "floatingPreviewEnabled should default to true")
        assert(settings.autoPasteEnabled == true, "autoPasteEnabled should default to true")
        assert(settings.floatingPreviewDuration >= 30.0, "floatingPreviewDuration should be positive default")

        // 変更と復元のテスト
        let origFloating = settings.floatingPreviewEnabled
        let origAuto = settings.autoPasteEnabled
        let origDuration = settings.floatingPreviewDuration

        settings.floatingPreviewEnabled = false
        assert(!settings.floatingPreviewEnabled, "floatingPreviewEnabled should update to false")

        settings.autoPasteEnabled = false
        assert(!settings.autoPasteEnabled, "autoPasteEnabled should update to false")

        settings.floatingPreviewDuration = 60.0
        assert(settings.floatingPreviewDuration == 60.0, "floatingPreviewDuration should update to 60.0")

        // 元に戻す
        settings.floatingPreviewEnabled = origFloating
        settings.autoPasteEnabled = origAuto
        settings.floatingPreviewDuration = origDuration

        // ウィンドウ確定テキスト同期の検証:
        // 録音中（カタカナ表示）から処理中（processing）を経て確定テキスト（英語）が届いた時、
        // プレビューウィンドウの currentText が確実に確定成果物（did you finish it?）と一致すること
        let controller = FloatingPreviewController.shared
        controller.showLiveRecording()
        controller.updateLiveText("ディド ユー フィニッシュ イット")
        assert(controller.currentText == "ディド ユー フィニッシュ イット")

        controller.setProcessing()
        assert(controller.phase == .processing)

        // updateLiveText は processing 中は無視される仕様であること
        controller.updateLiveText("無視されるテキスト")
        assert(controller.currentText == "ディド ユー フィニッシュ イット")

        // updateConfirmedText は processing 中でも確実に確定テキストに同期すること
        controller.updateConfirmedText("did you finish it?")
        assert(controller.currentText == "did you finish it?", "Confirmed text must match final artifact exactly")
        assert(controller.phase == .ready, "Phase must become .ready upon confirmed text sync")

        controller.hide()

        print("  -> FloatingPreview Settings & Confirmed Text Sync passed!")
    }

    static func testLivePunctuationFormatting() {
        print("[TEST] Live Punctuation Formatting & PunctuationService...")

        // 1. 文末表現の直後および末尾（$）が句点「。」に変換されること
        let in1 = "本日の作業は完了しました 明日もよろしくお願いします"
        let out1 = LiveSpeechService.formatLivePunctuation(text: in1, isJapanese: true)
        assert(out1 == "本日の作業は完了しました。明日もよろしくお願いします。", "Sentence ending replacement failed: got \(out1)")

        // 2. 接続詞後の空白が読点「、」に変換されること
        let in2 = "ですが 次のタスクに移ります"
        let out2 = LiveSpeechService.formatLivePunctuation(text: in2, isJapanese: true)
        assert(out2 == "ですが、次のタスクに移ります。", "Clause ending replacement failed: got \(out2)")

        // 3. 挨拶表現が読点「、」になり、末尾句点が付与されること
        let in3 = "こんにちは 明日の件ですが よろしくお願いします"
        let out3 = LiveSpeechService.formatLivePunctuation(text: in3, isJapanese: true)
        assert(out3 == "こんにちは、明日の件ですが、よろしくお願いします。", "Greeting and clause replacement failed: got \(out3)")

        // 4. 疑問文末尾が「？」になること
        let in4 = "明日の予定はいかがでしょうか"
        let out4 = LiveSpeechService.formatLivePunctuation(text: in4, isJapanese: true)
        assert(out4 == "明日の予定はいかがでしょうか？", "Question ending failed: got \(out4)")

        // 5. 辞書ルール（改行）が適用されること
        let in5 = "こんにちは改行お元気ですか"
        let out5 = LiveSpeechService.formatLivePunctuation(text: in5, isJapanese: true)
        assert(out5 == "こんにちは\nお元気ですか？", "Dictionary rule in live formatting failed: got \(out5)")

        // 6. PunctuationService.alignPunctuation によるプレビューとの厳格同期
        let liveRef = "本日の作業は完了しました。明日もよろしくお願いします。"
        let whisperOutput = "本日の作業は完了しました 明日もよろしくお願いします" // 句読点がないWhisper出力
        let aligned = PunctuationService.shared.alignPunctuation(
            text: whisperOutput,
            referenceLiveText: liveRef,
            isJapanese: true
        )
        assert(aligned == liveRef, "Align punctuation failed: got \(aligned), expected \(liveRef)")

        // 7. 「〜ですよね」の分断防止および「〜です。よね」の自動修復テスト
        let inYone1 = "まだ少し問題があるんですよね"
        let outYone1 = PunctuationService.shared.format(text: inYone1, isJapanese: true)
        assert(outYone1 == "まだ少し問題があるんですよね。", "Compound ending failed: got \(outYone1)")

        let inYone2 = "まだ少し問題があるんです。よね" // 誤って分断されたケースの修復
        let outYone2 = PunctuationService.shared.format(text: inYone2, isJapanese: true)
        assert(outYone2 == "まだ少し問題があるんですよね。", "Broken particle repair failed: got \(outYone2)")

        let inYone3 = "まだ少し問題があるんです よね" // 空白で分断されたケースの修復
        let outYone3 = PunctuationService.shared.format(text: inYone3, isJapanese: true)
        assert(outYone3 == "まだ少し問題があるんですよね。", "Space separated particle repair failed: got \(outYone3)")

        let inYone4 = "そうですよね 明日確認します"
        let outYone4 = PunctuationService.shared.format(text: inYone4, isJapanese: true)
        assert(outYone4 == "そうですよね。明日確認します。", "Sentence ending with next clause failed: got \(outYone4)")

        // 8. 「どうでしょうかねぇ」等の疑問文末終助詞の結合＆分断修復テスト
        let inQ1 = "どうでしょうかねぇ"
        let outQ1 = PunctuationService.shared.format(text: inQ1, isJapanese: true)
        assert(outQ1 == "どうでしょうかねぇ？", "Question with particle ending failed: got \(outQ1)")

        let inQ2 = "どうでしょうか？ねぇ" // 途中で誤って分断されたケースの修復
        let outQ2 = PunctuationService.shared.format(text: inQ2, isJapanese: true)
        assert(outQ2 == "どうでしょうかねぇ？", "Broken question particle repair failed: got \(outQ2)")

        let inQ3 = "どうでしょうか？ね？" // 途中で二重に？が入ったケースの修復
        let outQ3 = PunctuationService.shared.format(text: inQ3, isJapanese: true)
        assert(outQ3 == "どうでしょうかね？", "Double question particle repair failed: got \(outQ3)")

        print("  -> Live Punctuation Formatting & PunctuationService passed!")
    }

    static func testQuickAskAndPasteShortcuts() {
        print("[TEST] Quick Ask & Paste Shortcuts...")

        // 1. AppSettings のデフォルト値検証
        let settings = AppSettings.shared
        assert(settings.quickAskHotkeyCode == 49, "Default quickAskHotkeyCode should be Space (49)")
        assert(settings.quickAskHotkeyModifiers == UInt32(controlKey | shiftKey), "Default quickAskHotkeyModifiers should be Ctrl+Shift (4608)")
        assert(settings.quickAskHotkeyDisplayString == "⌃⇧Space", "Default quickAskHotkeyDisplayString should be ⌃⇧Space")

        assert(settings.pasteShortcutKeyCode == 36, "Default pasteShortcutKeyCode should be Return (36)")
        assert(settings.pasteShortcutModifiers == UInt32(cmdKey), "Default pasteShortcutModifiers should be Command (256)")
        assert(settings.pasteShortcutDisplayString == "⌘↩", "Default pasteShortcutDisplayString should be ⌘↩")

        // 会話モデル（クイック質問）のプロバイダー設定
        assert(settings.quickAskProviderMode == .sameAsLLM, "Default quickAskProviderMode should be sameAsLLM")
        assert(settings.groqQuickAskModel == "llama-3.3-70b-versatile", "Default groqQuickAskModel")
        assert(settings.openAIQuickAskModel == "gpt-4o-mini", "Default openAIQuickAskModel")
        assert(settings.customQuickAskModel == "llama3.2", "Default customQuickAskModel")

        // sameAsLLM のときの有効設定
        let cfgLLM = settings.effectiveQuickAskConfig
        assert(cfgLLM.modelName == settings.currentLLMModelName, "sameAsLLM should match currentLLMModelName")

        // groq モードに切り替えた場合の有効設定
        settings.quickAskProviderMode = .groq
        assert(settings.effectiveQuickAskConfig.modelName == "llama-3.3-70b-versatile")
        assert(settings.effectiveQuickAskConfig.provider == .groq)

        // openai モードに切り替えた場合の有効設定
        settings.quickAskProviderMode = .openai
        assert(settings.effectiveQuickAskConfig.modelName == "gpt-4o-mini")
        assert(settings.effectiveQuickAskConfig.provider == .openai)

        // custom モードに切り替えた場合の有効設定
        settings.quickAskProviderMode = .custom
        assert(settings.effectiveQuickAskConfig.modelName == "llama3.2")
        assert(settings.effectiveQuickAskConfig.isCustom == true)

        // 状態復元
        settings.quickAskProviderMode = .sameAsLLM

        // 2. LLMService のクイック質問出力サニタイズ検証
        let llm = LLMService.shared
        // 不要なラベルの除去
        assert(llm.sanitizeQuickAskOutput("答え：trash") == "trash", "Prefix removal failed")
        assert(llm.sanitizeQuickAskOutput("回答: 4") == "4", "Prefix removal failed")
        assert(llm.sanitizeQuickAskOutput("Answer: Paris") == "Paris", "Prefix removal failed")

        // 不要な丁寧語語尾（〜です、〜になります等）の除去
        assert(llm.sanitizeQuickAskOutput("trashです。") == "trash", "Polite ending removal failed")
        assert(llm.sanitizeQuickAskOutput("trashです") == "trash", "Polite ending removal failed")
        assert(llm.sanitizeQuickAskOutput("4になります。") == "4", "Polite ending removal failed")

        // 引用符の除去
        assert(llm.sanitizeQuickAskOutput("「trash」") == "trash", "Quotes removal failed")
        assert(llm.sanitizeQuickAskOutput("\"Paris\"") == "Paris", "Double quotes removal failed")

        // 空白または答えなし
        assert(llm.sanitizeQuickAskOutput("") == "[答えを持っていません。]", "Empty output fallback failed")
        assert(llm.sanitizeQuickAskOutput("   ") == "[答えを持っていません。]", "Whitespace output fallback failed")

        print("  -> Quick Ask & Paste Shortcuts passed!")
    }
}

