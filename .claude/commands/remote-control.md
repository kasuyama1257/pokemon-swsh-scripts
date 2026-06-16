---
description: 自宅PCのリモートコントロール・エージェントへコマンドを送り、結果を受け取る
argument-hint: <自宅PCで実行するシェルコマンド>
allowed-tools: Bash, Read, Write
---

## 役割

クラウド上のこのセッションから、自宅PCで常駐している
`remote-control/agent.py` へコマンドを送る。通信はGitリポジトリを
コマンドキューとして利用して行う（push でコマンド投入 → 自宅PCが pull
して実行 → 結果を push で返却 → こちらが pull で受け取る）。

自宅PCはNAT配下でよく、ポート開放は不要。クラウド↔自宅PCの直接接続は
行わず、すべて GitHub 経由の非同期通信になる。

## 実行するコマンド

ユーザーが指定したコマンド: `$ARGUMENTS`

`$ARGUMENTS` が空の場合は、自宅PCで何を実行したいかをユーザーに確認すること。

## 手順

1. 現在のブランチ名を取得する（エージェントが監視しているブランチに push する）:
   `git rev-parse --abbrev-ref HEAD`

2. 一意なコマンドIDを作る（例: `date +%Y%m%d-%H%M%S` に短いランダム文字列を付与）。

3. `remote-control/queue/<ID>.json` を作成する。フォーマット:
   ```json
   {
     "id": "<ID>",
     "created_at": "<ISO8601>",
     "command": "<$ARGUMENTS をそのまま>",
     "cwd": null,
     "timeout": 3600
   }
   ```
   - `cwd` は実行ディレクトリ。`null` ならリポジトリのルートで実行される。
     特定スクリプトを動かすだけなら省略してよい。
   - エージェント側で `REMOTE_CONTROL_TOKEN` を設定している場合は、
     同じ値を `"token"` フィールドに入れる必要がある。トークンが分からない
     場合はユーザーに確認する。リポジトリにトークンをハードコードしないこと。

4. commit して push する（ネットワーク失敗時は 2s,4s,8s,16s でリトライ）:
   ```
   git add remote-control/queue/<ID>.json
   git commit -m "remote-control: <短い説明> を投入"
   git push -u origin HEAD:<branch>
   ```

5. 投入したコマンドIDをユーザーに伝える。自宅PCのエージェントが
   ポーリング間隔（既定5秒）で拾って実行する。

6. 結果を取得する場合は、少し待ってから pull し、
   `remote-control/results/<ID>.json` を読む:
   ```
   git pull --rebase origin <branch>
   ```
   - 結果ファイルがまだ無ければ、エージェントが処理中。間隔を空けて
     再度 pull する（前景での `sleep` は使わず、ユーザーに「後で結果確認」と
     案内するか、Monitor ツールでファイル出現を待つ）。
   - 結果ファイルには `status`（completed/failed/timeout/rejected）、
     `exit_code`、`stdout`、`stderr` が入っている。要点を整形して報告する。

## 注意

- このコマンドはリポジトリ経由で自宅PCに任意コマンドを実行させる。
  対象リポジトリはプライベートにし、push権限者を信頼できる人に限ること。
- Switch操作スクリプト例:
  - `python3 egg-hatching.py --laps 20 /dev/ttyUSB0`
  - `python3 release.py --count 12 /dev/ttyUSB0`
  - `python3 tournament-battle.py --fight_time 150 /dev/ttyUSB0`
