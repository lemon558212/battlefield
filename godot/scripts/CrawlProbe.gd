# CrawlProbe.gd — 匍匐動作的快速探針（selftest 跑一輪要 10 分鐘，改一行就等 10 分鐘是不行的）。
# 直接驅動一個 Unit 趴著移動，逐幀取膝蓋與髖部的極值，印出與 [crawlchk] 同一組指標。
extends Node3D

const MODEL := "res://assets/models/chars/hr_m_Soldier.fbx"

var _u: Unit

func _ready() -> void:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.3, 0.5, 0.7)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_energy = 0.9
	var we := WorldEnvironment.new(); we.environment = e; add_child(we)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-50, 30, 0); add_child(sun)
	var cam := Camera3D.new(); add_child(cam); cam.make_current()
	cam.position = Vector3(3.2, 1.0, 0)
	cam.look_at(Vector3(0, 0.3, 2.0), Vector3.UP)
	_run(cam)

func _run(cam: Camera3D) -> void:
	_u = Unit.spawn(MODEL, "rifleman", 0, true)
	add_child(_u)
	_u.rotation.y = 0.0
	_u.stance_cmd = "prone"
	await get_tree().create_timer(1.8).timeout          # 等 _prone 收斂
	# ⚠ 一定要用 move_dir（＝鍵盤操控走的那條路徑）：move_to 的點地移動不會推進
	#   匍匐相位 _crawl，量出來會是一個完全靜止的姿勢（第一版探針就這樣誤判）。
	var sk := (_u.find_children("*", "Skeleton3D", true, false)[0]) as Skeleton3D
	var hip_i := sk.find_bone("Hips")
	var knee_i := sk.find_bone("LowerLeg.R")
	var thigh_i := sk.find_bone("UpperLeg.R")
	var foot_i := sk.find_bone("Foot.R")
	var f_lo := 9.9
	var f_hi := -9.9
	var s_lo := 9.9
	var s_hi := -9.9
	var a_lo := 999.0
	var a_hi := -999.0
	var amt_hi := 0.0
	var t := 0.0
	while t < 2.2:
		await get_tree().process_frame
		var dt: float = get_process_delta_time()
		t += dt
		_u.move_dir(Vector3(0, 0, 1), dt)
		var hip: Vector3 = sk.global_transform * sk.get_bone_global_pose(hip_i).origin
		var knee: Vector3 = sk.global_transform * sk.get_bone_global_pose(knee_i).origin
		var thigh: Vector3 = sk.global_transform * sk.get_bone_global_pose(thigh_i).origin
		var foot: Vector3 = sk.global_transform * sk.get_bone_global_pose(foot_i).origin
		var fwd := _u.facing_dir()
		var rgt := _u.right_dir()
		var fw: float = (knee - hip).dot(fwd)            # 正＝膝在髖前
		var sp: float = absf((knee - hip).dot(rgt))      # 外張量
		var ang: float = rad_to_deg(acos(clampf((knee - thigh).normalized()
				.dot((foot - knee).normalized()), -1.0, 1.0)))
		f_lo = minf(f_lo, fw); f_hi = maxf(f_hi, fw)
		s_lo = minf(s_lo, sp); s_hi = maxf(s_hi, sp)
		a_lo = minf(a_lo, ang); a_hi = maxf(a_hi, ang)
		amt_hi = maxf(amt_hi, _u._crawl_amt)
	print("[crawlprobe] _prone=%.2f _crawl_amt(max)=%.2f is_moving=%s"
			% [_u._prone, amt_hi, _u.is_moving()])
	print("[crawlprobe] 右膝相對髖前後 %.2f~%.2f（要一前一後，正=在髖前）%s"
			% [f_lo, f_hi, "OK" if (f_hi > 0.05 and f_lo < -0.05) else "FAIL"])
	print("[crawlprobe] 外張量 %.2f~%.2f（擺幅 %.2f）%s"
			% [s_lo, s_hi, s_hi - s_lo, "OK" if (s_hi - s_lo) > 0.05 else "FAIL"])
	print("[crawlprobe] 膝彎曲角 %.0f~%.0f 度 %s"
			% [a_lo, a_hi, "OK" if (a_hi - a_lo) > 12.0 else "FAIL"])
	cam.position = _u.global_position + Vector3(3.0, 0.9, 0)
	cam.look_at(_u.global_position + Vector3(0, 0.25, 0), Vector3.UP)
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://qa/")
	get_viewport().get_texture().get_image().save_png("res://qa/crawlprobe.png")
	print("[crawlprobe] DONE")
	get_tree().quit(0)
