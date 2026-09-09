import SwiftUI

public struct DictionarySettingsTab: View {
    @ObservedObject var settings = AppSettings.shared

    // 単語登録用
    @State private var newWordInput: String = ""

    // 置換ルール用
    @State private var newPattern: String = ""
    @State private var newReplacement: String = ""
    @State private var newIsRegex: Bool = false
    @State private var testInput: String = "人気のアニソンを聴きます。郵便番号1000001改行よろしくお願いいたします。"
    private let dictionary = DictionaryService.shared

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // ==========================================
                // セクション1: 読み不要のAI単語登録
                // ==========================================
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "tag.fill")
                            .foregroundColor(.accentColor)
                            .font(.system(size: 14))
                        Text("単語登録 (読みの入力は不要)")
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

                    Text("人名・社名・製品名・専門用語などを登録しておくと、AIが聞き間違いを防ぎ、最初から正しいスペルや漢字で入力されます。（※「読みがな」を教える必要はありません。カンマや改行区切りで複数の一括追加も可能です）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // 単語追加フォーム
                    HStack(spacing: 8) {
                        TextField("単語を入力 (例: VoiceIME, Kubernetes, 齋藤)...", text: $newWordInput)
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
                                        .font(.system(size: 24))
                                        .foregroundColor(.secondary.opacity(0.6))
                                    Text("登録されている単語はありません。\n上のフォームからよく使う用語を追加してください。")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .padding(.vertical, 20)
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
                            .frame(minHeight: 70, maxHeight: 120)
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
                // セクション2: 自動テキスト置換ルール
                // ==========================================
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundColor(.orange)
                                    .font(.system(size: 14))
                                Text("自動テキスト置換ルール (特殊な置換・コマンド)")
                                    .font(.headline)
                            }
                            Text("音声入力完了後、略称を正式名称に展開したり、改行などのコマンドに強制変換します。\n(例: \"アニソン\" ➔ \"アニメソング\"、\"(改行|かいぎょう)\" ➔ \"\\n\")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("初期ルールに戻す") {
                            settings.resetDictionaryRules()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    // 登録済みルール一覧
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("登録ルール一覧 (\(settings.dictionaryRules.count)件):")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                        }

                        ScrollView {
                            if settings.dictionaryRules.isEmpty {
                                Text("置換ルールが登録されていません。下のフォームから追加してください。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 110)
                            } else {
                                VStack(spacing: 6) {
                                    ForEach($settings.dictionaryRules) { $rule in
                                        HStack(spacing: 8) {
                                            Toggle("", isOn: $rule.isEnabled)
                                                .labelsHidden()
                                                .help("有効/無効の切り替え")

                                            TextField("置換前", text: $rule.pattern)
                                                .textFieldStyle(.roundedBorder)
                                                .frame(maxWidth: 150)

                                            Image(systemName: "arrow.right")
                                                .foregroundColor(.secondary)
                                                .font(.caption)

                                            TextField("置換後 (\\nで改行)", text: $rule.replacement)
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
                        .frame(height: 130)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                    }

                    // 新規ルール追加フォーム
                    VStack(alignment: .leading, spacing: 6) {
                        Text("新しいルールを追加:")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        HStack(spacing: 8) {
                            TextField("置換前 (例: アニソン)", text: $newPattern)
                                .textFieldStyle(.roundedBorder)

                            Image(systemName: "arrow.right")
                                .foregroundColor(.secondary)
                                .font(.caption)

                            TextField("置換後 (例: アニメソング, \\nで改行)", text: $newReplacement)
                                .textFieldStyle(.roundedBorder)

                            Toggle("正規表現", isOn: $newIsRegex)
                                .toggleStyle(.checkbox)
                                .font(.caption)

                            Button("追加") {
                                addRule()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(newPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    // リアルタイム置換テスト
                    VStack(alignment: .leading, spacing: 6) {
                        Text("リアルタイム置換プレビュー:")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        TextField("テスト入力テキスト", text: $testInput)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private var testOutput: String {
        dictionary.apply(
            text: testInput,
            rules: settings.dictionaryRules
        )
    }

    private func addWord() {
        let trimmed = newWordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.addVocabularyWord(trimmed)
        newWordInput = ""
    }

    private func addRule() {
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

    private func deleteRule(id: UUID) {
        settings.dictionaryRules.removeAll { $0.id == id }
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
