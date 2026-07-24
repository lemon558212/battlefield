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
var terrain_mobility: Dictionary = {}
var char_look: Dictionary = {}

func _ready() -> void:
	nations = _load_json("res://data/nations.json")
	class_base = _load_json("res://data/class_base.json")
	weapons = _load_json("res://data/weapons.json")
	maps = _load_json("res://data/maps.json")
	characters = _load_json("res://data/characters.json")
	vehicle_unlock = _load_json("res://data/vehicle_unlock.json")
	terrain_mobility = _load_json("res://data/terrain_mobility.json")
	char_look = _load_json("res://data/char_look.json")
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

func hit_chance(shooter, target, dist_px: float) -> float:
	var w: Dictionary = shooter.weapon
	if dist_px > w.get("range", 200):
		return 0.0
	var c: float = w.get("acc", 0.7)
	var ratio: float = dist_px / max(1.0, w.get("range", 200))
	if ratio > 0.5:
		c *= 1.0 - 0.45 * ((ratio - 0.5) / 0.5)
	return clamp(c, 0.0, 0.99)

func damage(shooter, target) -> int:
	var w: Dictionary = shooter.weapon
	var eff: float = w.get("atk", 10)
	var deff: float = GameData.class_base.get(target.cls, {}).get("def", 0)
	var dmg: float = eff * max(0.1, 1.0 - deff / max(1.0, eff) * 0.5)
	return int(max(1, round(dmg)))
