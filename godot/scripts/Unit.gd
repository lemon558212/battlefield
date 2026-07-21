# Unit.gd — 戰場單位＝2D 立繪看板（GDD/13，2026-07-21 使用者裁定：
# 戰場上的兵就是立繪本人，不用內建 3D 積木人。立繪站在 3D 戰場（戰場女武神式 2D-in-3D）。
class_name Unit
extends Node3D

signal shot_fired(from_pos: Vector3, to_pos: Vector3)

const WALK_SPEED := 6.0

var side: int = 0
var cls: String = "rifleman"
var spr: Sprite3D
var _move_target = null
var _shoot_target = null
var _shoot_timer := 0.0
var _base_y := 0.0
var _t := 0.0
var _fire_flash := 0.0

static func spawn_portrait(portrait_path: String, p_cls: String, p_side: int, is_player := true) -> Unit:
	var u := Unit.new()
	u.cls = p_cls
	u.side = p_side
	# 立繪看板
	var s := Sprite3D.new()
	if portrait_path != "" and ResourceLoader.exists(portrait_path):
		s.texture = load(portrait_path)
	s.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y     # 恆面向相機、保持直立
	s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD       # 透明去背（PNG 已烘焙透明）
	s.alpha_scissor_threshold = 0.35
	s.shaded = false
	s.double_sided = true
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	# 縮放：立繪高 ≈ 2.6m（比棋子略大，看得清臉）
	if s.texture:
		var th: float = s.texture.get_height()
		s.pixel_size = 2.6 / max(1.0, th)
	s.position.y = 1.3
	u.spr = s
	u.add_child(s)
	u._base_y = 1.3
	# 腳下識別環
	var ring := MeshInstance3D.new()
	ring.name = "Ring"
	var tor := TorusMesh.new()
	tor.inner_radius = 0.62
	tor.outer_radius = 0.72
	ring.mesh = tor
	ring.position.y = 0.06
	var rm := StandardMaterial3D.new()
	rm.albedo_color = Color(0.36, 0.61, 1.0) if is_player else Color(1.0, 0.42, 0.35)
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = rm
	u.add_child(ring)
	# 接觸陰影（橢圓暗影，讓立繪站得住）
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
	return u

func move_to(p: Vector3) -> void:
	_shoot_target = null
	_move_target = Vector3(p.x, 0.0, p.z)

func shoot_at(target: Unit) -> void:
	_move_target = null
	_shoot_target = target
	_shoot_timer = 0.3

func _process(delta: float) -> void:
	_t += delta
	# 立繪待機微浮動（有生命感，不是死圖）
	if spr:
		spr.position.y = _base_y + sin(_t * 2.2) * 0.04
		# 開火閃縮（後座感）
		if _fire_flash > 0.0:
			_fire_flash -= delta * 4.0
			var k: float = max(0.0, _fire_flash)
			spr.position.x = -0.12 * k
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
		# 移動時輕微左右擺（步行感）
		if spr:
			spr.position.x = sin(_t * 9.0) * 0.05
