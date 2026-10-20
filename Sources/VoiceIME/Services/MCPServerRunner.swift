import Foundation

/// `--mcp` 引数で起動された際に、GUIやKeychainを一切初期化せず、
/// ヘッドレスな MCP (Model Context Protocol) stdio サーバーとして動作させるランナー
public enum MCPServerRunner {
    public static func run() {
        // 1. MCP サーバースクリプトの探索
        var scriptPath: String?

        // バンドル内の Resources/voiceime_mcp_server.py
        if let bundleScript = Bundle.main.path(forResource: "voiceime_mcp_server", ofType: "py"),
           FileManager.default.fileExists(atPath: bundleScript) {
            scriptPath = bundleScript
        }

        // ~/.voiceime/mcp_server.py
        if scriptPath == nil {
            let homeScript = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".voiceime")
                .appendingPathComponent("mcp_server.py").path
            if FileManager.default.fileExists(atPath: homeScript) {
                scriptPath = homeScript
            }
        }

        guard let targetScript = scriptPath else {
            fputs("[VoiceIME MCP] エラー: voiceime_mcp_server.py が見つかりませんでした。\n", stderr)
            exit(1)
        }

        // 2. Python3 実行可能ファイルの探索
        let pythonPaths = [
            "/usr/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3"
        ]
        let pythonExecutable = pythonPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? "/usr/bin/python3"

        // 3. Process の起動と標準入出力の直結
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonExecutable)
        process.arguments = [targetScript]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
            process.waitUntilExit()
            exit(process.terminationStatus)
        } catch {
            fputs("[VoiceIME MCP] MCP サーバープロセスの起動に失敗しました: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
