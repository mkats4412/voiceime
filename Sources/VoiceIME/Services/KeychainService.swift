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

    public init(service: String = "com.voiceime.mac.apikey") {
        self.service = service
    }

    /// キーチェーン項目に表示される分かりやすい日本語ラベル
    private func itemLabel(for provider: APIProvider) -> String {
        return "VoiceIME (\(provider.displayName) APIキー)"
    }

    /// キーチェーン項目に表示される説明文
    private func itemDescription(for provider: APIProvider) -> String {
        return "VoiceIMEの音声入力および推敲機能に使用する \(provider.displayName) APIキー"
    }

    /// キーチェーン項目に表示されるコメント
    private func itemComment(for provider: APIProvider) -> String {
        return "VoiceIMEが安全にAPIキーを保管・参照するために使用します。Macのログインパスワードを入力して『常に許可』を選択してください。"
    }

    /// キーチェーン認証ダイアログ用の操作プロンプト文
    private func operationPrompt(for provider: APIProvider) -> String {
        return "VoiceIME: 音声入力・推敲機能で使用する \(provider.displayName) APIキーを安全に読み込むため、Macのログインパスワードで許可してください（『常に許可』を選択すると次回以降の入力を省略できます）"
    }

    /// 何らかのAPIキーがKeychainに登録されているかを判定
    public func hasAnyAPIKey() -> Bool {
        for provider in APIProvider.allCases {
            if hasAPIKey(for: provider) {
                return true
            }
        }
        return false
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

        let labelText = itemLabel(for: provider)
        let descText = itemDescription(for: provider)
        let commentText = itemComment(for: provider)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.accountKey
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        var success = false
        if status == errSecSuccess {
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrLabel as String: labelText,
                kSecAttrDescription as String: descText,
                kSecAttrComment as String: commentText
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
            success = (updateStatus == errSecSuccess)
        } else if status == errSecItemNotFound {
            var newEntry = query
            newEntry[kSecValueData as String] = data
            newEntry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            newEntry[kSecAttrLabel as String] = labelText
            newEntry[kSecAttrDescription as String] = descText
            newEntry[kSecAttrComment as String] = commentText
            let addStatus = SecItemAdd(newEntry as CFDictionary, nil)
            success = (addStatus == errSecSuccess)
        }

        if success {
            lock.lock()
            memoryCache[provider] = key
            lock.unlock()
        }
        return success
    }

    /// 指定したプロバイダのAPIキーをKeychainから取得
    public func loadAPIKey(for provider: APIProvider) -> String? {
        lock.lock()
        if let cached = memoryCache[provider] {
            lock.unlock()
            return cached
        }
        lock.unlock()

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
            lock.lock()
            memoryCache[provider] = key
            lock.unlock()
            // 既存キーのラベル・説明属性を最新の分かりやすい日本語にバックグラウンド更新
            let updateAttrs: [String: Any] = [
                kSecAttrLabel as String: itemLabel(for: provider),
                kSecAttrDescription as String: itemDescription(for: provider),
                kSecAttrComment as String: itemComment(for: provider)
            ]
            let baseQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: provider.accountKey
            ]
            _ = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
            return key
        }

        // OpenAI の場合のみ旧バージョンのキー互換性フォールバック
        if provider == .openai, let legacy = loadLegacyAPIKey() {
            lock.lock()
            memoryCache[.openai] = legacy
            lock.unlock()
            return legacy
        }

        // Sarashina の場合、既存のカスタムキー (voiceime_custom_llm_api_key) があればフォールバック
        if provider == .sarashina, let customKey = loadAPIKey(for: .custom), !customKey.isEmpty {
            lock.lock()
            memoryCache[.sarashina] = customKey
            lock.unlock()
            return customKey
        }

        // カスタムの場合、Sarashinaキーがあればフォールバック
        if provider == .custom, let sarashinaKey = loadAPIKey(for: .sarashina), !sarashinaKey.isEmpty {
            lock.lock()
            memoryCache[.custom] = sarashinaKey
            lock.unlock()
            return sarashinaKey
        }

        return nil
    }

    /// 指定したプロバイダのAPIキーをKeychainから削除
    @discardableResult
    public func deleteAPIKey(for provider: APIProvider) -> Bool {
        lock.lock()
        memoryCache.removeValue(forKey: provider)
        lock.unlock()

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

        // Sarashina の場合、カスタムキーの存在もチェック
        if provider == .sarashina {
            let customQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: APIProvider.custom.accountKey,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            return SecItemCopyMatching(customQuery as CFDictionary, nil) == errSecSuccess
        }

        // カスタムの場合、Sarashinaキーの存在もチェック
        if provider == .custom {
            let sarashinaQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: APIProvider.sarashina.accountKey,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            return SecItemCopyMatching(sarashinaQuery as CFDictionary, nil) == errSecSuccess
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
