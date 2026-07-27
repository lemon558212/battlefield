# ArmShot.gd — 手臂特寫：同一角色、同一姿勢，四個角度各拍一張大圖。
# 目的：肉眼判定「手臂到底在不在畫面上」，不靠任何間接指標（量錯維度＝白修的教訓）。
extends Node3D

const MODEL := "res://assets/models/chars/hr_m_Soldier.fbx"
const CLS := "rifleman"

var _cam: Camera3D
var _u: Unit

func _ready() -> void:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.20, 0.55, 0.30)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 1.0
	var we := WorldEnvironment.new(); we.environment = e; add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0); add_child(sun)
	_cam = Camera3D.new(); add_child(_cam); _cam.make_current()
	_run()

func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout

func _shot(tag: String, ang: float, h: float, dist: float) -> void:
	var c := _u.global_position + Vector3(sin(ang), 0, cos(ang)) * dist + Vector3(0, h, 0)
	_cam.position = c
	_cam.look_at(_u.global_position + Vector3(0, 1.28, 0), Vector3.UP)
	_cam.fov = 32.0
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://qa/")
	get_viewport().get_texture().get_image().save_png("res://qa/armshot_%s.png" % tag)
	print("[armshot] saved ", tag)

# 把骨頭畫成小球疊在模型上：肉眼直接比對「骨頭在哪」與「肉在哪」。
const BONE_DOTS := {
	"Shoulder.L": Color(1, 0, 0), "UpperArm.L": Color(1, 0.5, 0), "LowerArm.L": Color(1, 1, 0), "Hand.L": Color(0, 1, 0),
	"Shoulder.R": Color(0, 0.4, 1), "UpperArm.R": Color(0, 1, 1), "LowerArm.R": Color(1, 0, 1), "Hand.R": Color(1, 1, 1),
	"Index2.L": Color(0, 0, 0), "Middle4.L": Color(0.5, 0, 0.5), "Thumb2.L": Color(0.2, 0.2, 0.2),
}
var _dots := {}

func _mark_bones() -> void:
	if not OS.get_cmdline_user_args().has("dots"):
		return                       # 骨頭小球會蓋住肉，預設關閉；要看骨頭時加 -- dots
	var sks := _u.find_children("*", "Skeleton3D", true, false)
	if sks.is_empty():
		return
	var sk := sks[0] as Skeleton3D
	var line := []
	for bn in BONE_DOTS.keys():
		var bi := sk.find_bone(bn)
		if bi < 0:
			continue
		var p: Vector3 = sk.global_transform * sk.get_bone_global_pose(bi).origin
		if not _dots.has(bn):
			var d := MeshInstance3D.new()
			var sm := SphereMesh.new(); sm.radius = 0.028; sm.height = 0.056
			d.mesh = sm
			var mm := StandardMaterial3D.new()
			mm.albedo_color = BONE_DOTS[bn]
			mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mm.no_depth_test = true
			d.material_override = mm
			add_child(d)
			_dots[bn] = d
		(_dots[bn] as MeshInstance3D).global_position = p
		line.append("%s(%.2f,%.2f,%.2f)" % [bn, p.x, p.y, p.z])
	print("[bones] ", " ".join(line))
	# 每根骨「相對 rest 的 local 旋轉角」：接近 180° 就是線性混合蒙皮會塌陷的區間
	var l2 := []
	for bn in ["Shoulder.L", "UpperArm.L", "LowerArm.L", "Hand.L",
			"Shoulder.R", "UpperArm.R", "LowerArm.R", "Hand.R"]:
		var bi := sk.find_bone(bn)
		if bi < 0:
			continue
		var q: Quaternion = sk.get_bone_pose_rotation(bi) \
				* sk.get_bone_rest(bi).basis.get_rotation_quaternion().inverse()
		l2.append("%s=%.0f°" % [bn, rad_to_deg(2.0 * acos(clampf(absf(q.normalized().w), 0.0, 1.0)))])
	print("[delta] ", " ".join(l2))
	# 全骨座標：用來找「肉跑到那裡、卻沒有任何骨頭在那裡」的骨頭
	var l3 := []
	for i in sk.get_bone_count():
		var p3: Vector3 = sk.global_transform * sk.get_bone_global_pose(i).origin
		l3.append("%s(%.2f,%.2f,%.2f)" % [sk.get_bone_name(i), p3.x, p3.y, p3.z])
	print("[allbones] ", " ".join(l3))
	# rest basis 的行列式與縮放：負行列式＝鏡像骨，get_rotation_quaternion() 會失真
	var l4 := []
	for bn in ["Shoulder.L", "UpperArm.L", "LowerArm.L", "Hand.L",
			"Shoulder.R", "UpperArm.R", "LowerArm.R", "Hand.R"]:
		var bi := sk.find_bone(bn)
		if bi < 0:
			continue
		var rb := sk.get_bone_rest(bi).basis
		var gb := sk.get_bone_global_pose(bi).basis
		l4.append("%s det_rest=%.3f scale_rest=%s det_pose=%.3f" % [bn, rb.determinant(), rb.get_scale(), gb.determinant()])
	print("[det] ", " | ".join(l4))

func _run() -> void:
	_u = Unit.spawn(MODEL, CLS, 0, true)
	add_child(_u)
	_u.rotation.y = 0.0
	await _wait(1.2)
	_mark_bones()
	# 站姿待機（持槍）
	await _shot("front", PI, 1.35, 2.6)
	await _shot("right", PI * 0.5, 1.35, 2.6)
	await _shot("back", 0.0, 1.35, 2.6)
	await _shot("left", -PI * 0.5, 1.35, 2.6)
	await _shot("top", PI * 0.75, 3.2, 2.4)
	print("[armshot] DONE")
	get_tree().quit(0)
