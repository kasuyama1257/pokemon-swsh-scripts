#!/usr/bin/env bash
# SessionStart hook: 専用ブランチ session-history から軽量索引を取得し、
# 直近 N 件の1行要約だけを Claude へ提示する（起動時トークンを一定に保つ）。
# 全文(.md)はここでは読み込まない。必要時に grep→該当1件のみ参照する運用。
set -euo pipefail

PROJ="${CLAUDE_PROJECT_DIR:-$(pwd)}"
N="${SESSION_HISTORY_SHOW:-5}"          # 起動時に見せる件数
INDEX="$PROJ/.session-history/log.jsonl"

# 専用ブランチから索引ファイルのみ取得（履歴本体はチェックアウトしない＝高速）
mkdir -p "$PROJ/.session-history"
git -C "$PROJ" fetch --depth=1 origin session-history >/dev/null 2>&1 || true
if git -C "$PROJ" cat-file -e origin/session-history:sessions/log.jsonl 2>/dev/null; then
  git -C "$PROJ" show origin/session-history:sessions/log.jsonl > "$INDEX" 2>/dev/null || true
fi
[ ! -s "$INDEX" ] && exit 0   # 履歴がまだ無ければ静かに終了

TOTAL="$(grep -c '' "$INDEX" 2>/dev/null || echo 0)"
RECENT="$(tail -n "$N" "$INDEX" 2>/dev/null | jq -r '"- " + .date + " [" + .id + "] " + (.summary // "") + (if (.files|length)>0 then "  (files: " + (.files|join(", ")) + ")" else "" end)' 2>/dev/null | tac)"

cat <<EOF
<session-history>
過去のセッション履歴データベースが利用可能です（全 ${TOTAL} 件）。直近 ${N} 件:
${RECENT}

全文や過去分の参照は索引を grep してから該当 .md を1件だけ開くこと（起動コスト節約）:
  git show origin/session-history:sessions/log.jsonl | grep -i 'キーワード'
  git show origin/session-history:sessions/<日付>-<id>.md
</session-history>
EOF
exit 0
