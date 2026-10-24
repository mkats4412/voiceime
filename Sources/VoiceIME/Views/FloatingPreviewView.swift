import SwiftUI
import AppKit

@MainActor
public struct FloatingPreviewView: View {
    @ObservedObject var controller: FloatingPreviewController
    @ObservedObject private var settings = AppSettings.shared

    // ユーザー設定可能な発話準備完了カラー（青紫、グリーン、ブルー等）
    private var readyColor: Color {
        settings.recordingIndicatorColor.color
    }
    private var colorNameJa: String {
        settings.recordingIndicatorColor.colorNameJa
    }

    public init(controller: FloatingPreviewController? = nil) {
        self.controller = controller ?? FloatingPreviewController.shared
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ヘッダーバー
            HStack(alignment: .center, spacing: 6) {
                switch controller.phase {
                case .liveRecording:
                    if controller.isMicReady {
                        // 🟣/🟢 マイク到達完了: 発話可能
                        Circle()
                            .fill(readyColor)
                            .frame(width: 10, height: 10)
                            .shadow(color: readyColor.opacity(0.85), radius: 4)

                        Text(controller.mode == .quickAsk ? "どうぞ話してください (AI質問中)" : "どうぞ話してください (録音中)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.primary)

                        Text("マイク準備完了")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(readyColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule()
                                    .fill(readyColor.opacity(0.15))
                            )
                    } else {
                        // 🟡 マイク起動中（数ミリ秒〜数百ミリ秒の間）
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 9, height: 9)

                        Text("マイク起動中... (\(colorNameJa)になったら話してください)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if controller.isPinned {
                        HStack(spacing: 3) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                            Text("固定中 (離しても維持)")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.15))
                        )
                    } else if controller.mode == .quickAsk {
                        Text("離すとAIが回答")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.purple.opacity(0.12))
                            )
                    } else {
                        Text("+ で消さずに維持")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundColor(.secondary.opacity(0.8))
                    }

                case .paused:
                    // ⏸️ 一時停止中（考え中）
                    Image(systemName: "pause.circle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 12, weight: .bold))

                    Text("一時停止中 (考え中)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.primary)

                    Text("マイク停止中")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.15))
                        )

                    Spacer()

                    let pauseHint = controller.mode == .quickAsk ? "Spaceで再開 / ⌃⇧離して送信" : "Spaceで再開 / ⌃離して入力"
                    Text(pauseHint)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.15))
                        )

                case .processing:
                    ProgressView()
                        .controlSize(.small)
                    Text(controller.mode == .quickAsk ? "AI回答取得中..." : (AppSettings.shared.isLLMRefinementActive ? "AI推敲中..." : "文字起こし中..."))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)

                    Spacer()

                    if controller.isPinned {
                        HStack(spacing: 3) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                            Text("固定中")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.15))
                        )
                    }

                case .ready:
                    let iconName: String = {
                        if controller.isQuickAskQuestionEditing {
                            return "questionmark.bubble.fill"
                        } else if controller.isPinned {
                            return "pin.fill"
                        } else {
                            return controller.mode == .quickAsk ? "sparkles" : "mic.bubble.fill"
                        }
                    }()
                    let iconColor: Color = {
                        if controller.isQuickAskQuestionEditing {
                            return .purple
                        } else if controller.isPinned {
                            return .orange
                        } else {
                            return controller.mode == .quickAsk ? .purple : .accentColor
                        }
                    }()
                    let titleText: String = {
                        if controller.isQuickAskQuestionEditing {
                            return "AIクイック質問 (質問を修正中)"
                        } else if controller.isPinned {
                            return "修正モード"
                        } else {
                            return controller.mode == .quickAsk ? "AIの回答" : "音声入力プレビュー"
                        }
                    }()

                    Image(systemName: iconName)
                        .foregroundColor(iconColor)
                        .font(.system(size: 13, weight: .semibold))

                    Text(titleText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)

                    Spacer()

                    // ガイダンスバッジ
                    let defaultNotice = controller.isQuickAskQuestionEditing
                        ? "質問を修正 ➔ \(AppSettings.shared.pasteShortcutDisplayString) でAIに送信 / + で閉じる"
                        : (controller.isPinned
                            ? "修正可能 ➔ + で閉じる / \(AppSettings.shared.pasteShortcutDisplayString) で挿入"
                            : (controller.mode == .quickAsk
                                ? "\(AppSettings.shared.pasteShortcutDisplayString) でペースト"
                                : "入力先を選択 ➔ \(AppSettings.shared.pasteShortcutDisplayString)"))
                    Text(controller.customNotice ?? defaultNotice)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(controller.isQuickAskQuestionEditing ? .purple : (controller.isPinned ? .orange : .secondary))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(controller.isQuickAskQuestionEditing ? Color.purple.opacity(0.12) : (controller.isPinned ? Color.orange.opacity(0.12) : Color.primary.opacity(0.06)))
                        )

                    // ピン留めトグルボタン
                    Button {
                        controller.togglePinned()
                    } label: {
                        Image(systemName: controller.isPinned ? "pin.fill" : "pin")
                            .foregroundColor(controller.isPinned ? .orange : .secondary.opacity(0.8))
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help(controller.isPinned ? "ピン留め固定中 (+ キーで閉じる)" : "ピン留め固定 (+ キー)")
                }

                // 閉じるボタン
                Button {
                    if controller.isPinned {
                        controller.dismissAfterEditing()
                    } else {
                        controller.cancel()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary.opacity(0.8))
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("プレビューを閉じる (+ または Esc)")
            }

            // テキスト編集・表示エリア
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.65))

                if controller.currentText.isEmpty {
                    let placeholder: String = {
                        if controller.phase == .liveRecording {
                            if controller.isMicReady {
                                return controller.mode == .quickAsk
                                    ? "どうぞ質問を話してください... (例: ゴミの英語のスペルは?)"
                                    : "どうぞ話してください。話した言葉がリアルタイムでここに表示されます..."
                            } else {
                                return "マイクを起動しています... \(colorNameJa)の表示になったらお話しください"
                            }
                        } else if controller.phase == .paused {
                            return "一時停止中: 考えがまとまったら Space を押して続きをお話しください..."
                        }
                        return ""
                    }()
                    Text(placeholder)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(controller.phase == .paused ? .orange.opacity(0.85) : (controller.isMicReady ? .secondary.opacity(0.8) : .orange.opacity(0.8)))
                        .padding(10)
                }

                AutoScrollingTextView(
                    text: $controller.currentText,
                    isEditable: controller.phase == .ready || controller.isPinned
                )
                .frame(minHeight: 56, maxHeight: 260)
                .padding(4)
                .onTapGesture {
                    if controller.phase == .ready || controller.isPinned {
                        controller.activateAndFocusForEditing()
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        controller.isPinned
                            ? Color.orange.opacity(0.65)
                            : (controller.phase == .paused
                                ? Color.orange.opacity(0.6)
                                : (controller.phase == .liveRecording
                                    ? (controller.isMicReady ? readyColor.opacity(0.85) : Color.orange.opacity(0.5))
                                    : Color.primary.opacity(0.12))),
                        lineWidth: controller.isPinned ? 1.5 : (controller.phase == .liveRecording && controller.isMicReady ? 1.5 : (controller.phase == .paused ? 1.5 : 1))
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

                // 挿入実行ボタン または AI送信ボタン
                Button {
                    if controller.isQuickAskQuestionEditing {
                        controller.submitQuickAskQuestion()
                    } else {
                        controller.insertTextToFrontmostApp()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: controller.isQuickAskQuestionEditing ? "paperplane.fill" : "arrow.down.doc.fill")
                            .font(.system(size: 10))

                        Text(controller.isQuickAskQuestionEditing ? "AIに送信" : "挿入")
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
                            .fill((controller.phase == .ready || controller.isPinned) && !controller.currentText.isEmpty
                                  ? (controller.mode == .quickAsk ? Color.purple : Color.accentColor)
                                  : Color.secondary.opacity(0.4))
                    )
                }
                .buttonStyle(.plain)
                .disabled((controller.phase != .ready && !controller.isPinned) || controller.currentText.isEmpty)
                .help(controller.isQuickAskQuestionEditing
                      ? "修正した質問をAIに送信 (\(AppSettings.shared.pasteShortcutDisplayString))"
                      : "フォーカス中のアプリにテキストをペースト (\(AppSettings.shared.pasteShortcutDisplayString))")
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
                .stroke(
                    controller.phase == .paused
                        ? Color.orange.opacity(0.6)
                        : (controller.phase == .liveRecording
                            ? (controller.isMicReady ? readyColor.opacity(0.65) : Color.orange.opacity(0.4))
                            : Color.primary.opacity(0.12)),
                    lineWidth: (controller.phase == .liveRecording && controller.isMicReady) || controller.phase == .paused ? 1.5 : 1
                )
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
        textView.allowsUndo = true
        textView.isRichText = false
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 4, height: 6)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.insertionPointColor = .labelColor

        if textView.string != text {
            textView.string = text
            // 非編集モード（Ctrl+Spaceホールド中: isEditable == false）でも確実にレイアウト計算を完了させて最下行（語尾）まで表示・スクロールさせる
            if let tc = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: tc)
            }
            let endRange = NSRange(location: (text as NSString).length, length: 0)
            textView.scrollRangeToVisible(endRange)
            textView.scrollToEndOfDocument(nil)
            DispatchQueue.main.async {
                if let tc = textView.textContainer {
                    textView.layoutManager?.ensureLayout(for: tc)
                }
                let latestEnd = NSRange(location: (textView.string as NSString).length, length: 0)
                textView.scrollRangeToVisible(latestEnd)
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
