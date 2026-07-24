# ModelView.gd — 重定向動畫逐格檢視：播指定動畫、跨週期存 N 格，看骨架有無扭曲。
extends Node3D

var _cam: Camera3D
var jobs := [
	["res://assets/models/chars/sniper-hero.glb", "Walk", 5],
	["res://assets/models/chars/sniper-hero.glb", "Idle_Gun_Pointing", 3],
	["res://assets/models/chars/sniper-hero.glb", "Gun_Shoot", 4],
]

func _ready() -> void:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.22, 0.25, 0.3)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 1.15
	var we := WorldEnvironment.new(); we.environment = e; add_child(we)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-45, 25, 0); add_child(sun)
	_cam = Camera3D.new(); add_child(_cam); _cam.make_current()
	if "selftest" in OS.get_cmdline_user_args():
		_run()

func _run() -> void:
	for job in jobs:
		var path: String = job[0]
		var clip: String = job[1]
		var frames: int = job[2]
		if not ResourceLoader.exists(path):
			print("[rt] MISSING ", path); continue
		var m := (load(path) as PackedScene).instantiate()
		add_child(m)
		# 用 Unit 的縮放邏輯不好取，這裡直接固定縮放與相機（模型約 1 單位高）
		m.scale = Vector3.ONE * 1.8
		var aps := m.find_children("*", "AnimationPlayer", true, false)
		if aps.is_empty():
			print("[rt] no AnimationPlayer"); m.queue_free(); continue
		var ap := aps[0] as AnimationPlayer
		if not ap.has_animation(clip):
			print("[rt] missing clip ", clip, " have=", ap.get_animation_list()); m.queue_free(); continue
		var a := ap.get_animation(clip)
		ap.play(clip)
		for i in frames:
			ap.seek(a.length * float(i) / float(frames), true)
			_cam.position = Vector3(1.3, 1.1, 1.9)
			_cam.look_at(Vector3(0, 0.85, 0), Vector3.UP)
			await get_tree().process_frame
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("res://rt_%s_%d.png" % [clip, i])
		print("[rt] ", clip, " x", frames, " len=", a.length)
		m.queue_free()
		await get_tree().process_frame
	print("[rt] DONE")
	get_tree().quit(0)
