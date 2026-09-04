import Foundation

@main
struct TestRunner {
    static func main() {
        print("=== Running VoiceIME Tests ===")

        testDictionaryService()
        testKeychainService()
        testLaunchAtLoginService()
        testLLMService()

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

        // 4. デフォルトの改行ルール
        let defaultRules = AppSettings.defaultDictionaryRules
        let out4 = service.apply(text: "おはようございます改行よろしくお願いいたします", rules: defaultRules)
        assert(out4 == "おはようございます\nよろしくお願いいたします", "Default rules replacement failed: got \(out4)")

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

        print("  -> LLMService URL Construction passed!")
    }
}
