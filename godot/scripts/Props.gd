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
	_mats = {
		"dirt": _mat(Color(0.34, 0.28, 0.20), 0.98),
		"concrete": _mat(Color(0.55, 0.54, 0.50), 0.95),
		"wood": _mat(Color(0.38, 0.28, 0.18), 0.92),
		"metal": _mat(Color(0.28, 0.29, 0.30), 0.55),
		"rock": _mat(Color(0.40, 0.39, 0.36), 0.95),
		"rust": _mat(Color(0.31, 0.20, 0.13), 0.98),
		"burn": _mat(Color(0.17, 0.15, 0.13), 1.0),
		"brick": _mat(Color(0.64, 0.46, 0.35), 0.96),
		"brick2": _mat(Color(0.52, 0.36, 0.28), 0.97),
		"cable": _mat(Color(0.09, 0.09, 0.10), 0.85),
	}
	_roads(map_data)
	_blocks(map_data)
	_teeth(map_data)
	_fences(map_data)
	_poles(map_data)
	_rubble(map_data)
	_wrecks(map_data)
	_walls_brick(map_data)
	_cables(map_data)
	_scorch(map_data)
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
			while d < total - 40.0:
				var p: Vector2 = a + dir * d + nrm * off * side
				if _off_limits(p) or _off_limits(p + dir * step):
					d += step
					continue
				if _terrain != null and _terrain.in_trench(p.x, p.y):
					d += step
					continue
				_box("wood", Vector3(0.12, 1.05, 0.12), Transform3D(Basis(), _pos(p.x, p.y, 0.52)))
				# 柵欄是連續的橫杆，障礙必須是線段——只登記柱子的話人會從兩柱之間穿過去
				_blk_seg(p, p + dir * step, 0.14, 1.05)
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
			if _off_limits(p):
				d += 260.0
				continue
			_blk_cir(p, 0.32, 6.2)
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
			var sz: float = rng.randf_range(0.18, 0.55)
			_box("rock", Vector3(sz, sz * rng.randf_range(0.4, 0.8), sz * rng.randf_range(0.7, 1.3)),
					Transform3D(Basis(Vector3.UP, rng.randf() * TAU), _pos(px, py, sz * 0.25)))
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
		_blk_cir(p, 1.5, 1.90)
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
					_box(key, Vector3(0.9, lyh * 0.94, 0.28),
							Transform3D(Basis(Vector3.UP, -ang),
							_pos(q.x, q.y, lyh * (float(ly) + 0.5)) + Vector3(shift, 0, 0)))
			var half: Vector2 = dirv * float(segn) * 0.5 * (1.1 / _ws)
			_blk_seg(p - half, p + half, 0.20, 1.25)

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
			if _off_limits(p):
				has_prev = false
				d += 260.0
				continue
			if has_prev:
				var span: float = prev.distance_to(p) * _ws
				var steps := 6
				for i in steps:
					var t0: float = float(i) / float(steps)
					var t1: float = float(i + 1) / float(steps)
					var m0: Vector2 = prev.lerp(p, (t0 + t1) * 0.5)
					# 垂鏈：中間下垂最多
					var sag: float = 0.9 * sin(PI * (t0 + t1) * 0.5)
					var ang2: float = atan2(p.y - prev.y, p.x - prev.x)
					_box("cable", Vector3(span / float(steps) + 0.1, 0.06, 0.06),
							Transform3D(Basis(Vector3.UP, -ang2), _pos(m0.x, m0.y, 5.5 - sag)))
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
		var sz: float = rng.randf_range(0.5, 1.5)
		_box("burn", Vector3(sz, 0.04, sz * rng.randf_range(0.6, 1.4)),
				Transform3D(Basis(Vector3.UP, rng.randf() * TAU),
				_pos(c.x + cos(a) * d, c.y + sin(a) * d, 0.03)))

# ---------- 障礙登記 ----------
# 半徑參數用公尺（跟建模同一套單位，改的時候不用心算），存進去統一換成 px。
# h_m＝這個障礙的實際高度（公尺）。人的碰撞不看高度（都擋），但彈道要看：
# 0.95m 的護欄擋得住趴著與蹲著的人的彈道，擋不住站姿對站姿的對射——這是
# 使用者 2026-07-26 指正「子彈可以穿過這些物體」的正解，不是一律擋或一律不擋。
func _blk_cir(c: Vector2, r_m: float, h_m: float) -> void:
	blockers.append({"t": "cir", "c": c, "r": r_m / _ws, "h": h_m})

func _blk_seg(a: Vector2, b: Vector2, r_m: float, h_m: float) -> void:
	# 順手存中點與半長：碰撞時先用它做粗剔除，才不用對每段柵欄都算一次最近點
	blockers.append({"t": "seg", "a": a, "b": b, "r": r_m / _ws, "h": h_m,
			"m": (a + b) * 0.5, "hl": a.distance_to(b) * 0.5})

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
			st2.add_vertex(p)

func _flush() -> void:
	for key in _batch.keys():
		var st: SurfaceTool = _batch[key]
		var mi := MeshInstance3D.new()
		mi.name = "Props_" + key
		mi.mesh = st.commit()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if key == "dirt" \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(mi)
	_batch.clear()
