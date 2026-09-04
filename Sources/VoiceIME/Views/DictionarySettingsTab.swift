import SwiftUI

public struct DictionarySettingsTab: View {
    @ObservedObject var settings = AppSettings.shared

    @State private var newPattern: String = ""
    @State private var newReplacement: String = ""
    @State private var newIsRegex: Bool = false
    @State private var testInput: String = "改行の件ですが、よろしくお願いいたします。"
    private let dictionary = DictionaryService.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // ヘッダー説明
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("カスタム単語置換ルール")
                        .font(.headline)
                    Text("AI推敲後のテキストに対して、独自の専門用語や略称、改行記号などを自動置換します。")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                        Text("ルールが登録されていません。下のフォームから追加してください。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 140)
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
                                        .frame(maxWidth: 150)

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
                .frame(height: 160)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }

            // 新規追加フォーム
            VStack(alignment: .leading, spacing: 6) {
                Text("新しいルールを追加:")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    TextField("置換前の単語", text: $newPattern)
                        .textFieldStyle(.roundedBorder)

                    Image(systemName: "arrow.right")
                        .foregroundColor(.secondary)
                        .font(.caption)

                    TextField("置換後の単語 (\\nで改行)", text: $newReplacement)
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

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var testOutput: String {
        dictionary.apply(
            text: testInput,
            rules: settings.dictionaryRules
        )
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
