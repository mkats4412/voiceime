import Foundation

/// 修正モードでのテキスト編集差分情報
public struct TextDiffResult: Equatable {
    public let before: String
    public let after: String

    public init(before: String, after: String) {
        self.before = before
        self.after = after
    }
}

/// 修正履歴レコード（~/.voiceime/corrections.json にストック）
public struct CorrectionRecord: Codable, Identifiable, Equatable {
    public var id: UUID
    public var timestamp: Date
    public var original: String
    public var corrected: String
    public var diffBefore: String
    public var diffAfter: String
    public var isRegisteredToVocabulary: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case original
        case corrected
        case diffBefore = "diff_before"
        case diffAfter = "diff_after"
        case isRegisteredToVocabulary = "is_registered_to_vocabulary"
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        original: String,
        corrected: String,
        diffBefore: String,
        diffAfter: String,
        isRegisteredToVocabulary: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.original = original
        self.corrected = corrected
        self.diffBefore = diffBefore
        self.diffAfter = diffAfter
        self.isRegisteredToVocabulary = isRegisteredToVocabulary
    }
}

/// 修正モードのテキスト差分を監視・単語登録し、~/.voiceime/corrections.json にストック保存するサービス
public final class CorrectionStockService: @unchecked Sendable {
    public static let shared = CorrectionStockService()

    private let queue = DispatchQueue(label: "com.voiceime.correction.stock", qos: .utility)
    private let maxStockCount = 200

    public var correctionsFileURL: URL {
        VoiceIMEDiskSyncService.shared.baseDirectory.appendingPathComponent("corrections.json")
    }

    private init() {}

    /// 修正前テキストと修正後テキストを比較し、変化した単語（差分）を抽出・予測
    public static func detectWordDiff(original: String, corrected: String) -> TextDiffResult? {
        let orig = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let corr = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard orig != corr, !orig.isEmpty, !corr.isEmpty else { return nil }

        let origChars = Array(orig)
        let corrChars = Array(corr)

        // 1. 共通プレフィックスの長さ
        var prefixLen = 0
        while prefixLen < origChars.count && prefixLen < corrChars.count && origChars[prefixLen] == corrChars[prefixLen] {
            prefixLen += 1
        }

        // 2. 共通サフィックスの長さ
        var suffixLen = 0
        while suffixLen < (origChars.count - prefixLen) && suffixLen < (corrChars.count - prefixLen) &&
              origChars[origChars.count - 1 - suffixLen] == corrChars[corrChars.count - 1 - suffixLen] {
            suffixLen += 1
        }

        // 文字種別ヘルパー
        func charCategory(_ ch: Character) -> String {
            guard let scalar = ch.unicodeScalars.first else { return "other" }
            let val = scalar.value
            if (0x4E00...0x9FFF).contains(val) { return "kanji" }
            if (0x30A0...0x30FF).contains(val) || ch == "ー" { return "katakana" }
            if (0x3040...0x309F).contains(val) { return "hiragana" }
            if ("a"..."z").contains(ch) || ("A"..."Z").contains(ch) || ("0"..."9").contains(ch) { return "ascii_alnum" }
            return "other"
        }

        // 3. 差分の先頭トークン境界の拡張（「渋谷公会堂」➔「渋公」の「渋」がプレフィックスに取られるのを防ぐ）
        var startCat = "other"
        if prefixLen < origChars.count {
            let cat = charCategory(origChars[prefixLen])
            if cat == "kanji" || cat == "katakana" || cat == "ascii_alnum" { startCat = cat }
        }
        if startCat == "other" && prefixLen < corrChars.count {
            let cat = charCategory(corrChars[prefixLen])
            if cat == "kanji" || cat == "katakana" || cat == "ascii_alnum" { startCat = cat }
        }
        if startCat == "kanji" || startCat == "katakana" || startCat == "ascii_alnum" {
            while prefixLen > 0 && charCategory(origChars[prefixLen - 1]) == startCat {
                prefixLen -= 1
            }
        }

        // 4. 差分の末尾トークン境界の拡張
        let origEndIdx = origChars.count - 1 - suffixLen
        let corrEndIdx = corrChars.count - 1 - suffixLen
        var endCat = "other"
        if origEndIdx >= 0 {
            let cat = charCategory(origChars[origEndIdx])
            if cat == "kanji" || cat == "katakana" || cat == "ascii_alnum" { endCat = cat }
        }
        if endCat == "other" && corrEndIdx >= 0 {
            let cat = charCategory(corrChars[corrEndIdx])
            if cat == "kanji" || cat == "katakana" || cat == "ascii_alnum" { endCat = cat }
        }
        if endCat == "kanji" || endCat == "katakana" || endCat == "ascii_alnum" {
            while suffixLen > 0 && charCategory(origChars[origChars.count - suffixLen]) == endCat {
                suffixLen -= 1
            }
        }

        let beforeDiff = String(origChars[prefixLen..<(origChars.count - suffixLen)])
        let afterDiff = String(corrChars[prefixLen..<(corrChars.count - suffixLen)])

        // 句読点や空白をトリミングして純粋な単語を抽出
        let punctuationSet = CharacterSet(charactersIn: " 　、。,.!！?？「」『』()（）[]［］{}｛｝\n\t")
        let cleanBefore = beforeDiff.trimmingCharacters(in: punctuationSet)
        let cleanAfter = afterDiff.trimmingCharacters(in: punctuationSet)

        guard !cleanBefore.isEmpty || !cleanAfter.isEmpty else { return nil }
        return TextDiffResult(before: cleanBefore, after: cleanAfter)
    }

    /// 単語を VoiceIME の登録単語（vocabulary.json）に追加
    @MainActor
    public func registerVocabularyWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let settings = AppSettings.shared
        if !settings.customVocabulary.contains(trimmed) {
            settings.addVocabularyWord(trimmed)
            NSLog("[VoiceIME] 📝 '-' キーにより単語登録を実行しました: [%@]", trimmed)
            return true
        } else {
            NSLog("[VoiceIME] ℹ️ すでに登録済みの単語です: [%@]", trimmed)
            return true
        }
    }

    /// 修正履歴をストックに追加（非同期・スレッドセーフ）
    public func recordCorrection(
        original: String,
        corrected: String,
        diffBefore: String,
        diffAfter: String,
        isRegistered: Bool
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }

            var records = self.loadRecordsFromDisk()
            let newRecord = CorrectionRecord(
                original: original,
                corrected: corrected,
                diffBefore: diffBefore,
                diffAfter: diffAfter,
                isRegisteredToVocabulary: isRegistered
            )

            // 重複（同一の元文・修正文が直近にある場合）を避けて先頭に追加
            records.removeAll { $0.original == original && $0.corrected == corrected }
            records.insert(newRecord, at: 0)

            // 最大件数制限（ローテーション）
            if records.count > self.maxStockCount {
                records = Array(records.prefix(self.maxStockCount))
            }

            self.saveRecordsToDisk(records)
            NSLog("[VoiceIME] 📦 修正履歴をストック保存しました: [%@ ➔ %@] (登録済: %d, 総ストック数: %d)",
                  diffBefore, diffAfter, isRegistered ? 1 : 0, records.count)
        }
    }

    /// すでにストックにある直近レコードの登録フラグを更新
    public func markLastRecordAsRegistered(for original: String, corrected: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            var records = self.loadRecordsFromDisk()
            if let idx = records.firstIndex(where: { $0.original == original && $0.corrected == corrected }) {
                records[idx].isRegisteredToVocabulary = true
                self.saveRecordsToDisk(records)
            }
        }
    }

    /// ディスクから修正履歴を読み込む
    public func loadRecordsFromDisk() -> [CorrectionRecord] {
        let url = correctionsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([CorrectionRecord].self, from: data)
        } catch {
            NSLog("[VoiceIME] ⚠️ corrections.json 読み込み失敗: %@", error.localizedDescription)
            return []
        }
    }

    /// ディスクへ修正履歴をアトミック保存
    private func saveRecordsToDisk(_ records: [CorrectionRecord]) {
        let url = correctionsFileURL
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let tempURL = dir.appendingPathComponent("corrections_\(UUID().uuidString).tmp")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: tempURL, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: url)
            }
        } catch {
            NSLog("[VoiceIME] ⚠️ corrections.json 保存失敗: %@", error.localizedDescription)
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    /// 修正履歴ストックを全件クリア
    public func clearStock() {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.removeItem(at: self.correctionsFileURL)
            NSLog("[VoiceIME] 🗑️ 修正履歴ストック (~/.voiceime/corrections.json) をクリアしました")
        }
    }
}
