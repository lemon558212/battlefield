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
	"coast":  {"palm": 0.30, "pine": 0.26, "broadleaf": 0.20, "shrub": 0.20, "dead": 0.04},
	"forest": {"pine": 0.40, "broadleaf": 0.42, "shrub": 0.15, "dead": 0.03},
	"grass":  {"broadleaf": 0.46, "pine": 0.20, "shrub": 0.28, "dead": 0.06},
	"urban":  {"broadleaf": 0.55, "shrub": 0.35, "dead": 0.10},
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
	var h: float = rng.randf_range(4.6, 8.2)
	var r0: float = h * rng.randf_range(0.030, 0.042)
	_taper(st, Vector3.ZERO, Vector3(rng.randf_range(-0.25, 0.25), h * 0.52,
			rng.randf_range(-0.25, 0.25)), r0, r0 * 0.55, 6, _bark(rng))
	# 主枝：兩三根伸出去，樹冠才不是「插在棍子上的一顆球」
	var top := Vector3(0, h * 0.52, 0)
	var n: int = rng.randi_range(2, 3)
	var leaf: Color = _leaf(rng)
	for i in n:
		var a: float = TAU * (float(i) + rng.randf_range(-0.2, 0.2)) / float(n)
		var reach: float = h * rng.randf_range(0.16, 0.26)
		var tip: Vector3 = top + Vector3(cos(a) * reach, h * rng.randf_range(0.10, 0.18),
				sin(a) * reach)
		_taper(st, top, tip, r0 * 0.5, r0 * 0.22, 5, _bark(rng))
		_blob(st, tip + Vector3(0, h * 0.06, 0), h * rng.randf_range(0.15, 0.21),
				rng.randf_range(0.62, 0.80), leaf * rng.randf_range(0.86, 1.14), rng)
	_blob(st, top + Vector3(0, h * 0.16, 0), h * rng.randf_range(0.19, 0.24),
			rng.randf_range(0.66, 0.82), leaf, rng)

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
		_cone(st, Vector3(0, y, 0) + off, rad, hh, 7, leaf * rng.randf_range(0.88, 1.10))

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
	var h: float = rng.randf_range(1.2, 2.2)
	var leaf: Color = _leaf(rng) * Color(1.0, 0.96, 0.86)
	for i in rng.randi_range(3, 5):
		var a: float = TAU * rng.randf()
		var d: float = h * rng.randf_range(0.0, 0.42)
		_blob(st, Vector3(cos(a) * d, h * rng.randf_range(0.32, 0.62), sin(a) * d),
				h * rng.randf_range(0.30, 0.46), rng.randf_range(0.70, 0.95),
				leaf * rng.randf_range(0.84, 1.16), rng)

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
	var rows := 3
	var cols := 6
	var pts: Array = []
	for iy in range(rows + 1):
		var row: Array = []
		var phi: float = PI * float(iy) / float(rows)
		for ix in cols:
			var th: float = TAU * float(ix) / float(cols)
			# 每個頂點加一點亂數＝團塊不規則，不是一顆完美的球
			var j: float = rng.randf_range(0.86, 1.14)
			row.append(c + Vector3(sin(phi) * cos(th) * r * j,
					cos(phi) * r * squash * j, sin(phi) * sin(th) * r * j))
		pts.append(row)
	for iy in rows:
		for ix in cols:
			var nx: int = (ix + 1) % cols
			_quad(st, pts[iy][ix], pts[iy][nx], pts[iy + 1][nx], pts[iy + 1][ix], col)

static func _cone(st: SurfaceTool, c: Vector3, r: float, h: float, sides: int, col: Color) -> void:
	var apex: Vector3 = c + Vector3(0, h, 0)
	for i in sides:
		var t0: float = TAU * float(i) / float(sides)
		var t1: float = TAU * float(i + 1) / float(sides)
		var p0: Vector3 = c + Vector3(cos(t0) * r, 0, sin(t0) * r)
		var p1: Vector3 = c + Vector3(cos(t1) * r, 0, sin(t1) * r)
		_tri(st, p0, p1, apex, col)
		_tri(st, p1, p0, c, col)          # 底面：從下方看不會破洞

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
