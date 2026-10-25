import Foundation
import AVFoundation
import Carbon

@main
@MainActor
struct TestRunner {
    static func main() {
        print("=== Running VoiceIME Tests ===")

        // 本番環境（~/.voiceime）を100%保護するための完全隔離サンドボックス
        let testSandboxDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceime_test_sandbox_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testSandboxDir, withIntermediateDirectories: true)
        VoiceIMEDiskSyncService.shared.customBaseDirectory = testSandboxDir
        defer {
            VoiceIMEDiskSyncService.shared.customBaseDirectory = nil
            try? FileManager.default.removeItem(at: testSandboxDir)
        }

        testDictionaryService()
        testSymbolDictionaryRules()
        testVoiceIMEDiskSync()
        testKeychainService()
        testLaunchAtLoginService()
        testLLMService()
        testAudioAnalysisService()
        testFloatingPreviewSettings()
        testLivePunctuationFormatting()
        testLiveSpeechPhoneticTransliteration()
        testQuickAskAndPasteShortcuts()
        testProgressiveRefinementPreview()
        testPipelineLogger()
        testAudioDeviceService()
        testCorrectionStockService()
        testImmediateCaptureAndLeadingVoicePreservation()
        testPushToTalkPauseAndResume()
        testSystemLogger()

        print("=== All Tests Passed Successfully! ===")
    }

    static func testProgressiveRefinementPreview() {
        print("[TEST] Progressive Refinement Preview (差分連結 & 推敲全置換)...")

        // 1. 基本的な差分抽出
        let w1 = "明日の天気は晴れで"
        let r1 = "明日の天気は晴れですが、"

        let w2 = "明日の天気は晴れで、午後から雨が降るそうです"
        let d2 = StreamingChunkPipelineService.extractDelta(newText: w2, baseText: w1)
        assert(d2 == "午後から雨が降るそうです", "Expected '午後から雨が降るそうです', got '\(String(describing: d2))'")

        let combined2 = StreamingChunkPipelineService.combineRefinedWithDelta(refined: r1, delta: d2 ?? "")
        assert(combined2 == "明日の天気は晴れですが、午後から雨が降るそうです", "Expected combined text, got '\(combined2)'")

        // 1-b. 中間推敲で末尾に句点「。」が付与された後に差分が連結された場合（不要な文頭・文中の句点混入防止）
        let rPeriod = "エラーの塗りつぶし、十分な。"
        let dNext = "エラーがありません。"
        let combinedPeriod = StreamingChunkPipelineService.combineRefinedWithDelta(refined: rPeriod, delta: dNext)
        assert(combinedPeriod == "エラーの塗りつぶし、十分なエラーがありません。", "Expected 'エラーの塗りつぶし、十分なエラーがありません。', got '\(combinedPeriod)'")

        // 2. 読点なしの差分抽出
        let w3 = "明日の天気は晴れで午後から雨が降るそうです"
        let d3 = StreamingChunkPipelineService.extractDelta(newText: w3, baseText: w1)
        assert(d3 == "午後から雨が降るそうです", "Expected '午後から雨が降るそうです', got '\(String(describing: d3))'")

        // 3. 空白やピリオドの英語差分抽出
        let wEn1 = "Hello world"
        let rEn1 = "Hello, world!"
        let wEn2 = "Hello world and good morning"
        let dEn2 = StreamingChunkPipelineService.extractDelta(newText: wEn2, baseText: wEn1)
        assert(dEn2 == "and good morning", "Expected 'and good morning', got '\(String(describing: dEn2))'")
        let combinedEn = StreamingChunkPipelineService.combineRefinedWithDelta(refined: rEn1, delta: dEn2 ?? "")
        assert(combinedEn == "Hello, world! and good morning", "Expected combined English text, got '\(combinedEn)'")

        // 4. 初回（baseText が空）の場合
        let dInitial = StreamingChunkPipelineService.extractDelta(newText: "テスト発話", baseText: "")
        assert(dInitial == "テスト発話", "Expected initial text, got '\(String(describing: dInitial))'")

        // 5. 文頭の漢字・表記がブレた場合のアンカー差分抽出（「海人」➔「海事」のケース）
        let wFuzzyBase = "海人の中東派遣1年延長へ 政府船舶の安全確保継続政府は中央海域で海賊対策と情報収集の任務にあたる海上自衛隊の派遣期間を"
        let wFuzzyNew = "海事の中東派遣1年延長へ 政府船舶の安全確保継続政府は中東海域で海賊対策と情報収集の任務にあたる海上自衛隊の派遣期間を来年11月まで1年間延長する方針を固めた"
        let dFuzzy = StreamingChunkPipelineService.extractDelta(newText: wFuzzyNew, baseText: wFuzzyBase)
        assert(dFuzzy == "来年11月まで1年間延長する方針を固めた", "Expected delta after anchor, got '\(String(describing: dFuzzy))'")

        // 6. 全く一致しないテキストの場合、安全のため nil を返す（二重重複の防止）
        let dMismatch = StreamingChunkPipelineService.extractDelta(newText: "全然違うテキストです", baseText: "過去の発話履歴です")
        assert(dMismatch == nil, "Expected nil on mismatch to prevent duplication, got '\(String(describing: dMismatch))'")

        // 7. Whisperの無音ハルシネーション（"Thank you." 等）のサニタイズテスト（文中含む）
        let hallucinatedInput1 = "Thank you.海賊対策について報告します。"
        assert(WhisperAPIService.sanitizeWhisperOutput(hallucinatedInput1) == "海賊対策について報告します。", "Should strip leading Thank you.")
        let hallucinatedInput2 = "本日はお集まりいただきありがとうございます。 ご視聴ありがとうございました。"
        assert(WhisperAPIService.sanitizeWhisperOutput(hallucinatedInput2) == "本日はお集まりいただきありがとうございます。", "Should strip trailing ご視聴ありがとうございました")
        let hallucinatedInput3 = "来年11月まで延長する方針を固めた。ご視聴ありがとうございました。海事の中東派遣へ"
        let sanitized3 = WhisperAPIService.sanitizeWhisperOutput(hallucinatedInput3)
        assert(!sanitized3.contains("ご視聴ありがとうございました"), "Should strip inline ご視聴ありがとうございました: got '\(sanitized3)'")

        // 7B. Whisperの異常反復ハルシネーション（"XXXX...", "ああああ..." 等）のサニタイズテスト
        let repeatedInput = "現在のARグラス市場はXRXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
        let sanitizedRep = WhisperAPIService.sanitizeWhisperOutput(repeatedInput)
        assert(sanitizedRep == "現在のARグラス市場はXRX", "Should reduce excessive repeating characters, got '\(sanitizedRep)'")

        // 7C. Whisperのフレーズ反復ハルシネーション（"Xreal Air 2 Pro Xreal Air 2 Pro Xreal Air 2 Pro" 等）のサニタイズテスト
        let repeatedPhrase3x = "1.総合バランス 初めて1台にするおすすめ開業 Xreal Air 2 Pro Xreal Air 2 Pro Xreal Air 2 Pro"
        let sanitizedPhrase3x = WhisperAPIService.sanitizeWhisperOutput(repeatedPhrase3x)
        assert(sanitizedPhrase3x == "1.総合バランス 初めて1台にするおすすめ開業 Xreal Air 2 Pro", "Should reduce 3x phrase repetition, got '\(sanitizedPhrase3x)'")

        let repeatedWords2x = "Xreal Air 2 Pro Xreal Air 2 Pro"
        let sanitizedWords2x = WhisperAPIService.sanitizeWhisperOutput(repeatedWords2x)
        assert(sanitizedWords2x == "Xreal Air 2 Pro", "Should reduce 2x multi-word phrase repetition, got '\(sanitizedWords2x)'")

        let repeatedLongJp2x = "今日もいい天気ですね 今日もいい天気ですね"
        let sanitizedLongJp2x = WhisperAPIService.sanitizeWhisperOutput(repeatedLongJp2x)
        assert(sanitizedLongJp2x == "今日もいい天気ですね", "Should reduce 2x long Japanese phrase repetition, got '\(sanitizedLongJp2x)'")

        let naturalRepeats = "はいはい、そうそう、だんだん、いろいろ"
        let sanitizedNatural = WhisperAPIService.sanitizeWhisperOutput(naturalRepeats)
        assert(sanitizedNatural == naturalRepeats, "Should preserve natural Japanese repeats like はいはい, got '\(sanitizedNatural)'")

        // 8. PCM無音トリミング (VAD) テスト
        let sampleRate = 16000.0
        let silenceSampleCount = Int(sampleRate * 0.5) // 0.5秒の無音
        let speechSampleCount = Int(sampleRate * 1.0)  // 1.0秒の音声 (振幅大)
        var mockPCM = Data(count: silenceSampleCount * 2) // 先頭無音
        for i in 0..<speechSampleCount {
            var val = Int16(sin(Double(i) * 0.1) * 20000.0) // ~ -4dBFS
            withUnsafeBytes(of: &val) { mockPCM.append(contentsOf: $0) }
        }
        mockPCM.append(Data(count: silenceSampleCount * 2)) // 末尾無音
        let trimmedPCM = StreamingChunkPipelineService.trimSilence(pcmData: mockPCM, sampleRate: sampleRate, speechThresholdDB: -38.0)
        assert(trimmedPCM.count < mockPCM.count, "Trimmed PCM should be shorter than original by cutting leading/trailing silence")

        // 9. 語尾脱落防止 & 無駄送信防止のトリガー条件（evaluateTrigger）テスト
        // A. 2回目以降: 語尾（「〜します」等 0.15s の有声発話）の後に 0.25s の小休止で確実にトリガー成立
        let tailTrigger = StreamingChunkPipelineService.evaluateTrigger(
            isFirstTrigger: false,
            totalSpeechDuration: 2.5,
            newSpeechDuration: 0.15,
            silentDuration: 0.25,
            timeSinceLastTrigger: 1.5,
            minIntervalSeconds: 1.2,
            minSilenceDuration: 0.12,
            isTranscribing: false
        )
        assert(tailTrigger == true, "Short ending speech with silence should trigger")

        // B. 2回目以降: キーを押したまま沈黙放置（newSpeechDuration == 0.0）では何秒経過しても絶対に送信しない
        let silenceLoopBlocked = StreamingChunkPipelineService.evaluateTrigger(
            isFirstTrigger: false,
            totalSpeechDuration: 2.5,
            newSpeechDuration: 0.0,
            silentDuration: 2.5,
            timeSinceLastTrigger: 3.0,
            minIntervalSeconds: 1.2,
            minSilenceDuration: 0.12,
            isTranscribing: false
        )
        assert(silenceLoopBlocked == false, "Silence with no new speech should never trigger")

        // C. 初回トリガー: 短い発話（「はい」0.15s）でも小休止 0.25s でトリガー成立
        let firstShortTrigger = StreamingChunkPipelineService.evaluateTrigger(
            isFirstTrigger: true,
            totalSpeechDuration: 0.15,
            newSpeechDuration: 0.15,
            silentDuration: 0.25,
            timeSinceLastTrigger: 0.0,
            minIntervalSeconds: 1.2,
            minSilenceDuration: 0.12,
            isTranscribing: false
        )
        assert(firstShortTrigger == true, "First short speech with pause should trigger")

        // D. 処理中（isTranscribing == true）はトリガー抑制
        let transcribingBlocked = StreamingChunkPipelineService.evaluateTrigger(
            isFirstTrigger: false,
            totalSpeechDuration: 2.5,
            newSpeechDuration: 0.5,
            silentDuration: 0.25,
            timeSinceLastTrigger: 2.0,
            minIntervalSeconds: 1.2,
            minSilenceDuration: 0.12,
            isTranscribing: true
        )
        assert(transcribingBlocked == false, "Should not trigger while transcribing")

        // E. 5.0秒言い終わり待機フラッシュ / 語尾キャッチアップ（needsTailCatchUp == true）時は確実にトリガー成立
        let waitingFlushTrigger = StreamingChunkPipelineService.evaluateTrigger(
            isFirstTrigger: false,
            totalSpeechDuration: 3.0,
            newSpeechDuration: 0.0,
            silentDuration: 5.0,
            timeSinceLastTrigger: 5.0,
            minIntervalSeconds: 1.5,
            minSilenceDuration: 0.12,
            isTranscribing: false,
            needsTailCatchUp: true
        )
        assert(waitingFlushTrigger == true, "5.0s waiting flush with needsTailCatchUp should trigger")

        print("  -> Progressive Refinement Preview passed!")
    }

    static func testLiveSpeechPhoneticTransliteration() {
        print("[TEST] Live Speech & KatakanaEnglishConverter...")

        // 1. カタカナ音訳判定: 英語発話が日本語認識でカタカナになった場合の検知
        assert(LiveSpeechService.isPhoneticEnglishTransliteration("ディド ユー フィニッシュ イット") == true)
        assert(LiveSpeechService.isPhoneticEnglishTransliteration("ハロー ワールド") == true)
        assert(LiveSpeechService.isPhoneticEnglishTransliteration("サンキュー") == true)
        assert(LiveSpeechService.isPhoneticEnglishTransliteration("アイ ハブ ア ペン") == true)

        // 2. 通常の日本語文（漢字・ひらがな含む）は音訳と誤認しないこと
        assert(LiveSpeechService.isPhoneticEnglishTransliteration("本日の作業は完了しました") == false)
        assert(LiveSpeechService.isPhoneticEnglishTransliteration("お疲れ様です") == false)
        assert(LiveSpeechService.isPhoneticEnglishTransliteration("どうでしょうか") == false)
        assert(LiveSpeechService.isPhoneticEnglishTransliteration("こんにちは") == false)

        // 3. Dictate プレフィックスのクリーンアップ
        assert(LiveSpeechService.cleanTranscriptionText("Dictate konnichiwa") == "konnichiwa")
        assert(LiveSpeechService.cleanTranscriptionText("Dictate did you finish it") == "did you finish it")
        assert(LiveSpeechService.cleanTranscriptionText("Dictate") == "")
        assert(LiveSpeechService.cleanTranscriptionText("hello") == "hello")

        // 4. KatakanaEnglishConverter によるカタカナ英語のリアルタイム英文変換
        let converter = KatakanaEnglishConverter.shared
        let out1 = converter.convertToEnglish("ディド ユー フィニッシュ イット")
        assert(out1 == "Did you finish it?", "Expected 'Did you finish it?', got '\(out1)'")

        let out2 = converter.convertToEnglish("ディドユーフィニッシュイット")
        assert(out2 == "Did you finish it?", "Expected 'Did you finish it?', got '\(out2)'")

        let out3 = converter.convertToEnglish("ハロー ワールド")
        assert(out3 == "Hello world", "Expected 'Hello world', got '\(out3)'")

        let out4 = converter.convertToEnglish("サンキュー ベリー マッチ")
        assert(out4 == "Thank you very much", "Expected 'Thank you very much', got '\(out4)'")

        let out5 = converter.convertToEnglish("アイ ハブ ア ペン")
        assert(out5 == "I have a pen", "Expected 'I have a pen', got '\(out5)'")

        // 5. 日英デュアル認識判定（decideBestTranscription）の徹底検証
        // ケースA: 日本語発声（「こんにちは」）- 初動でひらがな1文字でも日本語として採用（英語のKakやKonnichiwaは完全遮断）
        let decJaInitial = LiveSpeechService.decideBestTranscription(jaText: "こん", enText: "Kak")
        assert(decJaInitial?.text == "こん" && decJaInitial?.isJapanese == true, "Initial hiragana must take precedence as Japanese")

        let decJaFull = LiveSpeechService.decideBestTranscription(jaText: "こんにちは", enText: "Konnichiwa")
        assert(decJaFull?.text == "こんにちは" && decJaFull?.isJapanese == true, "Full Japanese greeting must be Japanese")

        let decJaPolite = LiveSpeechService.decideBestTranscription(jaText: "お疲れ様です", enText: "Otsukaresama")
        assert(decJaPolite?.text == "お疲れ様です" && decJaPolite?.isJapanese == true, "Polite Japanese must be Japanese")

        // ケースB: 英語発声（"Hello, how are you doing?"）
        // ユーザー報告の「A ロ had ゥ ー in グ」崩れ文字が出ても、有効英文があるため100%英語を採用！
        let decEnBroken = LiveSpeechService.decideBestTranscription(jaText: "A ロ had ゥ ー in グ", enText: "Hello, how are you doing?")
        assert(decEnBroken?.text == "Hello, how are you doing?" && decEnBroken?.isJapanese == false, "Broken transcription must yield valid English phrase")

        // JAがカタカナ音訳（ハローハード等）の場合も英語を採用
        let decEnKatakana = LiveSpeechService.decideBestTranscription(jaText: "ハローハード", enText: "Hello, how are you doing?")
        assert(decEnKatakana?.text == "Hello, how are you doing?" && decEnKatakana?.isJapanese == false, "Phonetic transliteration must yield English")

        // ケースC: 英語発声（"did you finish it"）
        let decEnDid = LiveSpeechService.decideBestTranscription(jaText: "ディド ユー フィニッシュ イット", enText: "did you finish it")
        assert(decEnDid?.text == "did you finish it" && decEnDid?.isJapanese == false, "English phrase must take precedence over katakana")

        // ケースD: 日本語エンジンの初動テキストが届くまでのノイズ遮断（"Kak" 等の初動単語ノイズは保留）
        let decNoisePending = LiveSpeechService.decideBestTranscription(jaText: "", enText: "Kak")
        assert(decNoisePending == nil, "Single noise word in English should wait for Japanese engine")

        print("  -> Live Speech & KatakanaEnglishConverter passed!")
    }

    static func testSymbolDictionaryRules() {
        print("[TEST] Symbol Dictionary Rules (音声入力用記号置換)...")
        let service = DictionaryService.shared
        let rules = AppSettings.symbolDictionaryRules

        // 1. 丸括弧 () - 「ひらきかっこ」「とじかっこ」「とじまるかっこ」「まるかっことじ」両対応
        assert(service.apply(text: "ひらきかっこテストとじかっこ", rules: rules) == "(テスト)")
        assert(service.apply(text: "ひらきかっこ テスト とじかっこ", rules: rules) == "(テスト)")
        assert(service.apply(text: "ひらきかっこテスト とじかっこ", rules: rules) == "(テスト)")
        assert(service.apply(text: "ひらきまるかっこhelloとじまるかっこ", rules: rules) == "(hello)")
        assert(service.apply(text: "ひらきかっこworldまるかっことじ", rules: rules) == "(world)")
        assert(service.apply(text: "Open parenthesisworldClose parenthesis", rules: rules) == "(world)")
        assert(service.apply(text: "open parenthesistestclose parenthesis", rules: rules) == "(test)")
        // 名詞単体の「丸括弧」「かっこ」は誤置換されずに保護されること
        assert(service.apply(text: "この部分は丸括弧で囲んでください", rules: rules) == "この部分は丸括弧で囲んでください")

        // 2. 角括弧 [] - 「ブラケット」「ぶらけっと」「かくかっこ」
        assert(service.apply(text: "ひらきブラケット配列とじブラケット", rules: rules) == "[配列]")
        assert(service.apply(text: "ひらきぶらけっと0とじぶらけっと", rules: rules) == "[0]")
        assert(service.apply(text: "ひらきかくかっこキーとじかくかっこ", rules: rules) == "[キー]")
        assert(service.apply(text: "Open bracket0Close bracket", rules: rules) == "[0]")
        assert(service.apply(text: "角括弧とブラケット", rules: rules) == "角括弧とブラケット")

        // 3. 波括弧 {} - 「ブレース」「ぶれーす」「なみかっこ」
        assert(service.apply(text: "ひらきブレースブロックとじブレース", rules: rules) == "{ブロック}")
        assert(service.apply(text: "ひらきなみかっこbodyとじなみかっこ", rules: rules) == "{body}")
        assert(service.apply(text: "Open bracebodyClose brace", rules: rules) == "{body}")
        assert(service.apply(text: "波括弧とブレース", rules: rules) == "波括弧とブレース")

        // 4. 鍵括弧 「」 - 「ひらきかぎかっこ」「とじかぎかっこ」「かぎかっことじ」
        assert(service.apply(text: "ひらきかぎかっこ重要とじかぎかっこ", rules: rules) == "「重要」")
        assert(service.apply(text: "ひらきかぎかっこ発言かぎかっことじ", rules: rules) == "「発言」")
        assert(service.apply(text: "Open quotespeechClose quote", rules: rules) == "「speech」")
        assert(service.apply(text: "鍵括弧の使い方", rules: rules) == "鍵括弧の使い方")

        // 5. ダブルクォート "" - 「ひらき」「とじ」両対応
        assert(service.apply(text: "ひらきダブルクォート引用ダブルクォートとじ", rules: rules) == "\"引用\"")
        assert(service.apply(text: "Open double quotetextClose double quote", rules: rules) == "\"text\"")

        // 6. シングルクォート '' - 「ひらき」「とじ」両対応
        assert(service.apply(text: "ひらきシングルクォート単語シングルクォートとじ", rules: rules) == "'単語'")
        assert(service.apply(text: "Open single quotecharClose single quote", rules: rules) == "'char'")

        // 7. 三点リーダー … / 二連三点リーダー ……
        assert(service.apply(text: "考え中さんてんリーダー", rules: rules) == "考え中…")
        assert(service.apply(text: "絶句にれんさんてんリーダー", rules: rules) == "絶句……")

        // 8. 感嘆符 (!) / びっくり記号（勝手に入った「。」「、」を巻き込んで「！」に置換。※単語「びっくりマーク」は辞書で破壊せず保護）
        assert(service.apply(text: "頑張ります!。", rules: rules) == "頑張ります！")
        assert(service.apply(text: "頑張ります！。", rules: rules) == "頑張ります！")
        assert(service.apply(text: "頑張ります。！", rules: rules) == "頑張ります！")
        assert(service.apply(text: "頑張ります! 。", rules: rules) == "頑張ります！")
        assert(service.apply(text: "びっくりマークの使い方", rules: rules) == "びっくりマークの使い方")

        // 9. 疑問符 (?) / はてな記号（勝手に入った「。」「、」を巻き込んで「？」に置換。※単語「はてなマーク」は辞書で破壊せず保護）
        assert(service.apply(text: "本当ですか?。", rules: rules) == "本当ですか？")
        assert(service.apply(text: "本当ですか？。", rules: rules) == "本当ですか？")
        assert(service.apply(text: "本当ですか。？", rules: rules) == "本当ですか？")
        assert(service.apply(text: "はてなマークの使い方", rules: rules) == "はてなマークの使い方")

        // 10. 英語の感嘆符 (!) / 疑問符 (?) のピリオド・カンマ巻き込み置換
        assert(service.apply(text: "Great!.", rules: rules) == "Great!")
        assert(service.apply(text: "Great.!", rules: rules) == "Great!")
        assert(service.apply(text: "Thank you. exclamation mark", rules: rules) == "Thank you!")
        assert(service.apply(text: "Really?.", rules: rules) == "Really?")
        assert(service.apply(text: "Really.?", rules: rules) == "Really?")
        assert(service.apply(text: "Are you sure. question mark", rules: rules) == "Are you sure?")

        // 10. 初期ルール (defaultDictionaryRules) に全記号ルールが最初から登録・有効化されていることを検証
        let defaultRules = AppSettings.defaultDictionaryRules
        for symbol in AppSettings.symbolDictionaryRules {
            let found = defaultRules.first(where: { $0.pattern == symbol.pattern })
            assert(found != nil, "Default rules must include symbol pattern: \(symbol.pattern)")
            assert(found!.isEnabled == true, "Symbol rule must be enabled by default: \(symbol.pattern)")
        }

        print("  -> Symbol Dictionary Rules passed!")
    }

    static func testVoiceIMEDiskSync() {
        print("[TEST] VoiceIMEDiskSyncService (一時ディレクトリによる安全な同期 & JSON復元)...")
        let syncService = VoiceIMEDiskSyncService.shared
        let originalBase = syncService.customBaseDirectory
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceime_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        syncService.customBaseDirectory = tempDir
        defer {
            syncService.customBaseDirectory = originalBase
            try? FileManager.default.removeItem(at: tempDir)
        }

        syncService.ensureDirectoryExists()
        assert(FileManager.default.fileExists(atPath: syncService.baseDirectory.path), "Base dir must exist")

        // テストデータ
        let testRules = [
            DictionaryRule(pattern: "テスト置換", replacement: "TestReplace", isRegex: false, isEnabled: true)
        ]
        let testVocab = ["テスト単語A", "テスト単語B"]

        // 個別書き出し (Granular Export) テスト
        syncService.exportDictionaryRulesToDisk(rules: testRules)
        assert(FileManager.default.fileExists(atPath: syncService.dictionaryFileURL.path), "dictionary.json should exist")

        syncService.exportVocabularyToDisk(vocabulary: testVocab)
        assert(FileManager.default.fileExists(atPath: syncService.vocabularyFileURL.path), "vocabulary.json should exist")

        // バックアップ（.bak）自動作成テスト: 更新時に直前のファイルが退避されるか
        let updatedVocab = ["テスト単語A", "テスト単語B", "新単語C"]
        syncService.exportVocabularyToDisk(vocabulary: updatedVocab)
        assert(FileManager.default.fileExists(atPath: syncService.vocabularyBackupFileURL.path), "vocabulary.json.bak should exist")

        // 読み込みテスト
        let loadedRules = syncService.importDictionaryFromDisk()
        assert(loadedRules != nil && loadedRules!.contains(where: { $0.pattern == "テスト置換" }), "Should decode rules from JSON")

        let loadedVocab = syncService.importVocabularyFromDisk()
        assert(loadedVocab != nil && loadedVocab!.contains("テスト単語A"), "Should decode vocab from JSON")

        // AI Agent が手動で ID やオプションを省略した最小限の JSON を書いた場合の互換デコードテスト
        let minimalJSON = """
        [
            {
                "pattern": "AI略称",
                "replacement": "Artificial Intelligence"
            }
        ]
        """.data(using: .utf8)!

        let decodedMinimal = try? JSONDecoder().decode([DictionaryRule].self, from: minimalJSON)
        assert(decodedMinimal != nil && decodedMinimal!.count == 1, "Minimal JSON should decode successfully")
        let firstRule = decodedMinimal!.first!
        assert(firstRule.pattern == "AI略称")
        assert(firstRule.replacement == "Artificial Intelligence")
        assert(firstRule.isEnabled == true, "isEnabled should default to true")

        print("  -> VoiceIMEDiskSync passed!")
    }

    static func testDictionaryService() {
        print("[TEST] DictionaryService...")
        let service = DictionaryService.shared

        // 1. プレーン置換
        let rules1 = [
            DictionaryRule(pattern: "改行", replacement: "\\n", isRegex: false, isEnabled: true),
            DictionaryRule(pattern: "株式会社テスト", replacement: "Test Corp.", isRegex: false, isEnabled: true)
        ]
        let out1 = service.apply(text: "こんにちは改行株式会社テストです", rules: rules1)
        assert(out1 == "こんにちは\nTest Corp.です", "Plain replacement failed: got \(out1)")

        // 2. 無効ルール
        let rules2 = [
            DictionaryRule(pattern: "テスト", replacement: "本番", isRegex: false, isEnabled: false)
        ]
        let out2 = service.apply(text: "これはテストです", rules: rules2)
        assert(out2 == "これはテストです", "Disabled rule test failed: got \(out2)")

        // 3. 正規表現置換
        let rules3 = [
            DictionaryRule(pattern: "([0-9]+)円", replacement: "¥$1", isRegex: true, isEnabled: true)
        ]
        let out3 = service.apply(text: "お会計は500円と1200円です", rules: rules3)
        assert(out3 == "お会計は¥500と¥1200です", "Regex test failed: got \(out3)")

        // 4. デフォルトの置換ルール (改行: 有効、郵便番号: チェックオフ無効)
        let defaultRules = AppSettings.defaultDictionaryRules
        let out4 = service.apply(text: "東京都千代田区1000001改行よろしくお願いいたします", rules: defaultRules)
        assert(out4 == "東京都千代田区1000001\nよろしくお願いいたします", "Default rules replacement failed (郵便番号 should be disabled by default): got \(out4)")

        // 郵便番号を有効化した場合のテスト
        let enabledRules = defaultRules.map { rule -> DictionaryRule in
            var r = rule
            if r.pattern.contains("[0-9]{3}") { r.isEnabled = true }
            return r
        }
        let out4Enabled = service.apply(text: "東京都千代田区1000001改行よろしくお願いいたします", rules: enabledRules)
        assert(out4Enabled == "東京都千代田区〒100-0001\nよろしくお願いいたします", "Enabled rule replacement failed: got \(out4Enabled)")

        // 5. 単語登録（customVocabulary）とプロンプトヒントの連動テスト
        let settings = AppSettings.shared
        let originalVocab = settings.customVocabulary
        settings.clearVocabulary()
        assert(settings.customVocabulary.isEmpty, "Vocabulary should be empty")

        settings.addVocabularyWord("VoiceIME")
        settings.addVocabularyWord("Kubernetes, 齋藤\nDocker")
        assert(settings.customVocabulary.contains("VoiceIME"), "Should contain VoiceIME")
        assert(settings.customVocabulary.contains("Kubernetes"), "Should contain Kubernetes")
        assert(settings.customVocabulary.contains("齋藤"), "Should contain 齋藤")
        assert(settings.customVocabulary.contains("Docker"), "Should contain Docker")
        assert(settings.promptHint.contains("VoiceIME"), "promptHint should synchronize with vocabulary")

        settings.removeVocabularyWord("Kubernetes")
        assert(!settings.customVocabulary.contains("Kubernetes"), "Should not contain Kubernetes after removal")

        // 状態復元
        settings.customVocabulary = originalVocab

        print("  -> DictionaryService passed!")
    }

    static func testKeychainService() {
        print("[TEST] KeychainService (isolated test service)...")
        let keychain = KeychainService(service: "com.voiceime.test.apikey")
        let testKey = "sk-test-key-\(UUID().uuidString)"

        // 1. 保存
        assert(keychain.saveAPIKey(testKey), "Keychain save failed")
        assert(keychain.hasAPIKey(), "hasAPIKey should be true")

        // 2. 取得
        let loaded = keychain.loadAPIKey()
        assert(loaded == testKey, "Loaded key doesn't match: \(String(describing: loaded))")

        // 3. 更新
        let updatedKey = "sk-updated-key-\(UUID().uuidString)"
        assert(keychain.saveAPIKey(updatedKey), "Keychain update failed")
        assert(keychain.loadAPIKey() == updatedKey, "Updated key doesn't match")

        // 4. 削除
        assert(keychain.deleteAPIKey(), "Keychain delete failed")
        assert(!keychain.hasAPIKey(), "hasAPIKey should be false after delete")

        // 5. プロバイダ別（Groq と OpenAI）の個別保存・独立性テスト
        let groqKey = "gsk_test_\(UUID().uuidString)"
        let openAIKey = "sk_test_\(UUID().uuidString)"

        assert(keychain.saveAPIKey(groqKey, for: .groq), "Save Groq key failed")
        assert(keychain.saveAPIKey(openAIKey, for: .openai), "Save OpenAI key failed")

        assert(keychain.loadAPIKey(for: .groq) == groqKey, "Groq key mismatch")
        assert(keychain.loadAPIKey(for: .openai) == openAIKey, "OpenAI key mismatch")

        assert(keychain.hasAPIKey(for: .groq), "hasAPIKey for groq should be true")
        assert(keychain.hasAPIKey(for: .openai), "hasAPIKey for openai should be true")

        // Groqキーだけ削除してもOpenAIキーは残る
        assert(keychain.deleteAPIKey(for: .groq), "Delete Groq key failed")
        assert(!keychain.hasAPIKey(for: .groq), "Groq key should be deleted")
        assert(keychain.hasAPIKey(for: .openai), "OpenAI key should still exist")

        keychain.deleteAPIKey(for: .openai)

        print("  -> KeychainService passed!")
    }

    @MainActor
    static func testLaunchAtLoginService() {
        print("[TEST] LaunchAtLoginService...")
        let service = LaunchAtLoginService.shared
        service.refresh()
        assert(service.statusMessage != "", "Status message should not be empty")
        print("  -> LaunchAtLoginService passed! (status: \(service.statusMessage))")
    }

    static func testLLMService() {
        print("[TEST] LLMService URL Construction...")
        let llm = LLMService.shared

        // 1. Groq URL
        let groqURL = llm.constructChatURL(from: "https://api.groq.com/openai/v1")
        assert(groqURL?.absoluteString == "https://api.groq.com/openai/v1/chat/completions",
               "Groq URL mismatch: \(String(describing: groqURL))")

        // 2. OpenAI URL
        let openAIURL = llm.constructChatURL(from: "https://api.openai.com/v1")
        assert(openAIURL?.absoluteString == "https://api.openai.com/v1/chat/completions",
               "OpenAI URL mismatch: \(String(describing: openAIURL))")

        // 3. 末尾スラッシュ・末尾パス付きURLの正規化
        let trailingSlashURL = llm.constructChatURL(from: "https://api.groq.com/openai/v1/")
        assert(trailingSlashURL?.absoluteString == "https://api.groq.com/openai/v1/chat/completions",
               "Trailing slash URL mismatch: \(String(describing: trailingSlashURL))")

        let fullEndpointURL = llm.constructChatURL(from: "https://api.groq.com/openai/v1/chat/completions")
        assert(fullEndpointURL?.absoluteString == "https://api.groq.com/openai/v1/chat/completions",
               "Full endpoint URL mismatch: \(String(describing: fullEndpointURL))")

        // 4. sanitizeLLMOutput のテスト（前置きラベルや引用符の除去）
        let out1 = llm.sanitizeLLMOutput("整形後：こんにちは、明日の天気はどうですか？", fallback: "元の文")
        assert(out1 == "こんにちは、明日の天気はどうですか？", "Prefix removal failed: \(out1)")

        let out2 = llm.sanitizeLLMOutput("「テストの文章です。」", fallback: "元の文")
        assert(out2 == "テストの文章です。", "Bracket removal failed: \(out2)")

        let out3 = llm.sanitizeLLMOutput("   \n\n  ", fallback: "フォールバック")
        assert(out3 == "フォールバック", "Empty fallback failed: \(out3)")

        // 5. 口語モード vs 文章モードのプロンプト生成テスト & カスタムプロンプト連動テスト
        let casualPrompt = llm.generateSystemPrompt(style: .casual, promptHint: "用語A, 用語B")
        assert(casualPrompt.contains("口語モード"), "Casual prompt should specify 口語モード")
        assert(casualPrompt.contains("用語A, 用語B"), "Casual prompt should contain prompt hint")

        let formalPrompt = llm.generateSystemPrompt(style: .formal, promptHint: nil)
        assert(formalPrompt.contains("文章モード"), "Formal prompt should specify 文章モード")

        // ユーザーカスタマイズプロンプトの動的反映テスト
        let settingsForPrompt = AppSettings.shared
        let originalCasual = settingsForPrompt.systemPromptCasual
        settingsForPrompt.systemPromptCasual = "テスト用カスタム口語プロンプト"
        let customCasualOut = llm.generateSystemPrompt(style: .casual, promptHint: nil)
        assert(customCasualOut == "テスト用カスタム口語プロンプト", "Custom casual prompt should be reflected")
        settingsForPrompt.systemPromptCasual = originalCasual

        // PromptConfig のエンコード・デコード検証
        let configTest = PromptConfig(
            casualSystemPrompt: "c1",
            formalSystemPrompt: "f1",
            userPromptTemplate: "u1 {input}"
        )
        let configData = try! JSONEncoder().encode(configTest)
        let decodedConfig = try! JSONDecoder().decode(PromptConfig.self, from: configData)
        assert(decodedConfig == configTest, "PromptConfig Codable mismatch")

        // 6. 英文句読点の正規化テスト (英語で入力した際に末尾が「。」でなく「.」になること等の検証)
        let enOut1 = LLMService.normalizePunctuation(for: "This is a test。")
        assert(enOut1 == "This is a test.", "English trailing period normalization failed: got '\(enOut1)'")

        let enOut2 = LLMService.normalizePunctuation(for: "How are you doing？")
        assert(enOut2 == "How are you doing?", "English trailing question mark normalization failed: got '\(enOut2)'")

        let enOut3 = LLMService.normalizePunctuation(for: "Hello world、how is it going。")
        assert(enOut3 == "Hello world, how is it going.", "English comma and period normalization failed: got '\(enOut3)'")

        let enOut4 = LLMService.normalizePunctuation(for: "Great job！")
        assert(enOut4 == "Great job!", "English exclamation mark normalization failed: got '\(enOut4)'")

        let enOut5 = llm.sanitizeLLMOutput("整形後：Thank you very much。", fallback: "fallback")
        assert(enOut5 == "Thank you very much.", "LLM output sanitize with English trailing period failed: got '\(enOut5)'")

        // 日本語文が維持されることの確認
        let jaOut1 = LLMService.normalizePunctuation(for: "明日の打ち合わせは10時からです。")
        assert(jaOut1 == "明日の打ち合わせは10時からです。", "Japanese trailing period should be preserved: got '\(jaOut1)'")

        let jaOut2 = LLMService.normalizePunctuation(for: "おすすめのPCはMacです。")
        assert(jaOut2 == "おすすめのPCはMacです。", "Japanese text with English word should preserve Japanese period: got '\(jaOut2)'")

        // 最後の文が英語の節で終わる場合の救済確認
        let mixedOut = LLMService.normalizePunctuation(for: "メモを作成しました。\nThank you for your help。")
        assert(mixedOut == "メモを作成しました。\nThank you for your help.", "Trailing English clause should have period normalized: got '\(mixedOut)'")

        // 7. AppSettings refinementStyle テスト
        let settings = AppSettings.shared
        let originalStyle = settings.refinementStyle
        settings.refinementStyle = .formal
        assert(settings.refinementStyle == .formal, "RefinementStyle should be formal")
        settings.refinementStyle = .casual
        assert(settings.refinementStyle == .casual, "RefinementStyle should be casual")
        settings.refinementStyle = originalStyle

        // 8. カスタムLLM URL 構築テスト (Ollama, LM Studio 等)
        let ollamaURL = llm.constructChatURL(from: "http://localhost:11434/v1")
        assert(ollamaURL?.absoluteString == "http://localhost:11434/v1/chat/completions",
               "Ollama custom URL mismatch: \(String(describing: ollamaURL))")

        let lmStudioURL = llm.constructChatURL(from: "http://localhost:1234/v1/")
        assert(lmStudioURL?.absoluteString == "http://localhost:1234/v1/chat/completions",
               "LM Studio custom URL mismatch: \(String(describing: lmStudioURL))")

        // 9. 共通推敲設定（ユーザー直接指定 & 未指定時は推敲OFF）テスト
        let originalUserBaseURL = settings.userLLMBaseURL
        let originalUserModel = settings.userLLMModel
        let originalRefinementEnabled = settings.llmRefinementEnabled

        // Sarashina 指定時
        settings.userLLMBaseURL = "https://api.sarashina.ai/v1"
        settings.userLLMModel = "sarashina3-mini"
        settings.llmRefinementEnabled = true
        assert(settings.resolvedLLMProvider == .sarashina, "resolvedLLMProvider should be sarashina")
        assert(settings.effectiveLLMConfig.modelName == "sarashina3-mini", "modelName should match")
        assert(settings.isLLMRefinementActive == true, "isLLMRefinementActive should be true when model is set")

        // 未指定（空欄）時 ➔ 推敲OFF
        settings.userLLMModel = ""
        assert(settings.isLLMRefinementActive == false, "isLLMRefinementActive should be false when model is empty")
        assert(settings.effectiveLLMProviderDisplayName.contains("未指定"), "displayName should indicate 未指定")

        // OpenAI 指定時
        settings.userLLMBaseURL = "https://api.openai.com/v1"
        settings.userLLMModel = "gpt-4o-mini"
        assert(settings.resolvedLLMProvider == .openai, "resolvedLLMProvider should be openai")
        assert(settings.isLLMRefinementActive == true, "isLLMRefinementActive should be true")

        // ローカル / カスタム 指定時
        settings.userLLMBaseURL = "http://localhost:11434/v1"
        settings.userLLMModel = "llama3.2"
        assert(settings.resolvedLLMProvider == .custom, "resolvedLLMProvider should be custom")
        assert(settings.effectiveLLMConfig.isCustom == true, "isCustom should be true for local LLM")
        assert(settings.isLLMRefinementActive == true, "isLLMRefinementActive should be true")

        // 状態復元
        settings.userLLMBaseURL = originalUserBaseURL
        settings.userLLMModel = originalUserModel
        settings.llmRefinementEnabled = originalRefinementEnabled

        // 10. AI語尾補完（「〜ですね」「〜ですか？」等のハルシネーション）の抑制テスト
        let hallucinated1 = LLMService.suppressHallucinatedEndings(
            output: "明日の予定の確認ですね。",
            originalInput: "明日の予定の確認"
        )
        assert(hallucinated1 == "明日の予定の確認。", "Hallucinated 'ですね' should be suppressed: got '\(hallucinated1)'")

        let hallucinated2 = LLMService.suppressHallucinatedEndings(
            output: "来週の進捗状況ですか？",
            originalInput: "来週の進捗状況"
        )
        assert(hallucinated2 == "来週の進捗状況。", "Hallucinated 'ですか？' should be suppressed: got '\(hallucinated2)'")

        let hallucinated3 = LLMService.suppressHallucinatedEndings(
            output: "新機能のリリースについてでしょうか？",
            originalInput: "新機能のリリースについて"
        )
        assert(hallucinated3 == "新機能のリリースについて。", "Hallucinated 'でしょうか？' should be suppressed: got '\(hallucinated3)'")

        // ユーザー自身が発話した「ですね」「ですか」は削られずに完全維持されることの検証
        let userSaidDesune = LLMService.suppressHallucinatedEndings(
            output: "明日の打ち合わせですね。",
            originalInput: "明日の打ち合わせですね"
        )
        assert(userSaidDesune == "明日の打ち合わせですね。", "User uttered 'ですね' must be preserved: got '\(userSaidDesune)'")

        let userSaidDesuka = LLMService.suppressHallucinatedEndings(
            output: "これでよろしいですか？",
            originalInput: "これでよろしいですか"
        )
        assert(userSaidDesuka == "これでよろしいですか？", "User uttered 'ですか' must be preserved: got '\(userSaidDesuka)'")

        // sanitizeLLMOutput 経由でのハルシネーション抑制確認
        let sanitizedHallucination = llm.sanitizeLLMOutput("整形後：議事録の送付ですね。", originalInput: "議事録の送付", fallback: "議事録の送付")
        assert(sanitizedHallucination == "議事録の送付。", "sanitizeLLMOutput should suppress hallucinated ending: got '\(sanitizedHallucination)'")

        // 11. XMLタグ（<formatted_text>）抽出テスト（Amical互換プロンプトフォーマット）
        let xmlOutput1 = llm.sanitizeLLMOutput("<formatted_text>本日の進捗状況です。</formatted_text>", fallback: "fallback")
        assert(xmlOutput1 == "本日の進捗状況です。", "XML formatted_text tag extraction failed: got '\(xmlOutput1)'")

        let xmlOutput2 = LLMService.extractFormattedText("AI思考プロセス...\n<formatted_text>\n会議の開始時間は15時です。\n</formatted_text>\n余計な注記")
        assert(xmlOutput2 == "会議の開始時間は15時です。", "XML wrapped multiline extraction failed: got '\(String(describing: xmlOutput2))'")

        // 11B. 改行（\n）の維持・自動復元テスト（LLMが1行に繋げてしまった場合でも入力の改行を復元）
        let multilineInput = "1. 総合バランス 初めて1台にするおすすめ\nXreal Air 2 Pro"
        let flattenedLLMResponse = "1. 総合バランス、初めて1台にするおすすめ、Xreal Air 2 Pro。"
        let restoredMultiline = llm.sanitizeLLMOutput(flattenedLLMResponse, originalInput: multilineInput, fallback: multilineInput)
        assert(restoredMultiline.contains("\n"), "Should restore newline from originalInput when LLM flattens it: got '\(restoredMultiline)'")

        // 12. WhisperAPIService sanitizeWhisperPrompt のバイト数制限と空白正規化テスト
        let normalPrompt = WhisperAPIService.sanitizeWhisperPrompt("  こんにちは   世界 \n\n  テスト  ", maxBytes: 800)
        assert(normalPrompt == "こんにちは 世界 テスト", "Whisper prompt whitespace normalization failed: got '\(normalPrompt)'")

        let longString = String(repeating: "あいうえお", count: 200) // 1000文字 = 3000バイト
        let truncated = WhisperAPIService.sanitizeWhisperPrompt(longString, maxBytes: 800)
        assert(truncated.utf8.count <= 800, "Truncated prompt should be <= 800 bytes, got \(truncated.utf8.count) bytes")
        assert(longString.hasSuffix(truncated), "Truncated string must be a valid suffix of original")

        print("  -> LLMService URL Construction, Sanitization, Punctuation Normalization, Prompt Modes, LLMProviderMode, and Whisper Prompt Sanitization passed!")
    }

    static func testAudioAnalysisService() {
        print("[TEST] AudioAnalysisService...")
        let service = AudioAnalysisService.shared
        let settings = AppSettings.shared

        // 1. AppSettings デフォルト値確認
        assert(settings.audioThresholdEnabled == true, "audioThresholdEnabled should be true by default")
        assert(settings.audioThresholdDB == -32.0, "audioThresholdDB should be -32.0 by default")
        assert(settings.audioTrimmingEnabled == true, "audioTrimmingEnabled should be true by default")

        let tempDir = FileManager.default.temporaryDirectory
        let silenceURL = tempDir.appendingPathComponent("test_silence_\(UUID().uuidString).m4a")
        let speechURL = tempDir.appendingPathComponent("test_speech_\(UUID().uuidString).m4a")

        let audioSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        defer {
            try? FileManager.default.removeItem(at: silenceURL)
            try? FileManager.default.removeItem(at: speechURL)
        }

        // 2. 微小音／環境音のみのファイル生成 (振幅 0.001 = 約 -60dB)
        do {
            let file = try AVAudioFile(forWriting: silenceURL, settings: audioSettings)
            let pcmFormat = file.processingFormat
            let frameCount: AVAudioFrameCount = 16000 // 1.0秒
            let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount)!
            buffer.frameLength = frameCount
            for i in 0..<Int(frameCount) {
                buffer.floatChannelData![0][i] = 0.001 * sin(Float(i) * 0.1)
            }
            try file.write(from: buffer)
        } catch {
            assertionFailure("Failed to write silence test audio: \(error)")
        }

        // 小さな音・無音の判定テスト: hasSpeech が false かつ isSilence が true になること
        let silenceMetrics = service.analyze(audioFileURL: silenceURL, thresholdDB: -32.0)
        assert(!silenceMetrics.hasSpeech, "Silence/small sound should NOT be recognized as speech! Got maxRMS=\(silenceMetrics.maxWindowRMS_DB)dB")
        assert(silenceMetrics.isSilence, "Silence file must be flagged as isSilence == true")
        assert(silenceMetrics.maxWindowRMS_DB < -32.0, "Silence RMS should be below -32dB")
        print("  -> Small sound rejection passed: maxRMS=\(String(format: "%.1f", silenceMetrics.maxWindowRMS_DB))dB < -32.0dB, isSilence=\(silenceMetrics.isSilence)")

        // 3. 発話音声を含むファイル生成 (無音 0.4s + 音声 0.8s (振幅 0.1 = 約 -20dB) + 無音 0.4s)
        do {
            let file = try AVAudioFile(forWriting: speechURL, settings: audioSettings)
            let pcmFormat = file.processingFormat
            let frameCount: AVAudioFrameCount = 25600 // 1.6秒
            let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount)!
            buffer.frameLength = frameCount
            for i in 0..<Int(frameCount) {
                if i >= 6400 && i < 19200 {
                    // 発話シミュレーション（-20dB）
                    buffer.floatChannelData![0][i] = 0.1 * sin(Float(i) * 0.1)
                } else {
                    // 無音・キー打鍵音
                    buffer.floatChannelData![0][i] = 0.001
                }
            }
            try file.write(from: buffer)
        } catch {
            assertionFailure("Failed to write speech test audio: \(error)")
        }

        // 音声の判定テスト: hasSpeech が true かつ isSilence が false になること
        let speechMetrics = service.analyze(audioFileURL: speechURL, thresholdDB: -32.0)
        assert(speechMetrics.hasSpeech, "Simulated speech should be recognized as speech!")
        assert(!speechMetrics.isSilence, "Normal speech must NOT be flagged as isSilence")
        assert(speechMetrics.maxWindowRMS_DB >= -32.0, "Speech RMS should be >= -32dB")
        print("  -> Speech detection passed: maxRMS=\(String(format: "%.1f", speechMetrics.maxWindowRMS_DB))dB >= -32.0dB, isSilence=\(speechMetrics.isSilence)")

        // 4. 短時間の単発クリック音／打鍵パルス（0.04秒の音のみ、持続しない音）のテスト
        let clickURL = tempDir.appendingPathComponent("test_click_\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: clickURL) }
        do {
            let file = try AVAudioFile(forWriting: clickURL, settings: audioSettings)
            let pcmFormat = file.processingFormat
            let frameCount: AVAudioFrameCount = 16000 // 1.0秒
            let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount)!
            buffer.frameLength = frameCount
            for i in 0..<Int(frameCount) {
                // 40ms だけ瞬間的に大きな音（キーボード打鍵の「カチッ」音）
                if i >= 4000 && i < 4640 {
                    buffer.floatChannelData![0][i] = 0.2
                } else {
                    buffer.floatChannelData![0][i] = 0.0001
                }
            }
            try file.write(from: buffer)
            let clickMetrics = service.analyze(audioFileURL: clickURL, thresholdDB: -32.0)
            assert(!clickMetrics.hasSpeech || clickMetrics.isSilence, "Short 40ms click/pulse must be rejected as speech or flagged as silence")
            print("  -> Transient click/pulse rejection passed: audibleDuration=\(String(format: "%.3f", clickMetrics.audibleDurationSeconds))s, isSilence=\(clickMetrics.isSilence)")
        } catch {
            assertionFailure("Failed to write click test audio: \(error)")
        }

        // 5. トリミングテスト: 発話前後の不要な微小音区間がトリミングされること
        if let trimmedURL = service.trimLeadingTrailingNoise(audioFileURL: speechURL, thresholdDB: -32.0) {
            defer { try? FileManager.default.removeItem(at: trimmedURL) }
            if let trimmedFile = try? AVAudioFile(forReading: trimmedURL) {
                let trimmedDuration = Double(trimmedFile.length) / trimmedFile.processingFormat.sampleRate
                assert(trimmedDuration < speechMetrics.totalDurationSeconds, "Trimmed duration should be shorter than original")
                print("  -> Noise trimming passed: original=\(String(format: "%.2f", speechMetrics.totalDurationSeconds))s -> trimmed=\(String(format: "%.2f", trimmedDuration))s")
            } else {
                assertionFailure("Failed to read trimmed file")
            }
        } else {
            assertionFailure("Trimming should succeed on padded audio")
        }

        print("  -> AudioAnalysisService passed!")
    }

    @MainActor
    static func testFloatingPreviewSettings() {
        print("[TEST] FloatingPreview Settings & Confirmed Text Sync...")
        let settings = AppSettings.shared

        // 初期値・型チェック
        assert(settings.floatingPreviewEnabled == true, "floatingPreviewEnabled should default to true")
        assert(settings.autoPasteEnabled == true, "autoPasteEnabled should default to true")
        assert(settings.floatingPreviewDuration >= 30.0, "floatingPreviewDuration should be positive default")
        assert(RecordingIndicatorColor.allCases.count >= 7, "RecordingIndicatorColor should have preset color choices")

        // 変更と復元のテスト
        let origFloating = settings.floatingPreviewEnabled
        let origAuto = settings.autoPasteEnabled
        let origDuration = settings.floatingPreviewDuration
        let origColor = settings.recordingIndicatorColor

        settings.recordingIndicatorColor = .purple
        assert(settings.recordingIndicatorColor == .purple, "recordingIndicatorColor should update to purple")
        settings.recordingIndicatorColor = .green
        assert(settings.recordingIndicatorColor == .green, "recordingIndicatorColor should update to green")
        settings.recordingIndicatorColor = origColor

        settings.floatingPreviewEnabled = false
        assert(!settings.floatingPreviewEnabled, "floatingPreviewEnabled should update to false")

        settings.autoPasteEnabled = false
        assert(!settings.autoPasteEnabled, "autoPasteEnabled should update to false")

        settings.floatingPreviewDuration = 60.0
        assert(settings.floatingPreviewDuration == 60.0, "floatingPreviewDuration should update to 60.0")

        // 元に戻す
        settings.floatingPreviewEnabled = origFloating
        settings.autoPasteEnabled = origAuto
        settings.floatingPreviewDuration = origDuration

        // ウィンドウ確定テキスト同期の検証:
        // 録音中（カタカナ表示）から処理中（processing）を経て確定テキスト（英語）が届いた時、
        // プレビューウィンドウの currentText が確実に確定成果物（did you finish it?）と一致すること
        let controller = FloatingPreviewController.shared
        controller.showLiveRecording()
        controller.updateLiveText("ディド ユー フィニッシュ イット")
        assert(controller.currentText == "ディド ユー フィニッシュ イット")

        controller.setProcessing()
        assert(controller.phase == .processing)

        // updateLiveText は processing 中は無視される仕様であること
        controller.updateLiveText("無視されるテキスト")
        assert(controller.currentText == "ディド ユー フィニッシュ イット")

        // updateConfirmedText は processing 中でも確実に確定テキストに同期すること
        controller.updateConfirmedText("did you finish it?")
        assert(controller.currentText == "did you finish it?", "Confirmed text must match final artifact exactly")
        assert(controller.phase == .ready, "Phase must become .ready upon confirmed text sync")

        // ＋キーによるピン留め・修正モード・消去のテスト
        controller.showLiveRecording()
        assert(!controller.isPinned, "showLiveRecording must reset isPinned to false")
        
        // 1回目の＋キー押下（ピン留め固定）
        controller.togglePinned()
        assert(controller.isPinned == true, "togglePinned must set isPinned to true")

        // 確定テキスト反映
        controller.updateConfirmedText("明日の会議は10時からです")
        assert(controller.isPinned == true, "isPinned must be preserved after updateConfirmedText")

        // テキスト修正（手動タイピング）シミュレーション
        controller.currentText = "明日の会議は11時からです"
        assert(controller.currentText == "明日の会議は11時からです")

        // 2回目の＋キー押下（修正完了による消去）
        controller.dismissAfterEditing()
        assert(!controller.isPinned, "dismissAfterEditing must reset isPinned to false")
        assert(!controller.isVisible, "dismissAfterEditing must hide the floating preview")
        assert(AppState.shared.lastProcessedText == "明日の会議は11時からです", "dismissAfterEditing must save corrected text to AppState")

        controller.hide()

        print("  -> FloatingPreview Settings & Confirmed Text Sync passed!")
    }

    static func testLivePunctuationFormatting() {
        print("[TEST] Live Punctuation Formatting & PunctuationService...")

        // 1. 文末表現の直後および末尾（$）が句点「。」に変換されること
        let in1 = "本日の作業は完了しました 明日もよろしくお願いします"
        let out1 = LiveSpeechService.formatLivePunctuation(text: in1, isJapanese: true)
        assert(out1 == "本日の作業は完了しました。明日もよろしくお願いします。", "Sentence ending replacement failed: got \(out1)")

        // 2. 接続詞後の空白が読点「、」に変換されること
        let in2 = "ですが 次のタスクに移ります"
        let out2 = LiveSpeechService.formatLivePunctuation(text: in2, isJapanese: true)
        assert(out2 == "ですが、次のタスクに移ります。", "Clause ending replacement failed: got \(out2)")

        // 3. 挨拶表現が読点「、」になり、末尾句点が付与されること
        let in3 = "こんにちは 明日の件ですが よろしくお願いします"
        let out3 = LiveSpeechService.formatLivePunctuation(text: in3, isJapanese: true)
        assert(out3 == "こんにちは、明日の件ですが、よろしくお願いします。", "Greeting and clause replacement failed: got \(out3)")

        // 4. 疑問文末尾が「？」になること
        let in4 = "明日の予定はいかがでしょうか"
        let out4 = LiveSpeechService.formatLivePunctuation(text: in4, isJapanese: true)
        assert(out4 == "明日の予定はいかがでしょうか？", "Question ending failed: got \(out4)")

        // 5. 辞書ルール（改行）が適用されること
        let in5 = "こんにちは改行お元気ですか"
        let out5 = LiveSpeechService.formatLivePunctuation(text: in5, isJapanese: true)
        assert(out5 == "こんにちは\nお元気ですか？", "Dictionary rule in live formatting failed: got \(out5)")

        // 6. PunctuationService.alignPunctuation によるプレビューとの厳格同期
        let liveRef = "本日の作業は完了しました。明日もよろしくお願いします。"
        let whisperOutput = "本日の作業は完了しました 明日もよろしくお願いします" // 句読点がないWhisper出力
        let aligned = PunctuationService.shared.alignPunctuation(
            text: whisperOutput,
            referenceLiveText: liveRef,
            isJapanese: true
        )
        assert(aligned == liveRef, "Align punctuation failed: got \(aligned), expected \(liveRef)")

        // 7. 「〜ですよね」の分断防止および「〜です。よね」の自動修復テスト
        let inYone1 = "まだ少し問題があるんですよね"
        let outYone1 = PunctuationService.shared.format(text: inYone1, isJapanese: true)
        assert(outYone1 == "まだ少し問題があるんですよね。", "Compound ending failed: got \(outYone1)")

        let inYone2 = "まだ少し問題があるんです。よね" // 誤って分断されたケースの修復
        let outYone2 = PunctuationService.shared.format(text: inYone2, isJapanese: true)
        assert(outYone2 == "まだ少し問題があるんですよね。", "Broken particle repair failed: got \(outYone2)")

        let inYone3 = "まだ少し問題があるんです よね" // 空白で分断されたケースの修復
        let outYone3 = PunctuationService.shared.format(text: inYone3, isJapanese: true)
        assert(outYone3 == "まだ少し問題があるんですよね。", "Space separated particle repair failed: got \(outYone3)")

        let inYone4 = "そうですよね 明日確認します"
        let outYone4 = PunctuationService.shared.format(text: inYone4, isJapanese: true)
        assert(outYone4 == "そうですよね。明日確認します。", "Sentence ending with next clause failed: got \(outYone4)")

        // 8. 「どうでしょうかねぇ」等の疑問文末終助詞の結合＆分断修復テスト
        let inQ1 = "どうでしょうかねぇ"
        let outQ1 = PunctuationService.shared.format(text: inQ1, isJapanese: true)
        assert(outQ1 == "どうでしょうかねぇ？", "Question with particle ending failed: got \(outQ1)")

        let inQ2 = "どうでしょうか？ねぇ" // 途中で誤って分断されたケースの修復
        let outQ2 = PunctuationService.shared.format(text: inQ2, isJapanese: true)
        assert(outQ2 == "どうでしょうかねぇ？", "Broken question particle repair failed: got \(outQ2)")

        let inQ3 = "どうでしょうか？ね？" // 途中で二重に？が入ったケースの修復
        let outQ3 = PunctuationService.shared.format(text: inQ3, isJapanese: true)
        assert(outQ3 == "どうでしょうかね？", "Double question particle repair failed: got \(outQ3)")

        // 9. 音声コマンド「改行」が同音異義語「開業」や「改行。」と認識されたケースの改行（\n）復元＆孤立「。」防止テスト
        let inKaigyo1 = "なかなか難しいですね、開業。次の入力は入りますか？"
        let outKaigyo1 = PunctuationService.shared.format(text: inKaigyo1, isJapanese: true)
        assert(outKaigyo1 == "なかなか難しいですね。\n次の入力は入りますか？", "Kaigyo homophone format failed: got \(outKaigyo1)")

        let inKaigyoWithPeriod = "なかなか難しいですね、改行。次の入力は入りますか？"
        let outKaigyoWithPeriod = PunctuationService.shared.format(text: inKaigyoWithPeriod, isJapanese: true)
        assert(outKaigyoWithPeriod == "なかなか難しいですね。\n次の入力は入りますか？", "Kaigyo with period format failed: got \(outKaigyoWithPeriod)")

        let inOrphanPeriodLine = "なかなか難しいですね。\n。\n次の入力は入りますか？"
        let outOrphanPeriodLine = PunctuationService.shared.format(text: inOrphanPeriodLine, isJapanese: true)
        assert(outOrphanPeriodLine == "なかなか難しいですね。\n次の入力は入りますか？", "Orphan period line cleanup failed: got \(outOrphanPeriodLine)")

        let refLiveWithNewline = "なかなか難しいですね、\n次の入力は入りますか？"
        let alignedKaigyo = PunctuationService.shared.alignPunctuation(
            text: "なかなか難しいですね、開業。次の入力は入りますか？",
            referenceLiveText: refLiveWithNewline,
            isJapanese: true
        )
        assert(alignedKaigyo == "なかなか難しいですね。\n次の入力は入りますか？", "Kaigyo alignPunctuation failed: got \(alignedKaigyo)")

        let alignedKaigyoWithNewlineAndPeriod = PunctuationService.shared.alignPunctuation(
            text: "なかなか難しいですね。\n改行。\n次の入力は入りますか？",
            referenceLiveText: "なかなか難しいですね。\n。\n次の入力は入りますか？",
            isJapanese: true
        )
        assert(alignedKaigyoWithNewlineAndPeriod == "なかなか難しいですね。\n次の入力は入りますか？", "Kaigyo newline+period alignPunctuation failed: got \(alignedKaigyoWithNewlineAndPeriod)")

        // 本来の語彙としての「開業」（開業する、開業医等）が誤って改行に変換されないことも検証
        let inRealKaigyo = "来月クリニックを開業します"
        let outRealKaigyo = PunctuationService.shared.format(text: inRealKaigyo, isJapanese: true)
        assert(outRealKaigyo == "来月クリニックを開業します。", "Real Kaigyo word should be preserved: got \(outRealKaigyo)")

        // 文中の名詞「改行のテスト」が「開業のテスト」と誤認識された場合に「改行のテスト」へ補正され、かつ途中で改行コードに化けないことを検証
        let inKaigyoNounTest = "今日は開業のテストします。開業。これでできるかな？"
        let outKaigyoNounTest = PunctuationService.shared.format(text: inKaigyoNounTest, isJapanese: true)
        assert(outKaigyoNounTest == "今日は改行のテストします。\nこれでできるかな？", "Kaigyo noun + command test failed: got \(outKaigyoNounTest)")

        // 10. 音声コマンド「改行」がAI・Whisperにより「開業ですね」「開業しました」と語尾補完・誤認識されたケースの救済テスト
        let inKaigyoDesune1 = "本日は晴天なり。開業ですね。"
        let outKaigyoDesune1 = PunctuationService.shared.format(text: inKaigyoDesune1, isJapanese: true)
        assert(outKaigyoDesune1 == "本日は晴天なり。\n", "Kaigyo '開業ですね。' after period failed: got '\(outKaigyoDesune1)'")

        let inKaigyoShimashita1 = "これで完了です。開業しました。"
        let outKaigyoShimashita1 = PunctuationService.shared.format(text: inKaigyoShimashita1, isJapanese: true)
        assert(outKaigyoShimashita1 == "これで完了です。\n", "Kaigyo '開業しました。' after period failed: got '\(outKaigyoShimashita1)'")

        let inKaigyoDesuneNoPunct = "よろしくお願いします開業ですね次の行です"
        let outKaigyoDesuneNoPunct = PunctuationService.shared.format(text: inKaigyoDesuneNoPunct, isJapanese: true)
        assert(outKaigyoDesuneNoPunct == "よろしくお願いします。\n次の行です。", "Kaigyo '開業ですね' without punct failed: got '\(outKaigyoDesuneNoPunct)'")

        let inKaigyoShimashitaNoPunct = "確認しました開業しました次の議題に移ります"
        let outKaigyoShimashitaNoPunct = PunctuationService.shared.format(text: inKaigyoShimashitaNoPunct, isJapanese: true)
        assert(outKaigyoShimashitaNoPunct == "確認しました。\n次の議題に移ります。", "Kaigyo '開業しました' without punct failed: got '\(outKaigyoShimashitaNoPunct)'")

        let inKaigyoDesuneStandalone = "開業ですね。"
        let outKaigyoDesuneStandalone = PunctuationService.shared.format(text: inKaigyoDesuneStandalone, isJapanese: true)
        assert(outKaigyoDesuneStandalone == "\n", "Standalone '開業ですね。' failed: got '\(outKaigyoDesuneStandalone)'")

        let inKaigyoShimashitaTrailing = "明日の予定について開業しました"
        let outKaigyoShimashitaTrailing = PunctuationService.shared.format(text: inKaigyoShimashitaTrailing, isJapanese: true)
        assert(outKaigyoShimashitaTrailing == "明日の予定について。\n", "Trailing '開業しました' failed: got '\(outKaigyoShimashitaTrailing)'")

        // 本物のビジネス「開業しました」「新規開業ですね」が誤変換されないことの検証
        let inRealBusiness1 = "今年クリニックを開業しました"
        let outRealBusiness1 = PunctuationService.shared.format(text: inRealBusiness1, isJapanese: true)
        assert(outRealBusiness1 == "今年クリニックを開業しました。", "Real business 'クリニックを開業しました' should not be converted: got '\(outRealBusiness1)'")

        let inRealBusiness2 = "新規開業ですね"
        let outRealBusiness2 = PunctuationService.shared.format(text: inRealBusiness2, isJapanese: true)
        assert(outRealBusiness2 == "新規開業ですね。", "Real business '新規開業ですね' should not be converted: got '\(outRealBusiness2)'")

        // 11. 名詞直後の「改行」「開業」コマンド（「これはテスト開業次の行」「これはテスト 開業次の行」）の改行救済テスト
        let inKaigyoNounInline1 = "これはテスト開業次の行"
        let outKaigyoNounInline1 = PunctuationService.shared.format(text: inKaigyoNounInline1, isJapanese: true)
        assert(outKaigyoNounInline1 == "これはテスト\n次の行", "Inline kaigyo after noun failed: got '\(outKaigyoNounInline1)'")

        let inKaigyoNounInline2 = "これはテスト 開業次の行"
        let outKaigyoNounInline2 = PunctuationService.shared.format(text: inKaigyoNounInline2, isJapanese: true)
        assert(outKaigyoNounInline2 == "これはテスト\n次の行", "Inline kaigyo with space after noun failed: got '\(outKaigyoNounInline2)'")

        // 12. カタカナ・表記揺れ（「あ、ビックリマーク！」「あ！マルカコトジ」）および文末判定と単語保護テスト
        let inKatakanaExcl = "あ、ビックリマーク！"
        let outKatakanaExcl = PunctuationService.shared.format(text: inKatakanaExcl, isJapanese: true)
        assert(outKatakanaExcl == "あ！", "Katakana exclamation mark with trailing ! failed: got '\(outKatakanaExcl)'")

        let inBareExcl1 = "あ、びっくりマーク"
        let outBareExcl1 = PunctuationService.shared.format(text: inBareExcl1, isJapanese: true)
        assert(outBareExcl1 == "あ！", "Trailing 'あ、びっくりマーク' failed: got '\(outBareExcl1)'")

        let inBareExcl2 = "あびっくりマーク"
        let outBareExcl2 = PunctuationService.shared.format(text: inBareExcl2, isJapanese: true)
        assert(outBareExcl2 == "あ！", "Trailing 'あびっくりマーク' failed: got '\(outBareExcl2)'")

        let inBareQuest = "あはてなマーク"
        let outBareQuest = PunctuationService.shared.format(text: inBareQuest, isJapanese: true)
        assert(outBareQuest == "あ？", "Trailing 'あはてなマーク' failed: got '\(outBareQuest)'")

        // 13. 文中の名詞「びっくりマーク」「はてなマーク」の保護テスト（強制置換されないこと）
        let inNounExcl1 = "びっくりマークの使い方"
        let outNounExcl1 = PunctuationService.shared.format(text: inNounExcl1, isJapanese: true)
        assert(outNounExcl1 == "びっくりマークの使い方", "Noun 'びっくりマークの使い方' should be preserved: got '\(outNounExcl1)'")

        let inNounExcl2 = "びっくりマークも文書中に出てくるから"
        let outNounExcl2 = PunctuationService.shared.format(text: inNounExcl2, isJapanese: true)
        assert(outNounExcl2 == "びっくりマークも文書中に出てくるから", "Noun 'びっくりマークも文書中に出てくるから' should be preserved: got '\(outNounExcl2)'")

        let inNounExcl3 = "ここにびっくりマークを入れてください"
        let outNounExcl3 = PunctuationService.shared.format(text: inNounExcl3, isJapanese: true)
        assert(outNounExcl3 == "ここにびっくりマークを入れてください", "Noun 'ここにびっくりマークを入れてください' should be preserved: got '\(outNounExcl3)'")

        let inNounQuest = "はてなマークの使い方"
        let outNounQuest = PunctuationService.shared.format(text: inNounQuest, isJapanese: true)
        assert(outNounQuest == "はてなマークの使い方", "Noun 'はてなマークの使い方' should be preserved: got '\(outNounQuest)'")

        let inKatakanaParen = "あ！マルカコトジ"
        let outKatakanaParen = PunctuationService.shared.format(text: inKatakanaParen, isJapanese: true)
        assert(outKatakanaParen == "あ！)", "Katakana close paren 'マルカコトジ' failed: got '\(outKatakanaParen)'")

        // 14. 括弧内の余計な空白および連続括弧間の空白除去テスト
        let inBracketSpace1 = "(テスト )"
        let outBracketSpace1 = PunctuationService.shared.format(text: inBracketSpace1, isJapanese: true)
        assert(outBracketSpace1 == "(テスト)", "Trailing space in paren failed: got '\(outBracketSpace1)'")

        let inBracketSpace2 = "( テスト )"
        let outBracketSpace2 = PunctuationService.shared.format(text: inBracketSpace2, isJapanese: true)
        assert(outBracketSpace2 == "(テスト)", "Surrounding space in paren failed: got '\(outBracketSpace2)'")

        let inBracketSpace3 = "(テスト ) (テスト )"
        let outBracketSpace3 = PunctuationService.shared.format(text: inBracketSpace3, isJapanese: true)
        assert(outBracketSpace3 == "(テスト)(テスト)", "Consecutive paren spaces failed: got '\(outBracketSpace3)'")

        let inBracketSpace4 = "(テスト) テスト(テスト) テスト"
        let outBracketSpace4 = PunctuationService.shared.format(text: inBracketSpace4, isJapanese: true)
        assert(outBracketSpace4 == "(テスト)テスト(テスト)テスト", "Paren to Japanese space failed: got '\(outBracketSpace4)'")

        // 15. 記号と音声コマンド重複の除去テスト（「お前な！びっくりマーク」➔「お前な！」、「本当ですか？はてなマーク」➔「本当ですか？」）
        let inDupExcl1 = "彼は言った「お前な！びっくりマーク」"
        let outDupExcl1 = PunctuationService.shared.format(text: inDupExcl1, isJapanese: true)
        assert(outDupExcl1 == "彼は言った「お前な！」", "Duplicate 'お前な！びっくりマーク' failed: got '\(outDupExcl1)'")

        let inDupExcl2 = "お前な！びっくりマーク"
        let outDupExcl2 = PunctuationService.shared.format(text: inDupExcl2, isJapanese: true)
        assert(outDupExcl2 == "お前な！", "Duplicate 'お前な！びっくりマーク' failed: got '\(outDupExcl2)'")

        let inDupQuest1 = "本当ですか？はてなマーク"
        let outDupQuest1 = PunctuationService.shared.format(text: inDupQuest1, isJapanese: true)
        assert(outDupQuest1 == "本当ですか？", "Duplicate '本当ですか？はてなマーク' failed: got '\(outDupQuest1)'")

        let inDupQuest2 = "本当ですか？クエスチョンマーク"
        let outDupQuest2 = PunctuationService.shared.format(text: inDupQuest2, isJapanese: true)
        assert(outDupQuest2 == "本当ですか？", "Duplicate '本当ですか？クエスチョンマーク' failed: got '\(outDupQuest2)'")

        let inBracketEndExcl = "彼は言った「お前なびっくりマーク」"
        let outBracketEndExcl = PunctuationService.shared.format(text: inBracketEndExcl, isJapanese: true)
        assert(outBracketEndExcl == "彼は言った「お前な！」", "Bracket end exclamation mark failed: got '\(outBracketEndExcl)'")

        // 16. 「のですべて」「いますぐ」「あとでする」等の語中「です/ます」誤分断防止および動詞重複（スタッター）修復テスト
        let inNodeSubete = "日本語は文字列が最後が重要で何何しないとするでは全然違うのですべてを表示することがすごく大事です"
        let outNodeSubete = PunctuationService.shared.format(text: inNodeSubete, isJapanese: true)
        assert(!outNodeSubete.contains("のです。べて"), "'のですべて' must NEVER be split into 'のです。べて': got '\(outNodeSubete)'")
        assert(outNodeSubete == "日本語は文字列が最後が重要で何何しないとするでは全然違うのですべてを表示することがすごく大事です。", "Expected preserved 'のですべて' and trailing period, got '\(outNodeSubete)'")

        let llmInputNodeSubete = StreamingChunkPipelineService.applyDictionaryRulesForLLMInput(to: inNodeSubete)
        assert(!llmInputNodeSubete.contains("のです。べて"), "LLM input preprocessing must NEVER split 'のですべて': got '\(llmInputNodeSubete)'")
        assert(llmInputNodeSubete == inNodeSubete, "LLM input preprocessing should preserve natural text: got '\(llmInputNodeSubete)'")

        let inImasugu = "いますぐ確認してあとでする予定です"
        let outImasugu = PunctuationService.shared.format(text: inImasugu, isJapanese: true)
        assert(!outImasugu.contains("います。ぐ") && !outImasugu.contains("あとです。る"), "'いますぐ' and 'あとでする' must not be split: got '\(outImasugu)'")

        let inStutter = "<formatted_text>すべてを表示するすることがすごく大事です。</formatted_text>"
        let outStutter = LLMService.shared.sanitizeLLMOutput(inStutter, originalInput: inNodeSubete, fallback: inNodeSubete)
        assert(outStutter == "すべてを表示することがすごく大事です。", "Verb stutter '表示するすることが' should be cleaned: got '\(outStutter)'")

        print("  -> Live Punctuation Formatting & PunctuationService passed!")
    }

    static func testQuickAskAndPasteShortcuts() {
        print("[TEST] Quick Ask & Paste Shortcuts...")

        // 1. AppSettings のデフォルト値検証
        let settings = AppSettings.shared
        assert(settings.quickAskHotkeyCode == 49, "Default quickAskHotkeyCode should be Space (49)")
        assert(settings.quickAskHotkeyModifiers == UInt32(controlKey | shiftKey), "Default quickAskHotkeyModifiers should be Ctrl+Shift (4608)")
        assert(settings.quickAskHotkeyDisplayString == "⌃⇧Space", "Default quickAskHotkeyDisplayString should be ⌃⇧Space")

        assert(settings.pasteShortcutKeyCode == 36, "Default pasteShortcutKeyCode should be Return (36)")
        assert(settings.pasteShortcutModifiers == UInt32(cmdKey), "Default pasteShortcutModifiers should be Command (256)")
        assert(settings.pasteShortcutDisplayString == "⌘↩", "Default pasteShortcutDisplayString should be ⌘↩")

        // 会話モデル（クイック質問）のプロバイダー設定
        assert(settings.quickAskProviderMode == .sameAsLLM, "Default quickAskProviderMode should be sameAsLLM")
        assert(settings.groqQuickAskModel == "llama-3.3-70b-versatile", "Default groqQuickAskModel")
        assert(settings.openAIQuickAskModel == "gpt-4o-mini", "Default openAIQuickAskModel")
        assert(settings.customQuickAskModel == "llama3.2", "Default customQuickAskModel")

        // sameAsLLM のときの有効設定
        let cfgLLM = settings.effectiveQuickAskConfig
        assert(cfgLLM.modelName == settings.currentLLMModelName, "sameAsLLM should match currentLLMModelName")

        // groq モードに切り替えた場合の有効設定
        settings.quickAskProviderMode = .groq
        assert(settings.effectiveQuickAskConfig.modelName == "llama-3.3-70b-versatile")
        assert(settings.effectiveQuickAskConfig.provider == .groq)

        // openai モードに切り替えた場合の有効設定
        settings.quickAskProviderMode = .openai
        assert(settings.effectiveQuickAskConfig.modelName == "gpt-4o-mini")
        assert(settings.effectiveQuickAskConfig.provider == .openai)

        // custom モードに切り替えた場合の有効設定
        settings.quickAskProviderMode = .custom
        assert(settings.effectiveQuickAskConfig.modelName == "llama3.2")
        assert(settings.effectiveQuickAskConfig.isCustom == true)

        // 状態復元
        settings.quickAskProviderMode = .sameAsLLM

        // 2. LLMService のクイック質問出力サニタイズ検証
        let llm = LLMService.shared
        // 不要なラベルの除去
        assert(llm.sanitizeQuickAskOutput("答え：trash") == "trash", "Prefix removal failed")
        assert(llm.sanitizeQuickAskOutput("回答: 4") == "4", "Prefix removal failed")
        assert(llm.sanitizeQuickAskOutput("Answer: Paris") == "Paris", "Prefix removal failed")

        // 引用符の除去
        assert(llm.sanitizeQuickAskOutput("「trash」") == "trash", "Quotes removal failed")
        assert(llm.sanitizeQuickAskOutput("\"Paris\"") == "Paris", "Double quotes removal failed")

        // 最大2行制限テスト（3行以上ある場合は最初の2行のみ残す）
        let threeLines = "1行目です。\n2行目です。\n3行目は不要です。"
        assert(llm.sanitizeQuickAskOutput(threeLines) == "1行目です。\n2行目です。", "Multi-line capping to 2 lines failed")

        // 空白または答えなし
        assert(llm.sanitizeQuickAskOutput("") == "[答えを持っていません。]", "Empty output fallback failed")
        assert(llm.sanitizeQuickAskOutput("   ") == "[答えを持っていません。]", "Whitespace output fallback failed")

        // 3. StreamingChunkPipelineService.applyDictionaryRules のリアルタイム音声コマンド（開業/改行/ピリオド）置換テスト
        let rawWhisperInput = "お買い物リスト開業1.ピリオド"
        let converted = StreamingChunkPipelineService.applyDictionaryRules(to: rawWhisperInput)
        assert(converted.contains("お買い物リスト\n1."), "Expected newline and period conversion: got '\(converted)'")

        // 4. クイック質問の送信前修正モードテスト
        let fpController = FloatingPreviewController.shared
        var submittedQuestion = ""
        fpController.showQuickAskQuestionForEditing(question: "ゴミの英語は？") { q in
            submittedQuestion = q
        }
        assert(fpController.isQuickAskQuestionEditing == true, "isQuickAskQuestionEditing should be true")
        assert(fpController.isPinned == true, "isPinned should be true")
        assert(fpController.currentText == "ゴミの英語は？")

        // ユーザーによる質問文の修正
        fpController.currentText = "粗大ゴミの英語は？"

        // 送信実行（⌘+Enter / submitQuickAskQuestion）
        fpController.submitQuickAskQuestion()
        assert(submittedQuestion == "粗大ゴミの英語は？", "Submitted question should match corrected text")
        assert(fpController.isQuickAskQuestionEditing == false, "isQuickAskQuestionEditing should be reset to false after submission")
        assert(fpController.phase == .processing, "Phase should transition to .processing")
        fpController.hide()

        print("  -> Quick Ask & Paste Shortcuts passed!")
    }

    static func testPipelineLogger() {
        print("[TEST] PipelineLogger (リアルタイムパイプラインログ記録 - デフォルトOFF & 有効化テスト)...")

        let logger = PipelineLogger.shared
        let logURL = logger.logFileURL

        // 1. デフォルト (未設定時) は OFF であることを検証
        UserDefaults.standard.removeObject(forKey: "voiceime_pipelineLoggingEnabled")
        assert(!logger.isLoggingEnabled, "isLoggingEnabled should default to false (Privacy by Default)")

        // 2. ログ有効化 (ON - ユーザー同意時) のテスト
        UserDefaults.standard.set(true, forKey: "voiceime_pipelineLoggingEnabled")
        assert(logger.isLoggingEnabled, "isLoggingEnabled should be true after explicit user enable")

        // テスト用のログ書き込み
        logger.logSessionStart()
        logger.logWhisperReceived(type: "テスト速報", text: "海人の中東派遣1年延長へ")
        logger.logLLMInput(type: "テスト推敲", text: "海人の中東派遣1年延長へ")
        logger.logLLMOutput(type: "テスト推敲", text: "海自の中東派遣1年延長へ")
        logger.logSessionEnd(finalText: "海自の中東派遣1年延長へ")

        // 非同期キューの書き込み完了を少し待機
        Thread.sleep(forTimeInterval: 0.1)

        assert(FileManager.default.fileExists(atPath: logURL.path), "Log file should exist at \(logURL.path)")

        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            fatalError("Failed to read log file at \(logURL.path)")
        }

        // 1. 2. 3. のラベルとそれぞれの前に改行があることを検証
        assert(content.contains("1. Whisperから逐次送られてきた文字列 [テスト速報"), "Expected 1. Whisper label in log")
        assert(content.contains("2. Whisperから推敲LLMへ送られる文字列 [テスト推敲"), "Expected 2. LLM input label in log")
        assert(content.contains("3. 推敲LLMから修正され戻される文字列 [テスト推敲"), "Expected 3. LLM output label in log")
        assert(content.contains("\n1. Whisperから逐次送られてきた文字列"), "Expected newline before 1.")
        assert(content.contains("\n2. Whisperから推敲LLMへ送られる文字列"), "Expected newline before 2.")
        assert(content.contains("\n3. 推敲LLMから修正され戻される文字列"), "Expected newline before 3.")
        assert(content.contains("海人の中東派遣1年延長へ"), "Expected logged transcribed text")
        assert(content.contains("海自の中東派遣1年延長へ"), "Expected logged refined text")

        // 3. ログ無効化 (OFF) のテスト
        UserDefaults.standard.set(false, forKey: "voiceime_pipelineLoggingEnabled")
        assert(!logger.isLoggingEnabled, "isLoggingEnabled should be false")
        let lengthBefore = (try? String(contentsOf: logURL, encoding: .utf8))?.count ?? 0
        logger.logDebug("This message should not be logged when disabled")
        Thread.sleep(forTimeInterval: 0.1)
        let lengthAfter = (try? String(contentsOf: logURL, encoding: .utf8))?.count ?? 0
        assert(lengthBefore == lengthAfter, "Log should not grow when disabled")

        print("  -> PipelineLogger passed! Log location: \(logURL.path)")
    }

    static func testSystemLogger() {
        print("[TEST] SystemLogger (~/Library/Logs/voiceime/YYYYMMDD.log 診断・監査・例外ログ)...")

        let sysLogger = SystemLogger.shared
        let logURL = sysLogger.currentLogFileURL()

        sysLogger.logAudit("ユーザー操作によりパイプラインログ記録が有効化されました (テスト監査)")
        sysLogger.logInfo("システム構成テスト: STT=Groq, LLM=OpenAI (有効)")
        sysLogger.logError("テストAPI通信エラー (401 Unauthorized)")
        sysLogger.logException("テスト例外ハンドリング", error: NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sample exception"]))

        Thread.sleep(forTimeInterval: 0.15)

        assert(FileManager.default.fileExists(atPath: logURL.path), "System log file must exist at \(logURL.path)")

        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            fatalError("Failed to read system log file at \(logURL.path)")
        }

        assert(content.contains("[AUDIT] ユーザー操作によりパイプラインログ記録が有効化されました"), "Expected AUDIT log")
        assert(content.contains("[INFO] システム構成テスト"), "Expected INFO log")
        assert(content.contains("[ERROR] テストAPI通信エラー"), "Expected ERROR log")
        assert(content.contains("[EXCEPTION] テスト例外ハンドリング"), "Expected EXCEPTION log")

        print("  -> SystemLogger passed! System log location: \(logURL.path)")
    }

    @MainActor
    static func testAudioDeviceService() {
        print("[TEST] AudioDeviceService (マイク選択・ハードウェア列挙・自動フォールバック)...")

        let service = AudioDeviceService.shared
        service.refreshDevices()

        // 1. デバイス一覧とデフォルトデバイスの取得検証
        let devices = service.availableDevices
        let defaultDev = service.systemDefaultDevice
        print("  -> Detected \(devices.count) input devices. Default: [\(defaultDev?.name ?? "none")]")
        assert(!devices.isEmpty || defaultDev != nil, "At least one input device or system default should be detected on macOS")

        let originalUID = AppSettings.shared.selectedAudioDeviceUID
        let originalName = AppSettings.shared.selectedAudioDeviceName

        // 2. システムデフォルト選択テスト
        service.selectDevice(uid: "", name: "システムデフォルト")
        assert(service.isFallbackActive == false, "System default selection should not trigger fallback")
        assert(service.effectiveDeviceName.contains("システムデフォルト"), "Effective device should indicate system default")

        // 3. 存在しない未接続デバイス（例: 電源OFFのBluetoothイヤホン）選択時のフォールバックテスト
        let fakeUID = "fake-wireless-earphone-uid-\(UUID().uuidString)"
        let fakeName = "Wireless Headset (Test Unconnected Device)"
        service.selectDevice(uid: fakeUID, name: fakeName)

        assert(service.isFallbackActive == true, "Selecting non-existent device MUST trigger fallback")
        assert(service.effectiveDeviceName.contains("代替") || service.effectiveDeviceName.contains("デフォルト"), "Effective device must indicate fallback")
        assert(service.fallbackReason != nil, "Fallback reason should be explained")
        print("  -> Fallback verified: \(service.fallbackReason ?? "")")

        // 4. 実在するデバイスを選択したテスト
        if let realDev = devices.first {
            service.selectDevice(uid: realDev.id, name: realDev.name)
            assert(service.isFallbackActive == false, "Real device should not trigger fallback")
            assert(service.effectiveDeviceName == realDev.name, "Effective device should match selected real device")
            print("  -> Real device selection verified: \(realDev.name)")
        }

        // 5. 状態復元
        service.selectDevice(uid: originalUID, name: originalName)
        print("  -> AudioDeviceService passed!")
    }

    @MainActor
    static func testCorrectionStockService() {
        print("[TEST] CorrectionStockService & '-' キー単語登録...")

        // 1. 差分検出テスト (detectWordDiff)
        // A. 単語の置き換え
        let diff1 = CorrectionStockService.detectWordDiff(
            original: "明日は渋谷公会堂に行きます",
            corrected: "明日は渋公に行きます"
        )
        assert(diff1 != nil, "Diff should be detected")
        assert(diff1?.before == "渋谷公会堂", "diff.before should be '渋谷公会堂', got '\(diff1?.before ?? "")'")
        assert(diff1?.after == "渋公", "diff.after should be '渋公', got '\(diff1?.after ?? "")'")

        // B. スペース・表記揺れの修正
        let diff2 = CorrectionStockService.detectWordDiff(
            original: "Voice IMEの使い方マニュアル",
            corrected: "VoiceIMEの使い方マニュアル"
        )
        assert(diff2 != nil, "Diff should be detected")
        assert(diff2?.after == "VoiceIME" || diff2?.before.contains("IME") == true, "Should detect word correction")

        // C. 差分なしの場合
        let diffNone = CorrectionStockService.detectWordDiff(
            original: "変更のない文章です",
            corrected: "変更のない文章です"
        )
        assert(diffNone == nil, "Identical text should return nil")

        // 2. 単語登録テスト (registerVocabularyWord)
        let testWord = "渋公_\(UUID().uuidString.prefix(6))"
        let regSuccess = CorrectionStockService.shared.registerVocabularyWord(String(testWord))
        assert(regSuccess == true, "Registration should succeed")
        assert(AppSettings.shared.vocabulary.contains(String(testWord)), "Settings should contain registered word")

        // 3. 履歴ストック記録テスト (recordCorrection & loadRecordsFromDisk)
        CorrectionStockService.shared.recordCorrection(
            original: "テスト前の文章",
            corrected: "テスト後の文章",
            diffBefore: "前",
            diffAfter: "後",
            isRegistered: true
        )

        // わずかに待機してディスク反映を確認
        Thread.sleep(forTimeInterval: 0.1)
        let records = CorrectionStockService.shared.loadRecordsFromDisk()
        assert(!records.isEmpty, "Records should be loaded from disk")
        assert(records.contains { $0.diffBefore == "前" && $0.diffAfter == "後" }, "Stock should contain recorded diff")

        // クリーンアップ
        AppSettings.shared.removeVocabularyWord(String(testWord))
        CorrectionStockService.shared.clearStock()

        print("  -> CorrectionStockService passed!")
    }

    @MainActor
    static func testImmediateCaptureAndLeadingVoicePreservation() {
        print("[TEST] Immediate Capture, Pre-Roll Ring Buffer & Leading Voice Preservation...")

        let pipeline = StreamingChunkPipelineService.shared
        pipeline.prepareImmediateCapture(speechThresholdDB: -32.0, isStreamingTriggerEnabled: false)

        let format = AVAudioFormat(standardFormatWithSampleRate: 16000.0, channels: 1)!

        // 1. 0.30秒のプリロールバッファ（キーを押した瞬間の小さな出だし声: -38dB = 振幅 0.0126）を投入
        let preRollFrames: AVAudioFrameCount = 4800 // 0.30s
        let preRollBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: preRollFrames)!
        preRollBuf.frameLength = preRollFrames
        for i in 0..<Int(preRollFrames) {
            preRollBuf.floatChannelData![0][i] = 0.015 * sin(Float(i) * 0.1)
        }
        pipeline.appendAudioBuffer(preRollBuf, isPreRoll: true)

        // 2. start() が後から呼ばれても、先行キャプチャしたプリロール音声が消えずに保持されることを検証
        pipeline.start(
            whisperConfig: (baseURL: "https://api.groq.com/openai/v1", apiKey: nil, model: "whisper-large-v3-turbo"),
            llmConfig: (baseURL: "", apiKey: nil, model: "", isCustom: false),
            style: .casual,
            isLLMEnabled: false,
            whisperPrompt: nil,
            language: "ja",
            speechThresholdDB: -32.0
        )

        // 3. 続く本発話（0.50秒: -20dB = 振幅 0.1）を投入
        let liveFrames: AVAudioFrameCount = 8000 // 0.50s
        let liveBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: liveFrames)!
        liveBuf.frameLength = liveFrames
        for i in 0..<Int(liveFrames) {
            liveBuf.floatChannelData![0][i] = 0.1 * sin(Float(i) * 0.1)
        }
        pipeline.appendAudioBuffer(liveBuf, isPreRoll: false)

        // 4. exportFullAudioWAV() でプリロール(0.30s) + 本発話(0.50s) = 0.80s のWAVが書き出されることを検証
        guard let exportedWAV = pipeline.exportFullAudioWAV() else {
            assertionFailure("exportFullAudioWAV() must return a valid WAV URL")
            return
        }
        defer { try? FileManager.default.removeItem(at: exportedWAV) }

        if let audioFile = try? AVAudioFile(forReading: exportedWAV) {
            let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            assert(abs(duration - 0.80) < 0.05, "Exported WAV must contain both 0.30s pre-roll and 0.50s live audio (expected ~0.80s, got \(duration)s)")
            print("  -> Pre-roll + immediate capture WAV export verified: duration=\(String(format: "%.2f", duration))s")
        } else {
            assertionFailure("Failed to read exported WAV file")
        }

        pipeline.cancel()
        print("  -> Immediate Capture & Leading Voice Preservation passed!")
    }

    static func testPushToTalkPauseAndResume() {
        print("[TEST] Push-to-Talk Pause and Resume (思考サポート・マイク一時停止 & 継続録音)...")

        let pipeline = StreamingChunkPipelineService.shared
        pipeline.prepareImmediateCapture(speechThresholdDB: -40.0, isStreamingTriggerEnabled: false)

        pipeline.start(
            whisperConfig: (baseURL: "https://api.groq.com/openai/v1", apiKey: nil, model: "whisper-large-v3-turbo"),
            llmConfig: (baseURL: "", apiKey: nil, model: "", isCustom: false),
            style: .casual,
            isLLMEnabled: false,
            whisperPrompt: nil,
            language: "ja",
            speechThresholdDB: -40.0
        )

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

        // 1. 最初の発話（0.40秒）
        let frames1: AVAudioFrameCount = 6400 // 0.40s
        let buf1 = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames1)!
        buf1.frameLength = frames1
        for i in 0..<Int(frames1) {
            buf1.floatChannelData![0][i] = 0.1 * sin(Float(i) * 0.1)
        }
        pipeline.appendAudioBuffer(buf1, isPreRoll: false)

        // 2. Spaceキーを離して一時停止（マイクOFF）
        pipeline.pauseCapture()

        // 3. 再度Spaceキーを押して再開（マイクON）
        pipeline.resumeCapture()

        // 4. 続きの発話（0.60秒）
        let frames2: AVAudioFrameCount = 9600 // 0.60s
        let buf2 = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames2)!
        buf2.frameLength = frames2
        for i in 0..<Int(frames2) {
            buf2.floatChannelData![0][i] = 0.1 * sin(Float(i) * 0.1)
        }
        pipeline.appendAudioBuffer(buf2, isPreRoll: false)

        // 5. フル音声 WAV 書き出しの検証 (0.40s + 0.60s = 1.00s)
        guard let exportedWAV = pipeline.exportFullAudioWAV() else {
            assertionFailure("exportFullAudioWAV() must succeed after resume")
            return
        }
        defer { try? FileManager.default.removeItem(at: exportedWAV) }

        if let audioFile = try? AVAudioFile(forReading: exportedWAV) {
            let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            assert(abs(duration - 1.00) < 0.05, "Exported WAV after resume must contain all segments (expected ~1.00s, got \(duration)s)")
            print("  -> Combined audio duration verified: \(String(format: "%.2f", duration))s")
        } else {
            assertionFailure("Failed to read exported WAV after resume")
        }

        pipeline.cancel()

        // 6. 動的キー表示名（ユーザー設定追従）の検証
        let settings = AppSettings.shared
        settings.hotkeyDisplayString = "⌃Space"
        assert(settings.hotkeyModifiersDisplayString == "⌃", "Modifiers display should be ⌃")
        assert(settings.hotkeyMainKeyDisplayString == "Space", "Main key display should be Space")

        settings.hotkeyDisplayString = "⌘⌥Space"
        assert(settings.hotkeyModifiersDisplayString == "⌘⌥", "Modifiers display should be ⌘⌥")
        assert(settings.hotkeyMainKeyDisplayString == "Space", "Main key display should be Space")

        settings.hotkeyDisplayString = "⌃⇧Q"
        assert(settings.hotkeyModifiersDisplayString == "⌃⇧", "Modifiers display should be ⌃⇧")
        assert(settings.hotkeyMainKeyDisplayString == "Q", "Main key display should be Q")

        print("  -> Push-to-Talk Pause and Resume passed!")
    }
}


