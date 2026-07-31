# Gear.gd — 角色裝具程序化網格（GDD/06 外觀 v2）。
# 頭具/背具都是低多邊形小件：跟樹/岩石同一套哲學——碎面＋逐面色差烘頂點色。
# 回傳 MeshInstance3D（頂點色材質），由 Unit._attach_gear 掛上骨骼。
class_name CharGear

static func build(item: String, main_c: Color, acc_c: Color) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	match item:
		"helmet": _helmet(st, main_c, false)
		"helmet_net": _helmet(st, main_c, true)
		"beret": _beret(st, main_c)
		"cap": _cap(st, main_c, acc_c)
		"boonie": _boonie(st, main_c)
		"hood": _hood(st, main_c)
		"balaclava": _balaclava(st, main_c)
		"goggles": _goggles(st, main_c, acc_c)
		"slim": _slim(st, main_c, acc_c)
		"ruck": _ruck(st, main_c, acc_c)
		"radio": _radio(st, main_c, acc_c)
		"tube": _tube(st, main_c, acc_c)
		"ammo": _ammo(st, main_c, acc_c)
		"armband": _armband(st)
		_:
			return null
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "Gear_" + item
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.92
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED   # 手繞面不保證朝外，裝具小件雙面保險
	mi.material_override = mat
	return mi

# ---------- 頭具（原點＝頭骨；+Y 上、+Z 臉的朝向） ----------

# 圓盔：壓扁半球殼＋一圈沿。net=true 加偽裝網塊
static func _helmet(st: SurfaceTool, c: Color, net: bool) -> void:
	_dome(st, Vector3(0, 0.055, 0), 0.135, 0.72, c)
	_ring(st, Vector3(0, 0.028, 0), 0.142, 0.030, c * 0.82)
	if net:
		var rng := RandomNumberGenerator.new()
		rng.seed = 77
		for i in 7:
			var a: float = TAU * float(i) / 7.0 + rng.randf_range(-0.3, 0.3)
			_boxc(st, Vector3(cos(a) * 0.11, 0.09 + rng.randf_range(-0.02, 0.03), sin(a) * 0.11),
					Vector3(0.05, 0.02, 0.05), c * rng.randf_range(0.55, 0.8))

# 貝雷帽：壓得很扁的圓盤、往右歪
static func _beret(st: SurfaceTool, c: Color) -> void:
	_dome(st, Vector3(0.03, 0.075, 0), 0.125, 0.38, c)
	_ring(st, Vector3(0.012, 0.055, 0), 0.118, 0.022, c * 0.8)

# 帽簷帽（巡邏帽）：淺圓頂＋前簷
static func _cap(st: SurfaceTool, c: Color, acc: Color) -> void:
	_dome(st, Vector3(0, 0.06, 0), 0.118, 0.52, c)
	_boxc(st, Vector3(0, 0.045, 0.14), Vector3(0.15, 0.018, 0.11), c * 0.9)
	_boxc(st, Vector3(0, 0.075, 0.0), Vector3(0.06, 0.03, 0.002), acc)   # 正面小徽

# 闊邊帽（狙擊/叢林）：圓頂＋一整圈大簷
static func _boonie(st: SurfaceTool, c: Color) -> void:
	_dome(st, Vector3(0, 0.065, 0), 0.112, 0.55, c)
	_ring(st, Vector3(0, 0.045, 0), 0.185, 0.012, c * 0.88)

# 連帽：後腦一片罩＋肩後垂布
static func _hood(st: SurfaceTool, c: Color) -> void:
	_dome(st, Vector3(0, 0.05, -0.02), 0.145, 0.8, c)
	_boxc(st, Vector3(0, -0.10, -0.12), Vector3(0.20, 0.14, 0.04), c * 0.9)

# 頭套：整顆頭深色薄殼（露臉開口朝 +Z 由 dome 偏後蓋出）
static func _balaclava(st: SurfaceTool, c: Color) -> void:
	_dome(st, Vector3(0, 0.03, -0.012), 0.132, 0.95, c * 0.6)

# 護目鏡帽：淺盔＋額前橫帶與兩鏡片
static func _goggles(st: SurfaceTool, c: Color, acc: Color) -> void:
	_dome(st, Vector3(0, 0.055, 0), 0.125, 0.6, c)
	_boxc(st, Vector3(0, 0.055, 0.115), Vector3(0.22, 0.045, 0.03), Color(0.16, 0.16, 0.17))
	for sx in [-0.055, 0.055]:
		_boxc(st, Vector3(sx, 0.055, 0.132), Vector3(0.07, 0.035, 0.012), acc * 1.2)

# ---------- 背具（原點＝胸椎骨後方；+Z 朝角色背後） ----------

static func _slim(st: SurfaceTool, c: Color, acc: Color) -> void:
	_boxc(st, Vector3(0, -0.02, 0.10), Vector3(0.22, 0.26, 0.09), c)
	_boxc(st, Vector3(0, -0.10, 0.15), Vector3(0.14, 0.09, 0.03), acc * 0.9)

static func _ruck(st: SurfaceTool, c: Color, acc: Color) -> void:
	_boxc(st, Vector3(0, -0.04, 0.13), Vector3(0.30, 0.38, 0.18), c)
	_boxc(st, Vector3(0, 0.14, 0.12), Vector3(0.26, 0.10, 0.16), c * 0.86)   # 上蓋
	for sx in [-0.09, 0.09]:
		_boxc(st, Vector3(sx, -0.05, 0.225), Vector3(0.05, 0.24, 0.02), acc * 0.85)

static func _radio(st: SurfaceTool, c: Color, acc: Color) -> void:
	_boxc(st, Vector3(0, -0.02, 0.12), Vector3(0.24, 0.30, 0.13), c * 0.7)
	_boxc(st, Vector3(-0.08, 0.10, 0.12), Vector3(0.02, 0.36, 0.02), Color(0.15, 0.15, 0.15))  # 天線
	_boxc(st, Vector3(0.05, 0.02, 0.19), Vector3(0.08, 0.05, 0.01), acc)

static func _tube(st: SurfaceTool, c: Color, acc: Color) -> void:
	# 斜背的筒（火箭/迫砲管）：圓柱用八角柱近似，斜 35°
	var b := Basis(Vector3(0, 0, 1), 0.61)
	_oct(st, b, Vector3(0.02, 0.0, 0.13), 0.05, 0.62, c * 0.75)
	_boxc(st, Vector3(0, -0.06, 0.10), Vector3(0.2, 0.22, 0.07), c)
	_boxc(st, Vector3(0.02, 0.0, 0.13) + b * Vector3(0, 0.32, 0), Vector3(0.075, 0.02, 0.075), acc * 0.8)

static func _ammo(st: SurfaceTool, c: Color, acc: Color) -> void:
	_boxc(st, Vector3(0, -0.03, 0.11), Vector3(0.26, 0.20, 0.12), c * 0.8)
	_boxc(st, Vector3(0, 0.075, 0.11), Vector3(0.27, 0.02, 0.13), acc * 0.7)   # 蓋縫
	_boxc(st, Vector3(0, -0.14, 0.11), Vector3(0.18, 0.02, 0.10), c * 0.6)

# 紅臂章（敵軍識別）：上臂一圈鮮紅布帶——可讀性靠它＋腳下紅環，不動制服本體
static func _armband(st: SurfaceTool) -> void:
	_ring(st, Vector3(0, -0.02, 0), 0.062, 0.055, Color(0.82, 0.12, 0.10))

# ---------- 幾何小件 ----------

static func _dome(st: SurfaceTool, c: Vector3, r: float, squash: float, col: Color) -> void:
	var rows := 2
	var cols := 7
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var pts: Array = []
	for iy in range(rows + 1):
		var row: Array = []
		var phi: float = PI * 0.5 * float(iy) / float(rows)      # 只做上半球
		for ix in cols:
			var th: float = TAU * float(ix) / float(cols)
			row.append(c + Vector3(sin(phi) * cos(th) * r,
					cos(phi) * r * squash, sin(phi) * sin(th) * r))
		pts.append(row)
	for iy in rows:
		for ix in cols:
			var nx: int = (ix + 1) % cols
			_q(st, pts[iy + 1][ix], pts[iy + 1][nx], pts[iy][nx], pts[iy][ix],
					col * rng.randf_range(0.94, 1.06))

static func _ring(st: SurfaceTool, c: Vector3, r: float, h: float, col: Color) -> void:
	var cols := 8
	for ix in cols:
		var t0: float = TAU * float(ix) / float(cols)
		var t1: float = TAU * float(ix + 1) / float(cols)
		var p0 := c + Vector3(cos(t0) * r, 0, sin(t0) * r)
		var p1 := c + Vector3(cos(t1) * r, 0, sin(t1) * r)
		_q(st, p0, p1, p1 + Vector3(0, h, 0), p0 + Vector3(0, h, 0), col)

static func _oct(st: SurfaceTool, b: Basis, c: Vector3, r: float, l: float, col: Color) -> void:
	var cols := 8
	for ix in cols:
		var t0: float = TAU * float(ix) / float(cols)
		var t1: float = TAU * float(ix + 1) / float(cols)
		var d0 := b * Vector3(cos(t0) * r, 0, sin(t0) * r)
		var d1 := b * Vector3(cos(t1) * r, 0, sin(t1) * r)
		var up := b * Vector3(0, l, 0)
		_q(st, c + d0 - up * 0.5, c + d1 - up * 0.5, c + d1 + up * 0.5, c + d0 + up * 0.5, col)

static func _boxc(st: SurfaceTool, c: Vector3, size: Vector3, col: Color) -> void:
	var h := size * 0.5
	var v := [Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z),
			Vector3(-h.x, h.y, -h.z), Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z),
			Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z)]
	for f in [[0, 1, 2, 3], [5, 4, 7, 6], [4, 0, 3, 7], [1, 5, 6, 2], [3, 2, 6, 7], [4, 5, 1, 0]]:
		_q(st, c + v[f[0]], c + v[f[1]], c + v[f[2]], c + v[f[3]], col)

static func _q(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	for p in [a, b, c, a, c, d]:
		st.set_color(col)
		st.add_vertex(p)
