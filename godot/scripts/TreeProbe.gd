# TreeProbe.gd — 樹種驗證台。
# 為什麼要有：判斷樹好不好看只能看**渲染出來的圖**（本專案最貴的教訓第一條），
# 而跑一次 `-- scene` 要好幾分鐘、樹還混在整個戰場裡看不清楚。
# 這裡把五個樹種 × 五個變體排成一排，旁邊立一根 1.75m 的人形比例尺——
# 「樹會不會太大」這種問題必須用比例尺回答，不能用眼睛猜。
extends Node3D

const TREES := preload("res://scripts/Trees.gd")

func _ready() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.62, 0.70, 0.80)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.70, 0.76, 0.86)
	e.ambient_light_energy = 0.55
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, 128, 0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	add_child(sun)
	# 地面
	var gp := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(300, 300)
	gp.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.30, 0.34, 0.22)
	gp.material_override = gm
	add_child(gp)

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.94
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var protos: Dictionary = TREES.build_protos()
	var cam := Camera3D.new()
	cam.fov = 52.0
	add_child(cam)
	# 一個樹種拍一張近照：五個變體排一排，每棵旁邊一根 1.75m 紅色人形比例尺。
	# 「樹會不會太大」必須用比例尺回答，不能用眼睛猜（本專案量錯維度的教訓）。
	for kind in TREES.KINDS:
		var holder := Node3D.new()
		add_child(holder)
		var x := 0.0
		var top := 0.0
		for m in protos[kind]:
			var mi := MeshInstance3D.new()
			mi.mesh = m
			mi.material_override = mat
			mi.position = Vector3(x, 0, 0)
			holder.add_child(mi)
			var ref := MeshInstance3D.new()
			var cap := CapsuleMesh.new()
			cap.radius = 0.22
			cap.height = 1.75
			ref.mesh = cap
			var rm := StandardMaterial3D.new()
			rm.albedo_color = Color(0.92, 0.24, 0.20)
			ref.material_override = rm
			ref.position = Vector3(x + 2.2, 0.875, 0.6)
			holder.add_child(ref)
			var aabb: AABB = m.get_aabb()
			top = maxf(top, aabb.size.y)
			var tris: int = 0
			if m.get_surface_count() > 0:
				tris = int(m.surface_get_array_len(0) / 3)
			print("[treeprobe] %-10s 高=%.1fm 寬=%.1fm 三角形=%d"
					% [kind, aabb.size.y, maxf(aabb.size.x, aabb.size.z), tris])
			x += 6.2
		var span: float = x - 6.2
		cam.position = Vector3(span * 0.5, top * 0.55, span * 0.72 + top * 1.15 + 6.0)
		cam.look_at(Vector3(span * 0.5, top * 0.42, 0))
		await get_tree().create_timer(0.45).timeout
		var img := get_viewport().get_texture().get_image()
		img.save_png("res://qa/tree_%s.png" % kind)
		holder.queue_free()
		await get_tree().process_frame
	print("[treeprobe] DONE")
	get_tree().quit(0)
