# GunTest.gd — 實機持槍驗收：走真實的 Unit.spawn 路徑（與戰場同一條程式），
# 從正面/側面/斜角三個角度拍，避免「槍正對鏡頭」造成的透視誤判。
extends Node3D

const CASES := [
	["sniper", "res://assets/models/chars/hr_w_Swat.fbx"],
	["rifleman", "res://assets/models/chars/hr_m_Soldier.fbx"],
	["specops", "res://assets/models/chars/hr_m_SciFi.fbx"],
	# 沒有真實武器模型、靠 _make_gun 程式生成的兵種也要驗（它們原本連瞄準姿都沒有）
	["mg", "res://assets/models/chars/hr_m_Soldier.fbx"],
	["at", "res://assets/models/chars/hr_m_Soldier.fbx"],
	["sam", "res://assets/models/chars/hr_m_Soldier.fbx"],
	["mortar", "res://assets/models/chars/hr_m_Soldier.fbx"],
]

var _cam: Camera3D

func _ready() -> void:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.55, 0.66, 0.78)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.95
	var we := WorldEnvironment.new(); we.environment = e; add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, 35, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(14, 14)
	ground.mesh = pm
	var gmat := StandardMaterial3D.new(); gmat.albedo_color = Color(0.42, 0.52, 0.34)
	ground.material_override = gmat
	add_child(ground)
	_cam = Camera3D.new(); add_child(_cam); _cam.make_current()
	_run()

func _run() -> void:
	for case in CASES:
		var cls: String = case[0]
		var u := Unit.spawn(case[1], cls, 0, true)
		add_child(u)
		u.global_position = Vector3.ZERO
		u.rotation.y = 0.0
		# 站姿與蹲姿都要拍：只拍蹲姿會漏掉「站著時被改壞」（姿勢兩態互相牽動過好幾次）
		for stance in ["stand", "crouch", "prone"]:
			u.want_cover = (stance == "crouch")
			u.want_prone = (stance == "prone")
			for i in (30 if stance == "stand" else 80):
				await get_tree().process_frame
			for shot in [["front", Vector3(0, 1.15, 2.8)], ["side", Vector3(2.8, 1.15, 0.0)], ["q", Vector3(2.0, 1.5, 2.0)]]:
				_cam.position = shot[1]
				_cam.look_at(Vector3(0, 0.95, 0), Vector3.UP)
				await get_tree().process_frame
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(_qa_path("res://u_%s_%s_%s.png" % [cls, stance, shot[0]]))
			_dump(u, cls, stance)
			print("[u] shot ", cls, " ", stance)
		u.queue_free()
		await get_tree().process_frame
	print("[u] DONE")
	get_tree().quit(0)

# 姿勢數據：只看圖會被透視騙（趴姿「腿翹起來」到底翹幾度，量了才知道）
func _dump(u: Unit, cls: String, stance: String) -> void:
	var sks := u.find_children("*", "Skeleton3D", true, false)
	if sks.is_empty():
		return
	var sk := sks[0] as Skeleton3D
	var p := {}
	for b in ["Hips", "Chest", "Head", "UpperLeg.L", "LowerLeg.L", "Foot.L"]:
		var i := sk.find_bone(b)
		p[b] = (sk.global_transform * sk.get_bone_global_pose(i).origin) if i >= 0 else Vector3.ZERO
	var thigh: Vector3 = p["LowerLeg.L"] - p["UpperLeg.L"]
	print("[dump] %s/%s 髖y=%.2f 胸y=%.2f 頭y=%.2f 膝y=%.2f 腳y=%.2f 大腿仰角=%.0f°" % [
		cls, stance, p["Hips"].y, p["Chest"].y, p["Head"].y, p["LowerLeg.L"].y, p["Foot.L"].y,
		rad_to_deg(asin(clampf(thigh.normalized().y, -1.0, 1.0)))])

# 截圖統一收進 res://qa/（專案根目錄不再堆截圖）。呼叫端照舊給 "res://xxx.png"。
func _qa_path(p: String) -> String:
	if not p.begins_with("res://") or p.trim_prefix("res://").contains("/"):
		return p
	DirAccess.make_dir_recursive_absolute("res://qa/")
	return "res://qa/" + p.trim_prefix("res://")
