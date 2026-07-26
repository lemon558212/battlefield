# BuildingTest.gd — 可進入建築驗收台（GDD/14 §5 [buildingchk]）。
# 驗四件事：外觀合理、室內真的有空間、門是唯一進出點（牆擋得住人）、牆擋視線。
extends Node3D

const BUILDING := preload("res://scripts/Building.gd")
var _cam: Camera3D
var _bd
var _u: Unit

func _ready() -> void:
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.35
	e.ssao_enabled = true
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	var we := WorldEnvironment.new(); we.environment = e; add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-46, 128, 0); sun.shadow_enabled = true; add_child(sun)
	var g := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(120, 120); g.mesh = pm
	var gm := StandardMaterial3D.new(); gm.albedo_color = Color(0.30, 0.40, 0.18)
	g.material_override = gm
	add_child(g)
	_cam = Camera3D.new(); add_child(_cam); _cam.make_current()
	_run()

func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout

func _shot(nm: String, eye: Vector3, look: Vector3) -> void:
	_cam.position = look + eye
	_cam.look_at(look, Vector3.UP)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_qa_path("res://bld_%s.png" % nm))
	print("[bld] saved ", nm)

func _run() -> void:
	_bd = BUILDING.new()
	add_child(_bd)
	# 地圖中心當原點：sdef 用 px，這裡直接給一個 200x160px（10x8m）的方框
	_bd.build({"x": 380.0, "y": 420.0, "w": 200.0, "h": 160.0}, 0.05, 960.0, 600.0, 0.0, 2)
	print("[bld] 牆段=%d 門=%d 窗=%d 樓層=%d" % [_bd.walls.size(), _bd.doors.size(),
			_bd.windows.size(), _bd.floors])
	_u = Unit.spawn("res://assets/models/chars/hr_m_Soldier.fbx", "rifleman", 0, true)
	add_child(_u)
	var c: Vector2 = _bd.rect.get_center()
	var door: Vector2 = _bd.doors[0] if _bd.doors.size() > 0 else c
	_u.global_position = Vector3((door.x - 480.0) * 0.05, 0, (door.y - 300.0) * 0.05 + 3.0)
	await _wait(0.8)
	var bc := Vector3((c.x - 480.0) * 0.05, 0, (c.y - 300.0) * 0.05)
	await _shot("outside", Vector3(11, 7, 13), bc + Vector3(0, 2, 0))
	await _shot("door", Vector3(0.2, 1.7, 9.5), bc + Vector3(0, 1.2, 0))
	# 屋頂淡出後拍室內
	_bd.set_roof_alpha(0.0)
	await _wait(0.3)
	await _shot("inside", Vector3(0.5, 6.5, 6.0), bc + Vector3(0, 1.0, 0))
	_bd.set_roof_alpha(1.0)
	print("[bld] DONE")
	get_tree().quit(0)

# 截圖統一收進 res://qa/（專案根目錄不再堆截圖）。呼叫端照舊給 "res://xxx.png"。
func _qa_path(p: String) -> String:
	if not p.begins_with("res://") or p.trim_prefix("res://").contains("/"):
		return p
	DirAccess.make_dir_recursive_absolute("res://qa/")
	return "res://qa/" + p.trim_prefix("res://")
