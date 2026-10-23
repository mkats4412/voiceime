import Foundation

/// 音声入力パイプラインにおける文字列の変遷をトラックし、
/// `~/.voiceime/pipeline.log` にリアルタイムで記録するロガーサービス
public final class PipelineLogger: @unchecked Sendable {
    public static let shared = PipelineLogger()

    private let queue = DispatchQueue(label: "com.voiceime.pipeline.logger", qos: .utility)

    public var logFileURL: URL {
        VoiceIMEDiskSyncService.shared.baseDirectory.appendingPathComponent("pipeline.log")
    }

    /// パイプラインログが有効かどうか (UserDefaults "voiceime_pipelineLoggingEnabled" と連動)
    public var isLoggingEnabled: Bool {
        UserDefaults.standard.object(forKey: "voiceime_pipelineLoggingEnabled") as? Bool ?? true
    }

    /// ログファイルをクリア
    public func clearLog() {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.removeItem(at: self.logFileURL)
        }
    }

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()

    private init() {}

    /// セッション開始ログ
    public func logSessionStart() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let timeStr = self.dateFormatter.string(from: Date())
            let header = """

==================================================
[\(timeStr)] 🎙️ 音声入力セッション開始
==================================================

"""
            self.appendToFile(header)
        }
    }

    /// 1. Whisperから逐次送られてきた文字列
    public func logWhisperReceived(type: String = "逐次速報", text: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let timeStr = self.dateFormatter.string(from: Date())
            let entry = "\n\n1. Whisperから逐次送られてきた文字列 [\(type) - \(timeStr)]:\n\(text)\n"
            self.appendToFile(entry)
        }
    }

    /// 2. Whisperから推敲LLMへ送られる文字列
    public func logLLMInput(type: String = "推敲入力", text: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let timeStr = self.dateFormatter.string(from: Date())
            let entry = "\n\n2. Whisperから推敲LLMへ送られる文字列 [\(type) - \(timeStr)]:\n\(text)\n"
            self.appendToFile(entry)
        }
    }

    /// 3. 推敲LLMから修正され戻される文字列
    public func logLLMOutput(type: String = "推敲出力", text: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let timeStr = self.dateFormatter.string(from: Date())
            let entry = "\n\n3. 推敲LLMから修正され戻される文字列 [\(type) - \(timeStr)]:\n\(text)\n"
            self.appendToFile(entry)
        }
    }

    /// 4. ユーザー手動修正による最終確定出力（修正モード）
    public func logUserCorrection(text: String, originalText: String? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let timeStr = self.dateFormatter.string(from: Date())
            var entry = "\n\n4. ユーザー手動修正による最終確定出力 [修正モード - \(timeStr)]:\n\(text)\n"
            if let orig = originalText?.trimmingCharacters(in: .whitespacesAndNewlines), !orig.isEmpty, orig != text {
                entry += "(修正前: \(orig))\n"
            }
            entry += """

==================================================
[\(timeStr)] ✅ 修正モード挿入完了
\(text)
==================================================

"""
            self.appendToFile(entry)
        }
    }

    /// デバッグ・トレースログ
    public func logDebug(_ message: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let timeStr = self.dateFormatter.string(from: Date())
            let entry = "[\(timeStr)] [DEBUG] \(message)\n"
            self.appendToFile(entry)
        }
    }

    /// セッション完了ログ
    public func logSessionEnd(finalText: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let timeStr = self.dateFormatter.string(from: Date())
            let footer = """

==================================================
[\(timeStr)] ✅ 音声入力セッション完了 (確定出力テキスト)
\(finalText)
==================================================

"""
            self.appendToFile(footer)
        }
    }

    private func appendToFile(_ string: String) {
        guard isLoggingEnabled else { return }
        guard let data = string.data(using: .utf8) else { return }
        let url = logFileURL
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        if let fileHandle = try? FileHandle(forWritingTo: url) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
            try? fileHandle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
