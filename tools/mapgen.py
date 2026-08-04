# -*- coding: utf-8 -*-
"""依劇情生成 15 章各自的戰場地圖。

使用者 2026-07-28：
  「每一章節地圖場景不可能長得差不多，戰場不可能都是一樣的地方，要大幅度更改成符合劇情」
  「該出現什麼就要有什麼，而且要很精緻細膩」
  「第6-15章可以依造敵人數量適時調整地圖整體大小」

設計原則
  1. 一章一張圖（ch01~ch15）。先前 15 章共用 10 張圖，其中 plain/verdun/urban/strait
     各被兩三章重複使用，玩起來就是「又是同一個地方」。
  2. 每張圖的地貌直接對照 story.json 的 brief 與對話：
     第3章要「兩道鐵絲網、十二座機槍堡、無人地帶」，那就真的長 12 座碉堡。
  3. 尺寸依該章敵人數量（difficulty.json）放大：人多就要有地方擺。
  4. **所有佈局都要過驗證**：建築不重疊/不出界/不壓部署區(40px)/不泡水；
     沙包、鐵絲網、碉堡、貨櫃不壓建築也不壓部署區；基地在自家部署區內。
     手排必漏——第一章排的時候我漏過三次，全是靠這個驗證抓出來的。
"""
import io, json, math, os, random, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
MAPS = os.path.join(ROOT, 'godot', 'data', 'maps.json')
STORY = os.path.join(ROOT, 'godot', 'data', 'story.json')
DIFF = os.path.join(ROOT, 'godot', 'data', 'difficulty.json')
WS = 0.05  # px -> m


# ---------------- 幾何工具 ----------------
def rect(o, g=0):
    return (o['x'] - g, o['y'] - g, o['x'] + o.get('w', 0) + g, o['y'] + o.get('h', 0) + g)


def hit(a, b):
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def dseg(px, py, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    L = dx * dx + dy * dy
    t = 0.0 if L == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / L))
    return math.hypot(px - ax - t * dx, py - ay - t * dy)


class Water:
    """這張圖的水域模型：曲線海岸（海在哪一側）＋任意條河。
    給佈局器問「這裡是不是水」，跟 Terrain.gd 的判定同一套語意。"""

    def __init__(self, coast=None, rivers=None):
        self.coast = coast
        self.rivers = rivers or []

    def coast_x(self, py):
        pts = sorted(self.coast['pts'], key=lambda q: q[1])
        if py <= pts[0][1]:
            return pts[0][0]
        if py >= pts[-1][1]:
            return pts[-1][0]
        for i in range(len(pts) - 1):
            (ax, ay), (bx, by) = pts[i], pts[i + 1]
            if ay <= py <= by:
                t = 0.0 if by == ay else (py - ay) / (by - ay)
                return ax + t * (bx - ax)
        return pts[-1][0]

    def coast_y(self, px):
        pts = sorted(self.coast['pts'], key=lambda q: q[0])
        if px <= pts[0][0]:
            return pts[0][1]
        if px >= pts[-1][0]:
            return pts[-1][1]
        for i in range(len(pts) - 1):
            (ax, ay), (bx, by) = pts[i], pts[i + 1]
            if ax <= px <= bx:
                t = 0.0 if bx == ax else (px - ax) / (bx - ax)
                return ay + t * (by - ay)
        return pts[-1][1]

    def wet(self, px, py, pad=0.0):
        for rv in self.rivers:
            hw = rv['w'] * 0.5 + pad
            p = rv['pts']
            for i in range(len(p) - 1):
                if dseg(px, py, p[i], p[i + 1]) < hw:
                    return True
        if self.coast:
            side = self.coast.get('sea', 'west')
            if side == 'west':
                return px < self.coast_x(py) + pad
            if side == 'east':
                return px > self.coast_x(py) - pad
            if side == 'north':
                return py < self.coast_y(px) + pad
            if side == 'south':
                return py > self.coast_y(px) - pad
        return False


class MapBuilder:
    def __init__(self, mid, name, w, h, biome, ground, sky, allow, weather='clear'):
        self.m = {
            'id': mid, 'name': name, 'w': w, 'h': h, 'biome': biome,
            'ground': ground, 'sky': sky, 'allow': allow, 'weather': weather,
            'budget': 2000, 'solids': [], 'sandbags': [], 'bushes': [], 'foxholes': [],
            'hills': [], 'trenches': [], 'roads': [], 'deploy': [], 'bases': [],
            'deepwaters': [], 'waters': [], 'shallows': [], 'reefs': [],
            'roadblocks': [], 'tanktraps': [], 'wires': [], 'pillboxes': [],
            'containers': [], 'quays': [], 'bridges': [], 'fords': [], 'rivers': [],
            '_enriched': True,
        }
        self.W, self.H = w, h
        self.water = Water()
        self.rng = random.Random(hash(mid) & 0xffff)
        self.problems = []

    # -- 水 --
    def set_coast(self, sea, pts, depth=2.8, slope=95):
        self.m['coast'] = {'sea': sea, 'pts': pts, 'depth': depth, 'slope': slope}
        self.water.coast = self.m['coast']

    def add_river(self, pts, w=74, depth=1.2, bank=0.5):
        self.m['rivers'].append({'pts': pts, 'w': w, 'depth': depth, 'bank': bank})
        self.water.rivers.append({'pts': pts, 'w': w})

    def add_ford(self, x, y, r=110, shallow=0.4):
        self.m['fords'].append({'x': x, 'y': y, 'r': r, 'shallow': shallow})

    # -- 佈局 --
    def deploy(self, a, b):
        self.m['deploy'] = [a, b]

    def bases(self, a, b):
        self.m['bases'] = [dict(a, side=0), dict(b, side=1)]

    def building(self, x, y, w, h, floors=1, kind=None, note='', burning=False):
        d = {'x': x, 'y': y, 'w': w, 'h': h, 'floors': floors, 'note': note}
        if kind:
            d['kind'] = kind
        if burning:
            d['burning'] = True
        self.m['solids'].append(d)
        return d

    # -- 驗證（每張圖都要跑）--
    def _blocked_zones(self, grow_deploy=40):
        z = [rect(s, 6) for s in self.m['solids']]
        z += [rect(d, grow_deploy) for d in self.m['deploy']]
        return z

    def validate(self):
        p = self.problems
        sol, dep = self.m['solids'], self.m['deploy']
        if len(dep) != 2:
            p.append('部署區必須剛好兩塊（Main 是用 deploy[side] 索引的）')
        for i, a in enumerate(sol):
            r = rect(a)
            if r[0] < 0 or r[1] < 0 or r[2] > self.W or r[3] > self.H:
                p.append('建築出界: %s' % a['note'])
            for b in sol[i + 1:]:
                if hit(r, rect(b)):
                    p.append('建築重疊: %s / %s' % (a['note'], b['note']))
            for k, dz in enumerate(dep):
                if hit(r, rect(dz, 40)):
                    p.append('建築壓到部署區%d: %s' % (k, a['note']))
            for fx in range(5):
                for fy in range(5):
                    if self.water.wet(a['x'] + a['w'] * fx / 4.0, a['y'] + a['h'] * fy / 4.0, 8):
                        p.append('建築泡水: %s' % a['note'])
                        break
                else:
                    continue
                break
        for k, dz in enumerate(dep):
            r = rect(dz)
            if r[0] < 0 or r[1] < 0 or r[2] > self.W or r[3] > self.H:
                p.append('部署區%d 出界' % k)
            wet_n = 0
            for fx in range(7):
                for fy in range(9):
                    if self.water.wet(dz['x'] + dz['w'] * fx / 6.0, dz['y'] + dz['h'] * fy / 8.0, 12):
                        wet_n += 1
            if wet_n:
                p.append('部署區%d 有 %d 個取樣點泡水' % (k, wet_n))
        for b in self.m['bases']:
            dz = dep[b['side']] if b['side'] < len(dep) else None
            if dz and not (dz['x'] <= b['x'] <= dz['x'] + dz['w'] and dz['y'] <= b['y'] <= dz['y'] + dz['h']):
                p.append('主堡 side=%d 不在自家部署區內' % b['side'])
            if self.water.wet(b['x'], b['y'], 10):
                p.append('主堡 side=%d 泡水' % b['side'])
        zones = self._blocked_zones()
        for key, items in (('sandbags', self.m['sandbags']), ('containers', self.m['containers']),
                           ('pillboxes', self.m['pillboxes'])):
            for it in items:
                if key == 'sandbags':
                    r = rect(it)
                    cx, cy, rad = it['x'] + it['w'] / 2.0, it['y'] + it['h'] / 2.0, max(it['w'], it['h']) / 2.0
                else:
                    rad = 130 if key == 'containers' else 40
                    cx, cy = it['x'], it['y']
                    r = (cx - rad, cy - rad, cx + rad, cy + rad)
                if self.water.wet(cx, cy, rad):
                    p.append('%s 泡水 @(%d,%d)' % (key, cx, cy))
                for q in zones:
                    if hit(r, q):
                        p.append('%s 壓到建築/部署區 @(%d,%d)' % (key, cx, cy))
                        break
        for wr in self.m['wires']:
            for q in wr['pts']:
                if self.water.wet(q[0], q[1], 6) and not wr.get('inWater'):
                    p.append('鐵絲網泡水 @(%d,%d)' % (q[0], q[1]))
        # 有河橫貫全圖就必須有渡口或橋，否則南北兩岸被完全切開
        for rv in self.m['rivers']:
            xs = [q[0] for q in rv['pts']]
            ys = [q[1] for q in rv['pts']]
            spans = (max(xs) - min(xs) > self.W * 0.75) or (max(ys) - min(ys) > self.H * 0.75)
            if spans and not self.m['fords'] and not self.m['bridges']:
                p.append('河橫貫全圖但沒有渡口也沒有橋＝兩岸完全隔絕')
        return p

    # -- 自動佈點：草叢與彈坑（避開一切）--
    def scatter(self, bushes=0, craters=0, crater_r=(24, 36), bush_r=None, pad=46):
        # ★草叢大小依 biome 決定（2026-08-04 使用者：「有綠地的地圖草叢範圍要大一點，
        #   讓人物可以躲」）。舊值 (20,32)px＝直徑 2~3.2m，一個人站進去只是「在範圍內」，
        #   畫面上看起來就是一小撮草，躲不住。
        #   綠地系放大到 (34,70)px＝**直徑 3.4~7m**：蹲下完全藏得住、可以藏 2~4 人，
        #   對 70×50m 的戰場又不會塔掃。城鎮系也放大一級但仍較小（城市本來就少草）。
        #   ⚠ 半徑放大之後同一塊空地塞得下的叢數會變少，這是預期的：
        #     要的是「少而大」而不是「多而碎」。實際數量會由驗證器與下面的計數印出來。
        if bush_r is None:
            green = self.m.get('biome') in ('grass', 'forest', 'coast')
            bush_r = (34, 70) if green else (26, 48)
        zones = self._blocked_zones(grow_deploy=0)
        zones += [rect(s, 8) for s in self.m['sandbags']]
        placed = []

        def ok(x, y, r):
            if x - r < 12 or y - r < 12 or x + r > self.W - 12 or y + r > self.H - 12:
                return False
            if self.water.wet(x, y, r + 10):
                return False
            box = (x - r, y - r, x + r, y + r)
            for q in zones + placed:
                if hit(box, q):
                    return False
            for rd in self.m['roads']:
                if dseg(x, y, (rd['x1'], rd['y1']), (rd['x2'], rd['y2'])) < rd.get('w', 40) * 0.5 + r + 8:
                    return False
            return True

        for _ in range(20000):
            if len(self.m['bushes']) >= bushes:
                break
            r = self.rng.randint(*bush_r)
            x, y = self.rng.randint(40, self.W - 40), self.rng.randint(40, self.H - 40)
            if not ok(x, y, r):
                continue
            self.m['bushes'].append({'x': x, 'y': y, 'r': r})
            placed.append((x - r - pad, y - r - pad, x + r + pad, y + r + pad))
        for _ in range(20000):
            if len(self.m['foxholes']) >= craters:
                break
            r = self.rng.randint(*crater_r)
            x, y = self.rng.randint(60, self.W - 60), self.rng.randint(60, self.H - 60)
            if not ok(x, y, r):
                continue
            self.m['foxholes'].append({'x': x, 'y': y, 'r': r})
            placed.append((x - r - 70, y - r - 70, x + r + 70, y + r + 70))


    # -- 自動找一塊乾淨的部署區（手排必漏，讓程式找）--
    # side: 'west'/'east'/'north'/'south'/'center'
    def auto_deploy(self, side_a, side_b, w=180, h=None, margin=40):
        h = h or int(self.H * 0.34)
        self.m['deploy'] = [self._find_zone(side_a, w, h, margin),
                            self._find_zone(side_b, w, h, margin)]
        # 基地擺在各自部署區中心
        self.m['bases'] = []
        for i, dz in enumerate(self.m['deploy']):
            self.m['bases'].append({'x': int(dz['x'] + dz['w'] / 2), 'y': int(dz['y'] + dz['h'] / 2),
                                    'side': i})

    def _find_zone(self, side, w, h, margin):
        # ⚠ 找不到就要**放寬再找**，不可以直接回一個沒驗證過的框——
        #   那等於「驗證通過但資料是壞的」，正是本專案最貴的一類 bug。
        for shrink, band in ((1.0, 0.30), (0.82, 0.38), (0.66, 0.46), (0.5, 0.55)):
            z = self._find_zone_try(side, int(w * shrink), int(h * shrink), margin, band)
            if z:
                return z
        self.problems.append('找不到乾淨的部署區（side=%s，已放寬四次）' % side)
        return {'x': 40, 'y': 40, 'w': w, 'h': h}

    def _find_zone_try(self, side, w, h, margin, band):
        bl = [rect(s, margin) for s in self.m['solids']]
        bl += [rect(d, margin) for d in self.m['deploy'] if d]
        best = None
        cands = []
        step = 40
        if side in ('west', 'east'):
            xs = range(30, max(60, int(self.W * band)), step) if side == 'west'                 else range(int(self.W * (1.0 - band)), max(int(self.W * (1.0 - band)) + 1,
                                                           self.W - w - 30), step)
            ys = range(30, max(60, self.H - h - 30), step)
        elif side in ('north', 'south'):
            xs = range(30, max(60, self.W - w - 30), step)
            ys = range(30, max(60, int(self.H * band)), step) if side == 'north'                 else range(int(self.H * (1.0 - band)), max(int(self.H * (1.0 - band)) + 1,
                                                          self.H - h - 30), step)
        else:
            xs = range(int(self.W * 0.35), int(self.W * 0.65), step)
            ys = range(int(self.H * 0.35), int(self.H * 0.65), step)
        for x in xs:
            for y in ys:
                if x + w > self.W - 20 or y + h > self.H - 20:
                    continue
                z = {'x': x, 'y': y, 'w': w, 'h': h}
                r = rect(z)
                if any(hit(r, q) for q in bl):
                    continue
                wet = False
                for fx in range(7):
                    for fy in range(9):
                        if self.water.wet(x + w * fx / 6.0, y + h * fy / 8.0, 14):
                            wet = True
                            break
                    if wet:
                        break
                if wet:
                    continue
                # 越靠近該側邊緣越好（部署區本來就該在自己那一邊）
                score = x if side == 'west' else (self.W - x - w if side == 'east' else
                        (y if side == 'north' else (self.H - y - h if side == 'south' else 0)))
                if best is None or score < best[0]:
                    best = (score, z)
        return best[1] if best else None

    # -- 把壓到建築/部署區的碉堡與貨櫃推開；推不開才丟掉 --
    def nudge_props(self):
        zones = self._blocked_zones()
        for key, rad in (('pillboxes', 42), ('containers', 130)):
            keep = []
            for it in self.m[key]:
                ok = False
                for tryi in range(40):
                    dx = 0 if tryi == 0 else int((tryi % 8 - 3.5) * 46)
                    dy = 0 if tryi == 0 else int((tryi // 8 - 2) * 52)
                    cx, cy = it['x'] + dx, it['y'] + dy
                    box = (cx - rad, cy - rad, cx + rad, cy + rad)
                    if cx - rad < 20 or cy - rad < 20 or cx + rad > self.W - 20 or cy + rad > self.H - 20:
                        continue
                    if self.water.wet(cx, cy, rad) and not it.get('inWater'):
                        continue
                    if any(hit(box, q) for q in zones):
                        continue
                    it['x'], it['y'] = cx, cy
                    ok = True
                    break
                if ok:
                    keep.append(it)
            self.m[key] = keep

    def sandbag_line(self, x, y, n, horiz=False, step=56):
        """一排沙包。壓到東西的自動略過（不硬塞）。"""
        zones = self._blocked_zones(grow_deploy=0)
        for i in range(n):
            if horiz:
                d = {'x': x + i * step, 'y': y, 'w': 46, 'h': 12}
            else:
                d = {'x': x, 'y': y + i * step, 'w': 12, 'h': 46}
            cx, cy = d['x'] + d['w'] / 2.0, d['y'] + d['h'] / 2.0
            if self.water.wet(cx, cy, 30) or cx < 20 or cy < 20 or cx > self.W - 20 or cy > self.H - 20:
                continue
            if any(hit(rect(d), q) for q in zones):
                continue
            self.m['sandbags'].append(d)
