import Foundation

/// リアルタイムプレビューと確定テキスト（Whisper / LLM 推敲後）の間で
/// 句読点（、。）や約物の整合性を保つための統一サービスクラス
public final class PunctuationService {
    public static let shared = PunctuationService()

    private init() {}

    /// 日本語および多言語の句読点補正・約物整形（リアルタイムプレビューおよび確定テキスト共通）
    public func format(text: String, isJapanese: Bool) -> String {
        guard !text.isEmpty else { return text }

        var formatted = text

        // 0-a. 辞書置換（「改行」➔ \n）の前に、日本語・英語の音声コマンド「改行」「開業」「かいぎょう」「new line」「new paragraph」と前後の句読点（。、.,）を一括正規化
        // これにより「改行。」や「New line.」が辞書置換で「\n。」となって次の行頭に「。」だけ残る現象を根絶する
        formatted = normalizeNewlineVoiceCommand(formatted)

        // 1. ユーザー辞書ルールの適用（「改行」➔ \n、括弧ルール等）
        formatted = DictionaryService.shared.apply(
            text: formatted,
            rules: AppSettings.shared.dictionaryRules
        )

        // 1-b. 括弧・引用符（「」、（）、()、[]、{}、"" 等）の直後や閉じ括弧の直前・直後に混入した不要な句点・ピリオド・読点を除去
        formatted = cleanupBracketPunctuation(formatted)

        // 0-b. 辞書適用後にも残っている「開業」「かいぎょう」「new line」および行頭の孤立句読点を正規化
        formatted = normalizeNewlineVoiceCommand(formatted)

        guard isJapanese else { return formatted }

        // 0-c. 「〜です。よね」「〜でしょうか？ね」「〜ですか？ね」など、文末表現と終助詞が句読点や空白で誤って分断されたケースを最優先で修復
        // 例: 「あるんです。よね」➔「あるんですよね」
        // 例: 「どうでしょうか？ねぇ」➔「どうでしょうかねぇ」
        // 例: 「どうでしょうか？ね？」➔「どうでしょうかね？」
        let brokenParticlePattern = "([でまし]す|[でま]した|ません|ございま[すした]|でしょうか|ですか|ますか|でしたか|ましたか)([。、？！]?[ 　]*)(よね|よな|よ|ねえ|ねー|ねぇ|ね|かな|かね|し|もん|もの|さ)($|[。、？！]|[ 　\t]+|(?=[\\nあ-んア-ン一-龥a-zA-Z0-9]))"
        if let regexBP = try? NSRegularExpression(pattern: brokenParticlePattern, options: []) {
            let range = NSRange(location: 0, length: (formatted as NSString).length)
            formatted = regexBP.stringByReplacingMatches(in: formatted, options: [], range: range, withTemplate: "$1$3$4")
        }

        // 0-d. 発話末尾・文末（行末・テキスト末尾・カギカッコ閉じ直前）に単独で発話された「びっくりマーク」「はてなマーク」の音声コマンドを「！」「？」に置換
        // ※「びっくりマークの使い方」「びっくりマークも」等の文中の名詞・助詞が続く文脈は100%保護し、発話末尾や括弧閉じ手前のみを対象とする
        let trailingExclPattern = "(?:(?<=[あ-んア-ン一-龥a-zA-Z0-9])[、， 　\t]*|^[ 　\t]*)(?:[びビ][っッ]?[くク][りリ][まマ][ー|ー]?[くク]|感嘆符|エクスクラメーション(?:マーク)?)[ 　\t]*[!！]?[。、., 　\t]*(?=[」』）\\)\\n]|$)"
        if let regexTE = try? NSRegularExpression(pattern: trailingExclPattern, options: []) {
            let range = NSRange(location: 0, length: (formatted as NSString).length)
            formatted = regexTE.stringByReplacingMatches(in: formatted, options: [], range: range, withTemplate: "！")
        }

        let trailingQuestPattern = "(?:(?<=[あ-んア-ン一-龥a-zA-Z0-9])[、， 　\t]*|^[ 　\t]*)(?:[はハ][てテ][なナ][まマ][ー|ー]?[くク]|ハテナマーク|疑問符|クエスチョン(?:マーク)?|クエッション(?:マーク)?)[ 　\t]*[?？]?[。、., 　\t]*(?=[」』）\\)\\n]|$)"
        if let regexTQ = try? NSRegularExpression(pattern: trailingQuestPattern, options: []) {
            let range = NSRange(location: 0, length: (formatted as NSString).length)
            formatted = regexTQ.stringByReplacingMatches(in: formatted, options: [], range: range, withTemplate: "？")
        }

        // 0-e. 記号と音声コマンド読みの重複除去（例: 「お前な！びっくりマーク」➔「お前な！」、「本当ですか？はてなマーク」➔「本当ですか？」）
        let duplicateExclPattern = "([!！])[ 　\t]*(?:[びビ][っッ]?[くク][りリ][まマ][ー|ー]?[くク]|感嘆符|エクスクラメーション(?:マーク)?)[!！。、., 　\t]*"
        if let regexDupE = try? NSRegularExpression(pattern: duplicateExclPattern, options: []) {
            let range = NSRange(location: 0, length: (formatted as NSString).length)
            formatted = regexDupE.stringByReplacingMatches(in: formatted, options: [], range: range, withTemplate: "$1")
        }

        let duplicateQuestPattern = "([?？])[ 　\t]*(?:[はハ][てテ][なナ][まマ][ー|ー]?[くク]|ハテナマーク|疑問符|クエスチョン(?:マーク)?|クエッション(?:マーク)?)[?？。、., 　\t]*"
        if let regexDupQ = try? NSRegularExpression(pattern: duplicateQuestPattern, options: []) {
            let range = NSRange(location: 0, length: (formatted as NSString).length)
            formatted = regexDupQ.stringByReplacingMatches(in: formatted, options: [], range: range, withTemplate: "$1")
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

        // 文末表現の直後に「、\n」がある場合は「。\n」に整える
        let commaBeforeNewlinePattern = "(\(fullEndings.joined(separator: "|")))[、，][ 　]*\\n"
        if let regexCBN = try? NSRegularExpression(pattern: commaBeforeNewlinePattern, options: []) {
            let range = NSRange(location: 0, length: (formatted as NSString).length)
            formatted = regexCBN.stringByReplacingMatches(in: formatted, options: [], range: range, withTemplate: "$1。\n")
        }

        let endingsPattern = "(\(fullEndings.joined(separator: "|")))(?![がからけどのでのにしたらたりならよねかもわぞぜさ])($|[ 　\t]+|(?=[\\nあ-んア-ン一-龥a-zA-Z0-9]))"
        if let regexE = try? NSRegularExpression(pattern: endingsPattern, options: []) {
            let range = NSRange(location: 0, length: (formatted as NSString).length)
            formatted = regexE.stringByReplacingMatches(in: formatted, options: [], range: range, withTemplate: "$1。")
        }

        // 6. 重複句読点および不自然な空白・行頭孤立句読点・括弧周辺の句読点クリーンアップ
        formatted = cleanupDuplicatePunctuation(formatted)

        return formatted
    }

    /// 括弧・引用符（「」、『』、（）、()、[]、{}、""、''）の前後（開き括弧の前後・閉じ括弧の前後）に
    /// 勝手に入った句点「。」やピリオド「.」・読点「、」を除去し、「かぎかっことじ」や「まるかっことじ」「なみかっことじ」等が
    /// 「「とち」」「(とち」「{とち」等に誤変換されたケースも、対応する括弧種別ごとに修復する
    public func cleanupBracketPunctuation(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text

        // 全角の丸括弧・角括弧・波括弧が混在している場合は、辞書ルールと統一して半角 () [] {} に揃える
        result = result
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: "［", with: "[")
            .replacingOccurrences(of: "］", with: "]")
            .replacingOccurrences(of: "｛", with: "{")
            .replacingOccurrences(of: "｝", with: "}")

        // マッチ位置より前のテキスト（およびマッチ文字列自身に含まれる括弧種別）から対応する閉じ括弧を判定するヘルパー
        func resolveMatchingCloseBracket(for matchRange: NSRange, in current: String) -> String {
            let nsCurrent = current as NSString
            let prefix = nsCurrent.substring(to: max(0, min(matchRange.location, nsCurrent.length)))
            let parenOpen = prefix.filter { $0 == "(" }.count
            let parenClose = prefix.filter { $0 == ")" }.count
            if parenOpen > parenClose { return ")" }

            let braceOpen = prefix.filter { $0 == "{" }.count
            let braceClose = prefix.filter { $0 == "}" }.count
            if braceOpen > braceClose { return "}" }

            let bracketOpen = prefix.filter { $0 == "[" }.count
            let bracketClose = prefix.filter { $0 == "]" }.count
            if bracketOpen > bracketClose { return "]" }

            let quoteOpen = prefix.filter { $0 == "「" }.count
            let quoteClose = prefix.filter { $0 == "」" }.count
            if quoteOpen > quoteClose { return "」" }

            // プレフィックスに未閉じ括弧がない場合（「ステータス正常。取り{」等）、マッチ文字列内の括弧種別から判定
            let matchedSub = nsCurrent.substring(with: matchRange)
            if matchedSub.contains("{") || matchedSub.contains("}") { return "}" }
            if matchedSub.contains("[") || matchedSub.contains("]") { return "]" }
            if matchedSub.contains("(") || matchedSub.contains(")") { return ")" }

            return "」"
        }

        // 0-a. 「〜かっことじ」や「とじ〜かっこ」の「とじ」が「とち」「土地」「どち」「と字」「都知」「都地」「都市」「取り」等として残ってしまったケースを対応する閉じ括弧に修復
        if let regexBrokenCloseSuffix = try? NSRegularExpression(
            pattern: "[。、，．\\.,]*[ 　\t]*[「(\\[\\{][ 　\t]*[。、，．\\.,]*[ 　\t]*(?:とじ|閉じ|とじる|閉じる|綴じ|綴じる|と字|戸字|閉字|途次|刀自|十時|当時|同時|とし|トシ|都市|年|どじ|ドジ|とち|土地|都知|都地|途地|取り|とり|トリ|とぢ|トジ|トチ|どち|栃)[ 　\t]*[。、，．\\.,]*[」』)\\]\\}]?",
            options: []
        ) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            if let match = regexBrokenCloseSuffix.firstMatch(in: result, options: [], range: range) {
                let targetClose = resolveMatchingCloseBracket(for: match.range, in: result)
                result = regexBrokenCloseSuffix.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: targetClose)
            }
        }
        if let regexBrokenClosePrefix = try? NSRegularExpression(
            pattern: "[。、，．\\.,]*[ 　\t]*(?:とじ|閉じ|とじる|閉じる|綴じ|綴じる|と字|戸字|閉字|途次|刀自|十時|当時|同時|とし|トシ|都市|年|どじ|ドジ|とち|土地|都知|都地|途地|取り|とり|トリ|とぢ|トジ|トチ|どち|栃)[ 　\t]*[。、，．\\.,]*[ 　\t]*[「」』(\\)\\[\\]\\{\\}][ 　\t]*[。、，．\\.,]*[」』)\\]\\}]?",
            options: []
        ) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            if let match = regexBrokenClosePrefix.firstMatch(in: result, options: [], range: range) {
                let targetClose = resolveMatchingCloseBracket(for: match.range, in: result)
                result = regexBrokenClosePrefix.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: targetClose)
            }
        }

        // 0-b. 既に開き括弧（「、(、[、{）が開いている状態で、対応する閉じ括弧が1つもなく2つ目の同じ開き括弧が出現している場合、2つ目を閉じ括弧に修復
        let bracketPairs: [(Character, String)] = [("「", "」"), ("(", ")"), ("[", "]"), ("{", "}")]
        for (openChar, closeStr) in bracketPairs {
            let openCount = result.filter { $0 == openChar }.count
            let closeCount = result.filter { String($0) == closeStr }.count
            if openCount == 2 && closeCount == 0, let lastOpenRange = result.range(of: String(openChar), options: .backwards) {
                result.replaceSubrange(lastOpenRange, with: closeStr)
            }
        }

        // 0-c. 「並(ステータス正常、と字並括弧です)」のように開きが「{」「[」「「」に置換されたあと、
        //      対応する「(」が0個なのに末尾等に孤立した「)」が残っている場合はその孤立「)」を除去
        let remainingParenOpen = result.filter { $0 == "(" }.count
        let remainingParenClose = result.filter { $0 == ")" }.count
        let hasOtherBrackets = result.contains("{") || result.contains("[") || result.contains("「")
        if remainingParenOpen == 0 && remainingParenClose > 0 && hasOtherBrackets {
            result = result.replacingOccurrences(of: ")", with: "")
        }

        // 1. 開き括弧の前後（直前および直後）に勝手に入った句点・読点・ピリオド・カンマを除去
        // （例: 。「。なかなか ➔ 「なかなか / .( .test ➔ (test / .{.body ➔ {body）
        if let regexAroundOpen = try? NSRegularExpression(
            pattern: "[ 　\t]*[。、，．\\.,]*[ 　\t]*([「『（(\\[［\\{｛【〈《])[ 　\t]*[。、，．\\.,]*[ 　\t]*",
            options: []
        ) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regexAroundOpen.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }

        // 2. 閉じ括弧の直前にある句点・読点・ピリオド・カンマおよび内側の余分な空白を除去
        // （例: なかなかうまくいかないな。」。 ➔ なかなかうまくいかないな」 / test. ) ➔ test) / テスト ) ➔ テスト)）
        // ※ 直前の？や！は疑問・感嘆の意味を持つため保持し、直後の「。」「.」のみ除去する
        if let regexBeforeClose = try? NSRegularExpression(
            pattern: "(?:[ 　\t]*[。、，．\\.,]+[ 　\t]*|[ 　\t]+)([」』）)\\]］\\}｝】〉》])",
            options: []
        ) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regexBeforeClose.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }
        if let regexAfterClose = try? NSRegularExpression(
            pattern: "([」』）)\\]］\\}｝】〉》])[ 　\t]*[。、，．\\.,]+",
            options: []
        ) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regexAfterClose.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }

        // 2-b. 日本語環境で閉じ括弧と開き括弧の間の余計な空白を除去（例: (テスト) (テスト) ➔ (テスト)(テスト)）
        if let regexBetweenBrackets = try? NSRegularExpression(
            pattern: "([」』）)\\]］\\}｝】〉》])[ 　]+(?=[「『（(\\[［\\{｛【〈《])",
            options: []
        ) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regexBetweenBrackets.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }

        // 2-c. 日本語文字と括弧の間の余分な空白を除去（Whisperが半角記号と日本語の間に挿入する空白を除去）
        // 例: (テスト) テスト ➔ (テスト)テスト / テスト (テスト) ➔ テスト(テスト)
        // ※ 英語 (test) test や test (test) 等のアルファベット同士の空白は保持する
        if let regexAfterCloseJapanese = try? NSRegularExpression(
            pattern: "([」』）)\\]］\\}｝】〉》])[ 　]+(?=[ぁ-んァ-ヶ一-龥])",
            options: []
        ) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regexAfterCloseJapanese.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }
        if let regexBeforeOpenJapanese = try? NSRegularExpression(
            pattern: "(?<=[ぁ-んァ-ヶ一-龥])[ 　]+([「『（(\\[［\\{｛【〈《])",
            options: []
        ) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regexBeforeOpenJapanese.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }

        // 3. ダブルクォート "..." / シングルクォート '...' のペア前後および内側の不要な句点「。」除去
        if let regexDoubleQuote = try? NSRegularExpression(
            pattern: "[。、，．]*[ 　\t]*\"[ 　\t]*[。、，．]*([^\"\\n]+?)[ 　\t]*[。、，．]*\"[ 　\t]*[。、，．\\.]*",
            options: []
        ) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regexDoubleQuote.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "\"$1\"")
        }

        // 3-b. シングルクォート '...' （日本語を含むペアのみ。英語のアポストロフィ don't 等は対象外）の前後・内側の不要な句点を除去
        if let regexSingleQuote = try? NSRegularExpression(
            pattern: "[。、，．]*[ 　\t]*'[ 　\t]*[。、，．]*([^'\\n]*?[ぁ-んァ-ヶ一-龥][^'\\n]*?)[ 　\t]*[。、，．]*'[ 　\t]*[。、，．\\.]*",
            options: []
        ) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regexSingleQuote.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "'$1'")
        }

        // 3-c. 閉じ括弧や引用符の直後に残ってしまった誤認識閉じ語（「たち、と言った」「とじと言った」等）の除去
        let closers = "」』\"'）)\\]\\}｝】〉》"
        let brokenGarbage = "(?:たち|タチ|立ち|断ち|裁ち|発ち|とじ|閉じ|とじる|閉じる|綴じ|綴じる|と字|戸字|閉字|途次|刀自|十時|当時|同時|とし|トシ|都市|年|どじ|ドジ|とち|土地|都知|都地|途地|取り|とり|トリ|とぢ|トジ|トチ|どち|栃)"
        let speechVerbs = "(と(?:[。、\\n$]|言|い[うい]|述|答|話|書|思|叫|尋|聞|つぶや|語|返|伝|主張|説明))"
        if let regexLingering = try? NSRegularExpression(
            pattern: "([\(closers)])[ 　\t]*\(brokenGarbage)[、，]?[ 　\t]*\(speechVerbs)",
            options: []
        ) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regexLingering.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1$2")
        }

        // 3-d. 未閉鎖の引用符（"..." または '...'）の自動修復
        // 音声認識で閉じクォートが欠落して「彼は'こんにちは と言った」や「彼は'こんにちは」となった場合、発言動詞の直前または文末で安全に閉じる
        for q in ["'", "\""] {
            let count: Int
            if q == "'" {
                // 英語のアポストロフィ（don't, it's等）を除外してカウント
                if let regexNonAlphaApos = try? NSRegularExpression(pattern: "(?<![a-zA-Z])'|'(?![a-zA-Z])", options: []) {
                    count = regexNonAlphaApos.numberOfMatches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length))
                } else {
                    count = result.filter { String($0) == q }.count
                }
            } else {
                count = result.filter { String($0) == q }.count
            }

            if count % 2 == 1 {
                // パターン1: 発言動詞・引用助詞（「と言った」「と言う」「と。」等）の直前で閉じる
                let verbPattern = "(\(q)[^\(q)\\n]+?)[ 　\t]*(?:\(brokenGarbage)[、，]?[ 　\t]*)?\(speechVerbs)"
                if let regexVerb = try? NSRegularExpression(pattern: verbPattern, options: []) {
                    let range = NSRange(location: 0, length: (result as NSString).length)
                    if regexVerb.firstMatch(in: result, options: [], range: range) != nil {
                        result = regexVerb.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1\(q)$2")
                        continue
                    }
                }

                // パターン2: 文末の未閉鎖クォートを補正（シングルクォートの場合は日本語または単語境界を含むもののみ）
                let endPattern: String
                if q == "'" {
                    endPattern = "((?<![a-zA-Z])\(q)[^\(q)\\n]*?[ぁ-んァ-ヶ一-龥][^\(q)\\n]*?)[ 　\t]*([。．\\.]?)$"
                } else {
                    endPattern = "(\(q)[^\(q)\\n]+?)[ 　\t]*([。．\\.]?)$"
                }
                if let regexEnd = try? NSRegularExpression(pattern: endPattern, options: []) {
                    let range = NSRange(location: 0, length: (result as NSString).length)
                    result = regexEnd.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1\(q)$2")
                }
            }
        }

        return result
    }

    /// 音声コマンド「改行」（および英語の "new line" / "new paragraph"）が Whisper / LLM で「開業」「かいぎょう」「改行。」等と変換されたケースを検出し `\n` に変換する
    /// また、文中の「開業のテスト」のような音声入力文脈での同音異義語も「改行」に補正する
    public func normalizeNewlineVoiceCommand(_ text: String) -> String {
        var result = text

        // 英語の "new paragraph" / "new line" / "newline" / "next line" 音声コマンド正規化（前後のカンマ・ピリオド・空白を吸収）
        if let regexEnParagraph = try? NSRegularExpression(
            pattern: "([\\.,?!]?)[ 　\t]*\\b[Nn]ew[ 　]*paragraph\\b(?![ 　]+(?:in|of|for))[ 　\t]*[\\.,]*[ 　\t]*",
            options: []
        ) {
            let nsString = result as NSString
            let matches = regexEnParagraph.matches(in: result, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let leading = (match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound) ? nsString.substring(with: match.range(at: 1)) : ""
                let punct = (leading == "?" || leading == "!") ? leading : (leading.isEmpty ? "" : ".")
                result = (result as NSString).replacingCharacters(in: match.range, with: "\(punct)\n\n")
            }
        }
        if let regexEnNewline = try? NSRegularExpression(
            pattern: "([\\.,?!]?)[ 　\t]*\\b(?:[Nn]ew|[Nn]ext)[ 　]*line\\b(?![ 　]+(?:character|characters|code|in|of|for))[ 　\t]*[\\.,]*[ 　\t]*",
            options: []
        ) {
            let nsString = result as NSString
            let matches = regexEnNewline.matches(in: result, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let leading = (match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound) ? nsString.substring(with: match.range(at: 1)) : ""
                let punct = (leading == "?" || leading == "!") ? leading : (leading.isEmpty ? "" : ".")
                result = (result as NSString).replacingCharacters(in: match.range, with: "\(punct)\n")
            }
        }

        // パターン0: 文中の名詞として「改行」を意図している文脈（例: 「今日は開業のテストします」「開業コード」「開業の位置」）の同音異義語補正
        if let regexNounContext = try? NSRegularExpression(
            pattern: "(?:開業|かいぎょう)(のテスト|テスト|コード|キー|位置|文字|機能|設定|ルール|がうまく|をテスト)",
            options: []
        ) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regexNounContext.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "改行$1")
        }

        // 救済対象となる「改行」「開業」「かいぎょう」音声コマンド表現
        // 1) 語尾付き（Whisper/LLMが「改行」を「開業ですね」「開業しました」「開業です」等と誤認識・語尾補完したケース）
        let kaigyoWithSuffix = "(?:改行|開業|かいぎょう)(?:ですね[ーえ]?|でしたね[ーえ]?|しました|します|です|でした)"
        // 2) 単体（「改行」「開業」「かいぎょう」）
        let kaigyoPlain = "(?:改行|開業|かいぎょう)"
        // 単体の場合に名詞・複合語・動詞として除外する否定先読み
        let notNounOrRealKaigyoForPlain = "(?![のをがはにでもとやへかコキ位文テル設機すし医届日資予準祝当以])"
        // 語尾付きの場合に複合語として除外する否定先読み
        let notCompoundForSuffix = "(?![コード|キー|位置|文字|機能|設定|ルール|医|届|日|資|予|準|祝|当|以|設|機])"

        let kaigyoCommandPattern = "(?:\(kaigyoWithSuffix)\(notCompoundForSuffix)|\(kaigyoPlain)\(notNounOrRealKaigyoForPlain))"

        // パターン1: 文末表現（ですね、ますね、です、ます、ました、でした、ください、お願いします、思います、でしょうか、ですか等）
        // の直後（読点・句点・改行・空白を挟んでもよい）に「開業ですね」「開業しました」「開業」「改行」等が来る場合
        let sentenceEndings = "ですよねー|ですよねえ|ですねー|ですねえ|ですよー|ますよねー|ますよねえ|ますねー|ますねえ|ますよー|でしたよね|ましたよね|ませんよね|ですよね|ますよね|ですね|ですよ|ますね|ますよ|でしたね|でしたよ|ましたね|ましたよ|ませんね|ませんよ|ございます|ございました|と思います|と考えます|とのことです|ませんでした|でした|ました|ません|でしょうか|ですか|ますか|でしたか|ましたか|ください|お願いします|お願いいたします|です|ます|だ|である|だった|だよ|だね|だな|かな|かしら"
        let patternAfterEnding = "(\(sentenceEndings))([、。，．？！?!\\n 　\t]*)\(kaigyoCommandPattern)([、。，．\\n 　\t]*)"
        if let regex1 = try? NSRegularExpression(pattern: patternAfterEnding, options: []) {
            let nsString = result as NSString
            let matches = regex1.matches(in: result, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let ending = (match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound) ? nsString.substring(with: match.range(at: 1)) : ""
                let middlePunct = (match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound) ? nsString.substring(with: match.range(at: 2)) : ""
                let punct: String
                if middlePunct.contains("？") || middlePunct.contains("?") ||
                   ending.hasSuffix("か") {
                    punct = "？"
                } else if middlePunct.contains("！") || middlePunct.contains("!") {
                    punct = "！"
                } else {
                    punct = "。"
                }
                result = (result as NSString).replacingCharacters(in: match.range, with: "\(ending)\(punct)\n")
            }
        }

        // パターン2: 句読点や改行の直後に「開業ですね」「開業しました」「開業」「改行」等が挟まり、次の文へ続くケース
        let standaloneBetweenSentences = "([、。，．？！?!\\n]+)[ 　\t]*\(kaigyoCommandPattern)[ 　\t]*[、。，．\\n]*([ 　\t]*)"
        if let regex2 = try? NSRegularExpression(pattern: standaloneBetweenSentences, options: []) {
            let nsString = result as NSString
            let matches = regex2.matches(in: result, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let leading = (match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound) ? nsString.substring(with: match.range(at: 1)) : ""
                let punct: String
                if leading.contains("？") || leading.contains("?") {
                    punct = "？"
                } else if leading.contains("！") || leading.contains("!") {
                    punct = "！"
                } else {
                    punct = "。"
                }
                result = (result as NSString).replacingCharacters(in: match.range, with: "\(punct)\n")
            }
        }

        // パターン3: 行頭・文頭・単独の「開業ですね」「開業しました」「開業」「改行」等（前後に文字がないか、改行のみ）
        let standalonePattern = "(?:^|\\n)[ 　\t]*\(kaigyoCommandPattern)[ 　\t]*[、。，．\\n]*$"
        if let regex3 = try? NSRegularExpression(pattern: standalonePattern, options: []) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regex3.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "\n")
        }

        // パターン3-b: 文末表現に限らず、名詞（「テスト」「報告」「メモ」等）や一般語の直後に「改行」「開業」が発話され、
        // 次の語へと続くケース（例: 「これはテスト改行次の行」「これはテスト開業次の行」「これはテスト 開業次の行」）
        // ※「クリニックを開業」「渋谷で開業」「今年新規開業」等の本物の開業文脈や「改行のテスト」「開業の手続き」等の名詞＋助詞文脈は除外
        let inlineKaigyoPattern = "(?<![をにで]|新規|医院|店舗|クリニック)([、。，．？！?! 　\t]*)(?:改行|開業|かいぎょう)(?!(?:コード|キー|位置|文字|機能|設定|ルール|医|届|日|資|予|準|祝|当|以|設|機|し|す|され|する|した|して|[のをがはにでもとやへか]))([、。，． 　\t]*)"
        if let regexInline = try? NSRegularExpression(pattern: inlineKaigyoPattern, options: []) {
            let nsString = result as NSString
            let matches = regexInline.matches(in: result, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let leading = (match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound) ? nsString.substring(with: match.range(at: 1)) : ""
                let punct: String
                if leading.contains("？") || leading.contains("?") {
                    punct = "？"
                } else if leading.contains("！") || leading.contains("!") {
                    punct = "！"
                } else if leading.contains("。") {
                    punct = "。"
                } else {
                    punct = ""
                }
                result = (result as NSString).replacingCharacters(in: match.range, with: "\(punct)\n")
            }
        }

        // パターン4: 文末（テキスト末尾）に直接付いた「開業ですね」「開業しました」等の救済
        // 例: 「明日の打ち合わせの件開業ですね」➔「明日の打ち合わせの件。\n」
        // （本物の「〜を開業しました」「新規開業しました」等を除外）
        if let regexTrailing = try? NSRegularExpression(
            pattern: "([^\\n 　\t]{2,})[ 　\t]*\(kaigyoWithSuffix)[ 　\t]*[、。，．？！?!\\n]*$",
            options: []
        ) {
            let nsString = result as NSString
            if let match = regexTrailing.firstMatch(in: result, options: [], range: NSRange(location: 0, length: nsString.length)) {
                let preceding = nsString.substring(with: match.range(at: 1))
                // 本物の「〜を開業しました」「新規開業しました」等を除外
                let isRealKaigyo = preceding.hasSuffix("を") || preceding.hasSuffix("が") ||
                    preceding.hasSuffix("に") || preceding.hasSuffix("で") ||
                    preceding.hasSuffix("へ") || preceding.hasSuffix("から") ||
                    preceding.hasSuffix("新規") || preceding.hasSuffix("独立") ||
                    preceding.hasSuffix("店舗") || preceding.hasSuffix("医院") ||
                    preceding.hasSuffix("クリニック")
                if !isRealKaigyo {
                    let punct = (preceding.hasSuffix("？") || preceding.hasSuffix("?")) ? "" : ((preceding.hasSuffix("！") || preceding.hasSuffix("!")) ? "" : "。")
                    result = nsString.replacingCharacters(in: match.range, with: "\(preceding)\(punct)\n")
                }
            }
        }

        return result
    }

    /// 重複した句読点や不自然な空白・行頭の孤立句読点（\n。\n 等）・括弧周辺の句読点を整理
    public func cleanupDuplicatePunctuation(_ text: String) -> String {
        var result = cleanupBracketPunctuation(text)

        // 「です。よね」「ます。よね」「でしょうか？ね」等の誤った句読点挿入の修復
        let brokenParticlePattern = "([でまし]す|[でま]した|ません|ございま[すした]|でしょうか|ですか|ますか|でしたか|ましたか)([。、？！][ 　]*)(よね|よな|よ|ねえ|ねー|ねぇ|ね|かな|かね|し|もん|もの|さ)"
        if let regexBP = try? NSRegularExpression(pattern: brokenParticlePattern, options: []) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regexBP.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1$3")
        }

        // 改行前後の不要な空白を整理
        if let regexNewlineSpace = try? NSRegularExpression(pattern: "[ 　\t]*\\n[ 　\t]*", options: []) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regexNewlineSpace.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "\n")
        }

        // ★重要: 改行の直後（次の行の行頭）に孤立した句読点（「\n。」「\n。\n」「\n、」等）を完全に除去・吸収
        // 1) 前の行末にすでに句読点がある場合（例: 「なかなか難しいですね。\n。\n次の入力」➔「なかなか難しいですね。\n次の入力」）
        if let regexOrphanAfterPunct = try? NSRegularExpression(pattern: "([。、，．？！?!])\\n+[。、，．]+\\n*", options: []) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regexOrphanAfterPunct.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1\n")
        }
        // 2) 前の行末に句読点がない場合（例: 「テスト\n。\n次の入力」➔「テスト。\n次の入力」）
        if let regexOrphanPeriod = try? NSRegularExpression(pattern: "([^\\n。、，．？！?!])\\n+[。．]+\\n*", options: []) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regexOrphanPeriod.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1。\n")
        }
        if let regexOrphanComma = try? NSRegularExpression(pattern: "([^\\n。、，．？！?!])\\n+[、，]+\\n*", options: []) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regexOrphanComma.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1、\n")
        }
        // 3) 文字列全体の先頭に孤立した句読点がある場合も除去
        if let regexLeadingPunct = try? NSRegularExpression(pattern: "^[。、，．]+\\n*", options: []) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regexLeadingPunct.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // 連続・重複の除去
        result = result.replacingOccurrences(of: "。。", with: "。")
        result = result.replacingOccurrences(of: "、、", with: "、")
        result = result.replacingOccurrences(of: "、。", with: "。")
        result = result.replacingOccurrences(of: "。、", with: "。")
        result = result.replacingOccurrences(of: "？？", with: "？")
        result = result.replacingOccurrences(of: "？。", with: "？")
        result = result.replacingOccurrences(of: "。？", with: "？")
        result = result.replacingOccurrences(of: "！。", with: "！")
        result = result.replacingOccurrences(of: "。！", with: "！")
        result = result.replacingOccurrences(of: "、？", with: "？")
        result = result.replacingOccurrences(of: "、！", with: "！")
        result = result.replacingOccurrences(of: "…、", with: "…")
        result = result.replacingOccurrences(of: "、…", with: "…")
        result = result.replacingOccurrences(of: "。…", with: "…")

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

        // 最終仕上げとして括弧内・括弧直後の不要な句点・ピリオドを再度クリーンアップ
        result = cleanupBracketPunctuation(result)

        return result
    }

    /// リアルタイムプレビューでユーザーが見ていたテキスト（referenceLiveText）の句読点・改行・区切りを
    /// 最終テキスト（Whisper / LLM 推敲結果）に厳格に同期・反映させる
    public func alignPunctuation(
        text: String,
        referenceLiveText: String,
        isJapanese: Bool
    ) -> String {
        let trimmedRef = referenceLiveText.trimmingCharacters(in: .whitespacesAndNewlines)
        var formatted = format(text: text, isJapanese: isJapanese)

        guard isJapanese, !trimmedRef.isEmpty else {
            return formatted
        }

        let formattedRef = format(text: trimmedRef, isJapanese: isJapanese)

        // 句読点・空白・改行を除去した純粋な文字列比較
        let cleanText = stripPunctuation(formatted)
        let cleanRef = stripPunctuation(formattedRef)

        // 1. 純粋な発話内容が完全に一致する場合:
        // ユーザーがプレビュー画面で見ていた formattedRef そのものの句読点・改行構造を最優先
        if cleanText == cleanRef {
            return formattedRef
        }

        // 2. プレビュー側に改行（\n）が存在するのに formatted 側で改行が失われている場合、改行位置を復元する
        if formattedRef.contains("\n") && !formatted.contains("\n") {
            formatted = restoreNewlines(in: formatted, from: formattedRef)
        }

        // 3. プレビューが遅延して末尾が途切れている場合（cleanRef が cleanText の前方一致）:
        // 確定テキスト（formatted）の末尾の完全な文言を決して削らず、formatted を優先
        if cleanText.hasPrefix(cleanRef) {
            return cleanupDuplicatePunctuation(formatted)
        }

        // 4. 疑問文の整合性
        if formattedRef.hasSuffix("？") || formattedRef.hasSuffix("?") {
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

    /// プレビュー文字列（reference）に含まれていた改行（\n）の位置を、確定テキスト（target）へ復元する
    private func restoreNewlines(in target: String, from reference: String) -> String {
        let refLines = reference.components(separatedBy: "\n")
        guard refLines.count > 1 else { return target }

        var result = target
        for i in 0..<(refLines.count - 1) {
            let cleanLine = stripPunctuation(refLines[i])
            guard cleanLine.count >= 2 else { continue }
            let suffixLen = min(4, cleanLine.count)
            let anchor = String(cleanLine.suffix(suffixLen))
            let escapedAnchor = NSRegularExpression.escapedPattern(for: anchor)
            // アンカー文字列＋直後の句読点（。、？！）の直後に改行が入っていなければ挿入
            let pattern = "(\(escapedAnchor)[。、，．？！?!]?)(?!\\n)"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let nsResult = result as NSString
                if let match = regex.firstMatch(in: result, options: [], range: NSRange(location: 0, length: nsResult.length)),
                   match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                    let matchedStr = nsResult.substring(with: match.range(at: 1))
                    result = nsResult.replacingCharacters(in: match.range, with: "\(matchedStr)\n")
                }
            }
        }
        return result
    }

    /// 句読点や空白記号を除去したテキストを取得
    public func stripPunctuation(_ text: String) -> String {
        let punctuationChars: Set<Character> = ["、", "。", "，", "．", "？", "！", "?", "!", " ", "　", "\n", "\r", "\t", "・"]
        return text.filter { !punctuationChars.contains($0) }
    }
}
