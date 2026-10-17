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
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional

VOICEIME_DIR = Path.home() / ".voiceime"
DICT_FILE = VOICEIME_DIR / "dictionary.json"
VOCAB_FILE = VOICEIME_DIR / "vocabulary.json"

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
    """VoiceIME アプリへ DistributedNotificationCenter 経由でリロード通知を送信"""
    try:
        import subprocess
        script = 'import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.voiceime.notification.reloadDictionary"), object: nil, userInfo: nil, deliverImmediately: true)'
        subprocess.Popen(["swift", "-e", script], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
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

def tool_reload_voiceime(args: Dict[str, Any]) -> str:
    # タイムスタンプを更新して FileWatcher を確実にトリガー
    try:
        ensure_voiceime_dir()
        if DICT_FILE.exists():
            os.utime(DICT_FILE, None)
        if VOCAB_FILE.exists():
            os.utime(VOCAB_FILE, None)
        return "VoiceIME アプリへ再読み込みシグナルを送信しました。ファイル監視により即座に反映されます。"
    except Exception as e:
        return f"再読み込みトリガー中にエラーが発生しました: {e}"

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
    "reload_voiceime": tool_reload_voiceime
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
