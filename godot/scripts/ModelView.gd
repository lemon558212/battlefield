# ModelView.gd — 決定性診斷：用「遊戲實際的 Unit.spawn」生成單位，rotation.y 固定 0，
# 從世界 +Z/+X/-Z/-X 四方位各拍一張。看到「臉」的那張＝模型正面朝的軸。
extends Node3D

var _cam: Camera3D

var models: Array[String] = [
	"res://assets/models/chars/soldier.glb",
	"res://assets/models/chars/sniper-tripo3.glb",
]
var views := [
	["camPosZ", Vector3(0, 1.2, 3.6)],
	["camPosX", Vector3(3.6, 1.2, 0)],
	["camNegZ", Vector3(0, 1.2, -3.6)],
	["camNegX", Vector3(-3.6, 1.2, 0)],
]

func _ready() -> void:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.20, 0.23, 0.27)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 1.1
	var we := WorldEnvironment.new()
	we.environment = e
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.make_current()
	if "selftest" in OS.get_cmdline_user_args():
		_run()

func _run() -> void:
	for mp in models:
		var u := Unit.spawn(mp, "rifleman", 0, true)
		add_child(u)
		u.global_position = Vector3.ZERO
		u.rotation.y = 0.0                     # ★關鍵：轉角固定 0
		var tagm := mp.get_file().get_basename()
		for v in views:
			u.rotation.y = 0.0                 # 每張都確保是 0（避免動畫/邏輯改到）
			_cam.position = v[1]
			_cam.look_at(Vector3(0, 0.95, 0), Vector3.UP)
			await get_tree().process_frame
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("res://fw_%s_%s.png" % [tagm, v[0]])
		print("[fw] ", tagm, " rotY=", u.rotation.y)
		u.queue_free()
		await get_tree().process_frame
	print("[fw] DONE")
	get_tree().quit(0)
