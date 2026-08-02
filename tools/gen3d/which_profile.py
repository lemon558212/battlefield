#!/usr/bin/env python3
"""which_profile.py — 反推 output_textured/ 裡的 glb 是用哪個檔位生成的。

為什麼需要這支（2026-08-02）：
  gen3d 跑完不會在檔案裡留下「我用了哪個檔位」的紀錄，而 VRAM 偵測失敗時
  會靜默降級成 low。結果是跑完 17 件、看起來一切正常，實際上是最低品質——
  使用者一度以為手上那批是 TRELLIS.2 ultra，是從「貼圖只有 1024×1024」
  才反推出真相。這支把那次的反推方法固定下來，隨時可查、不必再猜。

判準（對照 gen3d.py 的 PROFILES）：
  ultra  trellis2      1536^3  減面 200k  貼圖 2048
  high   trellis2      1024^3  減面 150k  貼圖 2048
  medium hunyuan-full   512^3  減面 150k  貼圖 2048
  low    hunyuan-mini   512^3  減面 100k  貼圖 1024
貼圖邊長是最可靠的指紋：只有 low 是 1024，其餘都是 2048。
（減面後的三角數會被後續處理改動，不能單靠它判斷。）

用法：python tools/gen3d/which_profile.py [目錄]
      預設目錄 godot/output_textured
"""
import json
import os
import struct
import sys
import glob


def probe(path):
    """回傳 (skins, anims, tris, [貼圖尺寸字串])。只讀 glTF 的 JSON chunk。"""
    with open(path, "rb") as f:
        magic, _ver, _len = struct.unpack("<4sII", f.read(12))
        if magic != b"glTF":
            raise ValueError("不是 glb")
        clen, _ctype = struct.unpack("<I4s", f.read(8))
        js = json.loads(f.read(clen).decode("utf-8"))
        blen, _btype = struct.unpack("<I4s", f.read(8))
        bin_ = f.read(blen)

    tris = 0
    for m in js.get("meshes", []):
        for p in m.get("primitives", []):
            idx = p.get("indices")
            if idx is not None:
                tris += js["accessors"][idx]["count"] // 3

    sizes = []
    for im in js.get("images", []):
        bv = js["bufferViews"][im["bufferView"]]
        head = bin_[bv.get("byteOffset", 0):bv.get("byteOffset", 0) + 64]
        if head[:8] == b"\x89PNG\r\n\x1a\n":
            w, h = struct.unpack(">II", head[16:24])
            sizes.append("%dx%d" % (w, h))
        else:
            sizes.append("非PNG")
    return len(js.get("skins", [])), len(js.get("animations", [])), tris, sizes


def verdict(sizes):
    if not sizes:
        return "?（沒有內嵌貼圖）"
    edge = sizes[0].split("x")[0]
    if edge == "1024":
        return "low（hunyuan-mini）★最低品質"
    if edge == "2048":
        return "ultra/high/medium 之一（貼圖 2048，需看形狀細節區分）"
    return "?（貼圖 %s，不在已知檔位）" % sizes[0]


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else os.path.join("godot", "output_textured")
    files = sorted(glob.glob(os.path.join(d, "*.glb")))
    if not files:
        print("找不到 glb：%s" % d)
        return 1
    print("%-16s %5s %5s %8s  %-11s %s" % ("檔案", "skin", "anim", "三角", "貼圖", "推定檔位"))
    print("-" * 88)
    tally = {}
    for fn in files:
        try:
            sk, an, tris, sizes = probe(fn)
        except Exception as e:
            print("%-16s 讀取失敗：%s" % (os.path.basename(fn), e))
            continue
        v = verdict(sizes)
        tally[v] = tally.get(v, 0) + 1
        print("%-16s %5d %5d %8d  %-11s %s"
              % (os.path.basename(fn), sk, an, tris,
                 sizes[0] if sizes else "-", v))
    print()
    for k, n in sorted(tally.items(), key=lambda kv: -kv[1]):
        print("  %d 件 → %s" % (n, k))
    # 角色能不能直接上場，取決於有沒有骨架（載具不需要）
    print()
    print("提醒：skin=0 ＝沒有骨架。載具不需要骨架可直接用；")
    print("      角色必須先綁骨（Mixamo 手動上傳，或改走 Tripo 從立繪重生成）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
