# WeatherProbe.gd — 動態天候系統（GDD/04 天候節）純函式斷言，3 秒跑完。
# 最重要的一條：**沙漠池 400 次擲骰永遠不出雨**——「沙漠不會下雨」是規則保證，
# 不是機率上剛好沒遇到。時段邊界與效果接線也各驗一次。
extends Node

var fails := 0

class MU:
	var weapon := {"acc": 0.6, "range": 200, "atk": 30}
	var cls := "assault"
	var stance_acc := 1.0
	var moving := false
	var hp_ratio := 1.0
	var wade := 0.0
	var slope := 0.0
	var elev := 0.0
	var in_crater := false
	var env_acc := 1.0
	var env_dodge := 1.0

func _chk(name: String, ok: bool, detail := "") -> void:
	if not ok:
		fails += 1
	print("[wxchk] %-40s %s %s" % [name, "OK" if ok else "FAIL", detail])

func _ready() -> void:
	await get_tree().process_frame
	# --- 時段邊界 ---
	_chk("04 時＝夜", GameData.tod_for_hour(4.0) == "night", GameData.tod_for_hour(4.0))
	_chk("06 時＝晨", GameData.tod_for_hour(6.0) == "dawn", GameData.tod_for_hour(6.0))
	_chk("12 時＝日", GameData.tod_for_hour(12.0) == "day", GameData.tod_for_hour(12.0))
	_chk("18 時＝昏", GameData.tod_for_hour(18.0) == "dusk", GameData.tod_for_hour(18.0))
	_chk("23 時＝夜", GameData.tod_for_hour(23.0) == "night", GameData.tod_for_hour(23.0))
	_chk("26 時（跨日）＝凌晨 2 點＝夜", GameData.tod_for_hour(26.0) == "night")

	# --- 轉移池封閉性：沙漠 400 次永不出雨（這是使用者問題的規則化答案）---
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	var w := "clear"
	var seen := {}
	for i in 400:
		w = GameData.weather_next("desert", w, rng)
		seen[w] = true
	_chk("沙漠 400 回合只出現晴/沙暴", not seen.has("rain") and not seen.has("storm") \
			and not seen.has("fog"), str(seen.keys()))
	_chk("沙漠會出現沙暴（不是永遠晴天）", seen.has("sand"), str(seen.keys()))

	# 叢林池：會下雨也會起霧，但不會有沙暴
	rng.seed = 778
	w = "clear"
	var seen2 := {}
	for i in 400:
		w = GameData.weather_next("forest", w, rng)
		seen2[w] = true
	_chk("叢林 400 回合不出現沙暴", not seen2.has("sand"), str(seen2.keys()))
	_chk("叢林會遇到雨或霧", seen2.has("rain") or seen2.has("fog"), str(seen2.keys()))

	# 未知 biome：不變（安全預設）
	_chk("未知 biome 維持原天氣", GameData.weather_next("moon", "clear", rng) == "clear")

	# --- 效果接線：大雨命中該乘 0.80×0.88 ---
	var s := MU.new()
	var t := MU.new()
	var base: float = GameData.hit_chance(s, t, 50.0)
	var fx: Dictionary = GameData.weather_fx("storm")
	s.env_acc = float(fx.get("acc", 1.0))
	t.env_dodge = float(fx.get("dodge", 1.0))
	var hit: float = GameData.hit_chance(s, t, 50.0)
	_chk("大雨命中 ×0.80×0.88", absf(hit - base * 0.80 * 0.88) < 0.005,
			"%.3f→%.3f" % [base, hit])
	_chk("晴天效果表全 1.0", float(GameData.weather_fx("clear").get("acc", 0)) == 1.0)
	_chk("沙暴視野 0.55", absf(float(GameData.weather_fx("sand").get("sight", 0)) - 0.55) < 0.001)

	print("[wxchk] FAILS=%d" % fails)
	print("[wxchk] DONE")
	get_tree().quit(1 if fails > 0 else 0)
