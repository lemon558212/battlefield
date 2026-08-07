# -*- coding: utf-8 -*-
"""glb_rest_pose.py — 量 glb 骨架**rest 姿勢**的脊椎傾角（不需要 Godot、不吃 GPU）。

存在理由：追「立繪本人模型上身前傾 30~45°」時，有兩種可能長得一模一樣——
  (A) 差量轉印沿骨鏈把 rest 方向差累積起來
  (B) **模型本身的 rest 姿勢就是前傾的**（那就不是轉印的錯，改轉印永遠修不好）
兩者只能靠「量 rest 本身」分辨。rest 就寫在 glb 的節點階層裡，解 JSON 就能算。

作法：從 skin 的 joints 找出骨架節點，累乘 TRS 得到每根骨的 rest 世界座標，
再取骨盆→頸部這條線與**垂直軸**的夾角。人站直時這個角接近 0。

用法：python3 tools/glb_rest_pose.py <model.glb> [骨名關鍵字...]
"""
import json
import struct
import sys

import numpy as np

sys.stdout.reconfigure(encoding="utf-8")


def read_glb(path):
    with open(path, "rb") as f:
        blob = f.read()
    off = 12
    gj = None
    while off < len(blob):
        clen, ctype = struct.unpack_from("<I4s", blob, off)
        if ctype == b"JSON":
            gj = json.loads(blob[off + 8: off + 8 + clen].decode("utf-8"))
            break
        off += 8 + clen + (-clen % 4)
    return gj


def trs(node):
    t = np.array(node.get("translation", [0, 0, 0]), dtype=float)
    r = node.get("rotation", [0, 0, 0, 1])
    s = np.array(node.get("scale", [1, 1, 1]), dtype=float)
    x, y, z, w = r
    rot = np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])
    m = np.eye(4)
    m[:3, :3] = rot * s
    m[:3, 3] = t
    return m


def main() -> int:
    src = sys.argv[1]
    keys = [k.lower() for k in sys.argv[2:]] or [
        "pelvis", "hip", "spine", "chest", "neck", "head"]
    g = read_glb(src)
    nodes = g.get("nodes", [])
    if "matrix" in json.dumps(nodes)[:200000] and any("matrix" in n for n in nodes):
        print("⚠ 有節點用 matrix 表示變換，本工具只解 TRS，數字可能不準")
    parent = {}
    for i, n in enumerate(nodes):
        for c in n.get("children", []):
            parent[c] = i
    world = {}

    def wm(i):
        if i in world:
            return world[i]
        m = trs(nodes[i])
        if i in parent:
            m = wm(parent[i]) @ m
        world[i] = m
        return m

    joints = []
    for sk in g.get("skins", []):
        joints += sk.get("joints", [])
    if not joints:
        joints = list(range(len(nodes)))
    picked = []
    for j in joints:
        nm = str(nodes[j].get("name", ""))
        if any(k in nm.lower() for k in keys):
            picked.append((nm, wm(j)[:3, 3]))
    if not picked:
        print("找不到脊椎相關骨（骨名關鍵字可自行指定）")
        for j in joints[:24]:
            print("   骨名：", nodes[j].get("name"))
        return 1
    picked.sort(key=lambda kv: kv[1][1])          # 由低到高（Y 向上）
    print(f"[rest] {src}")
    for nm, p in picked:
        print("   %-16s 位置 (%.3f, %.3f, %.3f)" % (nm, p[0], p[1], p[2]))
    lo, hi = picked[0][1], picked[-1][1]
    v = hi - lo
    if np.linalg.norm(v) < 1e-6:
        print("   脊椎長度為 0，量不出來")
        return 1
    up = np.array([0.0, 1.0, 0.0])
    tilt = np.degrees(np.arccos(np.clip(v @ up / np.linalg.norm(v), -1, 1)))
    fwd = np.degrees(np.arctan2(v[2], v[1]))      # 往 +Z（前）倒多少
    print("   ── 骨盆→頸 這條線：與垂直軸夾角 %.1f°，前後傾 %.1f°（正=往 +Z 倒）"
          % (tilt, fwd))
    print("   判讀：站直的 rest 應該接近 0°。若這裡就有 30~45°，"
          "那是**模型本身的 rest 就前傾**，改轉印永遠修不好。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
