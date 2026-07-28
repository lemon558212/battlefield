# GrowthProbe.gd — 養成系統（GDD/16）純公式斷言，3 秒跑完。
# UI 與訊號路徑由 `-- trainshot` 驗（真按鈕真畫面）；這裡只驗數學不會騙人：
# 花費曲線、每級效果、命中上限、Lv0 恆等（升級前後基準不可漂移）。
extends Node

var fails := 0

func _chk(name: String, got: float, want: float, tol := 0.005) -> void:
	var ok: bool = absf(got - want) < tol
	if not ok:
		fails += 1
	print("[growchk] %-36s 得到 %.3f 應為 %.3f %s" % [name, got, want, "OK" if ok else "FAIL"])

func _ready() -> void:
	await get_tree().process_frame
	_chk("Lv0→1 花費 80", GameData.growth_cost(0), 80)
	_chk("Lv3→4 花費 260", GameData.growth_cost(3), 260)
	_chk("Lv9→10 花費 620", GameData.growth_cost(9), 620)

	var w := {"acc": 0.7, "atk": 30, "range": 200}
	var r0: Array = GameData.growth_apply(100, w, 0)
	_chk("Lv0 血量不變", r0[0], 100)
	_chk("Lv0 命中不變", r0[1]["acc"], 0.7)
	_chk("Lv0 攻擊不變", r0[1]["atk"], 30)

	var r4: Array = GameData.growth_apply(100, w, 4)
	_chk("Lv4 HP ×1.20", r4[0], 120)
	_chk("Lv4 命中 +0.06", r4[1]["acc"], 0.76)
	_chk("Lv4 攻擊 ×1.12 取整", r4[1]["atk"], 34)
	_chk("Lv4 不動原武器 dict", w["acc"], 0.7)   # duplicate 了才能不污染共用表

	var hi := {"acc": 0.93, "atk": 30, "range": 200}
	var rc: Array = GameData.growth_apply(100, hi, 10)
	_chk("命中封頂 0.95", rc[1]["acc"], 0.95)

	var r10: Array = GameData.growth_apply(80, {"acc": 0.6, "atk": 44}, 10)
	_chk("Lv10 HP 80→120", r10[0], 120)
	_chk("Lv10 攻擊 44→57", r10[1]["atk"], 57)

	print("[growchk] FAILS=%d" % fails)
	print("[growchk] DONE")
	get_tree().quit(1 if fails > 0 else 0)
