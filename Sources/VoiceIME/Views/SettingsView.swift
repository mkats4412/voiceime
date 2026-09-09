import SwiftUI

public enum SettingsTab: String, CaseIterable, Identifiable {
    case api = "API連携"
    case dictionary = "単語・辞書"
    case shortcut = "操作・音声"
    case permissions = "アクセス権限"

    public var id: String { rawValue }

    var iconName: String {
        switch self {
        case .api: return "network"
        case .dictionary: return "character.book.closed"
        case .shortcut: return "waveform.and.mic"
        case .permissions: return "hand.raised"
        }
    }
}

public struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .api

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // 上部タブバー（macOS 設定パネルスタイル）
            HStack(spacing: 8) {
                ForEach(SettingsTab.allCases) { tab in
                    SettingsTabButton(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        action: {
                            guard selectedTab != tab else { return }
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedTab = tab
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // タブのコンテンツエリア（固定サイズでスクロール不要、すっきり配置）
            Group {
                switch selectedTab {
                case .api:
                    APISettingsTab()
                case .dictionary:
                    DictionarySettingsTab()
                case .shortcut:
                    ShortcutSettingsTab()
                case .permissions:
                    PermissionsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 560, minHeight: 580)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 18))
                Text(tab.rawValue)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor)
            )
            // ボタン全体の矩形（パディングおよび余白領域を含む）をクリック判定対象にする
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .foregroundColor(isSelected ? .accentColor : .primary)
        }
        .buttonStyle(TabPressButtonStyle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.15)
        } else if isHovered {
            return Color.primary.opacity(0.06)
        } else {
            return Color.clear
        }
    }
}

private struct TabPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

