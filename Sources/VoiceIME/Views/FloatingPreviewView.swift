import SwiftUI
import AppKit

@MainActor
public struct FloatingPreviewView: View {
    @ObservedObject var controller: FloatingPreviewController
    @FocusState private var isEditorFocused: Bool

    public init(controller: FloatingPreviewController? = nil) {
        self.controller = controller ?? FloatingPreviewController.shared
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ヘッダーバー
            HStack(alignment: .center, spacing: 6) {
                switch controller.phase {
                case .liveRecording:
                    Circle()
                        .fill(Color.red)
                        .frame(width: 9, height: 9)
                    Text("リアルタイム音声入力中...")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)

                    Spacer()

                    Text("離すとAI推敲")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.red.opacity(0.12))
                        )

                case .processing:
                    ProgressView()
                        .controlSize(.small)
                    Text("AI推敲中...")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)

                    Spacer()

                case .ready:
                    Image(systemName: "mic.bubble.fill")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 13, weight: .semibold))

                    Text("音声入力プレビュー")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)

                    Spacer()

                    // ガイダンスバッジ
                    Text(controller.customNotice ?? "入力先を選択 ➔ ⌘↩")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(0.06))
                        )
                }

                // 閉じるボタン
                Button {
                    controller.hide()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary.opacity(0.8))
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("プレビューを閉じる (Esc)")
            }

            // テキスト編集・表示エリア
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.65))

                if controller.phase == .liveRecording && controller.currentText.isEmpty {
                    Text("話した言葉がリアルタイムでここに表示されます...")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(10)
                }

                TextEditor(text: $controller.currentText)
                    .focused($isEditorFocused)
                    .font(.system(size: 13.5, weight: .regular))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 52, maxHeight: 140)
                    .padding(6)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        controller.phase == .liveRecording ? Color.red.opacity(0.4) :
                        (isEditorFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.1)),
                        lineWidth: 1
                    )
            )

            // 下部アクションバー
            HStack(spacing: 8) {
                // クリップボードにコピー
                Button {
                    controller.copyToClipboard()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: controller.copySuccess ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        Text(controller.copySuccess ? "コピー済み" : "コピー")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(controller.copySuccess ? .green : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(NSColor.controlColor))
                    )
                }
                .buttonStyle(.plain)
                .disabled(controller.currentText.isEmpty)
                .help("クリップボードにコピー")

                Spacer()

                // 挿入実行ボタン（⌘+Enter）
                Button {
                    controller.insertTextToFrontmostApp()
                } label: {
                    HStack(spacing: 5) {
                        Text("挿入")
                            .font(.system(size: 12, weight: .bold))

                        HStack(spacing: 2) {
                            Text("⌘")
                                .font(.system(size: 10, weight: .bold))
                            Text("↩")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.2))
                        )
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(controller.phase == .ready && !controller.currentText.isEmpty ? Color.accentColor : Color.secondary.opacity(0.4))
                    )
                }
                .buttonStyle(.plain)
                .disabled(controller.phase != .ready || controller.currentText.isEmpty)
                .help("フォーカス中のアプリにテキストをペースト (⌘+Return)")
            }
        }
        .padding(12)
        .frame(width: 440)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(controller.phase == .liveRecording ? Color.red.opacity(0.3) : Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(10)
    }
}
