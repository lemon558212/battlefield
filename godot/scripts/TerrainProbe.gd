# TerrainProbe.gd — 地形戰鬥修正（GDD/01 §4b）的純公式斷言，3 秒跑完。
# 訂指標的鐵則：每一條都先問「錯誤情況下會不會也通過」——所以每個係數都有
# 「門檻下不變」的對照組，載具豁免也各驗一次，不是只驗 happy path。
# 接線（_wrap 有沒有真的填地形）由 `-- stress` 的 [terrchk] 印出實戰值互相對照。
extends Node

var fails := 0

class MU:
	var weapon: Dictionary
	var cls := "assault"
	var stance_acc := 1.0
	var moving := false
	var hp_ratio := 1.0
	var wade := 0.0
	var slope := 0.0
	var elev := 0.0
	var in_crater := false
	var env_acc := 1.0     # 天候（GDD/04）：探針預設晴天＝中性
	var env_dodge := 1.0
	func _init(c := "assault"):
		cls = c
		weapon = {"acc": 0.6, "range": 200, "atk": 30, "shots": 1}

func _chk(name: String, got: float, want: float, tol := 0.005) -> void:
	var ok: bool = absf(got - want) < tol
	if not ok:
		fails += 1
	print("[terrchk] %-38s 得到 %.4f 應為 %.4f %s" % [name, got, want, "OK" if ok else "FAIL"])

func _ready() -> void:
	await get_tree().process_frame          # 等 GameData autoload 讀完 JSON
	var s := MU.new()
	var t := MU.new()
	var base: float = GameData.hit_chance(s, t, 50.0)
	_chk("基準（乾地、平地、同高）", base, 0.6)

	# --- 射手穩定度 ---
	s.wade = 0.5
	_chk("射手及膝涉水 ×0.92", GameData.hit_chance(s, t, 50.0), base * 0.92)
	s.wade = 0.9
	_chk("射手及腰涉水 ×0.80", GameData.hit_chance(s, t, 50.0), base * 0.80)
	s.wade = 0.30
	_chk("射手水深 0.30m（門檻下）不變", GameData.hit_chance(s, t, 50.0), base)
	s.wade = 0.0
	s.slope = 0.45
	_chk("射手站陡坡 ×0.88", GameData.hit_chance(s, t, 50.0), base * 0.88)
	s.slope = 0.2
	_chk("緩坡（門檻下）不變", GameData.hit_chance(s, t, 50.0), base)
	s.slope = 0.45
	s.wade = 0.5
	_chk("涉水＋陡坡疊乘", GameData.hit_chance(s, t, 50.0), base * 0.92 * 0.88)
	s.slope = 0.0
	s.wade = 0.0

	# --- 高低差 ---
	s.elev = 3.0
	_chk("居高臨下 +3m ×1.10", GameData.hit_chance(s, t, 50.0), base * 1.10)
	s.elev = -3.0
	_chk("仰射 -3m ×0.90", GameData.hit_chance(s, t, 50.0), base * 0.90)
	s.elev = 2.0
	_chk("高差 2m（門檻下）不變", GameData.hit_chance(s, t, 50.0), base)
	s.elev = 3.0
	var far: float = GameData.hit_chance(s, t, 250.0)
	_chk("超射程照樣 0（高地不能救）", far, 0.0)
	s.elev = 0.0

	# --- 目標閃避 ---
	t.wade = 0.5
	_chk("目標涉水 ×1.12（跑不掉）", GameData.hit_chance(s, t, 50.0), base * 1.12)
	t.wade = 0.0
	t.in_crater = true
	_chk("目標在彈坑 ×0.85", GameData.hit_chance(s, t, 50.0), base * 0.85)
	t.in_crater = false

	# --- 載具豁免（坦克沒有「據槍」，也不會在水裡「跑不掉」）---
	var vs := MU.new("tank")
	vs.wade = 0.9
	vs.slope = 0.5
	_chk("坦克射手不吃涉水/陡坡", GameData.hit_chance(vs, t, 50.0), 0.6)
	var vt := MU.new("tank")
	vt.wade = 0.9
	vt.in_crater = true
	# 一般槍打坦克傷害固定 1（剋制），這裡只驗命中率不受目標地形影響
	_chk("坦克目標不吃涉水/彈坑閃避", GameData.hit_chance(s, vt, 50.0), 0.6)

	# --- 殺傷力 ---
	# ⚠ 目標要用不在 class_base 裡的假兵種（def=0），否則裝甲減免混進來，
	#   驗的就不只是地形係數（第一輪 3 個 FAIL 就是這個測試假設錯，不是引擎錯）
	t = MU.new("probe_dummy")
	var d0: int = GameData.damage(s, t)
	_chk("基準傷害", float(d0), 30.0)
	t.wade = 0.8
	_chk("目標半身泡水傷害 ×0.85", float(GameData.damage(s, t)), round(30.0 * 0.85))
	t.wade = 0.5
	_chk("水深 0.5m（門檻下）傷害不變", float(GameData.damage(s, t)), 30.0)
	t.wade = 0.0

	# --- 濺射遮蔽 ---
	_chk("壕溝 defilade 0.5", GameData.splash_defilade(true, false), 0.5)
	_chk("彈坑 defilade 0.65", GameData.splash_defilade(false, true), 0.65)
	_chk("壕溝優先於彈坑", GameData.splash_defilade(true, true), 0.5)
	_chk("開闊地 1.0", GameData.splash_defilade(false, false), 1.0)

	print("[terrchk] FAILS=%d" % fails)
	print("[terrchk] DONE")
	get_tree().quit(1 if fails > 0 else 0)
