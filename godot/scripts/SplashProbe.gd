# SplashProbe.gd — 水花近拍驗證台。
# 使用者兩次回報水花假；判斷水花好不好看**只能看渲染出來的圖**，
# 而且要看「連續幾格」——水花是 0.7 秒的動態，單張靜態圖看不出它是不是一團白霧。
extends Node3D

func _ready() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.42, 0.50, 0.60)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.66, 0.74, 0.86)
	e.ambient_light_energy = 0.5
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 120, 0)
	sun.light_energy = 1.2
	add_child(sun)
	# 假水面：深色平面，這樣白色水花的形狀看得最清楚
	var gp := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	gp.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.10, 0.20, 0.26)
	gm.roughness = 0.35
	gp.material_override = gm
	add_child(gp)
	# 比例尺：1.75m 的紅柱，水花不該比人還大
	var ref := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.22
	cap.height = 1.75
	ref.mesh = cap
	var rm := StandardMaterial3D.new()
	rm.albedo_color = Color(0.86, 0.22, 0.18)
	ref.material_override = rm
	ref.position = Vector3(1.4, 0.875, 0)
	add_child(ref)

	var u = Unit.new()
	add_child(u)
	u.global_position = Vector3.ZERO
	var cam := Camera3D.new()
	cam.fov = 46.0
	cam.position = Vector3(0.2, 1.15, 3.4)
	cam.look_at(Vector3(0, 0.35, 0))
	add_child(cam)
	await get_tree().create_timer(0.4).timeout
	# 連拍：水花是 0.7 秒的動態，單張看不出它是不是一團白霧
	u._splash_fx(0.55)
	for i in 6:
		await get_tree().create_timer(0.13).timeout
		var img := get_viewport().get_texture().get_image()
		img.save_png("res://qa/splash_%d.png" % i)
	print("[splashprobe] DONE  qa/splash_0~5.png")
	get_tree().quit(0)
