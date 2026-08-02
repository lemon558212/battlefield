# -*- coding: utf-8 -*-
"""align_vehicle.py — 量出生成載具模型的「轉正角度」，輸出成 vehicle_look.json 的 rot_deg。

## 為什麼需要

`Unit._try_build_from_art` 是拿 **模型 AABB 的 size.z 當車長** 縮放、
拿 size.x/size.z 當碰撞盒的。生成出來的模型**朝向是隨機的**（實測：戰鬥機在
3D 裡被任意旋轉），照原樣接進去會同時錯三件事：車長縮放、碰撞盒、車頭朝向
（開起來是螃蟹走路）。所以接模型前必須先量出轉正角。

## 量法（不用猜、可驗算）

**載具都有左右對稱面**——比 AABB 可靠得多的訊號。
1. 直接**搜對稱平面的法向量** n（方位角×仰角掃半球）：把點雲對該平面鏡射，
   比體素占用的重合度。⚠ 生成模型是**薄殼**，兩層薄殼幾乎不會格格對上，
   所以比對前先把占用格膨脹一格，否則分數全部貼在雜訊底線上分不出高下。
   （第一版沒膨脹：已對正的坦克只有 0.398，跟歪掉的模型分不開。）
2. 把 n 轉到 X 軸。平面內剩下的自由度用 PCA 決定：最長軸→Z（車身細長）、次軸→Y。
3. 車頭朝 +Z 還是 -Z，對稱性分辨不出來（差 180 度一樣對稱）——
   這一步**只能看圖**，故本工具輸出轉正後三視圖讓人眼判，要掉頭就加 `--flip`。
   同理上下用原模型的 +Y 當參考（生成模型都是 Y 朝上的）。

輸出的 rot_deg 直接對應 Godot 的 `rotation_degrees`（Node3D 預設 Euler 序 YXZ），
本工具的矩陣分解也照 YXZ 分，兩邊是同一個約定。

用法：
  python3 tools/align_vehicle.py <in.glb> [--flip] [--png out.png]
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from glb_silhouette import load_positions          # noqa: E402

sys.stdout.reconfigure(encoding="utf-8")

GRID = 48            # 對稱度用的體素解析度


def voxels(p: np.ndarray, r: float) -> np.ndarray:
    idx = np.clip(((p / r + 1.0) * 0.5 * (GRID - 1)).astype(np.int32), 0, GRID - 1)
    occ = np.zeros((GRID, GRID, GRID), dtype=bool)
    occ[idx[:, 0], idx[:, 1], idx[:, 2]] = True
    return occ


def dilate(a: np.ndarray) -> np.ndarray:
    """六鄰域膨脹一格。薄殼對薄殼幾乎不會剛好對上，不膨脹分數就沒有鑑別力。"""
    o = a.copy()
    o[1:] |= a[:-1]; o[:-1] |= a[1:]
    o[:, 1:] |= a[:, :-1]; o[:, :-1] |= a[:, 1:]
    o[:, :, 1:] |= a[:, :, :-1]; o[:, :, :-1] |= a[:, :, 1:]
    return o


def sym_score(p: np.ndarray, n: np.ndarray, r: float) -> float:
    """點雲對「過原點、法向量 n」的平面鏡射後的重合度（0~1）。"""
    q = p - 2.0 * np.outer(p @ n, n)
    a, b = voxels(p, r), voxels(q, r)
    ad, bd = dilate(a), dilate(b)
    inter = np.count_nonzero((a & bd) | (b & ad))
    union = np.count_nonzero(a | b)
    return inter / max(union, 1)


def normal_of(az: float, el: float) -> np.ndarray:
    a, e = np.radians(az), np.radians(el)
    return np.array([np.cos(e) * np.cos(a), np.sin(e), np.cos(e) * np.sin(a)])


def long_axis(p: np.ndarray) -> np.ndarray:
    c = p - p.mean(axis=0)
    w, v = np.linalg.eigh(c.T @ c / len(c))
    return v[:, np.argmax(w)]


def find_plane(p: np.ndarray, r: float):
    """搜對稱面法向量。**兩道物理限制**，缺了會挑到假的對稱面：

    ① 法向量是載具的左右軸，不可能落在車身長軸上。攻擊機實測：
       分數最高的是 az=92（法向量沿機身）＝**機首機尾對摺**，那是假對稱
       （平直翼＋水平尾翼上下左右都湊得上去），真正的左右面只差 0.005 分。
    ② 左右軸大致水平（載具是站在地上的）。武裝直升機實測最高分在仰角 60 度＝
       把直升機側躺——旋翼葉片停在隨機方位會把真對稱面的分數壓下去。
    """
    la = long_axis(p)
    best = (-1.0, 0.0, 0.0)

    def ok(n):
        return abs(n @ la) <= 0.5

    for az in np.arange(0, 180, 4.0):              # 法向量半球（n 與 -n 等價）
        for el in np.arange(-40, 40.1, 5.0):       # 限制②
            n = normal_of(az, el)
            if not ok(n):                          # 限制①
                continue
            s = sym_score(p, n, r)
            if s > best[0]:
                best = (s, az, el)
    _, a0, e0 = best
    for az in np.arange(a0 - 4, a0 + 4.01, 1.0):   # 細掃
        for el in np.arange(e0 - 5, e0 + 5.01, 1.0):
            s = sym_score(p, normal_of(az, el), r)
            if s > best[0]:
                best = (s, az, el)
    return best


def build_rot(p: np.ndarray, n: np.ndarray) -> np.ndarray:
    """把對稱面法向量 n 轉到 X；平面內用 PCA 決定 Z（最長軸）與 Y。"""
    tmp = np.array([0.0, 1.0, 0.0])
    if abs(n @ tmp) > 0.9:
        tmp = np.array([0.0, 0.0, 1.0])
    e1 = np.cross(n, tmp); e1 /= np.linalg.norm(e1)
    e2 = np.cross(n, e1)
    proj = np.stack([p @ e1, p @ e2], axis=1)
    proj -= proj.mean(axis=0)
    w, v = np.linalg.eigh(proj.T @ proj / len(proj))
    long_v = v[:, np.argmax(w)]
    short_v = v[:, np.argmin(w)]
    z_ax = long_v[0] * e1 + long_v[1] * e2          # 車身長軸 → Z
    y_ax = short_v[0] * e1 + short_v[1] * e2        # 剩下那軸 → Y
    if y_ax[1] < 0:                                 # 上下：以原模型的 +Y 為準
        y_ax = -y_ax
    x_ax = np.cross(y_ax, z_ax)
    if x_ax @ n < 0:
        x_ax = -x_ax
    z_ax = np.cross(x_ax, y_ax)
    R = np.stack([x_ax, y_ax, z_ax])                # 列＝新座標軸 ⇒ q = R·p
    if np.linalg.det(R) < 0:
        R[0] = -R[0]
    return R


def to_euler_yxz(R: np.ndarray):
    """分解成 Godot 預設 Euler 序 YXZ（R = Ry·Rx·Rz）→ (x, y, z) 度。"""
    a = np.arcsin(np.clip(-R[1][2], -1.0, 1.0))
    c = np.arctan2(R[1][0], R[1][1])
    b = np.arctan2(R[0][2], R[2][2])
    return [np.degrees(a), np.degrees(b), np.degrees(c)]


def rot_y180(R):
    return np.array([[-1.0, 0, 0], [0, 1.0, 0], [0, 0, -1.0]]) @ R


def main() -> int:
    src = sys.argv[1]
    flip = "--flip" in sys.argv
    png = sys.argv[sys.argv.index("--png") + 1] if "--png" in sys.argv else None

    raw = load_positions(src).astype(np.float64)
    # 對稱搜尋要以形心為中心（鏡射面必過形心）；但回報的 aligned_aabb 必須以
    # **模型原點**為基準——Godot 是繞節點原點旋轉的，兩者若不同會差一個平移。
    pts = raw - (raw.min(axis=0) + raw.max(axis=0)) * 0.5
    r = np.abs(pts).max() * 1.001
    base = sym_score(pts, np.array([1.0, 0.0, 0.0]), r)
    score, az, el = find_plane(pts, r)
    R = build_rot(pts, normal_of(az, el))
    if flip:
        R = rot_y180(R)
    ex, ey, ez = to_euler_yxz(R)
    fin = raw @ R.T                                # 繞模型原點轉，與 Godot 一致
    size = fin.max(axis=0) - fin.min(axis=0)
    print(f"[align] {src}")
    print(f"    對稱度：原朝向 {base:.3f} → 轉正後 {score:.3f}（1.0＝完全左右對稱）")
    print(f"    rot_deg = [{ex:.1f}, {ey:.1f}, {ez:.1f}]")
    print(f"    轉正後尺寸 X={size[0]:.3f} Y={size[1]:.3f} Z={size[2]:.3f}"
          f"   長寬比 Z/X={size[2] / max(size[0], 1e-6):.2f}")
    # ⚠ 這組數字一定要跟著 rot_deg 一起寫進 vehicle_look.json。
    #   引擎不能自己量：Godot 量的是「各 mesh 的區域 AABB 再轉到世界」，
    #   模型一旋轉，斜放的盒子的正交外接框就被撐大（實測戰鬥機 Z 被撐大 20%），
    #   拿去算縮放會把飛機縮小 17%、拿去貼地會讓它浮在半空。
    lo = fin.min(axis=0)
    print(f"    aligned_aabb = [{lo[0]:.4f}, {lo[1]:.4f}, {lo[2]:.4f},"
          f" {size[0]:.4f}, {size[1]:.4f}, {size[2]:.4f}]"
          f"   （原點＝模型原點，與 Godot 的旋轉中心同一點）")
    if score < 0.70:
        print("    ⚠ 對稱度偏低，這個角度不一定可信——一定要看圖")
    if png:
        import glb_silhouette as gs
        from PIL import Image
        f32 = fin.astype(np.float32)
        panels = [gs.panel(f32, 0, 2, 420, True, "俯視 (上=+Z 車頭)", 0),
                  gs.panel(f32, 2, 1, 420, True, "側視 (右=+Z 車頭)", 0),
                  gs.panel(f32, 0, 1, 420, True, "前視", 0)]
        out = Image.new("RGB", (420 * 3 + 16, 420), (10, 11, 13))
        for i, pn in enumerate(panels):
            out.paste(pn, (i * 428, 0))
        out.save(png)
        print(f"    轉正後三視圖 -> {png}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
