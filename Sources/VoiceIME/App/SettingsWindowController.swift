import AppKit
import SwiftUI

@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    public static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let windowWidth: CGFloat = 580
    private let windowHeight: CGFloat = 700

    private override init() {
        super.init()
    }

    // MARK: - NSWindowDelegate
    // isReleasedWhenClosed = false のため close 後も window は保持され再利用される。
    // delegate を設定することで AppKit のウィンドウリスト管理を明確化し、
    // Instruments でリークとして誤検出されるのを防ぐ（挙動は維持）。
    public func windowWillClose(_ notification: Notification) {
        // 設定ウィンドウが閉じられたらメニューバー常駐（Dock非表示）に戻す
        NSApp.setActivationPolicy(.accessory)
    }

    public func showWindow() {
        // ウィンドウを前面に出すため一時的に regular アプリ化（Dockとメニューバーを活性化）
        NSApp.setActivationPolicy(.regular)

        if let existingWindow = window {
            NSApp.activate(ignoringOtherApps: true)
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = SettingsView()
        let hostingController = FirstMouseHostingController(rootView: contentView)

        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.title = "VoiceIME 設定"
        newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]

        let defaultSize = NSSize(width: windowWidth, height: windowHeight)
        newWindow.setContentSize(defaultSize)
        newWindow.minSize = NSSize(width: 560, height: 580)
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self

        self.window = newWindow

        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
    }
}

/// ウィンドウ非アクティブ時でも最初の1クリック目でタブ切り替えやボタン押下を即時受け付けるHostingView
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

/// FirstMouseHostingView を利用する NSHostingController
final class FirstMouseHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        self.view = FirstMouseHostingView(rootView: rootView)
    }
}
