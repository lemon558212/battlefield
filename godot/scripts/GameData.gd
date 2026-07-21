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

func _ready() -> void:
	nations = _load_json("res://data/nations.json")
	class_base = _load_json("res://data/class_base.json")
	weapons = _load_json("res://data/weapons.json")
	maps = _load_json("res://data/maps.json")
	characters = _load_json("res://data/characters.json")
	vehicle_unlock = _load_json("res://data/vehicle_unlock.json")
	terrain_mobility = _load_json("res://data/terrain_mobility.json")
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
