# -*- coding: utf-8 -*-
"""
clip_preview.py  -  .clip（Clip Studio Paint）ファイルから埋め込みプレビュー画像(PNG)を取り出す

使い方:  python clip_preview.py <入力.clip> <出力.png>
終了コード: 0=成功 / 1=失敗（詳細は標準エラー出力）

仕組み: .clip は「CSFCHUNK」で始まるチャンク構造で、CHNKSQLi チャンクの中身が
SQLiteデータベースになっている。その CanvasPreview.ImageData にPNGが入っている。
大きなピクセルデータ(CHNKExta)は読まずに seek で飛ばすので、数十MBのファイルでも速い。
標準ライブラリだけで動く（追加インストール不要）。
"""
import os
import sqlite3
import struct
import sys
import tempfile


def extract_sqlite_chunk(path):
    with open(path, "rb") as f:
        head = f.read(24)
        if head[:8] != b"CSFCHUNK":
            raise ValueError("CSFCHUNK ではありません（.clipファイルではない）")
        first = struct.unpack(">Q", head[16:24])[0]   # 最初のチャンクまでのオフセット
        f.seek(first)
        while True:
            h = f.read(16)
            if len(h) < 16 or not h.startswith(b"CHNK"):
                raise ValueError("SQLiteチャンクが見つかりません")
            size = struct.unpack(">Q", h[8:16])[0]
            if h[:8] == b"CHNKSQLi":
                return f.read(size)
            f.seek(size, os.SEEK_CUR)


def extract_preview(src, dst):
    blob = extract_sqlite_chunk(src)
    fd, tmp = tempfile.mkstemp(suffix=".db")
    try:
        with os.fdopen(fd, "wb") as t:
            t.write(blob)
        con = sqlite3.connect(tmp)
        try:
            row = con.execute("SELECT ImageData FROM CanvasPreview LIMIT 1").fetchone()
        finally:
            con.close()
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass
    if not row or not row[0]:
        raise ValueError("CanvasPreview にプレビュー画像がありません")
    data = bytes(row[0])
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("プレビューがPNG形式ではありません")
    out_dir = os.path.dirname(os.path.abspath(dst))
    os.makedirs(out_dir, exist_ok=True)
    with open(dst, "wb") as o:
        o.write(data)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: clip_preview.py <input.clip> <output.png>", file=sys.stderr)
        sys.exit(1)
    try:
        extract_preview(sys.argv[1], sys.argv[2])
    except Exception as e:
        print("ERROR: %s" % e, file=sys.stderr)
        sys.exit(1)
