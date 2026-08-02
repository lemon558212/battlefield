# -*- coding: utf-8 -*-
"""glb_silhouette.py — 純 numpy+PIL 的三視圖剪影（不需要 trimesh／matplotlib／GPU）。

存在理由：載具模型接進遊戲前必須確認**車頭朝哪個軸**。只看 AABB 分不出
「機身長 1.9m」與「翼展 1.9m」，但俯視剪影一眼就看得出來。
本機沒有 trimesh（那台 64GB 的機器已經不在了），所以這支自己解 GLB 的
POSITION accessor，用點雲潑點畫剪影——夠回答「朝向對不對」這一個問題。

輸出：上（俯視 XZ）／側（XY）／前（ZY）三張並排，附 1m 刻度線。

用法：python tools/glb_silhouette.py <in.glb> <out.png> [縮放前的真實長度m]
"""
import json
import struct
import sys

import numpy as np
from PIL import Image, ImageDraw

sys.stdout.reconfigure(encoding="utf-8")

CTYPE = {5126: ("<f4", 4), 5123: ("<u2", 2), 5125: ("<u4", 4)}


def load_positions(path: str) -> np.ndarray:
    with open(path, "rb") as f:
        blob = f.read()
    _magic, _ver, _total = struct.unpack_from("<4sII", blob, 0)
    off = 12
    gj = None
    binc = None
    while off < len(blob):
        clen, ctype = struct.unpack_from("<I4s", blob, off)
        data = blob[off + 8: off + 8 + clen]
        if ctype == b"JSON":
            gj = json.loads(data.decode("utf-8"))
        elif ctype == b"BIN\x00":
            binc = data
        off += 8 + clen + (-clen % 4)
    pts = []
    for m in gj.get("meshes", []):
        for p in m.get("primitives", []):
            acc = gj["accessors"][p["attributes"]["POSITION"]]
            bv = gj["bufferViews"][acc["bufferView"]]
            fmt, sz = CTYPE[acc["componentType"]]
            start = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
            stride = bv.get("byteStride", 0) or sz * 3
            raw = np.frombuffer(binc, dtype=np.uint8,
                                count=stride * acc["count"], offset=start)
            arr = raw.reshape(acc["count"], stride)[:, : sz * 3].copy()
            pts.append(arr.view(fmt).reshape(-1, 3))
    return np.concatenate(pts, axis=0)


def panel(pts: np.ndarray, ax_h: int, ax_v: int, size: int, flip_v: bool,
          title: str, scale: float) -> Image.Image:
    img = Image.new("RGB", (size, size), (18, 20, 24))
    d = ImageDraw.Draw(img)
    h, v = pts[:, ax_h], pts[:, ax_v]
    span = max(h.max() - h.min(), v.max() - v.min(), 1e-6) * 1.15
    cx, cy = (h.max() + h.min()) / 2, (v.max() + v.min()) / 2
    px = ((h - cx) / span + 0.5) * size
    py = ((v - cy) / span + 0.5) * size
    if flip_v:
        py = size - py
    ix = np.clip(px.astype(np.int32), 0, size - 1)
    iy = np.clip(py.astype(np.int32), 0, size - 1)
    buf = np.zeros((size, size), dtype=np.int32)
    np.add.at(buf, (iy, ix), 1)
    dens = np.clip(buf * 90, 0, 255).astype(np.uint8)
    rgb = np.dstack([dens, np.clip(dens * 1.05, 0, 255).astype(np.uint8), dens])
    img = Image.fromarray(np.maximum(np.asarray(img), rgb))
    d = ImageDraw.Draw(img)
    # 1m 刻度（依真實長度換算：模型被正規化過，span 是模型單位）
    if scale > 0:
        bar = size / span * (1.0 / scale)     # 1 公尺在畫面上多少像素
        d.line([(12, size - 14), (12 + bar, size - 14)], fill=(255, 210, 90), width=3)
        d.text((12, size - 30), "1m", fill=(255, 210, 90))
    d.text((10, 8), title, fill=(140, 220, 255))
    return img


def main() -> int:
    src, dst = sys.argv[1], sys.argv[2]
    real_len = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
    pts = load_positions(src)
    lo, hi = pts.min(axis=0), pts.max(axis=0)
    size_v = hi - lo
    # 模型單位 → 公尺的比例：真實長度 / 模型最長軸
    scale = (max(size_v) / real_len) if real_len > 0 else 0.0
    panels = [
        panel(pts, 0, 2, 420, True, "俯視 (X橫/Z縱, 上=+Z)", scale),
        panel(pts, 2, 1, 420, True, "側視 (Z橫/Y縱)", scale),
        panel(pts, 0, 1, 420, True, "前視 (X橫/Y縱)", scale),
    ]
    out = Image.new("RGB", (420 * 3 + 16, 420), (10, 11, 13))
    for i, p in enumerate(panels):
        out.paste(p, (i * (420 + 8), 0))
    out.save(dst)
    print(f"[sil] {src}  X={size_v[0]:.3f} Y={size_v[1]:.3f} Z={size_v[2]:.3f}"
          f"  點數={len(pts)}  -> {dst}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
