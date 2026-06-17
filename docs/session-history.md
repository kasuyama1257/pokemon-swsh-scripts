# セッション履歴データベース

Claude Code（特に web 版／リモート実行環境）のセッション履歴を **Git 上の永続データベース**
として自動運用する仕組み。手動記録は不要。会話内容の要約に **追加の LLM トークンは消費しない**
（トランスクリプトを `jq` で決定論的に解析するだけ）。

## 仕組み

リモート実行環境はコンテナが破棄されると消えるため、永続化は Git push に頼る。
履歴データは作業ブランチを汚さないよう **専用ブランチ `session-history`** に隔離して蓄積する。

```
[Stop フック]      会話トランスクリプトを解析 → ローカル .session-history/ に upsert
                   ・全文 .md（会話の逐語＋ツール操作1行。ツール出力は除外して圧縮）
                   ・索引 <id>.jsonl（1行の軽量メタ）
                   ・デバウンス: トランスクリプト未更新なら再処理しない
        │
[SessionEnd フック] 一時 worktree で session-history ブランチへ集約コミット＆push
                   ・session_id キーで upsert（重複しない）
                   ・sessions/log.jsonl（索引）と INDEX.md（人間向け一覧）を更新
        │
[SessionStart フック] session-history から索引のみ取得し、直近 N 件の1行要約を提示
                   ・全文 .md は読み込まない（起動トークンを一定に保つ）
```

## コスト特性

| 項目 | 値（目安） |
|------|-----------|
| 記録時の追加 LLM トークン | **0**（jq 解析のみ） |
| 索引 `log.jsonl` | 約 300B/件（1000 件で約 300KB） |
| 全文 `.md` | 約 8〜30KB/件（生トランスクリプトの約 7%。ツール出力を除外） |
| 起動時(SessionStart)の参照コスト | 約 600 トークン固定（履歴件数に依らない） |
| 全文の参照 | 必要時に grep→該当 1 件のみ（約 2,400 トークン/件） |

## 構成ファイル

- `.claude/settings.json` — Stop / SessionEnd / SessionStart フック登録
- `.claude/hooks/save-session-history.sh` — 記録（Stop）
- `.claude/hooks/persist-session-history.sh` — 永続化（SessionEnd）
- `.claude/hooks/load-session-history.sh` — 参照（SessionStart）
- `.gitignore` — `.session-history/`（ローカルスクラッチ）を無視
- 履歴データ本体 → ブランチ `session-history`（`sessions/*.md`, `sessions/log.jsonl`, `INDEX.md`）

## 過去履歴の参照方法（手動）

```bash
git fetch origin session-history
# 索引をキーワード検索
git show origin/session-history:sessions/log.jsonl | grep -i 'egg'
# 該当セッションの全文
git show origin/session-history:sessions/2026-06-17-54cbd271.md
# 人間向け一覧
git show origin/session-history:INDEX.md
```

## 設定

- `SESSION_HISTORY_SHOW`（環境変数）: 起動時に表示する直近件数（既定 5）。

## 注意 / 制約

- 永続化は **SessionEnd 発火時に1回** push する方針（毎ターン push しない＝ネットワーク/速度に配慮）。
  SessionEnd が発火しない異常終了では、その回の履歴は push されない点に留意。
  確実性を最優先したい場合は Stop フック側にも push を足せる（その分コミットが増える）。
- 機微情報は会話に書かない。履歴は Git に残るため。
