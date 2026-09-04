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
        request.timeoutInterval = 30.0
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

        request.httpBody = createMultipartBody(
            boundary: boundary,
            audioData: audioData,
            fileName: audioFileURL.lastPathComponent,
            mimeType: "audio/m4a",
            model: effectiveModel,
            mode: mode,
            prompt: prompt,
            language: language
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.networkError(error)
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
            return decoded.text
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
}
