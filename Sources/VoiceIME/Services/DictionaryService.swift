import Foundation

public final class DictionaryService {
    public static let shared = DictionaryService()

    private init() {}

    /// 登録された辞書置換ルールを順次適用する
    /// - VoiceInk の WordReplacementVariants / WordReplacementService と同様、非正規表現ルールではカンマ区切り（`,`）の複数トリガー指定に対応し、
    ///   短い語句（「かぎかっこ」等）が長い語句（「かぎかっことじ」「とじかぎかっこ」等）の一部を先に誤置換しないよう文字数降順（最長一致優先）で適用する
    public func apply(
        text: String,
        rules: [DictionaryRule]
    ) -> String {
        var result = text
        let enabledRules = rules.filter { $0.isEnabled && !$0.pattern.isEmpty }
        guard !enabledRules.isEmpty else { return result }

        for rule in enabledRules {
            let unescapedReplacement = unescapeSpecialCharacters(rule.replacement)

            if rule.isRegex {
                do {
                    let regex = try NSRegularExpression(pattern: rule.pattern, options: [])
                    let range = NSRange(result.startIndex..<result.endIndex, in: result)
                    result = regex.stringByReplacingMatches(
                        in: result,
                        options: [],
                        range: range,
                        withTemplate: unescapedReplacement
                    )
                } catch {
                    result = result.replacingOccurrences(of: rule.pattern, with: unescapedReplacement)
                }
            } else if unescapedReplacement == "\n" {
                // 「改行」➔「\n」の置換時:
                // - 「改行のテスト」「改行を入れる」「改行コード」など、文中の名詞として使われている「改行」（直後に助詞「の・を・が・は・に・で・も・と」や複合語が続く場合）は改行コードに変換せず名詞として残す
                // - 「改行。」のように直後に句読点がある場合は「。」ごと吸収して次の行頭に「\n。」が残るのを防止する
                let variants = Self.parseLiteralVariants(rule.pattern)
                for variant in variants {
                    let escapedPattern = NSRegularExpression.escapedPattern(for: variant)
                    let nounFollowLookahead = "(?![のをがはにでもとやへかコキ位文テル設機])"

                    if let regexWithTrailingPeriod = try? NSRegularExpression(
                        pattern: "([。、，．？！?!]?)[ 　\t]*\(escapedPattern)\(nounFollowLookahead)[ 　\t]*([。、，．]+)[ 　\t]*\\n?",
                        options: []
                    ) {
                        let nsResult = result as NSString
                        let matches = regexWithTrailingPeriod.matches(in: result, options: [], range: NSRange(location: 0, length: nsResult.length))
                        for match in matches.reversed() {
                            let leadingPunct = (match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound) ? nsResult.substring(with: match.range(at: 1)) : ""
                            let finalPunct: String
                            if leadingPunct == "？" || leadingPunct == "?" {
                                finalPunct = "？"
                            } else if leadingPunct == "！" || leadingPunct == "!" {
                                finalPunct = "！"
                            } else {
                                finalPunct = "。"
                            }
                            result = (result as NSString).replacingCharacters(in: match.range, with: "\(finalPunct)\n")
                        }
                    }

                    if let regexPlainNewline = try? NSRegularExpression(
                        pattern: "\(escapedPattern)\(nounFollowLookahead)",
                        options: []
                    ) {
                        let range = NSRange(location: 0, length: (result as NSString).length)
                        result = regexPlainNewline.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: unescapedReplacement)
                    }
                }
            } else {
                let variants = Self.parseLiteralVariants(rule.pattern)
                for variant in variants {
                    result = result.replacingOccurrences(of: variant, with: unescapedReplacement)
                }
            }
        }

        return result
    }

    /// 非正規表現ルールのパターン文字列からカンマ区切りの表記揺れ候補を展開し、文字数の長い順（最長一致優先）で返す
    public static func parseLiteralVariants(_ rawPattern: String) -> [String] {
        guard rawPattern.count > 1, rawPattern.contains(",") else {
            return [rawPattern]
        }
        let parts = rawPattern
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return [rawPattern] }
        return parts.sorted { $0.count > $1.count }
    }

    /// エスケープ文字列 (\n, \t) を実際の改行やタブ記号に変換
    private func unescapeSpecialCharacters(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\r", with: "\r")
    }
}
