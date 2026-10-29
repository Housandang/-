# -*- coding: utf-8 -*-
"""
audio_lock.py  -  ロック中、指定したアプリ以外の音を自動でミュートし続ける

必要なもの:  pip install pycaw     （psutil と comtypes も一緒に入る）

使い方:
  python audio_lock.py run --exempt Spotify.exe --parent-pid 1234 [--interval 2]
      数秒おきに、除外リスト以外の全アプリのミュートを確認して、鳴っている（ミュートされていない）
      ものをミュートする。ミュートしたアプリは audio_lock_state.json に記録する。
      親プロセス（lock_window.ahk）が居なくなったら、ミュートしたものを元に戻して終了する。
  python audio_lock.py restore
      audio_lock_state.json に記録されたアプリのミュートを解除して、記録を消す。
      （lock_window.ahk が休憩に入るとき・終了時・起動時に呼ぶ。異常終了でミュートが残るのを防ぐ）

方針:
  ・もともとユーザーがミュートしていたアプリには触らない（記録しない＝解除もしない）
  ・システム音（通知音など）のセッションは対象外
  ・異常があれば audio_lock_error.log に追記する
"""
import argparse
import datetime
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_PATH = os.path.join(HERE, "audio_lock_state.json")
ERROR_LOG = os.path.join(HERE, "audio_lock_error.log")


def log_error(msg):
    try:
        with open(ERROR_LOG, "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg))
    except OSError:
        pass


def load_state():
    try:
        with open(STATE_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        return [(int(d["pid"]), str(d["name"])) for d in data]
    except (OSError, ValueError, KeyError, TypeError):
        return []


def save_state(entries):
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump([{"pid": p, "name": n} for p, n in sorted(entries)], f)
    os.replace(tmp, STATE_PATH)   # 書き込み途中の状態を読まれないように置き換える


def clear_state():
    try:
        os.remove(STATE_PATH)
    except OSError:
        pass


def iter_sessions():
    """(pid, プロセス名(小文字), SimpleAudioVolume) を返す。システム音は含めない。"""
    from pycaw.pycaw import AudioUtilities
    for s in AudioUtilities.GetAllSessions():
        proc = s.Process
        if proc is None:
            continue
        try:
            name = proc.name()
        except Exception:
            continue
        yield s.ProcessId, name.lower(), s.SimpleAudioVolume


def mute_pass(exempt, muted):
    """除外以外のセッションをミュートする。muted（set）に自分がミュートしたものを追加する。"""
    changed = False
    for pid, name, vol in iter_sessions():
        if name in exempt or (pid, name) in muted:
            continue
        try:
            if vol.GetMute():
                continue                      # もともとミュート済み → 触らない
            vol.SetMute(1, None)
            muted.add((pid, name))
            changed = True
        except Exception as e:
            log_error("mute失敗 %s(%s): %s" % (name, pid, e))
    return changed


def restore_all():
    entries = set(load_state())
    if not entries:
        clear_state()
        return
    for pid, name, vol in iter_sessions():
        if (pid, name) in entries:
            try:
                vol.SetMute(0, None)
            except Exception as e:
                log_error("unmute失敗 %s(%s): %s" % (name, pid, e))
    clear_state()


def run(exempt, parent_pid, interval):
    import psutil
    muted = set(load_state())     # 前回の記録があれば引き継ぐ（残っていても最後に必ず戻せるように）
    try:
        while True:
            if parent_pid and not psutil.pid_exists(parent_pid):
                break
            try:
                if mute_pass(exempt, muted):
                    save_state(muted)
            except Exception as e:
                log_error("巡回中の例外: %s" % e)
            time.sleep(interval)
    finally:
        try:
            save_state(muted)
            restore_all()
        except Exception as e:
            log_error("終了時のrestoreで例外: %s" % e)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--exempt", default="", help="ミュートしないプロセス名（カンマ区切り。例: Spotify.exe）")
    r.add_argument("--parent-pid", type=int, default=0)
    r.add_argument("--interval", type=float, default=2.0)
    sub.add_parser("restore")
    a = ap.parse_args()
    try:
        if a.cmd == "run":
            exempt = {x.strip().lower() for x in a.exempt.split(",") if x.strip()}
            run(exempt, a.parent_pid, a.interval)
        else:
            restore_all()
    except ImportError as e:
        log_error("必要なライブラリがありません（pip install pycaw）: %s" % e)
        sys.exit(2)
    except Exception as e:
        log_error("致命的な例外: %s" % e)
        sys.exit(1)


if __name__ == "__main__":
    main()
