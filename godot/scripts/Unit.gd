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
		# 敵軍紅疊色一眼可辨；我方保留自然貼圖（僅極輕兵種色）
		u._tint(model, Color(0.9, 0.2, 0.16) if not is_player else Color(1, 1, 1, 0), 0.4 if not is_player else 0.0)
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

func _fit_model(model: Node) -> void:
	var aabb := _merged_aabb(model)
	if aabb.size.y > 0.01:
		var k := 1.8 / aabb.size.y
		model.scale = Vector3.ONE * k
		model.position.y = -aabb.position.y * k

func _merged_aabb(node: Node) -> AABB:
	var out := AABB()
	var first := true
	for m in node.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var b: AABB = mi.transform * mi.get_aabb()
		if first: out = b; first = false
		else: out = out.merge(b)
	return out

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
	gun.position = Vector3(0.02, 0.0, 0.10)
	gun.rotation_degrees = Vector3(0, 90, 8)

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

func _process(delta: float) -> void:
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
