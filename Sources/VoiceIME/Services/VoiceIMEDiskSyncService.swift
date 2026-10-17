import Foundation
import AppKit

/// `~/.voiceime/` 配下の JSON ファイル（dictionary.json, vocabulary.json）と
/// アプリ内設定（UserDefaults）との双方向同期を司るサービス
public final class VoiceIMEDiskSyncService {
    public static let shared = VoiceIMEDiskSyncService()

    public var baseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".voiceime", isDirectory: true)
    }

    public var dictionaryFileURL: URL {
        baseDirectory.appendingPathComponent("dictionary.json")
    }

    public var vocabularyFileURL: URL {
        baseDirectory.appendingPathComponent("vocabulary.json")
    }

    private let fileManager = FileManager.default
    private var isSyncingInternal = false

    private init() {
        ensureDirectoryExists()
    }

    /// `~/.voiceime` ディレクトリを確実に作成
    public func ensureDirectoryExists() {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true, attributes: nil)
            NSLog("[VoiceIME] 📁 ~/.voiceime ディレクトリを作成しました")
        }
    }

    /// アプリの設定内容を `~/.voiceime/*.json` に整形して書き出し
    public func exportToDisk(rules: [DictionaryRule], vocabulary: [String]) {
        guard !isSyncingInternal else { return }
        ensureDirectoryExists()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        // 1. dictionary.json
        if let dictData = try? encoder.encode(rules) {
            try? dictData.write(to: dictionaryFileURL, options: .atomic)
            NSLog("[VoiceIME] 💾 ~/.voiceime/dictionary.json を更新しました (%d ルール)", rules.count)
        }

        // 2. vocabulary.json
        if let vocabData = try? encoder.encode(vocabulary) {
            try? vocabData.write(to: vocabularyFileURL, options: .atomic)
            NSLog("[VoiceIME] 💾 ~/.voiceime/vocabulary.json を更新しました (%d 語)", vocabulary.count)
        }
    }

    /// `~/.voiceime/dictionary.json` から辞書置換ルールを読み込む
    public func importDictionaryFromDisk() -> [DictionaryRule]? {
        guard fileManager.fileExists(atPath: dictionaryFileURL.path),
              let data = try? Data(contentsOf: dictionaryFileURL) else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            let rules = try decoder.decode([DictionaryRule].self, from: data)
            NSLog("[VoiceIME] 📥 ~/.voiceime/dictionary.json から %d 件のルールを読み込みました", rules.count)
            return rules
        } catch {
            NSLog("[VoiceIME] ⚠️ ~/.voiceime/dictionary.json の読み込みエラー: %@", error.localizedDescription)
            return nil
        }
    }

    /// `~/.voiceime/vocabulary.json` から登録単語リストを読み込む
    public func importVocabularyFromDisk() -> [String]? {
        guard fileManager.fileExists(atPath: vocabularyFileURL.path),
              let data = try? Data(contentsOf: vocabularyFileURL) else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            let words = try decoder.decode([String].self, from: data)
            NSLog("[VoiceIME] 📥 ~/.voiceime/vocabulary.json から %d 件の単語を読み込みました", words.count)
            return words
        } catch {
            NSLog("[VoiceIME] ⚠️ ~/.voiceime/vocabulary.json の読み込みエラー: %@", error.localizedDescription)
            return nil
        }
    }

    /// アプリ起動時の同期
    /// `~/.voiceime/dictionary.json` が存在すれば読み込み、無ければ初期ルールを書き出す
    public func syncOnLaunch(settings: AppSettings) {
        ensureDirectoryExists()

        var didImport = false
        isSyncingInternal = true
        defer { isSyncingInternal = false }

        // 辞書ルールの同期
        if let diskRules = importDictionaryFromDisk(), !diskRules.isEmpty {
            settings.dictionaryRules = diskRules
            didImport = true
        }

        // 単語リストの同期
        if let diskVocab = importVocabularyFromDisk(), !diskVocab.isEmpty {
            settings.customVocabulary = diskVocab
            didImport = true
        }

        // ファイルがまだ無かった場合は、現在の設定（初期ルール等）をJSONとして初回書き出し
        if !fileManager.fileExists(atPath: dictionaryFileURL.path) || !fileManager.fileExists(atPath: vocabularyFileURL.path) {
            isSyncingInternal = false
            exportToDisk(rules: settings.dictionaryRules, vocabulary: settings.customVocabulary)
        } else if didImport {
            NSLog("[VoiceIME] ✅ ~/.voiceime からの初期設定読み込みが完了しました")
        }
    }

    /// Finderで `~/.voiceime` フォルダを開く
    public func openFolderInFinder() {
        ensureDirectoryExists()
        NSWorkspace.shared.open(baseDirectory)
    }
}
