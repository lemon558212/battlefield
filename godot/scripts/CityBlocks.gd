# CityBlocks.gd — town／urban 的城市街區（2026-07-27 使用者第 4 項）。
#
# 為什麼要有：`assets/kits/DowntownCity` 有 153 個模組件，但**專案只用到它的貼圖，
# 模型一個都沒用**。結果 town/urban 兩張圖就是「草原上放六棟程式生成的房子」，
# 完全沒有城市感——遠景空曠、沒有街廓、沒有天際線。
#
# 做法上的取捨：不從 76 個磚牆模組件去「拼」建築（那是關卡編輯器的工作量），
# 而是用 kit 裡三棟**已經組好的整棟**（Large / Medium / Small）排成街廓，
# 再用 Street / Sidewalk / Prop 補地面層。
#
# 三個原則：
#   1. **戰場內只放人行道與街道小物**（可通行、不擋路），整棟建築一律排在戰場外的
#      街廓帶——戰場內的可進入建築仍然是程式生成的 Building.gd（門/窗/樓梯/室內家具
#      那一整套規則都掛在它上面，換成 kit 模型等於全部重做）。
#   2. 一律 MultiMesh。街廓帶有上百棟，一棟一個節點就是上百次 draw call。
#   3. 街廓要對齊街道格線、建築要**貼著街廓邊緣**（沿街面）。真實城市的建築是
#      沿街連續的，隨機散佈會變成「郊區獨棟」，那不是城市。
class_name CityBlocks

# ⚠ 讀 `assets/models/city/`（版控內），不是 `assets/kits/`——後者在 .gitignore 裡，
# 是本機素材原始目錄。專案既有慣例就是「用到哪幾件就複製進 assets/ 並改寫貼圖路徑」，
# 直接讀 kits/ 的話，別台機器 clone 下來會整批載入失敗而且**不會有任何錯誤訊息**。
const KIT := "res://assets/models/city/"
const WHOLE := ["Building_Large_2", "Building_Medium_2_001", "Building_Small_1"]
const GROUND := ["Street_2Lane", "Street_2Lane_noSidewalk", "Sidewalk_Straight_3m",
		"Sidewalk_Corner_Flat_3m", "Sidewalk_Planter"]
const PROPS := ["Prop_Bollard", "Prop_Planter_Single", "Prop_ManholeCover", "Prop_Drain"]

# 載入一個 gltf，回傳 [[mesh, 相對 transform]...] 與量到的外框。
# ⚠ 量外框一定要在「transform 歸零」的狀態下量（同 Main._fit_prop 的理由）：
#   模型檔自帶的位移會讓外框算進一段空白，排出來的街廓就會有莫名其妙的縫。
static func load_parts(host: Node3D, name: String) -> Dictionary:
	var path: String = KIT + name + ".gltf"
	if not ResourceLoader.exists(path):
		return {}
	var res = load(path)
	if res == null:
		return {}
	var inst: Node3D = null
	if res is PackedScene:
		inst = (res as PackedScene).instantiate()
	if inst == null:
		return {}
	host.add_child(inst)
	var parts: Array = []
	var ab := AABB()
	var first := true
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		var m3 := mi as MeshInstance3D
		if m3.mesh == null:
			continue
		var xf: Transform3D = inst.global_transform.affine_inverse() * m3.global_transform
		parts.append([m3.mesh, xf])
		var b: AABB = xf * (m3.mesh as Mesh).get_aabb()
		ab = b if first else ab.merge(b)
		first = false
	host.remove_child(inst)
	inst.queue_free()
	if parts.is_empty():
		return {}
	return {"parts": parts, "aabb": ab}
