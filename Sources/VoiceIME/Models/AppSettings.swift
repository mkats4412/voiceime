import Foundation
import Carbon

public enum SpeechAPIMode: String, CaseIterable, Identifiable {
    case transcriptions = "transcriptions"
    case translations = "translations"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .transcriptions: return "文字起こし (話した言語のまま)"
        case .translations: return "英語翻訳 (音声を英語に自動翻訳)"
        }
    }
}

public enum TriggerMode: String, CaseIterable, Identifiable {
    case pushToTalk = "pushToTalk"
    case toggle = "toggle"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pushToTalk: return "キーを押している間だけ入力 (離すと自動出力)"
        case .toggle: return "1回押して録音開始、もう1回で停止・出力"
        }
    }
}

public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    private enum Keys {
        static let selectedProvider = "voiceime_selectedProvider"

        // Groq 設定
        static let groqBaseURL = "voiceime_groq_baseURL"
        static let groqModel = "voiceime_groq_model"
        static let groqLLMModel = "voiceime_groq_llm_model"

        // OpenAI 設定
        static let openAIBaseURL = "voiceime_openai_baseURL"
        static let openAIModel = "voiceime_openai_model"
        static let openAILLMModel = "voiceime_openai_llm_model"

        // 共通設定
        static let apiMode = "voiceime_apiMode"
        static let triggerMode = "voiceime_triggerMode"
        static let autoFallbackEnabled = "voiceime_autoFallbackEnabled"
        static let llmRefinementEnabled = "voiceime_llmRefinementEnabled"
        static let promptHint = "voiceime_promptHint"
        static let language = "voiceime_language"
        static let restoreClipboard = "voiceime_restoreClipboard"
        static let hotkeyCode = "voiceime_hotkeyCode"
        static let hotkeyModifiers = "voiceime_hotkeyModifiers"
        static let hotkeyDisplayString = "voiceime_hotkeyDisplayString"
        static let dictionaryRules = "voiceime_dictionaryRules"
    }

    private let defaults = UserDefaults.standard

    // MARK: - プロバイダー別設定 (Whisper & LLM)

    @Published public var selectedProvider: APIProvider {
        didSet { defaults.set(selectedProvider.rawValue, forKey: Keys.selectedProvider) }
    }

    @Published public var groqBaseURL: String {
        didSet { defaults.set(groqBaseURL, forKey: Keys.groqBaseURL) }
    }

    @Published public var groqModel: String {
        didSet { defaults.set(groqModel, forKey: Keys.groqModel) }
    }

    @Published public var groqLLMModel: String {
        didSet { defaults.set(groqLLMModel, forKey: Keys.groqLLMModel) }
    }

    @Published public var openAIBaseURL: String {
        didSet { defaults.set(openAIBaseURL, forKey: Keys.openAIBaseURL) }
    }

    @Published public var openAIModel: String {
        didSet { defaults.set(openAIModel, forKey: Keys.openAIModel) }
    }

    @Published public var openAILLMModel: String {
        didSet { defaults.set(openAILLMModel, forKey: Keys.openAILLMModel) }
    }

    // MARK: - 共通動作設定

    @Published public var apiMode: SpeechAPIMode {
        didSet { defaults.set(apiMode.rawValue, forKey: Keys.apiMode) }
    }

    @Published public var triggerMode: TriggerMode {
        didSet { defaults.set(triggerMode.rawValue, forKey: Keys.triggerMode) }
    }

    @Published public var autoFallbackEnabled: Bool {
        didSet { defaults.set(autoFallbackEnabled, forKey: Keys.autoFallbackEnabled) }
    }

    /// AI（LLM）による文脈理解・句読点・推敲の有効化フラグ
    @Published public var llmRefinementEnabled: Bool {
        didSet { defaults.set(llmRefinementEnabled, forKey: Keys.llmRefinementEnabled) }
    }

    @Published public var promptHint: String {
        didSet { defaults.set(promptHint, forKey: Keys.promptHint) }
    }

    @Published public var language: String {
        didSet { defaults.set(language, forKey: Keys.language) }
    }

    @Published public var restoreClipboard: Bool {
        didSet { defaults.set(restoreClipboard, forKey: Keys.restoreClipboard) }
    }

    @Published public var hotkeyCode: UInt32 {
        didSet { defaults.set(hotkeyCode, forKey: Keys.hotkeyCode) }
    }

    @Published public var hotkeyModifiers: UInt32 {
        didSet { defaults.set(hotkeyModifiers, forKey: Keys.hotkeyModifiers) }
    }

    @Published public var hotkeyDisplayString: String {
        didSet { defaults.set(hotkeyDisplayString, forKey: Keys.hotkeyDisplayString) }
    }

    @Published public var dictionaryRules: [DictionaryRule] {
        didSet { saveDictionaryRules() }
    }

    // MARK: - プロパティ連携ヘルパー

    public var currentProvider: APIProvider {
        selectedProvider
    }

    public var currentBaseURL: String {
        config(for: selectedProvider).baseURL
    }

    public var currentModelName: String {
        config(for: selectedProvider).modelName
    }

    public var currentLLMModelName: String {
        llmConfig(for: selectedProvider).modelName
    }

    /// Whisper（音声認識）用の設定を取得
    public func config(for provider: APIProvider) -> (baseURL: String, modelName: String) {
        switch provider {
        case .groq:
            return (groqBaseURL, groqModel)
        case .openai:
            return (openAIBaseURL, openAIModel)
        }
    }

    /// LLM（テキスト推敲）用の設定を取得
    public func llmConfig(for provider: APIProvider) -> (baseURL: String, modelName: String) {
        switch provider {
        case .groq:
            return (groqBaseURL, groqLLMModel)
        case .openai:
            return (openAIBaseURL, openAILLMModel)
        }
    }

    /// バックアッププロバイダ（相互バックアップキーが存在する場合）
    public var backupProvider: APIProvider? {
        guard autoFallbackEnabled else { return nil }
        switch selectedProvider {
        case .groq:
            return KeychainService.shared.hasAPIKey(for: .openai) ? .openai : nil
        case .openai:
            return KeychainService.shared.hasAPIKey(for: .groq) ? .groq : nil
        }
    }

    private init() {
        let savedProvider = defaults.string(forKey: Keys.selectedProvider) ?? APIProvider.groq.rawValue
        self.selectedProvider = APIProvider(rawValue: savedProvider) ?? .groq

        self.groqBaseURL = defaults.string(forKey: Keys.groqBaseURL) ?? "https://api.groq.com/openai/v1"
        self.groqModel = defaults.string(forKey: Keys.groqModel) ?? "whisper-large-v3-turbo"
        self.groqLLMModel = defaults.string(forKey: Keys.groqLLMModel) ?? "qwen/qwen3.8-27b"

        self.openAIBaseURL = defaults.string(forKey: Keys.openAIBaseURL) ?? "https://api.openai.com/v1"
        self.openAIModel = defaults.string(forKey: Keys.openAIModel) ?? "whisper-1"
        self.openAILLMModel = defaults.string(forKey: Keys.openAILLMModel) ?? "gpt-4o-mini"

        let savedMode = defaults.string(forKey: Keys.apiMode) ?? SpeechAPIMode.transcriptions.rawValue
        self.apiMode = SpeechAPIMode(rawValue: savedMode) ?? .transcriptions

        let savedTrigger = defaults.string(forKey: Keys.triggerMode) ?? TriggerMode.pushToTalk.rawValue
        self.triggerMode = TriggerMode(rawValue: savedTrigger) ?? .pushToTalk

        self.autoFallbackEnabled = defaults.object(forKey: Keys.autoFallbackEnabled) != nil ? defaults.bool(forKey: Keys.autoFallbackEnabled) : true
        self.llmRefinementEnabled = defaults.object(forKey: Keys.llmRefinementEnabled) != nil ? defaults.bool(forKey: Keys.llmRefinementEnabled) : true

        self.promptHint = defaults.string(forKey: Keys.promptHint) ?? ""
        self.language = defaults.string(forKey: Keys.language) ?? "ja"
        self.restoreClipboard = defaults.object(forKey: Keys.restoreClipboard) != nil ? defaults.bool(forKey: Keys.restoreClipboard) : true

        // Default shortcut: Ctrl + Space (kVK_Space = 49, controlKey)
        let savedCode = defaults.object(forKey: Keys.hotkeyCode) as? UInt32
        self.hotkeyCode = savedCode ?? UInt32(kVK_Space)

        let savedModifiers = defaults.object(forKey: Keys.hotkeyModifiers) as? UInt32
        self.hotkeyModifiers = savedModifiers ?? UInt32(controlKey)

        self.hotkeyDisplayString = defaults.string(forKey: Keys.hotkeyDisplayString) ?? "⌃Space"

        // Load dictionary rules with auto-migration (単語破壊の原因となる古いまる・てんルールを自動除去)
        if let data = defaults.data(forKey: Keys.dictionaryRules),
           let rules = try? JSONDecoder().decode([DictionaryRule].self, from: data) {
            let cleanedRules = rules.filter { rule in
                !rule.pattern.contains("まる") &&
                !rule.pattern.contains("てん") &&
                rule.pattern != "はてな" &&
                rule.pattern != "びっくり"
            }
            self.dictionaryRules = cleanedRules.isEmpty ? AppSettings.defaultDictionaryRules : cleanedRules
            if cleanedRules.count != rules.count {
                saveDictionaryRules()
            }
        } else {
            self.dictionaryRules = AppSettings.defaultDictionaryRules
            saveDictionaryRules()
        }
    }

    public static var defaultDictionaryRules: [DictionaryRule] {
        [
            DictionaryRule(pattern: "(改行|かいぎょう)", replacement: "\n", isRegex: true, isEnabled: true)
        ]
    }

    public func resetDictionaryRules() {
        self.dictionaryRules = AppSettings.defaultDictionaryRules
    }

    private func saveDictionaryRules() {
        if let data = try? JSONEncoder().encode(dictionaryRules) {
            defaults.set(data, forKey: Keys.dictionaryRules)
        }
    }

    public func resetToDefaults() {
        selectedProvider = .groq
        groqBaseURL = "https://api.groq.com/openai/v1"
        groqModel = "whisper-large-v3-turbo"
        groqLLMModel = "qwen/qwen3.8-27b"
        openAIBaseURL = "https://api.openai.com/v1"
        openAIModel = "whisper-1"
        openAILLMModel = "gpt-4o-mini"
        apiMode = .transcriptions
        triggerMode = .pushToTalk
        autoFallbackEnabled = true
        llmRefinementEnabled = true
        promptHint = ""
        language = "ja"
        restoreClipboard = true
        hotkeyCode = UInt32(kVK_Space)
        hotkeyModifiers = UInt32(controlKey)
        hotkeyDisplayString = "⌃Space"
        dictionaryRules = AppSettings.defaultDictionaryRules
    }
}
