# Biome.gd — 場地生態設定（GDD/04 地形類型 → 場景層的執行版）。
#
# 為什麼要有這一支：maps.json 早就有 10 張圖（城鎮/沙漠/森林/海灘/海峽/港口…），
# 每張都帶 ground 色、sky 時段、waters 水域——但 Godot 場景層從來沒讀，
# 全部畫成同一種草原（使用者 2026-07-26 指正：每種場地都要做，標準一致）。
# 這裡把「一張圖長什麼樣」收斂成一份設定，Terrain/Main/Props 只讀設定，不各自寫死。
#
# 資料與邏輯分離（專案鐵律 3）：數值只來自 maps.json 與本表；
# 本表的鍵＝地圖 id 前綴的生態類型，不含任何一張圖專屬的座標。
class_name Biome

# 各生態的場景參數。顏色是「疊在 maps.json ground 色上的配件色」；
# ground 基色一律讀圖上的 ground 欄位（美術在資料裡定過的，不在碼裡再定一次）。
#   grass_density: 全圖矮草的間距倍率（1=草原標準，0=無草）
#   grass_tint: 草的色調（沙漠枯黃、森林深綠）
#   tree_mult: 樹量倍率（0=無樹改巨石）
#   rock_mult: 巨石量倍率（沙漠/海岸用）
#   dirt/rock: 斑塊與陡坡的配件色
#   backdrop: 遠山三層的基色（近/中/遠）
const PROFILES := {
	"grass": {
		"grass_density": 1.0, "grass_tint": Color(1, 1, 1), "tree_mult": 1.0, "rock_mult": 0.0,
		"dirt": Color(0.25, 0.20, 0.13), "rock": Color(0.27, 0.26, 0.24),
		"backdrop": [Color(0.26, 0.31, 0.28), Color(0.40, 0.45, 0.50), Color(0.55, 0.62, 0.72)],
	},
	"mud": {      # 壕溝戰場：草稀、泥深、樹少（砲火轟過的地）
		"grass_density": 0.45, "grass_tint": Color(0.85, 0.78, 0.55), "tree_mult": 0.25, "rock_mult": 0.3,
		"dirt": Color(0.27, 0.21, 0.14), "rock": Color(0.25, 0.23, 0.20),
		"backdrop": [Color(0.30, 0.29, 0.26), Color(0.44, 0.42, 0.40), Color(0.58, 0.58, 0.60)],
	},
	"desert": {   # 無草無樹；巨石與礫石；沙色遠山
		"grass_density": 0.0, "grass_tint": Color(1, 1, 1), "tree_mult": 0.0, "rock_mult": 1.0,
		"dirt": Color(0.62, 0.50, 0.32), "rock": Color(0.55, 0.46, 0.34),
		"backdrop": [Color(0.52, 0.42, 0.28), Color(0.66, 0.55, 0.40), Color(0.78, 0.68, 0.54)],
	},
	"forest": {   # 密林：樹加倍、草深綠茂密
		"grass_density": 1.3, "grass_tint": Color(0.75, 1.0, 0.72), "tree_mult": 2.2, "rock_mult": 0.2,
		"dirt": Color(0.20, 0.16, 0.10), "rock": Color(0.24, 0.24, 0.21),
		"backdrop": [Color(0.18, 0.26, 0.20), Color(0.30, 0.40, 0.36), Color(0.46, 0.56, 0.58)],
	},
	"urban": {    # 城鎮/都市：草稀、樹少（行道樹等級）、灰調遠景
		"grass_density": 0.30, "grass_tint": Color(0.9, 0.95, 0.82), "tree_mult": 0.35, "rock_mult": 0.0,
		"dirt": Color(0.33, 0.31, 0.28), "rock": Color(0.36, 0.35, 0.33),
		"backdrop": [Color(0.32, 0.33, 0.35), Color(0.45, 0.46, 0.50), Color(0.60, 0.62, 0.68)],
	},
	"coast": {    # 海灘/海峽/港口的陸地部分：沙土帶乾草，樹稀
		"grass_density": 1.15, "grass_tint": Color(0.94, 1.0, 0.76), "tree_mult": 0.8, "rock_mult": 0.35,
		"dirt": Color(0.60, 0.52, 0.38), "rock": Color(0.50, 0.46, 0.40),
		"backdrop": [Color(0.34, 0.40, 0.42), Color(0.48, 0.55, 0.60), Color(0.62, 0.70, 0.78)],
	},
}

# 地圖 id → 生態類型。加新圖時：maps.json 加圖，這裡補一行（或圖上直接給 biome 欄位覆蓋）。
const MAP_BIOME := {
	"plain": "grass", "tutorial": "grass",
	"verdun": "mud",
	"town": "urban", "urban": "urban",
	"desert": "desert",
	"forest": "forest",
	"beach": "coast", "strait": "coast", "harbor": "coast",
}

static func of(map_data: Dictionary) -> Dictionary:
	var key: String = map_data.get("biome", MAP_BIOME.get(map_data.get("id", ""), "grass"))
	var p: Dictionary = PROFILES.get(key, PROFILES["grass"]).duplicate()
	p["key"] = key
	# ground 基色：讀圖上的 hex（美術定過的），沒有就用草原綠
	p["ground"] = Color.from_string(str(map_data.get("ground", "#7a8f5a")), Color(0.48, 0.56, 0.35))
	p["sky"] = str(map_data.get("sky", "day"))
	return p

# 天色時段（讀 maps.json 的 sky 欄位：day/dawn/dusk/night）。
# 回傳太陽角度/色溫/能量與環境參數，由 Main 套用——同一張圖的光照要跟資料一致，
# 夜襲章節（harbor）就該是夜色，不是每張都黃昏。
const SKY_PRESETS := {
	"day":  {"sun_deg": Vector3(-38, 128, 0), "sun_color": Color(1.0, 0.95, 0.86), "sun_energy": 1.2,
			"ambient": 0.30, "top": Color(0.24, 0.44, 0.74), "horizon": Color(0.80, 0.85, 0.88),
			"fog": Color(0.70, 0.74, 0.72), "mul": Color(1, 1, 1)},
	"dawn": {"sun_deg": Vector3(-14, 96, 0), "sun_color": Color(1.0, 0.78, 0.58), "sun_energy": 1.15,
			"ambient": 0.22, "top": Color(0.30, 0.38, 0.60), "horizon": Color(0.98, 0.76, 0.56),
			"fog": Color(0.80, 0.70, 0.60), "mul": Color(1.0, 0.88, 0.78)},
	"dusk": {"sun_deg": Vector3(-26, 142, 0), "sun_color": Color(1.0, 0.87, 0.68), "sun_energy": 1.35,
			"ambient": 0.24, "top": Color(0.22, 0.38, 0.66), "horizon": Color(0.92, 0.82, 0.66),
			"fog": Color(0.76, 0.72, 0.62), "mul": Color(1.0, 0.93, 0.82)},
	"night": {"sun_deg": Vector3(-44, 210, 0), "sun_color": Color(0.62, 0.70, 0.92), "sun_energy": 0.42,
			"ambient": 0.10, "top": Color(0.04, 0.06, 0.13), "horizon": Color(0.10, 0.13, 0.22),
			"fog": Color(0.08, 0.10, 0.16), "mul": Color(0.20, 0.24, 0.38)},
}

static func sky_preset(name: String) -> Dictionary:
	return SKY_PRESETS.get(name, SKY_PRESETS["day"])
