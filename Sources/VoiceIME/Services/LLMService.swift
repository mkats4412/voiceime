import Foundation

public final class LLMService {
    public static let shared = LLMService()

    public enum LLMError: LocalizedError {
        case missingAPIKey
        case invalidURL(String)
        case networkError(Error)
        case serverError(statusCode: Int, message: String)
        case invalidResponse
        case parsingError(Error)

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "APIキーが設定されていません。"
            case .invalidURL(let url):
                return "無効なAPIエンドポイントURLです: \(url)"
            case .networkError(let error):
                return "ネットワークエラー: \(error.localizedDescription)"
            case .serverError(let statusCode, let message):
                return "LLM APIエラー (HTTP \(statusCode)): \(message)"
            case .invalidResponse:
                return "LLMからの応答が無効です。"
            case .parsingError(let error):
                return "LLMレスポンスの解析に失敗しました: \(error.localizedDescription)"
            }
        }
    }

    private init() {}

    /// OpenAI互換の /chat/completions エンドポイントにリクエストを送り、音声認識テキストを推敲・整形する
    public func refine(
        text: String,
        baseURL: String,
        apiKey: String?,
        model: String,
        promptHint: String? = nil
    ) async throws -> String {
        let trimmedInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return "" }

        guard let endpointURL = constructChatURL(from: baseURL) else {
            throw LLMError.invalidURL(baseURL)
        }

        guard let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw LLMError.missingAPIKey
        }

        var systemPrompt = """
        あなたは音声入力IMEの補正AIです。入力された音声認識テキストを、文脈や背景・話題に沿った自然で読みやすい文章に整形して本文のみ出力してください。

        【補正ルール】
        1. 話題・背景の推論と固有名詞・聞き間違いの修復:
           - 全体の文脈から何についての話題（時事、スポーツ、技術、日常会話など）かを推論し、音声認識の聞き間違いや音の混同（母音のズレ・濁音等）を文脈に合致した正しい固有名詞・人名・用語に整える（例: ドジャースの文脈での「ルバーツ」➔「ロバーツ」、「マイコのテスト」➔「マイクのテスト」）。
           - 同一文脈内での表記揺れや誤認（例: 「ドジャース」と「ドジャーズ」等）があれば、文脈から判断して正しい実在名称に統一する。
        2. 疑問・質問・確認の文末（「ですか」「ますか」「でしょうか」「どうですか」等）の「。」は疑問符「？」にする（例: 「どうですか。」➔「どうですか？」、「どうでしょうか。」➔「どうでしょうか？」）。
        3. 挨拶表現（「こんにちは」「おはようございます」「お疲れ様です」等）の直後は、句点「。」ではなく読点「、」にする（例: 「こんにちは。」➔「こんにちは、」）。
        4. 「えー」「あのー」などのフィラーは削除し、文脈に応じた適切な読点「、」や句点「。」を付与する。
        5. 語調（敬体・常体など）や話者の意図を勝手に改変せず、解説や挨拶・引用符は付けずに整形後のテキストのみを出力する。
        """

        if let hint = promptHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            systemPrompt += "\n\n【参考用語・コンテキスト】\n\(hint)"
        }

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": trimmedInput]
            ],
            "temperature": 0.0,
            "max_tokens": 1024
        ]

        let httpBody: Data
        do {
            httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw LLMError.parsingError(error)
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15.0
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let errorMsg = parseErrorMessage(from: data) ?? "Unknown error"
            throw LLMError.serverError(statusCode: httpResponse.statusCode, message: errorMsg)
        }

        do {
            struct ChatCompletionResponse: Decodable {
                struct Choice: Decodable {
                    struct Message: Decodable {
                        let content: String?
                    }
                    let message: Message
                }
                let choices: [Choice]
            }

            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            if let content = decoded.choices.first?.message.content {
                let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmedContent.isEmpty ? trimmedInput : trimmedContent
            }
            return trimmedInput
        } catch {
            throw LLMError.parsingError(error)
        }
    }

    /// Base URLから /chat/completions エンドポイントURLを構築
    public func constructChatURL(from baseURL: String) -> URL? {
        var cleanURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanURL.hasSuffix("/audio/transcriptions") {
            cleanURL = String(cleanURL.dropLast("/audio/transcriptions".count))
        } else if cleanURL.hasSuffix("/audio/translations") {
            cleanURL = String(cleanURL.dropLast("/audio/translations".count))
        } else if cleanURL.hasSuffix("/chat/completions") {
            cleanURL = String(cleanURL.dropLast("/chat/completions".count))
        }

        while cleanURL.hasSuffix("/") {
            cleanURL = String(cleanURL.dropLast())
        }

        return URL(string: "\(cleanURL)/chat/completions")
    }

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
