import Foundation
import Security

public enum APIProvider: String, CaseIterable, Identifiable {
    case groq = "groq"
    case openai = "openai"
    case sarashina = "sarashina"
    case custom = "custom"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        case .sarashina: return "Sarashina"
        case .custom: return "カスタム"
        }
    }

    public var accountKey: String {
        switch self {
        case .groq: return "voiceime_groq_api_key"
        case .openai: return "voiceime_openai_api_key"
        case .sarashina: return "voiceime_sarashina_api_key"
        case .custom: return "voiceime_custom_llm_api_key"
        }
    }

    /// 音声認識（Whisper）に対応しているプロバイダー一覧
    public static var speechProviders: [APIProvider] {
        [.groq, .openai]
    }
}

public final class KeychainService {
    public static let shared = KeychainService()

    private let service: String
    private let legacyAccount = "openai_compatible_api_key"
    private let lock = NSLock()
    private var memoryCache: [APIProvider: String] = [:]

    /// パスワードプロンプト完全回避用のローカルファイルストレージ (~/.voiceime/api_keys.json)
    private var localKeysFileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".voiceime", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        return dir.appendingPathComponent("api_keys.json")
    }

    public init(service: String = "com.voiceime.mac.apikey") {
        self.service = service
    }

    // MARK: - ローカルファイルストレージ (~/.voiceime/api_keys.json) ヘルパー

    private func loadLocalKeys() -> [String: String] {
        guard FileManager.default.fileExists(atPath: localKeysFileURL.path),
              let data = try? Data(contentsOf: localKeysFileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func saveLocalKey(_ key: String, for provider: APIProvider) {
        var dict = loadLocalKeys()
        dict[provider.rawValue] = key
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: localKeysFileURL, options: .atomic)
            // 所有者のみ読み書き可能 (0600) に設定
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localKeysFileURL.path)
        }
    }

    private func deleteLocalKey(for provider: APIProvider) {
        var dict = loadLocalKeys()
        dict.removeValue(forKey: provider.rawValue)
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: localKeysFileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localKeysFileURL.path)
        }
    }

    /// 何らかのAPIキーが登録されているかを判定
    public func hasAnyAPIKey() -> Bool {
        for provider in APIProvider.allCases {
            if hasAPIKey(for: provider) {
                return true
            }
        }
        return false
    }

    /// ウォームアップ処理（以前は起動時にキーチェーンのキーを一斉読取してパスワード画面を誘発していたため、完全廃止）
    public func warmUp() {
        // パスワードプロンプト防止のため、起動時の一斉読み込みは行わない
    }

    /// 指定したプロバイダのAPIキーを保存
    @discardableResult
    public func saveAPIKey(_ key: String, for provider: APIProvider) -> Bool {
        lock.lock()
        memoryCache[provider] = key
        lock.unlock()

        // 1. パスワード不要のローカルファイルに確実に保存 (0600権限)
        saveLocalKey(key, for: provider)

        // 2. キーチェーンにもバックアップ保存（失敗してもローカルに保存されているため成功扱い）
        if let data = key.data(using: .utf8) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: provider.accountKey
            ]
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            if status == errSecSuccess {
                let updateAttributes: [String: Any] = [
                    kSecValueData as String: data
                ]
                _ = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
            } else if status == errSecItemNotFound {
                var newEntry = query
                newEntry[kSecValueData as String] = data
                newEntry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                _ = SecItemAdd(newEntry as CFDictionary, nil)
            }
        }

        return true
    }

    /// 指定したプロバイダのAPIキーを取得
    /// ローカルキャッシュ・ファイル優先で取得するため、キーチェーンパスワードダイアログは一切表示されません
    public func loadAPIKey(for provider: APIProvider) -> String? {
        // 1. メモリキャッシュ
        lock.lock()
        if let cached = memoryCache[provider], !cached.isEmpty {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // 2. ローカルファイル (~/.voiceime/api_keys.json) - パスワードプロンプト0
        let localKeys = loadLocalKeys()
        if let localKey = localKeys[provider.rawValue], !localKey.isEmpty {
            lock.lock()
            memoryCache[provider] = localKey
            lock.unlock()
            return localKey
        }

        // 3. キーチェーンからの移行フォールバック (ローカルファイルにまだ移行されていない場合のみ)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.accountKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty {
            lock.lock()
            memoryCache[provider] = key
            lock.unlock()
            // 次回以降キーチェーンを一切触らないようにローカルへ自動移行
            saveLocalKey(key, for: provider)
            return key
        }

        // OpenAI の場合のみ旧バージョンのキー互換性フォールバック
        if provider == .openai, let legacy = loadLegacyAPIKey(), !legacy.isEmpty {
            lock.lock()
            memoryCache[.openai] = legacy
            lock.unlock()
            saveLocalKey(legacy, for: .openai)
            return legacy
        }

        // Sarashina / Custom 相互フォールバック
        if provider == .sarashina {
            if let customLocal = localKeys[APIProvider.custom.rawValue], !customLocal.isEmpty {
                lock.lock()
                memoryCache[.sarashina] = customLocal
                lock.unlock()
                return customLocal
            }
        } else if provider == .custom {
            if let sarashinaLocal = localKeys[APIProvider.sarashina.rawValue], !sarashinaLocal.isEmpty {
                lock.lock()
                memoryCache[.custom] = sarashinaLocal
                lock.unlock()
                return sarashinaLocal
            }
        }

        return nil
    }

    /// 指定したプロバイダのAPIキーを削除
    @discardableResult
    public func deleteAPIKey(for provider: APIProvider) -> Bool {
        lock.lock()
        memoryCache.removeValue(forKey: provider)
        lock.unlock()

        deleteLocalKey(for: provider)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.accountKey
        ]

        _ = SecItemDelete(query as CFDictionary)
        if provider == .openai {
            deleteLegacyAPIKey()
        }
        return true
    }

    /// 指定したプロバイダのAPIキーが登録済みかどうかを判定
    public func hasAPIKey(for provider: APIProvider) -> Bool {
        // メモリまたはローカルファイルにあれば true (キーチェーンへのアクセス不要)
        lock.lock()
        if memoryCache[provider] != nil {
            lock.unlock()
            return true
        }
        lock.unlock()

        let localKeys = loadLocalKeys()
        if let key = localKeys[provider.rawValue], !key.isEmpty {
            return true
        }

        // Sarashina / Custom 相互フォールバック
        if provider == .sarashina && localKeys[APIProvider.custom.rawValue] != nil {
            return true
        }
        if provider == .custom && localKeys[APIProvider.sarashina.rawValue] != nil {
            return true
        }

        // キーチェーンのメタデータ確認（データ本文は要求しないため通常プロンプト不要）
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.accountKey,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            return true
        }

        return false
    }

    // MARK: - 後方互換性用メソッド

    @discardableResult
    public func saveAPIKey(_ key: String) -> Bool {
        saveAPIKey(key, for: .openai)
    }

    public func loadAPIKey() -> String? {
        loadAPIKey(for: .openai)
    }

    @discardableResult
    public func deleteAPIKey() -> Bool {
        deleteAPIKey(for: .openai)
    }

    public func hasAPIKey() -> Bool {
        hasAPIKey(for: .openai)
    }

    // MARK: - Legacy migration helpers
    private func loadLegacyAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: legacyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteLegacyAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: legacyAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
