# Unit.gd — 步兵/載具單位（GDD/13 P0）：glb 模型＋動畫狀態機（idle/walk/aim/shoot）
# 動作合理化鐵則（記憶 feedback-realism-rule）在 Godot 版由 AnimationPlayer 原生保證：
# 走路必踏步、開槍先舉槍後出彈、轉身面向目標。
class_name Unit
extends Node3D

signal shot_fired(from_pos: Vector3, to_pos: Vector3)

const WALK_SPEED := 6.0
const TURN_SPEED := 10.0

var side: int = 0
var cls: String = "rifleman"
var anim: AnimationPlayer = null
var anim_names := {}          # 語意名 → 實際片段名（regex 對表）
var _move_target = null       # Vector3 或 null
var _state := "idle"
var _shoot_timer := 0.0
var _shoot_target = null

static func spawn(model_path: String, p_cls: String, p_side: int) -> Unit:
	var u := Unit.new()
	u.cls = p_cls
	u.side = p_side
	var packed: PackedScene = load(model_path)
	if packed:
		var model := packed.instantiate()
		u.add_child(model)
		u._fit_model(model)
		u.anim = u._find_anim_player(model)
		u._map_anims()
	# 選取環
	var ring := MeshInstance3D.new()
	var tor := TorusMesh.new()
	tor.inner_radius = 0.85
	tor.outer_radius = 1.0
	ring.mesh = tor
	ring.position.y = 0.05
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.36, 0.61, 1.0) if p_side == 0 else Color(1.0, 0.42, 0.35)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = mat
	u.add_child(ring)
	return u

func _fit_model(model: Node) -> void:
	# 統一身高 ~1.8m、腳貼地、面向 -Z（Godot 前方）
	var aabb := _merged_aabb(model)
	if aabb.size.y > 0.01:
		var k := 1.8 / aabb.size.y
		model.scale = Vector3.ONE * k
		model.position.y = -aabb.position.y * k

func _merged_aabb(node: Node) -> AABB:
	var out := AABB()
	var first := true
	for m in node.find_children("*", "MeshInstance3D", true, false):
		var b: AABB = (m as MeshInstance3D).get_aabb()
		b = (m as MeshInstance3D).transform * b
		if first:
			out = b
			first = false
		else:
			out = out.merge(b)
	return out

func _find_anim_player(model: Node) -> AnimationPlayer:
	var found = model.find_children("*", "AnimationPlayer", true, false)
	return found[0] if found.size() > 0 else null

func _map_anims() -> void:
	if anim == null:
		return
	var pats := {
		"idle": "(?i)idle", "walk": "(?i)walk", "run": "(?i)run",
		"aim": "(?i)aim|point", "shoot": "(?i)shoot|fire|attack|gun",
		"hit": "(?i)hit|receive", "death": "(?i)death|die", "crouch": "(?i)crouch"
	}
	for key in pats.keys():
		var rx := RegEx.new()
		rx.compile(pats[key])
		for n in anim.get_animation_list():
			if rx.search(n):
				anim_names[key] = n
				break
	_play("idle")

func _play(key: String, blend := 0.25) -> void:
	if anim == null or not anim_names.has(key):
		return
	if _state == key and anim.is_playing():
		return
	var clip: String = anim_names[key]
	anim.play(clip, blend)
	# idle/walk 循環
	if key == "idle" or key == "walk" or key == "run":
		var a := anim.get_animation(clip)
		if a:
			a.loop_mode = Animation.LOOP_LINEAR
	_state = key

func move_to(p: Vector3) -> void:
	_shoot_target = null
	_move_target = Vector3(p.x, 0.0, p.z)

func shoot_at(target: Unit) -> void:
	# 合理化時序：轉身 → 舉槍(aim/或 shoot 起手) → 0.3s 後離膛（訊號給 Main 畫曳光）
	_move_target = null
	_shoot_target = target
	_shoot_timer = 0.3
	_face_towards(target.global_position, 1.0)
	if anim_names.has("aim"):
		_play("aim", 0.15)
	else:
		_play("shoot", 0.1)

func _face_towards(p: Vector3, k: float) -> void:
	var d := p - global_position
	d.y = 0.0
	if d.length() < 0.05:
		return
	var want := atan2(d.x, d.z)
	rotation.y = lerp_angle(rotation.y, want, k)

func _process(delta: float) -> void:
	if _shoot_target != null:
		_face_towards(_shoot_target.global_position, 0.4)
		_shoot_timer -= delta
		if _shoot_timer <= 0.0:
			_play("shoot", 0.05)
			var muzzle := global_position + Vector3(0, 1.35, 0)
			var hitp: Vector3 = _shoot_target.global_position + Vector3(0, 1.2, 0)
			shot_fired.emit(muzzle, hitp)
			_shoot_target = null
			# shoot 播完自動回 idle
			if anim and anim_names.has("shoot"):
				var len_s: float = anim.get_animation(anim_names["shoot"]).length
				await get_tree().create_timer(max(0.4, len_s)).timeout
				if _state == "shoot":
					_play("idle")
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
		_play("walk")
	elif _state == "walk":
		_play("idle")
