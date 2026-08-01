# -*- coding: utf-8 -*-
"""split_turret.py — 把 image-to-3D 生成的整台載具拆成「車體」與「砲塔」兩個 glb。

為什麼一定要拆：生成出來的是**單一網格**，但砲塔必須能獨立轉向瞄準
（GDD/01 §3：載具沒有骨架，瞄準就是轉砲塔）。整台不拆的話，要嘛砲塔不會動、
要嘛整台車跟著轉——兩者都違反現實。

拆法：以「砲塔座圈高度」為界的水平切面。砲管從砲塔往前伸、天線往上，
都在界線之上，會自然跟著砲塔走，不需要另外處理。
⚠ 切面高度是各車不同的，由 vehicle_look.json 的 turret_y（佔全高比例）給，
  不是猜一個通用值——實拍看不對就調那個數字。

用法：python tools/split_turret.py <in.glb> <out_hull.glb> <out_turret.glb> [turret_y]
"""
import sys
import numpy as np
import trimesh


def main():
    src, out_hull, out_tur = sys.argv[1], sys.argv[2], sys.argv[3]
    ty = float(sys.argv[4]) if len(sys.argv) > 4 else 0.45

    mesh = trimesh.load(src, force="mesh")
    lo, hi = mesh.bounds
    cut = lo[1] + (hi[1] - lo[1]) * ty
    tri_c = mesh.triangles.mean(axis=1)          # 每個三角形的重心
    up = tri_c[:, 1] > cut
    # ⚠ 兩片各自封口但不重疊的話，切面處會露出一條縫（實拍：砲塔與車體之間有黑洞）。
    #   車體多保留一段重疊帶，把縫塞住；重疊在模型內部，看不到也不會 z-fighting。
    overlap = (hi[1] - lo[1]) * 0.06
    keep_low = tri_c[:, 1] < cut + overlap

    if up.sum() == 0 or up.sum() == len(up):
        print(f"[split] FAIL 切面 y={cut:.3f} 把全部三角形分到同一邊"
              f"（上方 {up.sum()}／共 {len(up)}）——turret_y 給錯了")
        return 1

    for mask, path, tag in ((keep_low, out_hull, "車體"), (up, out_tur, "砲塔")):
        sub = mesh.submesh([np.where(mask)[0]], append=True)
        # ⚠ 生成模型是**薄殼**：水平切開後兩半都缺封口，遊戲裡會從切縫看穿到內部
        #   （實拍：砲塔與車體之間空一個洞、側面一大片白＝殼的內側）。
        #   切完一定要補洞，這不是美化、是「固體不可看穿」的基本要求。
        before = len(sub.faces)
        try:
            sub.fill_holes()
        except Exception as e:
            print(f"[split] ⚠ {tag} 補洞失敗：{e}")
        added = len(sub.faces) - before
        print(f"[split] {tag} 補洞 +{added} 面")
        sub.export(path)
        b = sub.bounds
        print(f"[split] {tag}: 面數 {len(sub.faces):6d}  尺寸 "
              f"{b[1][0]-b[0][0]:.2f} x {b[1][1]-b[0][1]:.2f} x {b[1][2]-b[0][2]:.2f}"
              f"  -> {path}")
    print(f"[split] 切面世界高 {cut:.3f}（全高 {hi[1]-lo[1]:.3f} 的 {ty:.0%}）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
