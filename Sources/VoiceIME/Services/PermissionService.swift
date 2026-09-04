import AppKit
import AVFoundation
import ApplicationServices

@MainActor
public final class PermissionService: ObservableObject {
    public static let shared = PermissionService()

    @Published public var isMicrophoneAuthorized: Bool = false
    @Published public var isAccessibilityAuthorized: Bool = false

    private init() {
        checkPermissions()
    }

    /// 現在の権限状態を更新チェック
    public func checkPermissions() {
        // マイク権限
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        self.isMicrophoneAuthorized = (micStatus == .authorized)

        // アクセシビリティ権限
        self.isAccessibilityAuthorized = AXIsProcessTrusted()
    }

    /// マイクアクセスをリクエスト
    public func requestMicrophoneAccess(completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            self.isMicrophoneAuthorized = true
            completion?(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async { [weak self] in
                    self?.isMicrophoneAuthorized = granted
                    completion?(granted)
                }
            }
        case .denied, .restricted:
            self.isMicrophoneAuthorized = false
            completion?(false)
        @unknown default:
            self.isMicrophoneAuthorized = false
            completion?(false)
        }
    }

    /// アクセシビリティ権限をリクエスト（システムダイアログを表示）
    public func requestAccessibilityAccess() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)
        self.isAccessibilityAuthorized = accessEnabled
    }

    /// システム設定のプライバシー（マイク）を開く
    public func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// システム設定のプライバシー（アクセシビリティ）を開く
    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
