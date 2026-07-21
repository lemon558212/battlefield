# Unit.gd — 步兵/載具單位（GDD/13）
# 動作合理化（記憶 feedback-realism-rule）由 AnimationPlayer 原生保證：
# 走路必踏步、瞄準舉槍(Idle_Gun_Pointing)、開火先舉槍後 Gun_Shoot、轉身面向目標。
# 戰場身體＝Quaternius(24 動畫)；角色 identity 走 2D 立繪（人的靈魂在立繪，3D 是棋子）。
class_name Unit
extends Node3D

signal shot_fired(from_pos: Vector3, to_pos: Vector3)

const WALK_SPEED := 6.0
const TURN_SPEED := 10.0

# 語意動作 → Quaternius 片段名（優先），找不到再用 regex 泛匹配（相容 tripo/其他模型）
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
var unit_name: String = ""
var anim: AnimationPlayer = null
var anim_names := {}
var _move_target = null
var _shoot_target = null
var _state := ""
var _shoot_timer := 0.0
var _busy_until := 0.0        # shoot/hit 播放鎖

static func spawn(model_path: String, p_cls: String, p_side: int, tint: Color) -> Unit:
	var u := Unit.new()
	u.cls = p_cls
	u.side = p_side
	var packed: PackedScene = load(model_path)
	if packed:
		var model := packed.instantiate()
		u.add_child(model)
		u._fit_model(model)
		u._tint(model, tint)
		var aps := model.find_children("*", "AnimationPlayer", true, false)
		if not aps.is_empty():
			u.anim = aps[0]
			u._map_anims()
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
	rm.albedo_color = Color(0.36, 0.61, 1.0) if p_side == 0 else Color(1.0, 0.42, 0.35)
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = rm
	u.add_child(ring)
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
		var b: AABB = mi.get_aabb()
		b = mi.global_transform.affine_inverse() * node.global_transform * (mi.transform * b) if false else (mi.transform * b)
		if first: out = b; first = false
		else: out = out.merge(b)
	return out

func _tint(model: Node, tint: Color) -> void:
	# 兵種色：以微量疊色區分（不蓋掉貼圖），敵我另靠識別環
	if tint.a <= 0.001:
		return
	for m in model.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		for si in mi.get_surface_override_material_count():
			var base := mi.get_active_material(si)
			if base is StandardMaterial3D:
				var dup := (base as StandardMaterial3D).duplicate()
				dup.albedo_color = dup.albedo_color.lerp(tint, 0.22)
				mi.set_surface_override_material(si, dup)

# 武器掛點（GDD/13）：把程序化槍械綁到右手骨 Wrist.R，隨骨架動畫一起動。
# 兵種決定槍型（長度/口徑），讓剪影可辨。
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
	# 槍在手中的擺位（相對手骨；經 selftest 微調）
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
	# 依兵種調整槍身/槍管尺寸
	var body_len := 0.34
	var barrel_len := 0.30
	var barrel_r := 0.012
	match p_cls:
		"sniper": body_len = 0.40; barrel_len = 0.55; barrel_r = 0.010
		"mg": body_len = 0.42; barrel_len = 0.42; barrel_r = 0.018
		"at": body_len = 0.30; barrel_len = 0.62; barrel_r = 0.045   # 火箭筒
		"mortar", "sam": body_len = 0.30; barrel_len = 0.50; barrel_r = 0.035
		"rifleman", "assault", "specops", "engineer": body_len = 0.34; barrel_len = 0.34
	var body := _box(0.05, 0.11, body_len, dark)
	body.position.z = 0.0
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
		# 1) Quaternius 精確名優先
		if Q_MAP.has(key) and have.has(Q_MAP[key]):
			anim_names[key] = Q_MAP[key]
			continue
		# 2) regex 泛匹配
		var rx := RegEx.new()
		rx.compile(RX_MAP[key])
		for n in have:
			if rx.search(n):
				anim_names[key] = n
				break
	_play("idle", 0.0)

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
	_shoot_target = null
	_move_target = Vector3(p.x, 0.0, p.z)

func aim_at(target: Unit) -> void:
	_move_target = null
	_shoot_target = null
	_face_towards(target.global_position, 0.5)
	_play("aim", 0.18)

func shoot_at(target: Unit) -> void:
	# 合理化時序：轉身 → 舉槍(aim) → 0.3s 後 Gun_Shoot 並發曳光
	_move_target = null
	_shoot_target = target
	_shoot_timer = 0.3
	_face_towards(target.global_position, 1.0)
	_play("aim", 0.12)

func _face_towards(p: Vector3, k: float) -> void:
	var d := p - global_position
	d.y = 0.0
	if d.length() < 0.05: return
	rotation.y = lerp_angle(rotation.y, atan2(d.x, d.z), k)

func _process(delta: float) -> void:
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
		_face_towards(_move_target, TURN_SPEED * delta)
		global_position += d.normalized() * WALK_SPEED * delta
		_play("run" if anim_names.has("run") else "walk")
	elif _state == "shoot" or _state == "":
		_play("idle")
