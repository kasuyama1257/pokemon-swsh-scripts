# CLAUDE.md

ポケモン剣盾のキー入力自動化 Python スクリプト群（`egg-hatching.py` / `tournament-battle.py`
/ `release.py`）。Switch-Fightstick 経由でシリアル送信する。詳細は `README.md` を参照。

## セッション履歴データベース

このリポジトリは、過去の Claude セッション履歴を **ブランチ `session-history` 上の永続 DB**
として自動蓄積している（フックで全自動・追加トークン消費なし）。仕組みは
`docs/session-history.md` を参照。

作業を始める前に、関連する過去セッションがないか索引を確認すること:

```bash
git fetch origin session-history 2>/dev/null
git show origin/session-history:sessions/log.jsonl | grep -i '<キーワード>'
git show origin/session-history:sessions/<日付>-<id>.md   # 該当1件だけ全文参照
```

起動時(SessionStart)に直近のセッション要約が自動提示される。全文は **必要な1件だけ**
開くこと（起動トークンを一定に保つため、まとめ読みしない）。
