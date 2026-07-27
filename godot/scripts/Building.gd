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
# 地標型別（劇情場景用）："" 一般民房／"tower" 塔樓（平頂＋女兒牆）／
# "radar" 雷達站（平頂＋天線碟）。第一章劇本點名了雷達站與鐘樓，
# 全部長成同一種紅瓦斜頂民房的話，玩家認不出劇情講的是哪一棟。
var kind := ""
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
	kind = String(sdef.get("kind", ""))
	rect = Rect2(float(sdef.get("x", 0)), float(sdef.get("y", 0)),
			maxf(float(sdef.get("w", 60)), 120.0), maxf(float(sdef.get("h", 60)), 120.0))
	position = Vector3((rect.get_center().x - map_w * 0.5) * _ws, world_y,
			(rect.get_center().y - map_h * 0.5) * _ws)
	# 材質全場共用一份：每棟各自 new 一組會讓 draw call 與材質切換翻倍
	# （6 棟建築把 8 單位的幀時從 6.2ms 推到 13.1ms）。
	# 貼圖化（GDD/14 §0a）：純色 albedo 是「像塑膠積木」的主因，見 Mats.gd 檔頭。
	# ⚠ 2026-07-27 使用者：「牆面貼圖尺度不對，近看是白模」。兩個原因疊在一起：
	#   ① 一次循環 3.2m ——第三人稱貼到牆邊時，整個畫面只有半張貼圖，等於沒有紋理；
	#   ② tint 1.28 是把貼圖整個乘亮，細節被推到過曝，剩下一片死白。
	#   改成 1.5m 一循環、tint 回到 1.0 附近。
	#   ⚠ 反過來也不行：1.5m 一循環時，貼圖的方格重複被看得一清二楚（實拍是一面棋盤）。
	#   2.4m 是「近看有紋理、遠看看不出重複」的折衷值。
	var wm := BattleMats.pbr("Concrete", 2.4, 0.92, Color(1.02, 0.99, 0.93))
	_wall_mat = wm
	var im := BattleMats.pbr("Concrete", 2.0, 0.95, Color(0.96, 0.93, 0.88))
	var fm := BattleMats.pbr("MarbleFloor", 1.9, 0.9, Color(0.98, 0.92, 0.83))
	# 屋頂要各自淡出（進屋時透明化），所以不能共用一顆材質
	var rm := BattleMats.pbr("RoofSlate", 1.0, 0.85, Color(1.35, 0.72, 0.58)).duplicate()
	rm.uv1_scale = Vector3(6.0, 6.0, 1.0)      # BoxMesh 的 UV 是 0~1，用循環次數而不是公尺
	var sizex: float = rect.size.x * _ws
	var sizez: float = rect.size.y * _ws
	# 地板（每層一片）
	for f in floors:
		_emit_box("floor", fm, Vector3(sizex, 0.18, sizez),
				Transform3D(Basis(), Vector3(0, float(f) * FLOOR_H - 0.09, 0)))
	# 四面外牆：南面開門，其餘開窗
	var half := Vector2(sizex * 0.5, sizez * 0.5)
	# 地基：牆體直接一刀切進草地是最明顯的「假」（使用者品質判準：與地面的過渡）。
	# 加一圈比牆略寬、往下埋 0.5m 的基座，外圍再散幾塊碎石把交界線藏掉。
	_emit_box("floor", im, Vector3(sizex + 0.34, 0.9, sizez + 0.34),
			Transform3D(Basis(), Vector3(0, -0.40, 0)))
	_footing_debris(Vector2(sizex * 0.5, sizez * 0.5), im)
	# 武器庫不開窗（軍事顧問16：彈藥庫是實心厚牆＋唯一一道門，開一排窗才是怪事），
	# 這也是玩家「一眼認出那是武器庫」的唯一線索——六棟長一樣就等於劇情沒落地。
	var solid_walls: bool = kind == "depot"
	_side(Vector2(-half.x, half.y), Vector2(half.x, half.y), wm, true)     # +Z（南）：門
	_side(Vector2(half.x, -half.y), Vector2(half.x, half.y), wm, false, solid_walls)    # +X
	_side(Vector2(-half.x, -half.y), Vector2(half.x, -half.y), wm, false, solid_walls)  # -Z
	_side(Vector2(-half.x, -half.y), Vector2(-half.x, half.y), wm, false, solid_walls)  # -X
	# 室內隔牆：一道帶門洞的牆，讓室內有兩個空間可以互相掩護
	_partition(half, im)
	# 樓梯（兩層以上）
	if floors > 1:
		_stairs(half, fm)
	# 室內陳設（GDD/14 §2）：空殼房子進去只有四面牆，既沒有可看的東西，
	# 也沒有室內掩體可用——進建築的戰術價值只剩「牆擋子彈」。
	_furnish(half, im, fm)
	# 保險：任何落在樓梯範圍內的室內障礙一律拿掉（家具是裝飾，樓梯是通路）
	if floors > 1:
		var keep: Array = []
		for sl in solids_local:
			if not _in_stairs(float(sl[0]), float(sl[1]), float(sl[2])):
				keep.append(sl)
		solids_local = keep
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
	if kind == "tower" or kind == "radar" or kind == "depot" or kind == "gate":
		# 軍用設施是平頂＋女兒牆（屋頂要能站人、架天線），不是紅瓦斜頂
		var deck := _box(sizex + 0.4, 0.22, sizez + 0.4, _wall_mat)
		deck.position = Vector3(0, top + 0.11, 0)
		roof.add_child(deck)
		# 女兒牆高度依用途：塔樓／雷達站是要站人的射擊位（0.55m 及膝掩體），
		# 哨所與武器庫只是屋頂收邊（0.24m）。
		# ⚠ 0.55m 的女兒牆蓋在 6m 見方的小屋頂上，比例上就是一個浴缸／游泳池
		#   （2026-07-27 實拍第一章哨所，一眼就看出不對）。
		var par_h: float = 0.55 if (kind == "tower" or kind == "radar") else 0.24
		for e in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
			var along := Vector3(absf(e.z) * sizex + 0.4, par_h, absf(e.x) * sizez + 0.4)
			var par := _box(maxf(along.x, 0.18), along.y, maxf(along.z, 0.18), _wall_mat)
			par.position = Vector3(e.x * (sizex * 0.5 + 0.1), top + 0.22 + par_h * 0.5,
					e.z * (sizez * 0.5 + 0.1))
			roof.add_child(par)
		if kind == "depot":
			# 彈藥庫屋頂的通風口：兩個小方箱。平頂＋無窗＋通風口＝一眼認得出是武器庫。
			for vx in [-0.25, 0.25]:
				var vent := _box(0.55, 0.42, 0.55, _wall_mat)
				vent.position = Vector3(sizex * vx, top + 0.43, sizez * 0.18)
				roof.add_child(vent)
		if kind == "gate":
			# 哨所：屋頂一根旗桿。劇本說這是「正門」，要讓玩家從遠處就分辨得出來。
			var pole := _box(0.10, 3.4, 0.10, _wall_mat)
			pole.position = Vector3(sizex * 0.30, top + 1.9, 0)
			roof.add_child(pole)
		if kind == "radar":
			var mast := _box(0.26, 1.6, 0.26, _wall_mat)
			mast.position = Vector3(0, top + 1.0, 0)
			roof.add_child(mast)
			# 天線碟：一片傾斜的薄盤，遠遠就認得出「那是雷達站」
			var dish := _box(2.6, 0.16, 2.6, _wall_mat)
			dish.position = Vector3(0, top + 1.95, 0)
			dish.rotation = Vector3(deg_to_rad(-38.0), deg_to_rad(24.0), 0)
			roof.add_child(dish)
	else:
		var ridge := _box(sizex + 0.5, 0.22, sizez + 0.5, rm)
		ridge.position = Vector3(0, top + 0.11, 0)
		roof.add_child(ridge)
		for sgn in [-1.0, 1.0]:
			var slopeb := _box(sizex + 0.7, 0.2, sizez * 0.62, rm)
			slopeb.position = Vector3(0, top + 0.62, sgn * sizez * 0.26)
			slopeb.rotation.x = sgn * deg_to_rad(22.0)
			roof.add_child(slopeb)
	_decorate(half, top)

# 室內陳設：桌、櫃、床、木箱、翻倒的桌子。
# 低桌與木箱＝室內掩體（登記進 covers 由 Main 讀），高櫃擋視線。
# ⚠ 一律走 _emit_box 合併批次：一間房十來個家具，各自一個節點就是十幾次 draw call。
var furniture: Array = []      # [{lx, lz, r, val}]，局部座標，Main 轉成掩體登記
# 室內實體障礙 [lx, lz, r]：桌、櫃、木箱都擋人（使用者：任何物體都不能穿越）
var solids_local: Array = []
func _furnish(half: Vector2, im: BaseMaterial3D, fm: BaseMaterial3D) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(absf(rect.position.x) * 17.0 + absf(rect.position.y) * 7.0) + 91
	for f in floors:
		var y0: float = float(f) * FLOOR_H
		# 靠牆的高櫃：擋視線、也讓空牆面有東西
		for k in 2:
			var wall_i: int = rng.randi() % 4
			# ⚠ 樓梯靠東牆（_stairs 的 lx = half.x-0.8）。高櫃也放東牆的話會把樓梯口堵死，
			#   實測結果是「人在樓梯前抽搐、上不了二樓」——跟「門前一根柱子廢掉整棟房」
			#   是同一個錯誤。有樓梯的樓層一律把櫃子挪到對面牆。
			if floors > 1 and wall_i == 1:
				wall_i = 0
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
# 牆腳碎料：沿四邊隨機丟幾塊小石/水泥塊，把「牆與地面的那條直線」打散。
# 不進碰撞表（0.1~0.2m 高的東西本來就跨得過去），純視覺。
func _footing_debris(half: Vector2, mat: BaseMaterial3D) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(rect.position.x) * 7919 + int(rect.position.y)
	for i in 22:
		var t: float = rng.randf()
		var p: Vector2
		match i % 4:
			0: p = Vector2(lerp(-half.x, half.x, t), half.y + rng.randf_range(0.02, 0.42))
			1: p = Vector2(lerp(-half.x, half.x, t), -half.y - rng.randf_range(0.02, 0.42))
			2: p = Vector2(half.x + rng.randf_range(0.02, 0.42), lerp(-half.y, half.y, t))
			_: p = Vector2(-half.x - rng.randf_range(0.02, 0.42), lerp(-half.y, half.y, t))
		var sx: float = rng.randf_range(0.14, 0.36)
		var sy: float = rng.randf_range(0.06, 0.16)
		_emit_box("floor", mat, Vector3(sx, sy, sx * rng.randf_range(0.6, 1.0)),
				Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(p.x, sy * 0.3, p.y)))

func _side(a: Vector2, b: Vector2, mat: BaseMaterial3D, is_door: bool, no_win := false) -> void:
	var len_m: float = a.distance_to(b)
	var dir: Vector2 = (b - a) / maxf(len_m, 0.001)
	var gaps: Array = []      # [起, 迄]（沿牆的長度座標）
	if no_win and not is_door:
		_wall_piece(a, b, mat, 0.0, FLOOR_H * float(floors))
		return
	if is_door:
		# ⚠ 門不能開在牆正中央：室內隔牆就在中線上，門會被隔牆堵住
		#   （第一版實拍就是「門變成兩條細縫」）。偏到 32% 處讓進門動線是順的。
		var c: float = len_m * 0.32
		gaps.append([c - DOOR_W * 0.5, c + DOOR_W * 0.5])
		doors.append(_local_to_px(a + dir * c))
		_deco_doors.append([a + dir * c, atan2(dir.y, dir.x)])
	else:
		# 每 3.2m 開一扇窗，牆太短就只開中間一扇
		var n: int = maxi(1, int(len_m / 3.2))
		for i in n:
			var c2: float = len_m * (float(i) + 0.5) / float(n)
			if c2 < 0.9 or c2 > len_m - 0.9:
				continue
			gaps.append([c2 - WIN_W * 0.5, c2 + WIN_W * 0.5])
			windows.append(_local_to_px(a + dir * c2))
			_deco_wins.append([a + dir * c2, atan2(dir.y, dir.x)])
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
func _wall_piece(a: Vector2, b: Vector2, mat: BaseMaterial3D, y0: float, hh: float) -> void:
	if hh <= 0.01 or a.distance_to(b) < 0.02:
		return
	var mid: Vector2 = (a + b) * 0.5
	var len_m: float = a.distance_to(b)
	var ang: float = atan2(b.y - a.y, b.x - a.x)
	var key := "wall" if mat == _wall_mat else "inner"
	_emit_box(key, mat, Vector3(len_m, hh, WALL_T),
			Transform3D(Basis(Vector3.UP, -ang), Vector3(mid.x, y0 + hh * 0.5, mid.y)))
	if y0 <= 0.02:            # 落地的段才擋人、擋子彈
		# ⚠ 高度要記下來：窗台只有 1.0m 高，先前牆段沒有高度欄位，
		#   `_shot_clear` 一律當成「從地板通到屋頂」→ **窗口射不出去也射不進來**。
		#   有了高度，蹲在窗台後打不到、站起來從窗口射得出去，這才是窗戶的戰術意義。
		walls.append({"a": _local_to_px(a), "b": _local_to_px(b), "h": y0 + hh})

func _partition(half: Vector2, mat: BaseMaterial3D) -> void:
	# 兩端內縮半個牆厚：與外牆重疊的共面會 z-fighting，畫面上是一片閃爍的雜點
	var a := Vector2(0.0, -half.y + WALL_T * 0.5)
	var b := Vector2(0.0, half.y - WALL_T * 0.5)
	var len_m: float = a.distance_to(b)
	var c: float = len_m * 0.62
	_wall_piece(a, a + Vector2(0, c - DOOR_W * 0.5), mat, 0.0, FLOOR_H * float(floors))
	_wall_piece(a + Vector2(0, c + DOOR_W * 0.5), b, mat, 0.0, FLOOR_H * float(floors))
	_wall_piece(a + Vector2(0, c - DOOR_W * 0.5), a + Vector2(0, c + DOOR_W * 0.5), mat,
			2.15, FLOOR_H * float(floors) - 2.15)

# 樓梯佔地（局部座標）：家具與障礙都不可以放進來
func _in_stairs(lx: float, lz: float, rad := 0.0) -> bool:
	if floors <= 1:
		return false
	var half := Vector2(rect.size.x * _ws * 0.5, rect.size.y * _ws * 0.5)
	var z0: float = -half.y + 0.61
	var zone := Rect2(half.x - 1.80, z0, STAIR_W, _stair_run()).grow(0.4 + rad)
	return zone.has_point(Vector2(lx, lz))

# 樓梯坡度（鐵律 0⑤：真實量級）。
# ⚠ 舊值是 12 階 × 0.28m 跑完 3.1m 高＝**43 度**，比真實樓梯（30~35 度）陡太多。
#   後果不只是看起來怪：人以 3m/s 走上 43 度斜面需要 2.8m/s 的垂直爬升，
#   超過 CLIMB_SPEED 2.4m/s 的上限 → 腳跟不上斜面 → 支撐判定掉回一樓 → 滑下來。
#   實測就是「走 4 秒還在 0.00m，上不了二樓」。
const STAIR_DEG := 32.0
const STAIR_W := 1.5

func _stair_run() -> float:
	var half_z: float = rect.size.y * _ws * 0.5
	return minf(FLOOR_H / tan(deg_to_rad(STAIR_DEG)), half_z * 2.0 - 1.2)

func _stairs(half: Vector2, mat: BaseMaterial3D) -> void:
	var run: float = _stair_run()
	var n: int = maxi(8, int(run / 0.28))
	for i in n:
		# ⚠ 往室內多退 0.25m：舊值讓梯面外緣離牆內面只剩 13cm，從窗口看出去
		#   整段樓梯貼在窗洞後面，讀起來像「樓梯長在牆上」（使用者 2026-07-27）。
		_emit_box("floor", mat, Vector3(1.1, 0.16, run / float(n) + 0.02),
				Transform3D(Basis(), Vector3(half.x - 1.05, float(i) * (FLOOR_H / float(n)),
						-half.y + 0.75 + float(i) * (run / float(n)))))

# 腳下的支撐面（鐵律 0③：有重量的東西會停在最近的支撐面上，不會沉到地形高度）。
# ⚠ 先前二樓地板只是畫出來的：站在二樓的人高度照 terrain.height_at() 算，
#   等於整個人陷在一樓的地面上——樓層根本不存在。
# 回傳世界 y；這個點沒有支撐（不在建築範圍內）回 -INF，呼叫端自己退回地形高度。
# y＝查詢者目前的腳底高度：只有「在腳下、或差一階以內」的樓板才撐得住，
# 否則站在一樓會被二樓的樓板吸上去。
const STEP_TOL := 0.35        # 一階台階的容差（樓梯每階 0.26m，抓 0.35 剛好）
func floor_at(px: float, py: float, y: float) -> float:
	if not rect.has_point(Vector2(px, py)):
		return -INF
	var lp3: Vector3 = _px_to_local(Vector2(px, py))     # 既有工具：px → 建築局部座標
	var lp := Vector2(lp3.x, lp3.z)
	var ly: float = y - position.y            # 查詢高度換成「相對一樓地板」
	var best := -INF
	# 樓梯斜面：幾何是 12 塊階梯箱，但支撐面用一道連續斜面近似——
	# 逐階判定會讓人每 0.26m 掉一次、走起來像在抽搐。
	if floors > 1:
		var half := Vector2(rect.size.x * _ws * 0.5, rect.size.y * _ws * 0.5)
		var z0: float = -half.y + 0.61
		var run: float = _stair_run()
		if absf(lp.x - (half.x - 1.05)) <= 0.75 and lp.y >= z0 and lp.y <= z0 + run:
			var ramp: float = clampf((lp.y - z0) / run, 0.0, 1.0) * FLOOR_H
			if ramp <= ly + STEP_TOL:
				best = maxf(best, ramp)
	for f in floors:
		var surf: float = float(f) * FLOOR_H
		if surf <= ly + STEP_TOL:
			best = maxf(best, surf)
	if best == -INF:
		return -INF
	return position.y + best

# 這個點是不是在建築室內（含牆內側）
func inside(px: float, py: float) -> bool:
	return rect.grow(-6.0).has_point(Vector2(px, py))

func _local_to_px(p: Vector2) -> Vector2:
	return Vector2(rect.get_center().x + p.x / _ws, rect.get_center().y + p.y / _ws)

static var _shared_mats := {}
var _deco_doors: Array = []    # [[局部座標 Vector2, 牆的方向角], ...] 裝飾件用
var _deco_wins: Array = []
var _wall_mat: BaseMaterial3D = null      # 這棟的外牆材質（批次鍵用，見 _wall_piece）
func _shared(key: String, c: Color, rough: float) -> StandardMaterial3D:
	if not _shared_mats.has(key):
		_shared_mats[key] = _mat(c, rough)
	return _shared_mats[key]

func _mat(c: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m

func _box(sx: float, sy: float, sz: float, mat: BaseMaterial3D) -> MeshInstance3D:
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

func _emit_box(key: String, mat: BaseMaterial3D, size: Vector3, xf: Transform3D) -> void:
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
		# UV＝世界座標投影（見 BattleMats.world_uv）：合併網格若用各箱子自己的 0~1 UV，
		# 磚縫會在每個接縫處錯開、大小也不一致，貼上去反而更假。
		for p in [a, b, c, a, c, d]:
			st2.set_normal(nrm)
			st2.set_uv(BattleMats.world_uv(p, nrm))
			st2.add_vertex(p)

func _flush_batch() -> void:
	for key in _batch.keys():
		var st: SurfaceTool = _batch[key]
		var mi := MeshInstance3D.new()
		mi.name = "Merged_" + key
		# 法線貼圖沒有切線就是亂的（會看到隨機的凹凸與接縫）。UV 已經給了，這裡補切線。
		st.generate_tangents()
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
		var m := mi.material_override as BaseMaterial3D
		if m == null:
			continue
		if a < 0.99:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		else:
			m.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		m.albedo_color.a = a


# ---------- 建築裝飾件（GDD/14 §0a：素材升級）----------
# 為什麼要有這一段：程式生成的方盒即使貼了圖，輪廓還是「一個開了洞的箱子」。
# 真實建築的辨識度來自輪廓上的凸出物——簷口、門扇、外掛的冷氣機。
# 模組件取自 Downtown City MegaKit（assets/models/city/），授權見 assets/textures/。
# ⚠ 一律 MultiMesh：一棟房子的簷口就二十幾件，逐件一個節點就是二十幾次 draw call。
const DECO := {
	"cornice": "res://assets/models/city/Cornice_Trim_Center.gltf",
	"door": "res://assets/models/city/Door_1.gltf",
	"ac": "res://assets/models/city/Prop_ACUnit.gltf",
}

func _decorate(half: Vector2, top: float) -> void:
	var xf_cornice: Array = []
	var xf_door: Array = []
	# 簷口：沿四面牆頂鋪，每 2m 一件（模組件原尺寸剛好 2m 寬）
	var runs := [
		[Vector2(-half.x, half.y), Vector2(half.x, half.y)],
		[Vector2(half.x, half.y), Vector2(half.x, -half.y)],
		[Vector2(half.x, -half.y), Vector2(-half.x, -half.y)],
		[Vector2(-half.x, -half.y), Vector2(-half.x, half.y)],
	]
	for r in runs:
		var a: Vector2 = r[0]
		var b: Vector2 = r[1]
		var L: float = a.distance_to(b)
		var dir: Vector2 = (b - a) / maxf(L, 0.001)
		var n: int = maxi(1, int(round(L / 2.0)))
		var step: float = L / float(n)
		for i in n:
			var c: Vector2 = a + dir * (step * (float(i) + 0.5))
			# 簷口往外凸 10cm（凸出物才有輪廓），高度壓成 0.45m
			var outv := Vector2(-dir.y, dir.x) * 0.10
			var bs := Basis(Vector3.UP, -atan2(dir.y, dir.x)).scaled(
					Vector3(step / 2.0, 0.45, 1.0))
			xf_cornice.append(Transform3D(bs, Vector3(c.x + outv.x, top - 0.22, c.y + outv.y)))
	# 門扇：卡在門洞裡（模組件 1.0×2.2m → 縮到 DOOR_W×2.15m）
	for d in _deco_doors:
		var pos: Vector2 = d[0]
		var ang: float = d[1]
		var bs2 := Basis(Vector3.UP, -ang).scaled(Vector3(DOOR_W / 1.0, 2.15 / 2.2, 1.0))
		xf_door.append(Transform3D(bs2, Vector3(pos.x, 0.0, pos.y)))
	# 窗台板：沿窗洞下緣往外凸 9cm 的一塊石板。
	# ⚠ 這裡原本掛的是**冷氣機**（Downtown City 模組件），有兩個問題：
	#   ① 年代不對——這是二戰型態的濱海軍事基地，牆上不會有分離式冷氣（軍事顧問16）；
	#   ② 它往外凸 24cm、又剛好在窗口下方，遠看就是「有東西從牆裡露出來」
	#      （使用者 2026-07-27 把它連同窗內看到的樓梯一起讀成「樓梯露在建築外」）。
	#   窗台板同樣提供「凸出物才有的輪廓與陰影」，但年代與尺度都對。
	for w in _deco_wins:
		var pw: Vector2 = w[0]
		var angw: float = w[1]
		var outw := Vector2(-sin(angw), cos(angw)) * 0.05
		if (pw + outw).length() < pw.length():
			outw = -outw          # 一定要朝建築外側凸出
		_emit_box("wall", _wall_mat, Vector3(WIN_W + 0.24, 0.09, WALL_T + 0.14),
				Transform3D(Basis(Vector3.UP, -angw),
				Vector3(pw.x + outw.x, WIN_SILL - 0.05, pw.y + outw.y)))
	_deco_mm("cornice", xf_cornice)
	_deco_mm("door", xf_door)

static var _deco_mesh := {}      # 路徑 → Mesh（全場共用，一個模型只讀一次）

func _deco_mm(key: String, xfs: Array) -> void:
	if xfs.is_empty():
		return
	var path: String = DECO[key]
	if not _deco_mesh.has(path):
		var found: Mesh = null
		if ResourceLoader.exists(path):
			var inst := (load(path) as PackedScene).instantiate()
			for mi in inst.find_children("*", "MeshInstance3D", true, false):
				var m3 := mi as MeshInstance3D
				if m3.mesh != null:
					found = m3.mesh
					break
			inst.queue_free()
		_deco_mesh[path] = found
	var mesh: Mesh = _deco_mesh[path]
	if mesh == null:
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Deco_" + key
	mmi.multimesh = mm
	# ⚠ 門扇模組件自帶的材質幾乎是純黑，在黃昏側逆光下就是門洞上貼了一塊黑板
	#   （實拍第一章營舍：門口是一片純黑長方形）。**視覺元素不可用純黑**——
	#   跟焦土黑洞是同一條教訓。統一覆蓋成深木色。
	if key == "door":
		var dm := BattleMats.pbr("Concrete", 1.2, 0.85, Color(0.42, 0.30, 0.20)).duplicate()
		dm.albedo_texture = null
		mmi.material_override = dm
	add_child(mmi)
