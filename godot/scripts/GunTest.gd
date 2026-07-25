# GunTest.gd — 持槍品質驗證台：可愛風軍事角色 + 真人動作(重定向) + 兵種武器。
# 有地面與刻度桿可判斷浮空/陷地/比例；武器依實際網格尺寸自動校正，不再共用同一組數值。
extends Node3D

const RetargetLib := preload("res://scripts/Retarget.gd")
const ANIMS := "res://assets/models/anims/ual_standard.glb"

# 每個兵種：角色模型 / 武器網格 / 該武器真實長度(公尺)
const CASES := [
	["rifleman", "res://assets/models/chars/hr_soldier.fbx", "res://assets/models/weapons/AssaultRifle_1.obj", 0.90],
	["sniper", "res://assets/models/chars/hr_swat.fbx", "res://assets/models/weapons/SniperRifle_1.obj", 1.25],
]
const POSES := ["Pistol_Idle", "Pistol_Aim_Neutral", "Pistol_Shoot", "Crouch_Idle", "Walk"]
const GRIP_RATIO := 0.30   # 握把位於槍身後端往前 30% 處

const AIM_POSES := ["Pistol_Aim_Neutral", "Pistol_Shoot"]
# 瞄準俯仰驗證：高處/水平/低處三個目標（角色在原點、面向 +Z）
const AIM_TARGETS := [["_hi", Vector3(0, 3.4, 5.0)], ["_lv", Vector3(0, 1.2, 5.0)], ["_lo", Vector3(0, -0.6, 5.0)]]

var _cam: Camera3D

# 擺放武器。aiming=true 時槍托抵右肩、槍口朝角色正前方（免費動作庫沒有步槍抵肩姿，故用程式補）；
# 否則沿用「貼右手」的持槍法（行走/待機時槍自然垂放）。
func _place_gun(gun: MeshInstance3D, sk: Skeleton3D, model: Node3D, aiming: bool,
		mesh_scale: float, grip: Vector3, stock: Vector3, aim_target: Vector3 = Vector3.INF) -> void:
	var scl := Vector3.ONE * mesh_scale
	if aiming:
		var si := sk.find_bone("Shoulder.R")
		if si < 0:
			return
		var shoulder: Vector3 = sk.global_transform * sk.get_bone_global_pose(si).origin
		# 槍口指向目標點（含俯仰角）；未指定目標時退回角色正前方水平
		var pocket0: Vector3 = shoulder - Vector3.UP * 0.06
		var aim: Vector3 = model.global_basis.z.normalized()
		if aim_target.x < INF:
			aim = (aim_target - pocket0).normalized()
		var x_axis := aim
		var up_ref := Vector3.UP
		if absf(x_axis.dot(up_ref)) > 0.97:
			up_ref = model.global_basis.z.normalized()
		var z_axis := x_axis.cross(up_ref).normalized()
		var y_axis := z_axis.cross(x_axis).normalized()
		var b := Basis(x_axis * mesh_scale, y_axis * mesh_scale, z_axis * mesh_scale)
		# 抵肩點稍微內收、略低於肩，才像貼在肩窩而不是浮在肩上
		var pocket: Vector3 = pocket0 + aim * 0.02
		gun.global_transform = Transform3D(b, pocket - b * stock)
	else:
		var hi := sk.find_bone("Hand.R")
		if hi < 0:
			return
		var hand: Transform3D = sk.global_transform * sk.get_bone_global_pose(hi)
		hand.basis = hand.basis.orthonormalized()
		var r := Basis.from_euler(Vector3(0, 0, deg_to_rad(90)))
		gun.global_transform = Transform3D(hand.basis * (r.scaled(scl)), hand.origin - (hand.basis * r * grip) * mesh_scale)

func _ready() -> void:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.55, 0.66, 0.78)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.9
	var we := WorldEnvironment.new(); we.environment = e; add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, 35, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)
	# 地面：判斷浮空/陷地的基準
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(12, 12)
	ground.mesh = pm
	var gmat := StandardMaterial3D.new(); gmat.albedo_color = Color(0.42, 0.52, 0.34)
	ground.material_override = gmat
	add_child(ground)
	# 0.5m 一節的刻度桿：比例合理性參照（總高 1.5m）
	for i in 3:
		var rod := MeshInstance3D.new()
		var bm := BoxMesh.new(); bm.size = Vector3(0.05, 0.5, 0.05)
		rod.mesh = bm
		var rmat := StandardMaterial3D.new()
		rmat.albedo_color = Color(0.92, 0.92, 0.92) if i % 2 == 0 else Color(0.15, 0.15, 0.15)
		rod.material_override = rmat
		rod.position = Vector3(-1.0, 0.25 + i * 0.5, 0)
		add_child(rod)
	_cam = Camera3D.new(); add_child(_cam); _cam.make_current()
	_run()

func _run() -> void:
	for case in CASES:
		var cls: String = case[0]
		var src := (load(ANIMS) as PackedScene).instantiate()
		add_child(src)
		src.position = Vector3(0, 0, -80)
		for mi in src.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).visible = false
		var ap := (src.find_children("*", "AnimationPlayer", true, false)[0]) as AnimationPlayer
		var sk_src := (src.find_children("*", "Skeleton3D", true, false)[0]) as Skeleton3D

		var model := (load(case[1]) as PackedScene).instantiate()
		add_child(model)
		model.global_position = Vector3.ZERO
		var sk_dst := (model.find_children("*", "Skeleton3D", true, false)[0]) as Skeleton3D

		var rt := RetargetLib.new()
		print("[gt] ", cls, " pairs=", rt.setup(sk_src, sk_dst))

		# 槍掛在模型底下（不綁手骨），由程式擺位：
		# 瞄準時架上肩窩、非瞄準時貼右手，兩者都再用 IK 把手抓上去。
		var gun := MeshInstance3D.new()
		gun.mesh = load(case[2])
		model.add_child(gun)
		await get_tree().process_frame
		var ab: AABB = gun.get_aabb()
		var raw_len: float = ab.size.x
		var mesh_scale: float = float(case[3]) / raw_len
		# 握把柄（右手）、前護木（左手）、槍托末端（抵肩點）
		var grip := Vector3(ab.position.x + GRIP_RATIO * raw_len, ab.position.y + 0.46 * ab.size.y, ab.get_center().z)
		var fore := Vector3(ab.position.x + 0.58 * raw_len, ab.position.y + 0.56 * ab.size.y, ab.get_center().z)
		var stock := Vector3(ab.position.x + 0.03 * raw_len, ab.position.y + 0.62 * ab.size.y, ab.get_center().z)
		print("[gt] ", cls, " raw_len=", raw_len, " -> ", case[3], "m  model_scale=", model.global_basis.get_scale())

		for pose in POSES:
			if not ap.has_animation(pose):
				print("[gt] MISSING ", pose); continue
			ap.play(pose); ap.seek(0.4, true); ap.advance(0.0)
			await get_tree().process_frame
			rt.apply()
			await get_tree().process_frame
			for variant in (AIM_TARGETS if pose in AIM_POSES else [["", Vector3.INF]]):
				var tag: String = variant[0]
				rt.apply()   # 每個變體都從乾淨的重定向姿勢起算，避免 IK 疊加
				await get_tree().process_frame
				# 瞄準時上半身與頭跟著俯仰，否則只有槍在動、人直挺挺看前方很假
				if pose in AIM_POSES:
					var eye: Vector3 = model.global_position + Vector3.UP * 1.35
					var av: Vector3 = ((variant[1] as Vector3) - eye).normalized()
					var pitch: float = asin(clampf(av.y, -1.0, 1.0))
					var right: Vector3 = model.global_basis.x.normalized()
					rt.add_world_rotation("Chest", right, -pitch * 0.45)
					rt.add_world_rotation("Head", right, -pitch * 0.40)
					await get_tree().process_frame
				_place_gun(gun, sk_dst, model, pose in AIM_POSES, mesh_scale, grip, stock, variant[1])
				# 兩手抓上槍：右手握把、左手前護木
				var t_grip: Vector3 = gun.global_transform * grip
				var t_fore: Vector3 = gun.global_transform * fore
				rt.ik_reach("UpperArm.R", "LowerArm.R", "Hand.R", t_grip)
				rt.ik_reach("UpperArm.L", "LowerArm.L", "Hand.L", t_fore)
				var hw: Vector3 = sk_dst.global_transform * sk_dst.get_bone_global_pose(sk_dst.find_bone("Hand.R")).origin
				# 手指握攏（軸 0 為此骨架的彎曲軸，掃描驗得）
				rt.curl_fingers(".R", 0, 55.0, 35.0)
				rt.curl_fingers(".L", 0, 55.0, 35.0)
				await get_tree().process_frame
				for shot in [["front", Vector3(1.6, 1.05, 2.2)], ["side", Vector3(3.0, 1.05, 0.0)]]:
					_cam.position = shot[1]
					_cam.look_at(Vector3(0, 0.85, 0), Vector3.UP)
					await get_tree().process_frame
					await RenderingServer.frame_post_draw
					get_viewport().get_texture().get_image().save_png("res://q_%s_%s%s_%s.png" % [cls, pose, tag, shot[0]])
				print("[gt] shot ", cls, " ", pose)

		model.queue_free(); src.queue_free()
		await get_tree().process_frame
	print("[gt] DONE")
	get_tree().quit(0)
