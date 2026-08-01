# -*- coding: utf-8 -*-
"""fill_unpainted.py — 補救「多視角上色沒覆蓋到」的區域。

為什麼需要：Hunyuan 的貼圖是把幾個視角的成像投影回 UV，
立繪是 3/4 俯視，模型的**側下方與底部完全沒有資訊**，那些 texel 留白。
遊戲裡看到的就是坦克側裙一大片死白（實拍抓到，且整台未切分時也一樣，
所以不是切分造成的）。

作法：把近白且低飽和的 texel 視為未上色，用最近的已上色 texel 填補
（不是塗單一色——保留鄰近的迷彩紋理，接縫才不明顯）。
⚠ 會印出被判定為未上色的比例：比例過高代表上色階段根本失敗，
  那要回頭修上色，不是靠這支遮掩（不做靜默補救）。

用法：python tools/fill_unpainted.py <in.glb> <out.glb> [白判準V] [飽和上限S]
"""
import struct
import sys
import json
import io

import numpy as np
from PIL import Image
import trimesh


def main():
    src, dst = sys.argv[1], sys.argv[2]
    v_th = float(sys.argv[3]) if len(sys.argv) > 3 else 0.90
    s_th = float(sys.argv[4]) if len(sys.argv) > 4 else 0.12

    mesh = trimesh.load(src, force="mesh")
    vis = getattr(mesh, "visual", None)
    img = getattr(getattr(vis, "material", None), "baseColorTexture", None)
    if img is None:
        print("[fill] FAIL 這個 glb 沒有 baseColorTexture，無從補起")
        return 1
    a = np.asarray(img.convert("RGB")).astype(np.float32) / 255.0
    mx = a.max(axis=2)
    mn = a.min(axis=2)
    sat = np.where(mx > 1e-6, (mx - mn) / np.maximum(mx, 1e-6), 0.0)
    blank = (mx > v_th) & (sat < s_th)
    pct = float(blank.mean()) * 100.0
    print(f"[fill] 未上色 texel {pct:.1f}%（判準 V>{v_th} 且 S<{s_th}）")
    if pct < 0.5:
        print("[fill] 幾乎沒有留白，直接輸出原檔")
        mesh.export(dst)
        return 0
    if pct > 60.0:
        print("[fill] FAIL 留白超過 60%——上色階段根本沒成功，"
              "回頭查上色，不要用補色遮掩")
        return 1

    # ⚠ 第一版用「UV 空間的最近鄰」填補，結果側面變成一片粉彩雜色——
    #   **UV 圖集上相鄰的島嶼，在模型表面上根本不相鄰**，抓到的是毫不相干的顏色。
    #   改用已上色區域的中位色填滿：車體下半、側裙、底盤在現實中本來就是素色，
    #   均勻一片比錯誤的紋理正確得多。再加一點點雜訊，避免看起來像塑膠。
    base = np.median(a[~blank], axis=0) * 0.80      # 壓暗：側下方本來就在陰影裡
    rng = np.random.default_rng(20260801)
    noise = rng.normal(0.0, 0.018, size=a.shape)
    fillcol = np.clip(base[None, None, :] + noise, 0.0, 1.0)
    out = np.where(blank[..., None], fillcol, a)
    print(f"[fill] 填補色 RGB({base[0]:.2f},{base[1]:.2f},{base[2]:.2f})")

    new_img = Image.fromarray((out * 255).astype(np.uint8))
    mesh.visual.material.baseColorTexture = new_img
    mesh.export(dst)
    print(f"[fill] 已補 {pct:.1f}% 的 texel -> {dst}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
