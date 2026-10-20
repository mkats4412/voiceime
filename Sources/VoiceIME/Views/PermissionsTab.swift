import SwiftUI

public struct PermissionsTab: View {
    @ObservedObject var permissionService = PermissionService.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("アクセス権限")
                    .font(.headline)
                Text("音声録音と入力欄への自動ペーストに必要な権限です。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 1. マイク権限カード
            HStack(spacing: 14) {
                Image(systemName: permissionService.isMicrophoneAuthorized ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 24))
                    .foregroundColor(permissionService.isMicrophoneAuthorized ? .green : .orange)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("マイク")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        if permissionService.isMicrophoneAuthorized {
                            Text("許可済み")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .cornerRadius(4)
                        } else {
                            Text("未許可")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .cornerRadius(4)
                        }
                    }

                    Text("音声入力の録音に使用")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if !permissionService.isMicrophoneAuthorized {
                    HStack(spacing: 8) {
                        Button("許可") {
                            permissionService.requestMicrophoneAccess { _ in
                                permissionService.checkPermissions()
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("設定を開く") {
                            permissionService.openMicrophoneSettings()
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.green)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.controlBackgroundColor))
            )

            // 2. アクセシビリティ権限カード
            HStack(spacing: 14) {
                Image(systemName: permissionService.isAccessibilityAuthorized ? "keyboard.fill" : "keyboard")
                    .font(.system(size: 24))
                    .foregroundColor(permissionService.isAccessibilityAuthorized ? .green : .orange)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("アクセシビリティ")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        if permissionService.isAccessibilityAuthorized {
                            Text("許可済み")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .cornerRadius(4)
                        } else {
                            Text("未許可")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .cornerRadius(4)
                        }
                    }

                    Text("入力欄への自動ペーストに使用")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if !permissionService.isAccessibilityAuthorized {
                    HStack(spacing: 8) {
                        Button("許可") {
                            permissionService.requestAccessibilityAccess()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("設定を開く") {
                            permissionService.openAccessibilitySettings()
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.green)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.controlBackgroundColor))
            )

            Spacer()

            HStack {
                Spacer()
                Button(action: {
                    permissionService.checkPermissions()
                }) {
                    Label("状態を再確認", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .onAppear {
            permissionService.checkPermissions()
        }
    }
}
