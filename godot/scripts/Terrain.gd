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
var biome: Dictionary = {}
var _waters: Array = []
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
	# 生態設定（Biome.gd）：每張圖的地表配色、草量、遠山色都從這裡來——
	# 先前全部寫死草原，10 張圖裡的沙漠/城鎮/海灘全長一個樣（使用者指正）。
	biome = Biome.of(map)
	# 水域（海灘/海峽/港口）：水面下的地要下陷，岸線才是斜坡不是斷崖
	_waters = []
	for wkey in ["waters", "deepwaters", "shallows"]:
		for wr in map.get(wkey, []):
			_waters.append({"r": Rect2(float(wr.get("x", 0)), float(wr.get("y", 0)),
					float(wr.get("w", 60)), float(wr.get("h", 60))),
					"deep": (1.9 if wkey == "deepwaters" else (0.5 if wkey == "shallows" else 1.2))})
	_group_waters()
	_build_shores()
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
	# 水域下陷：離岸越遠越深（平滑過渡），deepwaters 最深 1.9m。
	# ⚠⚠ 2026-07-27 修正：舊版是「每個矩形各自從自己的邊界往內下陷」，
	#   但 maps.json 的海是 deepwaters／waters／shallows 三條**相鄰**的長條 →
	#   每兩條的交界處海床又升回 0，水下多出兩道暗礁，水面因此出現深淺硬邊的條帶，
	#   遠看就是「好幾片藍色塑膠片疊在一起」（使用者說的藍地毯的一半原因）。
	#   正解：下陷量取「含這個點的矩形裡最深的那一個」，斜坡距離量到**整片相連水域**的邊界。
	var best_deep := 0.0
	var grp := -1
	for wi in _waters.size():
		if (_waters[wi]["r"] as Rect2).has_point(Vector2(px, py)):
			if float(_waters[wi]["deep"]) > best_deep:
				best_deep = float(_waters[wi]["deep"])
			grp = int(_waters[wi]["g"])
	if best_deep > 0.0 and grp >= 0:
		var ub: Rect2 = _water_groups[grp]
		var edge_d: float = minf(minf(px - ub.position.x, ub.end.x - px),
				minf(py - ub.position.y, ub.end.y - py))
		h -= best_deep * clampf(edge_d / 34.0, 0.0, 1.0)
	# 曲線海岸與河道（見下方 _shore_drop）：海床挖出來，岸線就是「地面穿過水面」那條線
	if not (_coasts.is_empty() and _rivers.is_empty()):
		h -= _shore_drop(px, py)
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
# ⚠ 2026-07-27：`data/terrain_mobility.json` 早就寫好每種機動型別的地形倍率
#   （shallow 1.55、wire 1.8、bush 0.85…），但**全專案沒有一行讀它**，
#   這裡自己寫死 1.5／2.0（違反鐵律 3，而且偵察兵跟重裝兵過壕溝一樣快）。
func move_cost(px: float, py: float, mob := "foot") -> float:
	var tab: Dictionary = GameData.terrain_mobility.get(mob, {})
	var c: float = float(tab.get("ground", 1.0))
	if in_water(px, py):
		var d: float = water_depth(px, py)
		var k = tab.get("shallow", 1.55)
		c = maxf(c, float(k) if k != null else 3.0)
		if d > 1.35:
			c = maxf(c, 4.0)          # 深及胸：形同不可通行
	for cr in _craters:
		if Vector2(px - float(cr.get("x", 0)), py - float(cr.get("y", 0))).length() < float(cr.get("r", 36)):
			c = maxf(c, float(tab.get("crater", 1.15)))
	if in_trench(px, py):
		c = maxf(c, float(tab.get("trench", 1.25)))
	if slope_at(px, py) > 0.35:
		c = maxf(c, float(tab.get("hill", 1.15)) * 1.3)
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
				# UV＝世界座標公尺：地表要疊一層土質細節貼圖（純色平面是「整片像塑膠」
				# 最大的單一面積）。顏色仍由頂點色決定，貼圖只負責質感（材質是相乘的）。
				st.set_uv(Vector2(v.x, v.z))
				st.add_vertex(v)
	st.generate_normals()
	st.generate_tangents()
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
	# 基色＝maps.json 的 ground 色（美術在資料層定過的）：壓暗到頂點色量級再做雜訊變化。
	# 沙漠圖的 ground 是沙色、城鎮是灰土——同一條公式，每張圖自然長自己的樣子。
	# ⚠ 2026-07-27（使用者：「地面仍偏禿」）：0.42 太暗。
	#   草的可視距離只有 42m，遠鏡頭下草全被裁掉、畫面上只剩這個頂點色——
	#   底色壓到 0.42 倍就等於「遠看是一片深褐色的土」。
	#   遠景的綠意必須由**地表頂點色**負責，不能指望草（草是給近景的細節）。
	var base: Color = biome.get("ground", Color(0.48, 0.56, 0.35)) * 0.56
	var grass: Color = (base * 0.82).lerp(base * 1.25, n)
	grass = grass.lerp(base, n2 * 0.35)
	var dirt: Color = biome.get("dirt", Color(0.25, 0.20, 0.13))
	var rock: Color = biome.get("rock", Color(0.27, 0.26, 0.24))
	var sl: float = slope_at(px, py)
	var c := grass
	# ⚠ 2026-07-27（使用者：「地面仍偏禿」）：門檻 0.25 太低。
	#   基礎起伏 ±0.9m 加上丘陵，全圖大半的坡度都超過 0.25，於是整片變裸土。
	#   現實裡草長不住的是**陡坡**（沖刷帶走表土），緩坡照樣是草。門檻拉到 0.45。
	c = c.lerp(dirt, clampf((sl - 0.45) * 1.8, 0.0, 0.62))      # 陡一點才是裸土
	c = c.lerp(rock, clampf((sl - 0.95) * 1.6, 0.0, 0.55))      # 更陡＝碎石
	# 岸線（使用者 2026-07-26：「河流只有一片藍色叫做河流? 不對吧」）：
	# 真實水岸是「濕泥/沙灘帶 → 乾土 → 草」的漸層，而不是草地直接切進藍色貼片。
	# 這裡把靠近水域的地表染成濕沙色並壓暗（濕的土比乾的暗）。
	# ⚠⚠ 2026-07-27：這段原本只讀 `_waters` **矩形**。第一章改成曲線海岸後那個陣列是空的，
	#   於是整條「濕泥→乾沙→草」的岸帶靜默消失，海灘直接是乾土（實拍）。
	#   這是本專案第三次「換了資料來源、舊的消費端沒跟上」——改成問地形本身的水位高差。
	var sh_wet := 0.0
	if not (_coasts.is_empty() and _rivers.is_empty()):
		# 高出水面幾公尺：0 = 水線，越高越乾。1.1m 之內都算潮間帶／河灘
		var above: float = -water_signed(px, py)
		if above > -99.0:
			sh_wet = clampf(1.0 - above / 1.10, 0.0, 1.0)
	for w2 in _waters:
		var wr2: Rect2 = w2["r"]
		var band: float = 46.0
		if wr2.grow(band).has_point(Vector2(px, py)):
			var dx2: float = maxf(maxf(wr2.position.x - px, px - wr2.end.x), 0.0)
			var dy2: float = maxf(maxf(wr2.position.y - py, py - wr2.end.y), 0.0)
			sh_wet = maxf(sh_wet, 1.0 - clampf(sqrt(dx2 * dx2 + dy2 * dy2) / band, 0.0, 1.0))
	if sh_wet > 0.0:
		# 邊界要參差：一條平滑的等寬濕帶看起來是「畫上去的鑲邊」
		sh_wet *= clampf(0.6 + _vnoise(px * 0.035, py * 0.035) * 0.8, 0.0, 1.0)
		# 乾沙（近水但在潮線之上）→ 濕泥沙（潮線附近）
		var dry_sand := Color(0.56, 0.48, 0.34)
		var wet_c := Color(0.31, 0.26, 0.18)
		c = c.lerp(dry_sand, clampf(sh_wet * 1.5, 0.0, 0.85))
		c = c.lerp(wet_c, clampf((sh_wet - 0.55) * 2.2, 0.0, 0.88))
	# 彈坑焦痕：直接烤進地表頂點色。先前是 Props 擺一堆懸空的黑色薄板（burn box），
	# 在彈坑斜壁上會翹起、懸空——燒焦是「地表本身變黑」，不是一種物體（鐵律 0）。
	for cr2 in _craters:
		var dcr: float = Vector2(px - float(cr2.get("x", 0)), py - float(cr2.get("y", 0))).length()
		var rcr: float = float(cr2.get("r", 36)) * 1.55
		if dcr < rcr:
			var kk: float = 1.0 - dcr / rcr
			# 邊緣參差：疊雜訊讓焦痕不是正圓
			kk *= clampf(0.55 + _vnoise(px * 0.05, py * 0.05) * 0.9, 0.0, 1.0)
			# 上限 0.55：0.85 疊上黃昏陰影後彈坑變成看不見底的黑洞（實拍），
			# 燒焦的土在現實裡仍反光，是深炭褐不是純黑
			c = c.lerp(Color(0.16, 0.13, 0.10), clampf(kk * 1.1, 0.0, 0.55))
	# 裸土斑塊：只靠坡度分層，平地就是一整片同色的草皮（實拍俯瞰很明顯）。
	# 真實草地會有踩禿的土、乾掉的枯草塊，用兩層雜訊做出不規則邊界。
	var pn: float = _vnoise(px * 0.006 + 41.0, py * 0.006 + 17.0)
	var pn2: float = _vnoise(px * 0.028 + 9.0, py * 0.028 + 3.0)
	# ⚠ 門檻 0.62、強度 0.55 疊在上面那層之後，平地也有一半是土色。
	#   踩禿的土斑本來就是「少數幾塊」，不是地表的底色。
	var patch: float = clampf((pn * 0.8 + pn2 * 0.35 - 0.74) * 3.6, 0.0, 1.0)
	c = c.lerp(dirt.lerp(Color(0.33, 0.27, 0.17), pn2), patch * 0.34)
	# 枯草：另一組雜訊，偏黃綠，面積小一點
	var dn: float = clampf((_vnoise(px * 0.013 + 77.0, py * 0.013 + 5.0) - 0.58) * 3.6, 0.0, 1.0)
	c = c.lerp(Color(0.31, 0.30, 0.12), dn * 0.32)
	if v.y < -0.25:
		c = c.lerp(Color(0.26, 0.21, 0.15), clampf(-v.y * 0.55, 0.0, 0.8))   # 溝底/彈坑＝翻起的泥
	# ⚠ 頂點色會被當成「線性空間」直接用，不轉換就會整片洗白——
	#   跟地表 shader 那次是同一個坑（GDD/10「sRGB 洗白」，2026-07-26 第二次踩到）。
	return c.srgb_to_linear()

# 由 Main 在建築建好後呼叫：no_rects＝建築的實際佔地（禁草區）
var _tree_feet: Array = []      # 樹腳位置（px）：在樹底補一圈草，樹才不是「插在地上」

func build_grass(no_rects: Array, tree_feet: Array = []) -> void:
	_no_grass = []
	for r in no_rects:
		_no_grass.append((r as Rect2).grow(1.2 / ws))
	_tree_feet = tree_feet
	_build_grass()

# ---------- 草（MultiMesh，一次繪製）----------
# 兩層：全地圖鋪一層稀疏矮草（先前只有 bushes 區有草，其餘地面光禿禿），
# bushes 區再鋪一層密集高草＝真正能藏人的草叢。
func _build_grass() -> void:
	_grass_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = GRASS_SHADER
	_grass_mat.shader = sh
	# ⚠ 比例（合理化鐵則）：草地那層先前最高接近 1m，第三人稱走進去畫面全是巨大葉片。
	#   真實草地是「矮而密」——高度砍到腳踝，葉片數加倍補密度，繪製次數不變。
	var gd: float = float(biome.get("grass_density", 1.0))
	if gd > 0.01:
		# 可視距離 42→58m：42m 在斜俯瞰下大約只到畫面下緣三分之一，
		# 中景就已經沒有草了。實例數不變，只是多畫一點（[perf] 要盯著）。
		_grass_layer(_tuft_mesh(0.55, 9), _scatter_field(), 58.0, "GrassField")
		# ★戰場外那一圈（2026-07-27 使用者：「遠景空曠、中景沒銜接」）：
		#   地形在戰場外還鋪了 90m，但草只鋪到戰場邊界，於是戰場邊緣就是一條
		#   「草地 → 光禿土地」的硬邊，遠景整片是裸土。
		#   外圈用 2.4 倍間距的稀草銜接（葉片數也減半），成本只有內圈的六分之一。
		_grass_layer(_tuft_mesh(0.62, 5), _scatter_outer(), 60.0, "GrassOuter")
	# ⚠ 高草的葉片寬度也跟著 scale_f 放大，1.35 倍時單片葉子有 4.3cm 寬——
	#   第三人稱貼地時整個畫面被幾片巨大葉子塞滿（使用者：畫面全是草）。
	#   高度保留（要藏得住蹲著的人），寬度砍回正常草葉。
	_grass_layer(_tuft_mesh(1.15, 11, 0.62), _scatter_bushes(), 70.0, "GrassBush")
	_grass_layer(_tuft_mesh(0.75, 10), _scatter_tree_feet(), 55.0, "GrassRoots")

# 樹腳的草：物件與地面的過渡。少了這一圈，樹看起來就是「插在草皮上的模型」。
func _scatter_tree_feet() -> Array:
	var xf: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 5150
	for tf in _tree_feet:
		var c: Vector2 = tf
		for i in 7:
			var a: float = rng.randf() * TAU
			var d: float = sqrt(rng.randf()) * (1.1 / ws)
			var gx: float = c.x + cos(a) * d
			var gy: float = c.y + sin(a) * d
			if _indoors(gx, gy):
				continue
			xf.append(_tuft_xf(gx, gy, rng, 0.9, 1.4))
	return xf

# 全地圖稀疏矮草：間距約 3.6m，避開建築、壕溝與陡坡（陡坡是裸土碎石）
func _scatter_field() -> Array:
	var xf: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260727
	# ⚠ 密度與成本的平衡（2026-07-26 實測）：0.8m 太疏（俯瞰是光禿草皮），
	#   但一路加到 0.55m 會讓實例數翻倍、幀時 5.8→20.5ms（49FPS，破 60FPS 預算）。
	#   0.7m 間距＋每叢葉片數 13→9，總頂點數幾乎不變，看起來卻更密。
	var step: float = 0.7 / ws / maxf(float(biome.get("grass_density", 1.0)), 0.05)
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

# 戰場外圈的稀草：只為了把「戰場」與「遠景森林」之間那段光禿地補起來。
# 間距刻意放大，玩家不會走到那裡，只需要遠看有東西。
func _scatter_outer() -> Array:
	var xf: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 771144
	var step: float = 1.7 / ws / maxf(float(biome.get("grass_density", 1.0)), 0.05)
	var band: float = 62.0 / ws
	var px := -band
	while px < mw + band:
		var py := -band
		while py < mh + band:
			var jx: float = px + rng.randf_range(-step * 0.45, step * 0.45)
			var jy: float = py + rng.randf_range(-step * 0.45, step * 0.45)
			py += step
			if jx > 0.0 and jx < mw and jy > 0.0 and jy < mh:
				continue                       # 戰場內已經有細草，不重複鋪
			if slope_at(jx, jy) > 0.8 or in_water(jx, jy):
				continue
			xf.append(_tuft_xf(jx, jy, rng, 0.9, 1.6))
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
	return in_water(px, py)      # 水裡不長草（實拍海灘的草長在水面下）

# 水面高度（公尺）。Main._build_water 畫水面時用同一個值，兩邊不可各寫各的，
# 否則「畫出來的水面」和「算出來的水深」會對不起來。
const WATER_SURFACE_Y := -0.30
# 涉水上限（公尺）。深水圍欄、移動成本、走查判準**共用這一個數字**。
# ⚠ 2026-07-28 從 1.35（及胸）降到 1.05（及腰）：走查台實拍到「水淹到脖子還在走」，
#   那不叫涉水叫游泳，而且人在那個深度根本推不動水、畫面上是一顆頭在漂。
#   帶裝備的步兵可通行的實務上限就是腰部。
const WADE_MAX := 1.05

# 把相連（或重疊）的水域矩形分組，每組存一個外框。
# 分組是必要的：直接用「全部水域的外框」會讓兩個相距很遠的獨立水塘共用一個大外框，
# 各自的岸邊就會突然變深。
var _water_groups: Array[Rect2] = []

func _group_waters() -> void:
	_water_groups = []
	var gid: Array[int] = []
	for i in _waters.size():
		gid.append(-1)
	for i in _waters.size():
		if gid[i] >= 0:
			continue
		var g: int = _water_groups.size()
		var bb: Rect2 = _waters[i]["r"]
		gid[i] = g
		var changed := true
		while changed:
			changed = false
			for j in _waters.size():
				if gid[j] >= 0:
					continue
				if bb.grow(2.0).intersects(_waters[j]["r"]):
					gid[j] = g
					bb = bb.merge(_waters[j]["r"])
					changed = true
		_water_groups.append(bb)
	for i in _waters.size():
		_waters[i]["g"] = gid[i]

# ---------- 曲線海岸與河道（2026-07-27 使用者：「河道或海要做到細緻細膩」）----------
# 為什麼要重做：舊版「矩形內部才是水」，岸線只能是直角，遠看就是一塊藍色長方形。
# 關鍵觀察——水面網格早就是**逐格看水深**才畫的（水深 0 的格子不畫），
# 也就是說岸線其實是「地面高度穿過水面 -0.30m 的那條等高線」。
# 所以只要把**海床**做成曲線，岸線就自動變成曲線，而且涉水減速、樹木避水、
# AI 尋路、水面網格全部免費跟著對——形狀放進地形，不要放進判定式。
#
# maps.json 新欄位（都是選用，舊圖不寫就走原本的矩形邏輯）：
#   "coast":  {"pts": [[x,y],...], "sea": "west|east|north|south",
#              "depth": 最深幾公尺, "slope": 幾 px 內從岸邊降到最深}
#   "rivers": [{"pts": [[x,y],...], "w": 河寬px, "depth": 幾公尺, "bank": 岸堤高}]
# ⚠ pts 會先做一次 Catmull-Rom 加密（每段補 6 點），折線才不會看起來是折的。
var _coasts: Array = []
var _rivers: Array = []
# 淺灘／渡口：河床在這裡抬起來，人走得過去。沒有渡口的河＝一道無法通過的牆，
# 而真實戰場的河一定有渡口，渡口本身就是戰術焦點（所有人都得從那裡過）。
var _fords: Array = []

func _smooth_path(pts: Array, per_seg := 6) -> Array:
	if pts.size() < 2:
		return pts
	var out: Array = []
	for i in range(pts.size() - 1):
		var p0: Vector2 = pts[maxi(i - 1, 0)]
		var p1: Vector2 = pts[i]
		var p2: Vector2 = pts[i + 1]
		var p3: Vector2 = pts[mini(i + 2, pts.size() - 1)]
		for k in per_seg:
			var t: float = float(k) / float(per_seg)
			# Catmull-Rom：通過每一個控制點，資料寫起來直觀（點就是岸線上的點）
			var t2: float = t * t
			var t3: float = t2 * t
			out.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t
					+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
					+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3))
	out.append(pts[pts.size() - 1])
	return out

func _pts_of(d: Dictionary) -> Array:
	var raw: Array = []
	for p in d.get("pts", []):
		raw.append(Vector2(float(p[0]), float(p[1])))
	return _smooth_path(raw)

func _build_shores() -> void:
	_coasts = []
	_rivers = []
	var c = map.get("coast", null)
	if c != null:
		var pts: Array = _pts_of(c)
		if pts.size() >= 2:
			_coasts.append({"pts": pts, "sea": String(c.get("sea", "west")),
					"depth": float(c.get("depth", 2.2)), "slope": float(c.get("slope", 70.0))})
	_fords = []
	for fd in map.get("fords", []):
		_fords.append({"c": Vector2(float(fd.get("x", 0)), float(fd.get("y", 0))),
				"r": float(fd.get("r", 90)), "k": float(fd.get("shallow", 0.42))})
	for rv in map.get("rivers", []):
		var rp: Array = _pts_of(rv)
		if rp.size() >= 2:
			_rivers.append({"pts": rp, "hw": float(rv.get("w", 60)) * 0.5,
					"depth": float(rv.get("depth", 1.2)), "bank": float(rv.get("bank", 0.35))})

# 這個點在岸線的海側多深處（px）。陸側回負值。
func _sea_side_dist(co: Dictionary, p: Vector2) -> float:
	var d: float = _dist_to_path(p, co["pts"])
	# 用「岸線本身的走向」判斷內外太脆弱（折線一凹就翻面）。
	# 這裡用最單純可靠的方式：海在哪一邊是資料寫死的，比座標即可。
	var near: Vector2 = _closest_on_path(p, co["pts"])
	var inside: bool
	match String(co["sea"]):
		"east": inside = p.x > near.x
		"north": inside = p.y < near.y
		"south": inside = p.y > near.y
		_: inside = p.x < near.x
	return d if inside else -d

func _closest_on_path(p: Vector2, pts: Array) -> Vector2:
	var best: Vector2 = pts[0]
	var bd := 1.0e20
	for i in range(pts.size() - 1):
		var q: Vector2 = Geometry2D.get_closest_point_to_segment(p, pts[i], pts[i + 1])
		var dd: float = p.distance_squared_to(q)
		if dd < bd:
			bd = dd
			best = q
	return best

# 海床／河床下陷量（公尺，正值＝往下挖）。也回傳岸堤抬升（負值）。
func _shore_drop(px: float, py: float) -> float:
	var p := Vector2(px, py)
	var drop := 0.0
	for co in _coasts:
		var d: float = _sea_side_dist(co, p)
		if d > 0.0:
			# smoothstep：岸邊是緩灘、外海才到最深，不是一階梯下去
			var t: float = clampf(d / float(co["slope"]), 0.0, 1.0)
			drop = maxf(drop, float(co["depth"]) * t * t * (3.0 - 2.0 * t))
	# 渡口：河床抬起（drop 乘上一個小於 1 的係數），中心最淺、往外恢復原深
	var ford_k := 1.0
	for fd in _fords:
		var fdd: float = p.distance_to(fd["c"])
		if fdd < float(fd["r"]):
			var ft: float = fdd / float(fd["r"])
			ford_k = minf(ford_k, lerpf(float(fd["k"]), 1.0, ft * ft))
	for rv in _rivers:
		var d2: float = _dist_to_path(p, rv["pts"])
		var hw: float = rv["hw"]
		if d2 < hw:
			var k: float = 1.0 - pow(d2 / hw, 2.2)      # 中央最深、往兩側收成 U 形
			drop = maxf(drop, float(rv["depth"]) * k * ford_k)
		elif d2 < hw * 1.6:
			# 河岸土堤：河不會是「地面上挖一條溝」，兩側會有沖積的高地
			var k2: float = 1.0 - (d2 - hw) / (hw * 0.6)
			drop -= float(rv["bank"]) * k2 * k2
	return drop

# 水域遮罩：純粹用高度判定的話，地形雜訊隨機凹下去的地方會憑空變成一灘水。
# 只有「水源宣告過的範圍」才可能有水。margin＝往外放寬幾 px（散佈物避水用）。
func _water_mask(px: float, py: float, margin := 0.0) -> bool:
	var p := Vector2(px, py)
	for w in _waters:
		if (w["r"] as Rect2).grow(margin).has_point(p):
			return true
	for co in _coasts:
		if _sea_side_dist(co, p) > -margin:
			return true
	for rv in _rivers:
		if _dist_to_path(p, rv["pts"]) < float(rv["hw"]) + margin:
			return true
	return false

func sea_dir() -> String:
	return String(_coasts[0]["sea"]) if not _coasts.is_empty() else ""

func has_shores() -> bool:
	return not (_coasts.is_empty() and _rivers.is_empty())

# 岸線上的取樣點（給 Main 佈深水圍欄用）
func coast_points() -> Array:
	var out: Array = []
	for co in _coasts:
		var pts: Array = co["pts"]
		for i in range(0, pts.size(), 2):
			out.append(pts[i])
	return out

# 海岸／河道的涵蓋範圍（px）：Main 用它決定水面網格要鋪多大
func shore_bounds() -> Rect2:
	var r := Rect2()
	var first := true
	for src in (_coasts + _rivers):
		var pad: float = float(src.get("slope", 0.0)) + float(src.get("hw", 0.0)) + 40.0
		for q in src["pts"]:
			var rr := Rect2(q as Vector2, Vector2.ZERO).grow(pad)
			r = rr if first else r.merge(rr)
			first = false
	if not _coasts.is_empty():
		# 海要一路鋪到地圖外，不然遠景會看到海突然結束
		match String(_coasts[0]["sea"]):
			"east": r = r.merge(Rect2(mw * 0.5, -OUTER / ws, mw, mh + 2.0 * OUTER / ws))
			"north": r = r.merge(Rect2(-OUTER / ws, -OUTER / ws, mw + 2.0 * OUTER / ws, mh * 0.5))
			"south": r = r.merge(Rect2(-OUTER / ws, 0.0, mw + 2.0 * OUTER / ws, mh))
			_: r = r.merge(Rect2(-OUTER / ws, -OUTER / ws, mw * 0.5 + OUTER / ws,
					mh + 2.0 * OUTER / ws))
	return r

# 這個點的水深（公尺，不在水裡回 0）＝水面高度減地面高度。
# 鐵律 0⑤：人在及腰的水裡不可能維持 3m/s 行軍。先前 waters/shallows 只是一張
# 半透明貼圖，不減速也不淹沒——這支就是把「畫出來的水」變成真的水。
func water_depth(px: float, py: float) -> float:
	if not _water_mask(px, py):
		return 0.0
	return maxf(0.0, WATER_SURFACE_Y - height_at(px, py))

# 帶正負號的水深：陸地回負值（高出水面幾公尺），不在水域遮罩內回 -99。
# 給水面網格判斷「這一格要不要畫」用——只看 water_depth>0 的話，格子是整格畫或整格不畫，
# 岸線就會呈現一階一階的鋸齒（實拍第一章海灘）。留一圈略高於水面的裙邊，
# 那些頂點 alpha 本來就是 0、而且位置低於地面會被地形擋住，看不見卻能把鋸齒補平。
func water_signed(px: float, py: float) -> float:
	if not _water_mask(px, py, 4.0):
		return -99.0
	return WATER_SURFACE_Y - height_at(px, py)

func water_depth_world(pos: Vector3) -> float:
	return water_depth(pos.x / ws + mw * 0.5, pos.z / ws + mh * 0.5)

# 這個點在不在水域（含淺水）：樹、巨石、電線桿的散佈都要避開
func in_water(px: float, py: float) -> bool:
	# ⚠ 這支是給「樹/巨石/電線桿不要長在水裡」用的，寧可保守：
	#   遮罩內、而且地面低於水面 +0.25m（潮間帶也算）就當成水。
	if not _water_mask(px, py, 6.0):
		return false
	if _coasts.is_empty() and _rivers.is_empty():
		return true          # 舊的矩形水域：在矩形裡就是水（維持原行為）
	return height_at(px, py) < WATER_SURFACE_Y + 0.25

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

# 遠景山脈（2026-07-26 重做）：先前是一圈「各自獨立的單片三角形」，
# 實拍就是天邊一排純灰三角錐——沒有山脊、沒有受光面、沒有距離感（使用者指正）。
# 真山脈看起來對的三件事，本函式就是照著做：
#   1. 連續山脊：相鄰的峰要連成一道稜線，不是各自站著的錐體
#   2. 受光面／背光面：同一座山朝太陽那側亮、背側暗，體積感全靠這個
#   3. 空氣透視：越遠的層越淡、越接近天空水平色，山腳融進霧裡
func _build_backdrop() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var base_r: float = maxf(mw, mh) * ws * 1.5 + 120.0
	# 三層：近山深而細、遠山淡而高大（遠山要更高才看得到，被近山擋掉一半）
	# [半徑倍率, 高度下限, 高度上限, 顏色, 雜訊頻率, 段數]
	# 遠山是 unshaded 頂點色（不吃光照），夜間圖要乘時段亮度自己壓暗，
	# 否則夜襲章節的山還是白天亮度（實拍港口夜戰抓到）
	var smul: Color = Biome.sky_preset(str(map.get("sky", "day"))).get("mul", Color(1, 1, 1))
	var bd0: Array = biome.get("backdrop", [Color(0.26, 0.31, 0.28),
			Color(0.40, 0.45, 0.50), Color(0.55, 0.62, 0.72)])
	var bd: Array = [bd0[0] * smul, bd0[1] * smul, bd0[2] * smul]
	var layers := [
		[1.00, 26.0, 62.0, bd[0], 3.1, 92],
		[1.55, 48.0, 108.0, bd[1], 2.3, 74],
		[2.30, 82.0, 170.0, bd[2], 1.7, 58],
	]
	# 太陽在西南（跟 Main 的主光一致）：那一側的坡面亮
	var sun_dir := Vector2(-0.6, -0.8).normalized()
	for L in layers:
		var rmul: float = float(L[0])
		var h_lo: float = float(L[1])
		var h_hi: float = float(L[2])
		var col: Color = L[3]
		var freq: float = float(L[4])
		var n: int = int(L[5])
		var rng := RandomNumberGenerator.new()
		rng.seed = 4242 + n
		var prev_out: Vector3 = Vector3.ZERO
		var prev_in: Vector3 = Vector3.ZERO
		var prev_top: Vector3 = Vector3.ZERO
		var prev_a := 0.0
		for i in range(n + 1):
			var t: float = float(i) / float(n)
			var a: float = TAU * t
			# 稜線高度＝兩層雜訊（大山塊 + 小峰）；用角度當座標，繞回來要接得上
			var nz: float = _vnoise(cos(a) * freq + 11.3, sin(a) * freq + 7.1)
			var nz2: float = _vnoise(cos(a) * freq * 3.7 + 3.0, sin(a) * freq * 3.7 + 9.0)
			var hh: float = h_lo + (h_hi - h_lo) * clampf(nz * 0.75 + nz2 * 0.35, 0.0, 1.0)
			var d: float = base_r * rmul * (0.94 + 0.12 * nz2)
			var dir := Vector3(cos(a), 0, sin(a))
			# 山脊有厚度：外緣、內緣各一條底線，中間是稜線
			var out_p: Vector3 = dir * (d + hh * 0.85) + Vector3(0, -6.0, 0)
			var in_p: Vector3 = dir * (d - hh * 0.75) + Vector3(0, -6.0, 0)
			var top_p: Vector3 = dir * d + Vector3(0, hh, 0)
			if i > 0:
				# 受光：稜線兩側的坡面各給不同亮度（內側朝場中央＝朝相機那面）
				var nrm_in := Vector2(-dir.x, -dir.z)
				var lit: float = clampf(nrm_in.dot(sun_dir) * 0.5 + 0.5, 0.0, 1.0)
				var c_in: Color = col.lightened(0.10 + 0.22 * lit)
				var c_out: Color = col.darkened(0.22)
				# 山腳融進霧：底邊拉向天空水平色
				var c_foot: Color = col.lerp(Color(0.70, 0.80, 0.88), 0.55)
				# 頂端補亮（受光的岩脊／殘雪）
				var c_top: Color = c_in.lightened(0.12)
				_ridge_quad(st, prev_in, in_p, top_p, prev_top, c_foot, c_top)
				_ridge_quad(st, prev_top, top_p, out_p, prev_out, c_top.lerp(c_out, 0.6), c_out)
			prev_out = out_p
			prev_in = in_p
			prev_top = top_p
			prev_a = a
	st.generate_normals()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED   # 背板不打光：受光感靠頂點色，也省效能
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(mat)
	var mi := MeshInstance3D.new()
	mi.name = "Backdrop"
	mi.mesh = st.commit()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

# 山脊的一片四邊形：a,b 是底邊（顏色 c0），c,d 是上邊（顏色 c1）。兩面都畫。
func _ridge_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		c0: Color, c1: Color) -> void:
	var quad := [[a, c0], [b, c0], [c, c1], [d, c1]]
	for tri in [[0, 1, 2], [0, 2, 3], [2, 1, 0], [3, 2, 0]]:
		for k in tri:
			st.set_color((quad[k][1] as Color).srgb_to_linear())
			st.add_vertex(quad[k][0] as Vector3)

# 一叢草（2026-07-26 重做）：原本是三片交叉的大三角形（0.95m 高、0.34m 寬），
# 第三人稱趴下來近看就是三片塑膠片。改成多根細葉，每根兩段、往上收尖並朝隨機方向彎。
# 頂點色 alpha 存「離地權重」給風擺動用（0=根、1=尖）；材質不透明，alpha 不影響顯示。
func _tuft_mesh(scale_f: float, blades := 7, width_f := 1.0) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	# ⚠ 頂點色會被當成線性空間直接用，不轉就整片偏亮——GDD/10「sRGB 洗白」，
	#   地表 shader、地表頂點色之後，這是同一天第三次踩到。
	var tint: Color = biome.get("grass_tint", Color(1, 1, 1)) if not biome.is_empty() else Color(1, 1, 1)
	var root := (Color(0.16, 0.24, 0.09) * tint).srgb_to_linear()
	var tipc := (Color(0.48, 0.60, 0.24) * tint).srgb_to_linear()
	for k in blades:
		var a: float = rng.randf() * TAU
		var off := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.0, 0.38) * scale_f
		var h: float = rng.randf_range(0.24, 0.60) * scale_f
		var w: float = rng.randf_range(0.020, 0.032) * scale_f * width_f
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
