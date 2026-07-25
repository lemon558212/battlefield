# ActionTest.gd — 全動作驗收台：把角色的每一個動作各拍一張，並印出關鍵姿勢數據。
# 存在理由：動作是「一整組」的，只驗其中一兩支，改 A 弄壞 B 不會有人發現。
# ⚠ 一律用「遊戲裡真正的觸發方式」驅動（move_to/shoot_at/take_hit/perform…），
#   不可直接呼叫 _play——那會被 Unit 自己的狀態機每幀打回 idle，測出來全是假的待機姿。
extends Node3D

const MODEL := "res://assets/models/chars/hr_m_Soldier.fbx"
const CLS := "rifleman"

var _cam: Camera3D
var _u: Unit
var _dummy: Unit

func _ready() -> void:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.55, 0.66, 0.78)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.85
	var we := WorldEnvironment.new(); we.environment = e; add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 35, 0); sun.shadow_enabled = true; add_child(sun)
	var g := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(60, 60); g.mesh = pm
	var gm := StandardMaterial3D.new(); gm.albedo_color = Color(0.55, 0.68, 0.38)
	g.material_override = gm
	add_child(g)
	_cam = Camera3D.new(); add_child(_cam); _cam.make_current()
	_run()

# ⚠ 一律用「秒」等待，不可用幀數：這個驗收台跑到 200+ FPS，
#   數幀等於等不到——先前 shoot 一直拍到舉槍前的那一格就是這個原因。
func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout

func _shot(name_: String, note: String) -> void:
	_cam.position = _u.global_position + Vector3(2.6, 1.25, 2.6)
	_cam.look_at(_u.global_position + Vector3(0, 0.95, 0), Vector3.UP)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://act_%s.png" % name_)
	print("[act] %-14s %-12s state=%-11s %s" % [name_, note, _u._state, _metrics()])

func _run() -> void:
	_u = Unit.spawn(MODEL, CLS, 0, true)
	add_child(_u)
	_dummy = Unit.spawn(MODEL, "rifleman", 1, false)
	add_child(_dummy)
	_dummy.global_position = Vector3(0, 0, 12)
	await _wait(0.67)

	await _shot("idle", "待機持槍")
	_u.perform("idle_relaxed", 1.2)
	await _wait(0.75)
	await _shot("idle_relaxed", "赤手待機")
	await _wait(1.00)

	# 走/跑：連拍三格才看得出腳在動、有沒有滑步
	_u.move_to(Vector3(0, 0, 9))
	await _wait(0.50)
	for f in 3:
		await _shot("run_%d" % f, "跑(第%d格)" % f)
		await _wait(0.15)
	_u.stop()
	_u.global_position = Vector3.ZERO
	await _wait(0.33)

	# 蹲姿與蹲行（掩體區內小幅移動）
	_u.want_cover = true
	await _wait(1.17)
	await _shot("crouch", "蹲姿")
	_u.move_to(Vector3(0, 0, 2.5))
	await _wait(0.50)
	for f in 3:
		await _shot("crouch_walk_%d" % f, "蹲行(第%d格)" % f)
		await _wait(0.15)
	_u.stop()
	_u.global_position = Vector3.ZERO
	_u.want_cover = false
	await _wait(0.67)

	# 趴姿
	_u.want_prone = true
	await _wait(1.50)
	await _shot("prone", "臥射")
	_u.want_prone = false
	await _wait(1.00)

	# 瞄準 → 射擊 → 換彈（連打三發觸發換彈）
	for i in 3:
		_u.shoot_at(_dummy)
		await _wait(0.17)
		if i == 0:
			await _shot("aim", "舉槍瞄準")      # shoot_at 先舉槍 0.3s
		await _wait(0.22)
		if i == 0:
			await _shot("shoot", "射擊(後座力最大的那一格)")
		await _wait(0.75)
	await _wait(0.80)
	await _shot("reload", "換彈匣")             # 第 3 發打完自動接換彈
	await _wait(2.33)

	# 工兵修理/治療、佔領據點
	_u.perform("fix")
	await _wait(0.67)
	await _shot("fix", "工兵修理/治療")
	await _wait(3.33)
	_u.perform("capture")
	await _wait(0.67)
	await _shot("capture", "佔領據點")
	await _wait(1.50)

	# 受擊 → 陣亡
	_u.take_hit()
	await _wait(0.20)
	await _shot("hit", "受擊")
	await _wait(0.67)
	_u.die()
	await _wait(1.60)      # 再晚就被淡出移除了（die 後約 2.4s 自我 queue_free）
	await _shot("death", "陣亡")
	print("[act] DONE")
	get_tree().quit(0)

# 關鍵數據：頭/手/腳的高度與前後位置。動作有沒有真的在動，看數字最準。
func _metrics() -> String:
	var sks := _u.find_children("*", "Skeleton3D", true, false)
	if sks.is_empty():
		return ""
	var sk := sks[0] as Skeleton3D
	var out := []
	for b in ["Head", "Hand.R", "Hand.L", "Foot.L", "Foot.R"]:
		var i := sk.find_bone(b)
		if i < 0:
			continue
		var p: Vector3 = (sk.global_transform * sk.get_bone_global_pose(i).origin) - _u.global_position
		out.append("%s(y%.2f z%+.2f)" % [b, p.y, p.z])
	return " ".join(out)
