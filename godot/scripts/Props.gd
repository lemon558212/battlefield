# Props.gd — 戰場中景物件（GDD/14 §0a「質感來自光影與空間層次」）。
# 只有地形＋幾棟房子的戰場很空，第三人稱一站進去就露餡：眼睛高度沒有東西可看。
# 這裡補的是「人眼高度的密度」：道路、路障、拒馬、圍籬、電線桿、碎石瓦礫。
# 資料一律讀 maps.json（roads/roadblocks/tanktraps 早就有欄位，只是以前沒畫）。
#
# ⚠ 幾何一律合併成單一網格（同 Building 的教訓）：一根柵欄一個節點的話，
#   幾百根就是幾百次 draw call，幀時直接翻倍。
class_name BattleProps
extends Node3D

var _ws := 0.05
var _mw := 960.0
var _mh := 600.0
var _terrain = null
var _batch := {}
var _mats := {}
# 實體障礙清單（GDD/14 §2 的「人要跟實體一樣」延伸到中景物件）。
# 座標一律遊戲 px；兩種形狀：
#   {"t":"cir","c":Vector2,"r":float}  柱狀物（龍牙、電線桿、樹）
#   {"t":"seg","a":Vector2,"b":Vector2,"r":float}  牆狀物（護欄、柵欄）
# ⚠ 只登記「人真的過不去」的東西：路面、瓦礫碎石不登記（那些是跨得過去的）。
var blockers: Array = []
var _no_zones: Array[Rect2] = []
# 有殘骸的位置（Main 拿去點火：燒毀的車輛會一直冒煙，不是乾淨的靜態模型）
var wreck_spots: Array = []

# 建築周邊禁區判定（門口不能被自家柵欄堵死）
func _off_limits(p: Vector2) -> bool:
	for z in _no_zones:
		if z.has_point(p):
			return true
	return false

func build(map_data: Dictionary, world_scale: float, terrain) -> void:
	_ws = world_scale
	_mw = float(map_data.get("w", 960))
	_mh = float(map_data.get("h", 600))
	_terrain = terrain
	blockers.clear()
	# 建築周邊禁區：柵欄長進房子裡、電線桿卡在門口都是明顯的假，
	# 而且門是唯一入口，門前多一根柱子就等於這棟房子廢了。
	_no_zones.clear()
	for s in map_data.get("solids", []):
		_no_zones.append(Rect2(float(s.get("x", 0)), float(s.get("y", 0)),
				float(s.get("w", 60)), float(s.get("h", 60))).grow(2.5 / _ws))
	# 部署區也是禁區（2026-07-27 實測抓到）：柵欄長在部署格上，
	# 玩家一放下士兵就緊貼柵欄，按前進直接撞牆＝「人不會動」。
	# 出生點必須是乾淨的地面，這跟「門口不能被堵死」是同一條理由。
	for dz in map_data.get("deploy", []):
		_no_zones.append(Rect2(float(dz.get("x", 0)), float(dz.get("y", 0)),
				float(dz.get("w", 300)), float(dz.get("h", 200))).grow(1.0 / _ws))
	# 貼圖化（GDD/14 §0a）：磚是磚、水泥是水泥、路是柏油，純色時代根本看不出材質差別。
	# 沒有現成貼圖的（木、金屬、電線、燒黑）維持純色——硬套錯貼圖比純色更假。
	_mats = {
		"dirt": BattleMats.pbr("Concrete_Asphalt", 6.0, 0.98, Color(0.95, 0.90, 0.82)),
		"concrete": BattleMats.pbr("Concrete", 2.4, 0.95, Color(1.20, 1.18, 1.12)),
		"wood": _mat(Color(0.38, 0.28, 0.18), 0.92),
		"metal": _mat(Color(0.28, 0.29, 0.30), 0.55),
		"rock": BattleMats.pbr("Concrete", 1.1, 0.95, Color(0.92, 0.90, 0.84)),
		"rust": _mat(Color(0.31, 0.20, 0.13), 0.98),
		"burn": _mat(Color(0.30, 0.26, 0.22), 1.0),   # 純黑在黃昏會變成黑洞，提亮成焦土色
		"brick": BattleMats.pbr("RedBrick", 1.6, 0.96, Color(1.30, 1.10, 0.98)),
		"brick2": BattleMats.pbr("RedBrick", 1.6, 0.97, Color(1.05, 0.86, 0.76)),
		"cable": _mat(Color(0.09, 0.09, 0.10), 0.85),
		"steel": _mat(Color(0.42, 0.44, 0.46), 0.55),
		"cargo1": _mat(Color(0.55, 0.24, 0.18), 0.88),
		"cargo2": _mat(Color(0.18, 0.36, 0.44), 0.88),
		"cargo3": _mat(Color(0.52, 0.48, 0.22), 0.88),
		# 地面痕跡專用（2026-07-27 使用者：「深色小方塊，還要更淡」）：
		# 先前借用 "dirt"＝柏油貼圖，比土地暗一大截，於是每一片都讀成一個深色方塊。
		# 痕跡本來就只是「土被踩過、顏色深一點」，對比要小到幾乎看不出邊界。
		"mark": _mat(Color(0.34, 0.27, 0.19), 1.0),
	}
	_roads(map_data)
	_blocks(map_data)
	_teeth(map_data)
	_fences(map_data)
	_poles(map_data)
	_rubble(map_data)
	_wrecks(map_data)
	_wires(map_data)
	_pillboxes(map_data)
	_containers(map_data)
	_quays(map_data)
	_bridges(map_data)
	_walls_brick(map_data)
	_cables(map_data)
	_scorch(map_data)
	_clutter(map_data)
	_flush()

# ---------- 各類物件 ----------
func _roads(m: Dictionary) -> void:
	for r in m.get("roads", []):
		var a := Vector2(float(r.get("x1", 0)), float(r.get("y1", 0)))
		var b := Vector2(float(r.get("x2", 0)), float(r.get("y2", 0)))
		var w: float = float(r.get("w", 40)) * _ws
		var seg: int = maxi(2, int(a.distance_to(b) * _ws / 4.0))
		# 路面要一段一段鋪才貼得住起伏地形（一整片長方形會插進丘陵裡）
		for i in seg:
			var p0: Vector2 = a.lerp(b, float(i) / float(seg))
			var p1: Vector2 = a.lerp(b, float(i + 1) / float(seg))
			var mid: Vector2 = (p0 + p1) * 0.5
			var len_m: float = (p1 - p0).length() * _ws
			var ang: float = atan2(p1.y - p0.y, p1.x - p0.x)
			_box("dirt", Vector3(len_m + 0.15, 0.12, w),
					Transform3D(Basis(Vector3.UP, -ang), _pos(mid.x, mid.y, 0.02)))

func _blocks(m: Dictionary) -> void:
	for rb in m.get("roadblocks", []):
		var cx: float = float(rb.get("x", 0))
		var cy: float = float(rb.get("y", 0))
		var w: float = float(rb.get("w", 120)) * _ws
		var n: int = maxi(2, int(w / 1.6))
		# 一整排護欄＝一條線段障礙（比逐塊圓形省，而且中間不會有縫可以鑽）
		var half: float = float(rb.get("w", 120)) * 0.5
		_blk_seg(Vector2(cx - half, cy), Vector2(cx + half, cy), 0.36, 0.85)
		for i in n:
			var t: float = (float(i) + 0.5) / float(n) - 0.5
			var px: float = cx + t * float(rb.get("w", 120))
			# 紐澤西護欄：下寬上窄的混凝土塊
			_box("concrete", Vector3(1.35, 0.35, 0.62), Transform3D(Basis(), _pos(px, cy, 0.17)))
			_box("concrete", Vector3(1.2, 0.5, 0.34), Transform3D(Basis(), _pos(px, cy, 0.58)))

func _teeth(m: Dictionary) -> void:
	for tt in m.get("tanktraps", []):
		var cx: float = float(tt.get("x", 0))
		var cy: float = float(tt.get("y", 0))
		var w: float = float(tt.get("w", 116))
		var h: float = float(tt.get("h", 52))
		for i in 6:
			var px: float = cx + (float(i % 3) - 1.0) * w * 0.34
			var py: float = cy + (float(i / 3) - 0.5) * h * 0.6
			if _off_limits(Vector2(px, py)):
				continue
			# 龍牙：四角錐用兩個交叉薄箱近似，低多邊形風格夠用
			# 龍牙本來就是「車過不去、人可以繞」的東西，所以是各自獨立的圓，不連成線
			_blk_cir(Vector2(px, py), 0.62, 1.10)
			_box("concrete", Vector3(0.5, 1.1, 0.5),
					Transform3D(Basis(Vector3.UP, deg_to_rad(45)).scaled(Vector3(1, 1, 1)), _pos(px, py, 0.55)))
			_box("concrete", Vector3(0.9, 0.22, 0.9), Transform3D(Basis(), _pos(px, py, 0.11)))

func _fences(m: Dictionary) -> void:
	# 沿道路兩側拉木柵欄：最便宜的「有人住過」訊號
	for r in m.get("roads", []):
		var a := Vector2(float(r.get("x1", 0)), float(r.get("y1", 0)))
		var b := Vector2(float(r.get("x2", 0)), float(r.get("y2", 0)))
		var dir: Vector2 = (b - a).normalized()
		var nrm := Vector2(-dir.y, dir.x)
		var total: float = a.distance_to(b)
		var step := 55.0
		var off: float = float(r.get("w", 40)) * 0.9
		for side in [-1.0, 1.0]:
			var d := 40.0
			var seg_i := 0
			while d < total - 40.0:
				seg_i += 1
				# 隔段留缺（2.75m 柵、2.75m 缺交錯）＝田埂出入口。連續路邊柵欄會把
				# 路變成一道牆：ch01 壓測抓到人卡在柵欄外 19m 進不了基地。每 4 段留
				# 1 缺仍不夠——滑行搜尋只有 ±3m，繞路演算法對長牆無力（第二輪實測）。
				# 兩側錯開半拍，穿越道路是小 zigzag，不會排成對齊的走廊。
				if seg_i % 2 == (0 if side > 0.0 else 1):
					d += step
					continue
				var p: Vector2 = a + dir * d + nrm * off * side
				if _off_limits(p) or _off_limits(p + dir * step):
					d += step
					continue
				if _terrain != null and _terrain.in_trench(p.x, p.y):
					d += step
					continue
				_box("wood", Vector3(0.12, 1.05, 0.12), Transform3D(Basis(), _pos(p.x, p.y, 0.52)))
				# 柵欄是連續的橫杆，障礙必須是線段——只登記柱子的話人會從兩柱之間穿過去
				_blk_seg(p, p + dir * step, 0.14, 1.05, true)   # 木柵欄：擋人不擋彈
				var p2: Vector2 = p + dir * step * 0.5
				var ang: float = atan2(dir.y, dir.x)
				for hh in [0.55, 0.9]:
					_box("wood", Vector3(step * _ws, 0.08, 0.05),
							Transform3D(Basis(Vector3.UP, -ang), _pos(p2.x, p2.y, hh)))
				d += step

func _poles(m: Dictionary) -> void:
	for r in m.get("roads", []):
		var a := Vector2(float(r.get("x1", 0)), float(r.get("y1", 0)))
		var b := Vector2(float(r.get("x2", 0)), float(r.get("y2", 0)))
		var dir: Vector2 = (b - a).normalized()
		var nrm := Vector2(-dir.y, dir.x)
		var total: float = a.distance_to(b)
		var d := 120.0
		while d < total - 60.0:
			var p: Vector2 = a + dir * d + nrm * float(r.get("w", 40)) * 1.6
			if _off_limits(p) or (_terrain != null and _terrain.in_water(p.x, p.y)):
				d += 260.0
				continue
			_blk_cir(p, 0.32, 6.2, true)                    # 木電線桿：擋人不擋彈
			_box("wood", Vector3(0.22, 6.2, 0.22), Transform3D(Basis(), _pos(p.x, p.y, 3.1)))
			_box("wood", Vector3(1.6, 0.14, 0.14), Transform3D(Basis(), _pos(p.x, p.y, 5.6)))
			d += 260.0

func _rubble(m: Dictionary) -> void:
	# 彈坑與建築附近散落瓦礫：碎石是「這裡打過仗」最直接的視覺線索
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260726
	var spots: Array = []
	for c in m.get("foxholes", []):
		spots.append([float(c.get("x", 0)), float(c.get("y", 0)), float(c.get("r", 36)) * 1.6])
	for s in m.get("solids", []):
		spots.append([float(s.get("x", 0)) + float(s.get("w", 60)) * 0.5,
				float(s.get("y", 0)) + float(s.get("h", 60)) * 0.5,
				maxf(float(s.get("w", 60)), float(s.get("h", 60))) * 1.1])
	for sp in spots:
		for i in 14:
			var ang: float = rng.randf() * TAU
			var dd: float = sqrt(rng.randf()) * float(sp[2])
			var px: float = float(sp[0]) + cos(ang) * dd
			var py: float = float(sp[1]) + sin(ang) * dd
			var sz: float = rng.randf_range(0.14, 0.42)
			# 埋 1/3 進土＋隨機傾倒：正擺在地表的方塊像垃圾桶蓋（實拍），
			# 真實碎石是半埋而且歪的（鐵律 0：有重量的東西會沉進軟土）
			_box("rock", Vector3(sz, sz * rng.randf_range(0.4, 0.8), sz * rng.randf_range(0.7, 1.3)),
					Transform3D(Basis(Vector3.UP, rng.randf() * TAU)
					* Basis(Vector3(1, 0, 0), rng.randf_range(-0.3, 0.3)),
					_pos(px, py, sz * 0.12)))
			# 大塊的瓦礫也要擋人（小碎石仍可跨過）
			if sz > 0.36:
				_blk_cir(Vector2(px, py), sz * 0.5, sz * 0.6)

# ---------- 戰爭痕跡（GDD/14 §0a：這裡打過仗）----------
# 車輛殘骸：燒毀的卡車骨架。放在道路旁與彈坑附近——車不會憑空停在草原中間。
func _wrecks(m: Dictionary) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 77120
	var spots: Array = []
	for r in m.get("roads", []):
		var a := Vector2(float(r.get("x1", 0)), float(r.get("y1", 0)))
		var b := Vector2(float(r.get("x2", 0)), float(r.get("y2", 0)))
		var dir: Vector2 = (b - a).normalized()
		var nrm := Vector2(-dir.y, dir.x)
		var total: float = a.distance_to(b)
		for t in [0.22, 0.63, 0.88]:
			spots.append([a + dir * total * t + nrm * float(r.get("w", 40)) * rng.randf_range(0.7, 1.1),
					atan2(dir.y, dir.x) + rng.randf_range(-0.5, 0.5)])
	for sp in spots:
		var p: Vector2 = sp[0]
		if not _off_limits(p) and (_terrain == null or not _terrain.in_water(p.x, p.y)):
			wreck_spots.append(p)
		if _off_limits(p):
			continue
		var ang: float = sp[1]
		var b3 := Basis(Vector3.UP, -ang)
		# 車身（燒穿的貨斗）＋駕駛室＋四個燒剩的輪子，全部低多邊形
		_box("rust", Vector3(4.6, 0.55, 2.1), Transform3D(b3, _pos(p.x, p.y, 0.62)))
		_box("rust", Vector3(1.7, 1.25, 2.0), Transform3D(b3, _pos(p.x, p.y, 1.35)
				+ b3 * Vector3(1.35, 0, 0)))
		for sx in [-1.5, 1.5]:
			for sz in [-0.95, 0.95]:
				_box("burn", Vector3(0.85, 0.85, 0.32),
						Transform3D(b3, _pos(p.x, p.y, 0.42) + b3 * Vector3(sx, 0, sz)))
		# 側板歪斜：完好的方盒看起來像停在那裡，不像被打壞的
		_box("rust", Vector3(3.4, 1.0, 0.12),
				Transform3D(b3 * Basis(Vector3.FORWARD, deg_to_rad(24.0)),
				_pos(p.x, p.y, 1.15) + b3 * Vector3(-0.4, 0, 1.0)))
		# 車體 4.6×2.1m（駕駛室往 +X 再突出到 2.2m）→ 半長 2.35、半寬 1.05
		_blk_obb(p, ang, Vector2(2.35, 1.05), 1.90)
		_scorch_at(p, 3.4)

# 磚牆殘段：城鎮感最便宜的來源，而且是天然掩體
func _walls_brick(m: Dictionary) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4410
	for sd in m.get("solids", []):
		var cx: float = float(sd.get("x", 0)) + float(sd.get("w", 60)) * 0.5
		var cy: float = float(sd.get("y", 0)) + float(sd.get("h", 60)) * 0.5
		var rr: float = maxf(float(sd.get("w", 60)), float(sd.get("h", 60))) * 0.9 + 6.0 / _ws
		for k in 1:
			var a: float = rng.randf() * TAU
			var p := Vector2(cx + cos(a) * rr, cy + sin(a) * rr)
			var ang: float = a + PI * 0.5
			var segn: int = rng.randi_range(3, 5)
			var dirv := Vector2(cos(ang), sin(ang))
			# ⚠ 一整片純色板子看不出是磚牆（實拍就是一面黑板）。改成逐層堆砌：
			#   每層 0.24m、深淺兩色交錯、每塊略微錯位，磚砌感才出得來。
			#   高度也降到半身牆——被炸垮的殘牆本來就不高，而且這樣才是好用的掩體。
			for i in segn:
				var q: Vector2 = p + dirv * (float(i) - float(segn) * 0.5) * (0.92 / _ws)
				# 高度往一端遞減＝被炸垮的樣子，再加隨機讓頂端破損不齊
				var hh: float = 1.55 * (1.0 - float(i) / float(segn) * rng.randf_range(0.25, 0.6))
				hh *= rng.randf_range(0.88, 1.05)
				if hh < 0.5:
					continue      # 太矮的整段不畫：一截 0.3m 的牆看起來是散落的板子，不是牆
				var layers: int = maxi(2, int(hh / 0.24))
				for ly in layers:
					var lyh: float = hh / float(layers)
					var shift: float = (0.055 if ly % 2 == 0 else -0.055) + rng.randf_range(-0.02, 0.02)
					var key: String = "brick" if (ly + i) % 2 == 0 else "brick2"
					# ★最底層往下埋 0.4m（2026-07-27 使用者：「紅磚牆浮空不接地」）。
					#   每個 0.9m 寬的磚塊只取牆段中心一個地形高度，地面一有起伏，
					#   兩端就懸空。把最底層加長往下埋，任何坡度都不會再看到牆底的縫。
					var extra: float = 0.4 if ly == 0 else 0.0
					_box(key, Vector3(0.9, lyh * 0.94 + extra, 0.28),
							Transform3D(Basis(Vector3.UP, -ang),
							_pos(q.x, q.y, lyh * (float(ly) + 0.5) - extra * 0.5) + Vector3(shift, 0, 0)))
				_ground_skirt(q, ang, rng)
			var half: Vector2 = dirv * float(segn) * 0.5 * (1.1 / _ws)
			_blk_seg(p - half, p + half, 0.20, 1.25)

# 牆腳的碎料堆（使用者的品質判準之一：「與地面的過渡，不可以硬插進地面」）。
# 現實裡沒有任何東西是「一條直線切進土裡」的——牆腳一定有掉下來的磚塊、
# 被雨打出來的土堆。幾塊小方塊就能把那條生硬的交界線藏掉。
func _ground_skirt(q: Vector2, ang: float, rng: RandomNumberGenerator) -> void:
	for k in rng.randi_range(3, 5):
		var off := Vector2(rng.randf_range(-0.55, 0.55), rng.randf_range(-0.30, 0.30)).rotated(ang)
		var p := q + off / _ws
		var sx: float = rng.randf_range(0.16, 0.34)
		var sy: float = rng.randf_range(0.07, 0.15)
		_box("brick2" if k % 2 == 0 else "rock", Vector3(sx, sy, sx * rng.randf_range(0.6, 1.0)),
				Transform3D(Basis(Vector3.UP, rng.randf() * TAU), _pos(p.x, p.y, sy * 0.35)))

# 電線：桿子有了卻沒有線，遠看就是一排孤零零的木頭。線是垂鏈，分段畫。
func _cables(m: Dictionary) -> void:
	for r in m.get("roads", []):
		var a := Vector2(float(r.get("x1", 0)), float(r.get("y1", 0)))
		var b := Vector2(float(r.get("x2", 0)), float(r.get("y2", 0)))
		var dir: Vector2 = (b - a).normalized()
		var nrm := Vector2(-dir.y, dir.x)
		var total: float = a.distance_to(b)
		var d := 120.0
		var prev := Vector2.ZERO
		var has_prev := false
		while d < total - 60.0:
			var p: Vector2 = a + dir * d + nrm * float(r.get("w", 40)) * 1.6
			if _off_limits(p) or (_terrain != null and _terrain.in_water(p.x, p.y)):
				has_prev = false
				d += 260.0
				continue
			if has_prev:
				var span: float = prev.distance_to(p) * _ws
				var steps := 6
				# ⚠ 高度要沿「兩根桿子的桿頂」內插，不可每段各自取腳下地形高——
				#   地形一起伏，每段基準高度都不同，電線就斷成一節節懸空黑棒
				#   （QA 反驗證實拍抓到：forest/beach/desert 人眼視角天上飄黑槓）。
				var h0: float = _terrain.height_at(prev.x, prev.y) if _terrain != null else 0.0
				var h1: float = _terrain.height_at(p.x, p.y) if _terrain != null else 0.0
				for i in steps:
					var t0: float = float(i) / float(steps)
					var t1: float = float(i + 1) / float(steps)
					var tm: float = (t0 + t1) * 0.5
					var m0: Vector2 = prev.lerp(p, tm)
					var sag: float = 0.9 * sin(PI * tm)      # 垂鏈：中間下垂最多
					var hm: float = _terrain.height_at(m0.x, m0.y) if _terrain != null else 0.0
					var ang2: float = atan2(p.y - prev.y, p.x - prev.x)
					_box("cable", Vector3(span / float(steps) + 0.1, 0.06, 0.06),
							Transform3D(Basis(Vector3.UP, -ang2),
							_pos(m0.x, m0.y, lerpf(h0, h1, tm) + 5.5 - sag - hm)))
			prev = p
			has_prev = true
			d += 260.0

# 彈坑焦土：彈坑只有形狀沒有痕跡，看起來像天然凹地
func _scorch(m: Dictionary) -> void:
	for c in m.get("foxholes", []):
		_scorch_at(Vector2(float(c.get("x", 0)), float(c.get("y", 0))),
				float(c.get("r", 36)) * _ws * 1.3)

func _scorch_at(c: Vector2, r_m: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(absf(c.x) * 31.0 + absf(c.y))
	for i in 7:
		var a: float = rng.randf() * TAU
		var d: float = sqrt(rng.randf()) * r_m / _ws
		# ⚠ 舊值：1.5m 見方、4cm 厚、離地 3cm 的純黑方塊，在黃昏光線下就是一個黑洞
		#   （使用者 2026-07-27 截圖）。焦痕要薄、要小、要貼平。
		var sz: float = rng.randf_range(0.35, 0.9)
		_box("burn", Vector3(sz, 0.010, sz * rng.randf_range(0.6, 1.4)),
				Transform3D(Basis(Vector3.UP, rng.randf() * TAU),
				_pos(c.x + cos(a) * d, c.y + sin(a) * d, -0.004)))

# ---------- 障礙登記 ----------
# 半徑參數用公尺（跟建模同一套單位，改的時候不用心算），存進去統一換成 px。
# h_m＝這個障礙的實際高度（公尺）。人的碰撞不看高度（都擋），但彈道要看：
# 0.95m 的護欄擋得住趴著與蹲著的人的彈道，擋不住站姿對站姿的對射——這是
# 使用者 2026-07-26 指正「子彈可以穿過這些物體」的正解，不是一律擋或一律不擋。
# pen＝子彈打得穿（鐵律 0②：材質不同，擋彈能力就不同）。
# 木柵欄、木電線桿擋得住人，但擋不住步槍彈——真實步槍彈輕鬆穿過 2cm 木板。
# 沙包、混凝土龍牙、車體才是真的擋彈物。
func _blk_cir(c: Vector2, r_m: float, h_m: float, pen := false) -> void:
	blockers.append({"t": "cir", "c": c, "r": r_m / _ws, "h": h_m, "pen": pen})

# 長條形物件（車輛殘骸）。用圓形近似會讓長軸兩端各有一段完全沒有實體——
# 卡車殘骸 4.6m 長、圓半徑 1.5m ＝從車頭或車尾走進貨斗裡（使用者 2026-07-27 實測）。
# ang＝長軸方向（px 平面的角度，與畫幾何用的 Basis(UP, -ang) 一致）。
func _blk_obb(c: Vector2, ang: float, half_m: Vector2, h_m: float, pen := false) -> void:
	blockers.append({"t": "obb", "c": c, "ax": Vector2(cos(ang), sin(ang)),
			"e": half_m / _ws, "r": 0.0, "h": h_m, "pen": pen})

func _blk_seg(a: Vector2, b: Vector2, r_m: float, h_m: float, pen := false) -> void:
	# 順手存中點與半長：碰撞時先用它做粗剔除，才不用對每段柵欄都算一次最近點
	blockers.append({"t": "seg", "a": a, "b": b, "r": r_m / _ws, "h": h_m, "pen": pen,
			"m": (a + b) * 0.5, "hl": a.distance_to(b) * 0.5})


# ---------- 劇本要求的地形元素（2026-07-28）----------
# 使用者：「該出現什麼就要有什麼」。以下是劇本明講、引擎先前完全沒有的幾件。

# 鐵絲網：樁 + 三條刺線 + 交叉線。
# 物理上它**擋人但不擋子彈**（pen=true）——這正是鐵絲網的戰術意義：
# 它不保護你，它只是把你留在機槍的射界裡。高度 1.0m（跨不過去）。
func _wires(m: Dictionary) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5150
	for w in m.get("wires", []):
		var pts: Array = w.get("pts", [])
		if pts.size() < 2:
			continue
		var hgt: float = float(w.get("h", 1.0))
		for i in range(pts.size() - 1):
			var a := Vector2(float(pts[i][0]), float(pts[i][1]))
			var b := Vector2(float(pts[i + 1][0]), float(pts[i + 1][1]))
			var seg_len: float = a.distance_to(b)
			if seg_len < 1.0:
				continue
			var n: int = maxi(2, int(seg_len * _ws / 2.2))
			var dirv: Vector2 = (b - a).normalized()
			var ang: float = atan2(dirv.y, dirv.x)
			for k in range(n + 1):
				var q: Vector2 = a.lerp(b, float(k) / float(n))
				if _off_limits(q):
					continue
				var lean := Basis(Vector3(1, 0, 0), rng.randf_range(-0.12, 0.12))
				_box("steel", Vector3(0.07, hgt, 0.07), Transform3D(lean, _pos(q.x, q.y, hgt * 0.5)))
			var mid_p: Vector2 = (a + b) * 0.5
			for lvl in [0.28, 0.58, 0.90]:
				_box("cable", Vector3(seg_len * _ws, 0.035, 0.035),
						Transform3D(Basis(Vector3.UP, -ang), _pos(mid_p.x, mid_p.y, hgt * float(lvl))))
			var cross: int = maxi(1, n / 2)
			for k2 in cross:
				var tm: float = (float(k2) + 0.5) / float(cross)
				var mp: Vector2 = a.lerp(b, tm)
				var span: float = seg_len * _ws / float(cross)
				var rise: float = hgt * 0.62
				var diag: float = sqrt(span * span + rise * rise)
				for sgn in [-1.0, 1.0]:
					var tilt: float = atan2(rise * sgn, span)
					_box("cable", Vector3(diag, 0.03, 0.03),
							Transform3D(Basis(Vector3.UP, -ang) * Basis(Vector3(0, 0, 1), tilt),
							_pos(mp.x, mp.y, hgt * 0.59)))
			_blk_seg(a, b, 0.35, hgt, true)

# 機槍堡（碉堡）：混凝土盒 + 射孔帶 + 帽簷。
# 射孔朝 `face`（度數）：碉堡的正面與背面戰術價值完全不同，玩家要看得出它對著哪邊。
func _pillboxes(m: Dictionary) -> void:
	for pb in m.get("pillboxes", []):
		var c := Vector2(float(pb.get("x", 0)), float(pb.get("y", 0)))
		var face: float = deg_to_rad(float(pb.get("face", 0)))
		var sz: float = float(pb.get("size", 1.0))
		var b := Basis(Vector3.UP, -face)
		var w: float = 3.4 * sz
		var d: float = 2.6 * sz
		var h: float = 1.9 * sz
		_box("concrete", Vector3(w, h * 0.55, d), Transform3D(b, _pos(c.x, c.y, h * 0.275)))
		_box("concrete", Vector3(w, h * 0.28, d), Transform3D(b, _pos(c.x, c.y, h * 0.86)))
		# ⚠ 射孔要是一條**窄縫**，不是整面開口。第一版留了整面開口，
		#   從外面看進去是一團沒有打光的黑洞（實拍第三章俯瞰）。
		#   真的碉堡射孔寬約 0.9m，兩側是厚實的混凝土。
		var slit: float = 0.9 * sz
		for sgn in [-1.0, 1.0]:
			var pier: float = (w - slit) * 0.5
			_box("concrete", Vector3(pier, h * 0.17, d),
					Transform3D(b, _pos(c.x, c.y, h * 0.635)
					+ b * Vector3(sgn * (w - pier) * 0.5, 0, 0)))
		# 內部樓板與後牆：沒有這兩件，從射孔看進去仍是空的
		_box("concrete", Vector3(w, 0.18 * sz, d),
				Transform3D(b, _pos(c.x, c.y, h * 0.55)))
		_box("concrete", Vector3(w, h * 0.17, 0.5 * sz),
				Transform3D(b, _pos(c.x, c.y, h * 0.635) + b * Vector3(0, 0, -d * 0.5 + 0.25 * sz)))
		_box("concrete", Vector3(w * 1.12, 0.18 * sz, d * 1.12),
				Transform3D(b, _pos(c.x, c.y, h + 0.09 * sz)))
		# 與地面的過渡：土堤堆在四周（碉堡不會是「放在草地上的水泥盒」）。
		# 2026-07-28 使用者：「土堆要更真實」——原本 8 個平放方盒排一圈，像積木。
		# 改成：每個位置兩塊**斜插交疊**的土塊（俯仰＋滾轉都亂給，彼此咬合），
		# 數量加密到 14 塊互相搭接成連續土堤，縫隙再灑碎石。斜插的盒子彼此交疊後
		# 輪廓線是亂的，讀起來就是「堆出來的土」而不是「擺上去的盒子」。
		var rng2 := RandomNumberGenerator.new()
		rng2.seed = int(absf(c.x) * 7.0 + absf(c.y) * 13.0)
		for k in 14:
			var a2: float = TAU * float(k) / 14.0 + rng2.randf_range(-0.16, 0.16)
			var rr: float = (maxf(w, d) * 0.5 + 0.35) * rng2.randf_range(0.88, 1.12)
			var bx: float = c.x + cos(a2) * rr / _ws
			var by: float = c.y + sin(a2) * rr / _ws
			for layer in 2:
				var msz: float = rng2.randf_range(0.45, 0.95) * sz * (1.0 - 0.25 * float(layer))
				var tiltb := Basis(Vector3.UP, a2 + rng2.randf_range(-0.5, 0.5)) \
						* Basis(Vector3(1, 0, 0), rng2.randf_range(-0.30, 0.30)) \
						* Basis(Vector3(0, 0, 1), rng2.randf_range(-0.22, 0.22))
				_box("dirt", Vector3(msz, msz * 0.42, msz * 0.75),
						Transform3D(tiltb, _pos(bx + rng2.randf_range(-3.0, 3.0),
						by + rng2.randf_range(-3.0, 3.0),
						msz * (0.10 + 0.16 * float(layer)))))
			if rng2.randf() < 0.6:
				var ssz: float = rng2.randf_range(0.10, 0.22) * sz
				_box("rock", Vector3(ssz, ssz * 0.8, ssz),
						Transform3D(Basis(Vector3.UP, rng2.randf() * TAU),
						_pos(bx + rng2.randf_range(-5.0, 5.0),
						by + rng2.randf_range(-5.0, 5.0), ssz * 0.3)))
		_blk_cir(c, maxf(w, d) * 0.52, h)

# 貨櫃：港口與城區最好用的掩體，也是第 10 章的劇情道具（走私貨櫃）。
# 40 呎櫃真實尺寸 12.2 x 2.44 x 2.59m。
func _containers(m: Dictionary) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 8891
	var keys := ["cargo1", "cargo2", "cargo3"]
	for ct in m.get("containers", []):
		var c := Vector2(float(ct.get("x", 0)), float(ct.get("y", 0)))
		var ang: float = deg_to_rad(float(ct.get("rot", 0)))
		var stack: int = maxi(1, int(ct.get("stack", 1)))
		var b := Basis(Vector3.UP, -ang)
		for lvl in stack:
			var key: String = keys[rng.randi() % keys.size()]
			var yy: float = 1.3 + float(lvl) * 2.62
			var off: Vector3 = b * Vector3(rng.randf_range(-0.12, 0.12), 0.0,
					rng.randf_range(-0.08, 0.08))
			_box(key, Vector3(12.2, 2.59, 2.44), Transform3D(b, _pos(c.x, c.y, yy) + off))
			# 瓦楞側板（2026-07-28 使用者：貨櫃要更真實）：貨櫃側面是垂直波浪板，
			# 不是平板。每 0.55m 一條凸稜（同色，靠自身陰影讀出起伏——低多邊形的做法），
			# 兩長側各 21 條。頂樓那層看得到的稜多、地面那層常被擋，全都給。
			var ribs := 21
			for ri in ribs:
				var rx: float = (float(ri) - float(ribs - 1) * 0.5) * 0.55
				for sgn0 in [-1.0, 1.0]:
					_box(key, Vector3(0.24, 2.45, 0.07),
							Transform3D(b, _pos(c.x, c.y, yy) + off
							+ b * Vector3(rx, 0.0, sgn0 * 1.24)))
			# 端框（角柱）
			for sgn in [-1.0, 1.0]:
				_box("steel", Vector3(0.12, 2.59, 2.5),
						Transform3D(b, _pos(c.x, c.y, yy) + off + b * Vector3(sgn * 6.05, 0, 0)))
			# 門端（+X 端）：兩扇門的分縫＋四根垂直鎖桿＋把手——貨櫃的「臉」，
			# 沒有它兩端長一樣，怎麼看都是一塊漆了色的磚。
			_box("steel", Vector3(0.05, 2.45, 0.06),
					Transform3D(b, _pos(c.x, c.y, yy) + off + b * Vector3(6.12, 0, 0)))
			for rz in [-0.92, -0.36, 0.36, 0.92]:
				_box("steel", Vector3(0.09, 2.45, 0.09),
						Transform3D(b, _pos(c.x, c.y, yy) + off + b * Vector3(6.14, 0, rz)))
				_box("steel", Vector3(0.16, 0.10, 0.28),
						Transform3D(b, _pos(c.x, c.y, yy - 0.35) + off + b * Vector3(6.16, 0, rz)))
		_blk_obb(c, ang, Vector2(6.2, 1.3), 2.59 + float(stack - 1) * 2.62)

# 碼頭：伸進水裡的混凝土平台＋繫船柱。是**可以走上去的平台**，不是障礙。
func _quays(m: Dictionary) -> void:
	for q in m.get("quays", []):
		var x: float = float(q.get("x", 0))
		var y: float = float(q.get("y", 0))
		var w: float = float(q.get("w", 200))
		var h: float = float(q.get("h", 60))
		var cx: float = x + w * 0.5
		var cy: float = y + h * 0.5
		_box("concrete", Vector3(w * _ws, 1.4, h * _ws), Transform3D(Basis(), _pos(cx, cy, 0.7)))
		var n: int = maxi(2, int(w * _ws / 6.0))
		for i in range(n + 1):
			var px: float = x + w * float(i) / float(n)
			_box("steel", Vector3(0.34, 0.62, 0.34), Transform3D(Basis(), _pos(px, y + 4.0, 1.65)))
			_box("steel", Vector3(0.34, 0.62, 0.34),
					Transform3D(Basis(), _pos(px, y + h - 4.0, 1.65)))
		blockers.append({"t": "obb", "c": Vector2(cx, cy), "ax": Vector2(1, 0),
				"e": Vector2(w * 0.5, h * 0.5), "r": 0.0, "h": 1.4, "k": "quay"})

# 橋：橋面＋護欄＋橋墩。broken > 0 時中段缺一塊（第 7 章「斷橋之城」）。
func _bridges(m: Dictionary) -> void:
	for bg in m.get("bridges", []):
		var a := Vector2(float(bg.get("x1", 0)), float(bg.get("y1", 0)))
		var b := Vector2(float(bg.get("x2", 0)), float(bg.get("y2", 0)))
		var w: float = float(bg.get("w", 70)) * _ws
		var broken: float = clampf(float(bg.get("broken", 0.0)), 0.0, 0.9)
		var total: float = a.distance_to(b)
		if total < 1.0:
			continue
		var dirv: Vector2 = (b - a).normalized()
		var ang: float = atan2(dirv.y, dirv.x)
		var segs: int = maxi(4, int(total * _ws / 3.0))
		var gap0: float = 0.5 - broken * 0.5
		var gap1: float = 0.5 + broken * 0.5
		for i in segs:
			var tm: float = (float(i) + 0.5) / float(segs)
			if broken > 0.01 and tm > gap0 and tm < gap1:
				continue
			var p: Vector2 = a.lerp(b, tm)
			var seg_m: float = total * _ws / float(segs)
			_box("concrete", Vector3(seg_m + 0.1, 0.55, w),
					Transform3D(Basis(Vector3.UP, -ang), _pos(p.x, p.y, 1.9)))
			for sgn in [-1.0, 1.0]:
				_box("steel", Vector3(seg_m + 0.1, 0.65, 0.14),
						Transform3D(Basis(Vector3.UP, -ang), _pos(p.x, p.y, 2.5)
						+ Basis(Vector3.UP, -ang) * Vector3(0, 0, sgn * w * 0.5)))
			blockers.append({"t": "obb", "c": p, "ax": Vector2(cos(ang), sin(ang)),
					"e": Vector2(seg_m * 0.5 / _ws, w * 0.5 / _ws), "r": 0.0,
					"h": 2.18, "k": "bridge"})
		var piers: int = maxi(2, segs / 3)
		for k in range(1, piers):
			var pt: float = float(k) / float(piers)
			if broken > 0.01 and pt > gap0 and pt < gap1:
				continue
			var pp: Vector2 = a.lerp(b, pt)
			_box("concrete", Vector3(1.6, 4.0, w * 0.5),
					Transform3D(Basis(Vector3.UP, -ang), _pos(pp.x, pp.y, -0.6)))

# ---------- 小件雜物（GDD/14 §使用痕跡；使用者 2026-07-27：「場景細膩感還沒有很完全」）----------
# 使用者的四條判準：細節層次（大形＋中形＋小件）、使用痕跡（不會是新的、不會排整齊）、
# 材質變化（每個個體顏色不同）、與地面的過渡（不可以硬插進地面）。
# 先前只有大形（建築、工事）與中形（護欄、電線桿），**小件完全沒有**——
# 於是每一塊空地都是「乾淨的草皮」，看起來像還沒佈置完的白模。
#
# 生成邏輯刻意「圍著建築與道路長」：真實基地的雜物堆在人活動的地方，
# 不會平均散佈在曠野。每一件都帶隨機色偏、隨機傾斜，底下再壓一圈泥土做過渡。
const CLUTTER_KINDS := ["crate", "drum", "tyre", "pallet", "block", "canvas", "spool"]

func _clutter(m: Dictionary) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(_mw * 31.0 + _mh * 17.0) + 4242
	# 聚落中心＝建築周邊與道路沿線，這是雜物真正會出現的地方
	var hubs: Array = []
	for sd in m.get("solids", []):
		hubs.append(Vector2(float(sd.get("x", 0)) + float(sd.get("w", 60)) * 0.5,
				float(sd.get("y", 0)) + float(sd.get("h", 60)) * 0.5))
	for r in m.get("roads", []):
		for k in 3:
			var t: float = (float(k) + 0.5) / 3.0
			hubs.append(Vector2(float(r.get("x1", 0)), float(r.get("y1", 0))).lerp(
					Vector2(float(r.get("x2", 0)), float(r.get("y2", 0))), t))
	if hubs.is_empty():
		hubs.append(Vector2(_mw * 0.5, _mh * 0.5))
	var placed := 0
	for i in 220:
		if placed >= 70:
			break
		var hub: Vector2 = hubs[rng.randi() % hubs.size()]
		# 距離用指數分佈：靠近聚落最多，越遠越稀——不是平均亂灑
		var dist: float = 40.0 + 150.0 * pow(rng.randf(), 2.0)
		var ang: float = rng.randf() * TAU
		var p := hub + Vector2(cos(ang), sin(ang)) * dist
		if p.x < 20.0 or p.y < 20.0 or p.x > _mw - 20.0 or p.y > _mh - 20.0:
			continue
		if _off_limits(p) or (_terrain != null and _terrain.in_water(p.x, p.y)):
			continue
		if _terrain != null and _terrain.in_trench(p.x, p.y):
			continue
		_one_clutter(CLUTTER_KINDS[rng.randi() % CLUTTER_KINDS.size()], p, rng)
		placed += 1
	# 地面痕跡：小坑、裂縫、散落碎屑。純視覺、不擋任何東西（跨得過去）。
	for i in 90:
		var p2 := Vector2(rng.randf_range(30.0, _mw - 30.0), rng.randf_range(30.0, _mh - 30.0))
		if _terrain != null and _terrain.in_water(p2.x, p2.y):
			continue
		# ⚠ 第一版用 scaled_local 想「調暗」——那是縮放不是顏色，結果是一堆
		#   浮在坡面上的黑色小方板（實拍抓到）。痕跡要薄、要貼平，而且只能鋪在
		#   夠平的地方：斜坡上放一片水平方板一定會有一邊翹起來。
		if _terrain != null and _terrain.slope_at(p2.x, p2.y) > 0.10:
			continue
		var sz: float = rng.randf_range(0.25, 0.8)
		_box("mark", Vector3(sz, 0.012, sz * rng.randf_range(0.5, 1.4)),
				Transform3D(Basis(Vector3.UP, rng.randf() * TAU), _pos(p2.x, p2.y, -0.004)))

# 單件雜物。每一件都：尺寸抖動、顏色抖動、傾斜一點、底下壓泥土。
func _one_clutter(kind: String, p: Vector2, rng: RandomNumberGenerator) -> void:
	var yaw: float = rng.randf() * TAU
	var tilt: float = rng.randf_range(-0.14, 0.14)      # 東西不會擺得筆直
	var b := Basis(Vector3.UP, yaw) * Basis(Vector3(1, 0, 0), tilt)
	match kind:
		"crate":            # 木彈藥箱，有時疊兩層
			var w: float = rng.randf_range(0.52, 0.78)
			var h: float = rng.randf_range(0.34, 0.46)
			_box("wood", Vector3(w, h, w * rng.randf_range(0.6, 0.85)),
					Transform3D(b, _pos(p.x, p.y, h * 0.5)))
			# ⚠ 疊了第二層就不是「踩得上去的矮箱」了（頂端到 0.9m）。
			#   碰撞高度一定要跟畫出來的一致，否則人會踩在半空中／半截身體插進上層箱子。
			var top: float = h
			if rng.randf() < 0.45:
				var w2: float = w * rng.randf_range(0.7, 0.95)
				_box("wood", Vector3(w2, h * 0.9, w2 * 0.8),
						Transform3D(Basis(Vector3.UP, yaw + rng.randf_range(-0.5, 0.5)),
						_pos(p.x + rng.randf_range(-0.1, 0.1), p.y + rng.randf_range(-0.1, 0.1),
						h * 1.45)))
				top = h * 1.45 + h * 0.45
			_blk_cir(p, 0.45, top, true)               # 單層＝踩得上去；疊兩層＝擋人。木頭擋不住彈
		"drum":             # 油桶：站立或倒下
			if rng.randf() < 0.68:
				_box("rust", Vector3(0.58, 0.88, 0.58), Transform3D(b, _pos(p.x, p.y, 0.44)))
				_blk_cir(p, 0.32, 0.88, true)          # 鐵皮桶擋人不擋步槍彈
			else:
				_box("rust", Vector3(0.88, 0.56, 0.56),
						Transform3D(Basis(Vector3.UP, yaw) * Basis(Vector3(0, 0, 1), PI * 0.5),
						_pos(p.x, p.y, 0.28)))
				_blk_cir(p, 0.34, 0.42, true)
		"tyre":             # 輪胎堆
			var n: int = rng.randi_range(2, 4)
			for k in n:
				_box("cable", Vector3(0.74, 0.20, 0.74),
						Transform3D(Basis(Vector3.UP, rng.randf() * TAU),
						_pos(p.x + rng.randf_range(-0.06, 0.06),
						p.y + rng.randf_range(-0.06, 0.06), 0.10 + float(k) * 0.19)))
			_blk_cir(p, 0.40, 0.10 + float(n) * 0.19, true)
		"pallet":           # 木棧板：平放，踩得過去
			for k in 4:
				_box("wood", Vector3(1.05, 0.055, 0.14),
						Transform3D(b, _pos(p.x, p.y, 0.06)
						+ b * Vector3(0, 0, -0.42 + float(k) * 0.28)))
			_box("wood", Vector3(1.05, 0.06, 0.92), Transform3D(b, _pos(p.x, p.y, 0.02)))
		"block":            # 水泥塊／斷樑
			var l: float = rng.randf_range(0.6, 1.3)
			_box("concrete", Vector3(l, rng.randf_range(0.22, 0.38), rng.randf_range(0.3, 0.5)),
					Transform3D(b, _pos(p.x, p.y, 0.16)))
			_blk_cir(p, l * 0.4, 0.34)                 # 混凝土：真的擋彈
		"canvas":           # 蓋著帆布的補給堆：不規則、最像「有人用過」
			for k in 3:
				var sx: float = rng.randf_range(0.5, 1.1)
				_box("dirt", Vector3(sx, rng.randf_range(0.22, 0.44), sx * 0.8),
						Transform3D(Basis(Vector3.UP, yaw + float(k) * 0.7)
						* Basis(Vector3(1, 0, 0), rng.randf_range(-0.2, 0.2)),
						_pos(p.x + rng.randf_range(-0.3, 0.3),
						p.y + rng.randf_range(-0.3, 0.3), 0.18)))
			_blk_cir(p, 0.55, 0.44, true)
		_:                  # spool 電纜捲軸
			_box("wood", Vector3(1.0, 0.10, 1.0), Transform3D(b, _pos(p.x, p.y, 0.06)))
			_box("cable", Vector3(0.62, 0.42, 0.62), Transform3D(b, _pos(p.x, p.y, 0.32)))
			_box("wood", Vector3(1.0, 0.10, 1.0), Transform3D(b, _pos(p.x, p.y, 0.58)))
			_blk_cir(p, 0.5, 0.64, true)
	# 與地面的過渡：底下壓幾坨土，不然任何物件都像「插進地板」
	for k2 in 3:
		var sz: float = rng.randf_range(0.18, 0.4)
		_box("dirt", Vector3(sz, sz * 0.22, sz * rng.randf_range(0.7, 1.3)),
				Transform3D(Basis(Vector3.UP, rng.randf() * TAU),
				_pos(p.x + rng.randf_range(-0.45, 0.45),
				p.y + rng.randf_range(-0.45, 0.45), 0.03)))

# ---------- 幾何合併 ----------
func _pos(px: float, py: float, y_off: float) -> Vector3:
	var y := 0.0
	if _terrain != null:
		y = _terrain.height_at(px, py)
	return Vector3((px - _mw * 0.5) * _ws, y + y_off, (py - _mh * 0.5) * _ws)

func _mat(c: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m

func _box(key: String, size: Vector3, xf: Transform3D) -> void:
	if not _batch.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_material(_mats[key])
		_batch[key] = st
	var st2: SurfaceTool = _batch[key]
	var h: Vector3 = size * 0.5
	var v := [
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z),
		Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z)]
	for f in [[0, 1, 2, 3], [5, 4, 7, 6], [4, 0, 3, 7], [1, 5, 6, 2], [3, 2, 6, 7], [4, 5, 1, 0]]:
		var a: Vector3 = xf * v[f[0]]
		var b: Vector3 = xf * v[f[1]]
		var c: Vector3 = xf * v[f[2]]
		var d: Vector3 = xf * v[f[3]]
		var nrm: Vector3 = (b - a).cross(c - a).normalized()
		for p in [a, b, c, a, c, d]:
			st2.set_normal(nrm)
			st2.set_uv(BattleMats.world_uv(p, nrm))      # 世界座標 UV，理由見 Mats.gd
			st2.add_vertex(p)

func _flush() -> void:
	for key in _batch.keys():
		var st: SurfaceTool = _batch[key]
		var mi := MeshInstance3D.new()
		mi.name = "Props_" + key
		st.generate_tangents()          # 法線貼圖要切線，理由同 Building._flush_batch
		mi.mesh = st.commit()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if key == "dirt" \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(mi)
	_batch.clear()
