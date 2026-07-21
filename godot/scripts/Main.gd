# Main.gd — P0 驗證場（GDD/13）：地面＋建築＋單位＋戰術相機
# 操作：左鍵點我方兵=選取(跟隨) / 點地=移動 / 點敵兵=開槍；右鍵拖曳=平移；滾輪=縮放
extends Node3D

var cam: TacticalCamera
var units: Array[Unit] = []
var selected: Unit = null
var _tracers: Array = []   # {mesh, ttl}

func _ready() -> void:
	_build_env()
	_build_scenery()
	_spawn_units()
	print("[Main] P0 ready — units=%d" % units.size())

func _build_env() -> void:
	# 地面
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(120, 120)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.42, 0.52, 0.30)
	ground.material_override = gm
	ground.create_trimesh_collision()   # 供點地射線
	add_child(ground)
	# 光照
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, 38, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.78, 0.82, 0.88)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.85, 0.88, 0.95)
	e.ambient_light_energy = 0.55
	env.environment = e
	add_child(env)
	# 相機
	cam = TacticalCamera.new()
	add_child(cam)
	cam.focus = Vector3(0, 0, 0)

func _build_scenery() -> void:
	for info in [["res://assets/models/house-b.glb", Vector3(-12, 0, -10)],
			["res://assets/models/townhouse-b.glb", Vector3(14, 0, -14)]]:
		var packed: PackedScene = load(info[0])
		if packed == null:
			continue
		var b := packed.instantiate()
		add_child(b)
		b.position = info[1]
		b.scale = Vector3.ONE * 3.0

func _spawn_units() -> void:
	var defs := [
		["res://assets/models/chars/rifleman-tripo.glb", "rifleman", 0, Vector3(-4, 0, 8)],
		["res://assets/models/chars/sniper-tripo3.glb", "sniper", 0, Vector3(0, 0, 9)],
		["res://assets/models/chars/assault.glb", "assault", 0, Vector3(4, 0, 8)],
		["res://assets/models/chars/mg-tripo.glb", "mg", 1, Vector3(2, 0, -6)],
		["res://assets/models/chars/assault.glb", "assault", 1, Vector3(-3, 0, -7)],
	]
	for d in defs:
		var u := Unit.spawn(d[0], d[1], d[2])
		add_child(u)
		u.position = d[3]
		u.shot_fired.connect(_on_shot)
		units.append(u)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_click(event.position)

func _click(screen_pos: Vector2) -> void:
	# 先試點兵（距離判定，P0 不掛 collider）
	var best: Unit = null
	var best_d := 40.0
	for u in units:
		var sp := cam.unproject_position(u.global_position + Vector3(0, 1.0, 0))
		var d := sp.distance_to(screen_pos)
		if d < best_d:
			best_d = d
			best = u
	if best != null:
		if best.side == 0:
			selected = best
			cam.set_follow(best)
			print("[Main] 選取 ", best.cls)
		elif selected != null:
			selected.shoot_at(best)
			print("[Main] %s 開火 → %s" % [selected.cls, best.cls])
		return
	# 點地移動
	if selected == null:
		return
	var from := cam.project_ray_origin(screen_pos)
	var dir := cam.project_ray_normal(screen_pos)
	if abs(dir.y) < 0.0001:
		return
	var t := -from.y / dir.y
	if t <= 0.0:
		return
	var hit := from + dir * t
	selected.move_to(hit)

func _on_shot(from_pos: Vector3, to_pos: Vector3) -> void:
	# 曳光線＋槍口閃光（0.15s）
	var im := ImmediateMesh.new()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.88, 0.45)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	im.surface_add_vertex(from_pos)
	im.surface_add_vertex(to_pos)
	im.surface_end()
	add_child(mi)
	var flash := OmniLight3D.new()
	flash.light_color = Color(1.0, 0.8, 0.4)
	flash.omni_range = 4.0
	flash.position = from_pos
	add_child(flash)
	_tracers.append({"mesh": mi, "light": flash, "ttl": 0.15})

func _process(delta: float) -> void:
	for tr in _tracers.duplicate():
		tr["ttl"] -= delta
		if tr["ttl"] <= 0.0:
			tr["mesh"].queue_free()
			tr["light"].queue_free()
			_tracers.erase(tr)
