import SwiftUI

public struct APISettingsTab: View {
    @ObservedObject var settings = AppSettings.shared
    private let keychain = KeychainService.shared
    private let apiService = WhisperAPIService.shared
    private let llmService = LLMService.shared

    @State private var apiKeyInput: String = ""
    @State private var isKeyVisible: Bool = false
    @State private var saveMessage: String? = nil
    @State private var hasKeyStored: Bool = false
    @State private var groqHasKey: Bool = false
    @State private var openAIHasKey: Bool = false

    private let maskText = "••••••••••••••••••••••••••••••••"

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
                }
            }
        )
    }

    /// プロバイダごとのLLMモデル名バインディング
    private var llmModelNameBinding: Binding<String> {
        Binding(
            get: { settings.currentLLMModelName },
            set: { newValue in
                switch settings.selectedProvider {
                case .groq: settings.groqLLMModel = newValue
                case .openai: settings.openAILLMModel = newValue
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
                // セクション0: プロバイダー選択 & バックアップ
                // ==========================================
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("プロバイダー選択", systemImage: "cpu")
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
                        let backupModel = settings.config(for: backup).modelName
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "arrow.triangle.swap")
                                .foregroundColor(.blue)
                                .font(.caption)
                            Text("相互バックアップ有効: \(currentProvider.displayName) 障害時は \(backup.displayName) (\(backupModel)) で自動再試行")
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
                                    TextField(hasKeyStored ? "新しいキーを入力して上書き保存" : "\(currentProvider.displayName) APIキーを入力 (gsk_... / sk-...)", text: $apiKeyInput)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 12.5, design: .monospaced))
                                } else {
                                    SecureField(hasKeyStored ? "新しいキーを入力して上書き保存" : "\(currentProvider.displayName) APIキーを入力 (gsk_... / sk-...)", text: $apiKeyInput)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 12.5, design: .monospaced))
                                }
                            } trailing: {
                                HStack(spacing: 6) {
                                    if !apiKeyInput.isEmpty && apiKeyInput != maskText {
                                        Button(action: { apiKeyInput = "" }) {
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
                            Text("※ キーはmacOSの安全なKeychainに保管されています。変更したい場合は上から新しいキーを入力して「保存」を押してください。")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else {
                            Text("※ 音声認識を使用するには、上記の入力エリアに \(currentProvider.displayName) のAPIキーを入力して「保存」をクリックしてください。")
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
                // セクション2: AI（LLM）推敲・文脈理解
                // ==========================================
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Label("AI（LLM）推敲・文脈理解", systemImage: "sparkles")
                                    .font(.headline)
                                Text("おすすめ")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.blue.opacity(0.12))
                                    .cornerRadius(4)
                            }
                            Text("音声認識結果の意味を理解し、「えーっと」などのフィラーを除去して自然な句読点（、。？！）を補完します。")
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
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("推敲モデル名:")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("[自由入力・変更可]")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("現在: \(settings.currentLLMModelName)")
                                    .font(.caption)
                                    .foregroundColor(.accentColor)
                            }

                            InputFieldBox {
                                Image(systemName: "brain")
                                    .foregroundColor(.purple)
                                    .font(.system(size: 13))
                            } content: {
                                TextField("モデルIDを入力（例: qwen/qwen3.8-27b, gpt-4o-mini など）", text: llmModelNameBinding)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12.5, design: .monospaced))
                            } trailing: {
                                if !llmModelNameBinding.wrappedValue.isEmpty {
                                    Button(action: { llmModelNameBinding.wrappedValue = "" }) {
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
                                    Button("qwen/qwen3.8-27b") {
                                        settings.groqLLMModel = "qwen/qwen3.8-27b"
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)

                                    Button("openai/gpt-oss-20b") {
                                        settings.groqLLMModel = "openai/gpt-oss-20b"
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                } else {
                                    Button("gpt-4o-mini") {
                                        settings.openAILLMModel = "gpt-4o-mini"
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }
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
                // セクション3: 音声認識（Whisper）設定
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

                    // 認識プロンプト
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("認識プロンプト (固有名詞ヒント):")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                            Text("「辞書」タブの単語登録と自動連動")
                                .font(.caption2)
                                .foregroundColor(.accentColor)
                        }

                        InputFieldBox {
                            Image(systemName: "text.quote")
                                .foregroundColor(.secondary)
                                .font(.system(size: 13))
                        } content: {
                            TextField("固有名詞や略語のヒント（例: VoiceIME, Kubernetes, ...）", text: $settings.promptHint)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5))
                        } trailing: {
                            if !settings.promptHint.isEmpty {
                                Button(action: { settings.clearVocabulary() }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 13))
                                }
                                .buttonStyle(.plain)
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
    }

    private func updateKeyStatus() {
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
    }

    private func toggleKeyVisibility() {
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

    private func saveAPIKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && trimmed != maskText else { return }

        if keychain.saveAPIKey(trimmed, for: currentProvider) {
            updateKeyStatus()
            AppState.shared.resetError()
            saveMessage = "✓ \(currentProvider.displayName) のAPIキーをKeychainに保存しました"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                saveMessage = nil
            }
        } else {
            saveMessage = "⚠️ 保存に失敗しました"
        }
    }

    private func deleteAPIKey() {
        if keychain.deleteAPIKey(for: currentProvider) {
            updateKeyStatus()
            saveMessage = "\(currentProvider.displayName) のAPIキーを削除しました"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                saveMessage = nil
            }
        }
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
