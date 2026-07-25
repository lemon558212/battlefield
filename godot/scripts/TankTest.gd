# TankTest.gd — 載具驗收台：坦克外觀（四視角）、砲塔轉向、行進、開火後座、被擊毀。
# 存在理由：坦克沒有現成模型是程式生成的，比例與剪影只能看圖判斷；
# 而「砲塔會不會轉向目標」「開火有沒有後座」這種動態行為，靜態圖看不出來，要連拍。
extends Node3D

const MODEL := ""          # 載具不吃模型檔，Unit 內程式生成
var _cam: Camera3D
var _tank: Unit
var _foe: Unit

func _ready() -> void:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.55, 0.66, 0.78)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.9
	var we := WorldEnvironment.new(); we.environment = e; add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 35, 0); sun.shadow_enabled = true; add_child(sun)
	var g := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(80, 80); g.mesh = pm
	var gm := StandardMaterial3D.new(); gm.albedo_color = Color(0.55, 0.68, 0.38)
	g.material_override = gm
	add_child(g)
	_cam = Camera3D.new(); add_child(_cam); _cam.make_current()
	_run()

func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout

func _shot(nm: String, note: String, eye: Vector3, look: Vector3) -> void:
	_cam.position = look + eye
	_cam.look_at(look, Vector3.UP)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://tank_%s.png" % nm)
	print("[tank] %-12s %s %s" % [nm, note, _metrics()])

func _metrics() -> String:
	var t := _tank.get_node_or_null("Vehicle/Turret")
	var yaw := 0.0
	if t:
		yaw = rad_to_deg((t as Node3D).rotation.y)
	return "車體朝向=%.0f° 砲塔相對=%.0f° 位置=(%.1f,%.1f)" % [
			rad_to_deg(_tank.rotation.y), yaw, _tank.global_position.x, _tank.global_position.z]

func _run() -> void:
	# 拿一個步兵當比例尺：坦克跟人的相對大小合不合理，一眼就看得出來
	var soldier := Unit.spawn("res://assets/models/chars/hr_m_Soldier.fbx", "rifleman", 0, true)
	add_child(soldier)
	soldier.global_position = Vector3(0, 0, 4.6)   # 擺在車頭正前方，側視時人與車才會同框比大小
	_tank = Unit.spawn("", "tank", 0, true)
	add_child(_tank)
	_foe = Unit.spawn("res://assets/models/chars/hr_m_Soldier.fbx", "rifleman", 1, false)
	add_child(_foe)
	_foe.global_position = Vector3(9.0, 0, 9.0)
	await _wait(1.0)
	print("[tank] 比例尺：步兵高 1.80m（Unit._fit_model 統一），坦克含砲塔高約 2.4m")
	await _shot("side", "側視（左邊步兵當比例尺）", Vector3(9, 3.4, 0), Vector3(0, 1.2, 0))
	await _shot("front", "正視", Vector3(0, 3.0, 10), Vector3(0, 1.2, 0))
	await _shot("q", "斜角", Vector3(7, 5.0, 7), Vector3(0, 1.2, 0))

	# 砲塔轉向：目標在右前方，砲塔應轉過去（車體不動）
	_tank.shoot_at(_foe)
	await _wait(0.45)
	await _shot("turret", "砲塔轉向目標", Vector3(6, 6.0, -6), Vector3(0, 1.2, 0))
	await _wait(0.5)
	await _shot("fire", "開火後座", Vector3(7, 3.2, 3), Vector3(0, 1.5, 0))
	await _wait(1.2)

	# 行進：履帶車先轉正再走
	_tank.move_to(Vector3(0, 0, -14))
	await _wait(1.0)
	await _shot("turn", "轉向中", Vector3(8, 5.0, 8), _tank.global_position + Vector3(0, 1.2, 0))
	await _wait(2.0)
	await _shot("move", "行進中", Vector3(8, 5.0, 8), _tank.global_position + Vector3(0, 1.2, 0))

	# 被擊毀
	_tank.take_hit()
	await _wait(0.4)
	_tank.die()
	await _wait(1.1)
	await _shot("dead", "被擊毀（下沉＋燒焦）", Vector3(8, 3.4, 6), _tank.global_position + Vector3(0, 1.0, 0))
	print("[tank] DONE")
	get_tree().quit(0)
