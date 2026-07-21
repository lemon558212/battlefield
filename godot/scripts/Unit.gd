# Unit.gd — 戰場單位（GDD/13，2026-07-21 使用者裁定）：
#   我方具名英雄＝2D 立繪看板（立繪本人站在 3D 戰場，戰場女武神式 2D-in-3D）；
#   敵軍無名兵＝3D 士兵模型紅染（我方英雄立繪不得給敵人用，敵兵之後再生圖立繪替換）。
# 立繪姿態：用現有 angry/hurt 表情圖切換（瞄準→angry、受擊→hurt）＋開火後座＋陣亡淡出傾倒。
class_name Unit
extends Node3D

signal shot_fired(from_pos: Vector3, to_pos: Vector3)

const WALK_SPEED := 6.0

var side: int = 0
var cls: String = "rifleman"
var is_portrait := true
var spr: Sprite3D
var tex_base: Texture2D
var tex_aim: Texture2D
var tex_hurt: Texture2D
var _move_target = null
var _shoot_target = null
var _shoot_timer := 0.0
var _base_y := 0.0
var _t := 0.0
var _fire_flash := 0.0
var _revert_t := 0.0      # 表情圖回復待機的倒數
var _hurt_t := 0.0        # 受擊紅閃倒數
var _dead := false
var _die_t := 0.0

# ---------- 我方立繪看板 ----------
static func spawn_portrait(portrait_path: String, p_cls: String, p_side: int, is_player := true) -> Unit:
	var u := Unit.new()
	u.cls = p_cls
	u.side = p_side
	u.is_portrait = true
	var s := Sprite3D.new()
	if portrait_path != "" and ResourceLoader.exists(portrait_path):
		s.texture = load(portrait_path)
	s.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y     # 恆面向相機、保持直立
	s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD       # 透明去背（PNG 已烘焙透明）
	s.alpha_scissor_threshold = 0.35
	s.shaded = false
	s.double_sided = true
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	if s.texture:
		var th: float = s.texture.get_height()
		s.pixel_size = 2.6 / max(1.0, th)              # 立繪高 ≈ 2.6m
	s.position.y = 1.3
	u.spr = s
	u.tex_base = s.texture
	u.add_child(s)
	u._base_y = 1.3
	# 表情圖（姿態切換用）
	var pa := GameData.portrait_path(p_cls, "angry")
	if pa != "" and ResourceLoader.exists(pa):
		u.tex_aim = load(pa)
	var ph := GameData.portrait_path(p_cls, "hurt")
	if ph != "" and ResourceLoader.exists(ph):
		u.tex_hurt = load(ph)
	_add_base(u, is_player)
	return u

# ---------- 敵軍 3D 士兵模型（紅染，無名兵）----------
static func spawn_model(model_path: String, p_cls: String, p_side: int) -> Unit:
	var u := Unit.new()
	u.cls = p_cls
	u.side = p_side
	u.is_portrait = false
	var body: Node3D = null
	if model_path != "" and ResourceLoader.exists(model_path):
		var packed: PackedScene = load(model_path)
		if packed:
			body = packed.instantiate()
	if body == null:                                   # 保底：找不到模型退回通用士兵
		var fb := "res://assets/models/chars/soldier.glb"
		if ResourceLoader.exists(fb):
			body = (load(fb) as PackedScene).instantiate()
	if body:
		u.add_child(body)
		_tint_red(body)
		_play_idle(body)
	u._base_y = 0.0
	_add_base(u, false)
	return u

# 腳下識別環＋接觸陰影（敵我共用）
static func _add_base(u: Unit, is_player: bool) -> void:
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
	var sh := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(1.5, 1.0)
	sh.mesh = qm
	sh.rotation_degrees.x = -90
	sh.position.y = 0.04
	var shm := StandardMaterial3D.new()
	shm.albedo_color = Color(0, 0, 0, 0.28)
	shm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sh.material_override = shm
	u.add_child(sh)

# 敵兵紅染：每個 MeshInstance3D 疊一層半透紅 overlay
static func _tint_red(root: Node) -> void:
	for c in root.get_children():
		if c is MeshInstance3D:
			var m := StandardMaterial3D.new()
			m.albedo_color = Color(0.85, 0.16, 0.13, 0.5)
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			(c as MeshInstance3D).material_overlay = m
		if c.get_child_count() > 0:
			_tint_red(c)

# 播待機動畫（Quaternius 有 AnimationPlayer；避免 T-pose 呆站）
static func _play_idle(root: Node) -> void:
	var ap := _find_anim(root)
	if ap == null:
		return
	var pick := ""
	for a in ap.get_animation_list():
		if "idle" in a.to_lower():
			pick = a
			break
	if pick == "" and ap.get_animation_list().size() > 0:
		pick = ap.get_animation_list()[0]
	if pick != "":
		ap.play(pick)

static func _find_anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim(c)
		if r != null:
			return r
	return null

# ---------- 行為 ----------
func move_to(p: Vector3) -> void:
	_shoot_target = null
	_move_target = Vector3(p.x, 0.0, p.z)

func shoot_at(target: Unit) -> void:
	_move_target = null
	_shoot_target = target
	_shoot_timer = 0.3
	if spr and tex_aim:              # 立繪：瞄準換 angry 表情
		spr.texture = tex_aim
		_revert_t = 0.9

func take_hit() -> void:
	if spr:
		if tex_hurt:
			spr.texture = tex_hurt
			_revert_t = 0.7
		_hurt_t = 0.35               # 紅閃

func die() -> void:
	_dead = true
	_die_t = 0.6
	_move_target = null
	_shoot_target = null

func _process(delta: float) -> void:
	_t += delta
	# 陣亡：淡出＋傾倒後移除
	if _dead:
		_die_t -= delta
		var k: float = clamp(_die_t / 0.6, 0.0, 1.0)
		if spr:
			spr.modulate.a = k
			rotation.z = (1.0 - k) * 1.2
		else:
			rotation.z = (1.0 - k) * 1.4
			position.y = _base_y - (1.0 - k) * 0.4
		if _die_t <= 0.0:
			queue_free()
		return
	# 表情圖回復待機
	if _revert_t > 0.0:
		_revert_t -= delta
		if _revert_t <= 0.0 and spr and tex_base:
			spr.texture = tex_base
	# 受擊紅閃
	if _hurt_t > 0.0:
		_hurt_t -= delta
		if spr:
			spr.modulate = Color(1, 0.4, 0.4) if _hurt_t > 0.0 else Color(1, 1, 1)
	# 立繪待機微浮＋開火後座
	if spr:
		spr.position.y = _base_y + sin(_t * 2.2) * 0.04
		if _fire_flash > 0.0:
			_fire_flash -= delta * 4.0
			var kf: float = max(0.0, _fire_flash)
			spr.position.x = -0.18 * kf
	if _shoot_target != null:
		_shoot_timer -= delta
		if _shoot_timer <= 0.0:
			_fire_flash = 1.0
			shot_fired.emit(global_position + Vector3(0, 1.35, 0),
					_shoot_target.global_position + Vector3(0, 1.2, 0))
			_shoot_target = null
		return
	if _move_target != null:
		var d: Vector3 = _move_target - global_position
		d.y = 0.0
		if d.length() < 0.15:
			_move_target = null
			return
		global_position += d.normalized() * WALK_SPEED * delta
		if spr:
			spr.position.x = sin(_t * 9.0) * 0.05
