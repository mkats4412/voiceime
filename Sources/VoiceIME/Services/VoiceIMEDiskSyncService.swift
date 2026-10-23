import Foundation
import AppKit

/// `~/.voiceime/` 配下の JSON ファイル（dictionary.json, vocabulary.json）と
/// アプリ内設定（UserDefaults）との双方向同期を司るサービス
public final class VoiceIMEDiskSyncService {
    public static let shared = VoiceIMEDiskSyncService()

    public var customBaseDirectory: URL? = nil

    public var baseDirectory: URL {
        if let custom = customBaseDirectory {
            return custom
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".voiceime", isDirectory: true)
    }

    public var dictionaryFileURL: URL {
        baseDirectory.appendingPathComponent("dictionary.json")
    }

    public var vocabularyFileURL: URL {
        baseDirectory.appendingPathComponent("vocabulary.json")
    }

    public var promptsFileURL: URL {
        baseDirectory.appendingPathComponent("prompts.json")
    }

    private let fileManager = FileManager.default
    private var isSyncingInternal = false

    /// 再読み込み時などに exportToDisk が再発火するのを防ぐスコープ実行
    public func performWithoutExport(_ block: () -> Void) {
        let prev = isSyncingInternal
        isSyncingInternal = true
        defer { isSyncingInternal = prev }
        block()
    }

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

    /// プロセス間通知名（外部CLIやMCPから即時リロードを促す通知）
    public static let reloadNotificationName = Notification.Name("com.voiceime.notification.reloadDictionary")

    private var monitorSource: DispatchSourceFileSystemObject?
    private let monitorQueue = DispatchQueue(label: "com.voiceime.disksync.monitor", qos: .utility)
    private var reloadDebounceWorkItem: DispatchWorkItem?
    private let timestampLock = NSLock()
    private var _lastExportTimestamp: TimeInterval = 0
    private var lastExportTimestamp: TimeInterval {
        get {
            timestampLock.lock()
            defer { timestampLock.unlock() }
            return _lastExportTimestamp
        }
        set {
            timestampLock.lock()
            defer { timestampLock.unlock() }
            _lastExportTimestamp = newValue
        }
    }
    private var lastDictionaryContentHash: Int = 0
    private var lastVocabularyContentHash: Int = 0
    private weak var targetSettings: AppSettings?

    /// アプリの設定内容を `~/.voiceime/*.json` に整形して書き出し
    public func exportToDisk(rules: [DictionaryRule], vocabulary: [String]) {
        guard !isSyncingInternal else { return }
        ensureDirectoryExists()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        lastExportTimestamp = Date().timeIntervalSince1970

        // 1. dictionary.json
        if let dictData = try? encoder.encode(rules) {
            lastDictionaryContentHash = dictData.hashValue
            try? dictData.write(to: dictionaryFileURL, options: .atomic)
            NSLog("[VoiceIME] 💾 ~/.voiceime/dictionary.json を更新しました (%d ルール)", rules.count)
        }

        // 2. vocabulary.json
        if let vocabData = try? encoder.encode(vocabulary) {
            lastVocabularyContentHash = vocabData.hashValue
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

        lastDictionaryContentHash = data.hashValue

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

        lastVocabularyContentHash = data.hashValue

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

    /// `~/.voiceime/prompts.json` にプロンプト設定を書き出し
    public func exportPromptsToDisk(config: PromptConfig) {
        guard !isSyncingInternal else { return }
        ensureDirectoryExists()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        lastExportTimestamp = Date().timeIntervalSince1970

        if let data = try? encoder.encode(config) {
            try? data.write(to: promptsFileURL, options: .atomic)
            NSLog("[VoiceIME] 💾 ~/.voiceime/prompts.json を更新しました")
        }
    }

    /// `~/.voiceime/prompts.json` からプロンプト設定を読み込む
    public func importPromptsFromDisk() -> PromptConfig? {
        guard fileManager.fileExists(atPath: promptsFileURL.path),
              let data = try? Data(contentsOf: promptsFileURL) else {
            return nil
        }
        do {
            let decoder = JSONDecoder()
            let config = try decoder.decode(PromptConfig.self, from: data)
            NSLog("[VoiceIME] 📥 ~/.voiceime/prompts.json を読み込みました")
            return config
        } catch {
            NSLog("[VoiceIME] ⚠️ ~/.voiceime/prompts.json の読み込みエラー: %@", error.localizedDescription)
            return nil
        }
    }

    /// アプリ起動時の同期および常駐ファイル監視の開始
    public func syncOnLaunch(settings: AppSettings) {
        self.targetSettings = settings
        ensureDirectoryExists()

        var didImport = false
        isSyncingInternal = true
        defer {
            isSyncingInternal = false
            startMonitoring(settings: settings)
        }

        // 辞書ルールの同期
        if let diskRules = importDictionaryFromDisk(), !diskRules.isEmpty {
            let migrated = AppSettings.migrateRules(diskRules)
            settings.dictionaryRules = migrated
            if migrated != diskRules {
                exportToDisk(rules: migrated, vocabulary: settings.customVocabulary)
            }
            didImport = true
        }

        // 単語リストの同期
        if let diskVocab = importVocabularyFromDisk(), !diskVocab.isEmpty {
            settings.customVocabulary = diskVocab
            didImport = true
        }

        // 推敲プロンプト設定の同期
        if let diskPrompts = importPromptsFromDisk() {
            settings.systemPromptCasual = diskPrompts.casualSystemPrompt
            settings.systemPromptFormal = diskPrompts.formalSystemPrompt
            settings.userPromptTemplate = diskPrompts.userPromptTemplate
            didImport = true
        } else {
            let current = PromptConfig(
                casualSystemPrompt: settings.systemPromptCasual,
                formalSystemPrompt: settings.systemPromptFormal,
                userPromptTemplate: settings.userPromptTemplate
            )
            exportPromptsToDisk(config: current)
        }

        // ファイルがまだ無かった場合は、現在の設定（初期ルール等）をJSONとして初回書き出し
        if !fileManager.fileExists(atPath: dictionaryFileURL.path) || !fileManager.fileExists(atPath: vocabularyFileURL.path) {
            isSyncingInternal = false
            exportToDisk(rules: settings.dictionaryRules, vocabulary: settings.customVocabulary)
        } else if didImport {
            NSLog("[VoiceIME] ✅ ~/.voiceime からの初期設定読み込みが完了しました")
        }
    }

    /// `~/.voiceime/` フォルダの変更監視を開始（AI Agent や外部スクリプトの変更を自動検知）
    public func startMonitoring(settings: AppSettings) {
        self.targetSettings = settings
        stopMonitoring()

        ensureDirectoryExists()

        // 1. 分散通知（DistributedNotificationCenter）による即時リロード監視
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleDistributedReloadNotification),
            name: Self.reloadNotificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        // 2. ディレクトリ監視 (kqueue / DispatchSource)
        let path = baseDirectory.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("[VoiceIME] ⚠️ ~/.voiceime のファイル監視オープンに失敗しました: errno=%d", errno)
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link, .rename],
            queue: monitorQueue
        )

        source.setEventHandler { [weak self] in
            self?.handleFileSystemEvent()
        }

        // 自身の fd を値キャプチャし、再監視開始時の新旧FD競合（誤クローズ）を完全に防止
        source.setCancelHandler {
            close(fd)
        }

        self.monitorSource = source
        source.resume()
        NSLog("[VoiceIME] 👁️ ~/.voiceime ディレクトリのリアルタイム自動監視を開始しました")
    }

    /// 監視の停止
    public func stopMonitoring() {
        reloadDebounceWorkItem?.cancel()
        reloadDebounceWorkItem = nil
        if let source = monitorSource {
            source.cancel()
            monitorSource = nil
        }
        DistributedNotificationCenter.default().removeObserver(self, name: Self.reloadNotificationName, object: nil)
    }

    @objc private func handleDistributedReloadNotification() {
        NSLog("[VoiceIME] 🔔 外部（MCP / CLI）からのリロード通知を受信しました")
        DispatchQueue.main.async {
            AppSettings.shared.reloadFromDisk()
        }
    }

    private func handleFileSystemEvent() {
        // 自プロセスによる書き出しから0.5秒以内はスキップ
        let now = Date().timeIntervalSince1970
        guard now - lastExportTimestamp > 0.5 else { return }

        // デバウンス処理（0.3秒待機して書き込み完了を待つ）
        reloadDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard self != nil else { return }

            NSLog("[VoiceIME] 🔄 外部変更を検知したため、~/.voiceime の設定を自動再読み込みします")
            DispatchQueue.main.async {
                AppSettings.shared.reloadFromDisk()
            }
        }

        self.reloadDebounceWorkItem = workItem
        monitorQueue.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    /// 外部（MCPやスクリプト）からアプリにリロードを促す通知を送信するヘルパー
    public static func postReloadNotification() {
        DistributedNotificationCenter.default().postNotificationName(
            reloadNotificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Finderで `~/.voiceime` フォルダを開く
    public func openFolderInFinder() {
        ensureDirectoryExists()
        NSWorkspace.shared.open(baseDirectory)
    }
}

/// `~/.voiceime/prompts.json` の構造定義
public struct PromptConfig: Codable, Equatable {
    public var casualSystemPrompt: String
    public var formalSystemPrompt: String
    public var userPromptTemplate: String

    enum CodingKeys: String, CodingKey {
        case casualSystemPrompt = "casual_system_prompt"
        case formalSystemPrompt = "formal_system_prompt"
        case userPromptTemplate = "user_prompt_template"
    }

    public init(casualSystemPrompt: String, formalSystemPrompt: String, userPromptTemplate: String) {
        self.casualSystemPrompt = casualSystemPrompt
        self.formalSystemPrompt = formalSystemPrompt
        self.userPromptTemplate = userPromptTemplate
    }

    public static let defaultCasualPrompt = """
あなたは音声認識テキストの校正・推敲エキスパートです（口語モード）。
話者の語尾・文体・口語ニュアンスを維持しながら、以下の観点で自然で読みやすい文章に修正してください：
・音声入力特有の誤字脱字、聞き間違い、同音異義語の誤変換（漢字の修正）を文脈から見つけ出して正しく修正する。
・音声入力で句読点が抜けて一続きになった文章に対して、文脈や文の切れ目を正しく判断し、自然な位置に句点（。）や読点（、）を適切に補う。

【厳守事項】
1. 発話内容の要約・大幅な削除・文の省略は絶対に禁止です。話された全ての文と話題を最初から最後まで漏れなく含めてください。
2. 修正後の文章のみを必ず <formatted_text> と </formatted_text> タグで囲んで出力してください。前置きや解説は一切不要です。
"""

    public static let defaultFormalPrompt = """
あなたは音声認識テキストの校正・推敲エキスパートです（文章モード）。
ビジネスや記録に適した端正で自然な文章にするため、以下の観点で修正してください：
・音声入力特有の誤字脱字、聞き間違い、同音異義語の誤変換（漢字の修正）を文脈から見つけ出して正しく修正する。
・音声入力で句読点が抜けて一続きになった文章に対して、文脈や文の切れ目を正しく判断し、自然な位置に句点（。）や読点（、）を適切に補う。

【厳守事項】
1. 発話内容の要約・大幅な削除・文の省略は絶対に禁止です。話された全ての文と話題を最初から最後まで漏れなく含めてください。
2. 修正後の文章のみを必ず <formatted_text> と </formatted_text> タグで囲んで出力してください。前置きや解説は一切不要です。
"""

    public static let defaultUserPromptTemplate = """
以下の <input> タグで囲まれた音声テキストを校正し、必ず <formatted_text> と </formatted_text> タグで囲んで出力してください。
※発話内容の要約や削除は禁止します。最初から最後まで全ての文を含めてください。

<input>
{input}
</input>
"""

    public static let `default` = PromptConfig(
        casualSystemPrompt: defaultCasualPrompt,
        formalSystemPrompt: defaultFormalPrompt,
        userPromptTemplate: defaultUserPromptTemplate
    )
}
