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

func build(map_data: Dictionary, world_scale: float, terrain) -> void:
	_ws = world_scale
	_mw = float(map_data.get("w", 960))
	_mh = float(map_data.get("h", 600))
	_terrain = terrain
	_mats = {
		"dirt": _mat(Color(0.34, 0.28, 0.20), 0.98),
		"concrete": _mat(Color(0.55, 0.54, 0.50), 0.95),
		"wood": _mat(Color(0.38, 0.28, 0.18), 0.92),
		"metal": _mat(Color(0.28, 0.29, 0.30), 0.55),
		"rock": _mat(Color(0.40, 0.39, 0.36), 0.95),
	}
	_roads(map_data)
	_blocks(map_data)
	_teeth(map_data)
	_fences(map_data)
	_poles(map_data)
	_rubble(map_data)
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
			# 龍牙：四角錐用兩個交叉薄箱近似，低多邊形風格夠用
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
				if _terrain != null and _terrain.in_trench(p.x, p.y):
					d += step
					continue
				_box("wood", Vector3(0.12, 1.05, 0.12), Transform3D(Basis(), _pos(p.x, p.y, 0.52)))
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
