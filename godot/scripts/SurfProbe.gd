# SurfProbe.gd — 逐 MeshInstance3D 逐 surface 倒出「網格表面數 vs override 數」與材質。
# 目的：驗證 `maxi(get_surface_override_material_count(), 1)` 這個寫法是否漏掉表面。
extends Node3D

const MODELS := ["hr_w_Swat", "hr_m_Soldier", "hr_m_SciFi", "hr_m_Adventurer"]

func _ready() -> void:
	for m in MODELS:
		var p := "res://assets/models/chars/%s.fbx" % m
		if not ResourceLoader.exists(p):
			print("[surf] 缺檔 ", m)
			continue
		var n := (load(p) as PackedScene).instantiate()
		add_child(n)
		for node in n.find_children("*", "MeshInstance3D", true, false):
			var mi := node as MeshInstance3D
			var sc: int = mi.mesh.get_surface_count() if mi.mesh else 0
			var oc: int = mi.get_surface_override_material_count()
			var mats := []
			for i in sc:
				var mat := mi.get_active_material(i)
				mats.append(mat.resource_name if mat else "null")
			print("[surf] %s / %s  mesh_surfaces=%d override_count=%d  mats=%s"
					% [m, mi.name, sc, oc, ", ".join(mats)])
		n.queue_free()
	get_tree().quit(0)
