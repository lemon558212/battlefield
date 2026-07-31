# Trees.gd — 程式化低多邊形樹種工廠（2026-07-27 使用者：「樹木要做到細緻細膩」）。
#
# 為什麼不是再找幾個 glb：全場只有 tree-single 與 pinetrees 兩個模型，整片森林是
# 同一棵樹複製貼上，使用者形容「樹是紙片」。問題不在多邊形數，在**沒有變化**——
# 他給過的四條判準裡有三條是「變化」：細節層次、使用痕跡、材質變化（每個個體顏色不同）。
# 程式化生成一次解決：五個樹種 × 每種三個亂數變體 = 15 份原型網格，
# 再用 MultiMesh 的 per-instance 顏色讓每一棵的葉色都不同。畫質路線仍是低多邊形＋強打光。
#
# 幾何原則（鐵律 0⑤：真實量級）：
#   闊葉喬木 6~9m、木麻黃/松 8~13m、椰子 7~11m、灌木 1.2~2.2m、枯樹 5~8m。
# 使用方式：
#   var protos := Trees.build_protos()          # {種類: [ArrayMesh, ...]}
#   Trees.pick(biome_key, near_water, rng)      # 依生態與離水遠近選樹種
class_name Trees

const KINDS := ["broadleaf", "pine", "palm", "shrub", "dead"]

# 生態 → 樹種權重。海岸多椰子與木麻黃（台灣濱海基地的防風林），沙漠沒有樹。
const MIX := {
	"coast":  {"palm": 0.28, "pine": 0.22, "broadleaf": 0.20, "shrub": 0.18, "dead": 0.12},
	"forest": {"pine": 0.38, "broadleaf": 0.38, "shrub": 0.14, "dead": 0.10},
	"grass":  {"broadleaf": 0.42, "pine": 0.18, "shrub": 0.26, "dead": 0.14},
	"urban":  {"broadleaf": 0.48, "shrub": 0.32, "dead": 0.20},
	"mud":    {"dead": 0.45, "pine": 0.20, "shrub": 0.30, "broadleaf": 0.05},
	"desert": {"shrub": 0.80, "dead": 0.20},
}
# 靠水邊（3m 內）另一套：椰子與灌木長在水邊，松柏不會
const MIX_SHORE := {"palm": 0.44, "shrub": 0.32, "broadleaf": 0.20, "dead": 0.04}

static func pick(biome_key: String, near_water: bool, rng: RandomNumberGenerator) -> String:
	var tab: Dictionary = MIX_SHORE if near_water else MIX.get(biome_key, MIX["grass"])
	var total := 0.0
	for k in tab:
		total += float(tab[k])
	var r: float = rng.randf() * total
	for k in tab:
		r -= float(tab[k])
		if r <= 0.0:
			return String(k)
	return "broadleaf"

# 每個樹種產生 n 個亂數變體的原型網格。回傳 {種類: [ArrayMesh, ...]}。
# ⚠ 變體要在**建置期**就固定下來，不可以每棵樹各建一份網格：
#   一棵一份 = 幾百份網格 = MultiMesh 完全失去意義，幀時會爆（本專案已經踩過一次）。
static func build_protos(variants := 5, seed_v := 20260727) -> Dictionary:
	var out := {}
	var rng := RandomNumberGenerator.new()
	for k in KINDS:
		var list: Array = []
		for v in variants:
			rng.seed = seed_v + hash(k) * 31 + v * 977
			list.append(_make(k, rng))
		out[k] = list
	return out

static func _make(kind: String, rng: RandomNumberGenerator) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	match kind:
		"pine": _pine(st, rng)
		"palm": _palm(st, rng)
		"shrub": _shrub(st, rng)
		"dead": _dead(st, rng)
		_: _broadleaf(st, rng)
	st.generate_normals()
	return st.commit()

# ---------- 各樹種 ----------

static func _broadleaf(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	# ★2026-07-27 重做（使用者：「樹冠仍偏一顆大白菜」）。
	# 一顆大團塊不管怎麼加雜訊都是一顆球。真實樹冠的輪廓是**好幾叢枝葉各自成團**，
	# 團與團之間有缺口、有陰影，逆光看得到天空從縫隙透過來。
	# 所以改成：主幹分岔 → 每根枝的末端各長一叢小團塊 → 團塊排在一個壓扁的半球殼上。
	var h: float = rng.randf_range(4.6, 8.2)
	var r0: float = h * rng.randf_range(0.032, 0.046)
	# 主幹微彎（兩段）：筆直的圓柱一看就是程式生成的
	var mid := Vector3(rng.randf_range(-0.18, 0.18), h * 0.30, rng.randf_range(-0.18, 0.18))
	var fork: Vector3 = mid + Vector3(rng.randf_range(-0.30, 0.30), h * 0.22,
			rng.randf_range(-0.30, 0.30))
	var bark: Color = _bark(rng)
	_taper(st, Vector3.ZERO, mid, r0, r0 * 0.78, 7, bark)
	_taper(st, mid, fork, r0 * 0.78, r0 * 0.60, 6, bark * 1.04)
	var leaf: Color = _leaf(rng)
	var crown_r: float = h * rng.randf_range(0.30, 0.40)      # 樹冠半徑
	var crown_y: float = h * rng.randf_range(0.30, 0.40)      # 樹冠中心離分岔多高
	var nb: int = rng.randi_range(3, 5)
	var tips: Array = []
	for i in nb:
		var a: float = TAU * (float(i) + rng.randf_range(-0.25, 0.25)) / float(nb)
		var reach: float = crown_r * rng.randf_range(0.45, 0.85)
		var tip: Vector3 = fork + Vector3(cos(a) * reach,
				crown_y * rng.randf_range(0.55, 1.0), sin(a) * reach)
		_taper(st, fork, tip, r0 * 0.52, r0 * 0.18, 5, bark * rng.randf_range(0.9, 1.1))
		tips.append(tip)
	# 葉團：每根枝末端一叢，再補幾叢填在枝與枝之間，缺口留著不要補滿
	var lumps: Array = []
	for tip2 in tips:
		lumps.append([tip2, rng.randf_range(0.28, 0.42)])
	for i in rng.randi_range(3, 5):
		var a2: float = rng.randf() * TAU
		var rr: float = crown_r * rng.randf_range(0.25, 0.95)
		lumps.append([fork + Vector3(cos(a2) * rr,
				crown_y * rng.randf_range(0.6, 1.25), sin(a2) * rr),
				rng.randf_range(0.22, 0.36)])
	for lm in lumps:
		_blob(st, lm[0] as Vector3, crown_r * float(lm[1]),
				rng.randf_range(0.66, 0.92), leaf * rng.randf_range(0.82, 1.18), rng)

static func _pine(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	var h: float = rng.randf_range(6.0, 12.0)
	var r0: float = h * rng.randf_range(0.022, 0.030)
	_taper(st, Vector3.ZERO, Vector3(0, h, 0), r0, r0 * 0.16, 6, _bark(rng))
	var leaf: Color = _leaf(rng) * Color(0.80, 0.92, 0.80)     # 針葉偏深偏藍
	var layers: int = rng.randi_range(4, 6)
	for i in layers:
		var t: float = float(i) / float(layers)
		var y: float = h * (0.26 + 0.68 * t)
		var rad: float = h * lerpf(0.20, 0.055, t) * rng.randf_range(0.9, 1.1)
		var hh: float = h * rng.randf_range(0.13, 0.19)
		# 每層略微偏心：正圓錐疊起來像聖誕樹玩具，偏心才像真的
		var off := Vector3(rng.randf_range(-0.2, 0.2), 0, rng.randf_range(-0.2, 0.2))
		_cone(st, Vector3(0, y, 0) + off, rad, hh, 7, leaf * rng.randf_range(0.88, 1.10), rng)

static func _palm(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	var h: float = rng.randf_range(5.5, 9.5)
	var r0: float = h * rng.randf_range(0.020, 0.028)
	# 彎曲的樹幹：椰子樹一定是彎的，直的一看就是圓柱體
	var lean: float = rng.randf_range(0.10, 0.26) * (1.0 if rng.randf() < 0.5 else -1.0)
	var dir: float = rng.randf() * TAU
	var segs := 6
	var prev := Vector3.ZERO
	var bark: Color = _bark(rng) * Color(1.05, 1.0, 0.9)
	for i in range(1, segs + 1):
		var t: float = float(i) / float(segs)
		var cur := Vector3(cos(dir) * lean * h * t * t, h * t, sin(dir) * lean * h * t * t)
		_taper(st, prev, cur, r0 * (1.0 - 0.45 * (t - 1.0 / segs)), r0 * (1.0 - 0.45 * t),
				6, bark * rng.randf_range(0.92, 1.08))
		prev = cur
	# 葉：向外向下垂的長片，中肋略折
	var leaf: Color = _leaf(rng) * Color(0.95, 1.05, 0.72)
	var nf: int = rng.randi_range(6, 9)
	for i in nf:
		var a: float = TAU * float(i) / float(nf) + rng.randf_range(-0.15, 0.15)
		var L: float = h * rng.randf_range(0.26, 0.36)
		var mid: Vector3 = prev + Vector3(cos(a) * L * 0.55, L * 0.22, sin(a) * L * 0.55)
		var tip: Vector3 = prev + Vector3(cos(a) * L, -L * rng.randf_range(0.18, 0.42), sin(a) * L)
		_frond(st, prev, mid, tip, L * 0.14, leaf * rng.randf_range(0.88, 1.12))
	# 椰子
	if rng.randf() < 0.6:
		for i in rng.randi_range(2, 4):
			var a2: float = rng.randf() * TAU
			_blob(st, prev + Vector3(cos(a2) * r0 * 2.0, -r0 * 1.6, sin(a2) * r0 * 2.0),
					r0 * 0.9, 0.9, Color(0.36, 0.28, 0.16), rng)

static func _shrub(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	var h: float = rng.randf_range(1.1, 2.3)
	var leaf: Color = _leaf(rng) * Color(1.0, 0.96, 0.86)
	# 幾根細枝從根部散出去，葉團掛在枝上——沒有枝的灌木就是地上放了幾顆球
	var stems: int = rng.randi_range(3, 5)
	for i in stems:
		var a: float = TAU * float(i) / float(stems) + rng.randf_range(-0.4, 0.4)
		var lean: float = rng.randf_range(0.18, 0.42)
		var tip := Vector3(cos(a) * h * lean, h * rng.randf_range(0.45, 0.75), sin(a) * h * lean)
		_taper(st, Vector3.ZERO, tip, h * 0.045, h * 0.018, 4, _bark(rng) * 0.9)
		_blob(st, tip, h * rng.randf_range(0.26, 0.40), rng.randf_range(0.66, 0.92),
				leaf * rng.randf_range(0.82, 1.18), rng)
	_blob(st, Vector3(0, h * 0.34, 0), h * rng.randf_range(0.26, 0.36),
			rng.randf_range(0.70, 0.95), leaf * rng.randf_range(0.86, 1.12), rng)

static func _dead(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	var h: float = rng.randf_range(4.0, 7.0)
	var r0: float = h * rng.randf_range(0.028, 0.040)
	var col: Color = Color(0.24, 0.19, 0.15) * rng.randf_range(0.85, 1.15)
	var top := Vector3(rng.randf_range(-0.3, 0.3), h * rng.randf_range(0.6, 0.85),
			rng.randf_range(-0.3, 0.3))
	_taper(st, Vector3.ZERO, top, r0, r0 * 0.3, 6, col)
	for i in rng.randi_range(3, 5):
		var a: float = TAU * rng.randf()
		var t: float = rng.randf_range(0.4, 0.95)
		var base: Vector3 = top * t
		var tip: Vector3 = base + Vector3(cos(a) * h * rng.randf_range(0.14, 0.30),
				h * rng.randf_range(0.10, 0.26), sin(a) * h * rng.randf_range(0.14, 0.30))
		_taper(st, base, tip, r0 * 0.42 * (1.0 - t * 0.5), r0 * 0.10, 4, col)

# ---------- 幾何基本件 ----------

# ---------- 岩石原型（2026-07-29 使用者：「石頭還是太假」）----------
# 舊做法＝共用 SphereMesh 壓扁（平滑法線）＝一窩光滑的蛋。
# 岩石的「真」來自：稜角（大位移＋平面法線）、逐面色差、頂面曬白/底部沾土。
# 跟樹一樣建置期產原型、MultiMesh 鋪場，每顆只是變換與色偏不同。
static func build_rock_protos(variants := 5, seed_v := 20260731) -> Array:
	var out: Array = []
	var rng := RandomNumberGenerator.new()
	for v in variants:
		rng.seed = seed_v + v * 131
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		# ★★2026-07-31 三修（使用者：「這類似的石頭太假了」，沙漠圖實拍像一顆黃糖果）。
		# 前兩版都在球面上加噪聲——不管幅度多大，那是「有疙瘩的球」，不是石頭。
		# 真實岩石的形狀來自**斷裂**：幾個平面把石塊削掉幾角，於是有大片平坦的斷面、
		# 銳利的稜線、以及面與面之間明確的明暗差。這一版改用「切割面」生成：
		#   ① 先做一顆略帶噪聲的橢球 ② 用 5~7 個隨機平面切它（面外的頂點壓回平面上）
		#   ③ 逐面法線（頂點不共用）＋依面朝向烘明暗：朝上曬白、朝下沾土
		var rows := 5
		var cols := 8
		var pts: Array = []
		for iy in range(rows + 1):
			var row: Array = []
			var phi: float = PI * float(iy) / float(rows)
			for ix in cols:
				var th: float = TAU * float(ix) / float(cols)
				var j: float = rng.randf_range(0.90, 1.10)
				row.append(Vector3(sin(phi) * cos(th) * j * rng.randf_range(0.85, 1.15),
						cos(phi) * rng.randf_range(0.55, 0.72) * j,
						sin(phi) * sin(th) * j * rng.randf_range(0.85, 1.15)))
			pts.append(row)
		# 切割面：法線隨機、距原點 0.42~0.78。面外的頂點沿法線壓回平面＝一片平坦斷面
		var planes: Array = []
		# 切多一點、切深一點：5~7 面且距原點 0.42~0.78 只削掉一點皮，
		# 輪廓仍是鵝卵石（實拍）。8~11 面、0.30~0.62 才會出現大片斷面與銳稜。
		for _p in rng.randi_range(8, 11):
			var n := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.6, 1),
					rng.randf_range(-1, 1)).normalized()
			planes.append([n, rng.randf_range(0.30, 0.62)])
		for iy in range(rows + 1):
			for ix in cols:
				var p: Vector3 = pts[iy][ix]
				for pl in planes:
					var nn: Vector3 = pl[0]
					var dd: float = pl[1]
					var over: float = p.dot(nn) - dd
					if over > 0.0:
						p -= nn * over
				pts[iy][ix] = p
		for iy in rows:
			for ix in cols:
				var nx: int = (ix + 1) % cols
				var a: Vector3 = pts[iy][ix]
				var b: Vector3 = pts[iy][nx]
				var c: Vector3 = pts[iy + 1][nx]
				var d: Vector3 = pts[iy + 1][ix]
				# 明暗依**面的實際朝向**烘進頂點色（不是依緯度）：切割後同一緯度的面
				# 朝向可能完全不同，用緯度上色會讓斷面看起來像貼了漸層紙。
				var fn: Vector3 = (b - a).cross(c - a).normalized()
				var up: float = clampf(fn.y, -1.0, 1.0)
				# ⚠ 明暗範圍不能開太大：頂點色會與「貼圖 × 色調」相乘，三重壓下去
				# 石頭變成黑色剪影（2026-07-31 實拍）。0.80~1.18 層次夠、不壓死。
				var sh: float = lerpf(0.80, 1.18, (up + 1.0) * 0.5)
				var fc := Color(sh, sh, sh) * rng.randf_range(0.93, 1.07)
				_quad(st, a, b, c, d, fc)
		st.generate_normals()
		st.generate_tangents()
		out.append(st.commit())
	return out

static func _bark(rng: RandomNumberGenerator) -> Color:
	return Color(0.30, 0.23, 0.16).lerp(Color(0.44, 0.36, 0.26), rng.randf())

static func _leaf(rng: RandomNumberGenerator) -> Color:
	return Color(0.20, 0.36, 0.15).lerp(Color(0.42, 0.56, 0.22), rng.randf())

# 錐台（樹幹／樹枝）：a→b，兩端半徑不同
static func _taper(st: SurfaceTool, a: Vector3, b: Vector3, ra: float, rb: float,
		sides: int, col: Color) -> void:
	var axis: Vector3 = b - a
	if axis.length() < 0.0001:
		return
	var up: Vector3 = axis.normalized()
	var side: Vector3 = up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
	var side2: Vector3 = up.cross(side).normalized()
	for i in sides:
		var t0: float = TAU * float(i) / float(sides)
		var t1: float = TAU * float(i + 1) / float(sides)
		var d0: Vector3 = side * cos(t0) + side2 * sin(t0)
		var d1: Vector3 = side * cos(t1) + side2 * sin(t1)
		_quad(st, a + d0 * ra, a + d1 * ra, b + d1 * rb, b + d0 * rb, col)

# 樹冠團塊：壓扁的多面體。用 8 面而不是 icosphere——低多邊形風格要看得出面
static func _blob(st: SurfaceTool, c: Vector3, r: float, squash: float, col: Color,
		rng: RandomNumberGenerator) -> void:
	# ★2026-07-29 再修（使用者：「樹木還是太假」）。假的三個來源：
	#   ① 頂點抖動 ±14% 太client——遠看仍是圓球。拉到 −22%~+26%，剪影才會碎。
	#   ② 六等分經線太密＝面太小看不出「面」。5 等分，面大才有低多邊形的稜。
	#   ③ 整團同一個綠——真樹冠上面吃光下面背光，臨接的葉簇色也不同。
	#     逐面亂數色差 ±10% ＋ 由上到下 1.14→0.66 的明暗，兩者都烘進頂點色。
	var rows := 3
	var cols := 5
	var pts: Array = []
	for iy in range(rows + 1):
		var row: Array = []
		var phi: float = PI * float(iy) / float(rows)
		for ix in cols:
			var th: float = TAU * (float(ix) + rng.randf_range(-0.18, 0.18)) / float(cols)
			var j: float = rng.randf_range(0.78, 1.26)
			row.append(c + Vector3(sin(phi) * cos(th) * r * j,
					cos(phi) * r * squash * j, sin(phi) * sin(th) * r * j))
		pts.append(row)
	for iy in rows:
		var sh: float = lerpf(1.14, 0.66, (float(iy) + 0.5) / float(rows))
		for ix in cols:
			var nx: int = (ix + 1) % cols
			_quad(st, pts[iy][ix], pts[iy][nx], pts[iy + 1][nx], pts[iy + 1][ix],
					col * sh * rng.randf_range(0.90, 1.10))

static func _cone(st: SurfaceTool, c: Vector3, r: float, h: float, sides: int, col: Color,
		rng: RandomNumberGenerator = null) -> void:
	var apex: Vector3 = c + Vector3(0, h, 0)
	# 針葉層的緣要參差＋逐面色差：正圓錐一圈同色＝塑膠聖誕樹（使用者再次點名太假）
	var jr: Array = []
	for i in range(sides + 1):
		jr.append(1.0 if rng == null else rng.randf_range(0.80, 1.18))
	jr[sides] = jr[0]
	for i in sides:
		var t0: float = TAU * float(i) / float(sides)
		var t1: float = TAU * float(i + 1) / float(sides)
		var p0: Vector3 = c + Vector3(cos(t0) * r * jr[i], 0, sin(t0) * r * jr[i])
		var p1: Vector3 = c + Vector3(cos(t1) * r * jr[i + 1], 0, sin(t1) * r * jr[i + 1])
		var fc: Color = col if rng == null else col * rng.randf_range(0.90, 1.10)
		_tri(st, p0, p1, apex, fc)
		_tri(st, p1, p0, c, fc * 0.72)    # 底面：從下方看不會破洞；針葉層底面背光要暗

static func _frond(st: SurfaceTool, a: Vector3, mid: Vector3, tip: Vector3, w: float,
		col: Color) -> void:
	var d: Vector3 = (tip - a)
	d.y = 0.0
	if d.length() < 0.0001:
		d = Vector3.RIGHT
	var side: Vector3 = d.normalized().cross(Vector3.UP) * w
	# 兩段（根部→中→尖），中肋折一下，葉子才有弧度
	_quad(st, a, a + side * 0.35, mid + side, mid, col)
	_quad(st, a, mid, mid - side, a - side * 0.35, col)
	_quad(st, mid, mid + side, tip, tip, col * 0.94)
	_quad(st, mid, tip, tip, mid - side, col * 0.94)

static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		col: Color) -> void:
	_tri(st, a, b, c, col)
	_tri(st, a, c, d, col)

static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	st.set_color(col)
	st.add_vertex(a)
	st.set_color(col)
	st.add_vertex(b)
	st.set_color(col)
	st.add_vertex(c)
