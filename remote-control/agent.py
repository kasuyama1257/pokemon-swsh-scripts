#!/usr/bin/env python3
"""自宅PCで常駐させるリモートコントロール・エージェント。

Gitリポジトリを「コマンドキュー」として利用し、クラウド上のClaude Codeセッション
（/remote-control コマンド）から送られてきたコマンドを自宅PCで実行する。

仕組み:
  1. 一定間隔でリモートブランチを fetch / rebase pull する
  2. remote-control/queue/*.json に未処理のコマンドがあれば実行する
  3. 実行結果を remote-control/results/<id>.json に書き出す
  4. キューのファイルを削除し、結果と合わせて commit / push する

自宅PCはNAT配下でもよい（外向きのgit pull/pushだけで完結し、ポート開放は不要）。

セキュリティ上の注意:
  このエージェントはリポジトリに push された任意のシェルコマンドを実行する。
  対象リポジトリへ push 権限を持つ人物は誰でも自宅PCを操作できることを意味する。
  - プライベートリポジトリで運用すること
  - 不特定多数とコラボするリポジトリでは使わないこと
  - REMOTE_CONTROL_TOKEN を設定すると、トークンが一致するコマンドのみ実行する
  - --allowlist で実行可能なコマンドを正規表現で制限できる
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

QUEUE_DIRNAME = "queue"
RESULTS_DIRNAME = "results"


def log(msg):
    now = datetime.datetime.now().isoformat(timespec="seconds")
    print(f"[{now}] {msg}", flush=True)


def run_git(repo_dir, args, check=True, retries=0):
    """gitコマンドを実行する。ネットワーク系は指数バックオフでリトライする。"""
    delay = 2
    last = None
    for attempt in range(retries + 1):
        last = subprocess.run(
            ["git", "-C", str(repo_dir), *args],
            capture_output=True,
            text=True,
        )
        if last.returncode == 0:
            return last
        if attempt < retries:
            log(f"git {' '.join(args)} 失敗（{delay}秒後に再試行）: {last.stderr.strip()}")
            time.sleep(delay)
            delay *= 2
    if check and last.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} 失敗: {last.stderr.strip()}")
    return last


def sync_pull(repo_dir, branch):
    """リモートの最新を取り込む。ローカル変更は退避してから取り込む。"""
    run_git(repo_dir, ["fetch", "origin", branch], retries=4)
    # 結果ファイル等のローカル差分が残っている場合に備えてリベースで取り込む
    run_git(repo_dir, ["rebase", f"origin/{branch}"], check=False)


def commit_and_push(repo_dir, branch, message):
    run_git(repo_dir, ["add", "-A"])
    status = run_git(repo_dir, ["status", "--porcelain"]).stdout.strip()
    if not status:
        return False
    run_git(repo_dir, ["commit", "-m", message])
    # push前にもう一度取り込み、競合を避ける
    run_git(repo_dir, ["fetch", "origin", branch], retries=4)
    run_git(repo_dir, ["rebase", f"origin/{branch}"], check=False)
    run_git(repo_dir, ["push", "origin", f"HEAD:{branch}"], retries=4)
    return True


def load_allowlist(path):
    if not path:
        return None
    patterns = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        patterns.append(re.compile(line))
    return patterns


def is_allowed(command, allowlist):
    if allowlist is None:
        return True
    return any(p.search(command) for p in allowlist)


def execute(command, cwd, timeout):
    started = datetime.datetime.now()
    try:
        proc = subprocess.run(
            command,
            shell=True,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        status = "completed"
        exit_code = proc.returncode
        stdout, stderr = proc.stdout, proc.stderr
    except subprocess.TimeoutExpired as e:
        status = "timeout"
        exit_code = None
        stdout = e.stdout or ""
        stderr = (e.stderr or "") + f"\n[timeout after {timeout}s]"
    finished = datetime.datetime.now()
    return {
        "status": status,
        "exit_code": exit_code,
        "stdout": stdout,
        "stderr": stderr,
        "started_at": started.isoformat(timespec="seconds"),
        "finished_at": finished.isoformat(timespec="seconds"),
    }


def process_queue(repo_dir, rc_dir, branch, token, allowlist, default_timeout):
    queue_dir = rc_dir / QUEUE_DIRNAME
    results_dir = rc_dir / RESULTS_DIRNAME
    results_dir.mkdir(parents=True, exist_ok=True)

    pending = sorted(p for p in queue_dir.glob("*.json"))
    processed_any = False

    for cmd_path in pending:
        try:
            cmd = json.loads(cmd_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            log(f"不正なコマンドファイルをスキップ: {cmd_path.name} ({e})")
            cmd_path.unlink()
            processed_any = True
            continue

        cmd_id = cmd.get("id", cmd_path.stem)
        command = cmd.get("command", "")
        cwd = cmd.get("cwd") or str(repo_dir)
        timeout = cmd.get("timeout", default_timeout)

        result = {"id": cmd_id, "command": command, "cwd": cwd}

        if token and cmd.get("token") != token:
            log(f"トークン不一致のためスキップ: {cmd_id}")
            result.update(
                status="rejected",
                exit_code=None,
                stdout="",
                stderr="REMOTE_CONTROL_TOKEN が一致しません",
                started_at=None,
                finished_at=datetime.datetime.now().isoformat(timespec="seconds"),
            )
        elif not is_allowed(command, allowlist):
            log(f"allowlist非該当のためスキップ: {cmd_id}: {command}")
            result.update(
                status="rejected",
                exit_code=None,
                stdout="",
                stderr="allowlistに一致しないコマンドです",
                started_at=None,
                finished_at=datetime.datetime.now().isoformat(timespec="seconds"),
            )
        else:
            log(f"実行: [{cmd_id}] {command}")
            result.update(execute(command, cwd, timeout))
            log(f"完了: [{cmd_id}] status={result['status']} exit={result['exit_code']}")

        (results_dir / f"{cmd_id}.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        cmd_path.unlink()
        processed_any = True

    if processed_any:
        commit_and_push(repo_dir, branch, "remote-control: コマンド実行結果を更新")

    return processed_any


def current_branch(repo_dir):
    return run_git(repo_dir, ["rev-parse", "--abbrev-ref", "HEAD"]).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description="自宅PC用リモートコントロール・エージェント")
    parser.add_argument(
        "--repo-dir",
        default=str(Path(__file__).resolve().parent.parent),
        help="対象gitリポジトリのパス（デフォルト: このスクリプトのリポジトリ）",
    )
    parser.add_argument(
        "--branch",
        default=None,
        help="キューを監視するブランチ（デフォルト: 現在のブランチ）",
    )
    parser.add_argument("--interval", type=int, default=5, help="ポーリング間隔（秒）")
    parser.add_argument(
        "--timeout",
        type=int,
        default=3600,
        help="コマンド側でtimeout指定が無い場合の既定タイムアウト（秒）",
    )
    parser.add_argument(
        "--allowlist",
        default=None,
        help="実行を許可するコマンドの正規表現を1行ずつ書いたファイル",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="ループせず1回だけキューを処理して終了する",
    )
    args = parser.parse_args()

    repo_dir = Path(args.repo_dir).resolve()
    rc_dir = repo_dir / "remote-control"
    branch = args.branch or current_branch(repo_dir)
    token = os.environ.get("REMOTE_CONTROL_TOKEN")
    allowlist = load_allowlist(args.allowlist)

    log(f"リモートコントロール・エージェント起動")
    log(f"  リポジトリ: {repo_dir}")
    log(f"  ブランチ  : {branch}")
    log(f"  間隔      : {args.interval}秒")
    log(f"  トークン  : {'有効' if token else '未設定'}")
    log(f"  allowlist : {args.allowlist or '無し（任意コマンド実行可）'}")
    if not token and allowlist is None:
        log("警告: トークン・allowlistとも未設定です。push権限者は任意コマンドを実行できます。")

    while True:
        try:
            sync_pull(repo_dir, branch)
            process_queue(repo_dir, rc_dir, branch, token, allowlist, args.timeout)
        except Exception as e:  # noqa: BLE001 - 常駐のため落とさない
            log(f"エラー: {e}")
        if args.once:
            break
        time.sleep(args.interval)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("停止しました")
        sys.exit(0)
