# Unit.gd — 戰場單位＝3D 動畫身體（GDD/13，2026-07-22 使用者拍板：戰場改 3D 模型、立繪只留 UI）。
# 這是 VC 本尊做法：立繪管 identity（選單/對話/角色卡），戰場上是能走/蹲/進掩體的 3D 模型（治「用飄的」）。
# 動作合理化由 AnimationPlayer 原生保證：走路必踏步、開火先舉槍轉身面向目標、受擊/陣亡有動作。
# 地基取自 git b93c0cb 的舊 Unit.gd。
class_name Unit
extends Node3D

signal shot_fired(from_pos: Vector3, to_pos: Vector3)

const WALK_SPEED := 3.0    # 6 太快像滑行；戰術步行速度更真（治滑步）
const TURN_SPEED := 12.0   # 轉身要快，短距離移動也能先轉正再跑

# 語意動作 → Quaternius 片段名（優先），找不到再 regex 泛匹配（相容其他模型）
const Q_MAP := {
	"idle": "Idle_Gun", "walk": "Walk", "run": "Run",
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

# 武器掛骨 Wrist.R，隨骨架動畫一起動；兵種決定槍型（剪影可辨）
func _attach_weapon(model: Node, p_cls: String) -> void:
	var sks := model.find_children("*", "Skeleton3D", true, false)
	if sks.is_empty():
		return
	var sk := sks[0] as Skeleton3D
	var bi := sk.find_bone("Wrist.R")
	if bi < 0:
		return
	var ba := BoneAttachment3D.new()
	ba.name = "WeaponMount"
	sk.add_child(ba)
	ba.bone_name = "Wrist.R"
	var gun := _make_gun(p_cls)
	ba.add_child(gun)
	gun.rotation_degrees = Vector3(0, 90, 8)
	_gun_node = gun
	_gun_mount = ba

func _make_gun(p_cls: String) -> Node3D:
	var root := Node3D.new()
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.11, 0.11, 0.12)
	dark.metallic = 0.6
	dark.roughness = 0.5
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.28, 0.19, 0.12)
	var body_len := 0.34
	var barrel_len := 0.30
	var barrel_r := 0.012
	match p_cls:
		"sniper": body_len = 0.40; barrel_len = 0.55; barrel_r = 0.010
		"mg": body_len = 0.42; barrel_len = 0.42; barrel_r = 0.018
		"at": body_len = 0.30; barrel_len = 0.62; barrel_r = 0.045
		"mortar", "sam": body_len = 0.30; barrel_len = 0.50; barrel_r = 0.035
		"rifleman", "assault", "specops", "engineer": body_len = 0.34; barrel_len = 0.34
	var body := _box(0.05, 0.11, body_len, dark)
	root.add_child(body)
	var barrel := _cyl(barrel_r, barrel_len, dark)
	barrel.rotation_degrees.x = 90
	barrel.position = Vector3(0, 0.02, body_len * 0.5 + barrel_len * 0.5)
	root.add_child(barrel)
	var grip := _box(0.04, 0.10, 0.05, wood)
	grip.position = Vector3(0, -0.09, -body_len * 0.3)
	root.add_child(grip)
	if p_cls == "sniper":
		var scope := _cyl(0.016, 0.12, dark)
		scope.rotation_degrees.x = 90
		scope.position = Vector3(0, 0.09, 0.05)
		root.add_child(scope)
	return root

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
		if Q_MAP.has(key) and have.has(Q_MAP[key]):
			anim_names[key] = Q_MAP[key]
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
	if _gun_fixed or _gun_node == null or _gun_mount == null:
		return
	if not is_inside_tree() or not _gun_mount.is_inside_tree():
		return
	_gun_fixed = true
	var ws := _gun_mount.global_transform.basis.get_scale()
	var s: float = (absf(ws.x) + absf(ws.y) + absf(ws.z)) / 3.0
	if s > 0.0001 and (s > 1.15 or s < 0.87):
		_gun_node.scale = Vector3.ONE / s
		_gun_node.position = Vector3(0.02, 0.0, 0.10) / s
	else:
		_gun_node.position = Vector3(0.02, 0.0, 0.10)

func _process(delta: float) -> void:
	_fix_gun_scale()
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
