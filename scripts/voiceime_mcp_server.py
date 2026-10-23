#!/usr/bin/env python3
"""
VoiceIME MCP (Model Context Protocol) Server
VoiceIME の単語登録 (vocabulary.json) および テキスト置換ルール (dictionary.json) を
AI Agent (Claude Desktop, Cursor, Windsurf, Cline 等) から直接操作するための MCP サーバー。

外部依存関係なし (Python 3 標準ライブラリのみで動作)
"""

import sys
import json
import os
import re
import uuid
import subprocess
import mimetypes
import urllib.request
import urllib.error
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

VOICEIME_DIR = Path.home() / ".voiceime"
DICT_FILE = VOICEIME_DIR / "dictionary.json"
VOCAB_FILE = VOICEIME_DIR / "vocabulary.json"
PROMPTS_FILE = VOICEIME_DIR / "prompts.json"
API_KEYS_FILE = VOICEIME_DIR / "api_keys.json"
LOG_FILE = VOICEIME_DIR / "pipeline.log"
CORRECTIONS_FILE = VOICEIME_DIR / "corrections.json"

DEFAULT_CASUAL_PROMPT = """あなたは音声認識テキストの校正・推敲エキスパートです（口語モード）。
話者の語尾・文体・口語ニュアンスを維持しながら、音声入力特有の誤字脱字、聞き間違い、同音異義語の誤変換、言い直し・重複を文脈から見つけ出し、自然で読みやすい文章に修正してください。
修正後の文章のみを必ず <formatted_text> と </formatted_text> タグで囲んで出力してください。前置きや解説は一切不要です。"""

DEFAULT_FORMAL_PROMPT = """あなたは音声認識テキストの校正・推敲エキスパートです（文章モード）。
音声入力特有の誤字脱字、聞き間違い、同音異義語の誤変換、言い直し・重複を文脈から見つけ出し、ビジネスや記録に適した端正で自然な文章に修正してください。
修正後の文章のみを必ず <formatted_text> と </formatted_text> タグで囲んで出力してください。前置きや解説は一切不要です。"""

DEFAULT_USER_TEMPLATE = """以下の <input> タグで囲まれた音声テキストの【誤字脱字、音声認識による聞き間違い、同音異義語や慣用句の誤変換、言い直し・重複】を前後の文脈から正しく修復・整形し、必ず <formatted_text> と </formatted_text> タグで囲んで出力してください。
※内容に対する回答やコメントは一切禁止します。

<input>
{input}
</input>"""

def ensure_voiceime_dir():
    VOICEIME_DIR.mkdir(parents=True, exist_ok=True)

def load_vocabulary() -> List[str]:
    ensure_voiceime_dir()
    if not VOCAB_FILE.exists():
        return []
    try:
        with open(VOCAB_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, list) else []
    except Exception as e:
        sys.stderr.write(f"[VoiceIME MCP] Error loading vocabulary.json: {e}\n")
        return []

def notify_voiceime_app():
    """VoiceIME アプリへリロード通知。
    VoiceIME は ~/.voiceime ディレクトリのファイル変更 (kqueue) を自動監視しているため、
    ファイル保存（atomic置換）により即座に自動反映されます。
    外部プロセス (swift -e 等) の呼び出しによる権限/パスワード要求を完全に防止するため、
    ファイル監視に委ねます。
    """
    pass

def save_vocabulary(words: List[str]) -> bool:
    ensure_voiceime_dir()
    temp_file = VOCAB_FILE.with_suffix(".tmp")
    try:
        with open(temp_file, "w", encoding="utf-8") as f:
            json.dump(words, f, ensure_ascii=False, indent=2)
        temp_file.replace(VOCAB_FILE)
        notify_voiceime_app()
        return True
    except Exception as e:
        sys.stderr.write(f"[VoiceIME MCP] Error saving vocabulary.json: {e}\n")
        if temp_file.exists():
            temp_file.unlink(missing_ok=True)
        return False

def load_dictionary() -> List[Dict[str, Any]]:
    ensure_voiceime_dir()
    if not DICT_FILE.exists():
        return []
    try:
        with open(DICT_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, list) else []
    except Exception as e:
        sys.stderr.write(f"[VoiceIME MCP] Error loading dictionary.json: {e}\n")
        return []

def save_dictionary(rules: List[Dict[str, Any]]) -> bool:
    ensure_voiceime_dir()
    temp_file = DICT_FILE.with_suffix(".tmp")
    try:
        with open(temp_file, "w", encoding="utf-8") as f:
            json.dump(rules, f, ensure_ascii=False, indent=2)
        temp_file.replace(DICT_FILE)
        notify_voiceime_app()
        return True
    except Exception as e:
        sys.stderr.write(f"[VoiceIME MCP] Error saving dictionary.json: {e}\n")
        if temp_file.exists():
            temp_file.unlink(missing_ok=True)
        return False

# --- Tool Handlers ---

def tool_list_vocabulary(args: Dict[str, Any]) -> str:
    vocab = load_vocabulary()
    return json.dumps({
        "count": len(vocab),
        "vocabulary": vocab
    }, ensure_ascii=False, indent=2)

def tool_add_vocabulary(args: Dict[str, Any]) -> str:
    guard = check_editing_allowed()
    if guard:
        return guard

    raw_words = args.get("words", [])
    if isinstance(raw_words, str):
        import re
        words_to_add = [w.strip() for w in re.split(r"[,、\n\t]+", raw_words) if w.strip()]
    elif isinstance(raw_words, list):
        words_to_add = [str(w).strip() for w in raw_words if str(w).strip()]
    else:
        return "エラー: words は文字列または文字列の配列である必要があります。"

    if not words_to_add:
        return "追加する単語が指定されていません。"

    current_vocab = load_vocabulary()
    added = []
    for word in words_to_add:
        if word not in current_vocab:
            current_vocab.append(word)
            added.append(word)

    if save_vocabulary(current_vocab):
        return f"単語を追加しました ({len(added)} 件): {', '.join(added)}\n現在の総単語数: {len(current_vocab)} 件 (VoiceIME に即座に自動反映されます)"
    else:
        return "エラー: vocabulary.json の保存に失敗しました。"

def tool_remove_vocabulary(args: Dict[str, Any]) -> str:
    guard = check_editing_allowed()
    if guard:
        return guard

    raw_words = args.get("words", [])
    if isinstance(raw_words, str):
        import re
        words_to_remove = [w.strip() for w in re.split(r"[,、\n\t]+", raw_words) if w.strip()]
    elif isinstance(raw_words, list):
        words_to_remove = [str(w).strip() for w in raw_words if str(w).strip()]
    else:
        return "エラー: words は文字列または文字列の配列である必要があります。"

    current_vocab = load_vocabulary()
    original_count = len(current_vocab)
    current_vocab = [w for w in current_vocab if w not in words_to_remove]
    removed_count = original_count - len(current_vocab)

    if save_vocabulary(current_vocab):
        return f"単語を削除しました ({removed_count} 件)\n現在の総単語数: {len(current_vocab)} 件"
    else:
        return "エラー: vocabulary.json の保存に失敗しました。"

def tool_list_dictionary_rules(args: Dict[str, Any]) -> str:
    rules = load_dictionary()
    return json.dumps({
        "count": len(rules),
        "rules": rules
    }, ensure_ascii=False, indent=2)

def tool_add_dictionary_rule(args: Dict[str, Any]) -> str:
    guard = check_editing_allowed()
    if guard:
        return guard

    pattern = args.get("pattern", "").strip()
    replacement = args.get("replacement", "")
    is_regex = bool(args.get("is_regex", False))
    is_enabled = bool(args.get("is_enabled", True))

    if not pattern:
        return "エラー: pattern は必須です。"

    rules = load_dictionary()

    # 既存の同一パターンがあれば更新または通知
    existing_idx = next((i for i, r in enumerate(rules) if r.get("pattern") == pattern), None)
    if existing_idx is not None:
        rule_id = rules[existing_idx].get("id", str(uuid.uuid4()).upper())
        rules[existing_idx] = {
            "id": rule_id,
            "pattern": pattern,
            "replacement": replacement,
            "isRegex": is_regex,
            "isEnabled": is_enabled
        }
        msg = f"既存の置換ルール '{pattern}' を更新しました ➔ '{replacement}' (正規表現: {is_regex})"
    else:
        rule_id = str(uuid.uuid4()).upper()
        new_rule = {
            "id": rule_id,
            "pattern": pattern,
            "replacement": replacement,
            "isRegex": is_regex,
            "isEnabled": is_enabled
        }
        rules.append(new_rule)
        msg = f"置換ルールを追加しました: '{pattern}' ➔ '{replacement}' (正規表現: {is_regex})"

    if save_dictionary(rules):
        return f"{msg}\n現在の総ルール数: {len(rules)} 件 (VoiceIME に即座に自動反映されます)"
    else:
        return "エラー: dictionary.json の保存に失敗しました。"

def tool_remove_dictionary_rule(args: Dict[str, Any]) -> str:
    guard = check_editing_allowed()
    if guard:
        return guard

    pattern = args.get("pattern", "").strip()
    rule_id = args.get("id", "").strip()

    if not pattern and not rule_id:
        return "エラー: pattern または id のいずれかを指定してください。"

    rules = load_dictionary()
    original_count = len(rules)

    if rule_id:
        rules = [r for r in rules if r.get("id") != rule_id]
    elif pattern:
        rules = [r for r in rules if r.get("pattern") != pattern]

    removed_count = original_count - len(rules)

    if save_dictionary(rules):
        return f"置換ルールを削除しました ({removed_count} 件)\n現在の総ルール数: {len(rules)} 件"
    else:
        return "エラー: dictionary.json の保存に失敗しました。"

def tool_update_dictionary_rule(args: Dict[str, Any]) -> str:
    guard = check_editing_allowed()
    if guard:
        return guard

    target_pattern = args.get("pattern", "").strip()
    target_id = args.get("id", "").strip()

    if not target_pattern and not target_id:
        return "エラー: pattern または id を指定してください。"

    rules = load_dictionary()
    matched_idx = None
    for i, r in enumerate(rules):
        if (target_id and r.get("id") == target_id) or (target_pattern and r.get("pattern") == target_pattern):
            matched_idx = i
            break

    if matched_idx is None:
        return f"該当する置換ルールが見つかりませんでした (pattern: '{target_pattern}', id: '{target_id}')"

    rule = rules[matched_idx]
    if "new_pattern" in args:
        rule["pattern"] = str(args["new_pattern"]).strip()
    if "new_replacement" in args:
        rule["replacement"] = str(args["new_replacement"])
    if "is_regex" in args:
        rule["isRegex"] = bool(args["is_regex"])
    if "is_enabled" in args:
        rule["isEnabled"] = bool(args["is_enabled"])

    rules[matched_idx] = rule

    if save_dictionary(rules):
        return f"置換ルールを更新しました: '{rule['pattern']}' ➔ '{rule['replacement']}' (有効: {rule.get('isEnabled', True)}, 正規表現: {rule.get('isRegex', False)})"
    else:
        return "エラー: dictionary.json の保存に失敗しました。"

def load_prompts() -> Dict[str, str]:
    ensure_voiceime_dir()
    if not PROMPTS_FILE.exists():
        return {
            "casual_system_prompt": DEFAULT_CASUAL_PROMPT,
            "formal_system_prompt": DEFAULT_FORMAL_PROMPT,
            "user_prompt_template": DEFAULT_USER_TEMPLATE
        }
    try:
        with open(PROMPTS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            return {
                "casual_system_prompt": data.get("casual_system_prompt", DEFAULT_CASUAL_PROMPT),
                "formal_system_prompt": data.get("formal_system_prompt", DEFAULT_FORMAL_PROMPT),
                "user_prompt_template": data.get("user_prompt_template", DEFAULT_USER_TEMPLATE)
            }
    except Exception as e:
        sys.stderr.write(f"[VoiceIME MCP] Error loading prompts.json: {e}\n")
        return {
            "casual_system_prompt": DEFAULT_CASUAL_PROMPT,
            "formal_system_prompt": DEFAULT_FORMAL_PROMPT,
            "user_prompt_template": DEFAULT_USER_TEMPLATE
        }

def save_prompts(prompts: Dict[str, str]) -> bool:
    ensure_voiceime_dir()
    temp_file = PROMPTS_FILE.with_suffix(".tmp")
    try:
        with open(temp_file, "w", encoding="utf-8") as f:
            json.dump(prompts, f, ensure_ascii=False, indent=2)
        temp_file.replace(PROMPTS_FILE)
        notify_voiceime_app()
        return True
    except Exception as e:
        sys.stderr.write(f"[VoiceIME MCP] Error saving prompts.json: {e}\n")
        if temp_file.exists():
            temp_file.unlink(missing_ok=True)
        return False

def tool_get_llm_prompts(args: Dict[str, Any]) -> str:
    prompts = load_prompts()
    return json.dumps(prompts, ensure_ascii=False, indent=2)

def tool_set_llm_prompts(args: Dict[str, Any]) -> str:
    current = load_prompts()
    updated = []
    if "casual_system_prompt" in args and args["casual_system_prompt"] is not None:
        current["casual_system_prompt"] = str(args["casual_system_prompt"])
        updated.append("口語システムプロンプト (casual_system_prompt)")
    if "formal_system_prompt" in args and args["formal_system_prompt"] is not None:
        current["formal_system_prompt"] = str(args["formal_system_prompt"])
        updated.append("文章システムプロンプト (formal_system_prompt)")
    if "user_prompt_template" in args and args["user_prompt_template"] is not None:
        current["user_prompt_template"] = str(args["user_prompt_template"])
        updated.append("ユーザー入力テンプレート (user_prompt_template)")

    if not updated:
        return "変更するプロンプトが指定されていません。(casual_system_prompt, formal_system_prompt, user_prompt_template のいずれかを指定してください)"

    if save_prompts(current):
        return f"以下のプロンプトを正常に更新・保存しました (VoiceIMEに即座に反映されます):\n" + "\n".join(f"- {u}" for u in updated)
    else:
        return "エラー: prompts.json の保存に失敗しました。"

def tool_reset_llm_prompts(args: Dict[str, Any]) -> str:
    defaults = {
        "casual_system_prompt": DEFAULT_CASUAL_PROMPT,
        "formal_system_prompt": DEFAULT_FORMAL_PROMPT,
        "user_prompt_template": DEFAULT_USER_TEMPLATE
    }
    if save_prompts(defaults):
        return "推敲プロンプトを初期値（推奨設定）にリセットしました。(VoiceIMEに即座に反映されます)"
    else:
        return "エラー: prompts.json のリセットに失敗しました。"

def tool_reload_voiceime(args: Dict[str, Any]) -> str:
    # タイムスタンプを更新して FileWatcher を確実にトリガー
    try:
        ensure_voiceime_dir()
        if DICT_FILE.exists():
            os.utime(DICT_FILE, None)
        if VOCAB_FILE.exists():
            os.utime(VOCAB_FILE, None)
        if PROMPTS_FILE.exists():
            os.utime(PROMPTS_FILE, None)
        notify_voiceime_app()
        return "VoiceIME アプリへ再読み込みシグナルを送信しました。ファイル監視により即座に反映されます。"
    except Exception as e:
        return f"再読み込みトリガー中にエラーが発生しました: {e}"

# ==========================================
# ログ設定・API キー・設定連携ヘルパー
# ==========================================

def load_api_keys() -> Dict[str, str]:
    if not API_KEYS_FILE.exists():
        return {}
    try:
        with open(API_KEYS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except Exception as e:
        sys.stderr.write(f"[VoiceIME MCP] Error loading api_keys.json: {e}\n")
        return {}

def get_app_setting(key: str, default: Any = None) -> Any:
    try:
        res = subprocess.run(
            ["defaults", "read", "com.voiceime.app", key],
            capture_output=True, text=True, check=True
        )
        val = res.stdout.strip()
        if val in ("1", "true", "YES"):
            return True
        elif val in ("0", "false", "NO"):
            return False
        return val
    except Exception:
        return default

def set_app_setting(key: str, value: Any) -> bool:
    try:
        if isinstance(value, bool):
            arg = "-bool"
            val_str = "true" if value else "false"
        elif isinstance(value, int):
            arg = "-int"
            val_str = str(value)
        elif isinstance(value, float):
            arg = "-float"
            val_str = str(value)
        else:
            arg = "-string"
            val_str = str(value)
        subprocess.run(
            ["defaults", "write", "com.voiceime.app", key, arg, val_str],
            capture_output=True, check=True
        )
        return True
    except Exception as e:
        sys.stderr.write(f"[VoiceIME MCP] Error setting defaults {key}: {e}\n")
        return False

def is_pipeline_logging_enabled() -> bool:
    val = get_app_setting("voiceime_pipelineLoggingEnabled", True)
    return bool(val)

def is_mcp_agent_editing_enabled() -> bool:
    """MCP連携（単語登録・置換ルール・修正ストック・ログ参照等）がVoiceIMEで有効化されているか確認"""
    val = get_app_setting("voiceime_mcpAgentEditingEnabled")
    if val is None:
        val = get_app_setting("voiceime_correctionStockEnabled", False)
    return bool(val)

def check_editing_allowed() -> Optional[str]:
    """MCPアクセスが許可されているかチェック。OFFの場合は親切な案内文を返す"""
    if not is_mcp_agent_editing_enabled():
        return (
            "【アクセス制限】VoiceIME の設定で『MCP連携』が無効(OFF)になっています。\n"
            "AI Agent (Cursor, Claude, Antigravity等) から VoiceIME の機能・辞書・ログ・単語登録にアクセスするには、"
            "メニューバーの VoiceIME ➔ 設定 ➔ 『単語登録・辞書』タブから『MCP連携』をONに切り替えてください。"
        )
    return None

def load_corrections() -> List[Dict[str, Any]]:
    ensure_voiceime_dir()
    if not CORRECTIONS_FILE.exists():
        return []
    try:
        with open(CORRECTIONS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, list) else []
    except Exception as e:
        sys.stderr.write(f"[VoiceIME MCP] Error loading corrections.json: {e}\n")
        return []

def save_corrections(records: List[Dict[str, Any]]) -> bool:
    ensure_voiceime_dir()
    temp_file = CORRECTIONS_FILE.with_suffix(".tmp")
    try:
        with open(temp_file, "w", encoding="utf-8") as f:
            json.dump(records, f, ensure_ascii=False, indent=2)
        temp_file.replace(CORRECTIONS_FILE)
        return True
    except Exception as e:
        sys.stderr.write(f"[VoiceIME MCP] Error saving corrections.json: {e}\n")
        if temp_file.exists():
            temp_file.unlink(missing_ok=True)
        return False

def log_to_pipeline(message: str):
    if not is_pipeline_logging_enabled():
        return
    try:
        ensure_voiceime_dir()
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(message)
    except Exception as e:
        sys.stderr.write(f"[VoiceIME MCP] Error writing to pipeline.log: {e}\n")

def apply_dictionary_rules(text: str) -> str:
    rules = load_dictionary()
    result = text
    for rule in rules:
        if not rule.get("isEnabled", True):
            continue
        pattern = rule.get("pattern", "")
        replacement = rule.get("replacement", "")
        if not pattern:
            continue
        try:
            if rule.get("isRegex", False):
                result = re.sub(pattern, replacement, result)
            else:
                result = result.replace(pattern, replacement)
        except Exception as e:
            sys.stderr.write(f"[VoiceIME MCP] Regex error for pattern '{pattern}': {e}\n")
    return result

def call_whisper_api(
    audio_path: str,
    base_url: str,
    api_key: str,
    model: str,
    language: Optional[str] = None,
    prompt: Optional[str] = None
) -> str:
    url = base_url.rstrip("/")
    if not url.endswith("/audio/transcriptions"):
        url = f"{url}/audio/transcriptions"

    path_obj = Path(audio_path)
    if not path_obj.exists():
        raise FileNotFoundError(f"音声ファイルが見つかりません: {audio_path}")

    filename = path_obj.name
    mime_type, _ = mimetypes.guess_type(audio_path)
    if not mime_type:
        mime_type = "audio/wav"

    with open(audio_path, "rb") as f:
        file_bytes = f.read()

    boundary = f"----VoiceIMEMCPBoundary{uuid.uuid4().hex}"
    body = bytearray()

    def add_field(name: str, val: str):
        nonlocal body
        body.extend(f"--{boundary}\r\n".encode("utf-8"))
        body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("utf-8"))
        body.extend(f"{val}\r\n".encode("utf-8"))

    add_field("model", model)
    add_field("response_format", "json")
    if language:
        add_field("language", language)
    if prompt:
        add_field("prompt", prompt)

    # file field
    body.extend(f"--{boundary}\r\n".encode("utf-8"))
    body.extend(f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'.encode("utf-8"))
    body.extend(f"Content-Type: {mime_type}\r\n\r\n".encode("utf-8"))
    body.extend(file_bytes)
    body.extend(b"\r\n")

    body.extend(f"--{boundary}--\r\n".encode("utf-8"))

    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
        "User-Agent": "VoiceIME/1.0 (Macintosh; Mac OS X)"
    }

    req = urllib.request.Request(url, data=bytes(body), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            resp_body = resp.read().decode("utf-8")
            data = json.loads(resp_body)
            return data.get("text", "").strip()
    except urllib.error.HTTPError as e:
        err_msg = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Whisper API エラー ({e.code}): {err_msg}")
    except Exception as e:
        raise RuntimeError(f"Whisper API リクエスト失敗: {e}")

def call_llm_refinement(
    text: str,
    base_url: str,
    api_key: str,
    model: str,
    style: str = "casual",
    prompt_hint: Optional[str] = None
) -> str:
    url = base_url.rstrip("/")
    if not url.endswith("/chat/completions"):
        url = f"{url}/chat/completions"

    prompts = load_prompts()
    if style == "formal":
        system_prompt = prompts.get("formal_system_prompt", DEFAULT_FORMAL_PROMPT)
    else:
        system_prompt = prompts.get("casual_system_prompt", DEFAULT_CASUAL_PROMPT)

    if prompt_hint:
        system_prompt += f"\n\n【文脈・用語ヒント】\n{prompt_hint}"

    user_template = prompts.get("user_prompt_template", DEFAULT_USER_TEMPLATE)
    user_content = user_template.replace("{input}", text)

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_content}
        ],
        "temperature": 0.3
    }

    data_bytes = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "User-Agent": "VoiceIME/1.0 (Macintosh; Mac OS X)"
    }

    req = urllib.request.Request(url, data=data_bytes, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp_body = resp.read().decode("utf-8")
            data = json.loads(resp_body)
            choices = data.get("choices", [])
            if not choices:
                return text
            raw_content = choices[0].get("message", {}).get("content", "").strip()

            # <formatted_text> タグからの抽出
            tag_match = re.search(r"<formatted_text>(.*?)</formatted_text>", raw_content, re.DOTALL)
            if tag_match:
                extracted = tag_match.group(1).strip()
                return extracted if extracted else text
            return raw_content
    except urllib.error.HTTPError as e:
        err_msg = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"LLM 推敲 API エラー ({e.code}): {err_msg}")
    except Exception as e:
        raise RuntimeError(f"LLM 推敲 API リクエスト失敗: {e}")

# ==========================================
# 音声テスト・ログ管理ツール実装
# ==========================================

def tool_transcribe_audio(args: Dict[str, Any]) -> str:
    audio_path = args.get("audio_path", "").strip()
    if not audio_path:
        return json.dumps({"status": "error", "message": "audio_path が指定されていません。"}, ensure_ascii=False)

    path_obj = Path(audio_path).expanduser().resolve()
    if not path_obj.exists():
        return json.dumps({"status": "error", "message": f"音声ファイルが見つかりません: {path_obj}"}, ensure_ascii=False)

    api_keys = load_api_keys()

    # 1. Whisper 設定の取得
    selected_provider = str(get_app_setting("voiceime_selectedProvider", "groq")).lower()
    if selected_provider == "openai":
        whisper_base_url = "https://api.openai.com/v1"
        whisper_model = str(get_app_setting("voiceime_openaiModel", "whisper-1"))
        whisper_api_key = api_keys.get("openai") or api_keys.get("voiceime_openai_api_key", "")
    else: # groq
        whisper_base_url = "https://api.groq.com/openai/v1"
        whisper_model = str(get_app_setting("voiceime_groqModel", "whisper-large-v3-turbo"))
        whisper_api_key = api_keys.get("groq") or api_keys.get("voiceime_groq_api_key", "")

    if not whisper_api_key:
        return json.dumps({"status": "error", "message": f"プロバイダ '{selected_provider}' の API キーが登録されていません (~/.voiceime/api_keys.json)"}, ensure_ascii=False)

    # 言語設定
    lang = args.get("language")
    if lang is None:
        saved_lang = str(get_app_setting("voiceime_language", ""))
        lang = saved_lang if saved_lang else None
    elif lang.strip() == "" or lang.lower() == "auto":
        lang = None

    prompt_hint = args.get("prompt_hint")

    # ログ記録開始
    now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    log_to_pipeline(f"\n==================================================\n[{now_str}] 🎙️ 音声入力セッション開始 (MCP テスト: {path_obj.name})\n==================================================\n")

    start_time = datetime.now()
    try:
        # Whisper 実行
        whisper_raw = call_whisper_api(
            audio_path=str(path_obj),
            base_url=whisper_base_url,
            api_key=whisper_api_key,
            model=whisper_model,
            language=lang,
            prompt=prompt_hint
        )
        rec_time_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        log_to_pipeline(f"\n\n1. Whisperから逐次送られてきた文字列 [MCPテスト速報 - {rec_time_str}]:\n{whisper_raw}\n")

        # 辞書置換
        dict_applied = apply_dictionary_rules(whisper_raw)

        # 推敲設定
        refine_arg = args.get("refinement_enabled")
        if refine_arg is not None:
            is_refine_enabled = bool(refine_arg)
        else:
            is_refine_enabled = bool(get_app_setting("voiceime_llmRefinementEnabled", False))

        style = args.get("refinement_style") or str(get_app_setting("voiceime_refinementStyle", "casual"))

        refined_text = None
        final_text = dict_applied

        if is_refine_enabled and dict_applied:
            llm_provider_mode = str(get_app_setting("voiceime_llmProviderMode", selected_provider)).lower()
            if llm_provider_mode == "openai":
                llm_base_url = "https://api.openai.com/v1"
                llm_model = str(get_app_setting("voiceime_openai_llm_model", "gpt-4o-mini"))
                llm_api_key = api_keys.get("openai") or api_keys.get("voiceime_openai_api_key", "")
            elif llm_provider_mode == "custom":
                llm_base_url = str(get_app_setting("voiceime_custom_llm_baseURL", "https://api.sarashina.ai/v1"))
                llm_model = str(get_app_setting("voiceime_custom_llm_model", "sarashina3-mini"))
                llm_api_key = api_keys.get("custom") or api_keys.get("sarashina") or api_keys.get("voiceime_custom_llm_api_key", "")
            else: # groq
                llm_base_url = "https://api.groq.com/openai/v1"
                llm_model = str(get_app_setting("voiceime_groq_llm_model", "qwen/qwen3.8-27b"))
                llm_api_key = api_keys.get("groq") or api_keys.get("voiceime_groq_api_key", "")

            if llm_api_key and llm_model:
                input_time_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
                log_to_pipeline(f"\n\n2. Whisperから推敲LLMへ送られる文字列 [MCP推敲入力 - {input_time_str}]:\n{dict_applied}\n")

                llm_result = call_llm_refinement(
                    text=dict_applied,
                    base_url=llm_base_url,
                    api_key=llm_api_key,
                    model=llm_model,
                    style=style,
                    prompt_hint=prompt_hint
                )
                output_time_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
                log_to_pipeline(f"\n\n3. 推敲LLMから修正され戻される文字列 [MCP推敲出力 - {output_time_str}]:\n{llm_result}\n")

                refined_text = llm_result
                final_text = apply_dictionary_rules(llm_result)

        end_time = datetime.now()
        end_time_str = end_time.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        duration = (end_time - start_time).total_seconds()
        log_to_pipeline(f"\n==================================================\n[{end_time_str}] ✅ 音声入力セッション完了 (確定出力テキスト - {duration:.2f}秒)\n{final_text}\n==================================================\n")

        response = {
            "status": "success",
            "audio_file": str(path_obj),
            "whisper_raw_text": whisper_raw,
            "dictionary_applied_text": dict_applied,
            "refined_text": refined_text,
            "final_text": final_text,
            "refinement_enabled": is_refine_enabled,
            "refinement_style": style if is_refine_enabled else None,
            "whisper_model": whisper_model,
            "duration_seconds": round(duration, 3),
            "pipeline_log_file": str(LOG_FILE)
        }
        return json.dumps(response, ensure_ascii=False, indent=2)

    except Exception as e:
        err_time_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        log_to_pipeline(f"\n[{err_time_str}] ❌ MCP音声テストエラー: {e}\n")
        return json.dumps({"status": "error", "message": str(e)}, ensure_ascii=False, indent=2)

def tool_get_pipeline_logging(args: Dict[str, Any]) -> str:
    enabled = is_pipeline_logging_enabled()
    exists = LOG_FILE.exists()
    size = LOG_FILE.stat().st_size if exists else 0
    mod_time = datetime.fromtimestamp(LOG_FILE.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S") if exists else None

    result = {
        "logging_enabled": enabled,
        "log_file_path": str(LOG_FILE),
        "file_exists": exists,
        "file_size_bytes": size,
        "last_modified": mod_time
    }
    return json.dumps(result, ensure_ascii=False, indent=2)

def tool_set_pipeline_logging(args: Dict[str, Any]) -> str:
    enabled = args.get("enabled")
    if enabled is None:
        return "エラー: 'enabled' (boolean: true または false) を指定してください。"
    val = bool(enabled)
    if set_app_setting("voiceime_pipelineLoggingEnabled", val):
        status_str = "有効 (ON)" if val else "無効 (OFF)"
        return f"パイプラインログ記録 (~/.voiceime/pipeline.log) を {status_str} に設定しました。(VoiceIMEアプリにも即座に反映されます)"
    else:
        return "エラー: ログ設定の更新に失敗しました。"

def tool_get_latest_pipeline_log(args: Dict[str, Any]) -> str:
    max_lines = args.get("max_lines", 50)
    try:
        max_lines = max(1, int(max_lines))
    except (ValueError, TypeError):
        max_lines = 50

    if not LOG_FILE.exists():
        return "ログファイル (~/.voiceime/pipeline.log) はまだ作成されていません。"

    try:
        with open(LOG_FILE, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
            tail_lines = lines[-max_lines:]
            return "".join(tail_lines)
    except Exception as e:
        return f"ログ読み込みエラー: {e}"

def tool_clear_pipeline_log(args: Dict[str, Any]) -> str:
    try:
        ensure_voiceime_dir()
        with open(LOG_FILE, "w", encoding="utf-8") as f:
            f.write("")
        return "パイプラインログ (~/.voiceime/pipeline.log) を正常にクリアしました。"
    except Exception as e:
        return f"ログクリア中にエラーが発生しました: {e}"

def tool_get_correction_history(args: Dict[str, Any]) -> str:
    """ストックされた修正履歴 (~/.voiceime/corrections.json) を取得"""
    limit = args.get("limit", 50)
    try:
        limit = max(1, min(200, int(limit)))
    except (ValueError, TypeError):
        limit = 50
    unregistered_only = bool(args.get("unregistered_only", False))

    records = load_corrections()
    if unregistered_only:
        records = [r for r in records if not r.get("is_registered_to_vocabulary", False)]

    records = records[:limit]
    if not records:
        return "ストックされた修正履歴はありません。"

    summary = {
        "count": len(records),
        "unregistered_count": sum(1 for r in records if not r.get("is_registered_to_vocabulary", False)),
        "records": records
    }
    return json.dumps(summary, ensure_ascii=False, indent=2)

def tool_register_correction_to_vocabulary(args: Dict[str, Any]) -> str:
    """修正履歴から単語登録を実行"""
    guard = check_editing_allowed()
    if guard:
        return guard

    correction_id = args.get("correction_id", "").strip()
    word = args.get("word", "").strip()

    records = load_corrections()
    target_word = word

    if correction_id:
        matched = next((r for r in records if r.get("id") == correction_id), None)
        if not matched:
            return f"エラー: 指定された correction_id '{correction_id}' が見つかりません。"
        if not target_word:
            target_word = matched.get("diff_after", "").strip()
        matched["is_registered_to_vocabulary"] = True
        save_corrections(records)

    if not target_word:
        return "エラー: 登録する単語 (word) または有効な correction_id を指定してください。"

    # 単語リストに追加
    vocab = load_vocabulary()
    if target_word not in vocab:
        vocab.append(target_word)
        save_vocabulary(vocab)
        return f"単語登録を完了しました: '{target_word}' (vocabulary.json に追加・反映されました)"
    else:
        return f"単語 '{target_word}' はすでに登録済みです。"

def tool_register_correction_to_dictionary(args: Dict[str, Any]) -> str:
    """修正履歴の差分（変更前 ➔ 変更後）をテキスト置換ルール（dictionary.json）として登録"""
    guard = check_editing_allowed()
    if guard:
        return guard

    correction_id = args.get("correction_id", "").strip()
    pattern = args.get("pattern", "").strip()
    replacement = args.get("replacement", "").strip()

    records = load_corrections()
    if correction_id:
        matched = next((r for r in records if r.get("id") == correction_id), None)
        if not matched:
            return f"エラー: 指定された correction_id '{correction_id}' が見つかりません。"
        if not pattern:
            pattern = matched.get("diff_before", "").strip()
        if not replacement:
            replacement = matched.get("diff_after", "").strip()
        matched["is_registered_to_vocabulary"] = True
        save_corrections(records)

    if not pattern or not replacement:
        return "エラー: pattern と replacement の両方を指定するか、有効な correction_id を指定してください。"

    rules = load_dictionary()
    existing_idx = next((i for i, r in enumerate(rules) if r.get("pattern") == pattern), None)
    if existing_idx is not None:
        rules[existing_idx]["replacement"] = replacement
        msg = f"既存の置換ルール '{pattern}' を更新しました ➔ '{replacement}'"
    else:
        new_rule = {
            "id": str(uuid.uuid4()).upper(),
            "pattern": pattern,
            "replacement": replacement,
            "isRegex": False,
            "isEnabled": True
        }
        rules.append(new_rule)
        msg = f"置換ルールを登録しました: '{pattern}' ➔ '{replacement}'"

    if save_dictionary(rules):
        return f"{msg} (dictionary.json に追加・反映されました)"
    else:
        return "エラー: dictionary.json の保存に失敗しました。"

def tool_clear_correction_history(args: Dict[str, Any]) -> str:
    """ストックされた修正履歴 (~/.voiceime/corrections.json) を全件クリア"""
    guard = check_editing_allowed()
    if guard:
        return guard

    try:
        ensure_voiceime_dir()
        if CORRECTIONS_FILE.exists():
            CORRECTIONS_FILE.unlink()
        return "修正履歴ストック (~/.voiceime/corrections.json) を正常にクリアしました。"
    except Exception as e:
        return f"修正履歴クリア中にエラーが発生しました: {e}"

TOOLS = [
    {
        "name": "list_vocabulary",
        "description": "VoiceIME の登録単語（人名、専門用語、社名等）一覧を取得します。",
        "inputSchema": {
            "type": "object",
            "properties": {}
        }
    },
    {
        "name": "add_vocabulary",
        "description": "VoiceIME に登録単語（人名、専門用語、社名等）を追加します。Whisper / LLM の推敲ヒントと自動連動します。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "words": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "追加する単語の配列、またはカンマ区切り文字列"
                }
            },
            "required": ["words"]
        }
    },
    {
        "name": "remove_vocabulary",
        "description": "VoiceIME から登録単語を削除します。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "words": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "削除する単語の配列、またはカンマ区切り文字列"
                }
            },
            "required": ["words"]
        }
    },
    {
        "name": "list_dictionary_rules",
        "description": "VoiceIME のテキスト自動置換ルール（略称展開、改行、記号、正規表現）一覧を取得します。",
        "inputSchema": {
            "type": "object",
            "properties": {}
        }
    },
    {
        "name": "add_dictionary_rule",
        "description": "VoiceIME にテキスト置換ルールを追加（または既存パターンを更新）します。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "pattern": {
                    "type": "string",
                    "description": "置換対象の単語または正規表現パターン"
                },
                "replacement": {
                    "type": "string",
                    "description": "置換後の文字列（改行は \\n）"
                },
                "is_regex": {
                    "type": "boolean",
                    "description": "正規表現を使用するかどうか (省略時は false)",
                    "default": False
                },
                "is_enabled": {
                    "type": "boolean",
                    "description": "ルールを有効化するかどうか (省略時は true)",
                    "default": True
                }
            },
            "required": ["pattern", "replacement"]
        }
    },
    {
        "name": "remove_dictionary_rule",
        "description": "VoiceIME のテキスト置換ルールを削除します。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "pattern": {
                    "type": "string",
                    "description": "削除対象のパターン"
                },
                "id": {
                    "type": "string",
                    "description": "削除対象のルールID (UUID)"
                }
            }
        }
    },
    {
        "name": "update_dictionary_rule",
        "description": "VoiceIME の既存のテキスト置換ルールを更新します。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "pattern": {
                    "type": "string",
                    "description": "対象ルールの現在のパターン"
                },
                "new_pattern": {
                    "type": "string",
                    "description": "変更後の新しいパターン (任意)"
                },
                "new_replacement": {
                    "type": "string",
                    "description": "変更後の新しい置換文字列 (任意)"
                },
                "is_regex": {
                    "type": "boolean",
                    "description": "正規表現フラグ (任意)"
                },
                "is_enabled": {
                    "type": "boolean",
                    "description": "有効フラグ (任意)"
                }
            },
            "required": ["pattern"]
        }
    },
    {
        "name": "reload_voiceime",
        "description": "VoiceIME アプリへ設定の再読み込みを明示的に通知します。",
        "inputSchema": {
            "type": "object",
            "properties": {}
        }
    },
    {
        "name": "get_llm_prompts",
        "description": "VoiceIME の推敲（LLM）用プロンプト（口語システムプロンプト、文章システムプロンプト、ユーザー入力テンプレート）を取得します。",
        "inputSchema": {
            "type": "object",
            "properties": {}
        }
    },
    {
        "name": "set_llm_prompts",
        "description": "VoiceIME の推敲（LLM）用プロンプトを更新します。指定した項目のみが更新され、~/.voiceime/prompts.json に即座に保存・同期されます。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "casual_system_prompt": {
                    "type": "string",
                    "description": "口語モード（チャット・会話向け）のシステムプロンプト (任意)"
                },
                "formal_system_prompt": {
                    "type": "string",
                    "description": "文章モード（ビジネス・報告書向け）のシステムプロンプト (任意)"
                },
                "user_prompt_template": {
                    "type": "string",
                    "description": "ユーザー入力プロンプトのテンプレート（{input} にWhisperテキストが挿入されます）(任意)"
                }
            }
        }
    },
    {
        "name": "reset_llm_prompts",
        "description": "VoiceIME の推敲（LLM）用プロンプトを推奨初期値にリセットします。",
        "inputSchema": {
            "type": "object",
            "properties": {}
        }
    },
    {
        "name": "transcribe_audio",
        "description": "音声ファイルを VoiceIME の Whisper 音声認識＆辞書置換＆AI推敲パイプラインに投入して文字起こしをテスト・実行します。ログ記録が有効な場合は ~/.voiceime/pipeline.log にもセッションログが記録されます。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "audio_path": {
                    "type": "string",
                    "description": "文字起こしする音声ファイル (WAV, MP3, M4A, AAC, FLAC, OGG等) の絶対パス (必須)"
                },
                "language": {
                    "type": "string",
                    "description": "音声言語コード (例: 'ja', 'en', 'auto'。省略時はVoiceIMEの現在設定) (任意)"
                },
                "refinement_enabled": {
                    "type": "boolean",
                    "description": "AI推敲 (LLM) を適用するかどうか (true/false。省略時はVoiceIMEの現在設定) (任意)"
                },
                "refinement_style": {
                    "type": "string",
                    "enum": ["casual", "formal"],
                    "description": "推敲スタイル ('casual': 口語・会話向け, 'formal': 文章・報告書向け。省略時は現在設定) (任意)"
                },
                "prompt_hint": {
                    "type": "string",
                    "description": "Whisper API に与えるコンテキスト・プロンプトヒント (任意)"
                }
            },
            "required": ["audio_path"]
        }
    },
    {
        "name": "get_pipeline_logging",
        "description": "VoiceIME のリアルタイムパイプラインログ (~/.voiceime/pipeline.log) の記録状態 (有効/無効、ファイルサイズ等) を取得します。",
        "inputSchema": {
            "type": "object",
            "properties": {}
        }
    },
    {
        "name": "set_pipeline_logging",
        "description": "VoiceIME のリアルタイムパイプラインログ (~/.voiceime/pipeline.log) の記録を有効化 (ON) または無効化 (OFF) に設定します。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "enabled": {
                    "type": "boolean",
                    "description": "true: ログ記録を有効化 (ON), false: ログ記録を停止 (OFF)"
                }
            },
            "required": ["enabled"]
        }
    },
    {
        "name": "get_latest_pipeline_log",
        "description": "パイプラインログ (~/.voiceime/pipeline.log) の最新内容（末尾N行）を取得します。音声認識・推敲テストの判定に利用できます。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "max_lines": {
                    "type": "integer",
                    "description": "取得する末尾行数 (デフォルト: 50)"
                }
            }
        }
    },
    {
        "name": "clear_pipeline_log",
        "description": "パイプラインログ (~/.voiceime/pipeline.log) を空にクリアします。",
        "inputSchema": {
            "type": "object",
            "properties": {}
        }
    },
    {
        "name": "get_correction_history",
        "description": "VoiceIME の修正モードでユーザーが手動修正した文章の履歴・差分ストック (~/.voiceime/corrections.json) を取得します。AI Agent がユーザーの修正傾向を分析して、単語登録や置換ルールの提案・自動登録を行う際に使用します。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "limit": {
                    "type": "integer",
                    "description": "取得する最大件数 (デフォルト: 50)"
                },
                "unregistered_only": {
                    "type": "boolean",
                    "description": "未だ単語登録されていない修正履歴のみを絞り込むかどうか (デフォルト: false)"
                }
            }
        }
    },
    {
        "name": "register_correction_to_vocabulary",
        "description": "修正履歴の差分単語（または指定単語）を VoiceIME の単語帳 (vocabulary.json) に登録します。AI Agent がユーザーの手動修正から固有名詞や新語を学習・登録する際に使用します。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "correction_id": {
                    "type": "string",
                    "description": "対象の修正履歴レコードID (UUID)"
                },
                "word": {
                    "type": "string",
                    "description": "登録する単語 (省略時は correction_id から自動抽出された修正後単語)"
                }
            }
        }
    },
    {
        "name": "register_correction_to_dictionary",
        "description": "修正履歴の差分（変更前 ➔ 変更後）を VoiceIME のテキスト置換ルール (dictionary.json) に登録します。同音異義語や音声誤認識の自動置換パターンを恒久的に学習させる際に使用します。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "correction_id": {
                    "type": "string",
                    "description": "対象の修正履歴レコードID (UUID)"
                },
                "pattern": {
                    "type": "string",
                    "description": "置換対象のパターン (省略時は correction_id から自動抽出された変更前テキスト)"
                },
                "replacement": {
                    "type": "string",
                    "description": "置換後のテキスト (省略時は correction_id から自動抽出された変更後テキスト)"
                }
            }
        }
    },
    {
        "name": "clear_correction_history",
        "description": "修正履歴ストック (~/.voiceime/corrections.json) を全件クリアします。",
        "inputSchema": {
            "type": "object",
            "properties": {}
        }
    }
]

TOOL_MAP = {
    "list_vocabulary": tool_list_vocabulary,
    "add_vocabulary": tool_add_vocabulary,
    "remove_vocabulary": tool_remove_vocabulary,
    "list_dictionary_rules": tool_list_dictionary_rules,
    "add_dictionary_rule": tool_add_dictionary_rule,
    "remove_dictionary_rule": tool_remove_dictionary_rule,
    "update_dictionary_rule": tool_update_dictionary_rule,
    "reload_voiceime": tool_reload_voiceime,
    "get_llm_prompts": tool_get_llm_prompts,
    "set_llm_prompts": tool_set_llm_prompts,
    "reset_llm_prompts": tool_reset_llm_prompts,
    "transcribe_audio": tool_transcribe_audio,
    "get_pipeline_logging": tool_get_pipeline_logging,
    "set_pipeline_logging": tool_set_pipeline_logging,
    "get_latest_pipeline_log": tool_get_latest_pipeline_log,
    "clear_pipeline_log": tool_clear_pipeline_log,
    "get_correction_history": tool_get_correction_history,
    "register_correction_to_vocabulary": tool_register_correction_to_vocabulary,
    "register_correction_to_dictionary": tool_register_correction_to_dictionary,
    "clear_correction_history": tool_clear_correction_history
}

def handle_json_rpc(line: str):
    try:
        req = json.loads(line)
    except Exception:
        return

    req_id = req.get("id")
    method = req.get("method")
    params = req.get("params", {})

    if method == "initialize":
        res = {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {
                    "tools": {}
                },
                "serverInfo": {
                    "name": "voiceime-mcp",
                    "version": "1.0.0"
                }
            }
        }
        send_response(res)
    elif method == "notifications/initialized":
        # Notification: no response needed
        pass
    elif method == "ping":
        send_response({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {}
        })
    elif method == "tools/list":
        res = {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "tools": TOOLS
            }
        }
        send_response(res)
    elif method == "tools/call":
        tool_name = params.get("name")
        tool_args = params.get("arguments", {})

        # MCP連携がOFFの場合は全ツールの実行を安全にブロック
        mcp_guard = check_editing_allowed()
        if mcp_guard:
            send_response({
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [
                        {
                            "type": "text",
                            "text": mcp_guard
                        }
                    ],
                    "isError": True
                }
            })
            return

        handler = TOOL_MAP.get(tool_name)
        if handler:
            try:
                text_result = handler(tool_args)
                res = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [
                            {
                                "type": "text",
                                "text": text_result
                            }
                        ],
                        "isError": False
                    }
                }
            except Exception as e:
                res = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [
                            {
                                "type": "text",
                                "text": f"Error executing tool {tool_name}: {e}"
                            }
                        ],
                        "isError": True
                    }
                }
        else:
            res = {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {
                    "code": -32601,
                    "message": f"Method not found: {tool_name}"
                }
            }
        send_response(res)
    elif req_id is not None:
        send_response({
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {
                "code": -32601,
                "message": f"Method not found: {method}"
            }
        })

def send_response(res: Dict[str, Any]):
    msg = json.dumps(res, ensure_ascii=False)
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()

def main():
    # CLI としての単発実行引数があれば簡易実行
    if len(sys.argv) > 1:
        cmd = sys.argv[1]
        if cmd == "list-vocab":
            print(tool_list_vocabulary({}))
            return
        elif cmd == "list-rules":
            print(tool_list_dictionary_rules({}))
            return
        elif cmd == "--help" or cmd == "-h":
            print("VoiceIME MCP Server")
            print("標準入出力 (JSON-RPC) で MCP サーバーとして動作します。")
            print("Claude Desktop / Cursor / Windsurf / Cline 等の設定に以下を指定してください:")
            print(f'  command: "{sys.executable}"')
            print(f'  args: ["{os.path.abspath(__file__)}"]')
            return

    # MCP stdio サーバー実行ループ
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        handle_json_rpc(line)

if __name__ == "__main__":
    main()
