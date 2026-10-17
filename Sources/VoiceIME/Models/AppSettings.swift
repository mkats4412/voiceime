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

public enum RefinementStyle: String, CaseIterable, Identifiable {
    case casual = "casual"   // 口語モード (自然な話し言葉・チャット)
    case formal = "formal"   // 文章モード (整った書き言葉・メール・ドキュメント)

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .casual: return "口語モード (自然な会話・チャット)"
        case .formal: return "文章モード (報告書・ビジネスメール)"
        }
    }

    public var shortTitle: String {
        switch self {
        case .casual: return "口語"
        case .formal: return "文章"
        }
    }

    public var description: String {
        switch self {
        case .casual:
            return "話したとおりの語尾やつなぎ言葉（「えーっと」「あのー」等）を自然に残し、聞き間違いや漢字の誤りのみを修正します。"
        case .formal:
            return "「えーっと」などのフィラーを除去し、読みやすく整った標準的な書き言葉（です・ます調など）に校正・推敲します。"
        }
    }
}

public enum LLMProviderMode: String, CaseIterable, Identifiable {
    case sameAsSpeech = "sameAsSpeech"
    case groq = "groq"
    case openai = "openai"
    case custom = "custom"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sameAsSpeech: return "音声認識と同一"
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        case .custom: return "カスタム (ローカルLLM / 互換URL)"
        }
    }
}

public enum QuickAskProviderMode: String, CaseIterable, Identifiable {
    case sameAsLLM = "sameAsLLM"
    case sameAsSpeech = "sameAsSpeech"
    case groq = "groq"
    case openai = "openai"
    case custom = "custom"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sameAsLLM: return "推敲モデルと同一"
        case .sameAsSpeech: return "音声認識と同一"
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        case .custom: return "カスタム (ローカルLLM / 互換URL)"
        }
    }
}

public enum AudioSensitivityPreset: String, CaseIterable, Identifiable {
    case whisperQuiet = "whisperQuiet"
    case standard = "standard"
    case noisyEnv = "noisyEnv"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .whisperQuiet: return "小声 (-38 dB)"
        case .standard: return "標準 (-32 dB)"
        case .noisyEnv: return "騒音対策 (-24 dB)"
        }
    }

    public var thresholdDB: Float {
        switch self {
        case .whisperQuiet: return -38.0
        case .standard: return -32.0
        case .noisyEnv: return -24.0
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

        // カスタム LLM 設定
        static let llmProviderMode = "voiceime_llmProviderMode"
        static let customLLMBaseURL = "voiceime_custom_llm_baseURL"
        static let customLLMModel = "voiceime_custom_llm_model"

        // 共通設定
        static let apiMode = "voiceime_apiMode"
        static let triggerMode = "voiceime_triggerMode"
        static let autoFallbackEnabled = "voiceime_autoFallbackEnabled"
        static let llmRefinementEnabled = "voiceime_llmRefinementEnabled"
        static let refinementStyle = "voiceime_refinementStyle"
        static let promptHint = "voiceime_promptHint"
        static let customVocabulary = "voiceime_customVocabulary"
        static let language = "voiceime_language"
        static let restoreClipboard = "voiceime_restoreClipboard"
        static let hotkeyCode = "voiceime_hotkeyCode"
        static let hotkeyModifiers = "voiceime_hotkeyModifiers"
        static let hotkeyDisplayString = "voiceime_hotkeyDisplayString"
        static let dictionaryRules = "voiceime_dictionaryRules"

        // 音声しきい値・小さな音除外設定
        static let audioThresholdEnabled = "voiceime_audioThresholdEnabled"
        static let audioThresholdDB = "voiceime_audioThresholdDB"
        static let audioTrimmingEnabled = "voiceime_audioTrimmingEnabled"

        // フローティングプレビュー・保留ウィンドウ設定
        static let floatingPreviewEnabled = "voiceime_floatingPreviewEnabled"
        static let autoPasteEnabled = "voiceime_autoPasteEnabled"
        static let floatingPreviewDuration = "voiceime_floatingPreviewDuration"

        // AI クイック質問 (Quick Ask) 設定
        static let quickAskHotkeyCode = "voiceime_quickAskHotkeyCode"
        static let quickAskHotkeyModifiers = "voiceime_quickAskHotkeyModifiers"
        static let quickAskHotkeyDisplayString = "voiceime_quickAskHotkeyDisplayString"
        static let quickAskProviderMode = "voiceime_quickAskProviderMode"
        static let groqQuickAskModel = "voiceime_groq_quickAskModel"
        static let openAIQuickAskModel = "voiceime_openai_quickAskModel"
        static let customQuickAskBaseURL = "voiceime_custom_quickAsk_baseURL"
        static let customQuickAskModel = "voiceime_custom_quickAsk_model"

        // プレビューペーストショートカット設定
        static let pasteShortcutKeyCode = "voiceime_pasteShortcutKeyCode"
        static let pasteShortcutModifiers = "voiceime_pasteShortcutModifiers"
        static let pasteShortcutDisplayString = "voiceime_pasteShortcutDisplayString"
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

    // MARK: - AI推敲 (LLM) プロバイダー設定

    /// AI推敲（文脈理解）のプロバイダーモード（音声認識と同一 / Groq / OpenAI / カスタム）
    @Published public var llmProviderMode: LLMProviderMode {
        didSet { defaults.set(llmProviderMode.rawValue, forKey: Keys.llmProviderMode) }
    }

    /// カスタムLLM Base URL (Ollama, LM Studio, その他互換サーバー)
    @Published public var customLLMBaseURL: String {
        didSet { defaults.set(customLLMBaseURL, forKey: Keys.customLLMBaseURL) }
    }

    /// カスタムLLM モデル名 (例: llama3.2, qwen2.5, mistral など)
    @Published public var customLLMModel: String {
        didSet { defaults.set(customLLMModel, forKey: Keys.customLLMModel) }
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

    /// AI推敲のスタイル（口語モード / 文章モード）
    @Published public var refinementStyle: RefinementStyle {
        didSet { defaults.set(refinementStyle.rawValue, forKey: Keys.refinementStyle) }
    }

    @Published public var promptHint: String {
        didSet { defaults.set(promptHint, forKey: Keys.promptHint) }
    }

    /// 読み不要の単語登録リスト（人名・社名・製品名・専門用語）
    @Published public var customVocabulary: [String] {
        didSet {
            defaults.set(customVocabulary, forKey: Keys.customVocabulary)
            // Whisper & LLM プロンプトヒントと自動連動
            let joined = customVocabulary.joined(separator: ", ")
            if promptHint != joined {
                promptHint = joined
            }
        }
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

    // MARK: - AI クイック質問 (Quick Ask) ショートカット
    @Published public var quickAskHotkeyCode: UInt32 {
        didSet { defaults.set(quickAskHotkeyCode, forKey: Keys.quickAskHotkeyCode) }
    }

    @Published public var quickAskHotkeyModifiers: UInt32 {
        didSet { defaults.set(quickAskHotkeyModifiers, forKey: Keys.quickAskHotkeyModifiers) }
    }

    @Published public var quickAskHotkeyDisplayString: String {
        didSet { defaults.set(quickAskHotkeyDisplayString, forKey: Keys.quickAskHotkeyDisplayString) }
    }

    @Published public var quickAskProviderMode: QuickAskProviderMode {
        didSet { defaults.set(quickAskProviderMode.rawValue, forKey: Keys.quickAskProviderMode) }
    }

    @Published public var groqQuickAskModel: String {
        didSet { defaults.set(groqQuickAskModel, forKey: Keys.groqQuickAskModel) }
    }

    @Published public var openAIQuickAskModel: String {
        didSet { defaults.set(openAIQuickAskModel, forKey: Keys.openAIQuickAskModel) }
    }

    @Published public var customQuickAskBaseURL: String {
        didSet { defaults.set(customQuickAskBaseURL, forKey: Keys.customQuickAskBaseURL) }
    }

    @Published public var customQuickAskModel: String {
        didSet { defaults.set(customQuickAskModel, forKey: Keys.customQuickAskModel) }
    }

    // MARK: - プレビュー挿入 (ペースト) ショートカット
    @Published public var pasteShortcutKeyCode: UInt32 {
        didSet { defaults.set(pasteShortcutKeyCode, forKey: Keys.pasteShortcutKeyCode) }
    }

    @Published public var pasteShortcutModifiers: UInt32 {
        didSet { defaults.set(pasteShortcutModifiers, forKey: Keys.pasteShortcutModifiers) }
    }

    @Published public var pasteShortcutDisplayString: String {
        didSet { defaults.set(pasteShortcutDisplayString, forKey: Keys.pasteShortcutDisplayString) }
    }

    @Published public var dictionaryRules: [DictionaryRule] {
        didSet { saveDictionaryRules() }
    }

    /// 音量しきい値（ノイズゲート）による小さな音の除外
    @Published public var audioThresholdEnabled: Bool {
        didSet { defaults.set(audioThresholdEnabled, forKey: Keys.audioThresholdEnabled) }
    }

    /// 最小入力音量しきい値 (-50dB ... -15dB, デフォルト -32dB)
    @Published public var audioThresholdDB: Float {
        didSet { defaults.set(audioThresholdDB, forKey: Keys.audioThresholdDB) }
    }

    /// 発話前後の無音・打鍵音トリミング
    @Published public var audioTrimmingEnabled: Bool {
        didSet { defaults.set(audioTrimmingEnabled, forKey: Keys.audioTrimmingEnabled) }
    }

    /// 画面下部にプレビュー・保留ウィンドウを表示（⌘+Enterでどこでも入力）
    @Published public var floatingPreviewEnabled: Bool {
        didSet { defaults.set(floatingPreviewEnabled, forKey: Keys.floatingPreviewEnabled) }
    }

    /// 録音完了時に直前のアクティブアプリへ直接自動入力（ペースト）を試みるフラグ
    @Published public var autoPasteEnabled: Bool {
        didSet { defaults.set(autoPasteEnabled, forKey: Keys.autoPasteEnabled) }
    }

    /// プレビューウィンドウの自動非表示秒数（0の場合は手動で閉じるまで表示）
    @Published public var floatingPreviewDuration: Double {
        didSet { defaults.set(floatingPreviewDuration, forKey: Keys.floatingPreviewDuration) }
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
        effectiveLLMConfig.modelName
    }

    /// 実際に使用される推敲（LLM）プロバイダー
    public var resolvedLLMProvider: APIProvider {
        switch llmProviderMode {
        case .sameAsSpeech:
            return selectedProvider
        case .groq:
            return .groq
        case .openai:
            return .openai
        case .custom:
            return .custom
        }
    }

    /// 有効な推敲（LLM）設定 (baseURL, modelName, isCustom)
    public var effectiveLLMConfig: (baseURL: String, modelName: String, isCustom: Bool) {
        switch llmProviderMode {
        case .sameAsSpeech:
            let cfg = llmConfig(for: selectedProvider)
            return (cfg.baseURL, cfg.modelName, false)
        case .groq:
            return (groqBaseURL, groqLLMModel, false)
        case .openai:
            return (openAIBaseURL, openAILLMModel, false)
        case .custom:
            return (customLLMBaseURL, customLLMModel, true)
        }
    }

    /// 現在有効な推敲（LLM）プロバイダーの表示名
    public var effectiveLLMProviderDisplayName: String {
        switch llmProviderMode {
        case .sameAsSpeech:
            return "\(selectedProvider.displayName) (音声認識と同一)"
        case .groq:
            return "Groq"
        case .openai:
            return "OpenAI"
        case .custom:
            return "カスタム (ローカルLLM/互換)"
        }
    }

    /// 会話（クイック質問）で実際に使用されるプロバイダー
    public var resolvedQuickAskProvider: APIProvider {
        switch quickAskProviderMode {
        case .sameAsLLM:
            return resolvedLLMProvider
        case .sameAsSpeech:
            return selectedProvider
        case .groq:
            return .groq
        case .openai:
            return .openai
        case .custom:
            return .custom
        }
    }

    /// 会話（クイック質問）のプロバイダー表示名
    public var effectiveQuickAskProviderDisplayName: String {
        switch quickAskProviderMode {
        case .sameAsLLM:
            return "\(effectiveLLMProviderDisplayName) (推敲モデルと同一)"
        case .sameAsSpeech:
            return "\(selectedProvider.displayName) (音声認識と同一)"
        case .groq:
            return "Groq"
        case .openai:
            return "OpenAI"
        case .custom:
            return "カスタム (ローカルLLM/互換)"
        }
    }

    /// 会話（クイック質問）で現在有効なモデル名
    public var currentQuickAskModelName: String {
        effectiveQuickAskConfig.modelName
    }

    /// 会話（クイック質問）の有効な設定 (baseURL, modelName, isCustom, provider)
    public var effectiveQuickAskConfig: (baseURL: String, modelName: String, isCustom: Bool, provider: APIProvider) {
        switch quickAskProviderMode {
        case .sameAsLLM:
            let llm = effectiveLLMConfig
            return (llm.baseURL, llm.modelName, llm.isCustom, resolvedLLMProvider)
        case .sameAsSpeech:
            let cfg = llmConfig(for: selectedProvider)
            return (cfg.baseURL, cfg.modelName, false, selectedProvider)
        case .groq:
            return (groqBaseURL, groqQuickAskModel, false, .groq)
        case .openai:
            return (openAIBaseURL, openAIQuickAskModel, false, .openai)
        case .custom:
            return (customQuickAskBaseURL, customQuickAskModel, true, .custom)
        }
    }

    /// Whisper（音声認識）用の設定を取得
    public func config(for provider: APIProvider) -> (baseURL: String, modelName: String) {
        switch provider {
        case .groq:
            return (groqBaseURL, groqModel)
        case .openai:
            return (openAIBaseURL, openAIModel)
        case .custom:
            return (customLLMBaseURL, customLLMModel)
        }
    }

    /// LLM（テキスト推敲）用の設定を取得
    public func llmConfig(for provider: APIProvider) -> (baseURL: String, modelName: String) {
        switch provider {
        case .groq:
            return (groqBaseURL, groqLLMModel)
        case .openai:
            return (openAIBaseURL, openAILLMModel)
        case .custom:
            return (customLLMBaseURL, customLLMModel)
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
        case .custom:
            return nil
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

        let savedLLMMode = defaults.string(forKey: Keys.llmProviderMode) ?? LLMProviderMode.sameAsSpeech.rawValue
        self.llmProviderMode = LLMProviderMode(rawValue: savedLLMMode) ?? .sameAsSpeech

        self.customLLMBaseURL = defaults.string(forKey: Keys.customLLMBaseURL) ?? "http://localhost:11434/v1"
        self.customLLMModel = defaults.string(forKey: Keys.customLLMModel) ?? "llama3.2"

        let savedMode = defaults.string(forKey: Keys.apiMode) ?? SpeechAPIMode.transcriptions.rawValue
        self.apiMode = SpeechAPIMode(rawValue: savedMode) ?? .transcriptions

        let savedTrigger = defaults.string(forKey: Keys.triggerMode) ?? TriggerMode.pushToTalk.rawValue
        self.triggerMode = TriggerMode(rawValue: savedTrigger) ?? .pushToTalk

        self.autoFallbackEnabled = defaults.object(forKey: Keys.autoFallbackEnabled) != nil ? defaults.bool(forKey: Keys.autoFallbackEnabled) : true
        self.llmRefinementEnabled = defaults.object(forKey: Keys.llmRefinementEnabled) != nil ? defaults.bool(forKey: Keys.llmRefinementEnabled) : true

        let savedStyle = defaults.string(forKey: Keys.refinementStyle) ?? RefinementStyle.casual.rawValue
        self.refinementStyle = RefinementStyle(rawValue: savedStyle) ?? .casual

        let savedHint = defaults.string(forKey: Keys.promptHint) ?? ""
        self.promptHint = savedHint

        if let savedVocab = defaults.stringArray(forKey: Keys.customVocabulary) {
            self.customVocabulary = savedVocab
        } else if !savedHint.isEmpty {
            // 既存の promptHint からカンマ区切りで移行
            self.customVocabulary = savedHint
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            self.customVocabulary = []
        }

        self.language = defaults.string(forKey: Keys.language) ?? "ja"
        self.restoreClipboard = defaults.object(forKey: Keys.restoreClipboard) != nil ? defaults.bool(forKey: Keys.restoreClipboard) : true

        // Default shortcut: Ctrl + Space (kVK_Space = 49, controlKey)
        let savedCode = defaults.object(forKey: Keys.hotkeyCode) as? UInt32
        self.hotkeyCode = savedCode ?? UInt32(kVK_Space)

        let savedModifiers = defaults.object(forKey: Keys.hotkeyModifiers) as? UInt32
        self.hotkeyModifiers = savedModifiers ?? UInt32(controlKey)

        self.hotkeyDisplayString = defaults.string(forKey: Keys.hotkeyDisplayString) ?? "⌃Space"

        // AI Quick Ask default shortcut: Ctrl + Shift + Space (kVK_Space = 49, controlKey | shiftKey)
        let savedQuickAskCode = defaults.object(forKey: Keys.quickAskHotkeyCode) as? UInt32
        self.quickAskHotkeyCode = savedQuickAskCode ?? UInt32(kVK_Space)

        let savedQuickAskMods = defaults.object(forKey: Keys.quickAskHotkeyModifiers) as? UInt32
        self.quickAskHotkeyModifiers = savedQuickAskMods ?? UInt32(controlKey | shiftKey)

        self.quickAskHotkeyDisplayString = defaults.string(forKey: Keys.quickAskHotkeyDisplayString) ?? "⌃⇧Space"

        let savedQuickAskProviderMode = defaults.string(forKey: Keys.quickAskProviderMode) ?? QuickAskProviderMode.sameAsLLM.rawValue
        self.quickAskProviderMode = QuickAskProviderMode(rawValue: savedQuickAskProviderMode) ?? .sameAsLLM

        self.groqQuickAskModel = defaults.string(forKey: Keys.groqQuickAskModel) ?? "llama-3.3-70b-versatile"
        self.openAIQuickAskModel = defaults.string(forKey: Keys.openAIQuickAskModel) ?? "gpt-4o-mini"
        self.customQuickAskBaseURL = defaults.string(forKey: Keys.customQuickAskBaseURL) ?? "http://localhost:11434/v1"
        self.customQuickAskModel = defaults.string(forKey: Keys.customQuickAskModel) ?? "llama3.2"

        // プレビューペーストショートカット default: ⌘ + Return (kVK_Return = 36, cmdKey)
        let savedPasteCode = defaults.object(forKey: Keys.pasteShortcutKeyCode) as? UInt32
        self.pasteShortcutKeyCode = savedPasteCode ?? UInt32(kVK_Return)

        let savedPasteMods = defaults.object(forKey: Keys.pasteShortcutModifiers) as? UInt32
        self.pasteShortcutModifiers = savedPasteMods ?? UInt32(cmdKey)

        self.pasteShortcutDisplayString = defaults.string(forKey: Keys.pasteShortcutDisplayString) ?? "⌘↩"

        // 音声しきい値設定の読み込み（デフォルト: 有効, -32dB, トリミング有効）
        self.audioThresholdEnabled = defaults.object(forKey: Keys.audioThresholdEnabled) != nil ? defaults.bool(forKey: Keys.audioThresholdEnabled) : true
        let savedThreshold = defaults.object(forKey: Keys.audioThresholdDB) as? Float
        self.audioThresholdDB = savedThreshold ?? -32.0
        self.audioTrimmingEnabled = defaults.object(forKey: Keys.audioTrimmingEnabled) != nil ? defaults.bool(forKey: Keys.audioTrimmingEnabled) : true

        self.floatingPreviewEnabled = defaults.object(forKey: Keys.floatingPreviewEnabled) != nil ? defaults.bool(forKey: Keys.floatingPreviewEnabled) : true
        self.autoPasteEnabled = defaults.object(forKey: Keys.autoPasteEnabled) != nil ? defaults.bool(forKey: Keys.autoPasteEnabled) : true
        self.floatingPreviewDuration = defaults.object(forKey: Keys.floatingPreviewDuration) as? Double ?? 45.0

        // Load dictionary rules with auto-migration (単語破壊の原因となる古いまる・てんルールを自動除去)
        if let data = defaults.data(forKey: Keys.dictionaryRules),
           let rules = try? JSONDecoder().decode([DictionaryRule].self, from: data) {
            var cleanedRules = rules.filter { rule in
                !rule.pattern.contains("まる") &&
                !rule.pattern.contains("てん") &&
                rule.pattern != "はてな" &&
                rule.pattern != "びっくり" &&
                rule.pattern != "マック" &&
                rule.pattern != "ウインドウズ" &&
                rule.pattern != "マクド" &&
                rule.pattern != "アニソン"
            }
            // 改行ルールが旧形式または未登録なら新形式 (改行 -> \n, isRegex: false) に補正
            if let idx = cleanedRules.firstIndex(where: { $0.pattern == "(改行|かいぎょう)" }) {
                cleanedRules[idx].pattern = "改行"
                cleanedRules[idx].replacement = "\\n"
                cleanedRules[idx].isRegex = false
            } else if !cleanedRules.contains(where: { $0.pattern == "改行" }) {
                cleanedRules.insert(DictionaryRule(pattern: "改行", replacement: "\\n", isRegex: false, isEnabled: true), at: 0)
            }
            // 郵便番号サンプルルール (正規表現ON、有効チェックOFF: 例として置いておくため初期値はチェックなし)
            if let zipIndex = cleanedRules.firstIndex(where: { $0.pattern.contains("[0-9]{3}") }) {
                cleanedRules[zipIndex].isEnabled = false
                cleanedRules[zipIndex].pattern = "([0-9]{3})([0-9]{4})"
                cleanedRules[zipIndex].replacement = "〒$1-$2"
                cleanedRules[zipIndex].isRegex = true
            } else {
                cleanedRules.append(DictionaryRule(pattern: "([0-9]{3})([0-9]{4})", replacement: "〒$1-$2", isRegex: true, isEnabled: false))
            }
            self.dictionaryRules = cleanedRules.isEmpty ? AppSettings.defaultDictionaryRules : cleanedRules
            saveDictionaryRules()
        } else {
            self.dictionaryRules = AppSettings.defaultDictionaryRules
            saveDictionaryRules()
        }
    }

    public static var defaultDictionaryRules: [DictionaryRule] {
        [
            DictionaryRule(pattern: "改行", replacement: "\\n", isRegex: false, isEnabled: true),
            DictionaryRule(pattern: "([0-9]{3})([0-9]{4})", replacement: "〒$1-$2", isRegex: true, isEnabled: false)
        ]
    }

    public func resetDictionaryRules() {
        self.dictionaryRules = AppSettings.defaultDictionaryRules
    }

    // MARK: - 単語登録（語彙リスト）管理

    /// 単語を追加（カンマや改行、読点区切りで複数一括入力にも対応）
    public func addVocabularyWord(_ rawText: String) {
        let words = rawText
            .components(separatedBy: CharacterSet(charactersIn: ",\n、\t"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var current = self.customVocabulary
        for word in words {
            if !current.contains(word) {
                current.append(word)
            }
        }
        self.customVocabulary = current
    }

    /// インデックス指定で単語を削除
    public func removeVocabularyWord(at index: Int) {
        guard customVocabulary.indices.contains(index) else { return }
        var current = self.customVocabulary
        current.remove(at: index)
        self.customVocabulary = current
    }

    /// 単語文字列指定で削除
    public func removeVocabularyWord(_ word: String) {
        self.customVocabulary = self.customVocabulary.filter { $0 != word }
    }

    /// 単語リストを全クリア
    public func clearVocabulary() {
        self.customVocabulary = []
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
        refinementStyle = .casual
        promptHint = ""
        language = "ja"
        restoreClipboard = true
        hotkeyCode = UInt32(kVK_Space)
        hotkeyModifiers = UInt32(controlKey)
        hotkeyDisplayString = "⌃Space"
        audioThresholdEnabled = true
        audioThresholdDB = -32.0
        audioTrimmingEnabled = true
        dictionaryRules = AppSettings.defaultDictionaryRules
    }
}
