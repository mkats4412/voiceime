import SwiftUI
import AppKit

@main
struct VoiceIMEApp: App {
    @StateObject private var appState: AppState

    init() {
        // プロセス間パイプ通信等での SIGPIPE シグナルによる異常終了を無視
        signal(SIGPIPE, SIG_IGN)

        // MCP (Model Context Protocol) stdio サーバーモード
        // GUI や Keychain 認証を一切行わず、ヘッドレスで即座に応答
        if CommandLine.arguments.contains("--mcp") || CommandLine.arguments.contains("mcp") {
            MCPServerRunner.run()
            exit(0)
        }

        if CommandLine.arguments.contains("--live-speech-helper") {
            LiveSpeechHelper.run()
            exit(0)
        }

        _appState = StateObject(wrappedValue: AppState.shared)

        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                openSettingsAction: {
                    SettingsWindowController.shared.showWindow()
                },
                quitAction: {
                    NSApplication.shared.terminate(nil)
                }
            )
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        switch appState.phase {
        case .idle:
            Image(systemName: "mic.fill")
        case .recording:
            Image(systemName: "record.circle.fill")
                .symbolRenderingMode(.multicolor)
        case .transcribing, .refining, .pasting:
            Image(systemName: "arrow.triangle.2.circlepath")
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }
}
