#!/usr/bin/env bash
# Stop hook: セッションのトランスクリプトを決定論的に解析し（LLM不使用）、
# 会話の「全文（逐語）＋ツール操作1行」と軽量索引をローカルキャッシュへ upsert する。
# 追加トークン: 0 / 速度: jq解析のみ / 容量: 本文は再現可能なツール出力を除外して圧縮。
set -euo pipefail

PROJ="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CACHE="$PROJ/.session-history"
mkdir -p "$CACHE"

# --- フック入力(JSON, stdin)を読む -------------------------------------------
INPUT="$(cat || true)"
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')"
SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty')"
[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0
[ -z "$SID" ] && SID="unknown"
SHORT="${SID:0:8}"

# --- デバウンス: トランスクリプト未更新なら再処理しない（速度対策） ----------
MARK="$CACHE/.mark-$SHORT"
SIG="$(stat -c '%Y-%s' "$TRANSCRIPT" 2>/dev/null || echo 0)"
[ -f "$MARK" ] && [ "$(cat "$MARK" 2>/dev/null)" = "$SIG" ] && exit 0

# --- メタ情報 ----------------------------------------------------------------
BRANCH="$(jq -r 'select(.gitBranch)|.gitBranch' "$TRANSCRIPT" 2>/dev/null | tail -1)"
TS_START="$(jq -r '.timestamp // empty' "$TRANSCRIPT" 2>/dev/null | head -1)"
TS_END="$(jq -r '.timestamp // empty' "$TRANSCRIPT" 2>/dev/null | tail -1)"
DATE="${TS_START%%T*}"; [ -z "$DATE" ] && DATE="$(date -u +%F)"
N_PROMPTS="$(jq -c 'select(.type=="user" and .promptSource and (.toolUseResult|not))' "$TRANSCRIPT" 2>/dev/null | grep -c '' || true)"
FIRST_PROMPT="$(jq -r 'select(.type=="user" and .promptSource and (.toolUseResult|not)) | (.message.content | if type=="string" then . else ([.[]|select(.type=="text")|.text]|join(" ")) end)' "$TRANSCRIPT" 2>/dev/null | head -1)"
FILES="$(jq -r 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|(.input.file_path // .input.path // empty)' "$TRANSCRIPT" 2>/dev/null | sed "s#^$PROJ/##" | sort -u | grep -v '^$' || true)"
FILES_CSV="$(printf '%s' "$FILES" | paste -sd ',' - 2>/dev/null || true)"

# --- 全文(.md): 会話本文を逐語 + ツール操作を1行で（出力は除外） -------------
MD="$CACHE/$DATE-$SHORT.md"
{
  echo "# Session $DATE ($SHORT)"
  echo
  echo "- session_id: \`$SID\`"
  echo "- branch: \`${BRANCH:-?}\`"
  echo "- period: $TS_START → $TS_END"
  echo "- prompts: $N_PROMPTS / files: ${FILES_CSV:-none}"
  echo
  echo "---"
  echo
  jq -r '
    if .type=="user" and .promptSource and (.toolUseResult|not) then
      "## 👤 User\n\n" + (.message.content | if type=="string" then . else ([.[]|select(.type=="text")|.text]|join("\n")) end) + "\n"
    elif .type=="assistant" then
      ([ .message.content[]? |
         if .type=="text" and ((.text//"")|length)>0 then .text
         elif .type=="tool_use" then "  - ⚙ `"+.name+"` "+(((.input.file_path // .input.command // .input.path // "")|tostring)[0:120])
         else empty end ] | join("\n")) as $t
      | if ($t|length)>0 then "### 🤖 Assistant\n\n"+$t+"\n" else empty end
    else empty end
  ' "$TRANSCRIPT" 2>/dev/null
} > "$MD"

# --- 軽量索引(1行JSON): このセッション分のみ（SessionEndで集約） --------------
SUMMARY="$(printf '%s' "$FIRST_PROMPT" | tr '\n' ' ' | cut -c1-160)"
jq -nc \
  --arg date "$DATE" --arg id "$SHORT" --arg sid "$SID" --arg branch "${BRANCH:-}" \
  --arg start "$TS_START" --arg end "$TS_END" --argjson prompts "${N_PROMPTS:-0}" \
  --arg files "$FILES_CSV" --arg summary "$SUMMARY" --arg detail "sessions/$DATE-$SHORT.md" \
  '{date:$date,id:$id,session_id:$sid,branch:$branch,start:$start,end:$end,prompts:$prompts,files:($files|split(",")|map(select(length>0))),summary:$summary,detail:$detail}' \
  > "$CACHE/$SHORT.jsonl"

printf '%s' "$SIG" > "$MARK"
exit 0
