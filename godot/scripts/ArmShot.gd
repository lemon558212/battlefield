# ArmShot.gd — 手臂特寫：同一角色、同一姿勢，四個角度各拍一張大圖。
# 目的：肉眼判定「手臂到底在不在畫面上」，不靠任何間接指標（量錯維度＝白修的教訓）。
extends Node3D

# 兵種可由指令列指定（使用者實際玩的是狙擊手＝hr_w_Swat＋狙擊槍，
# 用步槍兵驗完就宣稱好過去踩過同樣的坑：「驗證台過 ≠ 遊戲裡對」）。
static func _arg(key: String, dflt: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(key + "="):
			return a.substr(key.length() + 1)
	return dflt

var MODEL := "res://assets/models/chars/%s.fbx" % _arg("model", "hr_m_Soldier")
var CLS := _arg("cls", "rifleman")

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
	# ★連拍：使用者 2026-07-27 回報「跑步手臂與武器在背後、倒下也是、蹲下有一度沒有手臂」。
	#   這三個都是**過程中的某幾格**才出現，靜態擺姿勢一定拍不到。
	#   逐格拍成一排，再由人眼一次看完整段。
	await _seq("run", 10, 0.12, func(dt): _u.move_dir(Vector3(0, 0, 1), dt))
	_u.stop()
	await _wait(0.6)
	_u.want_cover = true                       # 觸發自動蹲：拍「蹲下的過程」
	await _seq("crouch", 12, 0.10, func(_dt): pass)
	_u.want_cover = false
	await _wait(1.2)
	# 使用者回報「蹲下有一度沒有手臂跟武器」。站→蹲拍過沒事，再驗**趴→蹲→站**這條：
	# 遊戲裡狙擊手會先自動臥射，玩家再按 C，走的是這條路徑。
	_u.stance_cmd = "prone"
	await _wait(1.8)
	_u.stance_cmd = "crouch"
	await _seq("p2c", 12, 0.10, func(_dt): pass)
	_u.stance_cmd = "stand"
	await _seq("c2s", 10, 0.10, func(_dt): pass)
	_u.stance_cmd = ""
	await _wait(0.8)
	_u.take_hit()
	await _wait(0.5)
	_u.die()
	await _seq("death", 12, 0.14, func(_dt): pass)
	print("[armshot] DONE")
	get_tree().quit(0)

# 連拍一段：每格之間可以持續驅動（跑步要每幀餵 move_dir，否則第二格就停了）
func _seq(tag: String, n: int, gap: float, tick: Callable) -> void:
	for f in n:
		var t := 0.0
		while t < gap:
			await get_tree().process_frame
			var dt: float = get_process_delta_time()
			t += dt
			tick.call(dt)
		var c := _u.global_position + Vector3(2.9, 1.15, 0.6)
		_cam.position = c
		_cam.look_at(_u.global_position + Vector3(0, 0.95, 0), Vector3.UP)
		_cam.fov = 40.0
		await RenderingServer.frame_post_draw
		DirAccess.make_dir_recursive_absolute("res://qa/")
		get_viewport().get_texture().get_image().save_png("res://qa/seq_%s_%d.png" % [tag, f])
	print("[armshot] seq ", tag, " x", n)
