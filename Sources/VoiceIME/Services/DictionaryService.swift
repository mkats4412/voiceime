import Foundation

public final class DictionaryService {
    public static let shared = DictionaryService()

    private init() {}

    /// 登録された辞書置換ルールを順次適用する
    public func apply(
        text: String,
        rules: [DictionaryRule]
    ) -> String {
        var result = text

        for rule in rules where rule.isEnabled && !rule.pattern.isEmpty {
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
            } else {
                result = result.replacingOccurrences(of: rule.pattern, with: unescapedReplacement)
            }
        }

        return result
    }

    /// エスケープ文字列 (\n, \t) を実際の改行やタブ記号に変換
    private func unescapeSpecialCharacters(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\r", with: "\r")
    }
}
