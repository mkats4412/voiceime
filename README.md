# VoiceIME (macOS 音声入力・自動ペースト アプリケーション)

Mac 上で動作し、ユーザーの音声を録音・文字起こしして、現在フォーカスされている任意のアプリケーションの入力フィールドへ自動的にテキストを入力する常駐型ツールです。

---

### 開発背景とメリット

既存ツールの重さ・コスト・精度課題を解消した、超軽量で安全なmacOS専用音声入力ツールです。

* **⚡️ Whisper＋LLM 2段階推敲**（Groq / OpenAI / Sarashina・Ollama等のカスタムLLM対応）
* **💬 AI会話（クイック質問）**（スペルや計算を極小の答えのみで即座に回答）
* **👀 リアルタイム・プレビュー画面**（発話内容を小さな画面でその場ですぐ確認）
* **🗣️ 記号の音声入力**（「ひらきまるかっこ」「まるかっことじ」等で各種括弧・クォートを入力）
* **📁 辞書・単語のJSON連携**（`~/.voiceime/` 配下に自動同期。AI Agentやスクリプトから直接編集可能）
* **MCP対応。** Claude DesktopやCursor等のAI Agentから単語・辞書ルールを直接操作可能
* **🔄 Groq/OpenAI 相互バックアップ**（応答遅延時の自動ヘッジドリクエスト）
* **🪶 ネイティブ製で超軽量**（常駐メモリ数十MB・低CPU負荷）
* **🔒 KeychainでAPIキー保護**
* **🛡️ 任意キーでのペースト挿入・45秒限定クリップボード保護**

---

### 前提条件 (Prerequisites)

| 項目 | 内容 |
|------|------|
| **OS** | macOS 13以降 |
| **アーキテクチャ** | Apple Silicon（M1〜M4）/ Intel Mac（自動判定） |
| **Xcode** | Swift 6.3以上（`xcode-select --install`） |
| **ネットワーク** | Groq/OpenAI APIのため常時接続 |
| **APIキー** | Groq または OpenAI（カスタムLLM/Ollama等の利用時は不要・任意） |
| **権限** | マイク / アクセシビリティ / Keychain（標準） |

### なぜビルドが必要か

1. **Appはリポジトリに含めていない**（`.gitignore` で除外）ため `git clone` 直後は存在しません。
2. **Gatekeeper/arch対応**: 配布zipはquarantine付与でブロックされるため、各自で `swiftc` → `codesign` すれば回避できます。Intel Macも再ビルドで対応。

### 起動と使い方

#### 1. アプリの起動
```bash
open ./build/VoiceIME.app
```
メニューバーにマイクアイコンが表示されます。「開発元未確認」なら右クリック→「開く」で許可。

#### 2. 初回設定
1. **設定ウィンドウを開く**:
   * メニューバーのマイクアイコンをクリックし、「設定...」を開きます。
2. **アクセス権限の許可（「アクセス権限」タブ）**:
   * **マイク**: 「許可をリクエスト」をクリックしてマイクへのアクセスを許可します。
   * **アクセシビリティ**: 「許可をリクエスト」をクリックしてシステム設定を開き、VoiceIME を許可します（アクティブな入力欄へ自動で `Cmd + V` ペーストを行うために必要です）。
3. **APIキーの設定（「API設定」タブ）**:
   * Groq/OpenAI のAPIキーを入力し「保存」（Keychainに暗号化保存）。カスタムURL（Sarashina、Ollama、LM Studio等）も設定可能です。
   * ⚠️ **重要**: 初回アクセス時に macOS のキーチェーン確認ダイアログ（「VoiceIME がキーチェーンにアクセスしようとしています」）が表示されたら、**必ず「常に許可（Always Allow）」** をクリックしてください。「許可」だと音声入力やアプリ再起動のたびに毎回パスワード入力を求められてしまいます。CLIなら `security add-generic-password -a "voiceime_groq_api_key" -s "com.voiceime.mac.apikey" -w "gsk_..." -U`

#### 3. 音声入力の手順
* `Ctrl + Space` を押しながら話すと小さな画面でリアルタイム確認でき、離すと自動挿入されます（`⌘ + Enter` での手動挿入にも対応）。

#### 4. AI会話（クイック質問）
* `Ctrl + Shift + Space` を押しながら話すと、単語スペルや計算等の答えだけを小さな画面に極小表示します（`⌘ + Enter` で挿入 / `Esc` で消去）。

#### 5. AI Agent / MCP 連携 (Model Context Protocol)
VoiceIME は単語登録や置換ルールを AI Agent から直接操作できる **MCP サーバー**（`~/.voiceime/mcp_server.py`）を標準搭載しています。外部からの変更はファイル監視により**アプリ再起動不要で即座に自動反映**されます。

* **Claude Desktop / Cursor 設定例 (`claude_desktop_config.json` 等)**:
```json
{
  "mcpServers": {
    "voiceime": {
      "command": "/Applications/VoiceIME.app/Contents/MacOS/VoiceIME",
      "args": ["--mcp"]
    }
  }
}
```
※ `python3 ~/.voiceime/mcp_server.py` の直接指定でも同様に動作します。どちらもパスワード入力不要で即座に応答します。
* **主なツール**:
  * `list_vocabulary` / `add_vocabulary` / `remove_vocabulary`: 単語登録の取得・追加・削除
  * `list_dictionary_rules` / `add_dictionary_rule` / `remove_dictionary_rule` / `update_dictionary_rule`: 置換ルールの取得・追加・削除・更新
  * `reload_voiceime`: 設定の即時再同期通知

---

### ビルドとテストの実行

#### アプリケーションのビルド
```bash
cd voiceime
./scripts/build_app.sh          # 初回のみ ./scripts/create_certificate.sh で権限固定可
open ./build/VoiceIME.app       # /Applications へは --install 付与
```
* Apple Silicon（M1〜M4）および Intel Mac の両方に自動対応（実行環境のCPUアーキテクチャを自動検出してネイティブコンパイルします）。

#### 単体テストの実行
```bash
cd voiceime
./scripts/run_tests.sh
```

---

### よくある質問・トラブル対処

| 症状 | 対処 |
|------|------|
| ホットキーが効かない | システム設定→プライバシー→アクセシビリティで VoiceIME を許可 |
| マイクが認識されない | システム設定→プライバシー→マイクで許可、再起動 |
| `APIキー未登録` エラー | API連携タブで再保存。`security find-generic-password -s com.voiceime.mac.apikey -w` で確認 |
| キーチェーンのパスワードを毎回求められる | ダイアログで「常に許可」を選択してください。再ビルド時に毎回聞かれる場合は `./scripts/create_certificate.sh` を実行して固定署名証明書を作成してください |
| 「開発元未確認」 | 右クリック→開く、または `xattr -cr build/VoiceIME.app`、各自で再ビルド |

### アンインストール

```bash
rm -rf ./build/VoiceIME.app /Applications/VoiceIME.app
security delete-generic-password -a "voiceime_groq_api_key" -s "com.voiceime.mac.apikey" 2>/dev/null; security delete-generic-password -a "voiceime_openai_api_key" -s "com.voiceime.mac.apikey" 2>/dev/null
# システム設定→一般→ログイン項目 から VoiceIME を削除
```

### アップデート

```bash
git pull
./scripts/build_app.sh --install
```

---

### 免責事項

本ソフトウェアの利用（または利用不能）により生じたいかなる損害（データの損失、業務の中断、外部API利用料金の発生、その他の直接的・間接的・派生的損害を含む）について、作者および関係者は一切の責任を負いません。本ソフトウェアは「現状有姿（AS IS）」で提供されており、明示または黙示を問わず、いかなる保証もいたしません。すべて利用者ご自身の自己責任においてご使用ください。
また、外部APIサービス（OpenAI, Groq等）の利用規約やセキュリティポリシー、利用料の管理についても利用者が確認・管理するものとします。

---

### ライセンス

本ソフトウェアは [MIT License](LICENSE) の下で公開されています。詳細は [`LICENSE`](LICENSE) ファイルをご確認ください。
