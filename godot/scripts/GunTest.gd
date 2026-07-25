# GunTest.gd — 實機持槍驗收：走真實的 Unit.spawn 路徑（與戰場同一條程式），
# 從正面/側面/斜角三個角度拍，避免「槍正對鏡頭」造成的透視誤判。
extends Node3D

const CASES := [
	["sniper", "res://assets/models/chars/soldier.glb"],
	["rifleman", "res://assets/models/chars/specops.glb"],
	["mg", "res://assets/models/chars/rifleman.glb"],
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
		for i in 30:
			await get_tree().process_frame
		for shot in [["front", Vector3(0, 1.15, 2.8)], ["side", Vector3(2.8, 1.15, 0.0)], ["q", Vector3(2.0, 1.5, 2.0)]]:
			_cam.position = shot[1]
			_cam.look_at(Vector3(0, 0.95, 0), Vector3.UP)
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("res://u_%s_%s.png" % [cls, shot[0]])
		print("[u] shot ", cls)
		u.queue_free()
		await get_tree().process_frame
	print("[u] DONE")
	get_tree().quit(0)
