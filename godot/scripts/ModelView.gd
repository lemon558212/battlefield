# ModelView.gd — 人物模型對照表：把所有可用內建模型各拍一張正面，供挑選角色基底。
extends Node3D

var _cam: Camera3D
var models: Array[String] = []

func _ready() -> void:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.62, 0.68, 0.55)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 1.25
	var we := WorldEnvironment.new(); we.environment = e; add_child(we)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-38, 15, 0); add_child(sun)
	_cam = Camera3D.new(); add_child(_cam); _cam.make_current()
	if "selftest" in OS.get_cmdline_user_args():
		_run()

const HERO := {
	"sniper": "res://assets/models/chars/soldier.glb",
	"rifleman": "res://assets/models/chars/specops.glb",
	"engineer": "res://assets/models/chars/engineer.glb",
	"mg": "res://assets/models/chars/rifleman.glb",
}
func _run() -> void:
	for cls in HERO.keys():
		var u := Unit.spawn(HERO[cls], cls, 0, true)   # 走遊戲實際路徑(含換裝)
		add_child(u)
		u.global_position = Vector3.ZERO
		u.rotation.y = 0.0
		await get_tree().create_timer(0.25).timeout
		_cam.position = Vector3(0, 1.05, 3.1)
		_cam.look_at(Vector3(0, 0.9, 0), Vector3.UP)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://cat_%s.png" % cls)
		print("[cat] ", cls)
		u.queue_free()
		await get_tree().process_frame
	print("[cat] DONE")
	get_tree().quit(0)

func _aabb(node: Node) -> AABB:
	var out := AABB(); var first := true
	for mm in node.find_children("*", "MeshInstance3D", true, false):
		var mi := mm as MeshInstance3D
		var b: AABB = mi.transform * mi.get_aabb()
		if first: out = b; first = false
		else: out = out.merge(b)
	return out
