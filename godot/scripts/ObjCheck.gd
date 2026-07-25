# ObjCheck.gd — 驗證 glb2obj 轉出的 OBJ 網格是否完好（上傳 Mixamo 前的把關）
extends Node3D
var _cam: Camera3D
func _ready() -> void:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.2, 0.23, 0.28)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 1.2
	var we := WorldEnvironment.new(); we.environment = e; add_child(we)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-45, 35, 0); add_child(sun)
	_cam = Camera3D.new(); add_child(_cam); _cam.make_current()
	if "selftest" in OS.get_cmdline_user_args():
		_run()
func _run() -> void:
	var p := "res://assets/tmp_objcheck/sniper_hanmushuang.obj"
	if not ResourceLoader.exists(p):
		print("[obj] MISSING ", p); get_tree().quit(1); return
	var mesh := load(p)
	var mi := MeshInstance3D.new(); mi.mesh = mesh; add_child(mi)
	var ab: AABB = mi.get_aabb()
	print("[obj] aabb pos=", ab.position, " size=", ab.size)
	var k: float = 1.8 / max(0.001, ab.size.y)
	mi.scale = Vector3.ONE * k
	mi.position = -Vector3(ab.position.x + ab.size.x*0.5, ab.position.y, ab.position.z + ab.size.z*0.5) * k
	for v in [["front", Vector3(0,1.1,3.4)], ["side", Vector3(3.4,1.1,0)]]:
		_cam.position = v[1]; _cam.look_at(Vector3(0,0.9,0), Vector3.UP)
		await get_tree().process_frame
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://objchk_%s.png" % v[0])
		print("[obj] saved ", v[0])
	get_tree().quit(0)
