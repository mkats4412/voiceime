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

        // 2. 挨拶表現（挨拶の直後に次の文が続く場合は読点「、」）
        let greetingPattern = "(おはようございます|こんにちは|こんばんは|お疲れ様です|お疲れ様でした)(\\s+|(?=[あ-んア-ン一-龥a-zA-Z0-9]))"
        if let regexG = try? NSRegularExpression(pattern: greetingPattern, options: []) {
            let range = NSRange(location: 0, length: (formatted as NSString).length)
            formatted = regexG.stringByReplacingMatches(in: formatted, options: [], range: range, withTemplate: "$1、")
        }

        // 3. 接続詞・節の切れ目の読点「、」
        let clausePattern = "(ですが|ですので|ですから|けれども|けれど|ただし|一方で|また|そして)(\\s+|(?=[あ-んア-ン一-龥a-zA-Z0-9]))"
        if let regexC = try? NSRegularExpression(pattern: clausePattern, options: []) {
            let range = NSRange(location: 0, length: (formatted as NSString).length)
            formatted = regexC.stringByReplacingMatches(in: formatted, options: [], range: range, withTemplate: "$1、")
        }

        // 4. 疑問・確認の文末表現（「でしょうか」「ですか」「ますか」など）➔ 疑問符「？」
        let questionPattern = "(でしょうか|ですか|ますか|でしょうかね)($|\\s+|(?=[あ-んア-ン一-龥a-zA-Z0-9]))"
        if let regexQ = try? NSRegularExpression(pattern: questionPattern, options: []) {
            let range = NSRange(location: 0, length: (formatted as NSString).length)
            formatted = regexQ.stringByReplacingMatches(in: formatted, options: [], range: range, withTemplate: "$1？")
        }

        // 5. 一般文末表現（「です」「ます」など、接続助詞「が」「から」「けど」「ら」が続かない場合）➔ 句点「。」
        let endingsPattern = "(です|ます|でした|ました|ません|ませんでした|ですね|ですよ|ございます|ございました|と思います|と考えます|とのことです)(?![がからけどら])($|\\s+|(?=[あ-んア-ン一-龥a-zA-Z0-9]))"
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

        // 連続・重複の除去
        result = result.replacingOccurrences(of: "。。", with: "。")
        result = result.replacingOccurrences(of: "、、", with: "、")
        result = result.replacingOccurrences(of: "、。", with: "。")
        result = result.replacingOccurrences(of: "。、", with: "。")
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

        // 2. 文末の句読点（。や？）の整合性をプレビューと完全に同期
        if trimmedRef.hasSuffix("？") || trimmedRef.hasSuffix("?") {
            if !formatted.hasSuffix("？") && !formatted.hasSuffix("?") {
                if formatted.hasSuffix("。") || formatted.hasSuffix(".") {
                    formatted = String(formatted.dropLast()) + "？"
                } else {
                    formatted += "？"
                }
            }
        } else if trimmedRef.hasSuffix("。") || trimmedRef.hasSuffix(".") {
            if !formatted.hasSuffix("。") && !formatted.hasSuffix(".") && !formatted.hasSuffix("？") && !formatted.hasSuffix("！") {
                formatted += "。"
            }
        } else if !trimmedRef.hasSuffix("。") && !trimmedRef.hasSuffix("？") && !trimmedRef.hasSuffix("！") {
            // プレビュー文末に句点がなかった場合（体言止め等）、最終テキスト末尾の余計な「。」を削除してプレビューと一致させる
            if formatted.hasSuffix("。") && !cleanRef.isEmpty {
                let endings = ["です", "ます", "でした", "ました", "ません", "ですね", "ですよ", "ございます"]
                let hasEnding = endings.contains { cleanRef.hasSuffix($0) }
                if !hasEnding {
                    formatted = String(formatted.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
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
