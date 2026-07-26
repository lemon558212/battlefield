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
	"mg": "res://assets/models/chars/rifleman.glb",
	"at": "res://assets/models/chars/at.glb",
	"sam": "res://assets/models/chars/sam.glb",
	"mortar": "res://assets/models/chars/mortar.glb",
	"rifleman": "res://assets/models/chars/specops.glb",
}
func _run() -> void:
	for cls in HERO.keys():
		var u := Unit.spawn(HERO[cls], cls, 0, true)
		add_child(u)
		u.global_position = Vector3.ZERO
		u.rotation.y = 0.0
		await get_tree().create_timer(0.3).timeout
		_cam.position = Vector3(0, 1.1, 2.7)
		_cam.look_at(Vector3(0, 0.95, 0), Vector3.UP)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(_qa_path("res://cat_%s.png" % cls))
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

# 截圖統一收進 res://qa/（專案根目錄不再堆截圖）。呼叫端照舊給 "res://xxx.png"。
func _qa_path(p: String) -> String:
	if not p.begins_with("res://") or p.trim_prefix("res://").contains("/"):
		return p
	DirAccess.make_dir_recursive_absolute("res://qa/")
	return "res://qa/" + p.trim_prefix("res://")
