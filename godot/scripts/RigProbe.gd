# RigProbe.gd — 逐一檢查**遊戲實際會用到的每一個角色模型**是否具備持槍 IK 需要的骨頭。
# ★存在理由（2026-07-27 血淚）：我一直只用 hr_m_Soldier 與 hr_w_Swat 驗手臂，
#   但玩家的英雄丁小滿用的是 hr_m_SciFi、白老師是 hr_m_Worker、巴頓是 hr_m_Adventurer…
#   任何一支缺骨頭，`ik_two_bone` 就 return false（**安靜地失敗**）＝那個角色沒有手臂也沒有武器。
extends Node3D

# 與 Main.CLASS_MODEL / HERO_MODEL 對齊：這裡列的是「遊戲裡真的會生出來的模型」
const MODELS := [
	"hr_m_Soldier", "hr_w_Swat", "hr_m_Worker", "hr_m_SciFi",
	"hr_m_Adventurer", "hr_w_Casual", "hr_w_Spacesuit",
]
# 持槍 IK／姿勢系統會去找的骨頭（缺任何一根就會安靜失敗）
const NEED := ["Root", "Hips", "Abdomen", "Torso", "Chest", "Neck", "Head",
		"Shoulder.L", "UpperArm.L", "LowerArm.L",
		"Shoulder.R", "UpperArm.R", "LowerArm.R",
		"UpperLeg.L", "LowerLeg.L", "Foot.L", "UpperLeg.R", "LowerLeg.R", "Foot.R"]
const HAND_ALT := [["Hand.L", "Wrist.L"], ["Hand.R", "Wrist.R"]]

func _ready() -> void:
	var bad := 0
	for m in MODELS:
		var p := "res://assets/models/chars/%s.fbx" % m
		if not ResourceLoader.exists(p):
			print("[rig] %s FAIL 缺檔" % m)
			bad += 1
			continue
		var n := (load(p) as PackedScene).instantiate()
		add_child(n)
		var sks := n.find_children("*", "Skeleton3D", true, false)
		if sks.is_empty():
			print("[rig] %s FAIL 沒有 Skeleton3D" % m)
			bad += 1
			n.queue_free()
			continue
		var sk := sks[0] as Skeleton3D
		var miss: Array = []
		for b in NEED:
			if sk.find_bone(b) < 0:
				miss.append(b)
		for pair in HAND_ALT:
			if sk.find_bone(pair[0]) < 0 and sk.find_bone(pair[1]) < 0:
				miss.append("%s/%s" % [pair[0], pair[1]])
		# 動畫來源：模型自帶動畫 or 需要重定向
		var aps := n.find_children("*", "AnimationPlayer", true, false)
		var n_anim: int = 0
		if not aps.is_empty():
			n_anim = (aps[0] as AnimationPlayer).get_animation_list().size()
		print("[rig] %-18s 骨數=%-3d 內建動畫=%-3d %s"
				% [m, sk.get_bone_count(), n_anim,
				"OK" if miss.is_empty() else "FAIL 缺骨=%s" % str(miss)])
		if not miss.is_empty():
			bad += 1
		n.queue_free()
	print("[rig] FAILS=%d" % bad)
	print("[rig] DONE")
	get_tree().quit(0)
