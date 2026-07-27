extends Node3D
const CITY := preload("res://scripts/CityBlocks.gd")
func _ready() -> void:
	for n in CITY.WHOLE + CITY.GROUND + CITY.PROPS:
		var d: Dictionary = CITY.load_parts(self, n)
		if d.is_empty():
			print("[cityprobe] %-28s 載入失敗" % n)
			continue
		var ab: AABB = d["aabb"]
		print("[cityprobe] %-28s 尺寸 %.1f x %.1f x %.1f m  件數=%d"
				% [n, ab.size.x, ab.size.y, ab.size.z, (d["parts"] as Array).size()])
	print("[cityprobe] DONE")
	get_tree().quit(0)
