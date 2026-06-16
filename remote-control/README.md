# リモートコントロール（Git経由）

クラウド上の Claude Code セッションから、**自宅のローカルPC**（Switch操作用の
マイコンが接続されたPC）へコマンドを送って実行するための仕組み。

クラウド環境は一時的（エフェメラル）で、自宅PCはNAT配下にあるため、両者を
直接つなぐのではなく **Gitリポジトリをコマンドキュー** として使う。

```
[クラウドのClaude]  --push-->  [GitHub]  --pull-->  [自宅PC: agent.py]
   /remote-control                                      コマンド実行
        ^                                                    |
        |                  <--push-- 結果 <-----------------/
        +-------------- pull で結果取得 ---------------------+
```

外向きの `git pull` / `git push` だけで完結するので、自宅ルーターのポート
開放やグローバルIP、DDNSは不要。

## 構成

| パス | 役割 |
|------|------|
| `remote-control/agent.py` | 自宅PCで常駐させるエージェント。リポジトリをポーリングしてコマンドを実行 |
| `remote-control/queue/` | 未実行コマンド（JSON）が置かれる。クラウド側が push する |
| `remote-control/results/` | 実行結果（JSON）。自宅PCが push して返す |
| `.claude/commands/remote-control.md` | `/remote-control` スラッシュコマンドの定義 |

## 自宅PCでのセットアップ

1. リポジトリをクローン（push できる認証を済ませておく。SSH鍵推奨）:
   ```bash
   git clone git@github.com:kasuyama1257/pokemon-swsh-scripts.git
   cd pokemon-swsh-scripts
   ```

2. エージェントを起動（監視するブランチを指定）:
   ```bash
   python3 remote-control/agent.py --branch master --interval 5
   ```
   - `--branch` : クラウド側が push するブランチ。省略時は現在のブランチ。
   - `--interval` : ポーリング間隔（秒）。既定 5。
   - `--once` : ループせず1回だけ処理して終了（動作確認用）。
   - `--timeout` : コマンド側でtimeout未指定時の既定値（秒）。既定 3600。
   - `--allowlist FILE` : 実行を許可するコマンドの正規表現を1行ずつ記述した
     ファイル。指定すると一致するコマンドのみ実行する。

3. 常駐させる場合は systemd / tmux / nohup などで起動しっぱなしにする。
   systemd の例:
   ```ini
   # /etc/systemd/system/swsh-remote-control.service
   [Unit]
   Description=pokemon-swsh remote control agent
   After=network-online.target

   [Service]
   WorkingDirectory=/home/youruser/pokemon-swsh-scripts
   ExecStart=/usr/bin/python3 remote-control/agent.py --branch master
   Restart=always
   Environment=REMOTE_CONTROL_TOKEN=ここに秘密のトークン

   [Install]
   WantedBy=multi-user.target
   ```

## クラウド側からの使い方

Claude Code セッションで `/remote-control` を実行する:

```
/remote-control python3 egg-hatching.py --laps 20 /dev/ttyUSB0
```

コマンドがキューに push され、自宅PCのエージェントが拾って実行し、結果を
push で返す。結果は `remote-control/results/<ID>.json` に入る。

## コマンド / 結果のフォーマット

コマンド (`queue/<ID>.json`):
```json
{
  "id": "20260616-223000-a1b2",
  "created_at": "2026-06-16T22:30:00",
  "command": "python3 egg-hatching.py --laps 20 /dev/ttyUSB0",
  "cwd": null,
  "timeout": 3600,
  "token": "（任意。エージェントでトークン設定時のみ必須）"
}
```

結果 (`results/<ID>.json`):
```json
{
  "id": "20260616-223000-a1b2",
  "command": "...",
  "cwd": "...",
  "status": "completed",
  "exit_code": 0,
  "stdout": "...",
  "stderr": "...",
  "started_at": "2026-06-16T22:30:05",
  "finished_at": "2026-06-16T22:45:10"
}
```

`status` は `completed` / `timeout` / `rejected` のいずれか。
`rejected` はトークン不一致または allowlist 非該当。

## セキュリティ上の注意

- **このエージェントはリポジトリに push された任意のシェルコマンドを自宅PCで
  実行する。** 対象リポジトリへ push できる人物は誰でも自宅PCを操作できる。
- 必ず **プライベートリポジトリ** で運用すること。
- 不特定多数とコラボするリポジトリでは使わないこと。
- 追加の防御:
  - `REMOTE_CONTROL_TOKEN` を環境変数で設定 → トークンが一致するコマンドのみ実行。
  - `--allowlist` で実行可能コマンドを正規表現で限定（例: Switch操作スクリプトのみ）。
- トークンや鍵をリポジトリにコミットしないこと。
