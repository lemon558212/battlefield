# -*- coding: utf-8 -*-
"""audit_char_colors.py — 用立繪本身稽核 char_look.json 的配色。

存在理由：艾拉被設成「暗紅外套」，但立繪的紅其實在頭髮與飾邊，外套是深炭灰。
這種錯不會被任何不變量測試抓到（測試對顏色是瞎的），只能拿立繪當真相來源比對。

判準（都是可量化的）：
  1. coat 與立繪「軀幹區中位色」的色差 ΔE 不可過大（>60 視為配色與立繪不符）
  2. hair 與立繪「頭部區中位色」同上
  3. coat 不可比 accent 更飽和——飾邊才是點綴色，主外套搶過飾邊就是配色反了

用法：python tools/audit_char_colors.py
"""
import json, os, statistics, colorsys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
from PIL import Image

CLASSES = ["rifleman", "assault", "mg", "sniper", "at", "mortar",
           "engineer", "specops", "sam"]


def median_rgb(im, box):
    px = [p for p in im.crop(box).getdata()
          if not (p[0] > 225 and p[1] > 220 and p[2] > 210)]   # 濾紙白背景
    if not px:
        return None
    return tuple(int(statistics.median([p[i] for p in px])) for i in range(3))


def hex2rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def dist(a, b):
    return sum((x - y) ** 2 for x, y in zip(a, b)) ** 0.5


def sat(rgb):
    return colorsys.rgb_to_hsv(*[c / 255.0 for c in rgb])[1]


def main():
    look = json.load(open(os.path.join(ROOT, "godot/data/char_look.json"),
                          encoding="utf-8"))
    fails = 0
    for cls in CLASSES:
        p = os.path.join(ROOT, "godot/assets/portraits", cls + ".png")
        if not os.path.exists(p):
            print(f"[colchk] FAIL {cls} 找不到立繪 {p}")
            fails += 1
            continue
        im = Image.open(p).convert("RGB")
        W, H = im.size
        head = median_rgb(im, (int(W * .40), int(H * .05), int(W * .62), int(H * .12)))
        torso = median_rgb(im, (int(W * .40), int(H * .24), int(W * .62), int(H * .38)))
        cfg = look.get(cls, {})
        c_coat, c_hair = hex2rgb(cfg.get("coat", "#000000")), hex2rgb(cfg.get("hair", "#000000"))
        c_acc = hex2rgb(cfg.get("accent", "#000000"))
        d_coat = dist(c_coat, torso) if torso else 999
        d_hair = dist(c_hair, head) if head else 999
        flag = ""
        if d_coat > 60:
            flag += f" ✗外套色差{d_coat:.0f}(立繪軀幹#{torso[0]:02x}{torso[1]:02x}{torso[2]:02x})"
            fails += 1
        if d_hair > 75:
            flag += f" ✗髮色差{d_hair:.0f}(立繪頭部#{head[0]:02x}{head[1]:02x}{head[2]:02x})"
            fails += 1
        if sat(c_coat) > sat(c_acc) + 0.12:
            flag += f" ✗外套比飾邊更飽和({sat(c_coat):.2f}>{sat(c_acc):.2f})＝主副色反了"
            fails += 1
        print(f"[colchk] {cls:<9} coat={cfg.get('coat')} 差{d_coat:5.1f} ／ "
              f"hair={cfg.get('hair')} 差{d_hair:5.1f}{flag or '  OK'}")
    print(f"[colchk] FAILS={fails}")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
