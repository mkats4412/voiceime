import Foundation

/// リアルタイムプレビューと確定テキスト（Whisper / LLM 推敲後）の間で
/// 句読点（、。）や約物の整合性を保つための統一サービスクラス
public final class PunctuationService {
    public static let shared = PunctuationService()

    private init() {}

    /// 日本語および多言語の句読点補正・約物整形（リアルタイムプレビューおよび確定テキスト共通）
    public func format(text: String, isJapanese: Bool) -> String {
        guard !text.isEmpty else { return text }

        // 1. ユーザー辞書ルールの適用（「改行」➔ \n 等）
        var formatted = DictionaryService.shared.apply(
            text: text,
            rules: AppSettings.shared.dictionaryRules
        )

        guard isJapanese else { return formatted }

        // 0. 「〜です。よね」「〜でしょうか？ね」「〜ですか？ね」など、文末表現と終助詞が句読点や空白で誤って分断されたケースを最優先で修復
        // 例: 「あるんです。よね」➔「あるんですよね」
        // 例: 「どうでしょうか？ねぇ」➔「どうでしょうかねぇ」
        // 例: 「どうでしょうか？ね？」➔「どうでしょうかね？」
        let brokenParticlePattern = "([でまし]す|[でま]した|ません|ございま[すした]|でしょうか|ですか|ますか|でしたか|ましたか)([。、？！]?[ 　]*)(よね|よな|よ|ねえ|ねー|ねぇ|ね|かな|かね|し|もん|もの|さ)($|[。、？！]|[ 　\t]+|(?=[\\nあ-んア-ン一-龥a-zA-Z0-9]))"
        if let regexBP = try? NSRegularExpression(pattern: brokenParticlePattern, options: []) {
            let range = NSRange(location: 0, length: (formatted as NSString).length)
            formatted = regexBP.stringByReplacingMatches(in: formatted, options: [], range: range, withTemplate: "$1$3$4")
        }

        // 2. 挨拶表現（挨拶の直後に次の文が続く場合は読点「、」）
        let greetingPattern = "(おはようございます|こんにちは|こんばんは|お疲れ様です|お疲れ様でした)([ 　\t]+|(?=[あ-んア-ン一-龥a-zA-Z0-9]))"
        if let regexG = try? NSRegularExpression(pattern: greetingPattern, options: []) {
            let range = NSRange(location: 0, length: (formatted as NSString).length)
            formatted = regexG.stringByReplacingMatches(in: formatted, options: [], range: range, withTemplate: "$1、")
        }

        // 3. 接続詞・節の切れ目の読点「、」
        let clausePattern = "(ですが|ですので|ですから|けれども|けれど|ただし|一方で|また|そして)([ 　\t]+|(?=[あ-んア-ン一-龥a-zA-Z0-9]))"
        if let regexC = try? NSRegularExpression(pattern: clausePattern, options: []) {
            let range = NSRange(location: 0, length: (formatted as NSString).length)
            formatted = regexC.stringByReplacingMatches(in: formatted, options: [], range: range, withTemplate: "$1、")
        }

        // 4. 疑問・確認の文末表現（「でしょうか」「ですか」「ますか」など、終助詞「ねぇ」「ねー」「ね」「よ」「かな」等も含む）➔ 疑問符「？」
        // ※「でしょうか」の後ろに終助詞がある場合は、終助詞までを一体として捉え、決して途中に「？」を挟まない
        let questionPattern = "((?:でしょうか|ですか|ますか|でしたか|ましたか)(?:ね[えーぇ]?|よ[おー]?|よね[えーぇ]?|かな)?)(?![がからけどのでのにしたらたりなら])(?![ねよさわぞぜかもーえぇ])($|[ 　\t]+|(?=[\\nあ-んア-ン一-龥a-zA-Z0-9]))"
        if let regexQ = try? NSRegularExpression(pattern: questionPattern, options: []) {
            let range = NSRange(location: 0, length: (formatted as NSString).length)
            formatted = regexQ.stringByReplacingMatches(in: formatted, options: [], range: range, withTemplate: "$1？")
        }

        // 5. 一般文末表現（「ですよね」「ですね」「ですよ」「ますよね」などの複合終助詞を最優先）
        // ※「です」「ます」などの単独形は、後続に終助詞（よね/よ/ね/か等）や接続助詞（が/から/けど/ので/し等）がない場合のみ句点「。」を付与
        let fullEndings = [
            // 4文字以上・複合終助詞（最長一致）
            "ですよねー", "ですよねえ", "ですねー", "ですねえ", "ですよー",
            "ますよねー", "ますよねえ", "ますねー", "ますねえ", "ますよー",
            "でしたよね", "ましたよね", "ませんよね",
            "ですよね", "ますよね",
            // 3文字終助詞
            "ですね", "ですよ", "ますね", "ますよ",
            "でしたね", "でしたよ", "ましたね", "ましたよ",
            "ませんね", "ませんよ",
            // 敬体・丁寧表現
            "ございます", "ございました", "と思います", "と考えます", "とのことです",
            "ませんでした",
            "でした", "ました", "ません",
            // 終止形（後続に助詞が続かないことが条件）
            "です", "ます"
        ]

        let endingsPattern = "(\(fullEndings.joined(separator: "|")))(?![がからけどのでのにしたらたりならよねかもわぞぜさ])($|[ 　\t]+|(?=[\\nあ-んア-ン一-龥a-zA-Z0-9]))"
        if let regexE = try? NSRegularExpression(pattern: endingsPattern, options: []) {
            let range = NSRange(location: 0, length: (formatted as NSString).length)
            formatted = regexE.stringByReplacingMatches(in: formatted, options: [], range: range, withTemplate: "$1。")
        }

        // 6. 重複句読点および不自然な空白のクリーンアップ
        formatted = cleanupDuplicatePunctuation(formatted)

        return formatted
    }

    /// 重複した句読点や不自然な空白を整理
    public func cleanupDuplicatePunctuation(_ text: String) -> String {
        var result = text

        // 「です。よね」「ます。よね」「でしょうか？ね」等の誤った句読点挿入の修復
        let brokenParticlePattern = "([でまし]す|[でま]した|ません|ございま[すした]|でしょうか|ですか|ますか|でしたか|ましたか)([。、？！][ 　]*)(よね|よな|よ|ねえ|ねー|ねぇ|ね|かな|かね|し|もん|もの|さ)"
        if let regexBP = try? NSRegularExpression(pattern: brokenParticlePattern, options: []) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regexBP.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1$3")
        }

        // 連続・重複の除去
        result = result.replacingOccurrences(of: "。。", with: "。")
        result = result.replacingOccurrences(of: "、、", with: "、")
        result = result.replacingOccurrences(of: "、。", with: "。")
        result = result.replacingOccurrences(of: "。、", with: "。")
        result = result.replacingOccurrences(of: "？？", with: "？")
        result = result.replacingOccurrences(of: "？？", with: "？")
        result = result.replacingOccurrences(of: "？。", with: "？")
        result = result.replacingOccurrences(of: "。？", with: "？")
        result = result.replacingOccurrences(of: "！。", with: "！")
        result = result.replacingOccurrences(of: "。！", with: "！")
        result = result.replacingOccurrences(of: "、？", with: "？")
        result = result.replacingOccurrences(of: "、！", with: "！")

        // 句読点の直後の余分な空白（日本語文字が続く場合）を除去
        if let regexSpace = try? NSRegularExpression(pattern: "([。、？！])[ 　]+(?=[あ-んア-ン一-龥])", options: []) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regexSpace.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }

        // 疑問表現＋終助詞の末尾に句読点がない場合は疑問符「？」を補完
        let questionEndingParticles = [
            "でしょうかねぇ", "でしょうかねー", "でしょうかねえ", "でしょうかね",
            "どうですかねぇ", "どうですかねー", "どうですかねえ", "どうですかね",
            "ですかねぇ", "ですかねー", "ですかねえ", "ですかね",
            "ますかねぇ", "ますかねー", "ますかねえ", "ますかね",
            "でしたかねぇ", "でしたかねー", "でしたかねえ", "でしたかね",
            "ましたかねぇ", "ましたかねー", "ましたかねえ", "ましたかね"
        ]
        for qep in questionEndingParticles {
            if result.hasSuffix(qep) {
                result += "？"
                break
            }
        }

        // 末尾が一般終助詞（よね、ね、よ等）で句点がない場合は補完
        let endingParticles = ["ですよね", "ますよね", "ですね", "ですよ", "ますね", "ますよ", "でしたよね", "ましたよね", "ませんよね"]
        for ep in endingParticles {
            if result.hasSuffix(ep) {
                result += "。"
                break
            }
        }

        // 末尾が読点「、」で終わっている場合は「。」に変換
        if result.hasSuffix("、") {
            result = String(result.dropLast()) + "。"
        }

        return result
    }

    /// リアルタイムプレビューでユーザーが見ていたテキスト（referenceLiveText）の句読点・区切りを
    /// 最終テキスト（Whisper / LLM 推敲結果）に厳格に同期・反映させる
    public func alignPunctuation(
        text: String,
        referenceLiveText: String,
        isJapanese: Bool
    ) -> String {
        var formatted = format(text: text, isJapanese: isJapanese)
        let trimmedRef = referenceLiveText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard isJapanese, !trimmedRef.isEmpty else {
            return formatted
        }

        // 句読点・空白・改行を除去した純粋な文字列比較
        let cleanText = stripPunctuation(formatted)
        let cleanRef = stripPunctuation(trimmedRef)

        // 1. 純粋な発話内容が完全に一致する場合:
        // ユーザーがプレビュー画面で見ていた referenceLiveText そのものの句読点構造を最優先
        if cleanText == cleanRef {
            return format(text: trimmedRef, isJapanese: isJapanese)
        }

        // 2. プレビューが遅延して末尾が途切れている場合（cleanRef が cleanText の前方一致）:
        // 確定テキスト（formatted）の末尾の完全な文言を決して削らず、formatted を完全優先
        if cleanText.hasPrefix(cleanRef) {
            return cleanupDuplicatePunctuation(formatted)
        }

        // 3. 疑問文の整合性
        if trimmedRef.hasSuffix("？") || trimmedRef.hasSuffix("?") {
            if !formatted.hasSuffix("？") && !formatted.hasSuffix("?") {
                if formatted.hasSuffix("。") || formatted.hasSuffix(".") {
                    formatted = String(formatted.dropLast()) + "？"
                } else {
                    formatted += "？"
                }
            }
        }

        return cleanupDuplicatePunctuation(formatted)
    }

    /// 句読点や空白記号を除去したテキストを取得
    public func stripPunctuation(_ text: String) -> String {
        let punctuationChars: Set<Character> = ["、", "。", "，", "．", "？", "！", "?", "!", " ", "　", "\n", "\r", "\t", "・"]
        return text.filter { !punctuationChars.contains($0) }
    }
}
