import Foundation

/// リアルタイム音声認識で英語発話が日本語エンジンによりカタカナ音訳された際、
/// キーを押している間に瞬時に自然な英単語・英文へと逆変換する高速コンバータ
public final class KatakanaEnglishConverter {
    public static let shared = KatakanaEnglishConverter()

    /// カタカナ ➔ 英単語マッピングテーブル（最長一致検索用）
    private let katakanaToEnglish: [String: String] = [
        // 疑問詞・助動詞・代名詞
        "ディドユー": "did you",
        "ディッドユー": "did you",
        "デュー": "did you",
        "ディド": "did",
        "ディッド": "did",
        "ドゥユー": "do you",
        "ドゥーユー": "do you",
        "ドゥ": "do",
        "ドゥー": "do",
        "ダズ": "does",
        "ダズント": "doesn't",
        "ドント": "don't",
        "ディドント": "didn't",
        "キャンユー": "can you",
        "キャン": "can",
        "キャント": "can't",
        "クッドユー": "could you",
        "クドユー": "could you",
        "クッド": "could",
        "クド": "could",
        "ウッドユー": "would you",
        "ウドユー": "would you",
        "ウッド": "would",
        "ウド": "would",
        "シュッド": "should",
        "シュド": "should",
        "ウィルユー": "will you",
        "ウィル": "will",
        "ウォウント": "won't",
        "メイアイ": "may I",
        "メイ": "may",
        "マスト": "must",

        // 代名詞
        "アイ": "I",
        "ユー": "you",
        "ヒー": "he",
        "シー": "she",
        "イット": "it",
        "ウィー": "we",
        "ゼイ": "they",
        "ミー": "me",
        "ヒム": "him",
        "ハー": "her",
        "アス": "us",
        "ゼム": "them",
        "マイ": "my",
        "ユア": "your",
        "ヒズ": "his",
        "アワ": "our",
        "ディス": "this",
        "ザット": "that",
        "ジーズ": "these",
        "ドーズ": "those",
        "ホワット": "what",
        "ワット": "what",
        "ホエア": "where",
        "ウェア": "where",
        "ホエン": "when",
        "ウェン": "when",
        "ホワイ": "why",
        "ワイ": "why",
        "ハウ": "how",
        "フー": "who",
        "ウィッチ": "which",

        // be動詞
        "アム": "am",
        "アー": "are",
        "アール": "are",
        "イズ": "is",
        "ワズ": "was",
        "ワー": "were",
        "ビーン": "been",

        // 挨拶・日常フレーズ
        "ハロー": "hello",
        "ワールド": "world",
        "ハイ": "hi",
        "グッドモーニング": "good morning",
        "モーニング": "morning",
        "グッドアフタヌーン": "good afternoon",
        "グッドイブニング": "good evening",
        "グッドナイト": "good night",
        "グッドバイ": "goodbye",
        "バイバイ": "bye bye",
        "サンキューベリーマッチ": "thank you very much",
        "サンキュー": "thank you",
        "センキュー": "thank you",
        "テンキュー": "thank you",
        "ユーアーウェルカム": "you're welcome",
        "ウェルカム": "welcome",
        "プリーズ": "please",
        "ソーリー": "sorry",
        "エクスキューズミー": "excuse me",
        "ナイスツゥミートゥユー": "nice to meet you",
        "ナイス": "nice",
        "グッド": "good",
        "グレイト": "great",
        "クール": "cool",
        "ファイン": "fine",
        "オーケー": "OK",
        "オッケー": "OK",
        "イエス": "yes",
        "ノー": "no",
        "シュア": "sure",
        "オフコース": "of course",
        "リアル": "real",
        "リアリー": "really",

        // 基本動詞
        "フィニッシュ": "finish",
        "フィニッシュド": "finished",
        "ハブ": "have",
        "ハズ": "has",
        "ハド": "had",
        "ゲット": "get",
        "ゴット": "got",
        "メイク": "make",
        "メイド": "made",
        "ゴー": "go",
        "ウェント": "went",
        "ゴーン": "gone",
        "カム": "come",
        "ケイム": "came",
        "テイク": "take",
        "トゥック": "took",
        "テイケン": "taken",
        "シーン": "seen",
        "ルック": "look",
        "ルックト": "looked",
        "ウォッチ": "watch",
        "シンク": "think",
        "ソート": "thought",
        "ノウ": "know",
        "ニュー": "knew",
        "ノウン": "known",
        "テル": "tell",
        "トールド": "told",
        "セイ": "say",
        "セッド": "said",
        "スピーク": "speak",
        "スポーク": "spoke",
        "トーク": "talk",
        "アスク": "ask",
        "ギブ": "give",
        "ゲイブ": "gave",
        "ギブン": "given",
        "ヘルプ": "help",
        "ワーク": "work",
        "コール": "call",
        "トライ": "try",
        "ニード": "need",
        "ウォント": "want",
        "ファインド": "find",
        "ファウンド": "found",
        "ユーズ": "use",
        "スタート": "start",
        "ストップ": "stop",
        "オープン": "open",
        "クローズ": "close",
        "チェンジ": "change",
        "チェック": "check",
        "プット": "put",
        "セット": "set",
        "キープ": "keep",
        "レット": "let",
        "リーヴ": "leave",
        "リーブ": "leave",
        "レフト": "left",
        "ミート": "meet",
        "メット": "met",
        "ブリング": "bring",
        "ライト": "write",
        "ローテ": "wrote",
        "リトゥン": "written",
        "リード": "read",
        "ラン": "run",
        "プレイ": "play",
        "ムーヴ": "move",
        "ムーブ": "move",
        "リブ": "live",
        "ライブ": "live",
        "ライク": "like",
        "ラヴ": "love",
        "ラブ": "love",
        "ホープ": "hope",
        "ウィッシュ": "wish",
        "ウェイト": "wait",
        "ステイ": "stay",
        "センド": "send",
        "セント": "sent",
        "クリエイト": "create",
        "ビギン": "begin",
        "エンド": "end",
        "ショウ": "show",
        "ショー": "show",
        "アンダースタンド": "understand",

        // 前置詞・冠詞・接続詞・副詞
        "ア": "a",
        "アン": "an",
        "ザ": "the",
        "ジ": "the",
        "トゥー": "to",
        "ツゥ": "to",
        "イン": "in",
        "オン": "on",
        "アット": "at",
        "フォー": "for",
        "ウィズ": "with",
        "バイ": "by",
        "フロム": "from",
        "アバウト": "about",
        "オブ": "of",
        "アンド": "and",
        "バット": "but",
        "オア": "or",
        "ソー": "so",
        "イフ": "if",
        "ゼン": "then",
        "ビコーズ": "because",
        "ナウ": "now",
        "ヒア": "here",
        "ゼア": "there",
        "オールウェイズ": "always",
        "エブリデイ": "every day",
        "サムタイムズ": "sometimes",
        "ネバー": "never",
        "ベリー": "very",
        "マッチ": "much",
        "メニー": "many",
        "モア": "more",
        "モスト": "most",
        "オール": "all",
        "サム": "some",
        "エニー": "any",

        // IT・プログラミング・ビジネス一般名詞
        "コード": "code",
        "ファイル": "file",
        "プロジェクト": "project",
        "プログラム": "program",
        "アプリ": "app",
        "ウェブ": "web",
        "サイト": "site",
        "サーバー": "server",
        "クライアント": "client",
        "データ": "data",
        "ベース": "base",
        "ユーザー": "user",
        "システム": "system",
        "エラー": "error",
        "バグ": "bug",
        "テスト": "test",
        "リリース": "release",
        "コミット": "commit",
        "プッシュ": "push",
        "プル": "pull",
        "マージ": "merge",
        "ブランチ": "branch",
        "ビルド": "build",
        "デプロイ": "deploy",
        "リクエスト": "request",
        "レスポンス": "response",
        "ページ": "page",
        "テキスト": "text",
        "ペン": "pen",
        "ブック": "book",
        "ノート": "note",
        "タイム": "time",
        "デイ": "day",
        "トゥデイ": "today",
        "トゥモロー": "tomorrow",
        "イエスタデイ": "yesterday",
        "パーソン": "person",
        "ピープル": "people",
        "チーム": "team",
        "ミーティング": "meeting",
        "タスク": "task",
        "プライオリティ": "priority"
    ]

    private lazy var sortedKeys: [String] = {
        katakanaToEnglish.keys.sorted { $0.count > $1.count }
    }()

    private init() {}

    /// カタカナ文字列を英語文字列に逆変換
    public func convertToEnglish(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return text }

        // スペースまたは中黒で区切られている場合は単語ごとに変換を試みる
        let hasSpaces = cleaned.contains(" ") || cleaned.contains("　") || cleaned.contains("・")
        if hasSpaces {
            let tokens = cleaned.components(separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "・")))
            var words: [String] = []
            for token in tokens where !token.isEmpty {
                if let mapped = katakanaToEnglish[token] {
                    words.append(mapped)
                } else {
                    // 単語単位でも最長一致で分解
                    words.append(tokenizeGreedy(token))
                }
            }
            return formatEnglishSentence(words.joined(separator: " "))
        } else {
            // スペース区切りがない一連のカタカナ（例: "ディドユーフィニッシュイット"）
            let converted = tokenizeGreedy(cleaned)
            return formatEnglishSentence(converted)
        }
    }

    /// 与えられたカタカナ文字列が辞書によって英語に変換可能かどうかを判定
    public func hasConversion(for text: String) -> Bool {
        let converted = convertToEnglish(text)
        return converted != text && converted.unicodeScalars.contains { CharacterSet.letters.contains($0) && $0.value < 0x200 }
    }

    /// 最長一致（Greedy）アルゴリズムによる連続カタカナの分解変換
    private func tokenizeGreedy(_ text: String) -> String {
        var remaining = text
        var resultWords: [String] = []

        while !remaining.isEmpty {
            var matched = false
            for key in sortedKeys {
                if remaining.hasPrefix(key) {
                    resultWords.append(katakanaToEnglish[key]!)
                    remaining.removeFirst(key.count)
                    matched = true
                    break
                }
            }
            if !matched {
                // 辞書にない未知のカタカナ部分は1文字進める
                let char = remaining.removeFirst()
                resultWords.append(String(char))
            }
        }

        // 連続するアルファベット単語を綺麗に空白結合
        return resultWords.joined(separator: " ")
    }

    /// 文頭の大文字化など英語表現の整形
    private func formatEnglishSentence(_ text: String) -> String {
        var words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !words.isEmpty else { return text }

        // 文頭単語のキャピタライズ
        if let firstWord = words.first, !firstWord.isEmpty {
            words[0] = firstWord.prefix(1).uppercased() + firstWord.dropFirst()
        }

        var result = words.joined(separator: " ")

        // 疑問詞で始まっている、または did you / do you / can you 等の疑問文パターンの場合は末尾に「?」を付与
        let lower = result.lowercased()
        let questionStarters = ["did you", "do you", "can you", "could you", "would you", "will you", "what", "where", "when", "why", "how", "who", "which", "are you", "is it", "is this"]
        for starter in questionStarters {
            if lower.hasPrefix(starter) {
                if !result.hasSuffix("?") && !result.hasSuffix("？") {
                    result += "?"
                }
                break
            }
        }

        return result
    }
}
