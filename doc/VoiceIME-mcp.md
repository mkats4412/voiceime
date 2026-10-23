# VoiceIME MCP (Model Context Protocol) 連携ガイド

> **AIエージェントがWhisperの認識癖を高度な正規表現で自動調教し、TTS音声による無発声テストまで自律完結する自己進化型IME基盤。**  
> 複雑なゆらぎ吸収ルールの生成から、テスト音声の投入・検証・アプリ即時反映、さらには日々の手動修正ストックからの自律学習まで、エージェントとの対話だけでVoiceIMEを育てることができます。

VoiceIME は、**MCP (Model Context Protocol)** を標準サポートしています。  
Claude Desktop、Cursor、Cline、Windsurf、Antigravity などの AI コーディング環境・エージェントから、VoiceIME の辞書設定、単語登録、修正履歴ストック、LLM推敲プロンプト、リアルタイムログ監視、音声文字起こしテストを直接対話・自動操作できます。

---

## 🌟 主な特徴

1. **ゼロ依存 (Zero Dependencies)**:
   - Python 3 標準ライブラリのみで動作。`pip install` などの追加ライブラリ導入は一切不要です。
2. **リアルタイム自動同期**:
   - MCP が `~/.voiceime/` の設定（JSON）を更新すると、VoiceIME アプリがファイル監視（kqueue）によって**再起動なし・ミリ秒単位で即時反映**します。
3. **安全設計（エージェント編集マスタースイッチ & 完全サイレント）**:
   - 設定画面（辞書・置換設定タブ）に **「AI Agent による編集・単語登録を許可 (MCP)」** スイッチを搭載。
   - **デフォルトは OFF（安全ガード）**。スイッチが OFF の間は、MCP 経由での設定変更（単語登録・置換ルール追加・削除等）が自動的にブロックされ、安全な参照（Read-Only）のみに制限されます。
   - バックグラウンド実行時はキーチェーン認証のポップアップ等の画面割り込みを一切行わず、完全サイレントで動作します。
4. **手動修正ストックからの自己進化（NEW）**:
   - ユーザーが修正モード（`+`キー）で手動編集した文章は、`~/.voiceime/corrections.json` に自動ストックされます。
   - AI エージェントはこのストックを読み込み、ユーザーの修正傾向や誤変換パターンを分析して、最適な単語登録や正規表現置換ルールを提案・自律登録できます。
5. **音声テスト & ログ追跡**:
   - 録音した音声ファイル（wav, m4a, mp3等）を直接 MCP 経由で VoiceIME のパイプラインに投入し、文字起こし・辞書置換・推敲の結果を検証できます。

---

## 📁 データ配置 (`~/.voiceime/`)

VoiceIME および MCP サーバーは、ホームディレクトリ配下の `~/.voiceime/` で設定を一元管理します：

| ファイル名 | 用途 | 説明 |
|---|---|---|
| `dictionary.json` | 辞書置換ルール | 括弧、記号、略称、正規表現置換ルール |
| `vocabulary.json` | 登録単語リスト | 人名、社名、専門用語（Whisper/LLMの初期プロンプトに注入） |
| `corrections.json` | 修正履歴ストック | ユーザーが修正モードで手動編集した文章・差分のストック |
| `prompts.json` | 推敲プロンプト | 口語モード・文章モードのシステムプロンプトおよびユーザー入力テンプレート |
| `pipeline.log` | パイプラインログ | Whisper音声認識 → 辞書置換 → LLM推敲 → 手動修正の実行履歴・経過時間ログ |
| `api_keys.json` | APIキー連携 | MCP用フォールバックAPIキー（Groq / OpenAI） |

---

## 🛠️ MCP ツール一覧（全20ツール）

AI エージェントから以下の 20 個のツールを利用できます。

### 1. 単語登録（固有名詞・専門用語）管理
- **`list_vocabulary`**: 登録されている単語一覧を取得。
- **`add_vocabulary`**: 単語（人名、専門用語、社名など）を新規登録。Whisper の `prompt` および LLM 推敲ヒントへ自動注入されます。
- **`remove_vocabulary`**: 登録単語を削除。

### 2. テキスト置換（辞書）ルール管理
- **`list_dictionary_rules`**: テキスト自動置換ルール一覧を取得。
- **`add_dictionary_rule`**: 置換ルール（通常文字列 / 正規表現）を追加・更新。
- **`remove_dictionary_rule`**: 置換ルールを削除。
- **`update_dictionary_rule`**: 既存の置換ルール（パターン、置換後文字列、有効/無効、正規表現フラグ）を更新。

### 3. 修正履歴ストック（自己進化・学習）管理 🌟NEW
- **`get_correction_history`**: ユーザーが修正モードで手動編集した文章の履歴・差分ストック（`corrections.json`）を取得。未登録分のみの絞り込み（`unregistered_only: true`）や件数制限が可能。
- **`register_correction_to_vocabulary`**: ストックされた修正履歴から、指定した修正後単語を単語辞書（`vocabulary.json`）へ登録し、ストックの登録済みフラグを更新。
- **`register_correction_to_dictionary`**: 修正前後の差分からテキスト自動置換ルール（`dictionary.json`）を生成・登録。
- **`clear_correction_history`**: 修正履歴ストック（`corrections.json`）をクリア。

### 4. LLM推敲プロンプト管理
- **`get_llm_prompts`**: 現在の推敲プロンプト（口語プロンプト、文章プロンプト、入力テンプレート）を取得。
- **`set_llm_prompts`**: プロンプトを更新・カスタマイズ。
- **`reset_llm_prompts`**: 推敲プロンプトを公式推奨の初期設定にリセット。

### 5. 音声投入 & 文字起こしテスト
- **`transcribe_audio`**:
  - 音声ファイル（wav, m4a, mp3, ogg, flac等）のパスを指定して、VoiceIME のパイプライン（Whisper API → 辞書置換 → LLM推敲）を直接テスト実行。
  - 各ステージごとの変換結果、処理時間、差分を出力します。

### 6. リアルタイム・パイプラインログ管理
- **`get_pipeline_logging`**: パイプラインログ（`pipeline.log`）の記録状態（ON/OFF、ファイルサイズ、最新更新日時）を取得。
- **`set_pipeline_logging`**: ログ記録の有効化（`enabled: true`）または無効化（`false`）。
- **`get_latest_pipeline_log`**: 最新の実行ログ（末尾N行）を取得し、認識精度や推敲、手動修正の出力を即座に確認。
- **`clear_pipeline_log`**: ログファイルをクリア。

### 7. アプリケーション同期
- **`reload_voiceime`**: VoiceIME アプリへ設定の即時再読み込みを明示通知。

---

## 🔒 セキュリティとエージェント編集許可スイッチ

VoiceIME の設定画面 ➔ **「辞書・置換設定」** タブには、以下の保護スイッチが用意されています：

> **「AI Agent による編集・単語登録を許可 (MCP)」**（デフォルト: OFF）

- **OFF の場合**:
  - AI エージェントは設定や修正履歴の「参照・分析（Read-Only）」のみ可能となります。
  - 単語登録や辞書ルールの追加・更新・削除ツールを呼び出すと、安全ガードによりエラーメッセージが返され、ユーザーが意図しない設定変更を 100% 防止します。
- **ON の場合**:
  - AI エージェントに書き込み権限が付与され、対話を通じて単語登録や置換ルールの追加・修正履歴の登録を自律的に行えるようになります。

---

## ⚙️ クライアント設定方法

### 1. Claude Desktop
`~/Library/Application Support/Claude/claude_desktop_config.json` に以下を追記します：

```json
{
  "mcpServers": {
    "voiceime": {
      "command": "python3",
      "args": [
        "/Applications/VoiceIME.app/Contents/Resources/voiceime_mcp_server.py"
      ]
    }
  }
}
```
※ 開発環境で直接スクリプトを参照する場合は、リポジトリ内のパス（例: `/path/to/voiceime/scripts/voiceime_mcp_server.py`）を指定しても動作します。

### 2. Cursor (`.cursor/mcp.json`)
プロジェクトルートの `.cursor/mcp.json`、またはユーザーグローバル設定に追加します：

```json
{
  "mcpServers": {
    "voiceime": {
      "command": "python3",
      "args": [
        "/Applications/VoiceIME.app/Contents/Resources/voiceime_mcp_server.py"
      ]
    }
  }
}
```

### 3. Cline / Windsurf
MCP 設定画面（Settings → MCP Servers）から以下の通り追加します：
- **Name**: `voiceime`
- **Command**: `python3`
- **Args**: `/Applications/VoiceIME.app/Contents/Resources/voiceime_mcp_server.py`

---

## 💬 エージェントとの対話ユースケース例

- **修正履歴からの自己学習（NEW）**:
  > 「VoiceIME で最近手動修正した文章のストック（`get_correction_history`）を確認して。よく誤変換されている単語や言い回しを分析して、単語登録するか置換ルールを作成して提案して」
- **単語登録の依頼**:
  > 「今日のミーティングで出てきた『Kubernetes』と『マイクロサービスアーキテクチャ』を VoiceIME の単語辞書に登録しておいて」
- **置換ルールの追加**:
  > 「『かっこ閉じる』と言ったときに『)』が出るように辞書ルールを追加して」
- **音声認識精度のテスト**:
  > 「この `./test_audio.wav` を VoiceIME で文字起こししてみて。辞書置換と推敲がどう効いたか確認したい」
- **ログの調査**:
  > 「さっき音声入力したときのパイプラインログを見せて。LLM推敲でどれくらい時間がかかった？ 手動修正はあった？」
