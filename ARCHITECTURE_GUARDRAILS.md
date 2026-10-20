# VoiceIME 開発・リファクタリング安全ガイドライン (Guardrails)

このドキュメントは、コードチェック、静的解析、リファクタリング、機能追加時に **「動作が壊れやすい繊細な macOS システム連携領域」** を保護するための重要注意事項をまとめたものです。
開発者および AI エージェントは、関連箇所のコードを変更する前に **必ず本ドキュメントを確認** してください。

---

## 1. CoreAudio & AVAudioEngine（マイク入力とリアルタイム音声認識）

### 🚨 厳禁事項
1. **`engine.inputNode.auAudioUnit.setDeviceID(...)` を直接呼び出さないこと**
   - CoreAudio の仕様上、`AVAudioEngine` の `inputNode` に対して `setDeviceID` を実行すると、内部の AUHAL 入力チェーン初期化が破壊され、`engine.start()` 時に **`kAudioUnitErr_FormatNotSupported`（エラー `-10868`）** が発生してエンジンが 100% 起動不能になります。
   - 入力デバイスは常にシステムのデフォルト入力として `AVAudioEngine` に自然に任せる必要があります。

2. **`inputNode.installTap` に `format: nil` を渡さないこと**
   - 必ず `let recordingFormat = inputNode.outputFormat(forBus: 0)` を取得し、その `recordingFormat` をタップに指定してください。

3. **`SFSpeechRecognizer` の認可ステータスで過剰なガードを設けないこと**
   - `SFSpeechRecognizer.authorizationStatus() == .authorized` だけでタスク生成を弾いてしまうと、初回権限（`.notDetermined`）の際にタスクが生成されず、画面へのリアルタイム文字起こしが停止します。
   - `guard let recognizer = recognizer, recognizer.isAvailable else { return }` の最小限チェックに留めてください。

4. **macOS 標準の STT（Apple Speech / SFSpeechRecognizer）の出力を画面に出さないこと**
   - 画面に表示するのは **Whisper（StreamingChunkPipelineService）からの高品質な認識結果のみ** です。
   - `LiveSpeechService.startLiveRecognition` の `onUpdate` コールバックは `{ _ in }` とし、Apple STT の不完全な認識結果でフローティングプレビューを上書き・汚染してはいけません。

---

## 2. Push-to-Talk（キー押下中のプレビュー表示とリリース時の入力）

### 🎯 必須要件
- **ユーザー体験の核心**:
  - キー（例: `Ctrl+Space`）を押しながら話している最中（手をキーボードから離す前）に、**Whisper API から逐次返ってくる認識結果** がリアルタイムにフローティング画面へ表示され、**「話した内容を目視確認できる」** こと。
  - 内容を確認した上で手を離すと、Whisper / AI推敲を経た確定テキストが自動ペーストされます。
- **注意点**:
  - キーを押している最中に画面が空のまま放置され、キーを離した瞬間に一瞬だけ文字が出てすぐ消える（ペーストされる）挙動は、ユーザーから「確認できず意味がない」と判定されます。
  - `StreamingChunkPipelineService` からのテキスト更新（`updatePipelineText`）を排他フラグ等でブロックしないようにしてください。

---

## 3. macOS キーチェーン認証と起動時ガイダンス

### 💡 仕組みとルール
1. **アプリ更新・差し替え後の初回起動ガイダンス**:
   - アプリをコンパイルして再配置した際、macOS は署名やバイナリの変更を検知してキーチェーンアクセス時にユーザーパスワードを求めます。
   - このため、アプリ起動時に `promptKeychainWarmupIfNeeded()` を呼び出し、**「VoiceIME: macOS キーチェーン認証のご案内」** ダイアログを最前面に出してユーザーに「了解して認証へ進む」を押させ、起動直後に `keychain.warmUp()` で事前認証を完了させます。
   - これにより、**CTRL+Space（音声入力中）に突然パスワードダイアログが割り込んで音声入力を遮断する事故を 100% 防ぎます**。

2. **MCP モード (`--mcp`) での完全サイレント動作**:
   - `voiceime --mcp` で起動される MCP サーバー時は、GUI（`AppState`）を初期化せず headless 実行し、ダイアログを絶対に表示させないこと。

---

## 4. 変更後の必須検証チェックリスト

コード修正やリファクタリングを行った際は、コミット前に必ず以下の手順で実機確認を行ってください：

- [ ] `./scripts/run_tests.sh` を実行し、全ユニットテストが PASS すること。
- [ ] `./scripts/build_app.sh --install` で `/Applications/VoiceIME.app` にインストールし、アプリを再起動すること。
- [ ] **Push-to-Talk の実動確認**:
  1. 推敲を OFF にする。
  2. `Ctrl+Space` を押しっぱなしにしながら「こんにちは、テストです」と話す。
  3. **手を離す前（キーを押している間）に、話した言葉が画面にリアルタイムで表示されることを目視確認する**。
  4. キーを離して、テキストが正しくペーストされることを確認する。
- [ ] `~/.voiceime/pipeline.log` を確認し、`AVAudioEngine 開始失敗 (-10868)` などのエラーが出ていないこと。
