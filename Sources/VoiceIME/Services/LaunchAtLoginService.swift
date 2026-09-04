import Foundation
import ServiceManagement
import AppKit

@MainActor
public final class LaunchAtLoginService: ObservableObject {
    public static let shared = LaunchAtLoginService()

    @Published public var isEnabled: Bool = false
    @Published public var statusMessage: String = ""
    @Published public var hasError: Bool = false
    @Published public var errorMessage: String? = nil

    private init() {
        refresh()
    }

    /// 現在のログイン項目ステータスを確認
    public func refresh() {
        let status = SMAppService.mainApp.status
        self.isEnabled = (status == .enabled)

        switch status {
        case .enabled:
            statusMessage = "有効 (Mac起動時に自動開始されます)"
            hasError = false
            errorMessage = nil
        case .requiresApproval:
            statusMessage = "システム設定での許可が必要です"
            hasError = true
            errorMessage = "macOSの「システム設定 > 一般 > ログイン項目」でVoiceIMEが許可されていません。"
        case .notRegistered:
            statusMessage = "無効"
            hasError = false
            errorMessage = nil
        case .notFound:
            statusMessage = "未登録"
            hasError = false
            errorMessage = nil
        @unknown default:
            statusMessage = ""
            hasError = false
            errorMessage = nil
        }
    }

    /// 自動起動の有効/無効を切り替え
    public func setEnabled(_ enable: Bool) {
        do {
            if enable {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            refresh()
        } catch {
            self.hasError = true
            self.errorMessage = "自動起動の設定に失敗しました: \(error.localizedDescription)"
            refresh()
        }
    }

    /// macOS システム設定の「ログイン項目」画面を開く
    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
