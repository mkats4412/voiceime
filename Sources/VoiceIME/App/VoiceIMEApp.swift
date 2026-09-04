import SwiftUI
import AppKit

@main
struct VoiceIMEApp: App {
    @StateObject private var appState = AppState.shared

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
