import SwiftUI

public struct MenuBarView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var settings = AppSettings.shared

    var openSettingsAction: () -> Void
    var quitAction: () -> Void

    public init(openSettingsAction: @escaping () -> Void, quitAction: @escaping () -> Void) {
        self.openSettingsAction = openSettingsAction
        self.quitAction = quitAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ステータスヘッダー
            HStack(spacing: 6) {
                statusIndicator
                Text(appState.statusMessage)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)

            // 録音トグルボタン
            Button(action: {
                appState.toggleRecording()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: appState.phase == .recording ? "stop.circle.fill" : "mic.fill")
                    Text(appState.phase == .recording ? "録音を停止" : "音声入力を開始")
                        .font(.system(size: 13))
                    Spacer()
                    Text(settings.hotkeyDisplayString)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(appState.phase == .recording ? .white : .secondary)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(appState.phase == .recording ? .red : .accentColor)

            if appState.phase == .recording {
                Button("録音を破棄") {
                    appState.cancelRecording()
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .font(.caption)
                .padding(.horizontal, 4)
            }

            // 言語クイック切り替え
            HStack(spacing: 6) {
                Text("言語:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Button("自動") {
                    settings.language = ""
                    settings.apiMode = .transcriptions
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: (settings.apiMode == .transcriptions && settings.language.isEmpty) ? .bold : .regular))
                .foregroundColor((settings.apiMode == .transcriptions && settings.language.isEmpty) ? .accentColor : .primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill((settings.apiMode == .transcriptions && settings.language.isEmpty) ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                )

                Button("日本語") {
                    settings.language = "ja"
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: settings.language == "ja" ? .bold : .regular))
                .foregroundColor(settings.language == "ja" ? .accentColor : .primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(settings.language == "ja" ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                )

                Button("英語") {
                    settings.language = "en"
                    settings.apiMode = .transcriptions
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: (settings.apiMode == .transcriptions && settings.language == "en") ? .bold : .regular))
                .foregroundColor((settings.apiMode == .transcriptions && settings.language == "en") ? .accentColor : .primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill((settings.apiMode == .transcriptions && settings.language == "en") ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                )

                Spacer()
            }
            .padding(.horizontal, 4)

            // 入力モード切替（日本語選択時に通常入力と英文翻訳を選択可能）
            if settings.language == "ja" {
                HStack(spacing: 6) {
                    Text("モード:")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Button("通常") {
                        settings.apiMode = .transcriptions
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: settings.apiMode == .transcriptions ? .bold : .regular))
                    .foregroundColor(settings.apiMode == .transcriptions ? .accentColor : .primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(settings.apiMode == .transcriptions ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                    )

                    Button("英文翻訳") {
                        settings.apiMode = .translations
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: settings.apiMode == .translations ? .bold : .regular))
                    .foregroundColor(settings.apiMode == .translations ? .accentColor : .primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(settings.apiMode == .translations ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                    )

                    Spacer()
                }
                .padding(.horizontal, 4)
            }

            // 口語モード / 文章モード切替（文字起こし & AI推敲ON時）
            if settings.apiMode == .transcriptions && settings.llmRefinementEnabled {
                HStack(spacing: 6) {
                    Text("推敲:")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Button("口語") {
                        settings.refinementStyle = .casual
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: settings.refinementStyle == .casual ? .bold : .regular))
                    .foregroundColor(settings.refinementStyle == .casual ? .accentColor : .primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(settings.refinementStyle == .casual ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                    )
                    .help("語尾や口語ニュアンスをそのまま維持（チャット・会話向け）")

                    Button("文章") {
                        settings.refinementStyle = .formal
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: settings.refinementStyle == .formal ? .bold : .regular))
                    .foregroundColor(settings.refinementStyle == .formal ? .accentColor : .primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(settings.refinementStyle == .formal ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                    )
                    .help("整った標準的な書き言葉に推敲（メール・報告書向け）")

                    Spacer()
                }
                .padding(.horizontal, 4)
            }

            // 直前の書き起こしプレビュー（存在する場合のみコンパクトに表示）
            if !appState.lastProcessedText.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .center, spacing: 6) {
                        Text("直前の入力:")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)

                        // どちらのLLM/音声認識プロバイダで認識・出力されたかを示すバッジ
                        if let provider = appState.lastEffectiveProvider {
                            let pColor = providerColor(for: provider)
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(pColor)
                                    .frame(width: 5, height: 5)
                                Text("認識: \(provider.displayName)")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(pColor)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(pColor.opacity(0.12))
                            )
                        }

                        Spacer()

                        Button(action: {
                            appState.copyRecentProcessedText()
                        }) {
                            HStack(spacing: 2) {
                                Image(systemName: appState.isRecentTextCopied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 8.5))
                                Text(appState.isRecentTextCopied ? "コピー済" : "コピー")
                                    .font(.system(size: 8.5, weight: .medium))
                            }
                            .foregroundColor(appState.isRecentTextCopied ? .green : .accentColor)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(appState.isRecentTextCopied ? Color.green.opacity(0.15) : Color.accentColor.opacity(0.12))
                            )
                        }
                        .buttonStyle(.plain)
                        .help("クリップボードにコピー")
                    }

                    Button(action: {
                        appState.copyRecentProcessedText()
                    }) {
                        Text(appState.lastProcessedText)
                            .font(.system(size: 11))
                            .lineLimit(3)
                            .padding(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.secondary.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("クリックでクリップボードにコピー")
                }
                .padding(.horizontal, 2)
            }

            // 直近の障害回避・フォールバック警告（Groq等の失敗理由を可視化）
            if let fallback = appState.lastFallbackRecord {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 11))
                        Text("\(fallback.primaryProvider.displayName) \(fallback.step)失敗")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.orange)
                        Spacer()
                        Button(action: {
                            appState.lastFallbackRecord = nil
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                    }

                    Text("理由: \(fallback.reasonSummary)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.primary)

                    Text(fallback.detail)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("➔ \(fallback.backupProvider.displayName) で自動継続しました")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                }
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
                .padding(.horizontal, 2)
            }

            if let error = appState.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Spacer()
                        Button("エラーを解除") {
                            appState.resetError()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
                .padding(6)
                .background(Color.red.opacity(0.08))
                .cornerRadius(6)
                .padding(.horizontal, 2)
            }

            Divider()
                .padding(.vertical, 2)

            // 設定・終了（上が「設定...」、下が「終了」の縦並び）
            VStack(spacing: 2) {
                Button(action: {
                    openSettingsAction()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape")
                            .frame(width: 16)
                        Text("設定...")
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverMenuItemStyle())

                Button(action: {
                    quitAction()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "power")
                            .frame(width: 16)
                        Text("VoiceIME を終了")
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverMenuItemStyle())
            }
        }
        .padding(10)
        .frame(width: 220)
    }

    private func providerColor(for provider: APIProvider) -> Color {
        switch provider {
        case .groq: return .orange
        case .openai: return .green
        case .custom: return .purple
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch appState.phase {
        case .idle:
            Circle().fill(Color.green).frame(width: 8, height: 8)
        case .recording:
            Circle().fill(Color.red).frame(width: 8, height: 8)
        case .transcribing, .refining, .pasting:
            ProgressView().controlSize(.mini)
        case .error:
            Circle().fill(Color.orange).frame(width: 8, height: 8)
        }
    }
}

/// メニュー項目用のボタンスタイル
private struct HoverMenuItemStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isPressed ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.06))
            )
    }
}
