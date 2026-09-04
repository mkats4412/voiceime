import Foundation
import Security

public enum APIProvider: String, CaseIterable, Identifiable {
    case groq = "groq"
    case openai = "openai"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        }
    }

    public var accountKey: String {
        switch self {
        case .groq: return "voiceime_groq_api_key"
        case .openai: return "voiceime_openai_api_key"
        }
    }
}

public final class KeychainService {
    public static let shared = KeychainService()

    private let service: String
    private let legacyAccount = "openai_compatible_api_key"
    private var memoryCache: [APIProvider: String] = [:]

    public init(service: String = "com.voiceime.mac.apikey") {
        self.service = service
    }

    /// アプリ起動時に登録済みAPIキーをKeychainから事前読み込み
    /// これにより、macOSのKeychain認証ダイアログ（初回アクセス許可）をアプリ起動時に表示・解決させ、
    /// 音声入力中の画面ダイアログによる割り込みや待機遅延を防止します。
    public func warmUp() {
        for provider in APIProvider.allCases {
            if hasAPIKey(for: provider) {
                _ = loadAPIKey(for: provider)
            }
        }
    }

    /// 指定したプロバイダのAPIキーをKeychainに保存（すでに存在する場合は更新）
    @discardableResult
    public func saveAPIKey(_ key: String, for provider: APIProvider) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.accountKey
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        var success = false
        if status == errSecSuccess {
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
            success = (updateStatus == errSecSuccess)
        } else if status == errSecItemNotFound {
            var newEntry = query
            newEntry[kSecValueData as String] = data
            newEntry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(newEntry as CFDictionary, nil)
            success = (addStatus == errSecSuccess)
        }

        if success {
            memoryCache[provider] = key
        }
        return success
    }

    /// 指定したプロバイダのAPIキーをKeychainから取得
    public func loadAPIKey(for provider: APIProvider) -> String? {
        if let cached = memoryCache[provider] {
            return cached
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.accountKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) {
            memoryCache[provider] = key
            return key
        }

        // OpenAI の場合のみ旧バージョンのキー互換性フォールバック
        if provider == .openai, let legacy = loadLegacyAPIKey() {
            memoryCache[.openai] = legacy
            return legacy
        }
        return nil
    }

    /// 指定したプロバイダのAPIキーをKeychainから削除
    @discardableResult
    public func deleteAPIKey(for provider: APIProvider) -> Bool {
        memoryCache.removeValue(forKey: provider)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.accountKey
        ]

        let status = SecItemDelete(query as CFDictionary)
        if provider == .openai {
            deleteLegacyAPIKey()
        }
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// 指定したプロバイダのAPIキーが登録済みかどうかを判定（機密データの復号を要求しないためパスワードプロンプト不要）
    public func hasAPIKey(for provider: APIProvider) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.accountKey,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            return true
        }

        // OpenAI の場合のみ旧バージョンのキー互換性チェック
        if provider == .openai {
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: legacyAccount,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            return SecItemCopyMatching(legacyQuery as CFDictionary, nil) == errSecSuccess
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
