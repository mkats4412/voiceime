---
name: voiceime-pre-check
description: >-
  VoiceIMEのコードチェック、リファクタリング、バグ修正、機能追加を行う直前に必ず読み込み、
  CoreAudioクラッシュ、キーチェーン認証の割り込み、Push-to-Talkリアルタイムプレビューの消失を防ぐための必須事前安全確認スキル。
---

# VoiceIME コードチェック直前の安全確認スキル (Pre-Check Protocol)

VoiceIME のソースコードを変更・リファクタリング・最適化・チェックする前に、**必ずこのスキルを読んで以下の禁止事項・保護領域を遵守してください**。

---

## 🛑 【絶対禁止】コードチェックで壊してはいけない 3 大要件

### 1. CoreAudio / AVAudioEngine（マイク入力とストリーミング）
* **禁止コード**: `engine.inputNode.auAudioUnit.setDeviceID(...)`
  * **理由**: `AVAudioEngine` の `inputNode` に対して `setDeviceID` を直接呼ぶと、AUHAL の入力チェーン初期化状態が破壊され、`engine.start()` 時に **`kAudioUnitErr_FormatNotSupported` (エラー `-10868`)** で 100% クラッシュ・起動失敗します。
  * **ルール**: 入力デバイスは常にシステムのデフォルト入力として `AVAudioEngine` に自然に開かせてください。
* **マイクタップのフォーマット**:
  * `inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat)`
  * `let recordingFormat = inputNode.outputFormat(forBus: 0)` をそのまま渡してください。`format: nil` に変更してはいけません。
* **SFSpeechRecognizer の過剰ガード禁止**:
  * `SFSpeechRecognizer.authorizationStatus() == .authorized` だけでタスク生成をスキップしてはいけません（`.notDetermined` の初動リクエストが死にます）。

### 2. Push-to-Talk リアルタイム表示（UXの絶対防衛線）
* **必須挙動**:
  * ユーザーがキー（例: `Ctrl+Space`）を押しながら話している最中（手を離す前）に、話した言葉がリアルタイムでフローティング画面に随時出力され、**「目視確認できる状態」** でなければなりません。
* **禁止事項**:
  * `LiveSpeechService` の `startLiveRecognition` コールバックを空（`{ _ in }`）にしないこと。必ず `FloatingPreviewController.shared.updateLiveText(text)` へ渡してください。
  * 「キーを離した瞬間に一瞬文字が出てすぐペーストされて消える」状態はデグレ（バグ）です。話している最中に出力されている必要があります。
  * `FloatingPreviewController` のテキスト更新を排他ロック等でブロックしないこと。

### 3. macOS キーチェーン認証と起動時ガイダンス
* **初回起動案内ウィンドウの維持**:
  * アプリ更新・再コンパイル後の初回起動時には、最前面に **「VoiceIME: macOS キーチェーン認証のご案内」** ダイアログを表示し、ユーザーに「了解して認証へ進む」を押させて起動直後に `keychain.warmUp()` で事前認証を完了させてください。
  * これを削除すると、音声入力（CTRL+Space）の瞬間に macOS のシステムパスワードダイアログが突然飛び出してきて音声入力を遮断してしまいます。
* **MCP モード (`--mcp`) の完全サイレント化**:
  * `voiceime --mcp` で起動される MCP サーバー時は、GUI（`AppState`）を初期化せず headless 実行し、ダイアログを絶対に表示させないこと。

---

## 📋 修正前のセルフチェックシート

コードの編集を開始する前に、自身の修正計画をチェックしてください：
- [ ] `LiveSpeechService.swift` 内の `inputNode.installTap` や `AVAudioEngine` を触ろうとしていないか？
- [ ] `engine.inputNode.auAudioUnit.setDeviceID` を呼ぼうとしていないか？
- [ ] リアルタイム音声認識のコールバック（`updateLiveText`）を遮断していないか？
- [ ] キーチェーンの `promptKeychainWarmupIfNeeded()` や `warmUp()` を削除しようとしていないか？

---

## 🧪 修正完了後の必須検証コマンド

コード変更後は、必ず以下の手順を実行してデグレがないことを確認してください：

```bash
# 1. ユニットテストの実行
./scripts/run_tests.sh

# 2. アプリのビルド & インストール
./scripts/build_app.sh --install

# 3. アプリの再起動
killall VoiceIME && sleep 1 && open /Applications/VoiceIME.app

# 4. 実機での確認
# Ctrl+Space を押しながら話し、手を離す前にフローティング画面に文字が出ることを目視確認する。
# ~/.voiceime/pipeline.log を確認し、エラー -10868 が出ていないことを確認する。
```
