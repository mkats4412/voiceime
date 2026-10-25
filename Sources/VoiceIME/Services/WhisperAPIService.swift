import Foundation

public final class WhisperAPIService {
    public static let shared = WhisperAPIService()

    public enum APIError: LocalizedError {
        case missingAPIKey
        case invalidURL(String)
        case emptyAudioFile
        case networkError(Error)
        case serverError(statusCode: Int, message: String)
        case invalidResponse
        case parsingError(Error)

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "APIキーが設定されていません。設定画面でAPIキーを入力してください。"
            case .invalidURL(let url):
                return "無効なAPIエンドポイントURLです: \(url)"
            case .emptyAudioFile:
                return "音声ファイルが存在しないか空です。"
            case .networkError(let error):
                return "ネットワークエラー: \(error.localizedDescription)"
            case .serverError(let statusCode, let message):
                return "APIエラー (HTTP \(statusCode)): \(message)"
            case .invalidResponse:
                return "サーバーからの応答が無効です。"
            case .parsingError(let error):
                return "レスポンスの解析に失敗しました: \(error.localizedDescription)"
            }
        }

        public var summary: String {
            switch self {
            case .serverError(let statusCode, let message):
                if statusCode == 429 {
                    return "レート制限 (429)"
                } else if statusCode == 503 || statusCode == 502 || statusCode == 504 {
                    return "サーバー混雑 (\(statusCode))"
                } else if statusCode == 500 {
                    return "サーバーエラー (500)"
                } else if statusCode == 400 {
                    let shortMsg = message.count > 25 ? "\(message.prefix(25))..." : message
                    return "リクエスト不正 (400: \(shortMsg))"
                } else if statusCode == 401 {
                    return "認証エラー (401)"
                } else if statusCode == 404 {
                    return "未対応モデル/URL (404)"
                } else {
                    return "HTTP \(statusCode)"
                }
            case .networkError(let error):
                if let urlError = error as? URLError {
                    if urlError.code == .timedOut {
                        return "タイムアウト (15秒超過)"
                    } else if urlError.code == .notConnectedToInternet {
                        return "オフライン"
                    } else if urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost {
                        return "接続不能"
                    }
                }
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                    return "タイムアウト (15秒超過)"
                }
                return "通信エラー (\(error.localizedDescription))"
            case .emptyAudioFile:
                return "音声データが空"
            case .missingAPIKey:
                return "APIキー未設定"
            case .invalidURL:
                return "無効なURL"
            case .invalidResponse:
                return "無効な応答"
            case .parsingError:
                return "解析エラー"
            }
        }
    }

    private init() {}

    /// 音声ファイルをOpenAI互換APIに送信してテキストに変換する
    public func transcribe(
        audioFileURL: URL,
        baseURL: String,
        apiKey: String?,
        model: String,
        mode: SpeechAPIMode = .transcriptions,
        prompt: String? = nil,
        language: String? = nil
    ) async throws -> String {
        guard let endpointURL = constructEndpointURL(from: baseURL, mode: mode) else {
            throw APIError.invalidURL(baseURL)
        }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioFileURL)
        } catch {
            throw APIError.emptyAudioFile
        }

        guard !audioData.isEmpty else {
            throw APIError.emptyAudioFile
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15.0
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        if let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // Groq等のWhisper APIでは、turboモデル（whisper-large-v3-turbo）は /audio/translations（英語翻訳）エンドポイントに非対応（HTTP 404: Invalid URL となる）。
        // 翻訳モード時は、Groqが翻訳に対応している標準モデル「whisper-large-v3」へ自動的に切り替えてリクエストする。
        let effectiveModel: String
        if mode == .translations && model.contains("turbo") {
            effectiveModel = "whisper-large-v3"
        } else {
            effectiveModel = model
        }

        // Amicalのwhisper-prompt設計を参考にした安全なプロンプト最適化
        let sanitizedPrompt = prompt.map { Self.sanitizeWhisperPrompt($0) }

        let isWAV = audioFileURL.pathExtension.lowercased() == "wav"
        request.httpBody = createMultipartBody(
            boundary: boundary,
            audioData: audioData,
            fileName: audioFileURL.lastPathComponent,
            mimeType: isWAV ? "audio/wav" : "audio/m4a",
            model: effectiveModel,
            mode: mode,
            prompt: sanitizedPrompt,
            language: language
        )

        var (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Keep-Alive アイドル切断（-1005: networkConnectionLost）の即時1回自動リトライ
            if let urlErr = error as? URLError, urlErr.code == .networkConnectionLost {
                NSLog("[VoiceIME] ⚠️ Keep-Alive切断(-1005)を検知。新規接続で即時再試行します...")
                do {
                    (data, response) = try await URLSession.shared.data(for: request)
                } catch {
                    throw APIError.networkError(error)
                }
            } else {
                throw APIError.networkError(error)
            }
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let rawError = parseErrorMessage(from: data) ?? "Unknown error"
            var message = rawError
            if httpResponse.statusCode == 404 && mode == .translations {
                message = "\(rawError) (翻訳APIには whisper-large-v3 等の翻訳対応モデルが必要です)"
            }
            throw APIError.serverError(statusCode: httpResponse.statusCode, message: message)
        }

        do {
            struct TranscriptionResponse: Decodable {
                let text: String
            }
            let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
            return Self.sanitizeWhisperOutput(decoded.text)
        } catch {
            throw APIError.parsingError(error)
        }
    }

    /// Base URLから適切なエンドポイントURL（transcriptions または translations）を構築
    public func constructEndpointURL(from baseURL: String, mode: SpeechAPIMode) -> URL? {
        var cleanURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // 既存の末尾パス (/audio/transcriptions や /audio/translations) を除去して正規化
        if cleanURL.hasSuffix("/audio/transcriptions") {
            cleanURL = String(cleanURL.dropLast("/audio/transcriptions".count))
        } else if cleanURL.hasSuffix("/audio/translations") {
            cleanURL = String(cleanURL.dropLast("/audio/translations".count))
        }

        while cleanURL.hasSuffix("/") {
            cleanURL = String(cleanURL.dropLast())
        }

        let endpointPath: String
        switch mode {
        case .transcriptions:
            endpointPath = "/audio/transcriptions"
        case .translations:
            endpointPath = "/audio/translations"
        }

        return URL(string: "\(cleanURL)\(endpointPath)")
    }

    /// multipart/form-data 形式のHTTPボディを生成
    private func createMultipartBody(
        boundary: String,
        audioData: Data,
        fileName: String,
        mimeType: String,
        model: String,
        mode: SpeechAPIMode,
        prompt: String?,
        language: String?
    ) -> Data {
        var body = Data()

        func appendString(_ string: String) {
            if let data = string.data(using: .utf8) {
                body.append(data)
            }
        }

        func appendField(name: String, value: String) {
            appendString("--\(boundary)\r\n")
            appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            appendString("\(value)\r\n")
        }

        // model
        appendField(name: "model", value: model)

        // response_format
        appendField(name: "response_format", value: "json")

        // language (transcriptions モード時のみ適用)
        if mode == .transcriptions, let language = language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
            appendField(name: "language", value: language)
        }

        // prompt
        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            appendField(name: "prompt", value: prompt)
        }

        // audio file
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(audioData)
        appendString("\r\n")

        // closing boundary
        appendString("--\(boundary)--\r\n")

        return body
    }

    /// エラーレスポンスJSONからメッセージを取り出す
    private func parseErrorMessage(from data: Data) -> String? {
        struct ErrorWrapper: Decodable {
            struct ErrorDetail: Decodable {
                let message: String?
            }
            let error: ErrorDetail?
            let message: String?
        }

        if let wrapper = try? JSONDecoder().decode(ErrorWrapper.self, from: data) {
            if let msg = wrapper.error?.message, !msg.isEmpty {
                return msg
            }
            if let msg = wrapper.message, !msg.isEmpty {
                return msg
            }
        }
        return String(data: data, encoding: .utf8)
    }

    /// Whisper APIの initial_prompt を安全に最適化・サニタイズする (Amical の設計を参考)
    /// - Groqの896バイト上限（Whisperの~224トークン上限）を考慮し、UTF-8境界を守りながら安全に切り詰める
    /// - 連続する余分な空白（改行含む）を単一スペースに丸めて、多言語トークナイザーの文字化け・中国語ハルシネーションを防ぐ
    public static func sanitizeWhisperPrompt(_ prompt: String, maxBytes: Int = 800) -> String {
        // 空白・改行の連続を単一スペースに正規化
        let collapsed = prompt.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "" }

        guard let data = collapsed.data(using: .utf8) else { return collapsed }
        if data.count <= maxBytes {
            return collapsed
        }

        // 先頭側からバイト単位で切り詰め、かつUTF-8文字境界を壊さないよう調整
        // （Whisperは文末・末尾側のコンテキストを最優先するため、末尾を残す）
        var startIndex = data.count - maxBytes
        // UTF-8継続バイト (0b10xxxxxx: 0x80..0xBF) の間は進めて先頭バイト (0b0xxxxxxx または 0b11xxxxxx) を探す
        while startIndex < data.count && (data[startIndex] & 0xC0) == 0x80 {
            startIndex += 1
        }

        let subdata = data.subdata(in: startIndex..<data.count)
        return String(data: subdata, encoding: .utf8) ?? collapsed
    }

    /// Whisper APIの出力テキストから、無音・微小ノイズ特有の既知のハルシネーション（"Thank you.", "ご視聴ありがとうございました" 等）
    /// およびトークン反復ループ（"XXXX...", "ああああああ..." 等の4連続以上の異常反復）を完全除去
    public static func sanitizeWhisperOutput(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        // 1. 同一文字の異常連続（4回以上の繰り返し: 例 "XXXX...", "・・・・", "！！！！" 等）をカット
        // ※ 通常の日本語・英語会話で4回以上同一文字が連続することはなく、Whisperの自己回帰ループバグのため除去
        if let repeatRegex = try? NSRegularExpression(pattern: "(.)\\1{3,}", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = repeatRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let hallucinationPatterns = [
            "(?i)[ \t]*(?:Thank you(?: very much)?|Thanks for watching|Subtitles by[^\n\r]*)[ \t\\.\\,\\!\\?]*",
            "[ \t]*(?:ご視聴ありがとうございました|ご視聴ありがとうござい[ました]*|視聴ありがとうございました|チャンネル登録(?:よろしく[お願いたし]*|お願い[いたし]*)*)[ \t。、！？\\.]*"
        ]
        for pattern in hallucinationPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
                result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return result
    }
}
