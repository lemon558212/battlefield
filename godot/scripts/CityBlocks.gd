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
		# 套件材質整治（2026-07-31 使用者實拍兩個穿幫）：
		#   ① 基座/簷口飾條材質帶 emission → 白天整圈紅光帶（像一圈熔岩）
		#   ② 牆面單面（背面剔除）→ 從某些角度整面牆隱形，室內像剖面娃娃屋
		# 一律關 emission＋雙面渲染。duplicate 後改，不動素材原檔。
		for si in (m3.mesh as Mesh).get_surface_count():
			# ⚠ GLTF 匯入的材質可能在三個層：mesh 表面 / MeshInstance 覆寫 / active。
			#   只改 mesh 表面那層修不到（第一輪實拍紅帶紋絲不動）——用 active 取、
			#   改完寫回 mesh 表面（MultiMesh 只認 mesh 表面層）。
			var sm = (m3.mesh as Mesh).surface_get_material(si)
			if sm == null:
				sm = m3.get_active_material(si)
			if sm is BaseMaterial3D:
				var fixed := (sm as BaseMaterial3D).duplicate() as BaseMaterial3D
				fixed.emission_enabled = false
				fixed.cull_mode = BaseMaterial3D.CULL_DISABLED
				# 亮度壓 0.85＋粗糙度拉滿：紅色貼圖裝飾條在黃昏暖陽下會讀成
				# 霓虹紅光帶（使用者實拍）；壓一檔就回到「褪色油漆」的質感
				# 壓紅通道：套件貼圖的裝飾條是高飽和純紅，黃昏暖陽下讀成霓虹紅光帶
				# （綠色鑑別實驗確認就是這一層）。紅壓多一點、綠藍少一點＝
				# 紅條變「褪色油漆紅」、紅磚變沉穩暗磚，不動幾何。
				fixed.albedo_color = fixed.albedo_color * Color(0.62, 0.72, 0.72, 1.0)
				fixed.roughness = maxf(fixed.roughness, 0.9)
				(m3.mesh as Mesh).surface_set_material(si, fixed)
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
