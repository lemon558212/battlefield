# PoseProbe.gd — 重定向對照台：左邊＝UAL 來源真人動作本尊，右邊＝重定向到 hr_ 骨架的結果。
# 用途：蹲姿轉印後變形時，先分清楚是「來源動作本來就長這樣」還是「重定向算錯」。
# 不走 Unit.spawn，直接拿骨架對骨架，排除持槍/IK/貼地等其他干擾。
extends Node3D

const RIG := preload("res://scripts/Retarget.gd")
const UAL := "res://assets/models/anims/ual_standard.glb"
const DST := "res://assets/models/chars/hr_m_Soldier.fbx"
const CLIPS := ["Crouch_Idle", "Pistol_Idle", "Crouch_Fwd"]

var _cam: Camera3D
var _src: Node3D
var _dst: Node3D
var _ssk: Skeleton3D
var _dsk: Skeleton3D
var _ap: AnimationPlayer
var _rig = null
var _on := false

func _ready() -> void:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.55, 0.66, 0.78)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 1.0
	var we := WorldEnvironment.new(); we.environment = e; add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 30, 0); sun.shadow_enabled = true; add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(20, 20)
	ground.mesh = pm
	var gm := StandardMaterial3D.new(); gm.albedo_color = Color(0.42, 0.52, 0.34)
	ground.material_override = gm
	add_child(ground)
	_cam = Camera3D.new(); add_child(_cam); _cam.make_current()
	_run()

func _run() -> void:
	_src = (load(UAL) as PackedScene).instantiate()
	add_child(_src)
	_src.position = Vector3(-1.1, 0, 0)
	_ap = _src.find_children("*", "AnimationPlayer", true, false)[0]
	_ssk = _src.find_children("*", "Skeleton3D", true, false)[0]

	_dst = (load(DST) as PackedScene).instantiate()
	add_child(_dst)
	_dst.position = Vector3(1.1, 0, 0)
	_dsk = _dst.find_children("*", "Skeleton3D", true, false)[0]

	await get_tree().process_frame
	_dump_rest()
	_dump_tree(_ssk, "SRC")
	_dump_tree(_dsk, "DST")
	_rig = RIG.new()
	print("[probe] pairs=", _rig.setup(_ssk, _dsk))
	_on = true

	for clip in CLIPS:
		if not _ap.has_animation(clip):
			print("[probe] 缺片段 ", clip); continue
		_ap.play(clip)
		_ap.seek(0.7, true)
		for i in 8:
			await get_tree().process_frame
		_dump_pose(clip)
		for shot in [["front", Vector3(0, 1.2, 4.2)], ["side", Vector3(4.2, 1.2, 0.0)]]:
			_cam.position = shot[1]
			_cam.look_at(Vector3(0, 0.9, 0), Vector3.UP)
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("res://p_%s_%s.png" % [clip, shot[0]])
		print("[probe] shot ", clip)
	print("[probe] DONE")
	get_tree().quit(0)

func _process(_d: float) -> void:
	if _on and _rig != null:
		_rig.apply()

# 骨架階層攤開：重定向出錯十次有九次是「父子關係跟想的不一樣」（腳骨掛 Root 就是前例）。
func _dump_tree(sk: Skeleton3D, tag: String) -> void:
	var lines := []
	for i in sk.get_bone_count():
		var p := sk.get_bone_parent(i)
		lines.append("%s<%s" % [sk.get_bone_name(i), "-" if p < 0 else sk.get_bone_name(p)])
	print("[tree] ", tag, " n=", sk.get_bone_count(), " ", " ".join(lines))

# 姿勢數據對照：來源動作本身的骨骼世界座標 vs 重定向後目標的骨骼世界座標。
# 只看圖會被透視騙，數字才分得出「來源就是這樣」與「轉印算錯」。
func _dump_pose(clip: String) -> void:
	var sp := {}
	for b in ["pelvis", "spine_03", "thigh_l", "calf_l", "foot_l"]:
		var i := _ssk.find_bone(b)
		sp[b] = (_ssk.global_transform * _ssk.get_bone_global_pose(i).origin) - _src.position
	var dp := {}
	for b in ["Hips", "Chest", "UpperLeg.L", "LowerLeg.L", "Foot.L"]:
		var i := _dsk.find_bone(b)
		dp[b] = (_dsk.global_transform * _dsk.get_bone_global_pose(i).origin) - _dst.position
	var s_lean: Vector3 = sp["spine_03"] - sp["pelvis"]
	var d_lean: Vector3 = dp["Chest"] - dp["Hips"]
	print("[pose] %s\n  SRC 髖=%.2f/%.2f 膝=%.2f/%.2f 踝=%.2f/%.2f 軀幹傾角=%.0f°\n  DST 髖=%.2f/%.2f 膝=%.2f/%.2f 踝=%.2f/%.2f 軀幹傾角=%.0f°" % [
		clip,
		sp["pelvis"].y, sp["pelvis"].z, sp["calf_l"].y, sp["calf_l"].z, sp["foot_l"].y, sp["foot_l"].z,
		rad_to_deg(atan2(s_lean.z, s_lean.y)),
		dp["Hips"].y, dp["Hips"].z, dp["LowerLeg.L"].y, dp["LowerLeg.L"].z, dp["Foot.L"].y, dp["Foot.L"].z,
		rad_to_deg(atan2(d_lean.z, d_lean.y))])

# 兩具骨架的 rest 世界朝向對照：軸向不同時重定向會整個歪掉，先把數據攤開。
func _dump_rest() -> void:
	print("[probe] src xf=", _ssk.global_transform)
	print("[probe] dst xf=", _dsk.global_transform)
	for pair in [["pelvis", "Hips"], ["spine_01", "Abdomen"], ["thigh_l", "UpperLeg.L"], ["calf_l", "LowerLeg.L"], ["foot_l", "Foot.L"]]:
		var si := _ssk.find_bone(pair[0])
		var di := _dsk.find_bone(pair[1])
		if si < 0 or di < 0:
			print("[probe] 找不到 ", pair); continue
		var sw: Transform3D = _ssk.global_transform * _ssk.get_bone_global_rest(si)
		var dw: Transform3D = _dsk.global_transform * _dsk.get_bone_global_rest(di)
		print("[probe] %s src_org=%s src_y=%s | dst_org=%s dst_y=%s" % [
			pair[0], sw.origin, sw.basis.y.normalized(), dw.origin, dw.basis.y.normalized()])
