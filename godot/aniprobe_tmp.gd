extends SceneTree
func _init():
	for p in ["res://assets/models/chars/sniper-tripo3.glb","res://assets/models/chars/rifleman-tripo.glb","res://assets/models/chars/sniper.glb"]:
		var m = (load(p) as PackedScene).instantiate()
		var aps = m.find_children("*","AnimationPlayer",true,false)
		var names = []
		if aps.size()>0: names = aps[0].get_animation_list()
		print(p.get_file(), " -> ", names)
	quit()
