# SlopeCostProbe.gd — 坡度移動成本曲線（GDD/14 §3-4；2026-07-31 使用者：爬坡要更耗）。
# 純函式斷言，3 秒跑完。驗三件事：
#   ① 連續：坡度每增一分成本就多一分，沒有門檻突跳（舊版 0.34→1.0、0.36→1.5）
#   ② 有向：同一個點上坡比下坡貴
#   ③ 兵種差異：重裝兵爬坡比偵察兵更吃力
extends Node

var fails := 0

func _chk(name: String, ok: bool, detail := "") -> void:
	if not ok:
		fails += 1
	print("[costchk] %-44s %s %s" % [name, "OK" if ok else "FAIL", detail])

func _ready() -> void:
	await get_tree().process_frame
	var t := BattleTerrain.new()
	add_child(t)
	# 造一張只有一座山的圖：山心在 (500,300)、半徑 300px、高 12（×0.4＝4.8m）
	t.build({"w": 1000, "h": 600, "hills": [{"x": 500, "y": 300, "r": 300, "h": 12}]}, 0.05)
	await get_tree().process_frame
	# 沿山坡由外往內取樣，方向指向山心＝上坡
	var to_peak := Vector2(1, 0)
	# ⚠ 單調性要對「坡度」驗，不是對「位置」：山是鐘形，過了半徑中點坡度本來就
	# 遞減，成本跟著降是正確的（第一版測試把這個判成 FAIL——測試假設錯，不是程式錯）。
	var pairs: Array = []
	print("[costchk] 上坡成本曲線（foot，方向指向山頂）：")
	for px in [220, 260, 300, 340, 380, 420, 460]:
		var sl: float = t.slope_signed(float(px), 300.0, to_peak)
		var c: float = t.move_cost(float(px), 300.0, "foot", to_peak)
		print("    px=%d 坡度=%+.3f（%.1f度） 成本=%.3f" % [px, sl, rad_to_deg(atan(absf(sl))), c])
		pairs.append([sl, c])
	pairs.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	var mono := true
	var prev := -999.0
	for pr in pairs:
		if float(pr[1]) < prev - 0.001:
			mono = false
		prev = float(pr[1])
	_chk("成本隨坡度單調不減（無門檻突跳）", mono)
	# 有向：同一點，上坡 vs 下坡
	var up_c: float = t.move_cost(300.0, 300.0, "foot", to_peak)
	var down_c: float = t.move_cost(300.0, 300.0, "foot", -to_peak)
	_chk("上坡比下坡貴", up_c > down_c + 0.05, "上=%.3f 下=%.3f" % [up_c, down_c])
	# 緩降（坡度 < 0.25）才該省力；23 度陡降本來就要煞車（設計如此，見 SLOPE_BRAKE_AT）
	var gentle_c: float = t.move_cost(220.0, 300.0, "foot", -to_peak)
	var gentle_sl: float = t.slope_signed(220.0, 300.0, to_peak)
	_chk("緩降省力（成本 <1.0）", gentle_c < 1.0,
			"坡度=%.3f 成本=%.3f" % [gentle_sl, gentle_c])
	_chk("陡降要煞車（成本 >1.0 但遠低於上坡）", down_c > 1.0 and down_c < up_c * 0.7,
			"陡降=%.3f 上坡=%.3f" % [down_c, up_c])
	# 兵種：重裝比偵察吃力
	var scout_c: float = t.move_cost(300.0, 300.0, "scout", to_peak)
	var heavy_c: float = t.move_cost(300.0, 300.0, "heavy", to_peak)
	_chk("重裝爬坡比偵察兵吃力", heavy_c > scout_c, "偵察=%.3f 重裝=%.3f" % [scout_c, heavy_c])
	# 比舊制更耗：舊制在坡度>0.35 是 hill(1.15)*1.3=1.495，以下是 1.0
	var sl_mid: float = t.slope_signed(300.0, 300.0, to_peak)
	if sl_mid > 0.35:
		_chk("同坡度比舊門檻制更耗", up_c > 1.495, "新=%.3f 舊=1.495" % up_c)
	else:
		_chk("緩坡也開始計費（舊制完全不耗）", up_c > 1.02, "坡度=%.3f 成本=%.3f" % [sl_mid, up_c])
	# 平地不受影響
	var flat_c: float = t.move_cost(50.0, 50.0, "foot", to_peak)
	_chk("平地成本仍為 1.0 附近", absf(flat_c - 1.0) < 0.25, "平地=%.3f" % flat_c)
	print("[costchk] FAILS=%d" % fails)
	print("[costchk] DONE")
	get_tree().quit(1 if fails > 0 else 0)
