# AGENTS.md - VoiceIME エージェント作業規範

このファイルは、VoiceIME リポジトリで作業するすべての AI エージェント（Antigravity、Cursor、Claude等）に対する**最優先の行動規範（ルール）**です。

---

## 🚨 最重要ルール：コード修正・チェック前の事前スキル確認と stash 退避

**コードチェック、静的解析、リファクタリング、バグ修正、機能追加を行う前に、必ず事前スキル [voiceime-pre-check](.agents/skills/voiceime-pre-check/SKILL.md) および [continuous-spec-sync](.agents/skills/continuous-spec-sync/SKILL.md)、[ARCHITECTURE_GUARDRAILS.md](ARCHITECTURE_GUARDRAILS.md) を読み込み、禁止事項と仕様同期ルールを確認してください。**

**また、チェックやリファクタリングを始める直前には、作業ツリーに未コミットの変更がある場合、必ず `git stash push -u -m "pre-check-backup-..."` でスタッシュし、チェック前の状態を確実に保持・退避してください。**

---

## 📘 継続的仕様同期ルール（Doc-First Sync）
対話を通じて決まった挙動、制約事項、データ構造の変更は、コードを変更する前に必ず事前スキル [continuous-spec-sync](.agents/skills/continuous-spec-sync/SKILL.md) に従って `doc/SPEC.md`（または `docs/SPEC.md`）へ即座に反映してください。
1. **仕様ドキュメント先行更新**: ユーザー要求や不変制約（Invariant Rules）をコード変更前に `doc/SPEC.md` に追記・更新する。
2. **完了報告への明記**: 完了報告には「`doc/SPEC.md` のどの項目を更新・追記したか」を明記する。
3. **リファクタリング時の検証義務**: 仕様書（`doc/SPEC.md`）を照合し、仕様・制約の逸脱を防止する。

### 厳守すべき 4 大保護領域
1. **CoreAudio / AVAudioEngine**:
   - `engine.inputNode.auAudioUnit.setDeviceID` の呼び出しは絶対禁止（エラー `-10868` でクラッシュします）。
   - `inputNode.installTap` には必ず `inputNode.outputFormat(forBus: 0)` を渡すこと。
2. **Push-to-Talk リアルタイム出力（Whisperストリーミング表示の厳守）**:
   - macOS 標準の STT（Apple Speech / SFSpeechRecognizer）の出力を画面に出すのは厳禁。画面には **Whisper（StreamingChunkPipelineService）からの認識結果のみ** を出力すること。
   - `LiveSpeechService.shared.startLiveRecognition` のコールバックは `{ _ in }` とし、Apple STT でプレビューを上書きしてはいけません。
   - キー（`Ctrl+Space`）を押している最中（手を離す前）に、Whisperから届いた速報（`updatePipelineText`）がリアルタイムにフローティング画面に出力され、**「目視確認できる状態」** を絶対に維持すること。
3. **音声入力しきい値のユーザー設定直結と無音時送信の完全防止**:
   - `StreamingChunkPipelineService` のしきい値に勝手なオフセット（`-4.0dB` や `-34.0dB`）をハードコードしないこと。必ずユーザーが設定画面で調整した `settings.audioThresholdDB` に 1:1 でダイレクトに連動させること。
   - トリガー判定は単なる経過サンプル数（`newAudioDuration`）ではなく、必ず音量しきい値を超えた **有声発話時間（`speechFramesSinceLastTrigger` / `newSpeechDuration`）** を用いること。話していない沈黙中に同じテキストを Whisper API に連続送信（無駄送信ループ）させてはいけません。
4. **キーチェーン認証ガイダンス**:
   - アプリ差し替え後の初回起動時には「VoiceIME: macOS キーチェーン認証のご案内」モーダルを出し、起動時に事前認証（`warmUp`）を完了させること。
   - ただし `--mcp`（MCP サーバー）モードでは GUI を起動せず完全サイレント動作とすること。

---

## 変更後の必須検証
コードを変更した後は、必ず次の手順で検証してください：
1. `./scripts/run_tests.sh`（全テスト通過）
2. `./scripts/build_app.sh --install`（アプリビルドと反映）
3. `killall VoiceIME && sleep 1 && open /Applications/VoiceIME.app`（アプリ再起動）
4. 実機で `Ctrl+Space` を押しながら話し、手を離す前に画面に文字が出ることの目視確認。
