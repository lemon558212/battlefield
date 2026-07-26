# AniProbe.gd — 列出 UAL 動作庫裡有哪些片段與長度。
# 存在理由：要「補齊角色動作」前，第一個問題永遠是「素材裡到底有什麼」，
# 用猜的會做出一堆對不到片段的死碼（Unit.UAL_MAP 就是照這份清單填的）。
extends Node3D

const UAL := "res://assets/models/anims/ual_standard.glb"

func _ready() -> void:
	if not ResourceLoader.exists(UAL):
		print("[ual] 找不到動作庫 ", UAL)
		get_tree().quit(1)
		return
	var n := (load(UAL) as PackedScene).instantiate()
	add_child(n)
	var aps := n.find_children("*", "AnimationPlayer", true, false)
	if aps.is_empty():
		print("[ual] 動作庫裡沒有 AnimationPlayer")
		get_tree().quit(1)
		return
	var ap := aps[0] as AnimationPlayer
	var list := ap.get_animation_list()
	print("[ual] count=", list.size())
	for a in list:
		print("[ual] %-22s %.2fs" % [a, ap.get_animation(a).length])
	get_tree().quit(0)
