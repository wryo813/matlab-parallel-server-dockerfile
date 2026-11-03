#!/usr/bin/env python3
"""startjobmanager に管理者パスワードを、ログへ残さずに渡す。

startjobmanager は SECURITY_LEVEL>=2 でパスワードを /dev/tty から対話入力させる。
単純に `printf pass | script -c ...` とすると、子プロセスがエコーを無効化する前に
PTY がパスワードをそのままエコーし、コンテナログ (docker logs) に平文で残る。

このスクリプトは
  1. 自前で PTY を作ってコマンドを起動し、
  2. 出力にパスワードプロンプトが現れるまで待ち、
  3. PTY のエコーを無効にしてから パスワードを書き込み、
  4. 念のため出力中のパスワード文字列も伏せ字にして標準出力へ流す。
終了コードは子プロセスのものをそのまま返す。
"""
import argparse
import os
import pty
import re
import select
import signal
import sys
import termios
import time

REDACTED = b"********"


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--password-file", required=True, help="パスワードを 1 行で含むファイル (末尾の改行は除去する)")
    p.add_argument("--prompt-regex", default=r"password", help="パスワードプロンプトとみなす正規表現 (大文字小文字を区別しない)")
    p.add_argument("--prompt-timeout", type=float, default=180.0,
                   help="この秒数プロンプトが現れなければ、入力せずに子プロセスの終了を待つ")
    p.add_argument("--max-sends", type=int, default=3, help="プロンプトが繰り返されたときに再送する上限回数")
    p.add_argument("--overall-timeout", type=float, default=900.0, help="この秒数を超えたら子プロセスを強制終了する")
    p.add_argument("command", nargs=argparse.REMAINDER, help="-- の後に実行するコマンド")
    args = p.parse_args()
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command:
        p.error("実行するコマンドを -- の後に指定してください")
    return args


def read_password(path):
    with open(path, "rb") as f:
        data = f.read()
    return data.rstrip(b"\r\n")


def disable_echo(fd):
    attrs = termios.tcgetattr(fd)
    attrs[3] &= ~termios.ECHO  # lflag
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def main():
    args = parse_args()
    password = read_password(args.password_file)
    if not password:
        print("[feed-admin-password] パスワードファイルが空です", file=sys.stderr)
        return 2
    prompt_re = re.compile(args.prompt_regex.encode(), re.IGNORECASE)
    out = sys.stdout.buffer

    # 伏せ字処理は二段目の保護 (一段目はエコーの無効化)。短い文字列を伏せると
    # 無関係な出力まで壊れるので、6 文字未満のパスワードには適用しない。
    if len(password) >= 6:
        def redact(data):
            return data.replace(password, REDACTED)
    else:
        print("[feed-admin-password] 注意: パスワードが短いため出力の伏せ字処理を行いません", file=sys.stderr)
        def redact(data):
            return data

    pid, fd = pty.fork()
    if pid == 0:  # 子プロセス: PTY を制御端末として持つ
        os.execvp(args.command[0], args.command)

    start = time.time()
    sends = 0
    scan_from = 0          # 直近の送信以降に現れたプロンプトだけを数えるための位置
    window = b""           # プロンプト検出用に末尾だけ保持する
    status = None
    try:
        while True:
            now = time.time()
            if now - start > args.overall_timeout:
                print("[feed-admin-password] 全体タイムアウト。子プロセスを終了します", file=sys.stderr)
                os.kill(pid, signal.SIGTERM)
                break
            ready, _, _ = select.select([fd], [], [], 1.0)
            if fd in ready:
                try:
                    data = os.read(fd, 4096)
                except OSError:
                    break  # 子が終了して PTY が閉じた
                if not data:
                    break
                out.write(redact(data))
                out.flush()
                window = (window + data)[-8192:]
                scan_from = max(0, scan_from - max(0, len(window) + len(data) - 8192))
                if sends < args.max_sends and prompt_re.search(window, scan_from):
                    disable_echo(fd)
                    os.write(fd, password + b"\n")
                    sends += 1
                    scan_from = len(window)
            elif sends == 0 and now - start > args.prompt_timeout:
                print("[feed-admin-password] プロンプトが現れませんでした。入力せずに終了を待ちます", file=sys.stderr)
                args.prompt_timeout = float("inf")
            # 子プロセスが終わっていれば残りの出力を読み切って抜ける
            wpid, wstatus = os.waitpid(pid, os.WNOHANG)
            if wpid == pid:
                status = wstatus
                while True:
                    ready, _, _ = select.select([fd], [], [], 0.2)
                    if fd not in ready:
                        break
                    try:
                        data = os.read(fd, 4096)
                    except OSError:
                        break
                    if not data:
                        break
                    out.write(redact(data))
                    out.flush()
                break
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
    if status is None:
        _, status = os.waitpid(pid, 0)
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


if __name__ == "__main__":
    sys.exit(main())
