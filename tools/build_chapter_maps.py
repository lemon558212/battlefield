# -*- coding: utf-8 -*-
"""15 章各自的戰場配方。每一章的地貌直接對照 story.json 的 brief 與對話。

尺寸依 difficulty.json 的敵人數量放大（使用者：「第6-15章可以依造敵人數量適時調整
地圖整體大小」）：W = 1300 + 80 * 敵人數，H = W * 0.70。
第 1 章維持已驗證過的 1400x1000 不動。
"""
import io, json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mapgen import MapBuilder, MAPS, STORY, DIFF, ROOT, dseg


def size_for(n_enemy, floor_w=1400):
    w = max(floor_w, 1300 + 80 * n_enemy)
    return int(w), int(w * 0.70)


def ring(cx, cy, r, n, start=0.0):
    import math
    return [[int(cx + r * math.cos(start + 2 * math.pi * i / n)),
             int(cy + r * math.sin(start + 2 * math.pi * i / n))] for i in range(n)]


# =============================================================
def ch02(n):  # 平原上的旗：奪回邊境哨站，「左翼是弱點」
    W, H = size_for(n)
    b = MapBuilder('ch02', '第二章：邊境哨站', W, H, 'grass', '#7f8f57', 'day', ['land', 'air'])
    cx, cy = W * 0.62, H * 0.5
    # 哨站本體：司令部＋兩棟營房＋車庫＋旗桿（gate 帶旗桿）
    b.building(int(cx - 150), int(cy - 260), 300, 190, 2, note='哨站司令部')
    b.building(int(cx - 160), int(cy + 90), 280, 170, 1, note='營房')
    b.building(int(cx + 190), int(cy - 90), 220, 200, 1, 'depot', '軍械庫')
    b.building(int(cx - 430), int(cy - 60), 190, 160, 1, 'gate', '哨站正門（旗桿）')
    b.building(int(cx + 200), int(cy + 150), 200, 150, 2, 'tower', '瞭望塔')
    # 一條小溪從北往南（不橫貫，不切斷戰場）
    b.add_river([[int(W * 0.30), -40], [int(W * 0.33), int(H * 0.22)],
                 [int(W * 0.28), int(H * 0.46)], [int(W * 0.32), int(H * 0.72)],
                 [int(W * 0.27), H + 40]], w=56, depth=0.8, bank=0.35)
    b.add_ford(int(W * 0.305), int(H * 0.34), 120, 0.35)
    b.add_ford(int(W * 0.295), int(H * 0.60), 120, 0.35)
    b.m['roads'] = [{'x1': int(W * 0.10), 'y1': int(cy + 20), 'x2': W - 60, 'y2': int(cy + 10), 'w': 26}]
    b.auto_deploy('west', 'east', w=180, h=int(H * 0.44))
    # 防線：北翼（左翼）刻意稀疏——劇本說「左翼是弱點」，玩家要看得出來
    b.sandbag_line(int(cx - 300), int(cy + 60), 5)
    b.sandbag_line(int(cx - 300), int(cy - 300), 2)          # 左翼只有兩段
    b.sandbag_line(int(cx + 140), int(cy - 300), 4, horiz=True)
    b.m['wires'].append({'pts': [[int(cx - 340), int(cy + 40)], [int(cx - 330), int(cy + 330)]], 'h': 1.0})
    b.m['trenches'] = [{'pts': [[int(cx - 300), int(cy + 60)], [int(cx - 290), int(cy + 320)]], 'w': 44}]
    b.m['hills'] = [{'x': int(W * 0.85), 'y': int(H * 0.22), 'r': 260, 'h': 5},
                    {'x': int(W * 0.18), 'y': int(H * 0.80), 'r': 220, 'h': 4}]
    b.nudge_props()
    # ⚠ ch01 沿用這張 tutorial 圖，而它是 coast（綠地系）：草叢要跟其他綠地圖一樣大，
    #   否則第一章看起來是全遊戲唯一「草很小、躲不住」的地方（使用者 2026-08-04 指出）。
    b.scatter(bushes=22, craters=5, bush_r=(34, 70))
    return b


def ch03(n):  # 絞肉機重演：兩道鐵絲網、十二座機槍堡、無人地帶
    W, H = size_for(n)
    b = MapBuilder('ch03', '第三章：無人地帶', W, H, 'mud', '#6b6551', 'day', ['land', 'air'], 'rain')
    midx = W * 0.5
    # 兩道鐵絲網（南北縱走），中間是無人地帶
    for i, fx in enumerate([0.40, 0.60]):
        b.m['wires'].append({'pts': [[int(W * fx), -30], [int(W * (fx + 0.015)), int(H * 0.3)],
                                     [int(W * (fx - 0.01)), int(H * 0.62)], [int(W * fx), H + 30]],
                             'h': 1.0})
    # 十二座機槍堡：東側（敵方）一排八座，西側四座
    for i in range(8):
        y = int(H * (0.08 + 0.12 * i))
        b.m['pillboxes'].append({'x': int(W * 0.72), 'y': y, 'face': 180, 'size': 1.0})
    for i in range(4):
        y = int(H * (0.16 + 0.22 * i))
        b.m['pillboxes'].append({'x': int(W * 0.26), 'y': y, 'face': 0, 'size': 0.95})
    # 壕溝網：每側兩道平行 + 交通壕
    b.m['trenches'] = [
        {'pts': [[int(W * 0.20), 40], [int(W * 0.22), int(H * 0.5)], [int(W * 0.20), H - 40]], 'w': 52},
        {'pts': [[int(W * 0.31), 60], [int(W * 0.33), int(H * 0.5)], [int(W * 0.31), H - 60]], 'w': 46},
        {'pts': [[int(W * 0.78), 40], [int(W * 0.76), int(H * 0.5)], [int(W * 0.78), H - 40]], 'w': 52},
        {'pts': [[int(W * 0.67), 60], [int(W * 0.65), int(H * 0.5)], [int(W * 0.67), H - 60]], 'w': 46},
        {'pts': [[int(W * 0.20), int(H * 0.30)], [int(W * 0.31), int(H * 0.32)]], 'w': 40},
        {'pts': [[int(W * 0.78), int(H * 0.68)], [int(W * 0.67), int(H * 0.70)]], 'w': 40},
    ]
    # 無人地帶只剩一棟被打爛的農舍
    b.building(int(midx - 110), int(H * 0.44), 220, 160, 1, note='廢棄農舍')
    b.building(int(W * 0.83), int(H * 0.36), 240, 180, 2, 'depot', '敵方彈藥所')
    b.building(int(W * 0.08), int(H * 0.40), 220, 170, 2, note='我方掩蔽部')
    b.m['roads'] = []
    b.auto_deploy('west', 'east', w=150, h=int(H * 0.46))
    b.m['tanktraps'] = [{'x': int(W * 0.5), 'y': int(H * 0.18), 'w': 150, 'h': 60},
                        {'x': int(W * 0.5), 'y': int(H * 0.78), 'w': 150, 'h': 60}]
    b.nudge_props()
    b.scatter(bushes=6, craters=26, crater_r=(26, 44))       # 砲擊過的地：彈坑多、草少
    return b


def ch04(n):  # 無聲的村莊：藏兵於民宅，村口有孩子
    W, H = size_for(n)
    b = MapBuilder('ch04', '第四章：無聲的村莊', W, H, 'urban', '#7a7f5e', 'day', ['land', 'air'])
    # 主街東西向，兩側民宅（貼街面，這才像村莊不是郊區獨棟）
    road_y = int(H * 0.5)
    b.m['roads'] = [{'x1': 60, 'y1': road_y, 'x2': W - 60, 'y2': road_y, 'w': 34},
                    {'x1': int(W * 0.5), 'y1': 80, 'x2': int(W * 0.5) + 8, 'y2': H - 80, 'w': 26}]
    xs = [0.14, 0.28, 0.42, 0.60, 0.74, 0.87]
    for i, fx in enumerate(xs):
        if abs(fx - 0.5) < 0.06:
            continue
        b.building(int(W * fx - 105), road_y - 250, 210, 165, 2, note='民宅N%d' % i)
        b.building(int(W * fx - 105), road_y + 85, 210, 160, 1 + (i % 2), note='民宅S%d' % i)
    b.building(int(W * 0.5) - 120, road_y - 430, 240, 170, 3, 'tower', '教堂鐘塔')
    b.auto_deploy('south', 'north', w=170, h=int(H * 0.16))
    b.m['roadblocks'] = [{'x': int(W * 0.5), 'y': road_y - 60, 'w': 150}]
    b.sandbag_line(int(W * 0.20), road_y - 40, 3, horiz=True)
    b.sandbag_line(int(W * 0.70), road_y + 30, 3, horiz=True)
    b.nudge_props()
    b.scatter(bushes=16, craters=4)
    return b


def ch05(n):  # 沙暴走廊：裝甲縱隊撤往港口，18 回合追擊
    W, H = size_for(n)
    b = MapBuilder('ch05', '第五章：沙暴走廊', W, H, 'desert', '#b09462', 'day', ['land', 'air'], 'sand')
    # 走廊：南北兩道沙丘夾出一條中央通道
    b.m['hills'] = [{'x': int(W * 0.2), 'y': int(H * 0.06), 'r': 420, 'h': 11},
                    {'x': int(W * 0.55), 'y': int(H * 0.02), 'r': 460, 'h': 13},
                    {'x': int(W * 0.85), 'y': int(H * 0.08), 'r': 400, 'h': 10},
                    {'x': int(W * 0.25), 'y': int(H * 0.96), 'r': 430, 'h': 12},
                    {'x': int(W * 0.62), 'y': int(H * 1.00), 'r': 470, 'h': 13},
                    {'x': int(W * 0.90), 'y': int(H * 0.94), 'r': 390, 'h': 9}]
    b.m['roads'] = [{'x1': 40, 'y1': int(H * 0.5), 'x2': W - 40, 'y2': int(H * 0.52), 'w': 40}]
    b.building(int(W * 0.78), int(H * 0.30), 260, 200, 1, 'depot', '燃料補給點')
    b.building(int(W * 0.72), int(H * 0.62), 200, 160, 2, 'radar', '防空雷達')
    b.building(int(W * 0.18), int(H * 0.60), 220, 170, 1, note='廢棄驛站')
    b.auto_deploy('west', 'east', w=190, h=int(H * 0.34))
    b.m['tanktraps'] = [{'x': int(W * 0.55), 'y': int(H * 0.5), 'w': 170, 'h': 70}]
    b.nudge_props()
    b.scatter(bushes=0, craters=10)
    return b


def ch06(n):  # 林海伏擊：車隊被包餃子，利用樹障與高草
    W, H = size_for(n)
    b = MapBuilder('ch06', '第六章：林海', W, H, 'forest', '#4f6b3a', 'day', ['land', 'air'])
    # 一條穿越林海的道路（伏擊點在中段），一條溪
    b.m['roads'] = [{'x1': 40, 'y1': int(H * 0.62), 'x2': int(W * 0.45), 'y2': int(H * 0.48),
                     'w': 32},
                    {'x1': int(W * 0.45), 'y1': int(H * 0.48), 'x2': W - 40, 'y2': int(H * 0.38),
                     'w': 32}]
    b.add_river([[-40, int(H * 0.20)], [int(W * 0.24), int(H * 0.26)], [int(W * 0.46), int(H * 0.16)],
                 [int(W * 0.70), int(H * 0.24)], [W + 40, int(H * 0.18)]], w=64, depth=1.0, bank=0.45)
    b.add_ford(int(W * 0.35), int(H * 0.21), 120, 0.38)
    b.building(int(W * 0.52), int(H * 0.66), 230, 180, 1, note='林務站')
    b.building(int(W * 0.20), int(H * 0.78), 200, 150, 1, note='獵人小屋')
    b.building(int(W * 0.80), int(H * 0.70), 210, 165, 2, 'tower', '瞭望台')
    b.auto_deploy('west', 'east', w=170, h=int(H * 0.30))
    b.m['hills'] = [{'x': int(W * 0.35), 'y': int(H * 0.88), 'r': 320, 'h': 7},
                    {'x': int(W * 0.72), 'y': int(H * 0.90), 'r': 300, 'h': 6}]
    b.nudge_props()
    b.scatter(bushes=40, craters=3)      # 高草多＝隱蔽多，這是本章的玩法
    return b


def ch07(n):  # 斷橋之城：州府巷戰，河穿城而過，橋斷了
    W, H = size_for(n)
    b = MapBuilder('ch07', '第七章：斷橋之城', W, H, 'urban', '#6f7466', 'day', ['land', 'air'])
    b.add_river([[int(W * 0.44), -40], [int(W * 0.47), int(H * 0.26)], [int(W * 0.42), int(H * 0.54)],
                 [int(W * 0.48), int(H * 0.80)], [int(W * 0.45), H + 40]], w=110, depth=2.2, bank=0.6)
    # 兩座橋：北橋斷了（劇名），南橋完好＝唯一的過河點，全場戰術焦點
    b.m['bridges'] = [
        {'x1': int(W * 0.30), 'y1': int(H * 0.28), 'x2': int(W * 0.62), 'y2': int(H * 0.28),
         'w': 90, 'broken': 0.42},
        {'x1': int(W * 0.30), 'y1': int(H * 0.76), 'x2': int(W * 0.62), 'y2': int(H * 0.76),
         'w': 80, 'broken': 0.0}]
    b.m['roads'] = [{'x1': 40, 'y1': int(H * 0.28), 'x2': W - 40, 'y2': int(H * 0.28), 'w': 30},
                    {'x1': 40, 'y1': int(H * 0.76), 'x2': W - 40, 'y2': int(H * 0.76), 'w': 28}]
    for i, fx in enumerate([0.10, 0.24, 0.66, 0.80, 0.92]):
        b.building(int(W * fx - 110), int(H * 0.40), 220, 175, 2 + (i % 2), note='街區A%d' % i)
    for i, fx in enumerate([0.14, 0.30, 0.70, 0.86]):
        b.building(int(W * fx - 105), int(H * 0.04), 210, 165, 2, note='街區B%d' % i)
    b.building(int(W * 0.72), int(H * 0.86), 240, 170, 3, 'tower', '州廳鐘樓')
    b.deploy({'x': 50, 'y': int(H * 0.62), 'w': 170, 'h': int(H * 0.20)},
             {'x': W - 220, 'y': int(H * 0.62), 'w': 170, 'h': int(H * 0.20)})
    b.bases({'x': 135, 'y': int(H * 0.72)}, {'x': W - 135, 'y': int(H * 0.72)})
    b.m['containers'] = [{'x': int(W * 0.20), 'y': int(H * 0.58), 'rot': 12, 'stack': 2},
                         {'x': int(W * 0.78), 'y': int(H * 0.20), 'rot': 96, 'stack': 1}]
    b.nudge_props()
    b.scatter(bushes=8, craters=12)
    return b


def ch08(n):  # 紅色灘頭：LST 搶灘，灘頭有碉堡、淺灘有鐵絲網
    W, H = size_for(n)
    b = MapBuilder('ch08', '第八章：紅色灘頭', W, H, 'coast', '#9aa46f', 'dawn', ['land', 'air'])
    b.set_coast('west', [[int(W * 0.30), -80], [int(W * 0.26), int(H * 0.16)],
                         [int(W * 0.31), int(H * 0.34)], [int(W * 0.24), int(H * 0.52)],
                         [int(W * 0.29), int(H * 0.70)], [int(W * 0.25), int(H * 0.88)],
                         [int(W * 0.30), H + 80]], depth=3.0, slope=150)
    # 灘頭碉堡：面向大海（西＝180 度）
    for i in range(5):
        y = int(H * (0.14 + 0.18 * i))
        b.m['pillboxes'].append({'x': int(W * 0.375), 'y': y, 'face': 180, 'size': 1.15})
    # 淺灘鐵絲網：泡在水裡是**故意的**（劇本：「淺灘有鐵絲網」）
    b.m['wires'].append({'pts': [[int(W * 0.315), int(H * 0.06)], [int(W * 0.305), int(H * 0.46)],
                                 [int(W * 0.315), int(H * 0.94)]], 'h': 1.0, 'inWater': True})
    b.m['wires'].append({'pts': [[int(W * 0.345), int(H * 0.10)], [int(W * 0.340), int(H * 0.90)]],
                         'h': 1.0, 'inWater': True})
    b.building(int(W * 0.55), int(H * 0.16), 250, 190, 2, 'depot', '灘頭補給站')
    b.building(int(W * 0.58), int(H * 0.60), 260, 200, 2, note='海防營舍')
    b.building(int(W * 0.82), int(H * 0.36), 220, 175, 3, 'tower', '觀測塔')
    b.building(int(W * 0.80), int(H * 0.74), 230, 170, 1, 'radar', '岸防雷達')
    b.m['roads'] = [{'x1': int(W * 0.40), 'y1': int(H * 0.50), 'x2': W - 50, 'y2': int(H * 0.48), 'w': 30}]
    b.deploy({'x': int(W * 0.395), 'y': int(H * 0.36), 'w': 120, 'h': int(H * 0.26)},
             {'x': W - 230, 'y': int(H * 0.10), 'w': 180, 'h': int(H * 0.22)})
    b.bases({'x': int(W * 0.45), 'y': int(H * 0.49)}, {'x': W - 140, 'y': int(H * 0.20)})
    b.m['tanktraps'] = [{'x': int(W * 0.42), 'y': int(H * 0.80), 'w': 160, 'h': 64}]
    b.nudge_props()
    b.scatter(bushes=14, craters=14)
    return b


def ch09(n):  # 海峽封鎖線：三艘補給船通過海峽，潛艦與飛彈艇在等
    W, H = size_for(n)
    b = MapBuilder('ch09', '第九章：海峽封鎖線', W, H, 'coast', '#8f9a6d', 'day', ['land', 'air'], 'fog')
    # 海在北：南岸是陸地，北邊整片是海（水道）
    b.set_coast('north', [[-80, int(H * 0.60)], [int(W * 0.18), int(H * 0.66)],
                          [int(W * 0.38), int(H * 0.58)], [int(W * 0.58), int(H * 0.68)],
                          [int(W * 0.78), int(H * 0.60)], [W + 80, int(H * 0.66)]],
                depth=3.2, slope=170)
    b.building(int(W * 0.12), int(H * 0.78), 240, 180, 2, 'radar', '南岸觀測站')
    b.building(int(W * 0.46), int(H * 0.80), 260, 190, 2, 'depot', '補給碼頭倉庫')
    b.building(int(W * 0.80), int(H * 0.76), 230, 175, 3, 'tower', '燈塔')
    b.m['quays'] = [{'x': int(W * 0.42), 'y': int(H * 0.62), 'w': 320, 'h': 120}]
    b.m['roads'] = [{'x1': 60, 'y1': int(H * 0.90), 'x2': W - 60, 'y2': int(H * 0.90), 'w': 28}]
    b.auto_deploy('south', 'south', w=200, h=int(H * 0.11))
    b.m['reefs'] = [{'x': int(W * 0.30), 'y': int(H * 0.30), 'r': 90},
                    {'x': int(W * 0.66), 'y': int(H * 0.22), 'r': 110}]
    b.nudge_props()
    b.scatter(bushes=10, craters=4)
    return b


def ch10(n):  # 霧港疑雲：夜霧軍港，走私貨櫃，前段滲透後段強攻
    W, H = size_for(n)
    b = MapBuilder('ch10', '第十章：霧港', W, H, 'coast', '#6d7360', 'night', ['land', 'air'], 'fog')
    b.set_coast('south', [[-80, int(H * 0.70)], [int(W * 0.22), int(H * 0.74)],
                          [int(W * 0.45), int(H * 0.68)], [int(W * 0.68), int(H * 0.76)],
                          [W + 80, int(H * 0.70)]], depth=3.0, slope=150)
    b.m['quays'] = [{'x': int(W * 0.14), 'y': int(H * 0.58), 'w': 360, 'h': 130},
                    {'x': int(W * 0.58), 'y': int(H * 0.60), 'w': 340, 'h': 130}]
    # 貨櫃場：這是本章的劇情道具（查獲走私貨櫃），也是最好的掩體迷宮
    for i in range(9):
        b.m['containers'].append({'x': int(W * (0.16 + 0.075 * i)), 'y': int(H * (0.34 + 0.10 * (i % 3))),
                                  'rot': 0 if i % 2 == 0 else 90, 'stack': 1 + (i % 3 == 0)})
    b.building(int(W * 0.10), int(H * 0.12), 270, 200, 2, 'depot', '港務倉庫')
    b.building(int(W * 0.44), int(H * 0.08), 300, 210, 2, note='海關大樓')
    b.building(int(W * 0.78), int(H * 0.14), 240, 185, 3, 'tower', '塔台')
    b.building(int(W * 0.80), int(H * 0.42), 220, 170, 1, 'radar', '港區雷達')
    b.m['roads'] = [{'x1': 50, 'y1': int(H * 0.28), 'x2': W - 50, 'y2': int(H * 0.28), 'w': 32}]
    b.auto_deploy('west', 'east', w=170, h=int(H * 0.18))
    b.nudge_props()
    b.scatter(bushes=6, craters=5)
    return b


def ch11(n):  # 群山之肩：隘口在上，敵在棱線後
    W, H = size_for(n)
    b = MapBuilder('ch11', '第十一章：群山之肩', W, H, 'grass', '#6d7a52', 'day', ['land', 'air'])
    # 棱線：東側一道高牆般的山脊，中間留一個鞍部（隘口）＝唯一的正面通道
    b.m['hills'] = [{'x': int(W * 0.70), 'y': int(H * 0.04), 'r': 420, 'h': 26},
                    {'x': int(W * 0.72), 'y': int(H * 0.96), 'r': 430, 'h': 27},
                    {'x': int(W * 0.86), 'y': int(H * 0.50), 'r': 300, 'h': 20},
                    {'x': int(W * 0.30), 'y': int(H * 0.16), 'r': 340, 'h': 9},
                    {'x': int(W * 0.26), 'y': int(H * 0.84), 'r': 330, 'h': 8}]
    b.building(int(W * 0.80), int(H * 0.44), 240, 190, 2, 'tower', '峰頂觀察哨')
    b.building(int(W * 0.60), int(H * 0.46), 220, 170, 1, 'depot', '隘口彈藥所')
    b.building(int(W * 0.16), int(H * 0.46), 230, 175, 1, note='山腳集結地')
    b.m['roads'] = [{'x1': 60, 'y1': int(H * 0.52), 'x2': W - 60, 'y2': int(H * 0.50), 'w': 28}]
    b.m['trenches'] = [{'pts': [[int(W * 0.66), int(H * 0.28)], [int(W * 0.64), int(H * 0.50)],
                                [int(W * 0.66), int(H * 0.72)]], 'w': 48}]
    b.m['wires'].append({'pts': [[int(W * 0.58), int(H * 0.24)], [int(W * 0.56), int(H * 0.76)]], 'h': 1.0})
    for i in range(4):
        b.m['pillboxes'].append({'x': int(W * 0.69), 'y': int(H * (0.24 + 0.17 * i)),
                                 'face': 180, 'size': 1.0})
    b.deploy({'x': 60, 'y': int(H * 0.30), 'w': 180, 'h': int(H * 0.40)},
             {'x': W - 240, 'y': int(H * 0.12), 'w': 170, 'h': int(H * 0.22)})
    b.bases({'x': 150, 'y': int(H * 0.5)}, {'x': W - 155, 'y': int(H * 0.22)})
    b.nudge_props()
    b.scatter(bushes=20, craters=8)
    return b


def ch12(n):  # 鋼鐵洪流：三十回合防守，鐵絲網＋反戰車壕
    W, H = size_for(n)
    b = MapBuilder('ch12', '第十二章：鋼鐵洪流', W, H, 'grass', '#7c8a55', 'dusk', ['land', 'air'])
    # 防線在東（玩家側 side=1）：三層——鐵絲網、反戰車壕、沙包與碉堡
    b.m['wires'] = [{'pts': [[int(W * 0.46), 40], [int(W * 0.48), int(H * 0.5)],
                             [int(W * 0.46), H - 40]], 'h': 1.0},
                    {'pts': [[int(W * 0.52), 60], [int(W * 0.54), int(H * 0.5)],
                             [int(W * 0.52), H - 60]], 'h': 1.0}]
    b.m['trenches'] = [{'pts': [[int(W * 0.60), 40], [int(W * 0.62), int(H * 0.5)],
                                [int(W * 0.60), H - 40]], 'w': 76},          # 反戰車壕：寬
                       {'pts': [[int(W * 0.72), 80], [int(W * 0.74), int(H * 0.5)],
                                [int(W * 0.72), H - 80]], 'w': 50}]
    b.m['tanktraps'] = [{'x': int(W * 0.56), 'y': int(H * 0.20), 'w': 180, 'h': 70},
                        {'x': int(W * 0.56), 'y': int(H * 0.50), 'w': 180, 'h': 70},
                        {'x': int(W * 0.56), 'y': int(H * 0.80), 'w': 180, 'h': 70}]
    for i in range(6):
        b.m['pillboxes'].append({'x': int(W * 0.78), 'y': int(H * (0.10 + 0.16 * i)),
                                 'face': 180, 'size': 1.05})
    b.building(int(W * 0.88), int(H * 0.20), 240, 185, 2, 'depot', '前進補給所')
    b.building(int(W * 0.86), int(H * 0.62), 250, 190, 2, note='指揮掩蔽部')
    b.building(int(W * 0.14), int(H * 0.44), 230, 175, 1, note='敵方集結地')
    b.m['roads'] = [{'x1': 40, 'y1': int(H * 0.5), 'x2': W - 40, 'y2': int(H * 0.5), 'w': 30}]
    b.deploy({'x': int(W * 0.02), 'y': int(H * 0.24), 'w': 170, 'h': int(H * 0.52)},
             {'x': int(W * 0.90), 'y': int(H * 0.36), 'w': 150, 'h': int(H * 0.22)})
    b.bases({'x': int(W * 0.06), 'y': int(H * 0.50)}, {'x': int(W * 0.95), 'y': int(H * 0.47)})
    b.nudge_props()
    b.scatter(bushes=14, craters=16)
    return b


def ch13(n):  # 孤島要塞：離島仿製兵工廠，三處岸防砲
    W, H = size_for(n)
    b = MapBuilder('ch13', '第十三章：孤島要塞', W, H, 'coast', '#7f8a63', 'day', ['land', 'air'])
    # 島：中央一塊陸地。用「海在西」＋「海在東」做不到，改成海在西、島東側靠地圖邊
    b.set_coast('west', [[int(W * 0.34), -80], [int(W * 0.30), int(H * 0.18)],
                         [int(W * 0.36), int(H * 0.38)], [int(W * 0.28), int(H * 0.58)],
                         [int(W * 0.35), int(H * 0.80)], [int(W * 0.31), H + 80]],
                depth=3.2, slope=160)
    # 三處岸防砲（劇本：影山靜在海圖上圈出三處）
    for i, fy in enumerate([0.18, 0.50, 0.82]):
        b.m['pillboxes'].append({'x': int(W * 0.40), 'y': int(H * fy), 'face': 180, 'size': 1.3})
    b.building(int(W * 0.62), int(H * 0.34), 340, 250, 2, 'depot', '仿製裝備兵工廠')
    b.building(int(W * 0.60), int(H * 0.72), 250, 185, 2, note='工人宿舍')
    b.building(int(W * 0.88), int(H * 0.20), 210, 170, 3, 'tower', '要塞塔')
    b.building(int(W * 0.88), int(H * 0.60), 200, 165, 1, 'radar', '對海雷達')
    b.m['roads'] = [{'x1': int(W * 0.42), 'y1': int(H * 0.52), 'x2': W - 50, 'y2': int(H * 0.50), 'w': 30}]
    b.m['quays'] = [{'x': int(W * 0.34), 'y': int(H * 0.60), 'w': 260, 'h': 110}]
    b.deploy({'x': int(W * 0.415), 'y': int(H * 0.40), 'w': 110, 'h': int(H * 0.20)},
             {'x': W - 210, 'y': int(H * 0.38), 'w': 160, 'h': int(H * 0.18)})
    b.bases({'x': int(W * 0.46), 'y': int(H * 0.50)}, {'x': W - 130, 'y': int(H * 0.46)})
    b.m['wires'].append({'pts': [[int(W * 0.44), int(H * 0.10)], [int(W * 0.45), int(H * 0.32)]], 'h': 1.0})
    b.m['wires'].append({'pts': [[int(W * 0.44), int(H * 0.70)], [int(W * 0.45), int(H * 0.92)]], 'h': 1.0})
    b.nudge_props()
    b.scatter(bushes=12, craters=10)
    return b


def ch14(n):  # 灰幕之後：夜戰潛入首都圈
    W, H = size_for(n)
    b = MapBuilder('ch14', '第十四章：首都圈', W, H, 'urban', '#5e6357', 'night', ['land', 'air'])
    road_y1, road_y2 = int(H * 0.30), int(H * 0.70)
    b.m['roads'] = [{'x1': 40, 'y1': road_y1, 'x2': W - 40, 'y2': road_y1, 'w': 30},
                    {'x1': 40, 'y1': road_y2, 'x2': W - 40, 'y2': road_y2, 'w': 30},
                    {'x1': int(W * 0.34), 'y1': 60, 'x2': int(W * 0.34), 'y2': H - 60, 'w': 26},
                    {'x1': int(W * 0.68), 'y1': 60, 'x2': int(W * 0.68), 'y2': H - 60, 'w': 26}]
    # 密集街廓：夜戰潛入靠的是建築之間的陰影
    for i, fx in enumerate([0.10, 0.22, 0.46, 0.58, 0.80, 0.92]):
        b.building(int(W * fx - 100), int(H * 0.04), 200, 170, 3, note='街廓N%d' % i)
        b.building(int(W * fx - 100), int(H * 0.44), 200, 175, 2 + (i % 2), note='街廓M%d' % i)
        b.building(int(W * fx - 100), int(H * 0.80), 200, 165, 2, note='街廓S%d' % i)
    b.auto_deploy('west', 'east', w=150, h=int(H * 0.14))
    b.m['containers'] = [{'x': int(W * 0.34), 'y': int(H * 0.50), 'rot': 0, 'stack': 1},
                         {'x': int(W * 0.68), 'y': int(H * 0.62), 'rot': 90, 'stack': 2}]
    b.nudge_props()
    b.scatter(bushes=8, craters=3)
    return b


def ch15(n):  # 黎明線：總攻要塞，海空壓制外環、陸軍破牆、直取中樞
    W, H = size_for(n)
    b = MapBuilder('ch15', '第十五章：黎明線', W, H, 'urban', '#6a6f60', 'dawn', ['land', 'air'])
    cx, cy = int(W * 0.66), int(H * 0.5)
    # 要塞：外環（碉堡＋鐵絲網＋壕溝）＋內城（指揮中樞）
    b.building(cx - 190, cy - 150, 380, 300, 3, 'tower', '灰幕指揮中樞')
    for i, (dx, dy) in enumerate([(-430, -330), (330, -330), (-430, 250), (330, 250)]):
        b.building(cx + dx, cy + dy, 230, 180, 2, 'depot', '外環堡壘%d' % i)
    b.m['pillboxes'] = [{'x': int(p[0]), 'y': int(p[1]), 'face': 180, 'size': 1.2}
                        for p in ring(cx, cy, 520, 8)]
    b.m['wires'] = [{'pts': ring(cx, cy, 640, 14) + [ring(cx, cy, 640, 14)[0]], 'h': 1.0}]
    b.m['trenches'] = [{'pts': ring(cx, cy, 730, 12) + [ring(cx, cy, 730, 12)[0]], 'w': 54}]
    b.m['roads'] = [{'x1': 40, 'y1': cy, 'x2': cx - 210, 'y2': cy, 'w': 34}]
    b.auto_deploy('west', 'east', w=180, h=int(H * 0.26))
    b.nudge_props()
    b.scatter(bushes=10, craters=20)
    return b


RECIPES = {2: ch02, 3: ch03, 4: ch04, 5: ch05, 6: ch06, 7: ch07, 8: ch08,
           9: ch09, 10: ch10, 11: ch11, 12: ch12, 13: ch13, 14: ch14, 15: ch15}


# ⚠ 2026-08-04（使用者拍板「不做飛機也不做戰艦」）：
#   · allow 全面拿掉 'sea'——沒有艦艇兵種了，海域只剩地形障礙的意義。
#   · 每張圖都補上 'air'：武裝無人機是唯一的空中兵種，且哪張圖都該出得來。
#   （這兩件必須改在**生成器**裡：直接改 maps.json 會在下次重新生成時被蓋掉，
#     我第一次就是這樣白改了一輪。）
def main():
    maps = json.load(io.open(MAPS, encoding='utf-8'))
    story = json.load(io.open(STORY, encoding='utf-8'))
    diff = json.load(io.open(DIFF, encoding='utf-8'))
    tiers = {t['ch']: t for t in diff['tiers']}

    # 第 1 章：沿用已驗證過的 tutorial，只換 id
    ch01 = dict(maps['tutorial'])
    ch01['id'] = 'ch01'
    ch01['name'] = '第一章：濱海基地'
    # ⚠ ch01 是沿用手工驗證過的 tutorial 圖，**不重新生成**，所以草叢放大要在這裡做
    #   （第一次改了 scatter() 卻沒生效，就是因為 ch01 根本沒走那條路）。
    #   放大之後可能壓到建築或道路，故逐叢往下收到放得下為止（收不下就維持原值）。
    def _fits_ch01(bx, by, br):
        for a in ch01.get('solids', []):
            if (bx + br > a['x'] and bx - br < a['x'] + a['w']
                    and by + br > a['y'] and by - br < a['y'] + a['h']):
                return False
        for rd in ch01.get('roads', []):
            if dseg(bx, by, (rd['x1'], rd['y1']), (rd['x2'], rd['y2'])) < rd.get('w', 40) * 0.5 + br:
                return False
        return True

    ch01['bushes'] = [dict(b) for b in ch01.get('bushes', [])]
    grown = 0
    for b in ch01['bushes']:
        want = min(70, max(34, int(b['r'] * 2.0)))
        while want > b['r'] and not _fits_ch01(b['x'], b['y'], want):
            want -= 4
        if want > b['r']:
            b['r'] = want
            grown += 1
    print('ch01 草叢放大 %d/%d 叢' % (grown, len(ch01['bushes'])))
    maps['ch01'] = ch01

    bad_total = 0
    rows = []
    for n_ch in sorted(RECIPES):
        tier = tiers.get(n_ch, {'enemyCount': 6})
        b = RECIPES[n_ch](tier['enemyCount'])
        probs = b.validate()
        bad_total += len(probs)
        maps[b.m['id']] = b.m
        rows.append('ch%02d %-14s %4dx%-4d bld=%2d 碉堡=%2d 鐵絲=%d 貨櫃=%2d 碼頭=%d 橋=%d 壕=%d %s'
                    % (n_ch, b.m['name'][4:], b.W, b.H, len(b.m['solids']), len(b.m['pillboxes']),
                       len(b.m['wires']), len(b.m['containers']), len(b.m['quays']),
                       len(b.m['bridges']), len(b.m['trenches']),
                       'OK' if not probs else 'FAIL(%d)' % len(probs)))
        for q in probs:
            rows.append('      ! ' + q)
    for c in story:
        c['map'] = 'ch%02d' % c['n']
    json.dump(maps, io.open(MAPS, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    json.dump(story, io.open(STORY, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    io.open(os.path.join(ROOT, 'logs', '_mapgen.txt'), 'w', encoding='utf-8').write('\n'.join(rows))
    print('problems=%d' % bad_total)
    return bad_total


if __name__ == '__main__':
    sys.exit(0 if main() == 0 else 1)
