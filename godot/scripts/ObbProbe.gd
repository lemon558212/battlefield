# ObbProbe.gd — 只驗新增的 OBB 幾何（純函式，不進戰場、不用等 -- play 的 9 分鐘）。
# 為什麼要有這一支：`-- play` 一輪要 9 分鐘，而幾何寫錯多半是**符號或軸搞反**，
# 那種錯用 4 個手算的案例 3 秒就抓得到。先過這關再去跑實戰。
extends Node

const MAIN := preload("res://scripts/Main.gd")

var fails := 0

func _chk(name: String, got, want, tol := 0.01) -> void:
	var ok: bool
	if got is Vector2:
		ok = (got as Vector2).distance_to(want) < tol
	else:
		ok = absf(float(got) - float(want)) < tol
	if not ok:
		fails += 1
	print("[obbchk] %-42s 得到 %s 應為 %s %s" % [name, str(got), str(want), "OK" if ok else "FAIL"])

func _ready() -> void:
	var m = MAIN.new()
	# 一個沿 X 軸躺著的盒：半長 3（X 向）、半寬 1.75（Y 向），中心原點
	var bk := {"t": "obb", "c": Vector2.ZERO, "ax": Vector2(1, 0),
			"e": Vector2(3.0, 1.75), "r": 0.0, "h": 2.4}
	# 1) 車尾正後方 4m（盒外）＝不該被推
	_chk("盒外不推", m._blk_push(bk, Vector2(-4.0, 0.0), 0.42), Vector2(-4.0, 0.0))
	# 2) ★使用者回報的情況：陷在車尾內側 → 推回車尾外 3.42
	#    ⚠ 推出方向用「最小平移向量」＝往最近的那一面出去，不是「從哪進去從哪出去」。
	#    所以取樣點要選在車尾這一側真的比較近的地方（-2.5：離車尾面 0.5，離側面 1.75）。
	#    在 (-1,0) 那種位置側面反而比較近，程式會往側面推——那是對的，不是 bug。
	_chk("車尾內側推回車尾外", m._blk_push(bk, Vector2(-2.5, 0.0), 0.42), Vector2(-3.42, 0.0))
	_chk("深陷車底走最近的面", m._blk_push(bk, Vector2(-1.0, 0.0), 0.42), Vector2(-1.0, 2.17))
	# 3) 剛好貼在車尾面上 → 推到 3.42
	_chk("貼車尾面", m._blk_push(bk, Vector2(-3.0, 0.0), 0.42), Vector2(-3.42, 0.0))
	# 4) 側面內部（-1.0, 1.0）→ 側面比較近，往側面推到 2.17
	_chk("側面內部往側面推", m._blk_push(bk, Vector2(-1.0, 1.0), 0.42), Vector2(-1.0, 2.17))
	# 5) 角落外側 → 沿對角推開，離角點 0.42
	var corner := m._blk_push(bk, Vector2(3.1, 1.85), 0.42)
	_chk("角落外側距角點", corner.distance_to(Vector2(3.0, 1.75)), 0.42)
	# 6) 轉 90 度的盒（車頭朝 +Y）：從 -Y 方向進來要被車尾擋
	var bk2 := {"t": "obb", "c": Vector2.ZERO, "ax": Vector2(0, 1),
			"e": Vector2(3.0, 1.75), "r": 0.0, "h": 2.4}
	_chk("轉90度後車尾內側", m._blk_push(bk2, Vector2(0.0, -2.5), 0.42), Vector2(0.0, -3.42))
	_chk("轉90度後側面內側", m._blk_push(bk2, Vector2(1.5, 0.0), 0.42), Vector2(2.17, 0.0))
	# 側面外 2.5m（盒半寬 1.75＋人 0.42 = 2.17）→ 還有空隙，不該推
	_chk("轉90度後側面外不推", m._blk_push(bk2, Vector2(2.5, 0.0), 0.42), Vector2(2.5, 0.0))
	# 7) 射線：從車尾外沿長軸射過去，t 應在進入車尾面（-3）的位置
	_chk("射線從車尾進入", m._blk_ray_t(bk, Vector2(-10.0, 0.0), Vector2(10.0, 0.0)), 0.35)
	# 8) 射線完全錯過（離側面 3m 遠）
	_chk("射線錯過回 -1", m._blk_ray_t(bk, Vector2(-10.0, 5.0), Vector2(10.0, 5.0)), -1.0)
	# 9) 射線橫穿側面：從 (0,-5) 到 (0,5)，進入點 y=-1.75 → t=0.325
	_chk("射線橫穿側面", m._blk_ray_t(bk, Vector2(0.0, -5.0), Vector2(0.0, 5.0)), 0.325)
	# 10) 內部/外框
	_chk("盒內判定", 1.0 if m._blk_inside(bk, Vector2(-2.0, 1.0)) else 0.0, 1.0)
	_chk("盒外判定", 1.0 if m._blk_inside(bk, Vector2(-4.0, 0.0)) else 0.0, 0.0)
	# 11) 外接框：轉 45 度時邊長應是 (3+1.75)/√2 × 2
	var bk3 := {"t": "obb", "c": Vector2.ZERO, "ax": Vector2(1, 1).normalized(),
			"e": Vector2(3.0, 1.75), "r": 0.0, "h": 2.4}
	_chk("45度外接框半寬", m._blk_aabb(bk3).size.x * 0.5, (3.0 + 1.75) / sqrt(2.0))
	# 12) 圓與線段沒被改壞（回歸）
	var cir := {"t": "cir", "c": Vector2.ZERO, "r": 2.0, "h": 1.2}
	_chk("圓 推出", m._blk_push(cir, Vector2(1.0, 0.0), 0.42), Vector2(2.42, 0.0))
	_chk("圓 射線進入", m._blk_ray_t(cir, Vector2(-10.0, 0.0), Vector2(10.0, 0.0)), 0.4)
	var seg := {"t": "seg", "a": Vector2(-5, 0), "b": Vector2(5, 0), "r": 0.5,
			"h": 1.2, "m": Vector2.ZERO, "hl": 5.0}
	_chk("線段 推出", m._blk_push(seg, Vector2(0.0, 0.2), 0.42), Vector2(0.0, 0.92))
	print("[obbchk] FAILS=%d" % fails)
	print("[obbchk] DONE")
	get_tree().quit(0)
