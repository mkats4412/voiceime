import SwiftUI

@MainActor
public final class DictionarySettingsViewModel: ObservableObject {
    @Published public var newWordInput: String = ""
    @Published public var newPattern: String = ""
    @Published public var newReplacement: String = ""
    @Published public var newIsRegex: Bool = false
    @Published public var testInput: String = "人気のアニソンを聴きます。郵便番号1000001改行よろしくお願いいたします。"

    public init() {}

    public func addWord(settings: AppSettings) {
        let trimmed = newWordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.addVocabularyWord(trimmed)
        newWordInput = ""
    }

    public func addRule(settings: AppSettings) {
        let pattern = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return }

        let rule = DictionaryRule(
            pattern: pattern,
            replacement: newReplacement,
            isRegex: newIsRegex,
            isEnabled: true
        )
        settings.dictionaryRules.append(rule)

        newPattern = ""
        newReplacement = ""
        newIsRegex = false
    }

    public func deleteRule(id: UUID, settings: AppSettings) {
        settings.dictionaryRules.removeAll { $0.id == id }
    }
}

public struct DictionarySettingsTab: View {
    @ObservedObject var settings = AppSettings.shared
    @StateObject private var vm = DictionarySettingsViewModel()

    private var newWordInput: String { vm.newWordInput }
    private var newPattern: String { vm.newPattern }
    private var newReplacement: String { vm.newReplacement }
    private var newIsRegex: Bool { vm.newIsRegex }
    private var testInput: String { vm.testInput }
    // フォーカス状態の管理（フォーカス時にプレースホルダーを非表示にするため）
    private enum FocusField: Hashable {
        case newWord
        case newPattern
        case newReplacement
        case rulePattern(UUID)
        case ruleReplacement(UUID)
        case testInput
    }

    @FocusState private var focusedField: FocusField?

    private let dictionary = DictionaryService.shared

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                // ==========================================
                // ~/.voiceime 外部連携
                // ==========================================
                HStack(spacing: 12) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.title3)
                        .foregroundColor(.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("ローカル同期 (~/.voiceime)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("単語と置換ルールを ~/.voiceime/ とJSON自動同期")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button {
                        VoiceIMEDiskSyncService.shared.openFolderInFinder()
                    } label: {
                        Label("フォルダ", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        settings.reloadFromDisk()
                    } label: {
                        Label("再読込", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
                )

                // ==========================================
                // MCP連携 & AI Agent編集（修正ストック含む）
                // ==========================================
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("MCP連携（AI Agent による辞書・ログ・単語登録へのアクセス）を有効にする", isOn: $settings.mcpAgentEditingEnabled)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    HStack(spacing: 8) {
                        Image(systemName: "cpu")
                            .foregroundColor(.accentColor)
                        Text("ONにすると、外部のAI Agent (Cursor, Claude, Antigravity等) からMCP経由での辞書参照・編集・修正ストック管理が可能になり、修正モードでの '-' キー単語登録や修正差分のストックが有効化されます。OFFにするとMCPからのすべてのツールアクセスが安全に遮断されます。（デフォルト: OFF）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if settings.mcpAgentEditingEnabled {
                        HStack(spacing: 12) {
                            Button(action: {
                                let url = CorrectionStockService.shared.correctionsFileURL
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }) {
                                Label("ストックファイルを表示", systemImage: "doc.text")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button(action: {
                                CorrectionStockService.shared.clearStock()
                            }) {
                                Label("ストックをクリア", systemImage: "trash")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

                // ==========================================
                // セクション1: 単語登録
                // ==========================================
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "tag.fill")
                            .foregroundColor(.accentColor)
                            .font(.system(size: 14))
                        Text("単語登録")
                            .font(.headline)

                        Spacer()

                        if !settings.customVocabulary.isEmpty {
                            Text("\(settings.customVocabulary.count)件")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))

                            Button("すべて削除") {
                                settings.clearVocabulary()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .foregroundColor(.red)
                        }
                    }

                    Text("専門用語や固有名詞を登録（読みがな不要、カンマ区切りで一括追加可）")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // 単語追加フォーム
                    HStack(spacing: 8) {
                        TextField(focusedField == .newWord ? "" : "単語を入力 (例: VoiceIME, Kubernetes)...", text: $vm.newWordInput)
                            .focused($focusedField, equals: .newWord)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                addWord()
                            }

                        Button("追加") {
                            addWord()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newWordInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    // 登録済み単語チップ一覧
                    VStack(alignment: .leading, spacing: 8) {
                        if settings.customVocabulary.isEmpty {
                            HStack {
                                Spacer()
                                VStack(spacing: 4) {
                                    Image(systemName: "text.badge.plus")
                                        .font(.system(size: 20))
                                        .foregroundColor(.secondary.opacity(0.6))
                                    Text("登録されている単語はありません")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 16)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                            )
                        } else {
                            ScrollView {
                                FlowLayout(spacing: 6) {
                                    ForEach(Array(settings.customVocabulary.enumerated()), id: \.offset) { index, word in
                                        VocabularyChipView(word: word) {
                                            settings.removeVocabularyWord(at: index)
                                        }
                                    }
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 60, maxHeight: 110)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

                // ==========================================
                // セクション2: 置換ルール
                // ==========================================
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.orange)
                            .font(.system(size: 14))
                        Text("置換ルール")
                            .font(.headline)

                        Spacer()

                        if !settings.dictionaryRules.isEmpty {
                            Text("\(settings.dictionaryRules.count)件")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }

                        Button("初期化") {
                            settings.resetDictionaryRules()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Text("音声入力後の置換やコマンド変換（例: 改行 ➔ \\n）")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // 置換ルール追加フォーム
                    HStack(spacing: 8) {
                        TextField(focusedField == .newPattern ? "" : "置換前", text: $vm.newPattern)
                            .focused($focusedField, equals: .newPattern)
                            .textFieldStyle(.roundedBorder)

                        Image(systemName: "arrow.right")
                            .foregroundColor(.secondary)
                            .font(.caption)

                        TextField(focusedField == .newReplacement ? "" : "置換後", text: $vm.newReplacement)
                            .focused($focusedField, equals: .newReplacement)
                            .textFieldStyle(.roundedBorder)

                        Toggle("正規表現", isOn: $vm.newIsRegex)
                            .toggleStyle(.checkbox)
                            .font(.caption)

                        Button("追加") {
                            addRule()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    // 登録済みルール一覧
                    ScrollView {
                        if settings.dictionaryRules.isEmpty {
                            Text("置換ルールはありません")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 80)
                        } else {
                            VStack(spacing: 6) {
                                ForEach($settings.dictionaryRules) { $rule in
                                    HStack(spacing: 8) {
                                        Toggle("", isOn: $rule.isEnabled)
                                            .labelsHidden()

                                        TextField(focusedField == .rulePattern(rule.id) ? "" : "置換前", text: $rule.pattern)
                                            .focused($focusedField, equals: .rulePattern(rule.id))
                                            .textFieldStyle(.roundedBorder)
                                            .frame(maxWidth: 150)

                                        Image(systemName: "arrow.right")
                                            .foregroundColor(.secondary)
                                            .font(.caption)

                                        TextField(focusedField == .ruleReplacement(rule.id) ? "" : "置換後", text: $rule.replacement)
                                            .focused($focusedField, equals: .ruleReplacement(rule.id))
                                            .textFieldStyle(.roundedBorder)
                                            .frame(maxWidth: 160)

                                        Toggle("正規表現", isOn: $rule.isRegex)
                                            .toggleStyle(.checkbox)
                                            .font(.caption)

                                        Spacer()

                                        Button(role: .destructive) {
                                            deleteRule(id: rule.id)
                                        } label: {
                                            Image(systemName: "trash")
                                                .foregroundColor(.red)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    .padding(6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color(NSColor.controlBackgroundColor))
                                    )
                                }
                            }
                        }
                    }
                    .frame(height: 120)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )

                    // リアルタイム置換テスト
                    VStack(alignment: .leading, spacing: 6) {
                        Text("テスト入力:")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        TextField(focusedField == .testInput ? "" : "入力してテスト...", text: $vm.testInput)
                            .focused($focusedField, equals: .testInput)
                            .textFieldStyle(.roundedBorder)

                        HStack(alignment: .top, spacing: 6) {
                            Text("結果:")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                            Text(testOutput.isEmpty ? "（空）" : testOutput)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.primary)
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.secondary.opacity(0.1))
                                    )
                        }
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

                Spacer(minLength: 10)
            }
            .padding(18)
        }
        .onAppear {
            settings.reloadPreferencesFromDefaults()
        }
    }

    private var testOutput: String {
        dictionary.apply(
            text: testInput,
            rules: settings.dictionaryRules
        )
    }

    private func addWord() {
        vm.addWord(settings: settings)
    }

    private func addRule() {
        vm.addRule(settings: settings)
    }

    private func deleteRule(id: UUID) {
        vm.deleteRule(id: id, settings: settings)
    }
}

/// 単語チップ表示コンポーネント
private struct VocabularyChipView: View {
    let word: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(word)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("「\(word)」を削除")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
    }
}

/// 単語チップを折り返して並べるレイアウト
@available(macOS 13.0, *)
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
