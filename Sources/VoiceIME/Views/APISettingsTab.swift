import SwiftUI

@MainActor
public final class APISettingsViewModel: ObservableObject {
    @Published public var apiKeyInput: String = ""
    @Published public var isKeyVisible: Bool = false
    @Published public var saveMessage: String? = nil
    @Published public var hasKeyStored: Bool = false
    @Published public var groqHasKey: Bool = false
    @Published public var openAIHasKey: Bool = false

    @Published public var customApiKeyInput: String = ""
    @Published public var isCustomKeyVisible: Bool = false
    @Published public var customSaveMessage: String? = nil
    @Published public var hasCustomKeyStored: Bool = false

    @Published public var sarashinaApiKeyInput: String = ""
    @Published public var isSarashinaKeyVisible: Bool = false
    @Published public var sarashinaSaveMessage: String? = nil
    @Published public var hasSarashinaKeyStored: Bool = false

    @Published public var llmApiKeyInput: String = ""
    @Published public var isLLMKeyVisible: Bool = false
    @Published public var llmSaveMessage: String? = nil
    @Published public var hasLLMKeyStored: Bool = false

    @Published public var isTestingLLM: Bool = false
    @Published public var testLLMResult: String? = nil
    @Published public var testLLMIsError: Bool = false

    @Published public var isTestingQuickAsk: Bool = false
    @Published public var testQuickAskResult: String? = nil
    @Published public var testQuickAskIsError: Bool = false

    public enum PromptTabMode: String, CaseIterable, Identifiable {
        case casual = "口語システムプロンプト"
        case formal = "文章システムプロンプト"
        case userTemplate = "ユーザー入力テンプレート"
        public var id: String { rawValue }
    }
    @Published public var selectedPromptTab: PromptTabMode = .casual

    public let maskText = "••••••••••••••••••••••••••••••••"
    private let keychain = KeychainService.shared

    public init() {}

    public func updateKeyStatus(currentProvider: APIProvider) {
        groqHasKey = keychain.hasAPIKey(for: .groq)
        openAIHasKey = keychain.hasAPIKey(for: .openai)

        let exists = keychain.hasAPIKey(for: currentProvider)
        hasKeyStored = exists
        isKeyVisible = false
        if exists {
            apiKeyInput = maskText
        } else {
            apiKeyInput = ""
        }
        updateCustomKeyStatus()
        updateSarashinaKeyStatus()
        updateLLMKeyStatus(settings: AppSettings.shared)
    }

    public func updateSarashinaKeyStatus() {
        let exists = keychain.hasAPIKey(for: .sarashina)
        hasSarashinaKeyStored = exists
        isSarashinaKeyVisible = false
        if exists {
            sarashinaApiKeyInput = maskText
        } else {
            sarashinaApiKeyInput = ""
        }
    }

    public func toggleSarashinaKeyVisibility() {
        isSarashinaKeyVisible.toggle()
        if isSarashinaKeyVisible {
            if (sarashinaApiKeyInput == maskText || sarashinaApiKeyInput.isEmpty),
               let loadedKey = keychain.loadAPIKey(for: .sarashina) {
                sarashinaApiKeyInput = loadedKey
            }
        } else {
            if let loadedKey = keychain.loadAPIKey(for: .sarashina), sarashinaApiKeyInput == loadedKey {
                sarashinaApiKeyInput = maskText
            }
        }
    }

    public func saveSarashinaAPIKey() {
        let trimmed = sarashinaApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && trimmed != maskText else { return }

        if keychain.saveAPIKey(trimmed, for: .sarashina) {
            updateSarashinaKeyStatus()
            AppState.shared.resetError()
            sarashinaSaveMessage = "✓ Sarashina APIキーをKeychainに保存しました"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.sarashinaSaveMessage = nil
            }
        } else {
            sarashinaSaveMessage = "⚠️ 保存に失敗しました"
        }
    }

    public func deleteSarashinaAPIKey() {
        if keychain.deleteAPIKey(for: .sarashina) {
            updateSarashinaKeyStatus()
            sarashinaSaveMessage = "Sarashina APIキーを削除しました"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.sarashinaSaveMessage = nil
            }
        }
    }

    public func updateCustomKeyStatus() {
        let exists = keychain.hasAPIKey(for: .custom)
        hasCustomKeyStored = exists
        isCustomKeyVisible = false
        if exists {
            customApiKeyInput = maskText
        } else {
            customApiKeyInput = ""
        }
    }

    public func toggleKeyVisibility(currentProvider: APIProvider) {
        isKeyVisible.toggle()
        if isKeyVisible {
            if (apiKeyInput == maskText || apiKeyInput.isEmpty),
               let loadedKey = keychain.loadAPIKey(for: currentProvider) {
                apiKeyInput = loadedKey
            }
        } else {
            if let loadedKey = keychain.loadAPIKey(for: currentProvider), apiKeyInput == loadedKey {
                apiKeyInput = maskText
            }
        }
    }

    public func toggleCustomKeyVisibility() {
        isCustomKeyVisible.toggle()
        if isCustomKeyVisible {
            if (customApiKeyInput == maskText || customApiKeyInput.isEmpty),
               let loadedKey = keychain.loadAPIKey(for: .custom) {
                customApiKeyInput = loadedKey
            }
        } else {
            if let loadedKey = keychain.loadAPIKey(for: .custom), customApiKeyInput == loadedKey {
                customApiKeyInput = maskText
            }
        }
    }

    public func saveAPIKey(currentProvider: APIProvider) {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && trimmed != maskText else { return }

        if keychain.saveAPIKey(trimmed, for: currentProvider) {
            updateKeyStatus(currentProvider: currentProvider)
            AppState.shared.resetError()
            saveMessage = "✓ \(currentProvider.displayName) のAPIキーをKeychainに保存しました"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.saveMessage = nil
            }
        } else {
            saveMessage = "⚠️ 保存に失敗しました"
        }
    }

    public func saveCustomAPIKey() {
        let trimmed = customApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && trimmed != maskText else { return }

        if keychain.saveAPIKey(trimmed, for: .custom) {
            updateCustomKeyStatus()
            AppState.shared.resetError()
            customSaveMessage = "✓ カスタムAPIキーをKeychainに保存しました"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.customSaveMessage = nil
            }
        } else {
            customSaveMessage = "⚠️ 保存に失敗しました"
        }
    }

    public func deleteAPIKey(currentProvider: APIProvider) {
        if keychain.deleteAPIKey(for: currentProvider) {
            updateKeyStatus(currentProvider: currentProvider)
            saveMessage = "\(currentProvider.displayName) のAPIキーを削除しました"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.saveMessage = nil
            }
        }
    }

    public func deleteCustomAPIKey() {
        if keychain.deleteAPIKey(for: .custom) {
            updateCustomKeyStatus()
            customSaveMessage = "カスタムAPIキーを削除しました"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.customSaveMessage = nil
            }
        }
    }

    public func updateLLMKeyStatus(settings: AppSettings) {
        let provider = settings.resolvedLLMProvider
        let exists = keychain.hasAPIKey(for: provider)
        hasLLMKeyStored = exists
        isLLMKeyVisible = false
        if exists {
            llmApiKeyInput = maskText
        } else {
            llmApiKeyInput = ""
        }
    }

    public func toggleLLMKeyVisibility(settings: AppSettings) {
        let provider = settings.resolvedLLMProvider
        isLLMKeyVisible.toggle()
        if isLLMKeyVisible {
            if (llmApiKeyInput == maskText || llmApiKeyInput.isEmpty),
               let loadedKey = keychain.loadAPIKey(for: provider) {
                llmApiKeyInput = loadedKey
            }
        } else {
            if let loadedKey = keychain.loadAPIKey(for: provider), llmApiKeyInput == loadedKey {
                llmApiKeyInput = maskText
            }
        }
    }

    public func saveLLMAPIKey(settings: AppSettings) {
        let provider = settings.resolvedLLMProvider
        let trimmed = llmApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && trimmed != maskText else { return }

        if keychain.saveAPIKey(trimmed, for: provider) {
            if provider == .sarashina {
                _ = keychain.saveAPIKey(trimmed, for: .custom)
            } else if provider == .custom {
                _ = keychain.saveAPIKey(trimmed, for: .sarashina)
            }
            updateLLMKeyStatus(settings: settings)
            updateKeyStatus(currentProvider: settings.selectedProvider)
            AppState.shared.resetError()
            llmSaveMessage = "✓ \(provider.displayName) APIキーをKeychainに保存しました"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.llmSaveMessage = nil
            }
        } else {
            llmSaveMessage = "⚠️ 保存に失敗しました"
        }
    }

    public func deleteLLMAPIKey(settings: AppSettings) {
        let provider = settings.resolvedLLMProvider
        if keychain.deleteAPIKey(for: provider) {
            if provider == .sarashina {
                _ = keychain.deleteAPIKey(for: .custom)
            } else if provider == .custom {
                _ = keychain.deleteAPIKey(for: .sarashina)
            }
            updateLLMKeyStatus(settings: settings)
            updateKeyStatus(currentProvider: settings.selectedProvider)
            llmSaveMessage = "\(provider.displayName) APIキーを削除しました"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.llmSaveMessage = nil
            }
        }
    }

    public func testLLMConnection(settings: AppSettings) async {
        let config = settings.effectiveLLMConfig
        let trimmedModel = config.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            testLLMIsError = false
            testLLMResult = "推敲モデル名が未指定のため推敲OFFです（Whisper文字起こしをそのまま出力）"
            return
        }

        isTestingLLM = true
        testLLMResult = nil
        testLLMIsError = false

        let resolvedProvider = settings.resolvedLLMProvider
        let apiKey = keychain.loadAPIKey(for: resolvedProvider)

        do {
            let res = try await LLMService.shared.refine(
                text: "えーっと、これは音声入力のテストです。",
                baseURL: config.baseURL,
                apiKey: apiKey,
                model: trimmedModel,
                promptHint: settings.promptHint.isEmpty ? nil : settings.promptHint,
                style: settings.refinementStyle,
                isCustom: config.isCustom
            )
            testLLMIsError = false
            testLLMResult = "✓ 成功: 「\(res)」"
        } catch {
            testLLMIsError = true
            let summary = (error as? LLMService.LLMError)?.summary ?? error.localizedDescription
            testLLMResult = "⚠️ 接続失敗: \(summary)"
        }

        isTestingLLM = false
    }

    public func testQuickAskConnection(settings: AppSettings) async {
        isTestingQuickAsk = true
        testQuickAskResult = nil
        testQuickAskIsError = false

        let config = settings.effectiveQuickAskConfig
        let apiKey = keychain.loadAPIKey(for: config.provider)

        do {
            let res = try await LLMService.shared.quickAsk(
                question: "ゴミの英語のスペルは?",
                history: [],
                baseURL: config.baseURL,
                apiKey: apiKey,
                model: config.modelName,
                isCustom: config.isCustom
            )
            testQuickAskIsError = false
            testQuickAskResult = "✓ 成功: 「\(res)」"
        } catch {
            testQuickAskIsError = true
            let summary = (error as? LLMService.LLMError)?.summary ?? error.localizedDescription
            testQuickAskResult = "⚠️ 接続失敗: \(summary)"
        }

        isTestingQuickAsk = false
    }
}

public struct APISettingsTab: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var appState = AppState.shared
    @StateObject private var vm = APISettingsViewModel()
    private let keychain = KeychainService.shared
    private let apiService = WhisperAPIService.shared
    private let llmService = LLMService.shared

    private var apiKeyInput: String { vm.apiKeyInput }
    private var isKeyVisible: Bool { vm.isKeyVisible }
    private var saveMessage: String? { vm.saveMessage }
    private var hasKeyStored: Bool { vm.hasKeyStored }
    private var groqHasKey: Bool { vm.groqHasKey }
    private var openAIHasKey: Bool { vm.openAIHasKey }
    private var maskText: String { vm.maskText }

    public init() {}

    private var currentProvider: APIProvider {
        settings.selectedProvider
    }

    /// プロバイダごとのBaseURLバインディング
    private var baseURLBinding: Binding<String> {
        Binding(
            get: { settings.currentBaseURL },
            set: { newValue in
                switch settings.selectedProvider {
                case .groq: settings.groqBaseURL = newValue
                case .openai: settings.openAIBaseURL = newValue
                case .sarashina: settings.sarashinaBaseURL = newValue
                case .custom: settings.customLLMBaseURL = newValue
                }
            }
        )
    }

    /// プロバイダごとのWhisperモデル名バインディング
    private var modelNameBinding: Binding<String> {
        Binding(
            get: { settings.currentModelName },
            set: { newValue in
                switch settings.selectedProvider {
                case .groq: settings.groqModel = newValue
                case .openai: settings.openAIModel = newValue
                case .sarashina: settings.sarashinaModel = newValue
                case .custom: settings.customLLMModel = newValue
                }
            }
        )
    }

    /// プロバイダごとのLLMモデル名バインディング
    private var llmModelNameBinding: Binding<String> {
        Binding(
            get: { settings.currentLLMModelName },
            set: { newValue in
                switch settings.resolvedLLMProvider {
                case .sarashina: settings.sarashinaModel = newValue
                case .groq: settings.groqLLMModel = newValue
                case .openai: settings.openAILLMModel = newValue
                case .custom: settings.customLLMModel = newValue
                }
            }
        )
    }

    /// 保存ボタンが押せる条件: 入力があり、かつダミーマスク文字列そのものではないこと
    private var canSaveKey: Bool {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != maskText
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                // ==========================================
                // セクション0: 音声認識プロバイダー選択 & バックアップ
                // ==========================================
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("音声認識プロバイダー選択", systemImage: "waveform.circle")
                            .font(.headline)
                        Spacer()
                        Text("クラウドAPI")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 10) {
                        // Groq 切り替えボタン
                        Button(action: {
                            settings.selectedProvider = .groq
                            updateKeyStatus()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "bolt.fill")
                                    .foregroundColor(.orange)
                                    .font(.system(size: 16))
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text("Groq (超高速 約0.6秒・無料枠)")
                                            .font(.system(size: 12, weight: .semibold))
                                        if groqHasKey {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .font(.system(size: 10))
                                        }
                                    }
                                    Text("認識: \(settings.groqModel)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(currentProvider == .groq ? Color.orange.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(currentProvider == .groq ? Color.orange : Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)

                        // OpenAI 切り替えボタン
                        Button(action: {
                            settings.selectedProvider = .openai
                            updateKeyStatus()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                    .foregroundColor(.green)
                                    .font(.system(size: 16))
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text("OpenAI (約2〜4秒・高品質)")
                                            .font(.system(size: 12, weight: .semibold))
                                        if openAIHasKey {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .font(.system(size: 10))
                                        }
                                    }
                                    Text("認識: \(settings.openAIModel)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(currentProvider == .openai ? Color.green.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(currentProvider == .openai ? Color.green : Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // バックアップ連携カード
                    if let backup = settings.backupProvider {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "arrow.triangle.swap")
                                .foregroundColor(.blue)
                                .font(.caption)
                            Text("相互バックアップ有効: \(currentProvider.displayName) 障害時や応答遅延時は \(backup.displayName) で並行高速化")
                                .font(.caption)
                                .foregroundColor(.primary)
                            Spacer()
                            Toggle("", isOn: $settings.autoFallbackEnabled)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.blue.opacity(0.08))
                        )
                    } else if currentProvider == .groq && !openAIHasKey {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                                .font(.caption)
                            Text("ヒント: OpenAI のキーも登録すると、Groq 障害時の自動バックアップになります")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 4)
                    } else if currentProvider == .openai && !groqHasKey {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                                .font(.caption)
                            Text("ヒント: Groq のキーも登録すると、OpenAI 障害時の自動バックアップになります")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1)
                )

                // 直近の障害回避・フォールバック診断情報
                if let fallback = appState.lastFallbackRecord {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("直近のAPI障害回避レポート (\(fallback.primaryProvider.displayName) \(fallback.step) 失敗)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.orange)
                            Spacer()
                            Button("クリア") {
                                appState.lastFallbackRecord = nil
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }

                        HStack(alignment: .top, spacing: 4) {
                            Text("失敗理由:")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.primary)
                            Text(fallback.reasonSummary)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.primary)
                        }

                        HStack(alignment: .top, spacing: 4) {
                            Text("エラー詳細:")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                            Text(fallback.detail)
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }

                        Text("➔ \(fallback.backupProvider.displayName) に自動フォールバックして処理を継続しました。")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.orange.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
                }

                // ==========================================
                // セクション1: APIキー入力（Keychain）
                // ==========================================
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("\(currentProvider.displayName) APIキー設定", systemImage: "key.fill")
                            .font(.headline)

                        Spacer()

                        if hasKeyStored {
                            HStack(spacing: 4) {
                                Image(systemName: "lock.shield.fill")
                                    .foregroundColor(.green)
                                Text("Keychain暗号化保護中")
                                    .foregroundColor(.green)
                            }
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.12))
                            .cornerRadius(4)
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("未登録 (入力必須)")
                                    .foregroundColor(.orange)
                                    .fontWeight(.semibold)
                            }
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(4)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(currentProvider.displayName) のAPIキーを入力してください:")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        HStack(spacing: 8) {
                            InputFieldBox(isWarning: !hasKeyStored) {
                                Image(systemName: hasKeyStored ? "key.horizontal.fill" : "key.horizontal")
                                    .foregroundColor(hasKeyStored ? .accentColor : .orange)
                                    .font(.system(size: 13))
                            } content: {
                                if isKeyVisible {
                                    TextField(hasKeyStored ? "新しいキーを入力して上書き保存" : "\(currentProvider.displayName) APIキーを入力 (gsk_... / sk-...)", text: $vm.apiKeyInput)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 12.5, design: .monospaced))
                                } else {
                                    SecureField(hasKeyStored ? "新しいキーを入力して上書き保存" : "\(currentProvider.displayName) APIキーを入力 (gsk_... / sk-...)", text: $vm.apiKeyInput)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 12.5, design: .monospaced))
                                }
                            } trailing: {
                                HStack(spacing: 6) {
                                    if !apiKeyInput.isEmpty && apiKeyInput != maskText {
                                        Button(action: { vm.apiKeyInput = "" }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                                .font(.system(size: 13))
                                        }
                                        .buttonStyle(.plain)
                                        .help("入力をクリア")
                                    }

                                    Button(action: toggleKeyVisibility) {
                                        Image(systemName: isKeyVisible ? "eye.slash.fill" : "eye.fill")
                                            .foregroundColor(.secondary)
                                            .font(.system(size: 13))
                                    }
                                    .buttonStyle(.plain)
                                    .help(isKeyVisible ? "キーを伏字にする" : "キーを表示する")
                                }
                            }

                            Button("保存") {
                                saveAPIKey()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .disabled(!canSaveKey)

                            if hasKeyStored {
                                Button("削除") {
                                    deleteAPIKey()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .foregroundColor(.red)
                                .help("KeychainからAPIキーを完全に消去")
                            }
                        }

                        if hasKeyStored {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("※ キーはmacOSの暗号化領域（キーチェーン）に安全に保管されています。変更したい場合は新しいキーを入力して「保存」を押してください。")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("💡 アプリの更新後に初回起動した際、macOSからパスワード確認が表示された場合はMacのログインパスワードを入力して『常に許可』を選択してください。")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text("※ 音声認識を使用するには、上記の入力エリアに \(currentProvider.displayName) のAPIキーを入力して「保存」をクリックしてください（キーチェーンに暗号化保存されます）。")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }

                        if let msg = saveMessage {
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(.accentColor)
                                .transition(.opacity)
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(hasKeyStored ? Color(NSColor.separatorColor).opacity(0.6) : Color.orange.opacity(0.6), lineWidth: hasKeyStored ? 1 : 1.5)
                )

                // ==========================================
                // セクション2: 音声認識（Whisper）詳細設定
                // ==========================================
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("音声認識（Whisper）詳細設定", systemImage: "waveform")
                            .font(.headline)
                        Spacer()
                        Text("対象: \(currentProvider.displayName)")
                            .font(.caption)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(4)
                    }

                    // Base URL 入力
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(currentProvider.displayName) Base URL:")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        InputFieldBox {
                            Image(systemName: "link")
                                .foregroundColor(.blue)
                                .font(.system(size: 13))
                        } content: {
                            TextField("https://api.groq.com/openai/v1", text: baseURLBinding)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                        } trailing: {
                            if !baseURLBinding.wrappedValue.isEmpty {
                                Button(action: { baseURLBinding.wrappedValue = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 13))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if let resolvedURL = apiService.constructEndpointURL(from: settings.currentBaseURL, mode: settings.apiMode) {
                            HStack(spacing: 4) {
                                Text("送信先:")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(resolvedURL.absoluteString)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.primary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.08))
                            .cornerRadius(4)
                        }
                    }

                    // 音声認識モデル名
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("音声認識モデル名:")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("[自由入力・変更可]")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("現在: \(settings.currentModelName)")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }

                        InputFieldBox {
                            Image(systemName: "waveform")
                                .foregroundColor(.orange)
                                .font(.system(size: 13))
                        } content: {
                            TextField("モデルIDを入力（例: whisper-large-v3-turbo, whisper-1 など）", text: modelNameBinding)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5, design: .monospaced))
                        } trailing: {
                            if !modelNameBinding.wrappedValue.isEmpty {
                                Button(action: { modelNameBinding.wrappedValue = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 13))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text("候補からワンクリックで入力:")
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            if currentProvider == .groq {
                                Button("whisper-large-v3-turbo") {
                                    settings.groqModel = "whisper-large-v3-turbo"
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)

                                Button("whisper-large-v3") {
                                    settings.groqModel = "whisper-large-v3"
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            } else {
                                Button("gpt-4o-mini-transcribe (高速)") {
                                    settings.openAIModel = "gpt-4o-mini-transcribe"
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)

                                Button("whisper-1 (高精度・約2秒)") {
                                    settings.openAIModel = "whisper-1"
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                    }

                    // 一括データ送信トグル
                    Divider()
                        .padding(.vertical, 4)

                    Toggle(isOn: $settings.batchTranscriptionEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("録音終了時の一括送信モード（OFF時はリアルタイム累積・紙芝居ストリーミング）")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("ONの場合、キーを離した際に全音声を1回でAPI送信します。OFF（デフォルト）の場合、話者の息継ぎ（無音）を検知するたびに0秒からの累積音声をAPIへ送信し、紙芝居のように画面全体を最新の高精度テキストへ上書き更新します（1分間に最大18回レート制限でAPIクォータを安全に保護）。")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1)
                )

                // ==========================================
                // セクション3: AI（LLM）推敲・文脈理解 [共通設定]
                // ==========================================
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Label("AI（LLM）推敲・文脈理解（共通設定）", systemImage: "sparkles")
                                    .font(.headline)
                                Text(settings.isLLMRefinementActive ? "推敲有効" : "推敲OFF")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(settings.isLLMRefinementActive ? .blue : .secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(settings.isLLMRefinementActive ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.12))
                                    .cornerRadius(4)
                            }
                            Text("音声認識プロバイダー（Groq / OpenAI）に関係なく共通で適用されます。音声の誤字・同音異義語・慣用句の誤りを自然に復元します。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $settings.llmRefinementEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }

                    if settings.llmRefinementEnabled {
                        VStack(alignment: .leading, spacing: 12) {
                            // 1. 推敲モデル名（ユーザー自由入力）
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("推敲モデル名:")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("※ 空欄の場合は推敲を使用せず、文字起こしをそのまま出力します")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    if settings.userLLMModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text("未指定 (推敲なし)")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    } else {
                                        Text("指定中: \(settings.userLLMModel)")
                                            .font(.caption)
                                            .foregroundColor(.accentColor)
                                    }
                                }

                                InputFieldBox {
                                    Image(systemName: "brain")
                                        .foregroundColor(.purple)
                                        .font(.system(size: 13))
                                } content: {
                                    TextField("例: sarashina3-mini, gpt-4o-mini など（空欄で推敲なし）", text: $settings.userLLMModel)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 12.5, design: .monospaced))
                                } trailing: {
                                    if !settings.userLLMModel.isEmpty {
                                        Button(action: { settings.userLLMModel = "" }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                                .font(.system(size: 13))
                                        }
                                        .buttonStyle(.plain)
                                        .help("推敲モデル名をクリア（推敲OFF）")
                                    }
                                }

                                HStack(spacing: 6) {
                                    Image(systemName: "hand.tap.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                    Text("ワンクリック候補:")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)

                                    Button("🌸 sarashina3-mini (推奨)") {
                                        settings.userLLMModel = "sarashina3-mini"
                                        if settings.userLLMBaseURL.isEmpty || !settings.userLLMBaseURL.contains("sarashina") {
                                            settings.userLLMBaseURL = "https://api.sarashina.ai/v1"
                                        }
                                        vm.updateLLMKeyStatus(settings: settings)
                                    }
                                    .buttonStyle(.bordered).controlSize(.mini)

                                    Button("🌸 sarashina3-nano") {
                                        settings.userLLMModel = "sarashina3-nano"
                                        if settings.userLLMBaseURL.isEmpty || !settings.userLLMBaseURL.contains("sarashina") {
                                            settings.userLLMBaseURL = "https://api.sarashina.ai/v1"
                                        }
                                        vm.updateLLMKeyStatus(settings: settings)
                                    }
                                    .buttonStyle(.bordered).controlSize(.mini)

                                    Button("🟢 gpt-4o-mini") {
                                        settings.userLLMModel = "gpt-4o-mini"
                                        settings.userLLMBaseURL = "https://api.openai.com/v1"
                                        vm.updateLLMKeyStatus(settings: settings)
                                    }
                                    .buttonStyle(.bordered).controlSize(.mini)

                                    Button("⚡ openai/gpt-oss-120b") {
                                        settings.userLLMModel = "openai/gpt-oss-120b"
                                        settings.userLLMBaseURL = "https://api.groq.com/openai/v1"
                                        vm.updateLLMKeyStatus(settings: settings)
                                    }
                                    .buttonStyle(.bordered).controlSize(.mini)

                                    Button("🚫 未指定 (推敲OFF)") {
                                        settings.userLLMModel = ""
                                    }
                                    .buttonStyle(.bordered).controlSize(.mini)
                                    .foregroundColor(.orange)
                                }
                            }

                            // 2. 推敲 Base URL（直接入力）
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("推敲 API Base URL:")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Text("自動検出: \(settings.resolvedLLMProvider.displayName)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                InputFieldBox {
                                    Image(systemName: "network")
                                        .foregroundColor(.blue)
                                        .font(.system(size: 13))
                                } content: {
                                    TextField("https://api.sarashina.ai/v1", text: $settings.userLLMBaseURL)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 12, design: .monospaced))
                                } trailing: {
                                    if !settings.userLLMBaseURL.isEmpty {
                                        Button(action: { settings.userLLMBaseURL = "" }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                                .font(.system(size: 13))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                HStack(spacing: 6) {
                                    Image(systemName: "hand.tap.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                    Text("プリセット:")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)

                                    Button("Sarashina") {
                                        settings.userLLMBaseURL = "https://api.sarashina.ai/v1"
                                        vm.updateLLMKeyStatus(settings: settings)
                                    }
                                    .buttonStyle(.bordered).controlSize(.mini)

                                    Button("OpenAI") {
                                        settings.userLLMBaseURL = "https://api.openai.com/v1"
                                        vm.updateLLMKeyStatus(settings: settings)
                                    }
                                    .buttonStyle(.bordered).controlSize(.mini)

                                    Button("Groq") {
                                        settings.userLLMBaseURL = "https://api.groq.com/openai/v1"
                                        vm.updateLLMKeyStatus(settings: settings)
                                    }
                                    .buttonStyle(.bordered).controlSize(.mini)

                                    Button("Ollama (11434)") {
                                        settings.userLLMBaseURL = "http://localhost:11434/v1"
                                        vm.updateLLMKeyStatus(settings: settings)
                                    }
                                    .buttonStyle(.bordered).controlSize(.mini)

                                    Button("LM Studio (1234)") {
                                        settings.userLLMBaseURL = "http://localhost:1234/v1"
                                        vm.updateLLMKeyStatus(settings: settings)
                                    }
                                    .buttonStyle(.bordered).controlSize(.mini)
                                }
                            }

                            // 3. 推敲 APIキー (Keychain保存)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("\(settings.resolvedLLMProvider.displayName) APIキー:")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    if settings.resolvedLLMProvider == .custom && (settings.userLLMBaseURL.contains("localhost") || settings.userLLMBaseURL.contains("127.0.0.1")) {
                                        Text("※ ローカルLLM (Ollama等) ではAPIキー不要です")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if vm.hasLLMKeyStored {
                                        HStack(spacing: 3) {
                                            Image(systemName: "lock.shield.fill")
                                                .foregroundColor(.green)
                                            Text("Keychain暗号化保護中")
                                                .foregroundColor(.green)
                                        }
                                        .font(.caption2)
                                    }
                                }

                                HStack(spacing: 8) {
                                    InputFieldBox {
                                        Image(systemName: "key.fill")
                                            .foregroundColor(.accentColor)
                                            .font(.system(size: 13))
                                    } content: {
                                        if vm.isLLMKeyVisible {
                                            TextField("APIキーを入力", text: $vm.llmApiKeyInput)
                                                .textFieldStyle(.plain)
                                                .font(.system(size: 12, design: .monospaced))
                                        } else {
                                            SecureField("APIキーを入力", text: $vm.llmApiKeyInput)
                                                .textFieldStyle(.plain)
                                                .font(.system(size: 12, design: .monospaced))
                                        }
                                    } trailing: {
                                        Button(action: { vm.toggleLLMKeyVisibility(settings: settings) }) {
                                            Image(systemName: vm.isLLMKeyVisible ? "eye.slash.fill" : "eye.fill")
                                                .foregroundColor(.secondary)
                                                .font(.system(size: 13))
                                        }
                                        .buttonStyle(.plain)
                                    }

                                    Button("保存") {
                                        vm.saveLLMAPIKey(settings: settings)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.regular)
                                    .disabled(vm.llmApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.llmApiKeyInput == vm.maskText)

                                    if vm.hasLLMKeyStored {
                                        Button("削除") {
                                            vm.deleteLLMAPIKey(settings: settings)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.regular)
                                        .foregroundColor(.red)
                                        .help("Keychainからこの推敲APIキーを消去")
                                    }
                                }

                                if let msg = vm.llmSaveMessage {
                                    Text(msg)
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                }
                            }

                            // 4. 文体スタイル
                            VStack(alignment: .leading, spacing: 6) {
                                Text("推敲文体スタイル:")
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                HStack(spacing: 8) {
                                    Button(action: { settings.refinementStyle = .casual }) {
                                        HStack {
                                            Image(systemName: settings.refinementStyle == .casual ? "largecircle.fill.circle" : "circle")
                                                .foregroundColor(.accentColor)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text("口語スタイル（会話・チャット向け）")
                                                    .font(.system(size: 11.5, weight: .semibold))
                                                Text("「〜ですね」「〜ですよ」等の自然な語尾や口調をそのまま維持します。")
                                                    .font(.system(size: 9.5))
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .padding(6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(settings.refinementStyle == .casual ? Color.accentColor.opacity(0.1) : Color.clear))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: { settings.refinementStyle = .formal }) {
                                        HStack {
                                            Image(systemName: settings.refinementStyle == .formal ? "largecircle.fill.circle" : "circle")
                                                .foregroundColor(.accentColor)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text("文章スタイル（報告書・メール向け）")
                                                    .font(.system(size: 11.5, weight: .semibold))
                                                Text("「〜である」「〜報告いたします」等の標準的な書き言葉に整えます。")
                                                    .font(.system(size: 9.5))
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .padding(6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(settings.refinementStyle == .formal ? Color.accentColor.opacity(0.1) : Color.clear))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            // 5. 推敲接続テスト
                            Divider().padding(.vertical, 2)

                            HStack(spacing: 10) {
                                Button(action: {
                                    Task {
                                        await vm.testLLMConnection(settings: settings)
                                    }
                                }) {
                                    HStack(spacing: 5) {
                                        if vm.isTestingLLM {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Image(systemName: "bolt.badge.checkmark.fill")
                                                .foregroundColor(.purple)
                                        }
                                        Text(vm.isTestingLLM ? "接続テスト中..." : "推敲接続テスト")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(vm.isTestingLLM)

                                if let result = vm.testLLMResult {
                                    Text(result)
                                        .font(.caption)
                                        .foregroundColor(vm.testLLMIsError ? .red : .green)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }

                            Divider().padding(.vertical, 4)

                            // 6. 推敲プロンプトの編集 (prompts.json 連動)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "pencil.and.outline")
                                        .foregroundColor(.purple)
                                    Text("推敲プロンプトの編集:")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Spacer()

                                    Button("Finderで開く") {
                                        VoiceIMEDiskSyncService.shared.openFolderInFinder()
                                    }
                                    .buttonStyle(.bordered).controlSize(.mini)
                                    .help("~/.voiceime/prompts.json が保存されているフォルダをFinderで開きます")

                                    Button("初期値に戻す") {
                                        settings.resetPromptsToDefaults()
                                    }
                                    .buttonStyle(.bordered).controlSize(.mini)
                                    .foregroundColor(.orange)
                                    .help("プロンプトを推奨初期値にリセットします")
                                }

                                Picker("", selection: $vm.selectedPromptTab) {
                                    ForEach(APISettingsViewModel.PromptTabMode.allCases) { mode in
                                        Text(mode.rawValue).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)

                                VStack(alignment: .leading, spacing: 4) {
                                    if vm.selectedPromptTab == .casual {
                                        TextEditor(text: $settings.systemPromptCasual)
                                            .font(.system(size: 11, design: .monospaced))
                                            .frame(height: 100)
                                            .padding(4)
                                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                                        Text("※ 口語モード発話時にシステムプロンプトとして使用されます。")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    } else if vm.selectedPromptTab == .formal {
                                        TextEditor(text: $settings.systemPromptFormal)
                                            .font(.system(size: 11, design: .monospaced))
                                            .frame(height: 100)
                                            .padding(4)
                                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                                        Text("※ 文章モード発話時にシステムプロンプトとして使用されます。")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    } else {
                                        TextEditor(text: $settings.userPromptTemplate)
                                            .font(.system(size: 11, design: .monospaced))
                                            .frame(height: 100)
                                            .padding(4)
                                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                                        Text("※ {input} の部分にWhisper文字起こしテキストが代入されます。")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }

                                Text("💡 ~/.voiceime/prompts.json に常時同期。MCPや外部エディタからの編集も即座に反映されます。")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1)
                )

                // ==========================================
                // セクション4: AI会話（クイック質問）モデル設定
                // ==========================================
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Label("AI会話（クイック質問）モデル設定", systemImage: "bubble.left.and.bubble.right.fill")
                                    .font(.headline)
                                Text(settings.quickAskHotkeyDisplayString)
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.purple)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.purple.opacity(0.12))
                                    .cornerRadius(4)
                            }
                            Text("\(settings.quickAskHotkeyDisplayString) で呼び出すAIクイック質問（英単語スペル、計算、要約質問等）で使用する会話モデルです。推敲モデルとは独立して選択できます。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        // 1. プロバイダー選択
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("会話プロバイダー:")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("使用中: \(settings.effectiveQuickAskProviderDisplayName)")
                                    .font(.caption)
                                    .foregroundColor(.purple)
                            }

                            Picker("", selection: $settings.quickAskProviderMode) {
                                Text("推敲モデルと同一 (\(settings.effectiveLLMProviderDisplayName))").tag(QuickAskProviderMode.sameAsLLM)
                                Text("音声認識と同一 (\(currentProvider.displayName))").tag(QuickAskProviderMode.sameAsSpeech)
                                Text("Groq (クラウド高速・会話)").tag(QuickAskProviderMode.groq)
                                Text("OpenAI (クラウド高品質・会話)").tag(QuickAskProviderMode.openai)
                                Text("カスタム (ローカルLLM / 互換URL)").tag(QuickAskProviderMode.custom)
                            }
                            .pickerStyle(.menu)
                        }

                        // 2. モード別の詳細設定
                        switch settings.quickAskProviderMode {
                        case .sameAsLLM:
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                Text("推敲設定で選択されているプロバイダー（\(settings.effectiveLLMProviderDisplayName)）およびモデル（\(settings.currentLLMModelName)）が自動適用されます。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))

                        case .sameAsSpeech:
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                Text("音声認識プロバイダー（\(currentProvider.displayName)）の設定が適用されます。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))

                        case .groq:
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Groq 会話モデル名:")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Text("現在: \(settings.groqQuickAskModel)")
                                        .font(.caption)
                                        .foregroundColor(.purple)
                                }

                                InputFieldBox {
                                    Image(systemName: "bubble.left.fill")
                                        .foregroundColor(.purple)
                                        .font(.system(size: 13))
                                } content: {
                                    TextField("例: llama-3.3-70b-versatile", text: $settings.groqQuickAskModel)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 12.5, design: .monospaced))
                                } trailing: {
                                    if !settings.groqQuickAskModel.isEmpty {
                                        Button(action: { settings.groqQuickAskModel = "" }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                                .font(.system(size: 13))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                HStack(spacing: 6) {
                                    Image(systemName: "hand.tap.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                    Text("候補:")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)

                                    Button("llama-3.3-70b-versatile (賢い・おすすめ)") {
                                        settings.groqQuickAskModel = "llama-3.3-70b-versatile"
                                    }
                                    .buttonStyle(.bordered).controlSize(.mini)

                                    Button("llama-3.1-8b-instant (最速)") {
                                        settings.groqQuickAskModel = "llama-3.1-8b-instant"
                                    }
                                    .buttonStyle(.bordered).controlSize(.mini)
                                }
                            }

                        case .openai:
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("OpenAI 会話モデル名:")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Text("現在: \(settings.openAIQuickAskModel)")
                                        .font(.caption)
                                        .foregroundColor(.purple)
                                }

                                InputFieldBox {
                                    Image(systemName: "bubble.left.fill")
                                        .foregroundColor(.purple)
                                        .font(.system(size: 13))
                                } content: {
                                    TextField("例: gpt-4o-mini", text: $settings.openAIQuickAskModel)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 12.5, design: .monospaced))
                                } trailing: {
                                    if !settings.openAIQuickAskModel.isEmpty {
                                        Button(action: { settings.openAIQuickAskModel = "" }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                                .font(.system(size: 13))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                HStack(spacing: 6) {
                                    Image(systemName: "hand.tap.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                    Text("候補:")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)

                                    Button("gpt-4o-mini (高速・安価・おすすめ)") {
                                        settings.openAIQuickAskModel = "gpt-4o-mini"
                                    }
                                    .buttonStyle(.bordered).controlSize(.mini)

                                    Button("gpt-4o (最高知能)") {
                                        settings.openAIQuickAskModel = "gpt-4o"
                                    }
                                    .buttonStyle(.bordered).controlSize(.mini)
                                }
                            }

                        case .custom:
                            VStack(alignment: .leading, spacing: 10) {
                                // Base URL
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("カスタム会話 Base URL:")
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        Spacer()
                                        Text("OpenAI互換 (/chat/completions)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    InputFieldBox {
                                        Image(systemName: "network")
                                            .foregroundColor(.purple)
                                            .font(.system(size: 13))
                                    } content: {
                                        TextField("http://localhost:11434/v1", text: $settings.customQuickAskBaseURL)
                                            .textFieldStyle(.plain)
                                            .font(.system(size: 12, design: .monospaced))
                                    } trailing: {
                                        if !settings.customQuickAskBaseURL.isEmpty {
                                            Button(action: { settings.customQuickAskBaseURL = "" }) {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundColor(.secondary)
                                                    .font(.system(size: 13))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }

                                    HStack(spacing: 6) {
                                        Image(systemName: "hand.tap.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        Text("プリセット:")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)

                                        Button("Sarashina") {
                                            settings.customQuickAskBaseURL = "https://api.sarashina.ai/v1"
                                            settings.customQuickAskModel = "sarashina3-mini"
                                        }
                                        .buttonStyle(.bordered).controlSize(.mini)

                                        Button("Ollama (11434)") {
                                            settings.customQuickAskBaseURL = "http://localhost:11434/v1"
                                        }
                                        .buttonStyle(.bordered).controlSize(.mini)

                                        Button("LM Studio (1234)") {
                                            settings.customQuickAskBaseURL = "http://localhost:1234/v1"
                                        }
                                        .buttonStyle(.bordered).controlSize(.mini)
                                    }
                                }

                                // モデル名
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("カスタム会話モデル名:")
                                        .font(.subheadline)
                                        .fontWeight(.medium)

                                    InputFieldBox {
                                        Image(systemName: "bubble.left.fill")
                                            .foregroundColor(.purple)
                                            .font(.system(size: 13))
                                    } content: {
                                        TextField("例: llama3.2, qwen2.5, sarashina3-mini など", text: $settings.customQuickAskModel)
                                            .textFieldStyle(.plain)
                                            .font(.system(size: 12.5, design: .monospaced))
                                    } trailing: {
                                        if !settings.customQuickAskModel.isEmpty {
                                            Button(action: { settings.customQuickAskModel = "" }) {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundColor(.secondary)
                                                    .font(.system(size: 13))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }

                                    HStack(spacing: 6) {
                                        Image(systemName: "hand.tap.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        Text("プリセット:")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)

                                        Button("llama3.2") { settings.customQuickAskModel = "llama3.2" }
                                            .buttonStyle(.bordered).controlSize(.mini)
                                        Button("qwen2.5:7b") { settings.customQuickAskModel = "qwen2.5:7b" }
                                            .buttonStyle(.bordered).controlSize(.mini)
                                        Button("sarashina3-mini") { settings.customQuickAskModel = "sarashina3-mini" }
                                            .buttonStyle(.bordered).controlSize(.mini)
                                    }
                                }
                            }
                        }

                        // 疎通テストボタン
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Button(action: {
                                    Task {
                                        await vm.testQuickAskConnection(settings: settings)
                                    }
                                }) {
                                    HStack(spacing: 5) {
                                        if vm.isTestingQuickAsk {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Image(systemName: "paperplane.fill")
                                        }
                                        Text(vm.isTestingQuickAsk ? "AI質問テスト中..." : "AI会話の疎通テスト")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(vm.isTestingQuickAsk)

                                if let result = vm.testQuickAskResult {
                                    Text(result)
                                        .font(.caption)
                                        .foregroundColor(vm.testQuickAskIsError ? .red : .green)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1)
                )

            }
            .padding(18)
        }
        .onAppear {
            updateKeyStatus()
        }
        .onChange(of: settings.selectedProvider) { _ in
            updateKeyStatus()
        }
        .onChange(of: settings.userLLMBaseURL) { _ in
            vm.updateLLMKeyStatus(settings: settings)
        }
    }

    private func updateKeyStatus() {
        vm.updateKeyStatus(currentProvider: currentProvider)
    }

    private func toggleKeyVisibility() {
        vm.toggleKeyVisibility(currentProvider: currentProvider)
    }

    private func saveAPIKey() {
        vm.saveAPIKey(currentProvider: currentProvider)
    }

    private func deleteAPIKey() {
        vm.deleteAPIKey(currentProvider: currentProvider)
    }
}

/// 視覚的に直感的な入力エリアコンテナ
private struct InputFieldBox<Leading: View, Content: View, Trailing: View>: View {
    let isWarning: Bool
    let leading: Leading
    let content: Content
    let trailing: Trailing

    init(
        isWarning: Bool = false,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.isWarning = isWarning
        self.leading = leading()
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            leading
                .frame(width: 18)

            content

            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isWarning ? Color.orange : Color(NSColor.separatorColor).opacity(0.85),
                    lineWidth: isWarning ? 1.5 : 1
                )
        )
    }
}
