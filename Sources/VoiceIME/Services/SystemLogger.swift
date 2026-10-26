import Foundation

/// システム診断・セキュリティ監査・例外エラーを `~/Library/Logs/voiceime/YYYYMMDD.log` に記録するロガーサービス
public final class SystemLogger: @unchecked Sendable {
    public static let shared = SystemLogger()

    private let queue = DispatchQueue(label: "com.voiceime.system.logger", qos: .utility)

    public var logDirectoryURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/voiceime", isDirectory: true)
    }

    private let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        return df
    }()

    private let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()

    private init() {
        createLogDirectoryIfNeeded()
    }

    /// 現在の日付（YYYYMMDD.log）に応じたログファイル URL
    public func currentLogFileURL() -> URL {
        let filename = "\(dayFormatter.string(from: Date())).log"
        return logDirectoryURL.appendingPathComponent(filename)
    }

    private func createLogDirectoryIfNeeded() {
        let dir = logDirectoryURL
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// セキュリティ監査ログ（ユーザー同意・ログ有効化・無効化・アクセス制限等）
    public func logAudit(_ message: String) {
        writeEntry(level: "AUDIT", message: message)
    }

    /// エラーログ（APIエラー・HTTPステータスエラー・初期化失敗等）
    public func logError(_ message: String, error: Error? = nil) {
        var fullMessage = message
        if let err = error {
            fullMessage += " [Error: \(err.localizedDescription)]"
        }
        writeEntry(level: "ERROR", message: fullMessage)
    }

    /// 例外ログ（キャッチされた例外・想定外の障害）
    public func logException(_ message: String, error: Error? = nil) {
        var fullMessage = message
        if let err = error {
            fullMessage += " [Exception: \(err)]"
        }
        writeEntry(level: "EXCEPTION", message: fullMessage)
    }

    /// 一般システムインフォメーションログ
    public func logInfo(_ message: String) {
        writeEntry(level: "INFO", message: message)
    }

    private func writeEntry(level: String, message: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.createLogDirectoryIfNeeded()
            let timeStr = self.timeFormatter.string(from: Date())
            let line = "[\(timeStr)] [\(level)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            let url = self.currentLogFileURL()
            if let fileHandle = try? FileHandle(forWritingTo: url) {
                defer { try? fileHandle.close() }
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
