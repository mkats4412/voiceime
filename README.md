# VoiceIME (macOS 音声入力・自動ペースト アプリケーション)

Mac 上で動作し、ユーザーの音声を録音・文字起こしして、現在フォーカスされている任意のアプリケーションの入力フィールドへ自動的にテキストを入力する常駐型ツールです。

---

### 開発背景とメリット

既存ツールの重さ・コスト・精度課題を解消した、超軽量で安全なmacOS専用音声入力ツールです。

* **⚡️ Whisper＋LLM 2段階推敲**
* **🔄 Groq/OpenAI 相互バックアップ**
* **💰 無料枠で実質0円**
* **🪶 ネイティブ製で超軽量**
* **🔒 KeychainでAPIキー保護**
* **🛡️ 120秒自動停止等のフェイルセーフ**

---

### 前提条件 (Prerequisites)

| 項目 | 内容 |
|------|------|
| **OS** | macOS 13以降 |
| **アーキテクチャ** | Apple Silicon推奨（Intelはビルド時 `-target` 変更） |
| **Xcode** | Swift 6.3以上（`xcode-select --install`） |
| **ネットワーク** | Groq/OpenAI APIのため常時接続 |
| **APIキー** | Groq または OpenAI のいずれか1つ |
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
3. **APIキーの設定（「API連携」タブ）**:
   * Groq/OpenAI のAPIキーを入力し「保存」（Keychainに暗号化保存）。
   * ⚠️ **重要**: 初回アクセス時に macOS のキーチェーン確認ダイアログ（「VoiceIME がキーチェーンにアクセスしようとしています」）が表示されたら、**必ず「常に許可（Always Allow）」** をクリックしてください。「許可」だと音声入力やアプリ再起動のたびに毎回パスワード入力を求められてしまいます。CLIなら `security add-generic-password -a "voiceime_groq_api_key" -s "com.voiceime.mac.apikey" -w "gsk_..." -U`

#### 3. 音声入力の実行手順
1. 任意のテキスト入力欄にカーソルを合わせます。
2. `Ctrl + Space`（初期値）を押しながら話します（トグルモードの場合は1回押して話す）。
3. 話し終わったらキーを離します。
4. Whisper による文字起こし ➔ LLM による自然な日本語推敲が一瞬で行われ、カーソル位置へ自動挿入されます。
5. ペースト後、直前のクリップボード内容が自動復元され、クリップボード履歴アプリ（Alfred, Raycast等）には一切残りません。

---

### ビルドとテストの実行

#### アプリケーションのビルド
```bash
cd voiceime
./scripts/build_app.sh          # 初回のみ ./scripts/create_certificate.sh で権限固定可
open ./build/VoiceIME.app       # /Applications へは --install 付与
```
* Intel Macは `scripts/build_app.sh:26` の `-target` を `x86_64` に変更。

#### 単体テストの実行
```bash
cd voiceime
swiftc Sources/VoiceIME/Models/*.swift \
       Sources/VoiceIME/Services/*.swift \
       Tests/VoiceIMETests/TestRunner.swift \
       -o /tmp/test_runner && /tmp/test_runner
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
