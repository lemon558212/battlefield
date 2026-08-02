# Fortify.gd — 野戰工事（沙包牆、壕溝護壁、鐵絲網）。
#
# 為什麼要獨立一支：使用者 2026-07-26 指正「場景還沒有真實感」。低多邊形要有 3A 場景感，
# 靠的不是多邊形數，而是這四件事——本檔就是照著做：
#   1. 細節層次：大形（牆體）＋中形（每個袋子）＋小件（掉落的袋、泥土堆）
#   2. 使用痕跡：沙包不會排整齊，會歪、會鬆、會有幾個掉下來
#   3. 材質變化：每袋顏色不同，底部較暗（沾泥），不是一片純色
#   4. 與地面的過渡：底部堆一圈泥土，物件才不是「硬插進地面」
#
# ⚠ 幾何一律合併（同 Building/Props 的教訓）：先前一個沙包堆＝10 個 MeshInstance3D，
#   一張圖五堆就是 50 次 draw call。
class_name Fortify
extends Node3D

var _ws := 0.05
var _mw := 960.0
var _mh := 600.0
var _terrain = null
var _st: SurfaceTool = null
var blockers: Array = []          # 同 Props.blockers 的格式，交給 Main 一起吃
# 邊界安全帶（px）。由 Main 傳入 EDGE_SAFE_M 換算，0＝不限制。
# 為什麼工事也要管：Main._strip_edge_blockers 會把邊界帶內的障礙從碰撞表剔掉
# （防人被夾在地圖邊緣），但**視覺是這裡畫的、不會一起消失** → 沙包看得到穿得過
# （使用者 2026-08-02 回報「還是會穿過柵欄」，實測連沙包也是）。
# 沙包牆本身多半在帶外，但散落沙包是牆位置**加隨機偏移**，偏出去就進帶內了。
var _edge_pad := 0.0
func _in_edge_band(p: Vector2) -> bool:
	if _edge_pad <= 0.0:
		return false
	return p.x < _edge_pad or p.y < _edge_pad \
			or p.x > _mw - _edge_pad or p.y > _mh - _edge_pad
# 可摧毀的工事段（GDD/15 G1）。⚠ 為了 draw call，全部工事本來合併成一個網格，
#   於是「炸掉其中一段沙包」在技術上做不到（不能隱藏合併網格的一部分）。
#   折衷：**沙包牆每一道自己一個網格**（一張圖十幾道，多十幾個 draw call，
#   實測 <0.4ms），其餘工事照舊合併。這樣才有東西可以炸。
#   每筆 {node: MeshInstance3D, c: Vector2(px), r: 半徑(px), blk: 對應的障礙}
var destructibles: Array = []
var _wall_st: SurfaceTool = null      # 目前這道沙包牆專用（不為 null 時 _tri_raw 寫這裡）

func begin(map_w: float, map_h: float, world_scale: float, terrain, edge_safe_m := 0.0) -> void:
	_mw = map_w
	_mh = map_h
	_ws = world_scale
	_terrain = terrain
	_edge_pad = (edge_safe_m + 0.6) / world_scale if edge_safe_m > 0.0 else 0.0
	blockers.clear()
	_st = SurfaceTool.new()
	_st.begin(Mesh.PRIMITIVE_TRIANGLES)

func finish() -> void:
	if _st == null:
		return
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.97
	mat.metallic_specular = 0.02   # Godot 4 的名字；寫 specular 會刷 SpatialMaterial 警告
	_st.set_material(mat)
	var mi := MeshInstance3D.new()
	mi.name = "Fortify"
	mi.mesh = _st.commit()
	add_child(mi)
	_st = null

# ---------- 沙包牆 ----------
# 真實沙包牆是「梯形剖面」：底寬頂窄，每層交錯半個袋子（磚砌法），否則會垮。
# 先前是兩排方盒疊起來，看起來像積木。
func sandbag_wall(cx: float, cy: float, w_px: float, h_px: float) -> void:
	# 這一道自己一個 SurfaceTool，才能單獨被炸掉
	_wall_st = SurfaceTool.new()
	_wall_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(absf(cx) * 13.0 + absf(cy) * 7.0) + 5
	var long_x: bool = w_px >= h_px
	var length_m: float = maxf(w_px, h_px) * _ws
	var ang: float = 0.0 if long_x else PI * 0.5
	var dir := Vector2(cos(ang), sin(ang))
	var bag_l := 0.52
	var bag_w := 0.34
	var bag_h := 0.22
	var rows := 6      # 蹲在後面要遮得住上半身：4 層只有 0.8m，蹲下也露肩
	var base_n: int = maxi(4, int(length_m / bag_l) + 2)
	for row in rows:
		# 上層內縮＝梯形剖面（每層少一個袋、往中間靠）
		var n: int = maxi(3, base_n - int(float(row) * 0.6))
		var y: float = float(row) * bag_h * 0.92 + bag_h * 0.5
		var depth_off: float = 0.0
		for i in n:
			var t: float = (float(i) - float(n - 1) * 0.5) * bag_l * 1.02
			# 交錯：奇數層平移半個袋
			if row % 2 == 1:
				t += bag_l * 0.5
			var jitter := Vector3(rng.randf_range(-0.02, 0.02), rng.randf_range(-0.015, 0.015),
					rng.randf_range(-0.03, 0.03))
			var pos := Vector3(dir.x * t, y, dir.y * t) + jitter
			pos.z += depth_off
			var yaw: float = ang + rng.randf_range(-0.14, 0.14)
			var tilt: float = rng.randf_range(-0.10, 0.10)
			_bag(Vector2(cx, cy), pos, Vector3(bag_l, bag_h, bag_w), yaw, tilt, rng)
	# 幾個掉在地上的袋子：整齊排列看起來像新品，戰場上的工事不會是新的
	# ⚠ 這幾個袋子先前是純視覺，沒有進碰撞表——使用者 2026-07-27 截圖裡「腿插進沙包」
	#   就是踩到它們。畫得出來的東西一定要有碰撞（鐵律 0①）。
	#   它們只有 0.22m 高，現實裡是**踩上去**不是繞過去，所以登記成矮障礙
	#   （h ≤ 0.5m），由 Main._ground_height 給頂面支撐、_resolve_solids 不水平推。
	for k in 3:
		var off := Vector3(dir.x * rng.randf_range(-length_m * 0.6, length_m * 0.6)
				+ rng.randf_range(-0.5, 0.5), bag_h * 0.45,
				dir.y * rng.randf_range(-length_m * 0.6, length_m * 0.6)
				+ rng.randf_range(0.5, 1.1))
		# ⚠ 落在邊界安全帶內就整顆不畫（連視覺一起跳過）：畫了而碰撞被剔除
		#   ＝看得到穿得過。視覺與碰撞必須同一個判斷、同一個 if。
		var loose_c: Vector2 = Vector2(cx, cy) + Vector2(off.x, off.z) / _ws
		if _in_edge_band(loose_c):
			continue
		_bag(Vector2(cx, cy), off, Vector3(bag_l, bag_h, bag_w),
				rng.randf() * TAU, rng.randf_range(-0.5, 0.5), rng)
		blockers.append({"t": "cir", "c": loose_c,
				"r": bag_l * 0.5 / _ws, "h": bag_h, "k": "sandbag_loose"})
	# 實體：沙包牆是一道牆，人不可能從中間穿過去（使用者 2026-07-26 指正
	# 「任何的物體都是不能穿越的」）。用線段涵蓋整道牆。
	var half_len: float = length_m * 0.5 / _ws
	var dpx := Vector2(dir.x, dir.y) * half_len
	# h＝實際堆到的高度（六層 × 0.22 × 0.92 + 半個袋）：彈道要靠它判斷
	# 「蹲在沙包後＝擋住、站起來＝上半身露出」，見 Props._blk_seg 的說明。
	# ⚠ 沙包牆的位置是 maps.json 指定的（設計者放的工事），不像散落沙包可以直接
	#   跳過——整道牆消失等於設計者的掩體被吃掉。所以這裡**不自己處理**，
	#   而是要求改資料，作法同「劇情建築壓在部署區」那條。
	#   放著不管的後果：碰撞被 Main._strip_edge_blockers 剔除、沙包牆照畫，
	#   玩家直接走過去（使用者 2026-08-02 回報的同一類現象）。
	if _in_edge_band(Vector2(cx, cy) - dpx) or _in_edge_band(Vector2(cx, cy) + dpx):
		push_error("[fort] 沙包牆貼在地圖邊界安全帶內（碰撞會被剔除、視覺卻留著＝穿得過）："
				+ "中心(%.0f,%.0f)　請改 maps.json 的 sandbags 讓它離邊界遠一點" % [cx, cy])
	blockers.append({"t": "seg", "a": Vector2(cx, cy) - dpx, "b": Vector2(cx, cy) + dpx,
			"r": 0.30 / _ws, "h": float(rows) * bag_h * 0.92 + bag_h * 0.5, "k": "sandbag",
			"m": Vector2(cx, cy), "hl": half_len})
	var wall_blk = blockers[blockers.size() - 1]
	# 底部泥土堆：物件與地面的過渡，沒有這層就是「硬插進地面」
	for k2 in 10:
		var t2: float = rng.randf_range(-length_m * 0.55, length_m * 0.55)
		var side: float = rng.randf_range(-0.45, 0.45)
		var sz: float = rng.randf_range(0.22, 0.5)
		var p2 := Vector3(dir.x * t2 + dir.y * side, sz * 0.16, dir.y * t2 - dir.x * side)
		_mound(Vector2(cx, cy), p2, sz, rng)
	# 這一道結束：commit 成自己的網格，登記進可摧毀清單
	var wmat := StandardMaterial3D.new()
	wmat.vertex_color_use_as_albedo = true
	wmat.roughness = 0.97
	wmat.metallic_specular = 0.02
	_wall_st.set_material(wmat)
	var wmi := MeshInstance3D.new()
	wmi.name = "SandbagWall"
	wmi.mesh = _wall_st.commit()
	add_child(wmi)
	destructibles.append({"node": wmi, "c": Vector2(cx, cy),
			"r": maxf(length_m * 0.5 / _ws, 20.0), "blk": wall_blk})
	_wall_st = null

# 一個沙包：12 個頂點（底/腰/頂三圈），腰部外鼓、頂部內縮＝鬆軟的袋子。
# 方盒做不出「裝了沙而鼓起來」的感覺，那是它看起來像積木的主因。
func _bag(anchor: Vector2, local: Vector3, size: Vector3, yaw: float, tilt: float,
		rng: RandomNumberGenerator) -> void:
	var b := Basis(Vector3.UP, yaw) * Basis(Vector3(1, 0, 0), tilt)
	var hx: float = size.x * 0.5
	var hy: float = size.y * 0.5
	var hz: float = size.z * 0.5
	# 每袋顏色不同：沙色↔土色，底部再壓暗（沾泥）
	var tone: float = rng.randf()
	var top_c: Color = Color(0.56, 0.49, 0.32).lerp(Color(0.46, 0.39, 0.26), tone)
	var bot_c: Color = top_c.darkened(0.42)
	var rings := [
		[-hy, 0.86, bot_c],          # 底：略收
		[0.0, 1.0, top_c.darkened(0.12)],   # 腰：最寬
		[hy, 0.72, top_c],           # 頂：內縮
	]
	var pts: Array = []
	for r in rings:
		var y: float = float(r[0])
		var k: float = float(r[1])
		var c: Color = r[2]
		var quad: Array = []
		for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			var p := Vector3(corner.x * hx * k + rng.randf_range(-0.012, 0.012), y,
					corner.y * hz * k + rng.randf_range(-0.012, 0.012))
			quad.append(b * p + local)
		pts.append([quad, c])
	# 側面兩圈
	for ri in 2:
		var lo: Array = pts[ri]
		var hi: Array = pts[ri + 1]
		for i in 4:
			var j: int = (i + 1) % 4
			_quad(anchor, lo[0][i], lo[0][j], hi[0][j], hi[0][i], lo[1], hi[1], false, local)
	# 頂與底
	var topq: Array = pts[2]
	_quad(anchor, topq[0][0], topq[0][1], topq[0][2], topq[0][3], topq[1], topq[1], false, local)
	var botq: Array = pts[0]
	_quad(anchor, botq[0][3], botq[0][2], botq[0][1], botq[0][0], botq[1], botq[1], false, local)

# 一小堆泥土（四角錐）：用來把物件的底邊「埋」進地面
func _mound(anchor: Vector2, local: Vector3, sz: float, rng: RandomNumberGenerator) -> void:
	var c := Color(0.30, 0.24, 0.17).lerp(Color(0.22, 0.19, 0.14), rng.randf())
	var h: float = sz * rng.randf_range(0.28, 0.5)
	var apex: Vector3 = local + Vector3(rng.randf_range(-0.05, 0.05), h,
			rng.randf_range(-0.05, 0.05))
	var corners: Array = []
	for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		corners.append(local + Vector3(corner.x * sz * 0.5, -h * 0.5, corner.y * sz * 0.5))
	for i in 4:
		var j: int = (i + 1) % 4
		_tri(anchor, corners[i], corners[j], apex, c.darkened(0.25), c.darkened(0.25), c, local)

# ---------- 壕溝護壁 ----------
# 光是地形凹下去不像壕溝——真實壕溝有木板護壁、支撐柱與溝緣土堤，
# 沒有這些看起來就是一條「地面上的溝」而不是「人挖出來的工事」。
func trench_revet(pts: Array, half_w_px: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 913
	for i in range(pts.size() - 1):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var total: float = a.distance_to(b)
		var dir: Vector2 = (b - a) / maxf(total, 0.001)
		var nrm := Vector2(-dir.y, dir.x)
		var step: float = 0.30 / _ws   # 木板要緊鄰，留縫就變成柵欄不是護壁
		var d := 0.0
		while d < total:
			var base: Vector2 = a + dir * d
			# ⚠ 護壁是「貼在溝壁上的擋土板」，不是「立在地面上的圍牆」。
			#   第一版把木板建在溝緣往上長，實拍是三公尺高的黑牆把視線全擋住。
			#   正確做法：從溝底長到溝緣，高度＝溝深。
			var y_bottom: float = _terrain.height_at(base.x, base.y) if _terrain != null else 0.0
			for side in [-1.0, 1.0]:
				# ⚠ 取樣點與擺放點要分開：木板要貼在斜壁上（往內 0.85），
				#   但深度必須用「溝緣」的高度來量——用內側點量會量到接近溝底，
				#   depth 算成 0、護壁只剩地面一圈小板子（實拍到）。
				var p_edge: Vector2 = base + nrm * half_w_px * side
				var p: Vector2 = base + nrm * half_w_px * 0.85 * side
				var y_edge: float = _terrain.height_at(p_edge.x, p_edge.y) if _terrain != null else 0.0
				var depth: float = maxf(y_edge - y_bottom, 0.35)
				# 高低不齊：整齊的護壁像圍籬不像工事，頂端要參差
				var ph: float = depth * rng.randf_range(0.88, 1.06)
				var yaw: float = atan2(dir.y, dir.x) + rng.randf_range(-0.05, 0.05)
				var c := Color(0.60, 0.44, 0.27).lerp(Color(0.48, 0.35, 0.21), rng.randf())
				_plank(p, y_bottom + ph * 0.5, Vector3(0.30, ph, 0.06), yaw,
						rng.randf_range(-0.05, 0.05), c)
				# 支撐柱：只高出溝緣一點點（露出來才看得到是有人加固過的）
				if int(d / step) % 4 == 0:
					_plank(p, y_bottom + (depth + 0.18) * 0.5,
							Vector3(0.10, depth + 0.18, 0.10), yaw, 0.0, c.darkened(0.25))
			d += step

func _plank(px: Vector2, world_y: float, size: Vector3, yaw: float, tilt: float,
		c: Color) -> void:
	var b := Basis(Vector3.UP, -yaw) * Basis(Vector3(1, 0, 0), tilt)
	var hx: float = size.x * 0.5
	var hy: float = size.y * 0.5
	var hz: float = size.z * 0.5
	var origin := Vector3((px.x - _mw * 0.5) * _ws, world_y, (px.y - _mh * 0.5) * _ws)
	var v := []
	for corner in [Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(1, 1, -1), Vector3(-1, 1, -1),
			Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(1, 1, 1), Vector3(-1, 1, 1)]:
		v.append(origin + b * Vector3(corner.x * hx, corner.y * hy, corner.z * hz))
	var top := c
	var bot := c.darkened(0.45)
	for f in [[0, 1, 2, 3], [5, 4, 7, 6], [4, 0, 3, 7], [1, 5, 6, 2], [3, 2, 6, 7], [4, 5, 1, 0]]:
		_quad(Vector2.ZERO, v[f[0]], v[f[1]], v[f[2]], v[f[3]], bot, top, true)

# ---------- 幾何工具 ----------
func _anchor_world(a: Vector2) -> Vector3:
	var y := 0.0
	if _terrain != null:
		y = _terrain.height_at(a.x, a.y)
	return Vector3((a.x - _mw * 0.5) * _ws, y, (a.y - _mh * 0.5) * _ws)

func _quad(anchor: Vector2, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
		c_lo: Color, c_hi: Color, absolute := false, out_from = null) -> void:
	var o: Vector3 = Vector3.ZERO if absolute else _anchor_world(anchor)
	var pivot = null
	if out_from != null:
		pivot = o + (out_from as Vector3)
	_tri_raw(o + p0, o + p1, o + p2, c_lo, c_lo, c_hi, pivot)
	_tri_raw(o + p0, o + p2, o + p3, c_lo, c_hi, c_hi, pivot)

func _tri(anchor: Vector2, p0: Vector3, p1: Vector3, p2: Vector3,
		c0: Color, c1: Color, c2: Color, out_from = null) -> void:
	var o: Vector3 = _anchor_world(anchor)
	var pivot = null
	if out_from != null:
		pivot = o + (out_from as Vector3)
	_tri_raw(o + p0, o + p1, o + p2, c0, c1, c2, pivot)

# ⚠ 合併網格不可用 generate_normals()（會把相鄰面的頂點平均，出現漸層條紋像半透明），
#   法線逐面自己給。頂點色一律 srgb_to_linear——不轉會整片偏亮（GDD/10 sRGB 洗白）。
# ⚠ 繞序：手算凸形物體每個面的繞序太容易錯，錯了就是「法線朝內＝整片全黑」
#   （沙包第一版實拍就是一片黑板子，GDD/10 那條事故的老症頭）。
#   給一個「物體中心」，法線一律翻成朝外，就不必再靠手算。
func _tri_raw(a: Vector3, b: Vector3, c: Vector3, ca: Color, cb: Color, cc: Color,
		out_from = null) -> void:
	var v1: Vector3 = b
	var v2: Vector3 = c
	var k1: Color = cb
	var k2: Color = cc
	var n: Vector3 = (v1 - a).cross(v2 - a).normalized()
	if out_from != null:
		var mid: Vector3 = (a + v1 + v2) / 3.0
		if n.dot(mid - (out_from as Vector3)) < 0.0:
			var tmp: Vector3 = v1
			v1 = v2
			v2 = tmp
			var tk: Color = k1
			k1 = k2
			k2 = tk
			n = -n
	var tgt: SurfaceTool = _wall_st if _wall_st != null else _st
	for item in [[a, ca], [v1, k1], [v2, k2]]:
		tgt.set_normal(n)
		tgt.set_color((item[1] as Color).srgb_to_linear())
		tgt.add_vertex(item[0])
