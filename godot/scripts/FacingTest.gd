# FacingTest.gd — 朝向驗證：讓同一個兵往 +X/-X/+Z/-Z 跑，逐張拍，看模型是否面向移動方向。
# 這是補上「移動朝向」的隔離驗證（過去 selftest 只拍靜態，漏掉此類 bug）。
extends Node3D

var u: Unit

func _ready() -> void:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.5, 0.6, 0.4)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.9, 0.92, 0.95)
	e.ambient_light_energy = 0.8
	var we := WorldEnvironment.new()
	we.environment = e
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 40, 0)
	add_child(sun)
	# 地面格線參考
	var g := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(20, 20)
	g.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.45, 0.55, 0.35)
	g.material_override = gm
	add_child(g)
	# 方向標記：+X 紅、+Z 藍柱
	_marker(Vector3(4, 0, 0), Color(1, 0.2, 0.2))   # +X
	_marker(Vector3(-4, 0, 0), Color(0.8, 0.4, 0.2)) # -X
	_marker(Vector3(0, 0, 4), Color(0.2, 0.4, 1))   # +Z
	_marker(Vector3(0, 0, -4), Color(0.2, 0.8, 1))  # -Z
	var cam := Camera3D.new()
	cam.position = Vector3(0, 2.4, 4.5)
	cam.look_at(Vector3(0,1.0,0), Vector3.UP)
	add_child(cam)
	cam.make_current()
	u = Unit.spawn("res://assets/models/chars/sniper-hero.glb", "sniper", 0, true)
	add_child(u)
	if "selftest" in OS.get_cmdline_user_args():
		_run()

func _marker(p: Vector3, c: Color) -> void:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.15
	cm.bottom_radius = 0.15
	cm.height = 2.0
	mi.mesh = cm
	mi.position = p + Vector3(0, 1, 0)
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = m
	add_child(mi)

func _run() -> void:
	var dirs := {"posX_紅": Vector3(4, 0, 0), "negX_橙": Vector3(-4, 0, 0),
			"posZ_藍": Vector3(0, 0, 4), "negZ_青": Vector3(0, 0, -4)}
	for name in dirs.keys():
		u.global_position = Vector3.ZERO
		u.move_to(dirs[name])
		# 讓它轉身＋跑一小段（約 1 秒）
		for i in 60:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://face_%s.png" % name)
		print("[face] ", name, " pos=", u.global_position, " rotY_deg=", rad_to_deg(u.rotation.y))
	print("[face] DONE")
	get_tree().quit(0)
