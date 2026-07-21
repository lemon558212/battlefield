# Main.gd — P0 驗證場（GDD/13）：地面＋建築＋單位＋戰術相機
# 操作：左鍵點我方兵=選取(跟隨) / 點地=移動 / 點敵兵=開槍；右鍵拖曳=平移；滾輪=縮放
extends Node3D

var cam: TacticalCamera
var units: Array[Unit] = []
var selected: Unit = null
var _tracers: Array = []   # {mesh, ttl}

var _selftest := false
var _shots_seen := 0

func _ready() -> void:
	_build_env()
	_build_scenery()
	_spawn_units()
	print("[Main] P0 ready — units=%d" % units.size())
	if "selftest" in OS.get_cmdline_user_args():
		_selftest = true
		_run_selftest()

func _run_selftest() -> void:
	# 自動腳本：選狙擊手→走向敵人→開槍→分階段截圖→退出（供 AI 無頭驗收）
	await get_tree().create_timer(0.6).timeout
	var me: Unit = null
	var foe: Unit = null
	for u in units:
		if u.side == 0 and u.cls == "sniper": me = u
		if u.side == 1: foe = u
	if me == null or foe == null:
		print("[selftest] FAIL no unit"); get_tree().quit(2); return
	selected = me
	cam.set_follow(me)
	for c in units: c.shot_fired.connect(func(_a, _b): _shots_seen += 1)
	# 站姿截圖
	await get_tree().create_timer(0.5).timeout
	_snap("res://selftest_idle.png")
	# 移動
	me.move_to(foe.global_position + Vector3(4, 0, 4))
	await get_tree().create_timer(0.4).timeout
	print("[selftest] moving state=", me._state)
	_snap("res://selftest_walk.png")
	await get_tree().create_timer(1.6).timeout
	# 開槍
	me.shoot_at(foe)
	await get_tree().create_timer(0.32).timeout
	print("[selftest] firing state=", me._state)
	_snap("res://selftest_shoot.png")
	# 近拍持槍/射擊姿態（評估動作品質）
	cam.set_follow(null)
	cam.dist = 5.5
	cam.pitch_deg = 12.0
	cam.focus = me.global_position + Vector3(0, 1.0, 0)
	me.shoot_at(foe)
	await get_tree().create_timer(0.15).timeout
	_snap("res://selftest_pose_aim.png")
	await get_tree().create_timer(0.3).timeout
	_snap("res://selftest_pose_shoot.png")
	await get_tree().create_timer(0.8).timeout
	print("[selftest] shots_seen=", _shots_seen, " aims=", me.anim_names)
	get_tree().quit(0)

func _snap(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[selftest] saved ", path, " ", img.get_width(), "x", img.get_height())

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
	# 相機（預設拉近，看得清單位）
	cam = TacticalCamera.new()
	add_child(cam)
	cam.focus = Vector3(0, 0, 2)
	cam.dist = 14.0
	cam.pitch_deg = 42.0

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

# 兵種 → Quaternius 模型（各含 24 動畫）＋兵種色（微量疊色區分剪影）
const CLASS_MODEL := {
	"rifleman": "res://assets/models/chars/rifleman.glb",
	"sniper": "res://assets/models/chars/sniper.glb",
	"mg": "res://assets/models/chars/mg.glb",
	"assault": "res://assets/models/chars/assault.glb",
	"at": "res://assets/models/chars/at.glb",
	"mortar": "res://assets/models/chars/mortar.glb",
	"engineer": "res://assets/models/chars/engineer.glb",
	"specops": "res://assets/models/chars/specops.glb",
	"sam": "res://assets/models/chars/sam.glb",
}
const CLASS_TINT := {
	"rifleman": Color(0.55, 0.75, 0.45), "sniper": Color(0.35, 0.45, 0.6),
	"mg": Color(0.7, 0.5, 0.3), "assault": Color(0.75, 0.35, 0.3),
	"at": Color(0.5, 0.4, 0.6), "mortar": Color(0.6, 0.6, 0.35),
	"engineer": Color(0.4, 0.62, 0.55), "specops": Color(0.25, 0.25, 0.3),
	"sam": Color(0.5, 0.55, 0.7),
}

func _make_unit(cls: String, side_i: int, pos: Vector3) -> Unit:
	var path: String = CLASS_MODEL.get(cls, CLASS_MODEL["rifleman"])
	var tint: Color = CLASS_TINT.get(cls, Color(0, 0, 0, 0))
	var u := Unit.spawn(path, cls, side_i, tint)
	add_child(u)
	u.position = pos
	u.rotation.y = 0.0 if side_i == 0 else PI
	u.shot_fired.connect(_on_shot)
	units.append(u)
	return u

func _spawn_units() -> void:
	# 我方一排（多兵種展示動畫）
	var mine := ["rifleman", "sniper", "mg", "assault", "engineer"]
	for i in mine.size():
		_make_unit(mine[i], 0, Vector3(-8 + i * 4.0, 0, 9))
	# 敵方
	var foes := ["assault", "mg", "at"]
	for i in foes.size():
		_make_unit(foes[i], 1, Vector3(-4 + i * 4.0, 0, -6))

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
