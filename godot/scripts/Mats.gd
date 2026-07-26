# Mats.gd — 共用 PBR 材質庫（GDD/06、GDD/14 §0a）。
#
# 為什麼要有這一支：使用者 2026-07-26 指正「3A 遊戲那種場景還沒有」。實拍檢視後，
# 最大的破口不是多邊形數，是**所有東西都是純色 albedo**——沒有貼圖、沒有法線、
# 沒有粗糙度變化，於是白牆是死白、水泥跟石頭同一種塑膠感、磚牆只是紅色方塊。
# 低多邊形＋好貼圖看起來像美術風格；低多邊形＋純色看起來像未完成的原型。
#
# 素材來源：Downtown City MegaKit [Standard]（本機素材包，2048² BaseColor/Normal/ORM），
# 授權文字複製在 assets/textures/DowntownCity_License.txt。
#
# ⚠ UV 一律「世界座標公尺」：牆體是好幾十個箱子烤進同一張網格的（見 Building._emit_box），
#   每個箱子各自 0~1 的 UV 會讓磚縫在接縫處錯開、而且大小不一。用世界座標投影，
#   相鄰箱子的貼圖自然接得上，磚塊的實際尺寸也才會固定。
# ⚠ ORM 貼圖（Occlusion/Roughness/Metallic 打包在 RGB）要用 ORMMaterial3D，
#   塞進 StandardMaterial3D 的 roughness_texture 會整片變成金屬感。
class_name BattleMats

const TEX_DIR := "res://assets/textures/"

static var _cache := {}

# name＝貼圖組名（T_<name>_BaseColor.png 等）；uv_m＝一次貼圖循環代表幾公尺；
# tint＝疊在貼圖上的色調（純色時代的顏色可以保留一點，維持既有配色感）。
# use_albedo=false＝只吃法線與粗糙度，顏色留給頂點色。地表要的是這個：
# 顏色必須維持草綠（頂點色算出來的），但要有顆粒與凹凸感；把土色貼圖乘上去
# 只會把草地染成灰泥（第一版實拍就是一片水泥色的「草地」）。
static func pbr(name: String, uv_m: float, rough := 1.0, tint := Color.WHITE,
		use_albedo := true) -> BaseMaterial3D:
	var key := "%s|%.2f|%.2f|%s|%s" % [name, uv_m, rough, tint.to_html(false), use_albedo]
	if _cache.has(key):
		return _cache[key]
	var base: Texture2D = _tex(name, "BaseColor")
	var orm: Texture2D = _tex(name, "ORM")
	var nrm: Texture2D = _tex(name, "Normal")
	var m: BaseMaterial3D
	if orm != null:
		var om := ORMMaterial3D.new()
		om.orm_texture = orm
		m = om
	else:
		var sm := StandardMaterial3D.new()
		sm.roughness = rough
		m = sm
	if base != null and use_albedo:
		m.albedo_texture = base
	m.albedo_color = tint
	if nrm != null:
		m.normal_enabled = true
		m.normal_texture = nrm
		m.normal_scale = 1.0
	# UV 是公尺，縮成「幾公尺一循環」
	var s: float = 1.0 / maxf(uv_m, 0.01)
	m.uv1_scale = Vector3(s, s, 1.0)
	m.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	_cache[key] = m
	return m

static func _tex(name: String, kind: String) -> Texture2D:
	var p := "%sT_%s_%s.png" % [TEX_DIR, name, kind]
	if not ResourceLoader.exists(p):
		return null
	return load(p) as Texture2D

# 合併網格用的 UV：依面法線挑兩個世界軸投影（三平面投影的簡化版）。
# 回傳單位＝公尺，交給材質的 uv1_scale 去縮。
static func world_uv(p: Vector3, n: Vector3) -> Vector2:
	var ax: float = absf(n.x)
	var ay: float = absf(n.y)
	var az: float = absf(n.z)
	if ay >= ax and ay >= az:
		return Vector2(p.x, p.z)          # 地板／屋頂：俯視投影
	if ax >= az:
		return Vector2(p.z, -p.y)         # 朝東西的面：z 橫、y 縱（縱軸要翻，貼圖才不上下顛倒）
	return Vector2(p.x, -p.y)             # 朝南北的面
