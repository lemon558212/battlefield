# MatProbe.gd — 列出各角色模型的材質名稱。
# _apply_look 是「依材質名分部位上色」，名字對不上就會把臉跟皮膚也刷成衣服色（整個人變黑）。
extends Node3D

const MODELS := [
	"hr_m_Soldier", "hr_m_SciFi", "hr_m_Worker", "hr_m_Adventurer", "hr_m_Punk", "hr_m_Suit",
	"hr_w_Swat", "hr_w_Casual", "hr_w_Farmer", "hr_w_Spacesuit",
]

func _ready() -> void:
	for m in MODELS:
		var p := "res://assets/models/chars/%s.fbx" % m
		if not ResourceLoader.exists(p):
			print("[mat] 缺檔 ", m); continue
		var n := (load(p) as PackedScene).instantiate()
		add_child(n)
		var names := []
		for mi in n.find_children("*", "MeshInstance3D", true, false):
			var c: int = maxi((mi as MeshInstance3D).get_surface_override_material_count(), 1)
			for i in c:
				var mat := (mi as MeshInstance3D).get_active_material(i)
				names.append("%s[%s]" % [mat.resource_name if mat else "null", mi.name])
		print("[mat] ", m, " → ", " ".join(names))
		n.queue_free()
	get_tree().quit(0)
