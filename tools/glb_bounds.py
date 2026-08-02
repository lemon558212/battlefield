# -*- coding: utf-8 -*-
"""glb_bounds.py — 不裝 trimesh 也能量 glb 的尺寸與朝向。

為什麼要有這支：載具模型接進遊戲前一定要先確認「長邊在哪個軸」。
Unit._try_build_from_art 是拿 **size.z 當車長**縮放的，模型若長邊在 X，
縮出來會變成一台又扁又長的怪物（而且碰撞盒跟著錯）。

glTF 的 POSITION accessor 自帶 min/max，所以量 AABB 根本不用解三角形，
純標準函式庫讀 GLB 的 JSON chunk 就夠了——這也是為什麼這支不需要 trimesh。
⚠ 只看 accessor 的 min/max＝**節點區域座標**；若 glb 內有非單位的節點變換，
數字會偏。本專案的生成模型都是單一 mesh、單位變換，故足夠；
會用到節點變換的模型這支會印警告，別直接信。

用法：python tools/glb_bounds.py <file.glb> [more.glb ...]
"""
import json
import struct
import sys


def read_glb_json(path: str) -> dict:
    with open(path, "rb") as f:
        magic, _ver, _len = struct.unpack("<4sII", f.read(12))
        if magic != b"glTF":
            raise ValueError(f"{path} 不是 GLB（magic={magic!r}）")
        clen, ctype = struct.unpack("<I4s", f.read(8))
        if ctype != b"JSON":
            raise ValueError(f"{path} 第一個 chunk 不是 JSON")
        return json.loads(f.read(clen).decode("utf-8"))


def bounds(g: dict):
    lo = [float("inf")] * 3
    hi = [float("-inf")] * 3
    tris = 0
    uv = False
    for m in g.get("meshes", []):
        for p in m.get("primitives", []):
            attrs = p.get("attributes", {})
            if "TEXCOORD_0" in attrs:
                uv = True
            acc = g["accessors"][attrs["POSITION"]]
            for i in range(3):
                lo[i] = min(lo[i], acc["min"][i])
                hi[i] = max(hi[i], acc["max"][i])
            if "indices" in p:
                tris += g["accessors"][p["indices"]]["count"] // 3
            else:
                tris += acc["count"] // 3
    return lo, hi, tris, uv


def main() -> int:
    bad = 0
    for path in sys.argv[1:]:
        g = read_glb_json(path)
        for n in g.get("nodes", []):
            if any(k in n for k in ("matrix", "rotation", "scale")):
                print(f"[glb] ⚠ {path} 有節點變換，以下數字是區域座標、可能不準")
                break
        lo, hi, tris, uv = bounds(g)
        s = [hi[i] - lo[i] for i in range(3)]
        axis = "XYZ"[max(range(3), key=lambda i: s[i])]
        img = len(g.get("images", []))
        print(f"{path}\n    尺寸 X={s[0]:.3f} Y={s[1]:.3f} Z={s[2]:.3f}"
              f"  最長軸={axis}  三角={tris}  UV={'有' if uv else '無'}  貼圖={img}")
        print(f"    底面 Y={lo[1]:.3f}  中心 X={(lo[0]+hi[0])/2:.3f} Z={(lo[2]+hi[2])/2:.3f}")
        if axis != "Z":
            bad += 1
    if bad:
        print(f"[glb] ⚠ {bad} 件的最長軸不是 Z——接進遊戲前要先轉正"
              f"（Unit._try_build_from_art 用 size.z 當車長）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
