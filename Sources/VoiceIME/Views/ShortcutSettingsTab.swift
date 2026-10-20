import SwiftUI
import Carbon

public struct ShortcutSettingsTab: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var appState = AppState.shared
    @ObservedObject var launchAtLogin = LaunchAtLoginService.shared
    @ObservedObject var micTester = MicrophoneLevelTester.shared
    @ObservedObject var audioDevices = AudioDeviceService.shared

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

    private let quickAskPresets: [ShortcutPreset] = [
        ShortcutPreset(name: "Ctrl + Shift + Space (デフォルト)", display: "⌃⇧Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey)),
        ShortcutPreset(name: "Cmd + Shift + Space", display: "⌘⇧Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey)),
        ShortcutPreset(name: "Ctrl + Option + Space", display: "⌃⌥Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)),
        ShortcutPreset(name: "Cmd + Option + Space", display: "⌘⌥Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey)),
        ShortcutPreset(name: "Option + Space", display: "⌥Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)),
        ShortcutPreset(name: "Ctrl + Shift + Q", display: "⌃⇧Q", keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey | shiftKey)),
    ]

    private let pastePresets: [ShortcutPreset] = [
        ShortcutPreset(name: "Cmd + Enter (デフォルト)", display: "⌘↩", keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey)),
        ShortcutPreset(name: "Enter のみ", display: "↩", keyCode: UInt32(kVK_Return), modifiers: 0),
        ShortcutPreset(name: "Shift + Enter", display: "⇧↩", keyCode: UInt32(kVK_Return), modifiers: UInt32(shiftKey)),
        ShortcutPreset(name: "Ctrl + Enter", display: "⌃↩", keyCode: UInt32(kVK_Return), modifiers: UInt32(controlKey)),
        ShortcutPreset(name: "Option + Enter", display: "⌥↩", keyCode: UInt32(kVK_Return), modifiers: UInt32(optionKey)),
        ShortcutPreset(name: "Cmd + Shift + V", display: "⌘⇧V", keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey)),
    ]

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                // セクション0: システム起動設定 (自動起動)
                VStack(alignment: .leading, spacing: 8) {
                    Text("自動起動")
                        .font(.headline)

                    HStack(alignment: .center) {
                        Toggle("Mac 起動時に自動起動する (ログイン項目)", isOn: Binding(
                            get: { launchAtLogin.isEnabled },
                            set: { launchAtLogin.setEnabled($0) }
                        ))
                        .font(.subheadline)

                        Spacer()

                        Button("システム設定を開く...") {
                            launchAtLogin.openLoginItemsSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )

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

                Divider()

                // セクション1: ショートカット設定
                VStack(alignment: .leading, spacing: 10) {
                    Text("ショートカット")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 12) {
                        // 音声入力起動
                        HStack {
                            Text("音声入力")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Spacer()

                            Text(settings.hotkeyDisplayString)
                                .font(.system(.subheadline, design: .monospaced))
                                .fontWeight(.bold)
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.accentColor.opacity(0.12))
                                )

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
                            .frame(width: 140)
                        }

                        Divider()

                        // クイック質問
                        HStack {
                            HStack(spacing: 6) {
                                Text("クイック質問")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("AI")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.purple)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.purple.opacity(0.12))
                                    .cornerRadius(4)
                            }

                            Spacer()

                            Text(settings.quickAskHotkeyDisplayString)
                                .font(.system(.subheadline, design: .monospaced))
                                .fontWeight(.bold)
                                .foregroundColor(.purple)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.purple.opacity(0.12))
                                )

                            Picker("", selection: Binding(
                                get: { settings.quickAskHotkeyDisplayString },
                                set: { newDisplay in
                                    if let preset = quickAskPresets.first(where: { $0.display == newDisplay }) {
                                        appState.updateQuickAskHotkey(
                                            keyCode: preset.keyCode,
                                            modifiers: preset.modifiers,
                                            displayString: preset.display
                                        )
                                    }
                                }
                            )) {
                                ForEach(quickAskPresets) { preset in
                                    Text("\(preset.name) (\(preset.display))").tag(preset.display)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 140)
                        }

                        Divider()

                        // 動作モード (Push-to-Talk vs Toggle)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("録音動作:")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Picker("", selection: $settings.triggerMode) {
                                Text("長押し (離すと入力)").tag(TriggerMode.pushToTalk)
                                Text("トグル (押して開始/停止)").tag(TriggerMode.toggle)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        Divider()

                        // 文体・推敲モード
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("推敲モード:")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                                Text(settings.refinementStyle == .casual ? "話し言葉・語尾を保持" : "書き言葉に校正")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Picker("", selection: $settings.refinementStyle) {
                                ForEach(RefinementStyle.allCases) { style in
                                    Text(style.title).tag(style)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                }

                Divider()

                // セクション: 保留・プレビュー
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("保留・プレビュー")
                            .font(.headline)
                        Spacer()
                        if settings.floatingPreviewEnabled {
                            Text("\(settings.pasteShortcutDisplayString) でペースト")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.accentColor.opacity(0.12))
                                )
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("画面下部に保留ウィンドウを表示する", isOn: $settings.floatingPreviewEnabled)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        if settings.floatingPreviewEnabled {
                            Divider()

                            HStack {
                                Text("ペーストキー:")
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                Spacer()

                                Picker("", selection: Binding(
                                    get: { settings.pasteShortcutDisplayString },
                                    set: { newDisplay in
                                        if let preset = pastePresets.first(where: { $0.display == newDisplay }) {
                                            appState.updatePasteShortcut(
                                                keyCode: preset.keyCode,
                                                modifiers: preset.modifiers,
                                                displayString: preset.display
                                            )
                                        }
                                    }
                                )) {
                                    ForEach(pastePresets) { preset in
                                        Text("\(preset.name) (\(preset.display))").tag(preset.display)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                            }

                            Divider()

                            Toggle("音声入力完了時に直接自動ペーストも行う", isOn: $settings.autoPasteEnabled)
                                .font(.subheadline)

                            Divider()

                            HStack {
                                Text("自動で閉じる時間:")
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                Spacer()

                                Picker("", selection: $settings.floatingPreviewDuration) {
                                    Text("30秒").tag(30.0)
                                    Text("45秒").tag(45.0)
                                    Text("60秒").tag(60.0)
                                    Text("閉じない").tag(0.0)
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                            }
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                }

                Divider()

                // セクション2: 入力マイク
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("入力マイク")
                            .font(.headline)
                        Spacer()
                        Button(action: {
                            audioDevices.refreshDevices()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text("更新")
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("マイク:")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Spacer()

                            Picker("", selection: Binding(
                                get: { settings.selectedAudioDeviceUID },
                                set: { newUID in
                                    if micTester.isTesting {
                                        micTester.stopTesting()
                                    }
                                    if newUID.isEmpty || newUID == "default" {
                                        audioDevices.selectDevice(uid: "", name: "システムデフォルト")
                                    } else if let dev = audioDevices.availableDevices.first(where: { $0.id == newUID }) {
                                        audioDevices.selectDevice(uid: dev.id, name: dev.name)
                                    }
                                }
                            )) {
                                let defaultName = audioDevices.systemDefaultDevice?.name ?? "未検出"
                                Text("システムデフォルト (\(defaultName))").tag("")

                                ForEach(audioDevices.availableDevices) { device in
                                    Text(device.name + (device.isSystemDefault ? " (既定)" : "")).tag(device.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }

                        // ステータス表示
                        HStack(spacing: 6) {
                            if audioDevices.isFallbackActive {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("フォールバック中: \(audioDevices.effectiveDeviceName)")
                                    .foregroundColor(.orange)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("有効: \(audioDevices.effectiveDeviceName)")
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .font(.caption)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                }

                Divider()

                // セクション3: 音声しきい値 (ノイズゲート)
                VStack(alignment: .leading, spacing: 10) {
                    Text("音声しきい値 (ノイズゲート)")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("小さな音を除外する (声の音量のみ入力)", isOn: $settings.audioThresholdEnabled)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        if settings.audioThresholdEnabled {
                            Divider()

                            // 感度プリセット & スライダー
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("入力しきい値:")
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
                                                .padding(.vertical, 4)
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
                                    Text("-50dB")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                } maximumValueLabel: {
                                    Text("-15dB")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Divider()

                            // 無音・打鍵音トリミング
                            Toggle("前後の微小音・打鍵音を自動カット", isOn: $settings.audioTrimmingEnabled)
                                .font(.subheadline)

                            Divider()

                            // リアルタイムマイクテスト
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("入力レベルテスト")
                                        .font(.subheadline)
                                        .fontWeight(.medium)

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
                                            Text(micTester.isTesting ? "停止" : "開始")
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(micTester.isTesting ? .red : .accentColor)
                                    .controlSize(.small)
                                }

                                AudioLevelMeterView(
                                    currentDB: micTester.currentLevelDB,
                                    thresholdDB: settings.audioThresholdDB,
                                    isTesting: micTester.isTesting
                                )

                                if micTester.isTesting {
                                    HStack {
                                        if micTester.isSpeechDetected {
                                            Label("音声を検知中", systemImage: "checkmark.circle.fill")
                                                .font(.caption)
                                                .foregroundColor(.green)
                                        } else {
                                            Label("待機中 (しきい値未満)", systemImage: "speaker.slash.fill")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Text(String(format: "%.0f dB", micTester.currentLevelDB))
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
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                }

                Divider()

                // セクション4: 言語・翻訳
                VStack(alignment: .leading, spacing: 10) {
                    Text("言語・翻訳")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("モード:")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Picker("", selection: $settings.apiMode) {
                                Text("文字起こし (通常入力)").tag(SpeechAPIMode.transcriptions)
                                Text("英語翻訳 (日本語音声→英語)").tag(SpeechAPIMode.translations)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        if settings.apiMode == .transcriptions {
                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                Text("音声言語:")
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                HStack(spacing: 8) {
                                    Button(action: { settings.language = "" }) {
                                        Text("自動判別")
                                            .font(.system(size: 11, weight: settings.language.isEmpty ? .bold : .regular))
                                            .foregroundColor(settings.language.isEmpty ? .accentColor : .primary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
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
                                            .padding(.vertical, 4)
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
                                            .padding(.vertical, 4)
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
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                }

                Divider()

                // セクション5: クリップボード
                VStack(alignment: .leading, spacing: 10) {
                    Text("クリップボード")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("ペースト後にクリップボード内容を復元する", isOn: $settings.restoreClipboard)
                            .font(.subheadline)

                        HStack(spacing: 8) {
                            Image(systemName: "shield.checkered")
                                .foregroundColor(.green)
                            Text("履歴アプリ (Raycast, Alfred, Maccy等) への除外保護が有効")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(NSColor.controlBackgroundColor))
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

