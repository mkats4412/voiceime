import SwiftUI
import Carbon

public struct ShortcutSettingsTab: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var appState = AppState.shared
    @ObservedObject var launchAtLogin = LaunchAtLoginService.shared
    @ObservedObject var micTester = MicrophoneLevelTester.shared

    public struct ShortcutPreset: Identifiable {
        public let id = UUID()
        public let name: String
        public let display: String
        public let keyCode: UInt32
        public let modifiers: UInt32
    }

    private let presets: [ShortcutPreset] = [
        ShortcutPreset(name: "Ctrl + Space (推奨)", display: "⌃Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey)),
        ShortcutPreset(name: "Cmd + Shift + R", display: "⌘⇧R", keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | shiftKey)),
        ShortcutPreset(name: "Ctrl + Option + Space", display: "⌃⌥Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)),
        ShortcutPreset(name: "Cmd + Shift + Space", display: "⌘⇧Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey)),
        ShortcutPreset(name: "Option + Space", display: "⌥Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)),
        ShortcutPreset(name: "Cmd + Shift + D", display: "⌘⇧D", keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | shiftKey)),
    ]

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                // セクション0: システム起動設定 (自動起動)
                VStack(alignment: .leading, spacing: 10) {
                    Text("システム自動起動")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center) {
                            Toggle(isOn: Binding(
                                get: { launchAtLogin.isEnabled },
                                set: { launchAtLogin.setEnabled($0) }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Mac 起動時に自動起動する (ログイン項目)")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("Mac にログインした際、VoiceIME をバックグラウンドで自動起動してメニューバーに常駐させます。")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            Button("システム設定を開く...") {
                                launchAtLogin.openLoginItemsSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        if launchAtLogin.hasError, let error = launchAtLogin.errorMessage {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                                Text(error)
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                }

                Divider()

                // セクション1: ショートカット設定
                VStack(alignment: .leading, spacing: 14) {
                    Text("グローバルショートカット")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("音声入力起動ショートカット")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Text("どのアプリを使っていても、このキー操作で即座に音声入力を呼び出せます。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Text(settings.hotkeyDisplayString)
                                .font(.system(.title3, design: .monospaced))
                                .fontWeight(.bold)
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.accentColor.opacity(0.12))
                                )
                        }

                        HStack {
                            Text("キーの選択:")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Picker("", selection: Binding(
                                get: { settings.hotkeyDisplayString },
                                set: { newDisplay in
                                    if let preset = presets.first(where: { $0.display == newDisplay }) {
                                        appState.updateHotkey(
                                            keyCode: preset.keyCode,
                                            modifiers: preset.modifiers,
                                            displayString: preset.display
                                        )
                                    }
                                }
                            )) {
                                ForEach(presets) { preset in
                                    Text("\(preset.name) (\(preset.display))").tag(preset.display)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )

                    // 録音・入力のトリガー動作 (Push-to-Talk vs Toggle)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("録音・入力の動作モード:")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Picker("", selection: $settings.triggerMode) {
                            Text("長押し入力 (離すと自動出力)").tag(TriggerMode.pushToTalk)
                            Text("トグル (1回で開始、もう1回で停止)").tag(TriggerMode.toggle)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if settings.triggerMode == .pushToTalk {
                            Text("【推奨】キーを押している間だけ話します。キーを離した瞬間に自動で文字起こし・AI推敲され、カーソル位置に入力されます。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("1回キーを押して録音を開始し、話し終わったらもう一度押して文字起こし・AI推敲・入力します。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Divider()

                // セクション2: 音声入力しきい値 (小さな音の除外 / ノイズゲート)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("音声入力しきい値 (ノイズゲート)")
                            .font(.headline)
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $settings.audioThresholdEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("小さな音を自動除外する (声の音量のみ入力)")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("打鍵音・呼吸音・周囲の雑音などの小さな音を拾わず、一定以上の音量で発話された音声のみを入力対象にします。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        if settings.audioThresholdEnabled {
                            Divider()

                            // 感度プリセット & スライダー
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("最小入力音量しきい値:")
                                        .font(.subheadline)
                                        .fontWeight(.medium)

                                    Spacer()

                                    Text(String(format: "%.0f dB", settings.audioThresholdDB))
                                        .font(.system(.subheadline, design: .monospaced))
                                        .fontWeight(.semibold)
                                        .foregroundColor(.accentColor)
                                }

                                HStack(spacing: 8) {
                                    ForEach(AudioSensitivityPreset.allCases) { preset in
                                        Button(action: {
                                            settings.audioThresholdDB = preset.thresholdDB
                                            micTester.updateThreshold(preset.thresholdDB)
                                        }) {
                                            Text(preset.title)
                                                .font(.system(size: 11, weight: abs(settings.audioThresholdDB - preset.thresholdDB) < 0.5 ? .bold : .regular))
                                                .foregroundColor(abs(settings.audioThresholdDB - preset.thresholdDB) < 0.5 ? .accentColor : .primary)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 5)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .fill(abs(settings.audioThresholdDB - preset.thresholdDB) < 0.5 ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .stroke(abs(settings.audioThresholdDB - preset.thresholdDB) < 0.5 ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                Slider(
                                    value: Binding(
                                        get: { settings.audioThresholdDB },
                                        set: { val in
                                            settings.audioThresholdDB = val
                                            micTester.updateThreshold(val)
                                        }
                                    ),
                                    in: -50.0...(-15.0),
                                    step: 1.0
                                ) {
                                    Text("しきい値")
                                } minimumValueLabel: {
                                    Text("-50dB (低)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                } maximumValueLabel: {
                                    Text("-15dB (高)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                Text("※ しきい値より小さな音（打鍵音や雑音）は文字起こしされず、自動的に無視されます。")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Divider()

                            // 無音・打鍵音トリミング
                            Toggle(isOn: $settings.audioTrimmingEnabled) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("発話前後の微小音・打鍵音を自動カット")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("キーを押した瞬間や離した瞬間の音、息継ぎを除去し、声の部分だけを文字起こしします。")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Divider()

                            // リアルタイムマイクテスト & レベルメーター
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("マイク入力レベルテスト")
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                        Text("声を出したりキーボードを叩いて、現在の音量としきい値を確認できます。")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    Button(action: {
                                        if micTester.isTesting {
                                            micTester.stopTesting()
                                        } else {
                                            micTester.startTesting(thresholdDB: settings.audioThresholdDB)
                                        }
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: micTester.isTesting ? "stop.fill" : "play.fill")
                                            Text(micTester.isTesting ? "テスト停止" : "テスト開始")
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(micTester.isTesting ? .red : .accentColor)
                                    .controlSize(.small)
                                }

                                // レベルメーターバー
                                AudioLevelMeterView(
                                    currentDB: micTester.currentLevelDB,
                                    thresholdDB: settings.audioThresholdDB,
                                    isTesting: micTester.isTesting
                                )

                                if micTester.isTesting {
                                    HStack {
                                        if micTester.isSpeechDetected {
                                            Label("声として検知中 (音声入力対象)", systemImage: "checkmark.circle.fill")
                                                .font(.caption)
                                                .foregroundColor(.green)
                                        } else {
                                            Label("小さな音 (除外対象)", systemImage: "speaker.slash.fill")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Text(String(format: "現在: %.0f dB", micTester.currentLevelDB))
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                }

                                if let error = micTester.errorMessage {
                                    Text(error)
                                        .font(.caption2)
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                }

                Divider()

                // セクション3: 入力モード & 音声言語
                VStack(alignment: .leading, spacing: 10) {
                    Text("入力モード & 音声言語")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 12) {
                        // 動作モード選択
                        VStack(alignment: .leading, spacing: 6) {
                            Text("動作モード:")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Picker("", selection: $settings.apiMode) {
                                Text("文字起こし (通常入力)").tag(SpeechAPIMode.transcriptions)
                                Text("英語翻訳 (日本語音声→英文入力)").tag(SpeechAPIMode.translations)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            if settings.apiMode == .transcriptions {
                                Text("発話した言語のままテキスト化します（通常の音声入力はこちら）。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("日本語などの音声を自動的に「英語」へ翻訳してテキスト入力します。")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                    Text("※ Groq利用時、翻訳機能は翻訳対応モデル (whisper-large-v3) で自動実行されます。")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        // 音声言語設定 (文字起こしモード時のみ)
                        if settings.apiMode == .transcriptions {
                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                Text("音声言語:")
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                HStack(spacing: 8) {
                                    Button(action: { settings.language = "" }) {
                                        Text("自動判別 (日英両用)")
                                            .font(.system(size: 11, weight: settings.language.isEmpty ? .bold : .regular))
                                            .foregroundColor(settings.language.isEmpty ? .accentColor : .primary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .fill(settings.language.isEmpty ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(settings.language.isEmpty ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: { settings.language = "ja" }) {
                                        Text("日本語 (ja)")
                                            .font(.system(size: 11, weight: settings.language == "ja" ? .bold : .regular))
                                            .foregroundColor(settings.language == "ja" ? .accentColor : .primary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .fill(settings.language == "ja" ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(settings.language == "ja" ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: { settings.language = "en" }) {
                                        Text("英語 (en)")
                                            .font(.system(size: 11, weight: settings.language == "en" ? .bold : .regular))
                                            .foregroundColor(settings.language == "en" ? .accentColor : .primary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .fill(settings.language == "en" ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(settings.language == "en" ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)

                                    TextField("コード", text: $settings.language)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 55)
                                }

                                Text(settings.language.isEmpty
                                     ? "話した言語（英語または日本語など）を自動検知してテキスト化します。"
                                     : (settings.language == "en" ? "英語専用モードです。話した英語がそのまま英文で出力されます。" : "日本語固定モードです（英語を話すと日本語に自動翻訳されます）。"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                }

                Divider()

                // セクション3: クリップボード・入力動作
                VStack(alignment: .leading, spacing: 10) {
                    Text("クリップボード・入力動作")
                        .font(.headline)

                    Toggle(isOn: $settings.restoreClipboard) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ペースト後にクリップボード内容を元に戻す")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("一時的にペーストに使用したクリップボードを直前の内容に復元します。普段のコピーデータが保持されます。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // 履歴除外保護カード
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "shield.checkered")
                            .font(.title3)
                            .foregroundColor(.green)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("クリップボード履歴ツールへの除外保護が有効です")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("自動ペースト時に org.nspasteboard.TransientType および org.nspasteboard.ConcealedType が付与されるため、Alfred、Raycast、Maccy、Clipy などの履歴管理アプリに音声入力テキストが記録されません。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.green.opacity(0.08))
                    )
                }
            }
            .padding(18)
        }
        .onDisappear {
            micTester.stopTesting()
        }
    }
}

/// リアルタイムマイク音量メーターとしきい値表示ビュー
public struct AudioLevelMeterView: View {
    let currentDB: Float
    let thresholdDB: Float
    let isTesting: Bool

    // -60 dB ... 0 dB の範囲を 0.0 ... 1.0 に正規化
    private func normalize(db: Float) -> CGFloat {
        let clamped = max(-60.0, min(0.0, db))
        return CGFloat((clamped + 60.0) / 60.0)
    }

    public var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let currentNorm = isTesting ? normalize(db: currentDB) : 0.0
                let thresholdNorm = normalize(db: thresholdDB)
                let isSpeech = isTesting && (currentDB >= thresholdDB)

                ZStack(alignment: .leading) {
                    // 背景トラック
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.separatorColor).opacity(0.3))
                        .frame(height: 14)

                    // 音量バー（現在値）
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: isSpeech
                                    ? [Color.green.opacity(0.8), Color.green]
                                    : [Color.secondary.opacity(0.3), Color.secondary.opacity(0.5)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, width * currentNorm), height: 14)
                        .animation(.linear(duration: 0.06), value: currentDB)

                    // しきい値境界線（マーカー）
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: 2, height: 18)
                        .offset(x: max(0, min(width - 2, width * thresholdNorm - 1)))
                        .overlay(
                            Image(systemName: "arrowtriangle.down.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.orange)
                                .offset(x: max(0, min(width - 2, width * thresholdNorm - 1)), y: -12),
                            alignment: .topLeading
                        )
                }
            }
            .frame(height: 22)
            .padding(.top, 6)

            // 目盛りラベル
            HStack {
                Text("-60dB")
                Spacer()
                Text("-40dB")
                Spacer()
                Text("しきい値 (\(Int(thresholdDB))dB)")
                    .foregroundColor(.orange)
                    .fontWeight(.medium)
                Spacer()
                Text("-10dB")
                Spacer()
                Text("0dB")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

