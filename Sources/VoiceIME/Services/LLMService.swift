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
                        return "タイムアウト (8秒超過)"
                    } else if urlError.code == .notConnectedToInternet {
                        return "オフライン"
                    } else if urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost {
                        return "接続不能"
                    }
                }
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                    return "タイムアウト (8秒超過)"
                }
                return "通信エラー (\(error.localizedDescription))"
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

    /// OpenAI互換の /chat/completions エンドポイントにリクエストを送り、音声認識テキストを推敲・整形する
    public func refine(
        text: String,
        baseURL: String,
        apiKey: String?,
        model: String,
        promptHint: String? = nil,
        style: RefinementStyle = .casual,
        livePreviewText: String? = nil,
        isCustom: Bool = false
    ) async throws -> String {
        let trimmedInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return "" }

        guard let endpointURL = constructChatURL(from: baseURL) else {
            throw LLMError.invalidURL(baseURL)
        }

        let cleanApiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isCustom {
            guard let key = cleanApiKey, !key.isEmpty else {
                throw LLMError.missingAPIKey
            }
        }

        let systemPrompt = generateSystemPrompt(style: style, promptHint: promptHint, livePreviewText: livePreviewText)

        let template = AppSettings.shared.userPromptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? PromptConfig.defaultUserPromptTemplate
            : AppSettings.shared.userPromptTemplate

        let userPrompt: String
        if template.contains("{input}") {
            userPrompt = template.replacingOccurrences(of: "{input}", with: trimmedInput)
        } else {
            userPrompt = """
            \(template)

            <input>
            \(trimmedInput)
            </input>
            """
        }

        // Sarashina API (api.sarashina.ai) 等の厳格なスキーマ検証APIでは max_tokens が禁止 (disallowed) で max_completion_tokens を使用
        let initialUseMaxCompletionTokens = baseURL.contains("sarashina.ai")

        func sendRequest(useMaxCompletionTokens: Bool) async throws -> String {
            var payload: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ],
                "temperature": 0.0
            ]
            if useMaxCompletionTokens {
                payload["max_completion_tokens"] = 512
            } else {
                payload["max_tokens"] = 512
            }

            let httpBody: Data
            do {
                httpBody = try JSONSerialization.data(withJSONObject: payload)
            } catch {
                throw LLMError.parsingError(error)
            }

            var request = URLRequest(url: endpointURL)
            request.httpMethod = "POST"
            request.timeoutInterval = isCustom ? 15.0 : 8.0
            if let key = cleanApiKey, !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = httpBody

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
                        throw LLMError.networkError(error)
                    }
                } else {
                    throw LLMError.networkError(error)
                }
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMError.invalidResponse
            }

            if !(200...299).contains(httpResponse.statusCode) {
                let errorMsg = parseErrorMessage(from: data) ?? "Unknown error"

                // 400 Bad Request かつパラメータ不一致（disallowed / max_tokens / Invalid JSON）の場合、
                // max_completion_tokens に切り替えて1回だけ自動再試行
                if httpResponse.statusCode == 400 && !useMaxCompletionTokens {
                    let lower = errorMsg.lowercased()
                    if lower.contains("disallow") || lower.contains("invalid json") || lower.contains("max_tokens") || lower.contains("max_completion_tokens") {
                        NSLog("[VoiceIME] ⚠️ 400エラー検知 (%@)。max_completion_tokens に切り替えて再試行します...", errorMsg)
                        return try await sendRequest(useMaxCompletionTokens: true)
                    }
                }

                throw LLMError.serverError(statusCode: httpResponse.statusCode, message: errorMsg)
            }

            do {
                let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
                if let content = decoded.choices.first?.message.content {
                    return sanitizeLLMOutput(content, originalInput: trimmedInput, fallback: trimmedInput)
                }
                return trimmedInput
            } catch {
                throw LLMError.parsingError(error)
            }
        }

        return try await sendRequest(useMaxCompletionTokens: initialUseMaxCompletionTokens)
    }

    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    public struct ChatMessage: Equatable {
        public let role: String
        public let content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    /// AIクイック質問専用のシステムプロンプト (最大2行の簡潔な回答)
    public static let quickAskSystemPrompt = """
    あなたは超簡潔・的確なAI質問応答アシスタントです。
    ユーザーの質問に対して、必要最小限の【答えそのもの】だけを簡潔に返してください。

    【絶対厳守ルール】
    1. 出力は最大2行以内（目安100〜150文字以内）で、要点を絞った簡潔な回答にすること。
    2. 挨拶（こんにちは等）、前置き（答えは〜、質問について〜）、相槌、長々とした背景解説は一切出力禁止。
    3. 単語や数字を問われた場合は、その単語や数字だけを出力すること。
       - 例: 「ゴミの英語のスペルは?」 ➔ trash
       - 例: 「1 + 3 は?」 ➔ 4
       - 例: 「日本の首都は?」 ➔ 東京
       - 例: 「ありがとうのフランス語は?」 ➔ Merci
       - 例: 「1キロは何メートル?」 ➔ 1000m
    4. 理由や方法など文章での説明を求められた場合でも、最大2行以内で要点のみを簡潔にまとめて出力すること。
    5. 今日の天気、リアルタイムニュース、最新株価など、Web検索や外部参照が必要で手元に確実な答えを持っていない場合は、必ず以下のように角括弧付きで返してください:
       [答えを持っていません。]
    6. 「」や""などの引用符や、Markdown装飾（**太字**など）は付けず、純粋な答えの文字列のみを出力すること。
    """

    /// AIクイック質問（簡単な単語スペルや計算などを100文字以内で極小出力）
    public func quickAsk(
        question: String,
        history: [ChatMessage] = [],
        baseURL: String,
        apiKey: String?,
        model: String,
        isCustom: Bool = false
    ) async throws -> String {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else { return "" }

        guard let endpointURL = constructChatURL(from: baseURL) else {
            throw LLMError.invalidURL(baseURL)
        }

        let cleanApiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isCustom {
            guard let key = cleanApiKey, !key.isEmpty else {
                throw LLMError.missingAPIKey
            }
        }

        var messages: [[String: String]] = [
            ["role": "system", "content": Self.quickAskSystemPrompt]
        ]
        for msg in history {
            messages.append(["role": msg.role, "content": msg.content])
        }
        messages.append(["role": "user", "content": trimmedQuestion])

        let initialUseMaxCompletionTokens = baseURL.contains("sarashina.ai")

        func sendRequest(useMaxCompletionTokens: Bool) async throws -> String {
            var payload: [String: Any] = [
                "model": model,
                "messages": messages,
                "temperature": 0.0
            ]
            if useMaxCompletionTokens {
                payload["max_completion_tokens"] = 256
            } else {
                payload["max_tokens"] = 256
            }

            let httpBody: Data
            do {
                httpBody = try JSONSerialization.data(withJSONObject: payload)
            } catch {
                throw LLMError.parsingError(error)
            }

            var request = URLRequest(url: endpointURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key = cleanApiKey, !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = httpBody
            request.timeoutInterval = 15.0

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                throw LLMError.networkError(error)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMError.invalidResponse
            }

            if httpResponse.statusCode != 200 {
                if httpResponse.statusCode == 400 && !useMaxCompletionTokens {
                    let errMsg = parseErrorMessage(from: data) ?? ""
                    if errMsg.contains("disallow") || errMsg.contains("max_tokens") || errMsg.contains("Invalid JSON") {
                        return try await sendRequest(useMaxCompletionTokens: true)
                    }
                }
                let errorMsg = parseErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
                throw LLMError.serverError(statusCode: httpResponse.statusCode, message: errorMsg)
            }

            do {
                let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
                if let content = decoded.choices.first?.message.content {
                    return sanitizeQuickAskOutput(content)
                }
                return "[答えを持っていません。]"
            } catch {
                throw LLMError.parsingError(error)
            }
        }

        return try await sendRequest(useMaxCompletionTokens: initialUseMaxCompletionTokens)
    }

    /// クイック質問の出力を極小化・サニタイズ
    public func sanitizeQuickAskOutput(_ rawText: String) -> String {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "[答えを持っていません。]" }

        // 前置きラベルの除去
        let prefixes = [
            "答え：", "答え:", "回答：", "回答:", "結果：", "結果:",
            "Answer:", "A:", "Ans:", "Output:"
        ]
        for prefix in prefixes {
            if text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 全体を囲む引用符の除去
        if text.count >= 2 && ((text.hasPrefix("「") && text.hasSuffix("」")) ||
           (text.hasPrefix("『") && text.hasSuffix("』")) ||
           (text.hasPrefix("\"") && text.hasSuffix("\"")) ||
           (text.hasPrefix("'") && text.hasSuffix("'"))) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 行数が3行以上ある場合は最初の2行のみに制限
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if lines.count > 2 {
            text = lines.prefix(2).joined(separator: "\n")
        }

        // 200文字制限
        if text.count > 200 {
            text = String(text.prefix(200))
        }

        return text
    }

    /// LLMが体言止めや未完の文に対して勝手に補完した語尾（「〜ですね」「〜ですか？」「〜でしょうか」等のハルシネーション）を抑制・除去する
    public static func suppressHallucinatedEndings(output: String, originalInput: String) -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanInput = originalInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !cleanInput.isEmpty else { return text }

        // 句読点・空白・改行を除去した比較用文字列（元の発話内容に該当語尾が存在したかを厳格に判定）
        let strippedInput = cleanInput.replacingOccurrences(of: "[、。，．？！?! 　\\n\\t]+", with: "", options: .regularExpression)

        // 抑制対象となる語尾ハルシネーションパターン（元の発話に含まれていない場合のみ安全に除去）
        // (1) 〜ですね / 〜でしたね
        // (2) 〜ですか / 〜でしょうか
        // (3) 〜ますね / 〜ましたね
        let rules: [(token: String, pattern: String, template: String)] = [
            ("ですね", "([^\\n 　\t]+?)ですね([。？！?!]*)$", "$1。"),
            ("でしたね", "([^\\n 　\t]+?)でしたね([。？！?!]*)$", "$1。"),
            ("ですか", "([^\\n 　\t]+?)ですか[？?。]*$", "$1。"),
            ("でしょうか", "([^\\n 　\t]+?)でしょうか[？?。]*$", "$1。"),
            ("ますね", "([^\\n 　\t]+?)ますね([。？！?!]*)$", "$1。"),
            ("ましたね", "([^\\n 　\t]+?)ましたね([。？！?!]*)$", "$1。"),
        ]

        for rule in rules {
            if !strippedInput.contains(rule.token) {
                if let regex = try? NSRegularExpression(pattern: rule.pattern, options: []) {
                    let range = NSRange(location: 0, length: (text as NSString).length)
                    if let match = regex.firstMatch(in: text, options: [], range: range) {
                        let stem = (match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound) ? (text as NSString).substring(with: match.range(at: 1)) : ""
                        // 「どうですか」「いかがですか」などの自然な疑問詞表現は体言止めの語尾補完ではないため除外
                        if (rule.token == "ですか" || rule.token == "でしょうか") &&
                           (stem.hasSuffix("どう") || stem.hasSuffix("いかが") || stem.hasSuffix("なに") || stem.hasSuffix("何")) {
                            continue
                        }
                        text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: rule.template)
                    }
                }
            }
        }

        // 連続した句点の正規化
        while text.contains("。。") {
            text = text.replacingOccurrences(of: "。。", with: "。")
        }

        return text
    }

    /// LLMのレスポンスから <formatted_text> タグで囲まれた部分を抽出（Amical方式の構造化パース）
    public static func extractFormattedText(_ rawText: String) -> String {
        let pattern = "<formatted_text>([\\s\\S]*?)</formatted_text>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let nsText = rawText as NSString
            if let match = regex.firstMatch(in: rawText, options: [], range: NSRange(location: 0, length: nsText.length)),
               match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                return nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// LLMの出力から余分な前置きラベルや引用符を除去・サニタイズする
    /// - Parameters:
    ///   - rawText: LLMの生の出力文字列
    ///   - originalInput: ユーザーの元の音声認識テキスト（指定時、AIによる勝手な語尾補完ハルシネーションを抑制）
    ///   - fallback: 解析失敗時等のフォールバック文字列
    public func sanitizeLLMOutput(_ rawText: String, originalInput: String? = nil, fallback: String) -> String {
        // 1. <formatted_text> タグがあれば内部テキストを最優先抽出（Amical構造化パース）
        var text = Self.extractFormattedText(rawText)
        guard !text.isEmpty else { return fallback }

        // よくある前置きラベル（「整形後:」「修正後:」「出力:」など）の除去
        let prefixes = [
            "整形後：", "整形後:", "修正後：", "修正後:",
            "校正後：", "校正後:", "出力：", "出力:", "結果：", "結果:"
        ]
        for prefix in prefixes {
            if text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 全体を囲む引用符（「」、""、''）の除去
        if text.count >= 2 && ((text.hasPrefix("「") && text.hasSuffix("」")) ||
           (text.hasPrefix("『") && text.hasSuffix("』")) ||
           (text.hasPrefix("\"") && text.hasSuffix("\"")) ||
           (text.hasPrefix("'") && text.hasSuffix("'"))) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // originalInput が渡されている場合、元の発話テキストに存在しない勝手な語尾補完（ハルシネーション）を抑制
        if let orig = originalInput, !orig.isEmpty {
            text = Self.suppressHallucinatedEndings(output: text, originalInput: orig)
        }

        // LLMによるサ変動詞の不自然な重複（「表示するすることが」➔「表示することが」等）を除去
        let stutterPattern = "([一-龥ァ-ヶー]{2,})するする(こと|ため|ので|から|には|よう|べき|必要|場合|とき|時|の|が|を|は)"
        if let regexStutter = try? NSRegularExpression(pattern: stutterPattern, options: []) {
            let range = NSRange(location: 0, length: (text as NSString).length)
            text = regexStutter.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1する$2")
        }

        guard !text.isEmpty else { return fallback }
        return Self.normalizePunctuation(for: text)
    }

    /// 日本語特有の文字（ひらがな、カタカナ、漢字）が含まれているかを判定
    public static func containsJapaneseCharacters(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            // ひらがな: U+3040...U+309F
            // カタカナ: U+30A0...U+30FF
            // CJK統合漢字 / 互換漢字: U+4E00...U+9FFF, U+3400...U+4DBF, U+F900...U+FAFF
            if (0x3040...0x309F).contains(scalar.value) ||
               (0x30A0...0x30FF).contains(scalar.value) ||
               (0x4E00...0x9FFF).contains(scalar.value) ||
               (0x3400...0x4DBF).contains(scalar.value) ||
               (0xF900...0xFAFF).contains(scalar.value) {
                return true
            }
        }
        return false
    }

    /// 英文テキストや文末英文節における不自然な日本語句読点（。や、など）を英語の適切な約物（. や ,）に正規化
    public static func normalizePunctuation(for text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        let hasJapanese = containsJapaneseCharacters(result)
        if !hasJapanese {
            // 日本語文字（かな・漢字）が一切含まれない純粋な英文・アルファベット主体のテキスト
            result = result.replacingOccurrences(of: "、", with: ", ")
            result = result.replacingOccurrences(of: "，", with: ", ")
            result = result.replacingOccurrences(of: "。", with: ". ")
            result = result.replacingOccurrences(of: "？", with: "? ")
            result = result.replacingOccurrences(of: "！", with: "! ")
            result = result.replacingOccurrences(of: "：", with: ": ")

            // 連続空白およびピリオド等の直前の不自然な空白の調整
            while result.contains("  ") {
                result = result.replacingOccurrences(of: "  ", with: " ")
            }
            result = result.replacingOccurrences(of: " .", with: ".")
            result = result.replacingOccurrences(of: " ,", with: ",")
            result = result.replacingOccurrences(of: " ?", with: "?")
            result = result.replacingOccurrences(of: " !", with: "!")
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)

            // 末尾の句読点補正（。で終わっている場合は確実に.にする）
            if result.hasSuffix("。") {
                result = String(result.dropLast()).trimmingCharacters(in: .whitespaces) + "."
            } else if result.hasSuffix("？") {
                result = String(result.dropLast()).trimmingCharacters(in: .whitespaces) + "?"
            } else if result.hasSuffix("！") {
                result = String(result.dropLast()).trimmingCharacters(in: .whitespaces) + "!"
            }
        } else {
            // 日本語文字を含むテキストの場合:
            // 最後の文（改行または既存の句点「。」の後）が英文（アルファベットのみで日本語文字を含まない）で終わり、
            // その末尾が「。」になっている場合を救済する（例: "本日の議題:\nThank you for your help。"）
            if result.hasSuffix("。") {
                let withoutTrailingPeriod = String(result.dropLast())
                if let lastChar = withoutTrailingPeriod.last, lastChar.isASCII && (lastChar.isLetter || lastChar.isNumber) {
                    let lastSentence = withoutTrailingPeriod.components(separatedBy: CharacterSet(charactersIn: "。\n")).last ?? ""
                    if !lastSentence.isEmpty && !containsJapaneseCharacters(lastSentence) {
                        result = withoutTrailingPeriod + "."
                    }
                }
            } else if result.hasSuffix("？") {
                let withoutTrailingMark = String(result.dropLast())
                if let lastChar = withoutTrailingMark.last, lastChar.isASCII && (lastChar.isLetter || lastChar.isNumber) {
                    let lastSentence = withoutTrailingMark.components(separatedBy: CharacterSet(charactersIn: "。\n")).last ?? ""
                    if !lastSentence.isEmpty && !containsJapaneseCharacters(lastSentence) {
                        result = withoutTrailingMark + "?"
                    }
                }
            }
        }

        return result
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

    /// 指定された推敲スタイル（口語モード / 文章モード）に応じたシステムプロンプトを生成
    public func generateSystemPrompt(
        style: RefinementStyle,
        promptHint: String?,
        livePreviewText: String? = nil
    ) -> String {
        let settings = AppSettings.shared
        let basePrompt: String
        switch style {
        case .casual:
            let prompt = settings.systemPromptCasual.trimmingCharacters(in: .whitespacesAndNewlines)
            basePrompt = prompt.isEmpty ? PromptConfig.defaultCasualPrompt : prompt
        case .formal:
            let prompt = settings.systemPromptFormal.trimmingCharacters(in: .whitespacesAndNewlines)
            basePrompt = prompt.isEmpty ? PromptConfig.defaultFormalPrompt : prompt
        }

        var fullPrompt = basePrompt
        if let hint = promptHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            fullPrompt += "\n\n【参考用語・コンテキスト】\n\(hint)"
        }
        return fullPrompt
    }
}
