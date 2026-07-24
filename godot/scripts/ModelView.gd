# ModelView.gd — 對照驗證：把「已知正確的通用兵」與「英雄」並排，
# 兩者都用 Unit.spawn（會套 _forward_fix）、給相同 rotation.y，從 +Z 拍。
# 兩個都露正臉 ⇒ 英雄的正面軸與通用兵一致 ⇒ 朝向邏輯對兩者都成立。
extends Node3D

var _cam: Camera3D

func _ready() -> void:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.55, 0.62, 0.45)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 1.3
	var we := WorldEnvironment.new(); we.environment = e; add_child(we)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-40, 10, 0); add_child(sun)
	_cam = Camera3D.new(); add_child(_cam); _cam.make_current()
	if "selftest" in OS.get_cmdline_user_args():
		_run()

func _run() -> void:
	var soldier := Unit.spawn("res://assets/models/chars/soldier.glb", "rifleman", 0, true)
	add_child(soldier)
	soldier.global_position = Vector3(-1.1, 0, 0)
	var hero := Unit.spawn("res://assets/models/chars/sniper-hero.glb", "sniper", 0, true)
	add_child(hero)
	hero.global_position = Vector3(1.1, 0, 0)
	# 四種朝向各拍一張：0=面向+Z(朝鏡頭)、90=+X(右)、180=-Z(背對)、-90=-X(左)
	for d in [0.0, 90.0, 180.0, -90.0]:
		soldier.rotation.y = deg_to_rad(d)
		hero.rotation.y = deg_to_rad(d)
		_cam.position = Vector3(0, 1.5, 4.6)
		_cam.look_at(Vector3(0, 0.95, 0), Vector3.UP)
		await get_tree().process_frame
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://cmp_%d.png" % int(d))
		print("[cmp] yaw=", d)
	print("[cmp] DONE (左=通用兵已驗證正確, 右=英雄)")
	get_tree().quit(0)
