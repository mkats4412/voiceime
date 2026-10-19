import SwiftUI
import AppKit

@MainActor
public struct FloatingPreviewView: View {
    @ObservedObject var controller: FloatingPreviewController

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
                        .fill(controller.mode == .quickAsk ? Color.purple : Color.red)
                        .frame(width: 9, height: 9)
                    Text(controller.mode == .quickAsk ? "AIクイック質問中..." : "音声入力中です..")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)

                    Spacer()

                    if controller.mode == .quickAsk {
                        Text("離すとAIが回答")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.purple.opacity(0.12))
                            )
                    }

                case .processing:
                    ProgressView()
                        .controlSize(.small)
                    Text(controller.mode == .quickAsk ? "AI回答取得中..." : (AppSettings.shared.isLLMRefinementActive ? "AI推敲中..." : "文字起こし中..."))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)

                    Spacer()

                case .ready:
                    Image(systemName: controller.mode == .quickAsk ? "sparkles" : "mic.bubble.fill")
                        .foregroundColor(controller.mode == .quickAsk ? .purple : .accentColor)
                        .font(.system(size: 13, weight: .semibold))

                    Text(controller.mode == .quickAsk ? "AIの回答" : "音声入力プレビュー")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)

                    Spacer()

                    // ガイダンスバッジ
                    let defaultNotice = controller.mode == .quickAsk
                        ? "\(AppSettings.shared.pasteShortcutDisplayString) でペースト"
                        : "入力先を選択 ➔ \(AppSettings.shared.pasteShortcutDisplayString)"
                    Text(controller.customNotice ?? defaultNotice)
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
                    controller.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary.opacity(0.8))
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("プレビューを閉じてクリップボードを消去 (Esc)")
            }

            // テキスト編集・表示エリア
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.65))

                if controller.currentText.isEmpty {
                    let placeholder = controller.mode == .quickAsk
                        ? "質問を話してください... (例: ゴミの英語のスペルは?)"
                        : "話した言葉がリアルタイムでここに表示されます..."
                    Text(controller.phase == .liveRecording ? placeholder : "")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(10)
                }

                AutoScrollingTextView(
                    text: $controller.currentText,
                    isEditable: controller.phase == .ready
                )
                .frame(minHeight: 56, maxHeight: 150)
                .padding(4)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        controller.phase == .liveRecording
                            ? (controller.mode == .quickAsk ? Color.purple.opacity(0.5) : Color.red.opacity(0.4))
                            : Color.primary.opacity(0.12),
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

                // 挿入実行ボタン（ユーザー設定のショートカット）
                Button {
                    controller.insertTextToFrontmostApp()
                } label: {
                    HStack(spacing: 5) {
                        Text("挿入")
                            .font(.system(size: 12, weight: .bold))

                        Text(AppSettings.shared.pasteShortcutDisplayString)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5)
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
                            .fill(controller.phase == .ready && !controller.currentText.isEmpty
                                  ? (controller.mode == .quickAsk ? Color.purple : Color.accentColor)
                                  : Color.secondary.opacity(0.4))
                    )
                }
                .buttonStyle(.plain)
                .disabled(controller.phase != .ready || controller.currentText.isEmpty)
                .help("フォーカス中のアプリにテキストをペースト (\(AppSettings.shared.pasteShortcutDisplayString))")
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

/// 音声入力中にテキストが更新されるたびに最下部へ自動スクロールする TextView
struct AutoScrollingTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var font: NSFont = .systemFont(ofSize: 13.5)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let contentSize = scrollView.contentSize
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(containerSize: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = .labelColor
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 4, height: 6)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable

        if textView.string != text {
            textView.string = text
            // 音声入力中やテキスト追加時に最新の最下行へ自動スクロール
            DispatchQueue.main.async {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AutoScrollingTextView
        weak var textView: NSTextView?

        init(_ parent: AutoScrollingTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.parent.text = textView.string
        }
    }
}
