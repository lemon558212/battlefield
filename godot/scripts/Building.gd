# Building.gd — 可進入的程式生成建築（GDD/14 §2）。
# 為什麼要程式生成：現成的低多邊形房子都是「實心外殼」，玩家進不去；
# 用牆/地板/門窗/樓梯模組組出來，才能保證每棟都有真正的室內空間，
# 而且能同時吐出「牆線段、門位置、窗位置」這份結構資料——
# 掩體、視線、碰撞、迷霧全部吃同一份資料，不用再靠 AABB 猜。
class_name Building
extends Node3D

const WALL_T := 0.24          # 牆厚（公尺）
const FLOOR_H := 3.1          # 樓層淨高
const DOOR_W := 1.5           # 門寬
const WIN_W := 1.6            # 窗寬
const WIN_SILL := 1.0         # 窗台高
const WIN_H := 1.25           # 窗高

# 結構資料（座標一律用「遊戲 px」，與 maps.json／掩體系統同一套）
var walls: Array = []         # 每筆 {a: Vector2, b: Vector2}＝實心牆段（門窗缺口已扣掉）
var doors: Array = []         # 門中心點（px）＝唯一的進出點
var windows: Array = []       # 窗中心點（px）
var rect := Rect2()           # 建築外框（px）
var floors := 1
var roof: Node3D = null       # 屋頂節點（玩家進屋時淡出）

var _ws := 0.05
var _mw := 960.0
var _mh := 600.0
var _base_y := 0.0

func _px_to_local(p: Vector2) -> Vector3:
	return Vector3((p.x - _mw * 0.5) * _ws, 0, (p.y - _mh * 0.5) * _ws) - global_position + Vector3(0, _base_y, 0)

# 依 maps.json 的 solid 方框生成一棟建築。
# world_y＝地面高度（建築整體坐在這個高度上，地形起伏時不會浮空）
func build(sdef: Dictionary, world_scale: float, map_w: float, map_h: float, world_y: float, n_floors := 1) -> void:
	_ws = world_scale
	_mw = map_w
	_mh = map_h
	_base_y = world_y
	floors = n_floors
	rect = Rect2(float(sdef.get("x", 0)), float(sdef.get("y", 0)),
			maxf(float(sdef.get("w", 60)), 120.0), maxf(float(sdef.get("h", 60)), 120.0))
	position = Vector3((rect.get_center().x - map_w * 0.5) * _ws, world_y,
			(rect.get_center().y - map_h * 0.5) * _ws)
	# 材質全場共用一份：每棟各自 new 一組會讓 draw call 與材質切換翻倍
	# （6 棟建築把 8 單位的幀時從 6.2ms 推到 13.1ms）。
	var wm := _shared("wall", Color(0.72, 0.69, 0.62), 0.92)
	var im := _shared("inner", Color(0.62, 0.58, 0.52), 0.95)
	var fm := _shared("floor", Color(0.42, 0.34, 0.26), 0.9)
	var rm := _mat(Color(0.44, 0.20, 0.16), 0.85)      # 屋頂要各自淡出，不能共用
	var sizex: float = rect.size.x * _ws
	var sizez: float = rect.size.y * _ws
	# 地板（每層一片）
	for f in floors:
		_emit_box("floor", fm, Vector3(sizex, 0.18, sizez),
				Transform3D(Basis(), Vector3(0, float(f) * FLOOR_H - 0.09, 0)))
	# 四面外牆：南面開門，其餘開窗
	var half := Vector2(sizex * 0.5, sizez * 0.5)
	_side(Vector2(-half.x, half.y), Vector2(half.x, half.y), wm, true)     # +Z（南）：門
	_side(Vector2(half.x, -half.y), Vector2(half.x, half.y), wm, false)    # +X
	_side(Vector2(-half.x, -half.y), Vector2(half.x, -half.y), wm, false)  # -Z
	_side(Vector2(-half.x, -half.y), Vector2(-half.x, half.y), wm, false)  # -X
	# 室內隔牆：一道帶門洞的牆，讓室內有兩個空間可以互相掩護
	_partition(half, im)
	# 樓梯（兩層以上）
	if floors > 1:
		_stairs(half, fm)
	# 室內陳設（GDD/14 §2）：空殼房子進去只有四面牆，既沒有可看的東西，
	# 也沒有室內掩體可用——進建築的戰術價值只剩「牆擋子彈」。
	_furnish(half, im, fm)
	# 室內照明：牆一圍起來就是全黑，玩家看不到自己在哪。
	# 每層放一盞低強度暖光當「窗外漫射進來的光」，成本很低。
	var lamp := OmniLight3D.new()
	lamp.light_color = Color(1.0, 0.93, 0.82)
	lamp.light_energy = 1.6
	lamp.omni_range = maxf(sizex, sizez) * 1.1
	lamp.omni_attenuation = 1.2
	lamp.shadow_enabled = false
	lamp.position = Vector3(0, FLOOR_H * 0.7, 0)
	add_child(lamp)
	_flush_batch()
	# 屋頂：單獨節點，玩家進屋時淡出
	roof = Node3D.new()
	roof.name = "Roof"
	add_child(roof)
	var top: float = float(floors) * FLOOR_H
	var ridge := _box(sizex + 0.5, 0.22, sizez + 0.5, rm)
	ridge.position = Vector3(0, top + 0.11, 0)
	roof.add_child(ridge)
	for sgn in [-1.0, 1.0]:
		var slopeb := _box(sizex + 0.7, 0.2, sizez * 0.62, rm)
		slopeb.position = Vector3(0, top + 0.62, sgn * sizez * 0.26)
		slopeb.rotation.x = sgn * deg_to_rad(22.0)
		roof.add_child(slopeb)

# 室內陳設：桌、櫃、床、木箱、翻倒的桌子。
# 低桌與木箱＝室內掩體（登記進 covers 由 Main 讀），高櫃擋視線。
# ⚠ 一律走 _emit_box 合併批次：一間房十來個家具，各自一個節點就是十幾次 draw call。
var furniture: Array = []      # [{lx, lz, r, val}]，局部座標，Main 轉成掩體登記
# 室內實體障礙 [lx, lz, r]：桌、櫃、木箱都擋人（使用者：任何物體都不能穿越）
var solids_local: Array = []
func _furnish(half: Vector2, im: StandardMaterial3D, fm: StandardMaterial3D) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(absf(rect.position.x) * 17.0 + absf(rect.position.y) * 7.0) + 91
	for f in floors:
		var y0: float = float(f) * FLOOR_H
		# 靠牆的高櫃：擋視線、也讓空牆面有東西
		for k in 2:
			var wall_i: int = rng.randi() % 4
			var along: float = rng.randf_range(-0.55, 0.55)
			var lx := 0.0
			var lz := 0.0
			var rot := 0.0
			match wall_i:
				0: lx = -half.x + 0.35; lz = half.y * along; rot = PI * 0.5
				1: lx = half.x - 0.35; lz = half.y * along; rot = PI * 0.5
				2: lx = half.x * along; lz = -half.y + 0.35
				_: lx = half.x * along; lz = half.y - 0.35
			var hgt: float = rng.randf_range(1.5, 2.0)
			_emit_box("inner", im, Vector3(1.0, hgt, 0.45),
					Transform3D(Basis(Vector3.UP, rot), Vector3(lx, y0 + hgt * 0.5, lz)))
			if f == 0:
				solids_local.append([lx, lz, 0.55])      # 高櫃擋人
		# 桌子（桌面＋四腳）＋兩張椅子
		var tx: float = rng.randf_range(-half.x * 0.4, half.x * 0.4)
		var tz: float = rng.randf_range(-half.y * 0.4, half.y * 0.4)
		_emit_box("floor", fm, Vector3(1.5, 0.09, 0.85),
				Transform3D(Basis(), Vector3(tx, y0 + 0.74, tz)))
		for sx in [-0.65, 0.65]:
			for sz in [-0.34, 0.34]:
				_emit_box("floor", fm, Vector3(0.09, 0.74, 0.09),
						Transform3D(Basis(), Vector3(tx + sx, y0 + 0.37, tz + sz)))
		for sx2 in [-1.0, 1.0]:
			_emit_box("floor", fm, Vector3(0.42, 0.06, 0.42),
					Transform3D(Basis(), Vector3(tx + sx2, y0 + 0.45, tz)))
			_emit_box("floor", fm, Vector3(0.42, 0.5, 0.07),
					Transform3D(Basis(), Vector3(tx + sx2 * 1.18, y0 + 0.7, tz)))
		furniture.append({"lx": tx, "lz": tz, "r": 1.1, "val": 0.35})
		if f == 0:
			solids_local.append([tx, tz, 0.78])          # 桌子
		# 木箱堆＝真正好用的室內掩體（半身高，可以蹲在後面）
		for k2 in 3:
			var bx: float = rng.randf_range(-half.x * 0.75, half.x * 0.75)
			var bz: float = rng.randf_range(-half.y * 0.75, half.y * 0.75)
			var bs: float = rng.randf_range(0.5, 0.75)
			_emit_box("floor", fm, Vector3(bs, bs, bs),
					Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(bx, y0 + bs * 0.5, bz)))
			if rng.randf() < 0.5:      # 疊第二層
				_emit_box("floor", fm, Vector3(bs * 0.8, bs * 0.8, bs * 0.8),
						Transform3D(Basis(Vector3.UP, rng.randf() * TAU),
						Vector3(bx + 0.1, y0 + bs + bs * 0.4, bz - 0.08)))
			if f == 0:
				furniture.append({"lx": bx, "lz": bz, "r": 0.9, "val": 0.5})
				solids_local.append([bx, bz, bs * 0.72])  # 木箱堆
		# 翻倒的桌子：被打過的房子不會桌椅整齊
		var ox: float = rng.randf_range(-half.x * 0.6, half.x * 0.6)
		var oz: float = rng.randf_range(-half.y * 0.6, half.y * 0.6)
		_emit_box("floor", fm, Vector3(1.4, 0.08, 0.8),
				Transform3D(Basis(Vector3.FORWARD, deg_to_rad(84.0)).rotated(Vector3.UP, rng.randf() * TAU),
				Vector3(ox, y0 + 0.42, oz)))

# 一面牆：把門窗缺口扣掉後，剩下的實心段才建幾何、才登記進 walls
func _side(a: Vector2, b: Vector2, mat: StandardMaterial3D, is_door: bool) -> void:
	var len_m: float = a.distance_to(b)
	var dir: Vector2 = (b - a) / maxf(len_m, 0.001)
	var gaps: Array = []      # [起, 迄]（沿牆的長度座標）
	if is_door:
		# ⚠ 門不能開在牆正中央：室內隔牆就在中線上，門會被隔牆堵住
		#   （第一版實拍就是「門變成兩條細縫」）。偏到 32% 處讓進門動線是順的。
		var c: float = len_m * 0.32
		gaps.append([c - DOOR_W * 0.5, c + DOOR_W * 0.5])
		doors.append(_local_to_px(a + dir * c))
	else:
		# 每 3.2m 開一扇窗，牆太短就只開中間一扇
		var n: int = maxi(1, int(len_m / 3.2))
		for i in n:
			var c2: float = len_m * (float(i) + 0.5) / float(n)
			if c2 < 0.9 or c2 > len_m - 0.9:
				continue
			gaps.append([c2 - WIN_W * 0.5, c2 + WIN_W * 0.5])
			windows.append(_local_to_px(a + dir * c2))
	gaps.sort_custom(func(x, y): return x[0] < y[0])
	var cursor := 0.0
	for g in gaps:
		if g[0] > cursor:
			_wall_piece(a + dir * cursor, a + dir * g[0], mat, 0.0, FLOOR_H * float(floors))
		# 門洞上方要有門楣、窗洞上下要有牆，否則外觀會是一排缺口
		if is_door:
			_wall_piece(a + dir * g[0], a + dir * g[1], mat, 2.15, FLOOR_H * float(floors) - 2.15)
		else:
			_wall_piece(a + dir * g[0], a + dir * g[1], mat, 0.0, WIN_SILL)
			_wall_piece(a + dir * g[0], a + dir * g[1], mat, WIN_SILL + WIN_H,
					FLOOR_H * float(floors) - WIN_SILL - WIN_H)
		cursor = g[1]
	if cursor < len_m:
		_wall_piece(a + dir * cursor, a + dir * len_m, mat, 0.0, FLOOR_H * float(floors))

# 建一段牆的幾何；y0=底部高度、hh=高度。只有「落地的實心段」才算擋路/擋視線。
func _wall_piece(a: Vector2, b: Vector2, mat: StandardMaterial3D, y0: float, hh: float) -> void:
	if hh <= 0.01 or a.distance_to(b) < 0.02:
		return
	var mid: Vector2 = (a + b) * 0.5
	var len_m: float = a.distance_to(b)
	var ang: float = atan2(b.y - a.y, b.x - a.x)
	var key := "wall" if mat == _shared_mats.get("wall") else "inner"
	_emit_box(key, mat, Vector3(len_m, hh, WALL_T),
			Transform3D(Basis(Vector3.UP, -ang), Vector3(mid.x, y0 + hh * 0.5, mid.y)))
	if y0 <= 0.02:            # 落地的段才擋人、擋子彈
		walls.append({"a": _local_to_px(a), "b": _local_to_px(b)})

func _partition(half: Vector2, mat: StandardMaterial3D) -> void:
	# 兩端內縮半個牆厚：與外牆重疊的共面會 z-fighting，畫面上是一片閃爍的雜點
	var a := Vector2(0.0, -half.y + WALL_T * 0.5)
	var b := Vector2(0.0, half.y - WALL_T * 0.5)
	var len_m: float = a.distance_to(b)
	var c: float = len_m * 0.62
	_wall_piece(a, a + Vector2(0, c - DOOR_W * 0.5), mat, 0.0, FLOOR_H * float(floors))
	_wall_piece(a + Vector2(0, c + DOOR_W * 0.5), b, mat, 0.0, FLOOR_H * float(floors))
	_wall_piece(a + Vector2(0, c - DOOR_W * 0.5), a + Vector2(0, c + DOOR_W * 0.5), mat,
			2.15, FLOOR_H * float(floors) - 2.15)

func _stairs(half: Vector2, mat: StandardMaterial3D) -> void:
	var n := 12
	for i in n:
		_emit_box("floor", mat, Vector3(1.1, 0.16, 0.28),
				Transform3D(Basis(), Vector3(half.x - 0.8, float(i) * (FLOOR_H / float(n)),
						-half.y + 0.5 + float(i) * 0.28)))

# 這個點是不是在建築室內（含牆內側）
func inside(px: float, py: float) -> bool:
	return rect.grow(-6.0).has_point(Vector2(px, py))

func _local_to_px(p: Vector2) -> Vector2:
	return Vector2(rect.get_center().x + p.x / _ws, rect.get_center().y + p.y / _ws)

static var _shared_mats := {}
func _shared(key: String, c: Color, rough: float) -> StandardMaterial3D:
	if not _shared_mats.has(key):
		_shared_mats[key] = _mat(c, rough)
	return _shared_mats[key]

func _mat(c: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m

func _box(sx: float, sy: float, sz: float, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(sx, sy, sz)
	mi.mesh = bm
	mi.material_override = mat
	return mi

# ---------- 幾何合併（效能）----------
# 一棟房子拆成二三十個 BoxMesh 節點＝二三十次 draw call，六棟就把幀時從 6.2ms 推到 13.4ms。
# 改成「同材質的箱子全部烤進同一張網格」，一棟只剩一到兩個 surface。
var _batch := {}          # 材質鍵 → SurfaceTool

func _emit_box(key: String, mat: StandardMaterial3D, size: Vector3, xf: Transform3D) -> void:
	if not _batch.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_material(mat)
		_batch[key] = st
	var st2: SurfaceTool = _batch[key]
	var h: Vector3 = size * 0.5
	var v := [
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z),
		Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z)]
	var faces := [[0, 1, 2, 3], [5, 4, 7, 6], [4, 0, 3, 7], [1, 5, 6, 2], [3, 2, 6, 7], [4, 5, 1, 0]]
	for f in faces:
		var a: Vector3 = xf * v[f[0]]
		var b: Vector3 = xf * v[f[1]]
		var c: Vector3 = xf * v[f[2]]
		var d: Vector3 = xf * v[f[3]]
		# ⚠ 法線要自己給，不可用 generate_normals()：它會把相鄰箱子的頂點合併平均，
		#   合併後的牆會出現漸層條紋、看起來像半透明（2026-07-26 實拍踩到）。
		var nrm: Vector3 = (b - a).cross(c - a).normalized()
		for p in [a, b, c, a, c, d]:
			st2.set_normal(nrm)
			st2.add_vertex(p)

func _flush_batch() -> void:
	for key in _batch.keys():
		var st: SurfaceTool = _batch[key]
		var mi := MeshInstance3D.new()
		mi.name = "Merged_" + key
		mi.mesh = st.commit()
		# 室內構件（地板/樓梯/隔牆）不投影：陰影貼圖裡本來就看不到，白算
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if key == "wall" 				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
	_batch.clear()

# 屋頂淡出（玩家在室內時）：整棟消失會看不出自己在哪棟樓，只淡屋頂
func set_roof_alpha(a: float) -> void:
	if roof == null:
		return
	roof.visible = a > 0.02
	for c in roof.get_children():
		var mi := c as MeshInstance3D
		if mi == null:
			continue
		var m := mi.material_override as StandardMaterial3D
		if m == null:
			continue
		if a < 0.99:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		else:
			m.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		m.albedo_color.a = a
