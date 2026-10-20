# AGENTS.md - VoiceIME エージェント作業規範

このファイルは、VoiceIME リポジトリで作業するすべての AI エージェント（Antigravity、Cursor、Claude等）に対する**最優先の行動規範（ルール）**です。

---

## 🚨 最重要ルール：コード修正・チェック前の事前スキル確認

**コードチェック、静的解析、リファクタリング、バグ修正、機能追加を行う前に、必ず事前スキル [voiceime-pre-check](.agents/skills/voiceime-pre-check/SKILL.md) または [ARCHITECTURE_GUARDRAILS.md](ARCHITECTURE_GUARDRAILS.md) を読み込み、禁止事項を確認してください。**

### 厳守すべき 3 大保護領域
1. **CoreAudio / AVAudioEngine**:
   - `engine.inputNode.auAudioUnit.setDeviceID` の呼び出しは絶対禁止（エラー `-10868` でクラッシュします）。
   - `inputNode.installTap` には必ず `inputNode.outputFormat(forBus: 0)` を渡すこと。
2. **Push-to-Talk リアルタイム出力**:
   - キー（`Ctrl+Space`）を押している最中（手を離す前）に、話した言葉がリアルタイムにフローティング画面に出力され、**「目視確認できる状態」** を絶対に維持すること。
   - コールバックを空にしたり、排他フラグでプレビュー更新を阻害してはいけません。
3. **キーチェーン認証ガイダンス**:
   - アプリ差し替え後の初回起動時には「VoiceIME: macOS キーチェーン認証のご案内」モーダルを出し、起動時に事前認証（`warmUp`）を完了させること。
   - ただし `--mcp`（MCP サーバー）モードでは GUI を起動せず完全サイレント動作とすること。

---

## 変更後の必須検証
コードを変更した後は、必ず次の手順で検証してください：
1. `./scripts/run_tests.sh`（全テスト通過）
2. `./scripts/build_app.sh --install`（アプリビルドと反映）
3. `killall VoiceIME && sleep 1 && open /Applications/VoiceIME.app`（アプリ再起動）
4. 実機で `Ctrl+Space` を押しながら話し、手を離す前に画面に文字が出ることの目視確認。
