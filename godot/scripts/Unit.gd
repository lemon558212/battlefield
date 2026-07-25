# Unit.gd — 戰場單位＝3D 動畫身體（GDD/13，2026-07-22 使用者拍板：戰場改 3D 模型、立繪只留 UI）。
# 這是 VC 本尊做法：立繪管 identity（選單/對話/角色卡），戰場上是能走/蹲/進掩體的 3D 模型（治「用飄的」）。
# 動作合理化由 AnimationPlayer 原生保證：走路必踏步、開火先舉槍轉身面向目標、受擊/陣亡有動作。
# 地基取自 git b93c0cb 的舊 Unit.gd。
class_name Unit
extends Node3D

signal shot_fired(from_pos: Vector3, to_pos: Vector3)

# 賽璐璐描邊（往鳴潮卡通渲染靠）：背面沿法線外擴、只塗深色，形成輪廓線。
const OUTLINE_SHADER := """
shader_type spatial;
render_mode cull_front, unshaded, shadows_disabled;
uniform float width = 0.014;
uniform vec4 line_color : source_color = vec4(0.06, 0.06, 0.08, 1.0);
void vertex() { VERTEX += NORMAL * width; }
void fragment() { ALBEDO = line_color.rgb; }
"""
static var _outline_mat: ShaderMaterial

static func _get_outline() -> ShaderMaterial:
	if _outline_mat == null:
		var sh := Shader.new()
		sh.code = OUTLINE_SHADER
		_outline_mat = ShaderMaterial.new()
		_outline_mat.shader = sh
	return _outline_mat

# 給模型所有 StandardMaterial3D 加描邊 next_pass + 卡通化(降高光/加邊緣光感)
static func _cel_shade(model: Node) -> void:
	for m in model.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var cnt: int = maxi(mi.get_surface_override_material_count(), 1)
		for si in cnt:
			var base := mi.get_active_material(si)
			if base is StandardMaterial3D:
				var d := (base as StandardMaterial3D).duplicate()
				d.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
				d.roughness = maxf(d.roughness, 0.6)
				d.rim_enabled = true
				d.rim = 0.35
				d.rim_tint = 0.4
				d.next_pass = _get_outline()
				mi.set_surface_override_material(si, d)

const WALK_SPEED := 3.0    # 6 太快像滑行；戰術步行速度更真（治滑步）
const TURN_SPEED := 12.0   # 轉身要快，短距離移動也能先轉正再跑

# 語意動作 → Quaternius 片段名（優先），找不到再 regex 泛匹配（相容其他模型）
const Q_MAP := {
	"idle": "Idle_Gun_Pointing", "walk": "Walk", "run": "Run",
	"aim": "Idle_Gun_Pointing", "shoot": "Gun_Shoot", "run_shoot": "Run_Shoot",
	"hit": "HitRecieve", "death": "Death", "wave": "Wave",
}
const RX_MAP := {
	"idle": "(?i)idle", "walk": "(?i)walk", "run": "(?i)^run$|running",
	"aim": "(?i)aim|point", "shoot": "(?i)shoot|fire|attack|gun",
	"hit": "(?i)hit|receive", "death": "(?i)death|die", "wave": "(?i)wave",
}

var side: int = 0
var cls: String = "rifleman"
var anim: AnimationPlayer = null
var anim_names := {}
var _move_target = null
var _shoot_target = null
var _state := ""
var _shoot_timer := 0.0
var _busy_until := 0.0        # shoot/hit 播放鎖
var _dead := false
var _die_fade := 0.0
var _model: Node3D = null
var _gun_node: Node3D = null
var _gun_mount: Node3D = null
var _gun_fixed := false
var _gun_fix_wait := 0        # 等動畫姿勢真的套上骨骼再校正（同幀 advance 讀不到新姿勢）
const RIG := preload("res://scripts/Retarget.gd")
var _rig = null                # IK / 俯仰 / 握拳工具（綁在本模型骨架上）
var _gun_armed := false        # 有真實武器模型才做程式化持槍姿
var _gun_len_scale := 1.0      # 網格 → 真實槍長的縮放
var _gun_stock := Vector3.ZERO # 抵肩點（mesh 座標）
var _gun_grip := Vector3.ZERO  # 右手握把
var _gun_fore := Vector3.ZERO  # 左手前護木
var _gun_carry_xf := Transform3D.IDENTITY   # 攜行時的 local 變換（校正結果，離開瞄準要還原）
var _aiming := false
var aim_point = null           # 由 Main/射擊流程指定的瞄準目標點（世界座標）
var _gun_pos := Vector3.ZERO
var want_cover := false        # 由 Main 依所在位置設定；靜止時自動擺蹲姿
var _model_base_y := 0.0
var _crouch := 0.0             # 0=站 1=蹲（平滑過渡）
# 正面軸校正改「轉模型子節點」，Unit.rotation.y 一律代表「+Z 為正面」的純朝向。
# ⚠ 絕不可用檔名判斷模型慣例（2026-07-23 血淚：重定向後檔名沒了 "tripo" 兩字，
#   校正失效、90 度偏差整個回來）。改用「骨架骨名」判斷＝內容決定，改名不會壞。
func facing_dir() -> Vector3:
	return Vector3(sin(rotation.y), 0.0, cos(rotation.y))

# tripo 系骨架(Hip/L_Upperarm/L_Thigh)網格正面朝 +X → 模型需轉 -90° 才對齊 +Z；
# Quaternius 系(Hips/UpperArm.L)本就朝 +Z → 0。
static func _forward_fix(model: Node) -> float:
	var sks := model.find_children("*", "Skeleton3D", true, false)
	if sks.is_empty():
		return 0.0
	var sk := sks[0] as Skeleton3D
	if sk.find_bone("L_Upperarm") >= 0 or sk.find_bone("L_Thigh") >= 0:
		return -PI / 2.0
	return 0.0

static func spawn(model_path: String, p_cls: String, p_side: int, is_player: bool) -> Unit:
	var u := Unit.new()
	u.cls = p_cls
	u.side = p_side
	var packed: PackedScene = null
	if model_path != "" and ResourceLoader.exists(model_path):
		packed = load(model_path)
	if packed == null and ResourceLoader.exists("res://assets/models/chars/soldier.glb"):
		packed = load("res://assets/models/chars/soldier.glb")
	if packed:
		var model := packed.instantiate()
		u._model = model
		u.add_child(model)
		u._fit_model(model)
		model.rotation.y = _forward_fix(model)   # ★正面軸對齊：讓模型正面朝 Unit 的 +Z
		if is_player:
			u._apply_look(model, p_cls)                    # 依立繪配色換裝（2026-07-24）
		else:
			u._tint(model, Color(0.9, 0.2, 0.16), 0.4)     # 敵軍紅疊色一眼可辨
		var aps := model.find_children("*", "AnimationPlayer", true, false)
		if not aps.is_empty():
			u.anim = aps[0]
			u._map_anims()
			u._strip_root_motion()
		u._attach_weapon(model, p_cls)
	# 腳下識別環
	var ring := MeshInstance3D.new()
	ring.name = "Ring"
	var tor := TorusMesh.new()
	tor.inner_radius = 0.62
	tor.outer_radius = 0.72
	ring.mesh = tor
	ring.position.y = 0.06
	var rm := StandardMaterial3D.new()
	rm.albedo_color = Color(0.36, 0.61, 1.0) if is_player else Color(1.0, 0.36, 0.30)
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = rm
	u.add_child(ring)
	# 接觸陰影
	var sh := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(1.4, 1.0)
	sh.mesh = qm
	sh.rotation_degrees.x = -90
	sh.position.y = 0.04
	var shm := StandardMaterial3D.new()
	shm.albedo_color = Color(0, 0, 0, 0.26)
	shm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sh.material_override = shm
	u.add_child(sh)
	return u

# 縮放到 1.8m。蒙皮網格的 get_aabb() 不可靠（soldier.glb 曾被量成 41m 高 → 巨人橫跨畫面），
# 故「有骨架就用骨頭靜止姿勢的實際高度」量測，最可靠；並加安全夾限，寧可不縮放也不爆掉。
func _fit_model(model: Node) -> void:
	var h := 0.0
	var base_y := 0.0
	var sks := model.find_children("*", "Skeleton3D", true, false)
	if not sks.is_empty():
		var sk := sks[0] as Skeleton3D
		var lo := INF
		var hi := -INF
		for i in sk.get_bone_count():
			var t := sk.get_bone_global_rest(i)
			lo = minf(lo, t.origin.y)
			hi = maxf(hi, t.origin.y)
		if hi > lo:
			h = (hi - lo) * 1.12          # 骨頭頂點約在頭頂之下，補一點頭高
			base_y = lo
	if h <= 0.01:
		var aabb := _merged_aabb(model)
		h = aabb.size.y
		base_y = aabb.position.y
	if h <= 0.01:
		return
	var k: float = 1.8 / h
	if k < 0.02 or k > 50.0:
		push_warning("Unit._fit_model 縮放異常 k=%f h=%f，改用原尺寸" % [k, h])
		return
	model.scale = Vector3.ONE * k
	model.position.y = -base_y * k
	_model_base_y = model.position.y

# 遞迴累積父階變換算 AABB。
# ⚠ 舊版只用 mi.transform（沒累積父階），巢狀模型會被量得極小 → _fit_model 縮放暴衝
#   → 單位變成一個橫跨畫面的巨人（使用者看到的「場景黑色邊/灰色巨牆」真因，2026-07-24）。
func _aabb_rec(n: Node, xf: Transform3D, acc: AABB, has: bool) -> Array:
	var cur := xf
	if n is Node3D:
		cur = xf * (n as Node3D).transform
	if n is MeshInstance3D:
		var b: AABB = cur * (n as MeshInstance3D).get_aabb()
		acc = b if not has else acc.merge(b)
		has = true
	for c in n.get_children():
		var r := _aabb_rec(c, cur, acc, has)
		acc = r[0]
		has = r[1]
	return [acc, has]

func _merged_aabb(node: Node) -> AABB:
	var prev := (node as Node3D).transform
	(node as Node3D).transform = Transform3D.IDENTITY
	var r := _aabb_rec(node, Transform3D.IDENTITY, AABB(), false)
	(node as Node3D).transform = prev
	return r[0] if r[1] else AABB()

# 換裝：用內建 3D 模型 + 依角色立繪配色重新上色（data/char_look.json）。
# 模型材質具名(Hair/Skin/Eye/Eyebrows/各衣著色)，依名稱分部位套色；皮膚與眼睛不動。
const _KEEP := ["skin", "eye", "eyebrow", "moustache", "teeth", "mouth"]
func _apply_look(model: Node, p_cls: String) -> void:
	var look: Dictionary = GameData.char_look.get(p_cls, {})
	if look.is_empty():
		return
	var c_hair := Color(look.get("hair", "#333333"))
	var c_coat := Color(look.get("coat", "#3b3b3b"))
	var c_low := Color(look.get("lower", "#4a4a4a"))
	var c_acc := Color(look.get("accent", "#7a7a7a"))
	for m in model.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var cnt: int = maxi(mi.get_surface_override_material_count(), 1)
		for si in cnt:
			var base := mi.get_active_material(si)
			if not (base is StandardMaterial3D):
				continue
			var nm: String = (base as StandardMaterial3D).resource_name.to_lower()
			var keep := false
			for k in _KEEP:
				if nm.contains(k):
					keep = true
					break
			if keep:
				continue
			var src: Color = (base as StandardMaterial3D).albedo_color
			var target: Color
			if nm.contains("hair"):
				target = c_hair
			else:
				# 依原色明度分派：亮的走下身/點綴色，暗的走主外套色，保留原模型的層次
				var lum := src.get_luminance()
				if lum > 0.62:
					target = c_low
				elif lum > 0.34:
					target = c_acc
				else:
					target = c_coat
			var dup := (base as StandardMaterial3D).duplicate()
			dup.albedo_color = src.lerp(target, 0.82)
			mi.set_surface_override_material(si, dup)

func _tint(model: Node, tint: Color, strength: float) -> void:
	if strength <= 0.001:
		return
	for m in model.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var cnt: int = maxi(mi.get_surface_override_material_count(), 1)
		for si in cnt:
			var base := mi.get_active_material(si)
			if base is StandardMaterial3D:
				var dup := (base as StandardMaterial3D).duplicate()
				dup.albedo_color = dup.albedo_color.lerp(tint, strength)
				mi.set_surface_override_material(si, dup)

# 武器改回「握在手裡」（2026-07-25）：揹背只是繞過掛點縮放暴衝，並非修好。
# 真因：BoneAttachment3D 的世界縮放非 1（此類模型為 100 倍），不補償就會把槍放大成巨牆。
# 現改為掛右手腕骨 + 縮放補償 + 依網格實際尺寸自動校正握把，武器才真的在手上。
# 兵種若有真實武器模型就用，沒有的沿用程式生成外形（機槍/火箭筒/迫砲/防空）。
const WEAPON_MODEL := {
	"rifleman": ["res://assets/models/weapons/AssaultRifle_1.obj", 0.90],
	"sniper": ["res://assets/models/weapons/SniperRifle_1.obj", 1.25],
	"specops": ["res://assets/models/weapons/SubmachineGun_1.obj", 0.62],
	"assault": ["res://assets/models/weapons/Shotgun_1.obj", 0.95],
	"engineer": ["res://assets/models/weapons/Pistol_1.obj", 0.22],
}
const HAND_BONES := ["Wrist.R", "Hand.R", "hand_r"]

func _attach_weapon(model: Node, p_cls: String) -> void:
	var sks := model.find_children("*", "Skeleton3D", true, false)
	if sks.is_empty():
		return
	var sk := sks[0] as Skeleton3D
	var bone := ""
	for b in HAND_BONES:
		if sk.find_bone(b) >= 0:
			bone = b
			break
	if bone == "":
		return
	var mount := BoneAttachment3D.new()
	mount.name = "WeaponMount"
	mount.bone_name = bone
	sk.add_child(mount)
	var gun: Node3D
	if WEAPON_MODEL.has(p_cls):
		var mi := MeshInstance3D.new()
		mi.mesh = load(WEAPON_MODEL[p_cls][0])
		gun = mi
	else:
		gun = _make_gun(p_cls)
	mount.add_child(gun)
	_gun_node = gun
	_gun_mount = mount
	_gun_fixed = false         # 交由 _fix_gun_scale 在進場景樹後補償縮放
	_rig = RIG.new()
	_rig.bind(sk)
	# 動畫每幀都會覆寫骨骼姿勢，IK 必須等它寫完才套，否則手臂會被打回動畫姿勢。
	if sk.has_signal("skeleton_updated"):
		sk.skeleton_updated.connect(_on_skeleton_updated)
	# 量出槍身上的三個關鍵點（mesh 座標）：抵肩的槍托、右手握把、左手前護木
	if gun is MeshInstance3D and WEAPON_MODEL.has(p_cls):
		var ab: AABB = (gun as MeshInstance3D).get_aabb()
		var raw: float = ab.size.x
		if raw > 0.0001:
			_gun_len_scale = float(WEAPON_MODEL[p_cls][1]) / raw
		_gun_stock = Vector3(ab.position.x + 0.03 * raw, ab.position.y + 0.62 * ab.size.y, ab.get_center().z)
		_gun_grip = Vector3(ab.position.x + 0.30 * raw, ab.position.y + 0.46 * ab.size.y, ab.get_center().z)
		_gun_fore = Vector3(ab.position.x + 0.46 * raw, ab.position.y + 0.56 * ab.size.y, ab.get_center().z)
		_gun_armed = true

func _mat(col: Color, metal: float, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.metallic = metal
	m.roughness = rough
	return m

# 依兵種造出剪影可辨的專屬武器（GDD/02：狙擊槍/機槍/火箭筒/防空/迫砲/步槍）。
# 慣例：local +Z＝槍口方向，武器原點在握把附近，掛右手腕 Wrist.R。
func _make_gun(p_cls: String) -> Node3D:
	var root := Node3D.new()
	var metal := _mat(Color(0.13, 0.13, 0.14), 0.7, 0.42)
	var dark := _mat(Color(0.07, 0.07, 0.08), 0.8, 0.35)
	var poly := _mat(Color(0.10, 0.11, 0.12), 0.1, 0.7)   # 塑膠件
	var wood := _mat(Color(0.30, 0.20, 0.12), 0.0, 0.75)
	var glass := _mat(Color(0.25, 0.45, 0.55), 0.2, 0.15)
	match p_cls:
		"sniper":
			var rec := _box(0.05, 0.10, 0.42, metal); rec.position.z = 0.0; root.add_child(rec)
			var bar := _cyl(0.011, 0.62, dark); bar.rotation_degrees.x = 90; bar.position.z = 0.52; root.add_child(bar)
			var brake := _cyl(0.022, 0.06, dark); brake.rotation_degrees.x = 90; brake.position.z = 0.85; root.add_child(brake)
			var scope := _cyl(0.022, 0.20, dark); scope.rotation_degrees.x = 90; scope.position = Vector3(0, 0.10, 0.06); root.add_child(scope)
			var lens := _cyl(0.020, 0.02, glass); lens.rotation_degrees.x = 90; lens.position = Vector3(0, 0.10, 0.17); root.add_child(lens)
			var stock := _box(0.045, 0.13, 0.24, poly); stock.position = Vector3(0, -0.02, -0.30); root.add_child(stock)
			var mag := _box(0.035, 0.11, 0.06, poly); mag.position = Vector3(0, -0.10, -0.02); root.add_child(mag)
			_bipod(root, 0.62)
		"mg":
			var rec := _box(0.07, 0.12, 0.40, metal); root.add_child(rec)
			var bar := _cyl(0.018, 0.46, dark); bar.rotation_degrees.x = 90; bar.position.z = 0.44; root.add_child(bar)
			for i in 5:
				var fin := _cyl(0.026, 0.012, dark); fin.rotation_degrees.x = 90; fin.position.z = 0.30 + i * 0.03; root.add_child(fin)
			var box := _box(0.11, 0.11, 0.13, poly); box.position = Vector3(0.02, -0.10, -0.06); root.add_child(box)  # 彈鼓/彈箱
			var stock := _box(0.05, 0.12, 0.22, poly); stock.position = Vector3(0, -0.01, -0.30); root.add_child(stock)
			_bipod(root, 0.58)
		"at":
			var tube := _cyl(0.048, 0.78, dark); tube.rotation_degrees.x = 90; tube.position.z = 0.30; root.add_child(tube)
			var cone := _conemesh(0.048, 0.085, 0.10, dark); cone.rotation_degrees.x = -90; cone.position.z = -0.14; root.add_child(cone)  # 後噴口
			var warhead := _conemesh(0.055, 0.02, 0.10, _mat(Color(0.35,0.28,0.12),0.3,0.6)); warhead.rotation_degrees.x = 90; warhead.position.z = 0.72; root.add_child(warhead)
			var sight := _box(0.02, 0.07, 0.04, metal); sight.position = Vector3(0, 0.075, 0.20); root.add_child(sight)
			var grip := _box(0.03, 0.09, 0.05, poly); grip.position = Vector3(0, -0.09, 0.12); root.add_child(grip)
		"sam":
			var tube := _box(0.09, 0.09, 0.62, poly); tube.position.z = 0.24; root.add_child(tube)   # 方形發射管
			var tip := _conemesh(0.05, 0.006, 0.09, metal); tip.rotation_degrees.x = 90; tip.position.z = 0.58; root.add_child(tip)
			var seeker := _box(0.06, 0.05, 0.05, glass); seeker.position = Vector3(0.06, 0.03, 0.10); root.add_child(seeker)
			var grip := _box(0.03, 0.09, 0.05, poly); grip.position = Vector3(0, -0.09, 0.06); root.add_child(grip)
		"mortar":
			var mtube := _cyl(0.032, 0.70, metal); mtube.rotation_degrees.x = 60; mtube.position = Vector3(0, 0.14, 0.16); root.add_child(mtube)
			var basep := _box(0.20, 0.02, 0.20, dark); basep.position = Vector3(0, -0.14, -0.10); root.add_child(basep)
			var grip := _box(0.03, 0.09, 0.05, poly); grip.position = Vector3(0, -0.09, 0.0); root.add_child(grip)
		_:
			# 步槍/卡賓（rifleman/assault/specops/engineer 等）
			var rec := _box(0.05, 0.10, 0.30, metal); root.add_child(rec)
			var bar := _cyl(0.012, 0.30, dark); bar.rotation_degrees.x = 90; bar.position.z = 0.30; root.add_child(bar)
			var hand := _box(0.045, 0.06, 0.16, poly); hand.position.z = 0.18; root.add_child(hand)
			var mag := _box(0.035, 0.13, 0.055, poly); mag.position = Vector3(0, -0.11, -0.01); mag.rotation_degrees.x = 12; root.add_child(mag)
			var stock := _box(0.045, 0.10, 0.18, poly); stock.position = Vector3(0, -0.01, -0.24); root.add_child(stock)
			var sight := _box(0.015, 0.045, 0.10, metal); sight.position = Vector3(0, 0.075, 0.02); root.add_child(sight)
	return root

func _bipod(root: Node3D, front_z: float) -> void:
	var m := _mat(Color(0.08, 0.08, 0.09), 0.6, 0.5)
	for sgn in [-1.0, 1.0]:
		var leg := _cyl(0.006, 0.24, m)
		leg.rotation_degrees = Vector3(28, 0, sgn * 22)
		leg.position = Vector3(sgn * 0.05, -0.12, front_z * 0.55)
		root.add_child(leg)

func _conemesh(bottom_r: float, top_r: float, h: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.bottom_radius = bottom_r
	cm.top_radius = top_r
	cm.height = h
	mi.mesh = cm
	mi.material_override = mat
	return mi

func _box(x: float, y: float, z: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = Vector3(x, y, z)
	mi.mesh = m
	mi.material_override = mat
	return mi

func _cyl(r: float, h: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = r
	m.bottom_radius = r
	m.height = h
	mi.mesh = m
	mi.material_override = mat
	return mi

func _map_anims() -> void:
	if anim == null: return
	var have := anim.get_animation_list()
	for key in RX_MAP.keys():
		# ⚠ 部分模型(如 soldier.glb)片段名帶 "CharacterArmature|" 前綴，
		# 只做等值比對會失敗→退回 regex 抓到空手的 "Idle"，角色就變成垂手站著、槍飄在旁邊。
		# 故一律比對「| 之後的片段名」。
		if Q_MAP.has(key):
			var want: String = Q_MAP[key]
			var hit := ""
			for n in have:
				if n == want or n.substr(n.rfind("|") + 1) == want:
					hit = n
					break
			if hit != "":
				anim_names[key] = hit
				continue
		var rx := RegEx.new()
		rx.compile(RX_MAP[key])
		for n in have:
			if rx.search(n):
				anim_names[key] = n
				break
	_play("idle", 0.0)

# 抽離根運動：tripo 走/跑動畫把角色往前位移(root bone)，會跟程式移動疊加成滑步/回彈。
# 設 root_motion_track 讓 Godot 把該位移從姿勢抽走→動畫變原地踏步，位移純由程式驅動。
func _strip_root_motion() -> void:
	if anim == null:
		return
	var base: Node = null
	if anim.root_node != NodePath(""):
		base = anim.get_node_or_null(anim.root_node)
	if base == null:
		base = anim.get_parent()
	if base == null:
		return
	var sks := base.find_children("*", "Skeleton3D", true, false)
	if sks.is_empty():
		return
	var sk := sks[0] as Skeleton3D
	var rootbone := -1
	for i in sk.get_bone_count():
		if sk.get_bone_parent(i) == -1:
			rootbone = i
			break
	if rootbone < 0:
		return
	var relp := base.get_path_to(sk)
	anim.root_motion_track = NodePath(str(relp) + ":" + sk.get_bone_name(rootbone))

func _clip_len(key: String) -> float:
	if anim and anim_names.has(key):
		var a := anim.get_animation(anim_names[key])
		if a: return a.length
	return 0.5

func _play(key: String, blend := 0.2) -> void:
	if anim == null or not anim_names.has(key): return
	if _state == key and anim.is_playing(): return
	var clip: String = anim_names[key]
	if key in ["idle", "walk", "run", "aim"]:
		var a := anim.get_animation(clip)
		if a: a.loop_mode = Animation.LOOP_LINEAR
	anim.play(clip, blend)
	_state = key

# 立即中止移動/射擊（到位後擺蹲姿、或被打斷時用）
func stop() -> void:
	_move_target = null
	_shoot_target = null

func move_to(p: Vector3) -> void:
	if _dead: return
	_shoot_target = null
	_move_target = Vector3(p.x, 0.0, p.z)

func shoot_at(target: Unit) -> void:
	if _dead: return
	# 合理化時序：轉身 → 舉槍(aim) → 0.3s 後 shoot 並發曳光
	_move_target = null
	_shoot_target = target
	_shoot_timer = 0.3
	_face_towards(target.global_position, 1.0)
	_play("aim", 0.12)

func take_hit() -> void:
	if _dead: return
	var now := Time.get_ticks_msec() / 1000.0
	_play("hit", 0.05)
	_busy_until = now + max(0.4, _clip_len("hit"))

func die() -> void:
	if _dead: return
	_dead = true
	_move_target = null
	_shoot_target = null
	_play("death", 0.1)
	_die_fade = max(1.0, _clip_len("death"))   # 播完死亡動畫再淡出移除

func _face_towards(p: Vector3, k: float) -> void:
	var d := p - global_position
	d.y = 0.0
	if d.length() < 0.05: return
	rotation.y = lerp_angle(rotation.y, atan2(d.x, d.z), k)

# 槍械尺度補償：BoneAttachment 的世界縮放要等節點進場景樹才算得準
# （soldier.glb 掛點世界縮放極大，不補償這把 0.5m 的槍會變成 80+ 公尺長條＝「灰色巨牆」）。
func _fix_gun_scale() -> void:
	# 只校正一次：校正後槍即自然跟隨手骨擺動。
	# 若每幀重算會把槍鎖成永遠水平朝前，走路時手在擺、槍不動，反而脫節。
	if _gun_fixed or _gun_mount == null or _gun_node == null:
		return
	if not is_inside_tree() or not _gun_mount.is_inside_tree():
		return
	_gun_fixed = true
	# ⚠ 校正必須在「瞄準姿勢」下做，不能用第一幀的垂手靜止姿：
	#   校正完槍就固定跟著手骨走，若基準是垂手姿，動畫把手抬起來時槍口會跟著翹上天。
	if _gun_fix_wait < 6:
		_gun_fix_wait += 1
		_gun_fixed = false
		return
	# 動態對齊：讀「手腕在模型空間的朝向」反算，使槍口朝角色正前、瞄具朝上，
	# 不論模型/動畫幀差異都成立（治火箭筒指天、狙擊槍穿身）。
	# 以 Unit 本體為參考（_model 內部另有正面軸校正，拿它當基準會對錯方向）
	var wrist := (global_transform.affine_inverse() * _gun_mount.global_transform).basis.orthonormalized()
	var ws := _gun_mount.global_transform.basis.get_scale()
	var s: float = (absf(ws.x) + absf(ws.y) + absf(ws.z)) / 3.0
	if s < 0.0001:
		s = 1.0
	var desired := Basis.IDENTITY     # 程式生成的武器：槍口已是 +Z
	var scale_f := 1.0
	var grip := Vector3.ZERO
	if _gun_node is MeshInstance3D and WEAPON_MODEL.has(cls):
		var ab: AABB = (_gun_node as MeshInstance3D).get_aabb()
		var raw: float = ab.size.x
		if raw > 0.0001:
			scale_f = float(WEAPON_MODEL[cls][1]) / raw   # 依真實槍長換算，各槍網格尺寸不一
		desired = Basis(Vector3(0, 0, 1), Vector3(0, 1, 0), Vector3(-1, 0, 0))   # 槍管 +X → 角色正前 +Z
		# 握把柄：槍身後端往前 30%、下緣往上 46%（取槍管中線會讓槍浮在手掌上方）
		grip = Vector3(ab.position.x + 0.30 * raw, ab.position.y + 0.46 * ab.size.y, ab.get_center().z)
	var b := (wrist.inverse() * desired).scaled(Vector3.ONE * (scale_f / s))
	_gun_node.transform = Transform3D(b, -(b * grip))
	_gun_carry_xf = _gun_node.transform

# 蹲姿：Quaternius 動畫組沒有 crouch，故以「壓低身體＋前傾」模擬躲在掩體後。
# 移動中一律站起（跑步蹲著不合理）。
func _update_crouch(delta: float) -> void:
	if _model == null:
		return
	var target: float = 1.0 if (want_cover and not _dead and _move_target == null) else 0.0
	_crouch = move_toward(_crouch, target, delta * 3.2)
	_model.position.y = _model_base_y - 0.42 * _crouch
	_model.rotation.x = 0.13 * _crouch

func _process(delta: float) -> void:
	_fix_gun_scale()
	_update_crouch(delta)
	if _dead:
		_die_fade -= delta
		if _die_fade <= 0.4 and _model:      # 動畫播完後最後 0.4s 淡出
			var k: float = clamp(_die_fade / 0.4, 0.0, 1.0)
			_fade(k)
		if _die_fade <= 0.0:
			queue_free()
		return
	var now := Time.get_ticks_msec() / 1000.0
	if _shoot_target != null:
		_face_towards(_shoot_target.global_position, 0.5)
		_shoot_timer -= delta
		if _shoot_timer <= 0.0:
			_play("shoot", 0.05)
			_busy_until = now + max(0.5, _clip_len("shoot"))
			shot_fired.emit(global_position + Vector3(0, 1.35, 0),
					_shoot_target.global_position + Vector3(0, 1.2, 0))
			_shoot_target = null
		return
	if now < _busy_until:
		return
	if _move_target != null:
		var d: Vector3 = _move_target - global_position
		d.y = 0.0
		if d.length() < 0.15:
			_move_target = null
			_play("idle")
			return
		# VC 做法：先轉身面向目標，面向差太大時原地轉身不前進（治「面向一個方向跑」）
		var target_yaw := atan2(d.x, d.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, min(1.0, TURN_SPEED * delta))
		var ang := absf(wrapf(target_yaw - rotation.y, -PI, PI))
		if ang > 0.6:
			_play("idle")        # 還沒轉正：原地轉身
		else:
			global_position += d.normalized() * WALK_SPEED * delta
			_play("run" if anim_names.has("run") else "walk")
	elif _state == "shoot" or _state == "" or _state == "hit":
		_play("idle")

func _fade(k: float) -> void:
	for m in _model.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var cnt: int = maxi(mi.get_surface_override_material_count(), 1)
		for si in cnt:
			var mm := mi.get_active_material(si)
			if mm is StandardMaterial3D:
				var d := (mm as StandardMaterial3D).duplicate()
				d.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				d.albedo_color.a = k
				mi.set_surface_override_material(si, d)

# 程式化持槍姿（GDD/13，2026-07-25）：模型自帶動畫是「單手指槍」，長槍必須雙手才合理。
# 作法同真實遊戲的疊加瞄準層：槍托抵右肩、槍口指向目標，再用 IK 把兩隻手抓上槍。
# 移動中不套用（跑步時雙手鎖在槍上會與跑步動畫打架），改回攜行姿。
func _aim_pose() -> void:
	if not _gun_armed or _rig == null or _gun_node == null or not _gun_fixed or _model == null:
		return
	var sks := _model.find_children("*", "Skeleton3D", true, false)
	if sks.is_empty():
		return
	var sk := sks[0] as Skeleton3D
	_aiming = (not _dead) and _move_target == null
	if not _aiming:
		_gun_node.transform = _gun_carry_xf      # 攜行：還原成掛在手上
		return
	var si := sk.find_bone("Shoulder.R")
	if si < 0:
		return
	var tgt: Vector3 = global_position + facing_dir() * 8.0 + Vector3.UP * 1.2
	if aim_point != null:
		tgt = aim_point
	# 1) 上半身與頭先跟著俯仰——會動到肩膀位置，故必須排在算抵肩點之前
	var eye := global_position + Vector3.UP * 1.45
	var pitch: float = asin(clampf((tgt - eye).normalized().y, -1.0, 1.0))
	var right := global_basis.x.normalized()
	_rig.add_world_rotation("Chest", right, -pitch * 0.45)
	_rig.add_world_rotation("Head", right, -pitch * 0.40)
	# 2) 槍：槍托抵右肩窩、槍口指向目標
	var pocket: Vector3 = (sk.global_transform * sk.get_bone_global_pose(si).origin) - Vector3.UP * 0.06
	var aim: Vector3 = (tgt - pocket).normalized()
	var up_ref := Vector3.UP
	if absf(aim.dot(up_ref)) > 0.97:
		up_ref = facing_dir()                    # 目標近乎正上/正下時叉積會退化
	var z_axis := aim.cross(up_ref).normalized()
	var y_axis := z_axis.cross(aim).normalized()
	var b := Basis(aim * _gun_len_scale, y_axis * _gun_len_scale, z_axis * _gun_len_scale)
	var xf := Transform3D(b, pocket + aim * 0.02 - b * _gun_stock)
	# 3) 兩手抓上槍（右手握把、左手前護木）＋手指握攏
	# 肘部極向量：兩肘都朝下外側，這是持槍的自然姿勢；沒有約束會扭成怪解
	var down := -Vector3.UP
	var rightv := global_basis.x.normalized()
	_rig.ik_two_bone("UpperArm.R", "LowerArm.R", "Wrist.R", xf * _gun_grip, (down * 0.85 + rightv * 0.5).normalized())
	_rig.ik_two_bone("UpperArm.L", "LowerArm.L", "Wrist.L", xf * _gun_fore, (down * 0.9 + rightv * 0.28).normalized())
	_rig.curl_fingers(".R", 0, 55.0, 35.0)
	_rig.curl_fingers(".L", 0, 55.0, 35.0)
	# 4) 最後才擺槍：IK 會動到手骨→掛點跟著動，先擺會被帶偏
	_gun_node.global_transform = xf

var _in_pose := false          # skeleton_updated 內改骨骼會再觸發信號，需防遞迴
func _on_skeleton_updated() -> void:
	if _in_pose:
		return
	_in_pose = true
	_aim_pose()
	_in_pose = false
