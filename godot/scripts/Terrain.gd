# Terrain.gd — 戰場地形（GDD/14 §1）：把原本的一張平面換成高度場網格。
# 提供三件事：
#   1. 可跑可躲的幾何：丘陵起伏、壕溝、彈坑（土堤在溝旁自然隆起）
#   2. height_at()：所有單位一律貼著地形站，不再假設地面 y=0
#   3. 掩體與地形效果的資料來源：壕溝＝半身掩體、草叢＝隱蔽、上坡＝AP 加成
# 資料一律讀 data/maps.json（鐵律 3），本檔不寫死任何一張地圖的內容。
class_name BattleTerrain
extends Node3D

const CELL := 0.8                 # 網格邊長（公尺）。壕溝寬 2.2m，0.8 才切得出溝形
const HILL_H_SCALE := 0.4         # maps.json 的 hills.h 是 px 時代的值，×0.4 換成公尺（12→4.8m）
const TRENCH_DEPTH := 1.4         # 壕溝深（GDD/14 §1）
const TRENCH_BERM := 0.45         # 溝口外緣的土堤高
const CRATER_DEPTH := 1.1
const OUTER := 90.0               # 戰場外再鋪多遠（公尺）：不鋪遠一點，遠鏡頭會看到地圖是塊浮空積木
const OUTER_CELL := 7.5           # 外圍用粗網格，省三角形

var map: Dictionary = {}
var ws := 0.05                    # WORLD_SCALE：遊戲 px → 公尺
var mw := 960.0                   # 地圖寬（px）
var mh := 600.0
var _hills: Array = []
var _craters: Array = []
var _trenches: Array = []         # 每筆 {pts:[Vector2(px)], hw:半寬(px)}
var _grass_zones: Array = []
var _no_grass: Array[Rect2] = []      # 建築佔地（室內不長草）
var _grass_mat: ShaderMaterial = null

# ---------- 建置 ----------
func build(map_data: Dictionary, world_scale: float) -> void:
	map = map_data
	ws = world_scale
	mw = float(map.get("w", 960))
	mh = float(map.get("h", 600))
	_hills = map.get("hills", [])
	_craters = map.get("foxholes", [])
	_trenches = []
	for t in map.get("trenches", []):
		var pts: Array = []
		for p in t.get("pts", []):
			pts.append(Vector2(float(p[0]), float(p[1])))
		if pts.size() >= 2:
			_trenches.append({"pts": pts, "hw": float(t.get("w", 44)) * 0.5})
	_grass_zones = map.get("bushes", [])
	_no_grass = []
	_build_mesh()
	# ⚠ 草不在這裡生成：建築的實際佔地要等 Building 建完才知道
	#   （Building.rect 有「最小 120px」的規則，比 maps.json 的原始尺寸大），
	#   用原始尺寸當禁草區會漏掉一圈，實拍就是室內地板上長草。
	#   由 Main 在建好建築後呼叫 build_grass()。
	_build_backdrop()

# --- 值雜訊（value noise）：正弦疊加會產生規則的斜條紋，遠鏡頭一眼看破（實拍）。
# 這裡用固定 hash 的雙線性內插雜訊，結果自然且可重現（同一張圖每次都一樣）。
func _hash21(ix: int, iy: int) -> float:
	var n: int = ix * 374761393 + iy * 668265263
	n = (n ^ (n >> 13)) * 1274126177
	return float((n ^ (n >> 16)) & 0xFFFF) / 65535.0

func _vnoise(x: float, y: float) -> float:
	var xi: int = int(floor(x))
	var yi: int = int(floor(y))
	var fx: float = x - float(xi)
	var fy: float = y - float(yi)
	fx = fx * fx * (3.0 - 2.0 * fx)
	fy = fy * fy * (3.0 - 2.0 * fy)
	var a: float = _hash21(xi, yi)
	var b: float = _hash21(xi + 1, yi)
	var c: float = _hash21(xi, yi + 1)
	var d: float = _hash21(xi + 1, yi + 1)
	return lerp(lerp(a, b, fx), lerp(c, d, fx), fy)

# 高度查詢（輸入＝遊戲 px 座標，輸出＝公尺）。
# ⚠ 這是全遊戲唯一的地面高度真相，單位貼地、鏡頭、點擊落點都要走這裡。
func height_at(px: float, py: float) -> float:
	# 基礎起伏：不是每張地圖都有 hills 資料（第一章那張就沒有），
	# 但「全平的地」在 3D 下一眼就假。用固定的正弦疊加給每張圖一點緩坡，
	# 幅度小到不影響戰術（±0.9m），但遠看就有地貌。
	var h: float = ((_vnoise(px * 0.0035, py * 0.0035) - 0.5) * 1.5
			+ (_vnoise(px * 0.0105, py * 0.0105) - 0.5) * 0.55) * _edge_fade(px, py)
	for hl in _hills:
		var d: float = Vector2(px - float(hl.get("x", 0)), py - float(hl.get("y", 0))).length()
		var r: float = float(hl.get("r", 100))
		if d < r:
			var k: float = 0.5 + 0.5 * cos(PI * d / r)      # 平滑鐘形，邊緣不會有硬邊
			h += float(hl.get("h", 0)) * HILL_H_SCALE * k
	for c in _craters:
		var d2: float = Vector2(px - float(c.get("x", 0)), py - float(c.get("y", 0))).length()
		var r2: float = float(c.get("r", 36))
		if d2 < r2:
			var k2: float = 1.0 - (d2 / r2) * (d2 / r2)
			h -= CRATER_DEPTH * k2
	for t in _trenches:
		var d3: float = _dist_to_path(Vector2(px, py), t["pts"])
		var hw: float = t["hw"]
		if d3 < hw:
			h -= TRENCH_DEPTH * clampf(1.0 - pow(d3 / hw, 6.0), 0.0, 1.0)   # 溝底平、溝壁陡
		elif d3 < hw * 1.9:
			var k3: float = 1.0 - (d3 - hw) / (hw * 0.9)
			h += TRENCH_BERM * k3 * k3                                       # 挖出來的土堆在溝旁
	return h

# 地圖外圍用粗網格鋪，取樣不到細起伏會在邊界形成一圈假懸崖（實拍發現）。
# 故把「基礎起伏」在出界後 25m 內淡出到 0，外圍就是平的、接得上。
func _edge_fade(px: float, py: float) -> float:
	var ox: float = maxf(0.0, maxf(-px, px - mw))
	var oy: float = maxf(0.0, maxf(-py, py - mh))
	var d: float = Vector2(ox, oy).length() * ws
	return clampf(1.0 - d / 60.0, 0.0, 1.0)

func height_at_world(pos: Vector3) -> float:
	return height_at(pos.x / ws + mw * 0.5, pos.z / ws + mh * 0.5)

# 坡度（0＝平地，1＝陡）：上坡移動成本與地表材質分層都要用
func slope_at(px: float, py: float) -> float:
	var d := 12.0
	var hx: float = height_at(px + d, py) - height_at(px - d, py)
	var hz: float = height_at(px, py + d) - height_at(px, py - d)
	return Vector2(hx, hz).length() / (2.0 * d * ws)

# 地形移動成本（GDD/14 §3-4）：上坡 ×1.5、彈坑/溝底 ×2。
# AP 是「距離換算」的，成本倍率直接乘在扣除量上。
func move_cost(px: float, py: float) -> float:
	var c := 1.0
	if slope_at(px, py) > 0.35:
		c = 1.5
	for cr in _craters:
		if Vector2(px - float(cr.get("x", 0)), py - float(cr.get("y", 0))).length() < float(cr.get("r", 36)):
			return 2.0
	return c

# 這個點是不是在壕溝裡（半身掩體判定）
func in_trench(px: float, py: float) -> bool:
	for t in _trenches:
		if _dist_to_path(Vector2(px, py), t["pts"]) < float(t["hw"]) * 0.95:
			return true
	return false

# 壕溝當掩體登記（給 Main 的 _covers 用）：沿折線每隔一段放一個掩體點
func trench_covers() -> Array:
	var out: Array = []
	for t in _trenches:
		var pts: Array = t["pts"]
		for i in range(pts.size() - 1):
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			var seg: float = a.distance_to(b)
			var n: int = maxi(1, int(seg / 90.0))
			for k in range(n + 1):
				var p: Vector2 = a.lerp(b, float(k) / float(n))
				out.append({"wx": p.x, "wy": p.y, "r": float(t["hw"]) + 26.0,
						"val": 0.5, "type": "trench"})
	return out

func _dist_to_path(p: Vector2, pts: Array) -> float:
	var best := 1e9
	for i in range(pts.size() - 1):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var ab: Vector2 = b - a
		var l2: float = ab.length_squared()
		var t: float = 0.0 if l2 < 0.0001 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * t))
	return best

# ---------- 網格 ----------
# 座標軸取樣點：戰場範圍內密（CELL），範圍外用粗網格一路鋪到 OUTER 遠處。
# 只鋪到地圖邊界外 12m 的話，遠鏡頭下整張地圖會像浮在霧裡的一塊積木（實拍發現）。
func _axis(half: float) -> Array:
	var out: Array = []
	var v := -half - OUTER
	while v < -half - 0.01:
		out.append(v)
		v += OUTER_CELL
	v = -half
	while v < half:
		out.append(v)
		v += CELL
	out.append(half)
	v = half + OUTER_CELL
	while v <= half + OUTER + 0.01:
		out.append(v)
		v += OUTER_CELL
	return out

func _build_mesh() -> void:
	var half_x: float = mw * 0.5 * ws
	var half_z: float = mh * 0.5 * ws
	var xs := _axis(half_x)
	var zs := _axis(half_z)
	var nx: int = xs.size()
	var nz: int = zs.size()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for iz in range(nz - 1):
		for ix in range(nx - 1):
			var p00 := _vert(xs[ix], zs[iz])
			var p10 := _vert(xs[ix + 1], zs[iz])
			var p01 := _vert(xs[ix], zs[iz + 1])
			var p11 := _vert(xs[ix + 1], zs[iz + 1])
			# ⚠ 繞序要讓法線朝上（Godot 正面＝順時針看過去）。
			# 繞反了整片地會變成朝下的法線＝全暗一片，看起來像忘了打光（2026-07-26 實拍踩到）。
			for v in [p00, p11, p01, p00, p10, p11]:
				st.set_color(_ground_color(v))
				st.add_vertex(v)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "TerrainMesh"
	mi.mesh = st.commit()
	# 地形不投影：整片 200×200m 的網格丟進 4 段陰影很貴（8 單位 6.2→14.0ms），
	# 而地貌的立體感來自法線著色，關掉幾乎看不出差別（實測 14.0→? ms）。
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mi)
	_terrain_mi = mi

var _terrain_mi: MeshInstance3D = null

func set_material(m: Material) -> void:
	if _terrain_mi:
		_terrain_mi.material_override = m

func _vert(x: float, z: float) -> Vector3:
	return Vector3(x, height_at(x / ws + mw * 0.5, z / ws + mh * 0.5), z)

# 地表分層著色（GDD/14 §0a）：草／土／碎石／泥依「高度、坡度、色斑」決定。
# ⚠ 這件事原本是逐像素 shader 在算（兩次 value noise），整片地板鋪滿螢幕時很貴
#   （8 單位 6.2ms→14ms）。改成建網格時就把顏色烤進頂點色，畫面幾乎一樣、成本歸零。
func _ground_color(v: Vector3) -> Color:
	var px: float = v.x / ws + mw * 0.5
	var py: float = v.z / ws + mh * 0.5
	var n: float = _vnoise(px * 0.011, py * 0.011)      # 大塊色斑
	var n2: float = _vnoise(px * 0.045, py * 0.045)     # 細碎變化
	# 地面朝上、正對天空環境光，實測比同色的直立物件亮很多，
	# 所以基準色要壓得比直覺更暗更飽和，遠看才不會一片死白（2026-07-26 實拍調出來的值）。
	var grass := Color(0.15, 0.24, 0.09).lerp(Color(0.24, 0.34, 0.12), n)
	grass = grass.lerp(Color(0.19, 0.28, 0.10), n2 * 0.35)
	var dirt := Color(0.25, 0.20, 0.13)
	var rock := Color(0.27, 0.26, 0.24)
	var sl: float = slope_at(px, py)
	var c := grass
	c = c.lerp(dirt, clampf((sl - 0.25) * 2.2, 0.0, 0.85))      # 斜面＝裸土
	c = c.lerp(rock, clampf((sl - 0.85) * 1.6, 0.0, 0.6))       # 陡坡＝碎石
	if v.y < -0.25:
		c = c.lerp(Color(0.26, 0.21, 0.15), clampf(-v.y * 0.55, 0.0, 0.8))   # 溝底/彈坑＝翻起的泥
	# ⚠ 頂點色會被當成「線性空間」直接用，不轉換就會整片洗白——
	#   跟地表 shader 那次是同一個坑（GDD/10「sRGB 洗白」，2026-07-26 第二次踩到）。
	return c.srgb_to_linear()

# 由 Main 在建築建好後呼叫：no_rects＝建築的實際佔地（禁草區）
func build_grass(no_rects: Array) -> void:
	_no_grass = []
	for r in no_rects:
		_no_grass.append((r as Rect2).grow(1.2 / ws))
	_build_grass()

# ---------- 草（MultiMesh，一次繪製）----------
# 兩層：全地圖鋪一層稀疏矮草（先前只有 bushes 區有草，其餘地面光禿禿），
# bushes 區再鋪一層密集高草＝真正能藏人的草叢。
func _build_grass() -> void:
	_grass_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = GRASS_SHADER
	_grass_mat.shader = sh
	_grass_layer(_tuft_mesh(1.0), _scatter_field(), 55.0, "GrassField")
	_grass_layer(_tuft_mesh(1.5), _scatter_bushes(), 70.0, "GrassBush")

# 全地圖稀疏矮草：間距約 3.6m，避開建築、壕溝與陡坡（陡坡是裸土碎石）
func _scatter_field() -> Array:
	var xf: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260727
	var step: float = 0.8 / ws
	var px := step
	while px < mw - step:
		var py := step
		while py < mh - step:
			var jx: float = px + rng.randf_range(-step * 0.49, step * 0.49)
			var jy: float = py + rng.randf_range(-step * 0.49, step * 0.49)
			py += step
			if _indoors(jx, jy) or slope_at(jx, jy) > 0.7:
				continue
			xf.append(_tuft_xf(jx, jy, rng, 0.7, 1.05))
		px += step
	return xf

# 草叢區：密集、較高，這才是 GDD/01 §5a 的隱蔽來源
func _scatter_bushes() -> Array:
	var xf: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260726
	for z in _grass_zones:
		var cx: float = float(z.get("x", 0))
		var cy: float = float(z.get("y", 0))
		var r: float = float(z.get("r", 60))
		var n: int = clampi(int(r * r * 0.06), 40, 700)
		for i in n:
			var a: float = rng.randf() * TAU
			var d: float = sqrt(rng.randf()) * r
			var gx: float = cx + cos(a) * d
			var gy: float = cy + sin(a) * d
			if _indoors(gx, gy):
				continue
			xf.append(_tuft_xf(gx, gy, rng, 0.85, 1.3))
	return xf

func _indoors(px: float, py: float) -> bool:
	for nz in _no_grass:
		if nz.has_point(Vector2(px, py)):
			return true
	return false

func _tuft_xf(px: float, py: float, rng: RandomNumberGenerator, s0: float, s1: float) -> Transform3D:
	var pos := Vector3((px - mw * 0.5) * ws, height_at(px, py) - 0.04, (py - mh * 0.5) * ws)
	var b := Basis().rotated(Vector3.UP, rng.randf() * TAU).scaled(
			Vector3.ONE * rng.randf_range(s0, s1))
	return Transform3D(b, pos)

# 遠處的草看不清楚卻照樣要畫：用 visibility_range 讓它淡出，戰術俯瞰時不必付這筆錢。
func _grass_layer(tuft: ArrayMesh, xf: Array, vis_end: float, nm: String) -> void:
	if xf.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = tuft
	mm.instance_count = xf.size()
	for i in xf.size():
		mm.set_instance_transform(i, xf[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = nm
	mmi.multimesh = mm
	mmi.material_override = _grass_mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = vis_end
	mmi.visibility_range_end_margin = vis_end * 0.25
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(mmi)

# 遠景山脈剪影：戰場外圍一圈低多邊形山，讓地圖不再像一塊有邊界的積木。
# 不投影、不受霧影響太多，純粹當背板（GDD/14 §0a：質感來自光影與空間層次）。
func _build_backdrop() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var radius: float = maxf(mw, mh) * ws * 1.5 + 120.0
	var n := 46
	for i in n:
		var a: float = TAU * float(i) / float(n) + rng.randf_range(-0.03, 0.03)
		var d: float = radius * rng.randf_range(0.85, 1.25)
		var hgt: float = rng.randf_range(28.0, 74.0)
		var wdt: float = rng.randf_range(60.0, 130.0)
		var c: Vector3 = Vector3(cos(a) * d, -4.0, sin(a) * d)
		var side := Vector3(-sin(a), 0, cos(a)) * wdt * 0.5
		var top := c + Vector3(0, hgt, 0) + side * rng.randf_range(-0.25, 0.25)
		var col := Color(0.30, 0.36, 0.42).lerp(Color(0.42, 0.48, 0.54), rng.randf())
		for v in [c - side, c + side, top]:
			st.set_color(col.srgb_to_linear())
			st.add_vertex(v)
		for v in [c + side, c - side, top]:      # 背面也畫，繞圈時哪一側都看得到
			st.set_color(col.srgb_to_linear())
			st.add_vertex(v)
	st.generate_normals()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED   # 剪影不需要打光，也省效能
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(mat)
	var mi := MeshInstance3D.new()
	mi.name = "Backdrop"
	mi.mesh = st.commit()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

# 一叢草（2026-07-26 重做）：原本是三片交叉的大三角形（0.95m 高、0.34m 寬），
# 第三人稱趴下來近看就是三片塑膠片。改成多根細葉，每根兩段、往上收尖並朝隨機方向彎。
# 頂點色 alpha 存「離地權重」給風擺動用（0=根、1=尖）；材質不透明，alpha 不影響顯示。
func _tuft_mesh(scale_f: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	# ⚠ 頂點色會被當成線性空間直接用，不轉就整片偏亮——GDD/10「sRGB 洗白」，
	#   地表 shader、地表頂點色之後，這是同一天第三次踩到。
	var root := Color(0.16, 0.24, 0.09).srgb_to_linear()
	var tipc := Color(0.40, 0.52, 0.22).srgb_to_linear()
	for k in 7:
		var a: float = rng.randf() * TAU
		var off := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.0, 0.38) * scale_f
		var h: float = rng.randf_range(0.24, 0.60) * scale_f
		var w: float = rng.randf_range(0.020, 0.032) * scale_f
		var lean_a: float = rng.randf() * TAU
		var lean := Vector3(cos(lean_a), 0, sin(lean_a)) * rng.randf_range(0.10, 0.30) * h
		var side := Vector3(-sin(a), 0, cos(a))
		# 兩段：0→0.55h→h，寬度往上收，位移沿 lean 二次曲線（草是彎的不是直的）
		var p0: Vector3 = off
		var p1: Vector3 = off + Vector3(0, h * 0.55, 0) + lean * 0.30
		var p2: Vector3 = off + Vector3(0, h, 0) + lean
		_blade_seg(st, p0, p1, side * w, side * w * 0.6, root, root.lerp(tipc, 0.55))
		_blade_seg(st, p1, p2, side * w * 0.6, side * w * 0.08, root.lerp(tipc, 0.55), tipc)
	st.generate_normals()
	return st.commit()

# 一段草葉＝一個四邊形（兩個三角形），兩面都畫。alpha 存離地權重。
func _blade_seg(st: SurfaceTool, a: Vector3, b: Vector3, wa: Vector3, wb: Vector3,
		ca: Color, cb: Color) -> void:
	var quad := [[a - wa, ca], [a + wa, ca], [b + wb, cb], [b - wb, cb]]
	for tri in [[0, 1, 2], [0, 2, 3], [2, 1, 0], [3, 2, 0]]:
		for idx in tri:
			var v: Vector3 = quad[idx][0]
			var c: Color = quad[idx][1]
			c.a = clampf(v.y / 0.6, 0.0, 1.0)
			st.set_color(c)
			st.add_vertex(v)

# 草的風擺動：頂點著色器，成本幾乎為零（草的頂點總數才幾萬）。
# 相位取實例的世界座標，整片草才不會同手同腳一起晃。
const GRASS_SHADER := """
shader_type spatial;
render_mode cull_disabled, diffuse_burley;
uniform float wind_t = 0.0;
uniform float wind_amp = 0.10;
varying vec3 vcol;
void vertex() {
	float ph = MODEL_MATRIX[3].x * 0.7 + MODEL_MATRIX[3].z * 0.45;
	float w = COLOR.a;
	float gust = sin(wind_t * 0.37 + ph * 0.11) * 0.5 + 0.75;
	VERTEX.x += sin(wind_t * 2.1 + ph) * wind_amp * w * gust;
	VERTEX.z += cos(wind_t * 1.55 + ph * 1.3) * wind_amp * 0.6 * w * gust;
	vcol = COLOR.rgb;
}
void fragment() {
	ALBEDO = vcol;
	ROUGHNESS = 0.94;
	SPECULAR = 0.05;
}
"""

func _process(_delta: float) -> void:
	if _grass_mat != null:
		_grass_mat.set_shader_parameter("wind_t", float(Time.get_ticks_msec()) * 0.001)
