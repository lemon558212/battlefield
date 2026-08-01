# -*- coding: utf-8 -*-
"""preview_mesh.py — 純 CPU 的網格預覽算圖（不佔 GPU、不需要 Godot）。

存在理由：跑批期間絕不可再開 Godot（會撞掉批次），而生成模型的形狀好壞
必須先看過才知道要不要繼續往下做。用 matplotlib 做簡單的平行投影＋朗伯著色，
畫面不漂亮，但「輪廓對不對、細節有沒有出來」這件事看得出來。

用法：python tools/preview_mesh.py <mesh.glb> <out.png> [每視角面數上限]
"""
import sys
import numpy as np
import trimesh
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection

VIEWS = [(20, -60), (20, 30), (20, 120), (70, -60)]   # (仰角, 方位角)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    cap = int(sys.argv[3]) if len(sys.argv) > 3 else 30000
    m = trimesh.load(src, force="mesh")
    if len(m.faces) > cap:
        import fast_simplification as fs
        v, f = fs.simplify(m.vertices, m.faces, target_count=cap)
        m = trimesh.Trimesh(vertices=v, faces=f)
        m.fix_normals()
    print(f"[prev] {src}: {len(m.faces)} 面（預覽用）")
    # ⚠ glTF 是 Y 向上、matplotlib 3D 是 Z 向上：三角形座標要換軸，
    #   只改座標軸範圍不換頂點的話，模型會被立起來（第一版實拍到坦克站著）。
    tris = m.vertices[m.faces][:, :, [0, 2, 1]]
    nrm = m.face_normals[:, [0, 2, 1]]
    fig = plt.figure(figsize=(16, 4.2), dpi=110)
    for i, (elev, azim) in enumerate(VIEWS):
        ax = fig.add_subplot(1, len(VIEWS), i + 1, projection="3d")
        # 朗伯著色：光從左上前方來
        L = np.array([0.5, 0.8, 0.35])
        L = L / np.linalg.norm(L)
        shade = np.clip(nrm @ L, 0.0, 1.0) * 0.75 + 0.25
        cols = np.stack([shade * 0.62, shade * 0.66, shade * 0.58], axis=1)
        pc = Poly3DCollection(tris, facecolors=cols, edgecolors="none")
        ax.add_collection3d(pc)
        lo, hi = m.bounds
        c = ((lo + hi) / 2.0)[[0, 2, 1]]
        r = float(np.max(hi - lo)) * 0.55
        ax.set_xlim(c[0] - r, c[0] + r)
        ax.set_ylim(c[1] - r, c[1] + r)
        ax.set_zlim(c[2] - r, c[2] + r)
        ax.view_init(elev=elev, azim=azim)
        ax.set_axis_off()
        try:
            ax.set_box_aspect((1, 1, 1))
        except Exception:
            pass
    plt.tight_layout(pad=0.1)
    plt.savefig(dst, facecolor="#6f8f6a")
    print("[prev] saved ->", dst)


if __name__ == "__main__":
    main()
