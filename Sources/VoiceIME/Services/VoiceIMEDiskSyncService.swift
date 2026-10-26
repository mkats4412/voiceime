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

    public var dictionaryBackupFileURL: URL {
        baseDirectory.appendingPathComponent("dictionary.json.bak")
    }

    public var vocabularyFileURL: URL {
        baseDirectory.appendingPathComponent("vocabulary.json")
    }

    public var vocabularyBackupFileURL: URL {
        baseDirectory.appendingPathComponent("vocabulary.json.bak")
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

    deinit {
        stopMonitoring()
    }

    /// `~/.voiceime` ディレクトリを確実に作成
    public func ensureDirectoryExists() {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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

    /// 辞書置換ルール（dictionary.json）のみを整形して書き出し
    public func exportDictionaryRulesToDisk(rules: [DictionaryRule]) {
        guard !isSyncingInternal else { return }
        ensureDirectoryExists()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        lastExportTimestamp = Date().timeIntervalSince1970

        if let dictData = try? encoder.encode(rules) {
            lastDictionaryContentHash = dictData.hashValue
            backupFileIfExists(fileURL: dictionaryFileURL, backupURL: dictionaryBackupFileURL)
            try? dictData.write(to: dictionaryFileURL, options: .atomic)
            NSLog("[VoiceIME] 💾 ~/.voiceime/dictionary.json を更新しました (%d ルール)", rules.count)
        }
    }

    /// 単語登録リスト（vocabulary.json）のみを整形して書き出し
    public func exportVocabularyToDisk(vocabulary: [String]) {
        guard !isSyncingInternal else { return }
        ensureDirectoryExists()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        lastExportTimestamp = Date().timeIntervalSince1970

        if let vocabData = try? encoder.encode(vocabulary) {
            lastVocabularyContentHash = vocabData.hashValue
            backupFileIfExists(fileURL: vocabularyFileURL, backupURL: vocabularyBackupFileURL)
            try? vocabData.write(to: vocabularyFileURL, options: .atomic)
            NSLog("[VoiceIME] 💾 ~/.voiceime/vocabulary.json を更新しました (%d 語)", vocabulary.count)
        }
    }

    /// アプリの設定内容を `~/.voiceime/*.json` に整形して書き出し（互換用）
    public func exportToDisk(rules: [DictionaryRule], vocabulary: [String]) {
        exportDictionaryRulesToDisk(rules: rules)
        exportVocabularyToDisk(vocabulary: vocabulary)
    }

    /// 既存ファイルが有効な内容を持つ場合、自動的に `.bak` へ退避
    private func backupFileIfExists(fileURL: URL, backupURL: URL) {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        if let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? UInt64, size > 10 {
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.copyItem(at: fileURL, to: backupURL)
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

        // 1. 辞書ルールの同期
        if let diskRules = importDictionaryFromDisk(), !diskRules.isEmpty {
            let migrated = AppSettings.migrateRules(diskRules)
            settings.dictionaryRules = migrated
            if migrated != diskRules {
                exportDictionaryRulesToDisk(rules: migrated)
            }
            didImport = true
        } else if !fileManager.fileExists(atPath: dictionaryFileURL.path) {
            exportDictionaryRulesToDisk(rules: settings.dictionaryRules)
        }

        // 2. 単語リストの同期（ディスク上の単語を最優先で保護・復元）
        if let diskVocab = importVocabularyFromDisk(), !diskVocab.isEmpty {
            settings.customVocabulary = diskVocab
            didImport = true
        } else if let diskVocab = importVocabularyFromDisk(), diskVocab.isEmpty, !settings.customVocabulary.isEmpty {
            // ディスクが空配列だがUserDefaultsに有効な単語が残っている場合はサルベージして書き出し
            exportVocabularyToDisk(vocabulary: settings.customVocabulary)
        } else if !fileManager.fileExists(atPath: vocabularyFileURL.path) {
            exportVocabularyToDisk(vocabulary: settings.customVocabulary)
        }

        // 3. 推敲プロンプト設定の同期（旧デフォルトプロンプトの場合は語尾保全ルール付き最新プロンプトへ自動アップグレード）
        if var diskPrompts = importPromptsFromDisk() {
            var needsPromptUpgrade = false
            if diskPrompts.casualSystemPrompt == PromptConfig.legacyCasualPrompt || !diskPrompts.casualSystemPrompt.contains("改行（\\n）") {
                diskPrompts.casualSystemPrompt = PromptConfig.defaultCasualPrompt
                needsPromptUpgrade = true
            }
            if diskPrompts.formalSystemPrompt == PromptConfig.legacyFormalPrompt || !diskPrompts.formalSystemPrompt.contains("改行（\\n）") {
                diskPrompts.formalSystemPrompt = PromptConfig.defaultFormalPrompt
                needsPromptUpgrade = true
            }
            if !diskPrompts.userPromptTemplate.contains("改行位置を維持") {
                diskPrompts.userPromptTemplate = PromptConfig.defaultUserPromptTemplate
                needsPromptUpgrade = true
            }
            settings.systemPromptCasual = diskPrompts.casualSystemPrompt
            settings.systemPromptFormal = diskPrompts.formalSystemPrompt
            settings.userPromptTemplate = diskPrompts.userPromptTemplate
            if needsPromptUpgrade {
                let prev = isSyncingInternal
                isSyncingInternal = false
                exportPromptsToDisk(config: diskPrompts)
                isSyncingInternal = prev
            }
            didImport = true
        } else {
            let current = PromptConfig(
                casualSystemPrompt: settings.systemPromptCasual,
                formalSystemPrompt: settings.systemPromptFormal,
                userPromptTemplate: settings.userPromptTemplate
            )
            exportPromptsToDisk(config: current)
        }

        if didImport {
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

        // デバウンス処理（0.1秒待機して書き込み完了を待つ）
        reloadDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard self != nil else { return }

            NSLog("[VoiceIME] 🔄 外部変更を検知したため、~/.voiceime の設定を自動再読み込みします")
            DispatchQueue.main.async {
                AppSettings.shared.reloadFromDisk()
            }
        }

        self.reloadDebounceWorkItem = workItem
        monitorQueue.asyncAfter(deadline: .now() + 0.1, execute: workItem)
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

    public static let legacyCasualPrompt = """
あなたは音声認識テキストの校正・推敲エキスパートです（口語モード）。
話者の語尾・文体・口語ニュアンスを維持しながら、以下の観点で自然で読みやすい文章に修正してください：
・音声入力特有の誤字脱字、聞き間違い、同音異義語の誤変換（漢字の修正）を文脈から見つけ出して正しく修正する。
・音声入力で句読点が抜けて一続きになった文章に対して、文脈や文の切れ目を正しく判断し、自然な位置に句点（。）や読点（、）を適切に補う。

【厳守事項】
1. 発話内容の要約・大幅な削除・文の省略は絶対に禁止です。話された全ての文と話題を最初から最後まで漏れなく含めてください。
2. 修正後の文章のみを必ず <formatted_text> と </formatted_text> タグで囲んで出力してください。前置きや解説は一切不要です。
"""

    public static let legacyFormalPrompt = """
あなたは音声認識テキストの校正・推敲エキスパートです（文章モード）。
ビジネスや記録に適した端正で自然な文章にするため、以下の観点で修正してください：
・音声入力特有の誤字脱字、聞き間違い、同音異義語の誤変換（漢字の修正）を文脈から見つけ出して正しく修正する。
・音声入力で句読点が抜けて一続きになった文章に対して、文脈や文の切れ目を正しく判断し、自然な位置に句点（。）や読点（、）を適切に補う。

【厳守事項】
1. 発話内容の要約・大幅な削除・文の省略は絶対に禁止です。話された全ての文と話題を最初から最後まで漏れなく含めてください。
2. 修正後の文章のみを必ず <formatted_text> と </formatted_text> タグで囲んで出力してください。前置きや解説は一切不要です。
"""

    public static let defaultEnglishPrompt = """
You are an expert speech-to-text proofreader and editor.
Your task is to refine transcribed spoken English into natural, grammatically correct English text while preserving the speaker's exact words, phrasing, and style:
- Correct obvious speech recognition typos, homophone errors, and capitalization.
- Format punctuation naturally: use periods (.), commas (,), question marks (?), and exclamation marks (!). Always use half-width ASCII punctuation marks. Never use full-width punctuation marks (？, ！, 。, 、).
- Follow standard English punctuation spacing: no whitespace before punctuation marks, and exactly one whitespace after punctuation marks (. , ? !) when followed by another word.
- If a sentence is an inquiry or question, end it with a half-width question mark (?).
- If the input text contains newline characters (\\n), preserve all newline breaks exactly as paragraph/sentence delimiters. Do not merge paragraphs into a single line.
- Never summarize, abbreviate, or omit any sentences or thoughts spoken by the user.
- Output only the corrected text wrapped in <formatted_text> and </formatted_text> tags. No explanations or conversational replies.
"""

    public static let defaultCasualPrompt = """
あなたは音声認識テキストの校正・推敲エキスパートです（口語モード）。
話者の語尾・文体・口語ニュアンスを維持しながら、以下の観点で自然で読みやすい文章に修正してください：
・音声入力特有の誤字脱字、聞き間違い、同音異義語の誤変換（漢字の修正）を文脈から見つけ出して正しく修正する。
・音声入力で句読点（句点「。」や読点「、」）が抜けているため、必ず文末には句点（。）を付け、文の息継ぎや節の区切り（〜と、〜ので、〜から、〜だが 等）には読点（、）を積極的に補って読みやすくする。
・入力テキストに改行（\\n）が含まれる場合、段落や文の区切りとして改行を必ずそのまま維持して出力する。勝手に1行に繋げたり改行を削除したりしない。
・同じ言葉や動詞の不自然な重複（例：「表示するすることが」➔「表示することが」）があれば自然な日本語に整える。

【厳守事項】
1. 発話内容の要約・大幅な削除・文の省略は絶対に禁止です。話された全ての文と話題を最初から最後の語尾まで一言も漏らさず含めてください。
2. 日本語では文末・語尾（「〜する」と「〜しない」、「〜である」と「〜ではない」等の肯定・否定や語尾表現）が文全体の意味を決定づけます。文末の肯定・否定や語尾の意味を絶対に反転・省略・改変しないでください。
3. 入力テキストに含まれる改行（\\n）は段落や文の区切りです。絶対に1行に連結・削除せず、改行位置を必ずそのまま維持して出力してください。
4. 修正後の文章のみを必ず <formatted_text> と </formatted_text> タグで囲んで出力してください。前置きや解説は一切不要です。
"""

    public static let defaultFormalPrompt = """
あなたは音声認識テキストの校正・推敲エキスパートです（文章モード）。
ビジネスや記録に適した端正で自然な文章にするため、以下の観点で修正してください：
・音声入力特有の誤字脱字、聞き間違い、同音異義語の誤変換（漢字の修正）を文脈から見つけ出して正しく修正する。
・音声入力で句読点（句点「。」や読点「、」）が抜けているため、必ず文末には句点（。）を付け、文の息継ぎや節の区切り（〜と、〜ので、〜から、〜だが 等）には読点（、）を積極的に補って読みやすくする。
・入力テキストに改行（\\n）が含まれる場合、段落や文の区切りとして改行を必ずそのまま維持して出力する。勝手に1行に繋げたり改行を削除したりしない。
・同じ言葉や動詞の不自然な重複（例：「表示するすることが」➔「表示することが」）があれば自然な日本語に整える。

【厳守事項】
1. 発話内容の要約・大幅な削除・文の省略は絶対に禁止です。話された全ての文と話題を最初から最後の語尾まで一言も漏らさず含めてください。
2. 日本語では文末・語尾（「〜する」と「〜しない」、「〜である」と「〜ではない」等の肯定・否定や語尾表現）が文全体の意味を決定づけます。文末の肯定・否定や語尾の意味を絶対に反転・省略・改変しないでください。
3. 入力テキストに含まれる改行（\\n）は段落や文の区切りです。絶対に1行に連結・削除せず、改行位置を必ずそのまま維持して出力してください。
4. 修正後の文章のみを必ず <formatted_text> と </formatted_text> タグで囲んで出力してください。前置きや解説は一切不要です。
"""

    public static let defaultUserPromptTemplate = """
以下の <input> タグで囲まれた音声テキストを校正し、改行位置を維持したまま、文末には句点「。」、文の切れ目には読点「、」を必ず補って <formatted_text> と </formatted_text> タグで囲んで出力してください。

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
