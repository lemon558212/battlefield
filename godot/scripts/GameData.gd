# GameData.gd — 自動載入單例：讀取引擎中立的 JSON 內容資產（GDD/13）
# 資料真相仍在 data/*.json（自 HTML5 版導出）；規則數值一律查表，禁止寫死。
extends Node

var nations: Dictionary = {}
var class_base: Dictionary = {}
var weapons: Dictionary = {}
var maps: Dictionary = {}
var story: Array = []
var characters: Dictionary = {}
var vehicle_unlock: Dictionary = {}
var difficulty: Dictionary = {}   # 章節難度曲線（data/difficulty.json）
var terrain_mobility: Dictionary = {}
var terrain_combat: Dictionary = {}   # 地形戰鬥修正（GDD/01 §4b）
var growth: Dictionary = {}           # 養成系統數值表（GDD/16）
var weather_sys: Dictionary = {}      # 動態天候系統（GDD/04 天候節）
var char_look: Dictionary = {}
var enemy_look: Dictionary = {}       # 敵軍外觀（GDD/06 外觀 v2：敵我基底分池）

func _ready() -> void:
	nations = _load_json("res://data/nations.json")
	class_base = _load_json("res://data/class_base.json")
	weapons = _load_json("res://data/weapons.json")
	maps = _load_json("res://data/maps.json")
	characters = _load_json("res://data/characters.json")
	vehicle_unlock = _load_json("res://data/vehicle_unlock.json")
	difficulty = _load_json("res://data/difficulty.json")
	terrain_mobility = _load_json("res://data/terrain_mobility.json")
	terrain_combat = _load_json("res://data/terrain_combat.json")
	growth = _load_json("res://data/growth.json")
	weather_sys = _load_json("res://data/weather_system.json")
	char_look = _load_json("res://data/char_look.json")
	enemy_look = _load_json("res://data/enemy_look.json")
	var st = _load_json_any("res://data/story.json")
	if st is Array:
		story = st
	print("[GameData] nations=%d classes=%d maps=%d story=%d" % [
		nations.size(), class_base.size(), maps.size(), story.size()])

func _load_json(path: String) -> Dictionary:
	var v = _load_json_any(path)
	return v if v is Dictionary else {}

func _load_json_any(path: String):
	if not FileAccess.file_exists(path):
		push_warning("JSON 不存在：" + path)
		return {}
	var txt := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(txt)
	if parsed == null:
		push_warning("JSON 解析失敗：" + path)
		return {}
	return parsed

# ---------- 立繪解析（角色 identity 走立繪，2026-07-21 使用者強調要用上生成立繪）----------
# 姓名 → 兵種 key
func cls_by_name(nm: String) -> String:
	for cls in characters.keys():
		if characters[cls].get("name", "") == nm:
			return cls
	return ""

# 對話立繪：優先透明去背 png（assets/portraits/<cls>[_mood].png），回退 full jpg
func portrait_path(cls: String, mood := "") -> String:
	if cls == "":
		return ""
	var base := "res://assets/portraits/" + cls
	if mood != "":
		var mp := base + "_" + mood + ".png"
		if ResourceLoader.exists(mp):
			return mp
	var png := base + ".png"
	if ResourceLoader.exists(png):
		return png
	var jpg := base + ".jpg"
	return jpg if ResourceLoader.exists(jpg) else ""

func portrait_by_name(nm: String, mood := "") -> String:
	return portrait_path(cls_by_name(nm), mood)

# ---------- 戰鬥公式（移植 combat.js，數值查表不寫死）----------
func weapon_of(nation_id: String, cls: String) -> Dictionary:
	var base: Dictionary = weapons.get(class_base.get(cls, {}).get("wtype", "rifle"), {}).duplicate(true)
	base["type"] = class_base.get(cls, {}).get("wtype", "rifle")
	var spec: Dictionary = nations.get(nation_id, {}).get("units", {}).get(cls, {})
	var mods: Dictionary = spec.get("mods", {})
	base["atk"] = base.get("atk", 10) + mods.get("atk", 0)
	base["range"] = base.get("range", 200) + mods.get("range", 0)
	base["acc"] = min(0.99, base.get("acc", 0.7) + mods.get("acc", 0.0))
	base["shots"] = base.get("shots", 1) + mods.get("shots", 0)
	return base

# 部位係數（GDD/01 §4）：命中率與傷害各一套。
# 散熱器＝坦克尾部，要繞到背後才打得到——這是坦克戰的核心操作。
const PART_ACC := {"body": 1.0, "head": 0.55, "radiator": 0.75}
const PART_DMG := {"body": 1.0, "head": 2.0, "radiator": 3.0}

func hit_chance(shooter, target, dist_px: float, part := "body") -> float:
	var w: Dictionary = shooter.weapon
	if dist_px > w.get("range", 200):
		return 0.0
	var c: float = w.get("acc", 0.7)
	var ratio: float = dist_px / max(1.0, w.get("range", 200))
	if ratio > 0.5:
		c *= 1.0 - 0.45 * ((ratio - 0.5) / 0.5)
	c *= float(PART_ACC.get(part, 1.0))
	# 姿勢、移動與傷勢（鐵律 0）：先前站著跑步射擊與趴著據槍的命中率完全相同。
	# 真實差距很大——臥射有雙肘與地面三點支撐，跑動中射擊基本上是亂槍。
	# stance/moving/hurt 由 Main 在包裝時填，沒有就當站姿、靜止、滿血。
	c *= float(shooter.stance_acc)
	if shooter.moving:
		c *= 0.55
	c *= 0.78 + 0.22 * clampf(shooter.hp_ratio, 0.0, 1.0)
	# 地形修正（GDD/01 §4b）：射手穩定度 × 目標閃避。數值查 terrain_combat.json。
	# 載具不吃「涉水不穩／陡坡據槍」——它們沒有「據槍」這回事；高低差照吃。
	var ts: Dictionary = terrain_combat.get("shooter", {})
	var tt: Dictionary = terrain_combat.get("target", {})
	if not Unit.is_vehicle_cls(shooter.cls):
		if shooter.wade >= float(ts.get("wade_waist_depth", 0.75)):
			c *= float(ts.get("wade_waist_acc", 0.80))
		elif shooter.wade >= float(ts.get("wade_knee_depth", 0.35)):
			c *= float(ts.get("wade_knee_acc", 0.92))
		if shooter.slope > float(ts.get("slope_min", 0.35)):
			c *= float(ts.get("slope_acc", 0.88))
	var dh: float = shooter.elev - target.elev
	if dh >= float(ts.get("high_ground_dh", 2.5)):
		c *= float(ts.get("high_ground_acc", 1.10))
	elif dh <= -float(ts.get("high_ground_dh", 2.5)):
		c *= float(ts.get("low_ground_acc", 0.90))
	if not Unit.is_vehicle_cls(target.cls):
		if target.wade >= float(tt.get("wade_depth", 0.35)):
			c *= float(tt.get("wade_exposed", 1.12))   # 水拖住腿＝閃不掉
		if target.in_crater:
			c *= float(tt.get("crater_profile", 0.85)) # 輪廓低於地平線
	# 天候（GDD/04 天候節）：雨霧沙暴壓命中、抬目標閃避——載具乘員一樣看不清，全體吃
	c *= float(shooter.env_acc) * float(target.env_dodge)
	return clamp(c, 0.0, 0.99)

# GDD/01 §4 剋制兩條（與 js/combat.js 同一套判斷，不另設倍率表）：
#   ① 一般槍械打坦克固定 1 傷害（刮漆）
#   ② 反裝甲武器（antiTank）打步兵傷害 ×0.6
# 這兩條就是坦克存在的意義：步槍打不動它，但火箭兵能開罐頭。
func damage(shooter, target, part := "body") -> int:
	var w: Dictionary = shooter.weapon
	var mult := 1.0
	var anti: bool = bool(w.get("antiTank", false)) or bool(w.get("arc", false))
	if target.cls == "tank":
		if not anti:
			return 1                      # 刮漆：連散熱器也一樣，槍械就是打不穿
	elif bool(w.get("antiTank", false)):
		mult = 0.6
	var eff: float = float(w.get("atk", 10)) * mult
	var deff: float = GameData.class_base.get(target.cls, {}).get("def", 0)
	var dmg: float = eff * float(PART_DMG.get(part, 1.0)) * max(0.1, 1.0 - deff / max(1.0, eff) * 0.5)
	# 地形（GDD/01 §4b）：目標半身泡水，打到下半身的部分被水吸收
	var td: Dictionary = terrain_combat.get("damage", {})
	if not Unit.is_vehicle_cls(target.cls) and target.wade >= float(td.get("wade_depth", 0.75)):
		dmg *= float(td.get("wade_absorb", 0.85))
	return int(max(1, round(dmg)))

# ---------- 動態天候（GDD/04 天候節）：純函式放這裡讓 WeatherProbe 能直接斷言 ----------
func weather_fx(w: String) -> Dictionary:
	return weather_sys.get("effects", {}).get(w, {})

# 時刻 → 天色時段。bands 沒涵蓋的（20~05）＝夜
func tod_for_hour(h: float) -> String:
	var hh: float = fposmod(h, 24.0)
	for band in weather_sys.get("tod_bands", []):
		if hh >= float(band[0]) and hh < float(band[1]):
			return String(band[2])
	return "night"

# 天氣轉移：有慣性（stickiness 機率維持原狀），否則依該 biome 的池加權抽。
# 池就是合理性的邊界——沙漠池裡沒有 rain，規則層面保證沙漠永不下雨。
func weather_next(biome_key: String, cur: String, rng: RandomNumberGenerator) -> String:
	var pool: Dictionary = weather_sys.get("pools", {}).get(biome_key, {})
	if pool.is_empty():
		return cur
	if pool.has(cur) and rng.randf() < float(weather_sys.get("stickiness", 0.6)):
		return cur
	var total := 0.0
	for k in pool:
		total += float(pool[k])
	var r: float = rng.randf() * maxf(total, 0.0001)
	for k in pool:
		r -= float(pool[k])
		if r <= 0.0:
			return String(k)
	return cur

# ---------- 養成系統（GDD/16）：純公式放這裡讓 GrowthProbe 能直接斷言 ----------
# 升到下一級的花費：80 + 60×目前等級
func growth_cost(cur_lv: int) -> int:
	return int(growth.get("cost_base", 80)) + int(growth.get("cost_step", 60)) * cur_lv

# 套用兵科等級到出場屬性（回傳 [hp, weapon]；不改 data/ 基準值，敵軍不吃）
func growth_apply(base_hp: int, w: Dictionary, lv: int) -> Array:
	if lv <= 0:
		return [base_hp, w]
	var hp: int = int(round(base_hp * (1.0 + float(growth.get("hp_per_lv", 0.05)) * lv)))
	var w2: Dictionary = w.duplicate(true)
	w2["acc"] = minf(float(growth.get("acc_cap", 0.95)),
			float(w.get("acc", 0.7)) + float(growth.get("acc_per_lv", 0.015)) * lv)
	w2["atk"] = int(round(float(w.get("atk", 10)) * (1.0 + float(growth.get("atk_per_lv", 0.03)) * lv)))
	return [hp, w2]

# 濺射遮蔽（GDD/01 §4b defilade）：破片走直線，壕溝/彈坑裡的人只吃頂上的那份
func splash_defilade(in_trench: bool, in_crater: bool) -> float:
	var td: Dictionary = terrain_combat.get("damage", {})
	if in_trench:
		return float(td.get("splash_trench", 0.5))
	if in_crater:
		return float(td.get("splash_crater", 0.65))
	return 1.0
