#!/usr/bin/env bash
# SessionEnd hook: ローカルキャッシュ(.session-history)の今セッション分を、
# 専用ブランチ session-history へ集約コミット＆push する（作業ブランチは無汚染）。
# 一時 worktree を使い、作業ツリー/カレントブランチには一切触れない。
set -euo pipefail

PROJ="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CACHE="$PROJ/.session-history"
BR="session-history"

# 今セッションで生成された成果物が無ければ何もしない
shopt -s nullglob
MDS=("$CACHE"/*.md); JLS=("$CACHE"/*.jsonl)
[ ${#MDS[@]} -eq 0 ] && [ ${#JLS[@]} -eq 0 ] && exit 0

WT="$(mktemp -d)"
cleanup(){ git -C "$PROJ" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"; }
trap cleanup EXIT

git -C "$PROJ" fetch --depth=1 origin "$BR" >/dev/null 2>&1 || true
if git -C "$PROJ" show-ref --verify --quiet "refs/remotes/origin/$BR"; then
  git -C "$PROJ" worktree add --detach "$WT" "origin/$BR" >/dev/null 2>&1
  git -C "$WT" checkout -B "$BR" "origin/$BR" >/dev/null 2>&1
else
  # 専用ブランチ未作成 → orphan で新規作成
  git -C "$PROJ" worktree add --detach "$WT" >/dev/null 2>&1
  git -C "$WT" checkout --orphan "$BR" >/dev/null 2>&1
  git -C "$WT" reset --hard >/dev/null 2>&1 || true
  git -C "$WT" rm -rf . >/dev/null 2>&1 || true
fi

mkdir -p "$WT/sessions"

# 全文 .md を配置（同一セッションは上書き＝upsert）
for f in "${MDS[@]}"; do cp -f "$f" "$WT/sessions/$(basename "$f")"; done

# 索引 log.jsonl を session_id キーで upsert（既存から当該IDを除いて追記）
LOG="$WT/sessions/log.jsonl"
touch "$LOG"
for jl in "${JLS[@]}"; do
  SID="$(jq -r '.session_id' "$jl" 2>/dev/null)"; [ -z "$SID" ] && continue
  grep -v -F "\"session_id\":\"$SID\"" "$LOG" > "$LOG.tmp" 2>/dev/null || true
  cat "$jl" >> "$LOG.tmp"
  mv "$LOG.tmp" "$LOG"
done
# 日付順に整列（任意・読みやすさ用）
sort -t'"' -k4 "$LOG" -o "$LOG" 2>/dev/null || true

# 人間向け索引 INDEX.md を再生成
{
  echo "# Session History Index"
  echo
  echo "| date | id | summary | files |"
  echo "|------|----|---------|-------|"
  jq -r '"| \(.date) | [\(.id)](sessions/\(.detail|sub("^sessions/";""))) | \(.summary//"") | \((.files//[])|join(", ")) |"' "$LOG" 2>/dev/null
} > "$WT/INDEX.md"

cd "$WT"
git add -A
if ! git diff --cached --quiet; then
  DATE="$(date -u +%F)"
  git -c user.name="claude-session-history" -c user.email="noreply@anthropic.com" \
      commit -q -m "session history: update ${DATE}" || exit 0
  for i in 1 2 3 4; do
    git push -u origin "$BR" >/dev/null 2>&1 && break
    sleep $((2**i))
  done
fi
exit 0
