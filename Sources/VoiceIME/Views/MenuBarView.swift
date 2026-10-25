import SwiftUI

public struct MenuBarView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var audioDevices = AudioDeviceService.shared

    var openSettingsAction: () -> Void
    var quitAction: () -> Void

    public init(openSettingsAction: @escaping () -> Void, quitAction: @escaping () -> Void) {
        self.openSettingsAction = openSettingsAction
        self.quitAction = quitAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // 1. ステータスヘッダー
            HStack(spacing: 6) {
                statusIndicator
                Text(appState.statusMessage)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()

                // プロバイダ状態バッジ
                HStack(spacing: 4) {
                    Circle()
                        .fill(providerColor(for: settings.selectedProvider))
                        .frame(width: 5, height: 5)
                    Text(settings.selectedProvider.displayName)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 1)

            // 2. 録音トグルボタン
            Button(action: {
                appState.toggleRecording()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: appState.phase == .recording ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size: 13))
                    Text(appState.phase == .recording ? "録音を停止" : "音声入力を開始")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text(settings.hotkeyDisplayString)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(appState.phase == .recording ? .white.opacity(0.85) : .secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
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

            // 3. クイック設定カード（マイク・言語・推敲を美しくグルーピング）
            VStack(spacing: 8) {
                // A. マイク選択
                HStack(spacing: 6) {
                    Image(systemName: audioDevices.isFallbackActive ? "exclamationmark.triangle.fill" : "mic.fill")
                        .foregroundColor(audioDevices.isFallbackActive ? .orange : .secondary)
                        .font(.system(size: 11))
                        .frame(width: 14)

                    Text("マイク")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Spacer()

                    Menu {
                        let defaultName = audioDevices.systemDefaultDevice?.name ?? "未検出"
                        Button(action: {
                            audioDevices.selectDevice(uid: "", name: "システムデフォルト")
                        }) {
                            HStack {
                                Text("システムデフォルト (\(defaultName))")
                                if settings.selectedAudioDeviceUID.isEmpty || settings.selectedAudioDeviceUID == "default" {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }

                        Divider()

                        ForEach(audioDevices.availableDevices) { device in
                            Button(action: {
                                audioDevices.selectDevice(uid: device.id, name: device.name)
                            }) {
                                HStack {
                                    Text(device.name + (device.isSystemDefault ? " (システム既定)" : ""))
                                    if settings.selectedAudioDeviceUID == device.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }

                        Divider()

                        Button(action: {
                            audioDevices.refreshDevices()
                        }) {
                            Label("マイク一覧を更新", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(audioDevices.effectiveDeviceName)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(audioDevices.isFallbackActive ? .orange : .primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(audioDevices.isFallbackActive ? Color.orange.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .help("入力マイクを選択（クリックで切替）")
                }

                if audioDevices.isFallbackActive {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 9))
                        Text("「\(settings.selectedAudioDeviceName)」未検出 ➔ 代替入力中")
                            .font(.system(size: 9.5))
                            .foregroundColor(.orange)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Divider().opacity(0.4)

                // B. 言語切替
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                        .frame(width: 14)

                    Text("言語")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Spacer()

                    HStack(spacing: 3) {
                        pillButton(title: "自動", isSelected: settings.language.isEmpty) {
                            settings.language = ""
                            settings.apiMode = .transcriptions
                        }
                        pillButton(title: "日本語", isSelected: settings.language == "ja") {
                            settings.language = "ja"
                        }
                        pillButton(title: "英語", isSelected: settings.language == "en") {
                            settings.language = "en"
                            settings.apiMode = .transcriptions
                        }
                    }
                }

                // 日本語選択時のみ通常/英文翻訳モードを表示
                if settings.language == "ja" {
                    HStack(spacing: 6) {
                        Text("翻訳")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.leading, 20)

                        Spacer()

                        HStack(spacing: 3) {
                            pillButton(title: "通常入力", isSelected: settings.apiMode == .transcriptions) {
                                settings.apiMode = .transcriptions
                            }
                            pillButton(title: "英語翻訳", isSelected: settings.apiMode == .translations) {
                                settings.apiMode = .translations
                            }
                        }
                    }
                }

                Divider().opacity(0.4)

                // C. AI推敲切替（OFF / 口語 / 文章 のすっきり3択ピッカー）
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .foregroundColor(settings.isLLMRefinementActive ? .accentColor : .secondary)
                            .font(.system(size: 11))
                            .frame(width: 14)

                        Text("推敲")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Spacer()

                        HStack(spacing: 3) {
                            pillButton(title: "OFF", isSelected: !settings.llmRefinementEnabled) {
                                settings.llmRefinementEnabled = false
                            }
                            pillButton(title: "口語", isSelected: settings.llmRefinementEnabled && settings.refinementStyle == .casual) {
                                settings.llmRefinementEnabled = true
                                settings.refinementStyle = .casual
                            }
                            pillButton(title: "文章", isSelected: settings.llmRefinementEnabled && settings.refinementStyle == .formal) {
                                settings.llmRefinementEnabled = true
                                settings.refinementStyle = .formal
                            }
                        }
                    }

                    if settings.isLLMRefinementActive {
                        HStack(spacing: 4) {
                            Spacer()
                            Circle()
                                .fill(providerColor(for: settings.resolvedLLMProvider))
                                .frame(width: 4.5, height: 4.5)
                            Text("\(settings.resolvedLLMProvider.displayName): \(settings.effectiveLLMConfig.modelName)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.top, 1)
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
            )

            // 4. 直前の書き起こしプレビューカード（存在時のみスマートに表示）
            if !appState.lastProcessedText.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("直前の入力")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.secondary)

                        if let provider = appState.lastEffectiveProvider {
                            let pColor = providerColor(for: provider)
                            Text(provider.displayName)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(pColor)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(pColor.opacity(0.12))
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
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(appState.isRecentTextCopied ? Color.green.opacity(0.15) : Color.accentColor.opacity(0.10))
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
                            .foregroundColor(.primary)
                            .lineLimit(3)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(NSColor.textBackgroundColor).opacity(0.35))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("クリックでクリップボードにコピー")
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
                )
            }

            // 5. 直近の障害回避・フォールバック警告（Groq等の失敗理由を可視化）
            if let fallback = appState.lastFallbackRecord {
                VStack(alignment: .leading, spacing: 4) {
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
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.primary)

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
            }

            if let error = appState.errorMessage {
                VStack(alignment: .leading, spacing: 5) {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .lineLimit(3)

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
            }

            Divider()
                .padding(.vertical, 1)

            // 6. 設定・終了
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
        .frame(width: 248)
    }

    /// クイック設定用のピル型ボタン
    private func pillButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: isSelected ? .bold : .regular))
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 4.5)
                        .fill(isSelected ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                )
        }
        .buttonStyle(.plain)
    }

    private func providerColor(for provider: APIProvider) -> Color {
        switch provider {
        case .groq: return .orange
        case .openai: return .green
        case .sarashina: return .pink
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
