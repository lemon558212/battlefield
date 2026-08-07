# Main.gd — 遊戲總機（GDD/13 全量搬遷）：狀態機串起主選單→章節→簡報→立繪對話→部署→
# 回合戰鬥(CP/移動/開槍/簡易迷霧)→勝敗→戰報。戰場身體 Quaternius，角色 identity 走立繪。
extends Node3D

enum St { MENU, STORY, BRIEF, DIALOGUE, DEPLOY, CMD, ENEMY, END }

# 2026-07-25 換骨架體系：全面改用 Quaternius Humanoid Rig（hr_*.fbx）。
# 舊的 *.glb 骨架 Foot 骨掛在 Root、腿不成鏈，做不出蹲姿也接不了真人動作重定向；
# hr_ 骨架階層正確，動作全部由 UAL 真人 mocap 庫即時重定向（Unit._make_anim_source）。
const CLASS_MODEL := {
	"rifleman": "res://assets/models/chars/hr_m_Soldier.fbx", "sniper": "res://assets/models/chars/hr_w_Swat.fbx",
	"mg": "res://assets/models/chars/hr_m_Soldier.fbx", "assault": "res://assets/models/chars/hr_m_Soldier.fbx",
	"at": "res://assets/models/chars/hr_m_Soldier.fbx", "mortar": "res://assets/models/chars/hr_m_Soldier.fbx",
	"engineer": "res://assets/models/chars/hr_m_Worker.fbx", "specops": "res://assets/models/chars/hr_m_SciFi.fbx",
	"sam": "res://assets/models/chars/hr_m_Soldier.fbx",
}
# 2026-07-24 使用者裁定：放棄「立繪轉 3D」(tripo 綁骨爛/正面軸坑多)，改用內建 Quaternius 兵種模型，
# 再依各角色立繪配色「換裝」(data/char_look.json + Unit._apply_look)。骨架乾淨、動畫原生正確、零校正。
# 我方英雄基底：內建模型多為平民，僅 soldier(女性SWAT)/specops(黑色戰術)像軍人，
# 故依「立繪氣質」挑最接近者當基底，再以 char_look.json 換裝上色（2026-07-24 實拍對照表挑選）。
const HERO_MODEL := {
	"sniper":   "res://assets/models/chars/hr_w_Swat.fbx",       # 韓沐霜：女性戰術裝
	"rifleman": "res://assets/models/chars/hr_m_SciFi.fbx",      # 丁小滿：黑色戰術裝
	"engineer": "res://assets/models/chars/hr_m_Worker.fbx",     # 白老師：工兵/工人裝正合適
	"mg":       "res://assets/models/chars/hr_m_Soldier.fbx",    # 雷諾：制服老兵感
	"assault":  "res://assets/models/chars/hr_w_Swat.fbx",       # 艾拉：突擊，戰術裝
	"at":       "res://assets/models/chars/hr_m_Adventurer.fbx", # 巴頓
	"mortar":   "res://assets/models/chars/hr_w_Casual.fbx",     # 賽琳：俐落便裝
	"specops":  "res://assets/models/chars/hr_m_SciFi.fbx",      # 影山：黑色戰術
	"sam":      "res://assets/models/chars/hr_w_Spacesuit.fbx",  # 汀娜：裝甲
}
const CLASS_TINT := {
	"rifleman": Color(0.55, 0.75, 0.45), "sniper": Color(0.35, 0.45, 0.6), "mg": Color(0.7, 0.5, 0.3),
	"assault": Color(0.75, 0.35, 0.3), "at": Color(0.5, 0.4, 0.6), "mortar": Color(0.6, 0.6, 0.35),
	"engineer": Color(0.4, 0.62, 0.55), "specops": Color(0.25, 0.25, 0.3), "sam": Color(0.5, 0.55, 0.7),
}
const WORLD_SCALE := 0.05   # 遊戲座標(px) → 3D 公尺
const SIGHT := 200.0        # 視野半徑(px)

var ui: GameUI
var cam: TacticalCamera
var world: Node3D
var st: int = St.MENU
var chapter := 0
var player_side := 0
var nation := ["", ""]
var map_data := {}
var units: Array = []       # 每個 = Dictionary(單位資料)＋node
var selected = null
var turn := 1
var cp := 0
var cp_max := 6            # GDD/01 §1：基礎 6 + 存活坦克數，上限 10
# ---- 行動模式（GDD/01 §1-2）----
const CP_CAP := 10
const CP_BASE := 6
const PX_PER_AP := 3.0     # 1 AP = 3px
const AP_DECAY := 0.7      # 同一單位第 N 次下令：AP 上限 = 滿 AP × 0.7^(N-1)
var acting = null          # 目前在行動模式的單位（null＝指令模式）
var _act_last := Vector3.ZERO   # 上一幀位置，用來扣 AP
var _ap_ring: MeshInstance3D = null
var enemy_cp := 0          # 敵方階段的 CP 池（與我方同公式）
var _ai_state := ""        # ""＝待派下一個單位；"move"＝移動中；"fire"＝已開火收尾
var _ai_t := 0.0           # 每個敵方行動的逾時保險，避免卡住整場
var _ai_last := Vector3.ZERO   # 上次取樣的位置（停滯偵測用）
var _ai_stall := 0.0           # 已經原地不動多久
var _ai_why := ""          # 這次行動的決策理由（QA 要驗 AI 有照 GDD 的狀態機走）
var _ai_target = null
var budget_left := 0
var _tracers: Array = []
var _enemy_queue: Array = []
var _enemy_t := 0.0
var _zone_mesh: MeshInstance3D = null
var _bld_blk: Array = []          # 室內家具障礙（見 _build_ground 的註解）
var _ap_ring_r := -1.0            # 上次建環用的半徑／圓心（避免每幀重建貼地環）
var _ap_ring_c := Vector3(1e9, 0, 0)
# 掩體登記表（GDD/13 Phase2）：每筆＝{wx,wy,r,val,type}，座標為遊戲 px。
# val＝遮蔽強度 0~1；sandbag 硬掩體、building 全掩體、bush 只給隱蔽(降敵視野)不擋彈。
var _covers: Array = []
# 新腳本的 class_name 要等編輯器掃描過才註冊得到，直接用會 Parse Error（2026-07-26 踩到）。
# 用 preload 引用最保險，不依賴 .godot 的類別快取。
const TERRAIN := preload("res://scripts/Terrain.gd")
const BUILDING := preload("res://scripts/Building.gd")
const PROPS := preload("res://scripts/Props.gd")
const FORTIFY := preload("res://scripts/Fortify.gd")
const TREES := preload("res://scripts/Trees.gd")
const CITY := preload("res://scripts/CityBlocks.gd")
var _buildings: Array = []             # 場上所有建築（牆線段＝視線與碰撞的真相）
var terrain = null                     # 地形高度真相（GDD/14）
# 中景物件與樹的實體障礙（形狀定義見 Props.blockers），座標為遊戲 px。
var _blockers: Array = []
# 矮到「現實裡是踩上去、不是繞過去」的障礙（鐵律 0①＋③）。
# ⚠ 先前全場障礙一律水平推開，沒有任何東西有頂面：0.22m 的沙包會把人往旁邊推，
#   而畫出來卻沒進碰撞表的東西（散落袋、泥土堆）則直接被穿過去——
#   同一批物件「有的擋有的不擋」，這就是使用者說的不一致。
const STEP_UP := 0.5                   # 一步跨得上去的高度（真實約半公尺）
var _low_blk: Array = []               # _blockers 裡 h ≤ STEP_UP 的那些（頂面可站）
# 深水圍欄。⚠ 必須另外存：_build_water() 跑在 _build_ground 前段，而後面那句
#   `_blockers = []`（重建場景用）會把它整個清掉——所以深水從來沒有真的擋過人，
#   畫面上是海、走過去像草地。這是「畫出來的東西沒有碰撞」的又一例。
var _water_blk: Array = []
# 可摧毀的工事段（沙包牆）。爆炸會把它整段打掉：網格消失、碰撞消失、掩體消失。
var _destructibles: Array = []
# 支撐面查詢的粗剔除框（px）。⚠ _ground_height 每幀被呼叫 5 次×單位數
#   （_stick_to_ground 1 次＋_ground_normal 取樣 4 次），沒有粗剔除的話
#   16 單位就是每幀幾千次的建築＋矮障礙迴圈，實測幀時 5.9→10.9ms。
#   矮障礙（含散落瓦礫）會鋪滿全圖，用「聯集外框」剔除等於沒剔除，
#   所以改成空間格網：查詢只掃自己那一格。
const LOWGRID_PX := 100.0            # 格子邊長（px）＝5m
var _low_grid := {}                  # Vector2i(格) -> Array[矮障礙]
var _has_support := false
var _tree_feet: Array = []             # 樹腳位置（px）：Terrain 在樹底補草做過渡
var _pole_spots: Array = []            # 電線桿實際位置（px）：美術特寫取景用
const MAX_BUILDINGS := 24              # 一張圖最多幾棟可進入建築（村莊/街廓要用到十幾棟）
const BODY_R := 0.42                   # 步兵肩寬半徑
# ⚠ 2026-07-27 使用者實測：「從戰車後面可以穿過車尾走到車子中間」。
#   真因＝載具的碰撞是**一個半徑 1.6m 的圓**，而車體是 3.1m 寬 × 6.0m 長的長方形：
#   圓內切於「寬」，車頭與車尾各有約 1.4m 完全沒有實體。長條形的東西必須用長條形的碰撞。
#   VEHICLE_R 保留給「載具本身當移動者」的粗略半徑（車去撞牆），擋人／擋彈改用 OBB。
const VEHICLE_R := 1.6                 # 載具當移動者時的粗略半徑
const VEHICLE_HL := 3.00               # 車體半長（履帶全長 6.0m）
const VEHICLE_HW := 1.75               # 車體半寬（裙板外緣 1.7m、履帶外緣 1.87m）

const GROUND_SHADER := """
shader_type spatial;
// ⚠ 一定要標 source_color：否則這些值會被當成「線性空間」直接用，
// 輸出轉回 sRGB 後整片地面會亮一大截、綠色被洗成薄荷色。
// 這就是 GDD/10 五大事故裡的「sRGB 洗白」，換 Forward+ 時原地重演一次（2026-07-26）。
uniform vec3 grass_a : source_color = vec3(0.34, 0.45, 0.24);
uniform vec3 grass_b : source_color = vec3(0.47, 0.57, 0.31);
uniform vec3 dirt    : source_color = vec3(0.44, 0.39, 0.28);
varying vec3 wp;
void vertex() { wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
float h21(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p){
	vec2 i = floor(p); vec2 f = fract(p); vec2 u = f*f*(3.0-2.0*f);
	return mix(mix(h21(i), h21(i+vec2(1,0)), u.x), mix(h21(i+vec2(0,1)), h21(i+vec2(1,1)), u.x), u.y);
}
void fragment() {
	float n1 = vnoise(wp.xz * 0.35);
	float n2 = vnoise(wp.xz * 1.4);
	vec3 g = mix(grass_a, grass_b, clamp(n1 * 1.25, 0.0, 1.0));
	float d = smoothstep(0.58, 0.82, vnoise(wp.xz * 0.16));
	ALBEDO = mix(g, dirt, d * 0.75) * (0.90 + 0.20 * n2);
	ROUGHNESS = 0.97;
	SPECULAR = 0.05;
}
"""

# 退出前主動釋放靜態快取（2026-08-02）。
# 症狀：每次結束都印「ERROR: 1 resources still in use at exit」，而且在這台機器上
# 每章退出時都伴隨一次 Segmentation fault（退出碼 139）。它不影響 FAILS 判定
# （測試結論在 quit 之前就印完了），但「每章都噴一次紅字」本身就違反
# CLAUDE.md 的驗收標準，而且會蓋掉真正該被看到的退出期錯誤。
# 真因：各類的 `static var` 持有 Resource（ShaderMaterial／GradientTexture2D／
# 材質與 Mesh 快取），靜態變數活到**程式結束**，比引擎關閉資源系統還晚。
# 這些快取全是 lazy init，清掉後若還有人用會自動重建，所以在離開場景樹時清空是安全的。
func _exit_tree() -> void:
	_release_static()

func _release_static() -> void:
	BattleMats.clear_cache()
	Building.clear_cache()
	Unit.clear_cache()
	_soft_tex = null

# 測試結束的統一出口。直接 get_tree().quit() 會在**同一幀**開始關閉引擎，
# 此時大量 MultiMesh／材質／貼圖還活著，Vulkan 裝置銷毀在這台機器上會
# Segmentation fault（退出碼 139，每章一次）。先清掉靜態快取、讓引擎多跑一幀
# 把釋放做完，再要求離開。
# ⚠ 這**不影響測試判定**：結論（FAILS=）在呼叫本函式之前就已經印出來了。
func _quit_test(code: int) -> void:
	_release_static()
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit(code)

func _ready() -> void:
	_build_static()
	ui = GameUI.new()
	add_child(ui)
	ui.menu_story.connect(_open_story)
	ui.menu_versus.connect(_open_story)  # 遭遇戰暫同劇情入口
	ui.chapter_chosen.connect(_open_brief)
	ui.deploy_pick.connect(_on_deploy_pick)
	ui.deploy_go.connect(_start_battle)
	ui.end_turn.connect(_end_player_turn)
	ui.training_open.connect(_open_training)
	ui.training_up.connect(_on_training_up)
	ui.training_back.connect(_open_story)
	_load_growth()
	ui.end_action.connect(_end_action)
	ui.back_menu.connect(_open_menu)
	_open_menu()
	# 測試模式一律靜音（2026-07-30 使用者：「測試階段不要播背景音樂」）——
	# 跑批一跑七小時，BGM 跟著響七小時。靜音掛在 Master bus，不動遊戲本身的音量設定。
	for targ in ["e2e", "selftest", "shotseq", "mapshots", "play", "scene",
			"walk", "stress", "trainshot", "blkdump", "artshots", "idledrift", "locochk"]:
		if targ in OS.get_cmdline_user_args():
			AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)
			# ★★測試模式固定亂數種子（2026-08-04）。
			#   Godot 4 每次啟動都會自動隨機化全域 RNG，於是**同一份程式碼**
			#   兩輪跑出不同結果：20:25 那輪 play 是 0 FAIL，22:02 同一段就
			#   「走不進屋」。抖動的測試抓到的失敗沒辦法重現，也沒辦法證明修好了。
			#   理由與既有的「測試不吃養成存檔＝結果要可重現」完全同一條
			#   （_boot_to_battle 的 _growth 歸零）。
			#   ⚠ 只在測試模式固定；真正玩的時候天候、AI 仍該是隨機的。
			seed(20260804)
			print("[test] 固定亂數種子 20260804（測試結果要可重現）")
			break
	# 實玩飄移守望：一併打開記帳，這樣抓到時才知道是誰推的
	if "driftwatch" in OS.get_cmdline_user_args():
		_drift_watch = true
		_drift_dbg = true
		print("[driftwatch] 已啟用：照平常玩即可，沒按鍵卻位移超過 1cm 就會記一筆")
	if "e2e" in OS.get_cmdline_user_args():
		_e2e()
	elif "selftest" in OS.get_cmdline_user_args():
		_selftest()
	elif "shotseq" in OS.get_cmdline_user_args():
		_shotseq()
	elif "mapshots" in OS.get_cmdline_user_args():
		_mapshots()
	elif "play" in OS.get_cmdline_user_args():
		_playtest()
	elif "scene" in OS.get_cmdline_user_args():
		_sceneshots()
	elif "walk" in OS.get_cmdline_user_args():
		_walk_all()
	elif "stress" in OS.get_cmdline_user_args():
		_stress()
	elif "locochk" in OS.get_cmdline_user_args():
		_locochk()
	elif "idledrift" in OS.get_cmdline_user_args():
		_idledrift()
	elif "trainshot" in OS.get_cmdline_user_args():
		_trainshot()
	elif "blkdump" in OS.get_cmdline_user_args():
		_blkdump()
	elif "artshots" in OS.get_cmdline_user_args():
		_artshots()
	elif "lookshots" in OS.get_cmdline_user_args():
		_lookshots()
	elif "slopetest" in OS.get_cmdline_user_args():
		_slopetest()
	elif "sinkscan" in OS.get_cmdline_user_args():
		_sinkscan()

# ---------- 端對端測試：從主選單開始，全程合成滑鼠點擊走完整真實流程 ----------
# （治「測試從中間插進去、跳過真實 UI 流程」的驗證盲區——使用者是從頭玩的）
func _find_btn(txt: String) -> Button:
	for n in ui.root.find_children("*", "Button", true, false):
		var b := n as Button
		if b.text.replace(" ", "").replace("　", "").contains(txt.replace(" ", "")):
			return b
	return null

func _click_btn(txt: String) -> bool:
	var b := _find_btn(txt)
	if b == null:
		print("[e2e] FAIL 找不到按鈕: ", txt)
		return false
	_send_click(b.get_global_rect().get_center())
	await get_tree().create_timer(0.35).timeout
	return true

# 連拍模式（`-- shotseq`）：啟動後依時間序拍幾張，專門抓「畫面上有東西一直在動」
# 這種肉眼才看得到、數值驗證抓不到的問題（使用者 2026-07-26：「啟動遊戲有一直往下拉」）。
# 逐圖巡場（`-- mapshots`）：10 張圖各建一次場景、俯瞰＋人眼高度各拍一張。
# 使用者 2026-07-26：「城鎮、沙灘、沙漠、叢林都要做，而且標準都是一樣」——
# 標準一致的意思是每張圖都有同一套驗證：建得起來（無紅字）、有自己的地貌配色。
func _mapshots() -> void:
	await get_tree().create_timer(0.6).timeout
	ui.root.visible = false      # 主選單 UI 會整面蓋住場景（第一輪拍出來全是選單）
	# 只拍章節圖（ch01~ch15）；舊的 10 張是自由模式用的，不必每次都拍。
	# 用 `-- mapshots all` 才拍全部。
	var only_ch: bool = not ("all" in OS.get_cmdline_user_args())
	for id in GameData.maps.keys():
		if only_ch and not String(id).begins_with("ch"):
			continue
		map_data = GameData.maps[id]
		_teardown_world()
		await get_tree().process_frame
		_build_ground()
		var mwp: float = map_data.get("w", 960)
		var mhp: float = map_data.get("h", 600)
		cam.clear_tps()
		cam.set_follow(null)
		cam.focus = _to3d(mwp * 0.5, mhp * 0.55) + Vector3(0, 1.0, 0)
		cam.dist = 44.0
		cam.pitch_deg = 32.0
		cam.yaw = 0.35
		await get_tree().create_timer(1.0).timeout
		await _snap("res://map_%s_over.png" % id)
		cam.dist = 8.0
		cam.pitch_deg = 6.0
		await get_tree().create_timer(0.5).timeout
		await _snap("res://map_%s_eye.png" % id)
		print("[mapshots] %s biome=%s sky=%s OK" % [id, terrain.biome.get("key", "?"),
				map_data.get("sky", "day")])
	_quit_test(0)

# ---------- 場景 vs 劇本稽核（-- scene）----------
# 使用者 2026-07-27：「場景也沒有像你說的有被和劇情修正好」。
# maps.json 裡每個 solid 都寫了 note（正門哨所／營舍A／武器庫／雷達站／鐘樓），
# 但沒有人真的一棟一棟拍過看它「認不認得出來」。這裡對第一章的地圖：
#   ① 正上方俯拍整張圖（看得出基地的格局嗎）
#   ② 每一棟 solid 各拍一張人眼高度的近照，檔名帶 note
# 光有資料不算做好——玩家看不出那是雷達站，劇情就沒有落地。
func _sceneshots() -> void:
	await get_tree().create_timer(0.6).timeout
	ui.root.visible = false
	var ch: Dictionary = GameData.story[0]
	var mid: String = String(ch.get("map", "tutorial"))
	map_data = GameData.maps[mid]
	_teardown_world()
	await get_tree().process_frame
	_build_ground()
	# 部署藍框不是「場景」的一部分：稽核圖裡留著它會蓋在海面上，
	# 看起來像水域鋪了一張藍地毯（本輪一度誤判成水面的問題）。
	if is_instance_valid(_zone_mesh):
		_zone_mesh.visible = false
	var mwp: float = map_data.get("w", 960)
	var mhp: float = map_data.get("h", 600)
	cam.clear_tps()
	cam.set_follow(null)
	# 正上方：pitch 88 度（90 度時 look_at 的 up 向量會退化）
	cam.focus = _to3d(mwp * 0.5, mhp * 0.5)
	cam.dist = 42.0
	cam.pitch_deg = 88.0
	cam.yaw = 0.0
	await get_tree().create_timer(1.2).timeout
	await _snap("res://scene_ch1_top.png")
	# 斜俯瞰：看得出高低與體積
	cam.dist = 40.0
	cam.pitch_deg = 34.0
	cam.yaw = 0.5
	await get_tree().create_timer(0.8).timeout
	await _snap("res://scene_ch1_iso.png")
	var i := 0
	for sd in map_data.get("solids", []):
		i += 1
		var cx: float = float(sd.get("x", 0)) + float(sd.get("w", 120)) * 0.5
		var cy: float = float(sd.get("y", 0)) + float(sd.get("h", 120)) * 0.5
		# ⚠ dist 15／pitch 14 會把鏡頭放進隔壁那棟房子裡（實拍：整張是一面牆）。
		#   建築群很密，稽核鏡頭要拉遠並抬高才拍得到「這一棟長什麼樣」。
		cam.focus = _to3d(cx, cy) + Vector3(0, 2.4, 0)
		cam.dist = 26.0
		cam.pitch_deg = 26.0
		cam.yaw = 0.8
		await get_tree().create_timer(0.7).timeout
		await _snap("res://scene_ch1_%d.png" % i)
		print("[scene] %d %s kind=%s floors=%s burning=%s"
				% [i, String(sd.get("note", "?")), String(sd.get("kind", "民房")),
				sd.get("floors", 1), sd.get("burning", false)])
	# 劇情要的「工事」拍給人看：沙包線、壕溝、道路。資料有 23 段沙包與 2 條壕溝，
	# 但從來沒有人拍過近照確認它們真的在畫面上。
	# ⚠ pitch 要夠高（鏡頭抬到屋頂之上），否則稽核鏡頭會鑽進隔壁那棟房子裡，
	#   拍出來整張都是一面牆（本輪連續踩到兩次）。
	var spots := [["sandbag", 366.0, 300.0, 13.0, 42.0], ["trench", 520.0, 300.0, 13.0, 44.0],
			["road", 700.0, 300.0, 15.0, 40.0], ["shore", 300.0, 300.0, 17.0, 30.0]]
	for sp in spots:
		cam.focus = _to3d(float(sp[1]), float(sp[2])) + Vector3(0, 0.8, 0)
		cam.dist = float(sp[3])
		cam.pitch_deg = float(sp[4])
		cam.yaw = 1.55
		await get_tree().create_timer(0.6).timeout
		await _snap("res://scene_ch1_%s.png" % String(sp[0]))
	# 火與煙：粒子要時間長出來（煙的壽命 5.5 秒），等滿一輪再拍，否則拍到的是剛冒頭的幾顆
	var fire_at := Vector2(630.0, 110.0)
	for sd2 in map_data.get("solids", []):
		if bool(sd2.get("burning", false)):
			fire_at = Vector2(float(sd2.get("x", 0)) + float(sd2.get("w", 120)) * 0.5,
					float(sd2.get("y", 0)) + float(sd2.get("h", 120)) * 0.5)
	cam.focus = _to3d(fire_at.x, fire_at.y) + Vector3(0, 6.0, 0)
	cam.dist = 24.0
	cam.pitch_deg = 16.0
	cam.yaw = 1.2
	await get_tree().create_timer(7.0).timeout
	await _snap("res://scene_ch1_fire.png")
	cam.dist = 12.0
	await get_tree().create_timer(1.5).timeout
	await _snap("res://scene_ch1_fire_near.png")
	print("[scene] 建築數=%d 沙包段=%d 壕溝=%d 道路=%d" % [
			map_data.get("solids", []).size(), map_data.get("sandbags", []).size(),
			map_data.get("trenches", []).size(), map_data.get("roads", []).size()])
	print("[scene] DONE")
	_quit_test(0)

# ---------- 實際遊玩驗證（-- play）----------
# ---------- 全地圖走查（2026-07-27 使用者：「人物全地圖每一個角落都測試」）----------
# 做法：讓角色**用走的**（按 W，跟玩家完全同一條路徑）沿蛇行路線走遍全圖，
# 途中每 0.2 秒檢查六條不變量。不用瞬移、不直呼內部函式——瞬移過去只能證明
# 「那個座標沒問題」，證明不了「走得過去」，而使用者撞到的每一個 bug 都是走出來的。
#
# 六條不變量（任何一條破了就記座標、拍照、繼續走完，最後一次列出全部）：
#   1. 陷進實體：_resolve_solids 會把人推開 → 表示人在障礙/牆體裡面
#   2. 浮空或陷地：|腳底 - 地面高度| > 0.3m
#   3. 走進不該走的深水：水深 > 1.35m（及胸，規則上形同不可通行）
#   4. 卡死：整段路走完時限還離目標 > 2m，而且沒有合法理由（前方就是障礙才算合法）
#   5. 鏡頭穿牆：頭 → 鏡頭之間有實體
#   6. 出界：被 _clamp_to_map 夾住以外的地方
const WALK_STEP_PX := 110.0        # 蛇行取樣間距（px）＝5.5m
const WALK_SPEED_MIN := 0.9        # 低於這個速度（m/s）持續兩秒就算卡住

func _walk_all() -> void:
	if not await _boot_to_battle("walk"): _quit_test(1); return
	var mwp: float = map_data.get("w", 960)
	var mhp: float = map_data.get("h", 600)
	var pu = _deployed[0]
	# 敵人會打斷走查（警戒射擊、鏡頭被拉走）：全部移到地圖外並上護盾
	for e in units:
		if e["side"] != player_side and is_instance_valid(e["node"]):
			e["alive"] = false
			e["node"].visible = false
	var save := _shield(pu)
	_begin_action(pu)
	pu["ap"] = 999999.0
	pu["ap_max"] = 999999.0
	pu["node"].auto_stance = false
	pu["node"].stance_cmd = "stand"
	# 蛇行路線：一列一列掃過去，涵蓋每一個角落（含四角與貼邊）
	var cols: int = maxi(3, int(mwp / WALK_STEP_PX))
	var rows: int = maxi(3, int(mhp / WALK_STEP_PX))
	var pts: Array = []
	for r in range(rows + 1):
		var py: float = clampf(mhp * float(r) / float(rows), 18.0, mhp - 18.0)
		for c in range(cols + 1):
			var ci: int = c if (r % 2 == 0) else (cols - c)
			var px: float = clampf(mwp * float(ci) / float(cols), 18.0, mwp - 18.0)
			pts.append(Vector2(px, py))
	print("[walk] 路線 %d 個取樣點（%d 列 × %d 行，間距 %.1fm），地圖 %.0f×%.0f m"
			% [pts.size(), rows + 1, cols + 1, WALK_STEP_PX * WORLD_SCALE,
			mwp * WORLD_SCALE, mhp * WORLD_SCALE])
	# 起點必須在**乾的陸地上**。第一版直接放 pts[0]＝地圖左上角（18,18），
	# 而那裡在海裡（岸線在 x≈281）→ 整個第一列都在水下，「走進深水」的檢查
	# 從第一秒就一直 FAIL，測的是我自己的擺位不是遊戲。
	# ⚠ 前提不成立的測試等於沒測——起點找不到就大聲喊，不要默默從水裡開始。
	var start_i := -1
	for i0 in pts.size():
		if terrain == null or terrain.water_depth(pts[i0].x, pts[i0].y) <= 0.02:
			var w0: Vector3 = _to3d(pts[i0].x, pts[i0].y)
			if _resolve_solids(w0, BODY_R, pu).distance_to(w0) < 0.06:
				start_i = i0
				break
	if start_i < 0:
		push_error("[walk] 全圖找不到一個乾的空地當起點")
		_quit_test(1)
		return
	pu["node"].global_position = _to3d(pts[start_i].x, pts[start_i].y)
	pu["wx"] = pts[start_i].x
	pu["wy"] = pts[start_i].y
	print("[walk] 起點 px(%.0f,%.0f)（第 %d 個點；前面的都在海裡或障礙裡）"
			% [pts[start_i].x, pts[start_i].y, start_i])
	await get_tree().create_timer(0.5).timeout

	var bad := {"solid": [], "air": [], "deep": [], "stuck": [], "cam": [], "oob": []}
	_walk_bad = bad
	_walk_checked = 0
	var reached := 0
	for i in range(start_i + 1, pts.size()):
		var goal: Vector2 = pts[i]
		# ★★覆蓋率（2026-07-28 自我檢討）：第一版是「按著 W 直線走」，河變成真障礙之後
		#   129 段只抵達 20 段——**測試沒有真的走遍每個角落，那就等於沒測**。
		#   改成跟玩家（與 AI）一樣會繞路：直線不通就用遊戲自己的 `_avoid_goal`
		#   找一個中繼點，走過去再重新對準目標，最多繞兩次。
		var ok: bool = await _walk_leg(pu, goal)
		if not ok:
			for _detour in 2:
				var way: Vector3 = _avoid_goal(pu["node"].global_position,
						_to3d(goal.x, goal.y), BODY_R)
				var wp2 := Vector2(way.x / WORLD_SCALE + mwp * 0.5,
						way.z / WORLD_SCALE + mhp * 0.5)
				if wp2.distance_to(_live_px(pu)) * WORLD_SCALE < 1.0:
					break                      # 繞路點就在腳下＝繞不出去
				await _walk_leg(pu, wp2)
				ok = await _walk_leg(pu, goal)
				if ok:
					break
		if ok:
			reached += 1
		else:
			# 走不到不一定是 bug：目標可能在建築裡、水裡、障礙後面。
			# 只有「目標是一塊乾淨的空地、而且直線本來就通」卻走不到，才是真的卡死。
			var gw: Vector3 = _to3d(goal.x, goal.y)
			var gfix: Vector3 = _resolve_solids(gw, BODY_R, pu)
			var goal_blocked: bool = Vector2(gfix.x - gw.x, gfix.z - gw.z).length() > 0.06
			var goal_wet: bool = terrain != null and terrain.water_depth(goal.x, goal.y) > 0.9
			var goal_in_bld := false
			for bd in _buildings:
				if bd.rect.has_point(goal):
					goal_in_bld = true
					break
			# 陡坡也是合法理由（ch11 群山）：爬坡限速 2.4m/s 是物理，走不快不是卡死。
			# 沿直線取樣 8 點，任何一點坡度 >0.35 就不以卡死論。
			var steep := false
			if terrain != null:
				var from_px := _live_px(pu)
				for si in range(1, 8):
					var sp2: Vector2 = from_px.lerp(goal, float(si) / 8.0)
					if terrain.slope_at(sp2.x, sp2.y) > 0.35:
						steep = true
						break
			if _path_clear(pu["node"].global_position, gw, BODY_R) 					and not (goal_blocked or goal_wet or goal_in_bld or steep):
				bad["stuck"].append([_live_px(pu), goal, _live_px(pu).distance_to(goal) * WORLD_SCALE])
	var checked: int = _walk_checked
	print("[walk] 走完 %d 段，抵達 %d 段；共 %d 次取樣檢查" % [pts.size() - 1, reached, checked])
	var total := 0
	for k in bad:
		total += (bad[k] as Array).size()
	var names := {"solid": "陷進實體(人在障礙裡)", "air": "浮空或陷地(>0.3m)",
			"deep": "走進深水(>1.35m)", "stuck": "卡死(目標是空地卻走不到)",
			"cam": "鏡頭穿牆", "oob": "走出地圖"}
	for k in ["solid", "air", "deep", "stuck", "cam", "oob"]:
		var arr: Array = bad[k]
		if arr.is_empty():
			print("[walk][%s] 0 次 OK" % names[k])
			continue
		print("[walk][%s] FAIL %d 次，前 6 筆：" % [names[k], arr.size()])
		for j in mini(6, arr.size()):
			print("    ", arr[j])
	# 到現場拍照：每一類的第一個位置各拍一張，不要只給座標
	var shot := 0
	for k2 in ["solid", "air", "deep", "stuck", "cam", "oob"]:
		var arr2: Array = bad[k2]
		if arr2.is_empty():
			continue
		var e0 = arr2[0]
		var pos: Vector2 = e0 if e0 is Vector2 else (e0[0] as Vector2)
		pu["node"].global_position = _to3d(pos.x, pos.y)
		pu["wx"] = pos.x
		pu["wy"] = pos.y
		await get_tree().create_timer(0.6).timeout
		await _snap("res://walk_ch%02d_bad_%s.png" % [_test_chapter(), k2])
		shot += 1
	_unshield(pu, save)
	print("[walk] ch%02d FAILS=%d（拍了 %d 張現場照）" % [_test_chapter(), total, shot])
	print("[walk] DONE")
	_quit_test(0)

var _walk_bad := {}
var _walk_checked := 0

# 走一段（按 W，跟玩家同一條路徑），沿途每 0.2 秒檢查六條不變量。
# 回傳是否抵達（離目標 1.2m 內）。
func _walk_leg(pu, goal: Vector2) -> bool:
	var mwp: float = map_data.get("w", 960)
	var mhp: float = map_data.get("h", 600)
	var g3: Vector3 = _to3d(goal.x, goal.y)
	var dv: Vector3 = g3 - pu["node"].global_position
	if Vector2(dv.x, dv.z).length() < 0.4:
		return true
	cam.tps_yaw = rad_to_deg(atan2(dv.x, dv.z))
	await get_tree().create_timer(0.12).timeout
	var dist_m: float = _live_px(pu).distance_to(goal) * WORLD_SCALE
	var budget: float = dist_m / 1.0 + 3.0        # 涉水會慢到一半，預算要給夠
	var t := 0.0
	var slow := 0.0
	var air_run := 0
	var last: Vector2 = _live_px(pu)
	_press_key(KEY_W, true)
	while t < budget:
		await get_tree().create_timer(0.2).timeout
		t += 0.2
		# 死人不走路：單位中途陣亡（迎擊/交火）就中止這一段。
		# 不中止的話會對凍結的屍體連續取樣，而死亡已把鏡頭切回俯瞰——
		# 「頭→鏡頭」射線橫跨半張地圖，鏡頭穿牆檢查全是假警報（ch02 壓測 12 筆）。
		if not pu["alive"] or not is_instance_valid(pu["node"]):
			break
		var now: Vector2 = _live_px(pu)
		var moved: float = now.distance_to(last) * WORLD_SCALE
		last = now
		_walk_checked += 1
		var wp: Vector3 = pu["node"].global_position
		# 判準要跟遊戲實際用的落位函式同一支：走查用 _resolve_solids、遊戲用 _settle
		# 的話，量的是「解算前」的狀態，邊界上必然天天報 FAIL（同一條規則兩個數字）
		var fixed: Vector3 = _settle(wp, BODY_R, pu)
		if Vector2(fixed.x - wp.x, fixed.z - wp.z).length() > 0.06:
			_walk_bad["solid"].append(now)
		# ⚠ 「離地 0.3m」單次成立不是 bug——從 0.5m 河堤走下來本來就在自由落體。
		#   連續四次（0.8 秒）才算：0.8 秒的自由落體是 3.1m，比最深的壕溝還深。
		var gnd: float = _ground_height(wp)
		if absf(wp.y - gnd) > 0.30:
			air_run += 1
			if air_run >= 4:
				_walk_bad["air"].append([now, wp.y - gnd])
				air_run = 0
		else:
			air_run = 0
		var wd: float = terrain.water_depth(now.x, now.y) if terrain != null else 0.0
		if wd > BattleTerrain.WADE_MAX:
			_walk_bad["deep"].append([now, wd])
		if now.x < -1.0 or now.y < -1.0 or now.x > mwp + 1.0 or now.y > mhp + 1.0:
			_walk_bad["oob"].append(now)
		# 鏡頭穿牆只在「TPS 真的跟拍這個人」時才有意義（俯瞰鏡頭本來就隔很遠）
		if cam.is_tps() and _wall_ray(wp + Vector3(0, 1.6, 0), cam.global_position) < 0.92:
			_walk_bad["cam"].append(now)
			# 兇手識別：不印出「撞到什麼」的鏡頭穿牆報告只能猜（ch02 查了兩輪）
			print("[walkcam] px=(%.0f,%.0f) 擋住頭→鏡頭的是：%s"
					% [now.x, now.y, _wall_ray_why(wp + Vector3(0, 1.6, 0), cam.global_position)])
		if now.distance_to(goal) * WORLD_SCALE < 0.9:
			break
		slow = (slow + 0.2) if moved < WALK_SPEED_MIN * 0.2 else 0.0
		if slow >= 2.0:
			break                                  # 兩秒沒動：交給呼叫端決定要不要繞路
	_press_key(KEY_W, false)
	return _live_px(pu).distance_to(goal) * WORLD_SCALE < 1.2

# ---------- 動作流暢度量測（-- locochk chNN）2026-08-07 ----------
# 為什麼要有這一支：「滑步修好了」「轉向變平順了」全是主觀說法，而本專案已經被
# 「看起來對、其實沒修好」坑過三次。這支把每一項都變成可以印出來的數字。
#
# 核心量法——**站立中的腳，在世界座標上不應該移動**。
#   每幀取兩隻腳踝的世界座標；離地 < 6cm 視為「踩在地上」。
#   踩著的那隻腳如果還在水平位移，位移量就是實打實的滑步，無從狡辯。
#   評分用比值：planted_slide / body_move。腳完全不滑＝0，腳跟著身體一起滑＝1。
# ★滑步指標（2026-08-07 第二版，第一版有門檻依賴的弱點）。
#   第一版：先用「腳踝離地 < 6cm」判斷哪隻腳踩著，再累加它的水平位移。
#   問題是那個門檻跟骨架尺度、姿勢都有關——蹲行時腳本來就抬不高，
#   擺盪中的腳也被算成踩地，比值被灌水到 0.48（看起來像滑步，其實是量錯）。
#   第二版直接用步態的物理定義：**任何時刻至少有一隻腳是靜止的**。
#       slide = Σ min(|Δ左腳|, |Δ右腳|) / Σ |Δ身體|
#   完美步行→0（總有一隻腳釘著），整個人平移滑行→1（兩隻腳都跟著身體走）。
#   不需要任何門檻，也不吃骨架尺度。
const LOCO_SLIDE_FAIL := 0.35     # 滑步比值超過這個就算不及格
const LOCO_SNAP_FAIL := 22.0      # 單幀轉向超過幾度算「瞬間轉向」

var _lc_fail := 0
var _lc_lines: Array = []

func _lc_say(ok: bool, msg: String) -> void:
	if not ok:
		_lc_fail += 1
	_lc_lines.append(("     " if ok else " FAIL") + " " + msg)
	print("[locochk]%s %s" % ["  OK" if ok else " FAIL", msg])


# 量一段時間內的滑步／轉向／步態切換。回傳統計字典。
# hold_keys：這段期間按住哪些鍵（空陣列＝不按，量停步）。
func _lc_sample(u, secs: float, hold_keys: Array) -> Dictionary:
	for k in hold_keys:
		_press_key(k, true)
	var body_move := 0.0
	var slide := 0.0
	var planted_frames := 0
	var max_snap := 0.0            # 單幀最大轉向（度）
	var max_pen := 0.0             # 腳最深陷進地面幾公尺
	var min_h := 1e9               # 這段期間腳踝離地的最低值（診斷用）
	var step_mv := [0.0, 0.0]      # 這一幀左右腳各自的水平位移
	var foot_v := [[], []]         # 左右腳每幀的世界速度（m/s）
	var gait_switch := 0
	var speeds: Array = []
	var prev_pos: Vector3 = u.global_position
	var prev_yaw: float = u.rotation.y
	var prev_ank: Array = u.ankle_points()
	var prev_gait: String = u.loco_gait()
	var t := 0.0
	while t < secs:
		await get_tree().process_frame
		var dt: float = get_process_delta_time()
		t += dt
		var pos: Vector3 = u.global_position
		body_move += Vector2(pos.x - prev_pos.x, pos.z - prev_pos.z).length()
		prev_pos = pos
		var dyaw: float = absf(rad_to_deg(wrapf(u.rotation.y - prev_yaw, -PI, PI)))
		max_snap = maxf(max_snap, dyaw)
		prev_yaw = u.rotation.y
		speeds.append(u.loco_speed())
		var g: String = u.loco_gait()
		if g != prev_gait:
			gait_switch += 1
			prev_gait = g
		var ank: Array = u.ankle_points()
		if ank.size() == 2 and prev_ank.size() == 2:
			for i in 2:
				var a: Vector3 = ank[i]
				var gy: float = float(Unit.ground_sampler.call(a))
				var h: float = a.y - gy
				max_pen = maxf(max_pen, -h)
				min_h = minf(min_h, h)
				var pa: Vector3 = prev_ank[i]
				step_mv[i] = Vector2(a.x - pa.x, a.z - pa.z).length()
			# ⚠ 不可以用「每幀取比較不動的那一隻腳」——慢跑有**騰空期**，
			#   那幾幀兩隻腳都跟著身體飛，min() 必然等於身體位移，
			#   於是連完美的跑步動畫都會被判成滑步（實測結構性下限 0.7 左右）。
			#   改成把每隻腳每幀的速度全部記下來，量完取**低百分位**：
			#   接觸期的腳速該接近 0，取第 20 百分位就抓得到那一段，
			#   而且完全不受騰空期比例影響。
			foot_v[0].append(step_mv[0] / maxf(dt, 0.0001))
			foot_v[1].append(step_mv[1] / maxf(dt, 0.0001))
			planted_frames += 1
		prev_ank = ank
	for k in hold_keys:
		_press_key(k, false)
	var avg := 0.0
	for s in speeds:
		avg += float(s)
	avg = avg / maxf(float(speeds.size()), 1.0)
	# 接觸期腳速＝兩隻腳各取第 20 百分位，再取兩者較小者（總有一隻腳真的踩著）。
	var contact_v := -1.0
	for fi in 2:
		var arr: Array = foot_v[fi]
		if arr.size() < 8:
			continue
		arr.sort()
		var pv: float = float(arr[int(arr.size() * 0.20)])
		contact_v = pv if contact_v < 0.0 else minf(contact_v, pv)
	# 滑步比值＝接觸期腳速 / 身體平均速度。0＝腳真的釘住，1＝腳跟著身體一起滑。
	var body_v: float = body_move / maxf(t, 0.0001)
	slide = contact_v if contact_v >= 0.0 else 0.0
	return {
		"contact_v": contact_v, "body_v": body_v, "min_h": min_h, "plant_th": 0.0,
		"body": body_move, "slide": slide, "planted": planted_frames,
		"snap": max_snap, "pen": max_pen, "switch": gait_switch,
		"avg_speed": avg, "secs": t,
		"ratio": (contact_v / maxf(body_v, 0.05)) if contact_v >= 0.0 else -1.0,
	}


func _locochk() -> void:
	_lc_fail = 0
	_lc_lines.clear()
	if not await _boot_to_battle("locochk", 3): _quit_test(1); return
	var pu = _deployed[0]
	pu["ap"] = 999999.0
	pu["ap_max"] = 999999.0
	pu["node"].auto_stance = false
	pu["node"].stance_cmd = "stand"
	_begin_action(pu)
	# 進第三人稱（使用者實際操控的狀態；不進去就只是在測 AI 路徑）
	_send_click(cam.unproject_position(pu["node"].global_position + Vector3(0, 1.0, 0)))
	await get_tree().create_timer(0.6).timeout
	var u = pu["node"]
	if u.ankle_points().is_empty():
		print("[locochk] 這個兵種沒有可量測的腿骨（非 Quaternius 骨架），改測其他項目")
	print("[locochk] 第三人稱=%s 兵種=%s" % ["是" if cam.is_tps() else "否", String(pu["cls"])])

	# ---------- ① 起步：不可以一幀就到全速 ----------
	var t0 := Time.get_ticks_msec()
	_press_key(KEY_W, true)
	var to_full := 0.0
	var first_frame_speed := -1.0
	while to_full < 2.0:
		await get_tree().process_frame
		to_full += get_process_delta_time()
		if first_frame_speed < 0.0:
			first_frame_speed = u.loco_speed()
		if u.loco_speed() > 2.7:
			break
	_lc_say(first_frame_speed < 1.0,
			"起步第一幀速度 %.2f m/s（應遠小於全速 3.0＝有加速度）" % first_frame_speed)
	_lc_say(to_full > 0.15 and to_full < 1.2,
			"加速到 2.7 m/s 花了 %.2fs（合理區間 0.15~1.2s）" % to_full)

	# ---------- ② 等速跑：量滑步（順便連拍，讓「動態」有畫面可以對照）----------
	# 使用者的驗收標準是「實際看過」，而靜態單張證明不了披風有沒有在飄、
	# 腳有沒有在踏——本專案已經在這件事上吃過虧（見 lessons L-001~L-003）。
	for shot_i in 4:
		await _lc_sample(u, 0.30, [KEY_W])
		await _snap("res://locochk_run%d.png" % shot_i)
	# ---- 動畫診斷：先確定「片段有在播、倍率算對、腿真的在動」----
	_press_key(KEY_W, true)
	await get_tree().create_timer(0.4).timeout
	var ad: Dictionary = u.anim_debug()
	var lz_min := 1e9
	var lz_max := -1e9
	var lt := 0.0
	while lt < 1.2:
		await get_tree().process_frame
		lt += get_process_delta_time()
		var la: Array = u.ankle_local()
		if la.size() == 2:
			lz_min = minf(lz_min, (la[0] as Vector3).z)
			lz_max = maxf(lz_max, (la[0] as Vector3).z)
	_press_key(KEY_W, false)
	var swing: float = (lz_max - lz_min) if lz_max > -1e8 else -1.0
	print("[locochk] 動畫 步態=%s 片段=%s(播放中=%s 目前=%s) 長度=%.2fs 倍率=%.2f 步幅=%.2fm 原生速=%.2fm/s"
			% [ad["gait"], ad["clip"], str(ad["playing"]), ad["cur"], ad["len"],
			ad["scale"], ad["stride"], ad["native"]])
	print("[locochk] 左腳踝在**身體座標系**的前後擺幅 = %.3fm（＝腿實際擺動的行程）" % swing)
	# 一個跑步循環裡，腳相對身體前後應該掃過將近一個步幅。掃不到＝腿根本沒在擺，
	# 那麼不管倍率調多少，畫面上都只會是「一個定住的姿勢被平移」＝滑步。
	_lc_say(swing > 0.35,
			"腿的擺動行程 %.3fm（應接近一個步幅 %.2fm；<0.35m＝腿沒在動，倍率再準也沒用）"
			% [swing, float(ad["stride"])])
	await get_tree().create_timer(0.5).timeout
	var run_s: Dictionary = await _lc_sample(u, 2.5, [KEY_W])
	print("[locochk] 跑步 位移%.2fm 身體速%.2f 接觸期腳速%.2fm/s 比值%.3f 步態切換%d 最大單幀轉向%.1f° 取樣%d幀"
			% [run_s["body"], run_s["body_v"], run_s["contact_v"], run_s["ratio"],
			run_s["switch"], run_s["snap"], int(run_s["planted"])])
	# ★斷言不可以「量不到就跳過」——那正是上一版印出漂亮 0.000 卻什麼都沒測的原因。
	#   量不到踩地幀本身就是 FAIL：代表這支量測對這個兵種是壞的。
	# ★量不到就是 FAIL，不可以靜默跳過——那正是第一版印出漂亮 0.000
	#   卻其實一幀都沒量到的原因（假通過比沒測更糟）。
	_lc_say(int(run_s["planted"]) > 0,
			"跑步期間量到 %d 幀腳部資料（=0 代表量測對這副骨架失效，不是「沒有滑步」）"
			% int(run_s["planted"]))
	if int(run_s["planted"]) > 0:
		_lc_say(float(run_s["ratio"]) < LOCO_SLIDE_FAIL,
				"跑步滑步比值 %.3f（<%.2f；0＝總有一隻腳釘在地上，1＝兩腳跟著身體滑）"
				% [run_s["ratio"], LOCO_SLIDE_FAIL])
		_lc_say(float(run_s["pen"]) < 0.08,
				"跑步時腳最深陷地 %.3fm（<0.08m）" % run_s["pen"])
	_lc_say(int(run_s["switch"]) <= 2,
			"等速跑 2.5s 內步態只切換 %d 次（≤2＝沒有動畫抽搐）" % int(run_s["switch"]))

	# ---------- ③ 停步：不可以瞬停 ----------
	var stop_from: Vector3 = u.global_position
	var v0: float = u.loco_speed()
	var stop_t := 0.0
	while stop_t < 2.5 and u.loco_speed() > 0.05:
		await get_tree().process_frame
		stop_t += get_process_delta_time()
	var stop_d: float = Vector2(u.global_position.x - stop_from.x,
			u.global_position.z - stop_from.z).length()
	_lc_say(stop_t > 0.12 and stop_d > 0.10,
			"從 %.2f m/s 停下來花 %.2fs、滑行 %.2fm（不是一幀關電源）" % [v0, stop_t, stop_d])
	_lc_say(stop_d < 2.0, "停步滑行 %.2fm（<2m，不是溜冰）" % stop_d)

	# ---------- ④ 原地大角度轉向：不可以瞬間甩頭 ----------
	await get_tree().create_timer(0.4).timeout
	var yaw_before: float = u.rotation.y
	var turn_s: Dictionary = await _lc_sample(u, 1.6, [KEY_S])   # 往後＝180° 反向
	var turned: float = absf(rad_to_deg(wrapf(u.rotation.y - yaw_before, -PI, PI)))
	print("[locochk] 反向 轉了%.0f° 最大單幀%.1f° 位移%.2fm" % [turned, turn_s["snap"], turn_s["body"]])
	_lc_say(float(turn_s["snap"]) < LOCO_SNAP_FAIL,
			"180° 反向時單幀最大轉 %.1f°（<%.0f°＝沒有瞬間轉向）" % [turn_s["snap"], LOCO_SNAP_FAIL])

	# ---------- ⑤ 蹲行：舊碼滑最兇的情況（速度只剩 45%、動畫照原速播）----------
	await get_tree().create_timer(0.3).timeout
	u.stance_cmd = "crouch"
	await get_tree().create_timer(0.8).timeout
	var cr_s: Dictionary = await _lc_sample(u, 2.2, [KEY_W])
	print("[locochk] 蹲行 位移%.2fm 身體速%.2f 接觸期腳速%.2fm/s 比值%.3f"
			% [cr_s["body"], cr_s["body_v"], cr_s["contact_v"], cr_s["ratio"]])
	# ⚠ 走不動就不可以拿滑步比值來評分：分母是身體位移，接近 0 時比值會爆成天文數字
	#   （實測某輪 92.1），那是「測試站位卡住」不是「動作壞掉」。要分辨得出來。
	_lc_say(float(cr_s["body"]) > 0.6,
			"蹲行實際走了 %.2fm（<0.6m 代表被地形卡住，這一項量不準）" % float(cr_s["body"]))
	_lc_say(int(cr_s["planted"]) > 0, "蹲行期間量到 %d 幀腳部資料" % int(cr_s["planted"]))
	if int(cr_s["planted"]) > 0 and float(cr_s["body"]) > 0.6:
		_lc_say(float(cr_s["ratio"]) < LOCO_SLIDE_FAIL,
				"蹲行滑步比值 %.3f（<%.2f）" % [cr_s["ratio"], LOCO_SLIDE_FAIL])
	_lc_say(float(cr_s["avg_speed"]) < 2.0 and float(cr_s["avg_speed"]) > 0.4,
			"蹲行平均速度 %.2f m/s（應明顯慢於站姿 3.0）" % cr_s["avg_speed"])
	u.stance_cmd = "stand"
	await get_tree().create_timer(0.6).timeout

	# ---------- ⑥ 腳步 IK：站在斜坡上兩腳都要踩到地面 ----------
	var ik_line: String = u.loco_debug()
	print("[locochk] 狀態列：", ik_line)
	var ank: Array = u.ankle_points()
	if ank.size() == 2:
		var worst := 0.0
		for a in ank:
			var gy: float = float(Unit.ground_sampler.call(a))
			worst = maxf(worst, absf((a.y - gy) - 0.085))
		_lc_say(worst < 0.12, "靜止時兩腳踝離地誤差最大 %.3fm（<0.12m＝有踩到地）" % worst)

	await _snap("res://locochk_end.png")
	print("[locochk] ---- 總結 ----")
	for l in _lc_lines:
		print("[locochk]", l)
	print("[locochk] FAILS=%d  耗時=%.1fs" % [_lc_fail, (Time.get_ticks_msec() - t0) / 1000.0])
	print("[locochk] DONE")
	_quit_test(0)


# ---------- 原地飄移量測（-- idledrift chNN）----------
# 使用者 2026-08-02：「人物停在原地會小飄移」。
# 做法：真實流程開場、部署 3 個單位，**完全不下任何命令**，靜置 8 秒，
# 逐幀量每個活著單位的 XZ 位移，並對照 _drift 的記帳看是誰推的。
# 合格線（肉眼不可見）：淨位移 < 0.02m、單幀最大 < 0.005m。
func _idledrift() -> void:
	_drift_dbg = true
	_drift.clear()
	if not await _boot_to_battle("idledrift", 3): _quit_test(1); return
	# ⚠ 第一版只量「部署完不下令」的狀態，六個單位全 0.0000m ——量不到使用者看到的東西。
	#   使用者是**在第三人稱操控自己的角色時**看到飄移的，所以必須先進到那個狀態。
	var pu = _deployed[0]
	_send_click(cam.unproject_position(pu["node"].global_position + Vector3(0, 1.0, 0)))
	await get_tree().create_timer(0.5).timeout
	print("[drift] 第三人稱=%s（操控 %s）"
			% ["是" if cam.is_tps() else "否", String(pu["cls"])])
	# ⚠ 也要量**模型節點**，不是只量單位座標：人物網格掛在單位底下，
	#   模型自己的 position 若每幀抖動，畫面上就是人在飄，而單位座標完全不動
	#   （第一版就是這樣量到全 0 的）。
	# ⚠⚠ 第二版還是量到全 0（單位座標與模型節點都不動）——因為**骨骼在動時
	#   節點座標完全不變**。真正要量的是「畫面上看到的網格」：把單位底下所有
	#   MeshInstance3D 的世界 AABB 合併，取中心。這才是使用者眼睛看到的位置。
	#   （同一條教訓的第三次出現：骨骼數值正確 ≠ 畫面對，量錯對象等於沒量。）
	var vstart := {}
	var vlast := {}
	var vworst := {}
	# 先走 1.2 秒再放開——使用者是走一段停下來才看到飄的，直接靜置可能碰不到
	# ⚠ 合成輸入要像真的在玩：實際玩法是**一邊走一邊用滑鼠轉鏡頭**、而且常常斜走。
	#   只按 W 不動滑鼠，放開鍵時身體與鏡頭朝向剛好一致，那段「身體轉向鏡頭」的
	#   收斂根本不會被觸發——第一版就是這樣量到 0 的。
	_press_key(KEY_W, true)
	_press_key(KEY_D, true)
	var mt := 0.0
	while mt < 1.2:
		var mm := InputEventMouseMotion.new()
		mm.relative = Vector2(6.0, 0.0)      # 邊走邊轉鏡頭
		mm.screen_relative = mm.relative
		Input.parse_input_event(mm)
		await get_tree().process_frame
		mt += get_process_delta_time()
	_press_key(KEY_W, false)
	_press_key(KEY_D, false)
	await get_tree().create_timer(0.3).timeout
	print("[drift] 已斜走一段（含轉鏡頭）並放開按鍵，開始靜置量測")
	var start := {}
	var last := {}
	var worst := {}
	var mstart := {}
	var mlast := {}
	var mworst := {}
	var frames := 0
	var t := 0.0
	# 逐個網格點名（只對操控中那一個）：4.96m 的位移不像身體，要知道是哪個子節點在動
	var per := {}       # 節點路徑 -> [起點, 終點, 單幀最大]
	# 鏡頭與朝向也要量：鏡頭若在飄，畫面上看起來就是「人相對背景在移動」；
	# 朝向若持續轉，看起來也像在飄（兩者都不是位置問題，但使用者看到的是同一件事）。
	var cam0: Vector3 = cam.global_position
	var camlast: Vector3 = cam0
	var camworst := 0.0
	var yaw0: float = (pu["node"] as Node3D).rotation.y
	while t < 8.0:
		await get_tree().process_frame
		t += get_process_delta_time()
		frames += 1
		camworst = maxf(camworst, cam.global_position.distance_to(camlast))
		camlast = cam.global_position
		for mi in (pu["node"] as Node).find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			if not m.is_visible_in_tree():
				continue
			var b: AABB = m.global_transform * m.get_aabb()
			var c3: Vector3 = b.get_center()
			var c2 := Vector2(c3.x, c3.z)
			var nm: String = String(m.name)
			if not per.has(nm):
				per[nm] = [c2, c2, 0.0]
			else:
				var e: Array = per[nm]
				e[2] = maxf(e[2], c2.distance_to(e[1]))
				e[1] = c2
		for u in units:
			if not u["alive"] or not is_instance_valid(u["node"]):
				continue
			var id: int = u["node"].get_instance_id()
			var p: Vector3 = u["node"].global_position
			var flat := Vector2(p.x, p.z)
			# 模型（網格）的世界座標：抓單位底下第一個 Node3D 子節點的 global_position
			var vp := _visual_center(u["node"])
			var mp := flat
			var mdl = u["node"].get("_model")
			if mdl != null and is_instance_valid(mdl):
				var g: Vector3 = (mdl as Node3D).global_position
				mp = Vector2(g.x, g.z)
			if not start.has(id):
				start[id] = flat
				last[id] = flat
				worst[id] = 0.0
				mstart[id] = mp
				mlast[id] = mp
				mworst[id] = 0.0
				vstart[id] = vp
				vlast[id] = vp
				vworst[id] = 0.0
				continue
			worst[id] = maxf(worst[id], flat.distance_to(last[id]))
			last[id] = flat
			mworst[id] = maxf(mworst[id], mp.distance_to(mlast[id]))
			mlast[id] = mp
			vworst[id] = maxf(vworst[id], vp.distance_to(vlast[id]))
			vlast[id] = vp
	var fails := 0
	print("[drift] 靜置 %.1f 秒 / %d 幀" % [t, frames])
	var movers: Array = []
	for nm in per.keys():
		var e: Array = per[nm]
		movers.append([(e[1] as Vector2).distance_to(e[0]), e[2], nm])
	movers.sort_custom(func(a, b): return a[0] > b[0])
	for i in mini(6, movers.size()):
		print("[drift]   逐網格 %-28s 淨%.4fm 幀最大%.4fm" % [movers[i][2], movers[i][0], movers[i][1]])
	var yaw1: float = (pu["node"] as Node3D).rotation.y
	print("[drift] 鏡頭 淨%.4fm 幀最大%.4fm ／ 操控角色朝向變化 %.2f 度"
			% [cam.global_position.distance_to(cam0), camworst,
			rad_to_deg(absf(wrapf(yaw1 - yaw0, -PI, PI)))])
	if cam.global_position.distance_to(cam0) > 0.02:
		print("[drift] FAIL 鏡頭靜置時淨位移 %.4fm（門檻 0.02m）"
				% cam.global_position.distance_to(cam0))
		fails += 1
	for id in start.keys():
		var net: float = (last[id] as Vector2).distance_to(start[id] as Vector2)
		var wf: float = worst[id]
		var acc: Dictionary = _drift.get(id, {})
		# ⚠ 標籤不可以只從 _drift 拿：沒被推過的單位在 _drift 裡根本沒有條目，
		#   會全部印成 "?"，等於量到異常也不知道是誰（第一版就是這樣）。
		var tag: String = String(acc.get("cls", ""))
		var side_s := ""
		for uu in units:
			if is_instance_valid(uu.get("node")) and uu["node"].get_instance_id() == id:
				tag = String(uu["cls"])
				side_s = "我方" if uu["side"] == player_side else "敵方"
				if acting != null and acting.get("node") == uu["node"]:
					side_s += "★操控中"
				break
		tag = "%s%s" % [side_s, tag]
		var mnet: float = (mlast[id] as Vector2).distance_to(mstart[id] as Vector2)
		print("[drift] %-10s 單位 淨%.4fm 幀%.4fm ／ 模型 淨%.4fm 幀%.4fm"
				% [tag, net, wf, mnet, mworst[id]]
				+ " ／ settle %.3f pair %.3f clamp %.3f 逃生 %d 次"
				% [acc.get("settle", 0.0), acc.get("pair", 0.0),
				acc.get("clamp", 0.0), acc.get("esc", 0)])
		var vnet: float = (vlast[id] as Vector2).distance_to(vstart[id] as Vector2)
		print("[drift]   └ 網格（畫面看到的）淨 %.4fm 幀最大 %.4fm　起(%.2f,%.2f)→終(%.2f,%.2f)"
				% [vnet, vworst[id], (vstart[id] as Vector2).x, (vstart[id] as Vector2).y,
				(vlast[id] as Vector2).x, (vlast[id] as Vector2).y])
		if vnet > 0.02 or vworst[id] > 0.005:
			print("[drift] FAIL %s 網格在飄：淨 %.4fm、單幀 %.4fm（節點不動＝骨骼層在動）"
					% [tag, vnet, vworst[id]])
			fails += 1
		if mnet > 0.02 or mworst[id] > 0.005:
			print("[drift] FAIL %s 模型節點在飄：淨 %.4fm、單幀 %.4fm" % [tag, mnet, mworst[id]])
			fails += 1
		if net > 0.02:
			print("[drift] FAIL %s 靜置 %.1f 秒淨位移 %.3fm（門檻 0.02m）" % [tag, t, net])
			fails += 1
		if wf > 0.005:
			print("[drift] FAIL %s 單幀位移 %.4fm（門檻 0.005m）" % [tag, wf])
			fails += 1
	print("[drift] FAILS=%d" % fails)
	_quit_test(0 if fails == 0 else 1)

# ---------- 章節壓力測試（-- stress chNN，2026-07-28 使用者第 5 項）----------
# 真的打一場仗：走真實 UI 部署 3 個單位，每回合每兵向最近敵人推進（按 W 用走的，
# 沿用走查台的六條不變量）、射程內開火、按「結束回合」讓敵方 AI 跑完。
# 量三類問題：①走查不變量 FAIL ②回合末全員位置掃描 ③軟鎖（敵方回合跑不完）＋最差幀時。
# CP/AP 都吃真實規則（_begin_action 拿不到 CP 就輪空）——壓測要壓的是遊戲，不是作弊碼。
func _stress() -> void:
	if not await _boot_to_battle("stress", 3): _quit_test(1); return
	var chn := _test_chapter()
	# ③ 接線反驗證：印實戰座標下 _wrap 填出的地形事實。公式在 TerrainProbe 驗過，
	# 這行是防「資料寫好了但沒人讀」——wrap 沒填的話這裡永遠是 0/0/0/false。
	var w0 = _wrap(_deployed[0])
	print("[terrchk] 實戰 wrap：wade=%.2fm slope=%.2f elev=%.2fm crater=%s"
			% [w0.wade, w0.slope, w0.elev, str(w0.in_crater)])
	var bad := {"solid": [], "air": [], "deep": [], "stuck": [], "cam": [], "oob": []}
	_walk_bad = bad
	_walk_checked = 0
	var fails := 0
	var worst_ms := 0.0
	var turns := 0
	var shots := 0
	for turn_i in range(12):
		if st != St.CMD:
			var tw := 0.0
			while st != St.CMD and st != St.END and tw < 30.0:
				await get_tree().create_timer(0.5).timeout
				tw += 0.5
		if st == St.END: break
		if st != St.CMD:
			print("[stress] FAIL 回合 %d 等不到指揮階段 st=%d" % [turn_i, st])
			fails += 1
			break
		turns += 1
		for u in _deployed:
			if st != St.CMD: break
			if not u["alive"] or not is_instance_valid(u["node"]): continue
			var tgt = _stress_nearest_enemy(u)
			if tgt == null: break
			if not _begin_action(u): continue          # CP 不夠：真實規則，輪空
			await get_tree().create_timer(0.2).timeout
			var gpx := Vector2(float(tgt["wx"]), float(tgt["wy"]))
			var mypx: Vector2 = _live_px(u)
			# 步幅 160px＝8m/回合：90px 時 12 回合碰不到敵人，戰鬥系統整段沒被壓到
			var leg: Vector2 = mypx + (gpx - mypx).limit_length(160.0)
			await _walk_leg(u, leg)
			var dist_px: float = _live_px(u).distance_to(Vector2(float(tgt["wx"]), float(tgt["wy"])))
			if tgt["alive"] and u["alive"] and dist_px <= float(u["weapon"].get("range", 200)) \
					and _any_part_clear(u, tgt):
				await _fire(u, tgt)
				shots += 1
			_end_action()
			await get_tree().create_timer(0.15).timeout
		if st == St.END: break
		if not await _click_btn("結束回合"):
			_end_player_turn()
		# 等敵方 AI 跑完；順便量最差幀時（敵方回合是 AI 決策最重的一段）
		var te := 0.0
		var prev_t: int = Time.get_ticks_msec()
		while st == St.ENEMY and te < 90.0:
			await get_tree().process_frame
			var nowt: int = Time.get_ticks_msec()
			worst_ms = maxf(worst_ms, float(nowt - prev_t))
			prev_t = nowt
			te += get_process_delta_time()
		if st == St.ENEMY:
			print("[stress] FAIL 敵方回合 90 秒沒結束＝軟鎖")
			fails += 1
			break
		fails += await _stress_sweep()
		# 每回合戰況：沒有這行的話「12 回合零交火」跟「打得火熱」在 log 裡長一樣
		var php := 0
		var ehp := 0
		var min_d := 1e18
		for uu in units:
			if not uu["alive"]: continue
			if uu["side"] == player_side: php += int(uu["hp"])
			else: ehp += int(uu["hp"])
		for uu in units:
			if not uu["alive"] or uu["side"] != player_side: continue
			for ee in units:
				if not ee["alive"] or ee["side"] == player_side: continue
				min_d = minf(min_d, Vector2(float(uu["wx"]) - float(ee["wx"]),
						float(uu["wy"]) - float(ee["wy"])).length())
		print("[stress] 回合%d 我方開火累計%d 我方HP%d 敵方HP%d 最近敵距%.1fm"
				% [turns, shots, php, ehp, min_d * WORLD_SCALE])
	# stuck 不算 FAIL：推進路上被牆/河擋住是正常戰場（要求全圖走得通的是 -- walk）
	var wtot := 0
	for k in ["solid", "air", "deep", "cam", "oob"]:
		var arr: Array = bad[k]
		if not arr.is_empty():
			print("[stress][%s] %d 次，第 1 筆：%s" % [k, arr.size(), str(arr[0])])
		wtot += arr.size()
	var alive_p := _count_side(player_side)
	var alive_e := _count_side(1 - player_side)
	print("[stress] ch%02d 回合=%d 我方存活=%d 敵方存活=%d 取樣=%d 最差幀=%.0fms 結局=%s"
			% [chn, turns, alive_p, alive_e, _walk_checked, worst_ms,
			("打完" if st == St.END else "回合上限")])
	await _snap("res://stress_ch%02d_end.png" % chn)
	print("[stress] ch%02d FAILS=%d" % [chn, fails + wtot])
	print("[stress] DONE")
	_quit_test(0)

# ---------- 沉陷掃描（-- sinkscan chNN）：直接量「人腳 vs 畫面上的地表」 ----------
# 使用者 2026-07-31：「埋入地下一樣在第 15 章的建築物底下，其他章節一定也有」。
# 走查台的 air 檢查跟支撐用同一個 height_at，所以那個病它天生看不見（自己驗自己）。
# 這裡改成：物理支撐(height_at) vs 網格內插(height_at_mesh)——後者才是玩家看到的地表。
# 差 >0.15m 就是「人會陷進去/浮起來」的點，並且逐建築統計，證明修在哪。
func _sinkscan() -> void:
	_test_mode = true
	await get_tree().create_timer(0.5).timeout
	ui.root.visible = false
	var chn := _test_chapter()
	map_data = GameData.maps[String(GameData.story[chn - 1].get("map", "tutorial"))]
	_teardown_world()
	await get_tree().process_frame
	_build_ground()
	var mwp: float = map_data.get("w", 960)
	var mhp: float = map_data.get("h", 600)
	# 「畫面上的地表」＝**真的送進 GPU 的那份三角形**。從 TerrainMesh 的頂點陣列
	# 重建三角形做空間雜湊，再逐點求交。拿 height_at_mesh 去比 height_at_mesh
	# 等於沒驗（自我循環）；讀實際幾何才是獨立驗證。
	var tri_grid := {}
	var tmi := terrain.find_child("TerrainMesh", true, false) as MeshInstance3D
	if tmi == null or tmi.mesh == null:
		print("[sink] FAIL 找不到 TerrainMesh")
		_quit_test(1)
		return
	var arrs: Array = (tmi.mesh as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrs[Mesh.ARRAY_VERTEX]
	var GCELL := 4.0            # 雜湊格（公尺）
	var ti := 0
	while ti + 2 < verts.size():
		var a: Vector3 = verts[ti]
		var b: Vector3 = verts[ti + 1]
		var c: Vector3 = verts[ti + 2]
		var x0: int = int(floor(minf(minf(a.x, b.x), c.x) / GCELL))
		var x1: int = int(floor(maxf(maxf(a.x, b.x), c.x) / GCELL))
		var z0: int = int(floor(minf(minf(a.z, b.z), c.z) / GCELL))
		var z1: int = int(floor(maxf(maxf(a.z, b.z), c.z) / GCELL))
		for gxi in range(x0, x1 + 1):
			for gzi in range(z0, z1 + 1):
				var key := Vector2i(gxi, gzi)
				if not tri_grid.has(key):
					tri_grid[key] = []
				tri_grid[key].append(ti)
		ti += 3
	print("[sink] 三角形雜湊：%d 個三角形、%d 格" % [verts.size() / 3, tri_grid.size()])
	var worst := 0.0
	var worst_at := Vector2.ZERO
	var bad := 0
	var n := 0
	var near_bld := 0
	var old_bad := 0            # 舊算法（height_at）會沉的點數，用來對照修了多少
	var old_worst := 0.0
	var step := 6.0             # px＝0.3m，比 CELL(0.8m) 細才抓得到格內落差
	var py := 20.0
	while py < mhp - 20.0:
		var px := 20.0
		while px < mwp - 20.0:
			var foot: float = terrain.height_at_mesh(px, py)     # 人腳實際落點
			var w3: Vector3 = _to3d(px, py)
			var surf: float = _tri_surface(tri_grid, verts, w3.x, w3.z, GCELL)
			if surf == -1e18:                                   # 該點沒有地表三角形
				px += step
				continue
			n += 1
			var d: float = foot - surf                          # 負＝人在地表下（埋進去）
			var d_old: float = terrain.height_at(px, py) - surf
			if absf(d_old) > 0.15:
				old_bad += 1
				if absf(d_old) > absf(old_worst):
					old_worst = d_old
			if absf(d) > 0.15:
				bad += 1
				for bd in _buildings:
					if bd.rect.grow(6.0 / WORLD_SCALE).has_point(Vector2(px, py)):
						near_bld += 1
						break
				if absf(d) > absf(worst):
					worst = d
					worst_at = Vector2(px, py)
			px += step
		py += step
	print("[sink] ch%02d 取樣=%d｜新算法沉陷>0.15m=%d（建築6m內=%d）最大=%+.2fm @px(%.0f,%.0f)"
			% [chn, n, bad, near_bld, worst, worst_at.x, worst_at.y])
	print("[sink] ch%02d 對照：舊算法(height_at)沉陷=%d 最大=%+.2fm"
			% [chn, old_bad, old_worst])
	print("[sink] ch%02d FAILS=%d" % [chn, bad])
	print("[sink] DONE")
	_quit_test(0)


# 剔除「長在地圖邊界夾限帶裡」的障礙（2026-07-31，walk ch01/06/13 同一根因）。
# _clamp_to_map 把人夾在離邊界 1m 的線上；若障礙長在那條線的外側或線上，
# 每幀就是「障礙把人推出去 → clamp 把人拉回來」的死夾，走查報「陷進實體」或
# 「卡死」。上一輪只排除了樹，但沙包/柵欄/電線桿/岩石/瓦礫全都會長到邊界。
# 這裡在**組裝後統一過濾**——不管障礙來自哪個產生器，規則只有一份（單一真相）。
# 安全帶＝clamp 邊界 1m ＋ 身體半徑 0.42m ＋ 餘裕 0.2m ≒ 1.62m。
const EDGE_SAFE_M := 1.62
func _strip_edge_blockers(list: Array, mw_px: float, mh_px: float) -> Array:
	var pad: float = EDGE_SAFE_M / WORLD_SCALE
	var out: Array = []
	var cut := 0
	var kinds: Dictionary = {}     # 被剔掉的種類統計（要指名，不能只給總數）
	var spots: Array = []          # 前幾個的座標（定位「誰生的」用）
	for bk in list:
		# 深水圍欄本來就該貼著水域邊緣立，不受此限（它擋的是「別走進海裡」）
		if String(bk.get("k", "")) == "deepwater":
			out.append(bk)
			continue
		var near_edge := false
		var pts: Array = []
		match String(bk.get("t", "")):
			"cir":
				pts.append(bk["c"])
			"seg":
				pts.append(bk["a"])
				pts.append(bk["b"])
			"obb":
				pts.append(bk["c"])
			_:
				out.append(bk)
				continue
		var r_px: float = float(bk.get("r", 0.0))
		if bk.get("t", "") == "obb":
			var e: Vector2 = bk.get("e", Vector2.ZERO)
			r_px = maxf(e.x, e.y)
		for pt in pts:
			var p: Vector2 = pt
			if p.x - r_px < pad or p.y - r_px < pad 					or p.x + r_px > mw_px - pad or p.y + r_px > mh_px - pad:
				near_edge = true
				break
		if near_edge:
			cut += 1
			var kk: String = String(bk.get("k", ""))
			if kk == "":
				kk = "t=" + String(bk.get("t", "?"))
			kinds[kk] = int(kinds.get(kk, 0)) + 1
			# 帶上座標與半徑：只有種類統計時無法判斷是「誰生的、為什麼守衛沒攔到」，
			# 上一輪就因此在 Props 與 Main 的判準之間繞了一圈（2026-08-02）。
			if spots.size() < 6:
				spots.append("%s@(%.0f,%.0f)r%.0f 圖%.0fx%.0f"
						% [kk, float(pts[0].x), float(pts[0].y), r_px, mw_px, mh_px])
		else:
			out.append(bk)
	# ⚠ 一律印（含 0）：只在 >0 時印＝靜默跳過，看不出這道防線到底有沒有跑。
	#   本專案踩過三次，最貴的一次是撞窗戶那項在前置條件不成立時安靜 return 而假通過。
	print("[edge] 剔除邊界帶障礙 %d 個（安全帶 %.2fm，深水圍欄不剔）" % [cut, EDGE_SAFE_M])
	# ★★2026-08-02：這個數字現在是「視覺與碰撞不一致」的量化指標。
	#   被剔掉的障礙**視覺網格還在畫面上**＝看得到卻穿得過（使用者實測「穿過柵欄」）。
	#   Props 已改成在生成階段就避開邊界帶，所以這裡應該剔 0 個；
	#   剔到就代表有來源沒避開（例如 maps.json 把沙包/工事放進邊界帶），
	#   要指名種類，不可只印一個總數讓人看不出是什麼。
	if cut > 0:
		push_error("[edge] 有 %d 個障礙被剔掉碰撞但視覺仍在（看得到穿得過）：%s　前幾筆：%s"
				% [cut, str(kinds), str(spots)])
	return out

# 在實際網格三角形上求 (x,z) 的地表高度（重心座標）。找不到回 -1e18。
func _tri_surface(grid: Dictionary, verts: PackedVector3Array,
		x: float, z: float, gcell: float) -> float:
	var lst: Array = grid.get(Vector2i(int(floor(x / gcell)), int(floor(z / gcell))), [])
	for i in lst:
		var a: Vector3 = verts[i]
		var b: Vector3 = verts[i + 1]
		var c: Vector3 = verts[i + 2]
		var d: float = (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
		if absf(d) < 0.000001:
			continue
		var l1: float = ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / d
		var l2: float = ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / d
		var l3: float = 1.0 - l1 - l2
		if l1 < -0.0001 or l2 < -0.0001 or l3 < -0.0001:
			continue
		return a.y * l1 + b.y * l2 + c.y * l3
	return -1e18


# ---------- 斜坡姿態驗收（-- slopetest；2026-07-31 使用者：斜坡上整個人斜著跑）----------
# 真人在坡上：軀幹垂直、坡度由兩腿不等長吸收。量兩個數字：
#   ① 軀幹傾角（模型節點 roll/pitch）——應該遠小於坡度角
#   ② 兩腿膝角差——坡越陡差越大（腿真的在吃坡度）
func _slopetest() -> void:
	_test_mode = true
	await get_tree().create_timer(0.6).timeout
	ui.root.visible = false
	map_data = GameData.maps.get("plain", GameData.maps[GameData.maps.keys()[0]])
	_teardown_world()
	await get_tree().process_frame
	_build_ground()
	if is_instance_valid(_zone_mesh):
		_zone_mesh.visible = false
	nation[0] = "usa"
	nation[1] = "russia"
	player_side = 0
	units = []
	var mwp: float = map_data.get("w", 960)
	var mhp: float = map_data.get("h", 600)
	# 找全圖最陡的一塊地（側向坡度最大）
	var best := Vector2(mwp * 0.5, mhp * 0.5)
	var best_s := 0.0
	var gy := 60.0
	while gy < mhp - 60.0:
		var gx := 60.0
		while gx < mwp - 60.0:
			# ⚠ 要挑「跑得過去的斜坡」不是最陡點：全圖最陡的地方是壕溝護壁
			# （65 度垂直牆），量它等於在驗攀岩。可行走坡＝12~32 度，
			# 而且不能在壕溝裡（溝壁不是坡）。
			var sl: float = terrain.slope_at(gx, gy)
			if sl > best_s and sl < 0.62 and terrain.water_depth(gx, gy) <= 0.01 					and not terrain.in_trench(gx, gy):
				best_s = sl
				best = Vector2(gx, gy)
			gx += 40.0
		gy += 40.0
	var slope_deg: float = rad_to_deg(atan(best_s))
	print("[slope] 最陡點 px(%.0f,%.0f) 坡度=%.1f 度" % [best.x, best.y, slope_deg])
	var u = _spawn_unit("rifleman", 0, best.x, best.y, true)
	u["node"].auto_stance = false
	await get_tree().create_timer(1.5).timeout
	var mdl: Node3D = u["node"]._model
	var roll_deg: float = rad_to_deg(absf(mdl.rotation.z))
	var pitch_deg: float = rad_to_deg(absf(mdl.rotation.x))
	var tilt: float = maxf(roll_deg, pitch_deg)
	# 兩腿：量左右腳踝的世界高度差（腿真的在吃坡度的話會有差）
	var sks := (mdl as Node3D).find_children("*", "Skeleton3D", true, false)
	var leg_dh := 0.0
	if not sks.is_empty():
		var sk := sks[0] as Skeleton3D
		var li := sk.find_bone("Foot.L")
		var ri := sk.find_bone("Foot.R")
		if li >= 0 and ri >= 0:
			var lp: Vector3 = sk.global_transform * sk.get_bone_global_pose(li).origin
			var rp: Vector3 = sk.global_transform * sk.get_bone_global_pose(ri).origin
			leg_dh = absf(lp.y - rp.y)
	var fails := 0
	# 軀幹傾角應遠小於坡度：門檻＝坡度的 45%（趴姿才該完全貼合）
	var ok_tilt: bool = tilt < slope_deg * 0.45 + 2.0
	print("[slope] 軀幹傾角=%.1f 度（坡度 %.1f 度的 %.0f%%） %s"
			% [tilt, slope_deg, 100.0 * tilt / maxf(slope_deg, 0.01),
			"OK" if ok_tilt else "FAIL(整個人跟著坡面斜)"])
	if not ok_tilt:
		fails += 1
	print("[slope] 兩腳高度差=%.3fm %s" % [leg_dh,
			"OK(腿在吃坡度)" if leg_dh > 0.02 else "FAIL(兩腿等長＝坡度沒被腿吸收)"])
	if leg_dh <= 0.02:
		fails += 1
	cam.clear_tps()
	cam.set_follow(null)
	cam.focus = _to3d(best.x, best.y) + Vector3(0, 1.0, 0)
	cam.dist = 4.2
	cam.pitch_deg = 3.0
	cam.yaw = 0.0
	await get_tree().create_timer(0.9).timeout
	await _snap("res://slope_front.png")
	cam.yaw = PI * 0.5
	await get_tree().create_timer(0.7).timeout
	await _snap("res://slope_side.png")
	print("[slope] FAILS=%d" % fails)
	print("[slope] DONE")
	get_tree().quit(1 if fails > 0 else 0)

# ---------- 角色外觀驗收（-- lookshots；GDD/06 外觀 v2）----------
# 我方九人一排、敵軍九兵種一排。兩件事：
#   ① 程式斷言：我方兩兩「簽名」(基底,頭具,背具,主色) 相異；敵我任兩人基底必不同（分池）。
#   ② 實拍正面近景給使用者看——符不符合人設最終是人眼說了算。
func _lookshots() -> void:
	_test_mode = true
	await get_tree().create_timer(0.6).timeout
	ui.root.visible = false
	# 用自由模式平原圖當攝影棚：空曠無建築，不用跟章節地圖的地物搶鏡位
	map_data = GameData.maps.get("plain", GameData.maps[GameData.maps.keys()[0]])
	_teardown_world()
	await get_tree().process_frame
	_build_ground()
	if is_instance_valid(_zone_mesh):
		_zone_mesh.visible = false
	nation[0] = "usa"
	nation[1] = "russia"
	player_side = 0
	units = []
	var classes: Array = ["rifleman", "assault", "mg", "sniper", "at",
			"mortar", "engineer", "specops", "sam"]
	var fails := 0
	var sigs := {}
	# 展示場＝全圖離建築最遠的乾地（放地圖中心會排進營房巷子裡，實拍整張是牆）
	var mwp: float = map_data.get("w", 960)
	var mhp2: float = map_data.get("h", 600)
	var best_s := -1.0
	var base_p := Vector2(mwp * 0.5, mhp2 * 0.5)
	for gy in range(2, int(mhp2 / 100.0) - 1):
		for gx in range(3, int(mwp / 100.0) - 3):
			var cand := Vector2(float(gx) * 100.0, float(gy) * 100.0)
			if terrain != null and terrain.water_depth(cand.x, cand.y) > 0.01:
				continue
			if terrain != null and terrain.water_depth(cand.x + 480.0, cand.y + 90.0) > 0.01:
				continue                    # 兩排 9 人寬 480px，整片都要乾
			var sc := 1e9
			for bd in _buildings:
				sc = minf(sc, bd.rect.get_center().distance_to(cand + Vector2(240, 45)))
			# 展示區周邊也要避開大型障礙（殘骸/巨石會擋鏡頭——第二輪實拍前景一團火）
			for bk in _blockers:
				if float(bk.get("h", 0.0)) < 1.0 or bk.get("t", "") != "cir":
					continue
				var bc: Vector2 = bk["c"]
				if bc.x > cand.x - 60.0 and bc.x < cand.x + 540.0 \
						and bc.y > cand.y - 120.0 and bc.y < cand.y + 210.0:
					sc = minf(sc, 40.0)
			if sc > best_s:
				best_s = sc
				base_p = cand
	for i in classes.size():
		var cls: String = classes[i]
		var fu = _spawn_unit(cls, 0, base_p.x + float(i) * 60.0, base_p.y, true)
		fu["node"].auto_stance = false
		var eu = _spawn_unit(cls, 1, base_p.x + float(i) * 60.0, base_p.y + 90.0, false)
		eu["node"].auto_stance = false
		var lkp: Dictionary = GameData.char_look.get(cls, {})
		var lke: Dictionary = GameData.enemy_look.get(cls, {})
		sigs["我方" + cls] = [String(lkp.get("base", "?")), String(lkp.get("head", "")),
				String(lkp.get("pack", "")), String(lkp.get("coat", ""))]
		sigs["敵軍" + cls] = [String(lke.get("base", "?")), String(lke.get("head", "")),
				String(lke.get("pack", "")), "enemy"]
	# ① 我方兩兩簽名相異
	for a in classes:
		for b in classes:
			if a >= b:
				continue
			if sigs["我方" + a] == sigs["我方" + b]:
				print("[lookchk] FAIL 我方 %s 與 %s 外觀簽名完全相同 %s" % [a, b, str(sigs["我方" + a])])
				fails += 1
	# ② 敵我基底分池：任何我方基底不得出現在敵軍
	for a2 in classes:
		for b2 in classes:
			if sigs["我方" + a2][0] == sigs["敵軍" + b2][0]:
				print("[lookchk] FAIL 敵我共用基底：我方 %s 與敵軍 %s 都用 %s"
						% [a2, b2, sigs["我方" + a2][0]])
				fails += 1
	for k in sigs:
		print("[lookchk] %s → %s" % [k, str(sigs[k])])
	await get_tree().create_timer(2.0).timeout    # 等裝具縮放校正跑完
	cam.clear_tps()
	cam.set_follow(null)
	# 三人一組近景輪拍（遠景合照什麼人設都看不出來——第一輪實拍證實）
	for gi in 3:
		var gx: float = base_p.x + (float(gi) * 3.0 + 1.0) * 60.0
		cam.focus = _to3d(gx, base_p.y) + Vector3(0, 1.15, 0)
		cam.dist = 5.5
		cam.pitch_deg = 4.0
		cam.yaw = PI
		await get_tree().create_timer(0.9).timeout
		await _snap("res://look_friend%d.png" % gi)
		cam.focus = _to3d(gx, base_p.y + 90.0) + Vector3(0, 1.15, 0)
		cam.yaw = 0.0
		await get_tree().create_timer(0.9).timeout
		await _snap("res://look_enemy%d.png" % gi)
	cam.focus = _to3d(base_p.x + 240.0, base_p.y + 45.0) + Vector3(0, 1.2, 0)
	cam.dist = 26.0
	cam.pitch_deg = 16.0
	cam.yaw = 2.4
	await get_tree().create_timer(0.8).timeout
	await _snap("res://look_both.png")
	print("[lookchk] FAILS=%d" % fails)
	print("[lookchk] DONE")
	get_tree().quit(1 if fails > 0 else 0)

# ---------- 美術特寫（-- artshots chNN）----------
# mapshots 的人眼鏡頭是「地圖中心固定點」，常常卡在牆裡或巷子裡，
# 驗水面/樹葉/道具全靠運氣。這裡改成**依內容找景**：岸線、樹叢、貨櫃、碉堡各拍特寫。
func _artshots() -> void:
	await get_tree().create_timer(0.6).timeout
	ui.root.visible = false
	var chn := _test_chapter()
	var ch: Dictionary = GameData.story[chn - 1]
	map_data = GameData.maps[String(ch.get("map", "tutorial"))]
	_teardown_world()
	await get_tree().process_frame
	_build_ground()
	# 部署藍框不是場景的一部分：留著會像一條青色地毯鋪在地上（sceneshots 同一課）
	if is_instance_valid(_zone_mesh):
		_zone_mesh.visible = false
	var mwp: float = map_data.get("w", 960)
	var mhp: float = map_data.get("h", 600)
	cam.clear_tps()
	cam.set_follow(null)
	await get_tree().create_timer(1.5).timeout
	# ⓪ 氣氛鏡頭（無條件）：地圖中心附近的**空曠點**人眼視角。
	#   直接用中心點會掉進建築物裡（ch01 實拍整張是室內牆）；
	#   往外螺旋找第一個「不在屋裡、不在水裡」的點。
	var spot := Vector2(mwp * 0.5, mhp * 0.55)
	for ring in range(0, 8):
		var found_dry := false
		for aa in range(0, 8):
			var cand: Vector2 = Vector2(mwp * 0.5, mhp * 0.55) \
					+ Vector2.from_angle(TAU * float(aa) / 8.0) * float(ring) * 60.0
			var in_bld := false
			for bd in _buildings:
				if bd.rect.grow(30.0).has_point(cand):
					in_bld = true
					break
			if not in_bld and (terrain == null or terrain.water_depth(cand.x, cand.y) <= 0.01):
				spot = cand
				found_dry = true
				break
		if found_dry:
			break
	cam.focus = _to3d(spot.x, spot.y) + Vector3(0, 1.5, 0)
	cam.dist = 10.0
	cam.pitch_deg = 9.0
	cam.yaw = 0.6
	await get_tree().create_timer(2.5).timeout    # 粒子要時間長滿
	await _snap("res://art_ch%02d_scene.png" % chn)
	# ⓪b 道路鏡頭（有路才拍）：沿路看過去——電線桿、電線垂度、路邊柵欄一次入鏡
	var roads: Array = map_data.get("roads", [])
	if not roads.is_empty():
		# 挑「離建築最遠」的路段取樣點：第一條路的中點常在營房縫裡（實拍卡牆）
		var best_pt := Vector2.ZERO
		var best_dir := Vector2.RIGHT
		var best_score := -1.0
		for rd0 in roads:
			var ra0 := Vector2(float(rd0.get("x1", 0)), float(rd0.get("y1", 0)))
			var rb0 := Vector2(float(rd0.get("x2", 0)), float(rd0.get("y2", 0)))
			for tt in [0.25, 0.4, 0.5, 0.6, 0.75]:
				var cand: Vector2 = ra0.lerp(rb0, tt)
				var score := 1e9
				for bd in _buildings:
					score = minf(score, bd.rect.get_center().distance_to(cand)
							- maxf(bd.rect.size.x, bd.rect.size.y) * 0.5)
				if score > best_score:
					best_score = score
					best_pt = cand
					best_dir = (rb0 - ra0).normalized()
		var rm: Vector2 = best_pt
		var rdir: Vector2 = best_dir
		cam.focus = _to3d(rm.x, rm.y) + Vector3(0, 2.2, 0)
		cam.dist = 14.0
		cam.pitch_deg = 10.0
		cam.yaw = atan2(-rdir.x, -rdir.y)
		await get_tree().create_timer(0.8).timeout
		await _snap("res://art_ch%02d_road.png" % chn)
		# 電線桿特寫：對準 Props 實際放置的桿（用公式猜會拍到屋頂——猜過兩輪了）。
		# 挑「有相鄰桿」的一根（桿距 <300px），鏡頭橫著看，電線垂度才入鏡。
		if _pole_spots.size() >= 2:
			var pi_best := 0
			for pi3 in _pole_spots.size() - 1:
				if (_pole_spots[pi3] as Vector2).distance_to(_pole_spots[pi3 + 1]) < 300.0:
					pi_best = pi3
					break
			var pp0: Vector2 = _pole_spots[pi_best]
			var pp1: Vector2 = _pole_spots[mini(pi_best + 1, _pole_spots.size() - 1)]
			var mid_p: Vector2 = pp0.lerp(pp1, 0.5)
			var wire_dir: Vector2 = (pp1 - pp0).normalized()
			var side_n := Vector2(-wire_dir.y, wire_dir.x)
			cam.focus = _to3d(mid_p.x, mid_p.y) + Vector3(0, 4.4, 0)
			cam.dist = 11.0
			cam.pitch_deg = 8.0
			cam.yaw = atan2(side_n.x, side_n.y)
			await get_tree().create_timer(0.8).timeout
			await _snap("res://art_ch%02d_pole.png" % chn)
	# ① 岸線：掃網格找「水深 0.4m」的點，鏡頭從陸側 8m 外、1.7m 高看向水面
	if terrain != null:
		var found := Vector2.ZERO
		var ok := false
		for gy in range(6, int(mhp / 40)):
			for gx in range(6, int(mwp / 40)):
				var px := float(gx) * 40.0
				var py := float(gy) * 40.0
				var wd: float = terrain.water_depth(px, py)
				if wd > 0.25 and wd < 0.6:
					found = Vector2(px, py)
					ok = true
					break
			if ok: break
		if ok:
			# 岸的方向：往四周找乾的那一側
			var dry := Vector2(1, 0)
			for dv in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
				if terrain.water_depth(found.x + dv.x * 120.0, found.y + dv.y * 120.0) <= 0.01:
					dry = dv
					break
			var eye_px: Vector2 = found + dry * 140.0
			cam.focus = _to3d(eye_px.x, eye_px.y) + Vector3(0, 1.2, 0)
			cam.dist = 7.0
			cam.pitch_deg = 12.0
			cam.yaw = atan2(-dry.x, -dry.y)
			await get_tree().create_timer(1.2).timeout
			await _snap("res://art_ch%02d_water.png" % chn)
			# 同一點再拍一張近水面低角度（看漣漪/閃爍/浪花）
			cam.dist = 3.5
			cam.pitch_deg = 6.0
			await get_tree().create_timer(0.8).timeout
			await _snap("res://art_ch%02d_water2.png" % chn)
	# ①b 岩石特寫（使用者 2026-07-31：「這類似的石頭太假了」）：
	# 找最大的一顆石頭（_covers 裡 type=sandbag 且是石頭登記的那批），人眼高度平視
	var rock_at := Vector2(-1, -1)
	var rock_r := 0.0
	for bk in _blockers:
		if bk.get("t", "") != "cir" or float(bk.get("h", 0.0)) < 0.5:
			continue
		if String(bk.get("k", "")) != "":
			continue                        # 有 k 的是深水樁/沙包等，不是石頭
		if float(bk["r"]) > rock_r:
			rock_r = float(bk["r"])
			rock_at = bk["c"]
	if rock_at.x >= 0.0:
		cam.focus = _to3d(rock_at.x, rock_at.y) + Vector3(0, 0.8, 0)
		cam.dist = 6.0
		cam.pitch_deg = 6.0
		cam.yaw = 0.9
		await get_tree().create_timer(0.8).timeout
		await _snap("res://art_ch%02d_rock.png" % chn)
	# ② 樹叢：拿 _tree_feet 裡最靠中央的一棵
	if not _tree_feet.is_empty():
		var ctr := Vector2(mwp * 0.5, mhp * 0.5)
		var best: Vector2 = _tree_feet[0]
		for tf in _tree_feet:
			if (tf as Vector2).distance_to(ctr) < best.distance_to(ctr):
				best = tf
		cam.focus = _to3d(best.x, best.y) + Vector3(0, 3.2, 0)
		cam.dist = 9.0
		cam.pitch_deg = 10.0
		cam.yaw = 0.9
		await get_tree().create_timer(1.0).timeout
		await _snap("res://art_ch%02d_tree.png" % chn)
	# ②b 建築特寫（使用者 2026-07-31 回報城市圖剖面屋/紅光帶）：
	# 對第一棟建築拍四個方位——缺牆的那一面只有特定角度看得到
	var solids: Array = map_data.get("solids", [])
	if not solids.is_empty():
		var s0: Dictionary = solids[0]
		var scx: float = float(s0.get("x", 0)) + float(s0.get("w", 120)) * 0.5
		var scy: float = float(s0.get("y", 0)) + float(s0.get("h", 120)) * 0.5
		for qi in 4:
			cam.focus = _to3d(scx, scy) + Vector3(0, 2.6, 0)
			cam.dist = 24.0
			cam.pitch_deg = 18.0
			cam.yaw = TAU * float(qi) / 4.0 + 0.4
			await get_tree().create_timer(0.8).timeout
			await _snap("res://art_ch%02d_bld%d.png" % [chn, qi])
	# ③ 貨櫃／④ 碉堡（地圖有才拍）
	var shots := [["containers", "container", 16.0, 14.0], ["pillboxes", "pillbox", 13.0, 16.0]]
	for sp in shots:
		var arr: Array = map_data.get(sp[0], [])
		if arr.is_empty():
			continue
		var it: Dictionary = arr[0]
		cam.focus = _to3d(float(it.get("x", 0)), float(it.get("y", 0))) + Vector3(0, 1.6, 0)
		cam.dist = float(sp[2])
		cam.pitch_deg = float(sp[3])
		cam.yaw = 0.7
		await get_tree().create_timer(1.0).timeout
		await _snap("res://art_ch%02d_%s.png" % [chn, sp[1]])
	print("[artshots] ch%02d DONE" % chn)
	_quit_test(0)

# ---------- 障礙傾印（-- blkdump chNN）：查「人卡在那裡但不知道撞到什麼」 ----------
func _blkdump() -> void:
	if not await _boot_to_battle("blkdump"): _quit_test(1); return
	var x0 := 820.0; var x1 := 960.0; var y0 := 700.0; var y1 := 820.0
	print("[blkdump] 區域 x∈[%.0f,%.0f] y∈[%.0f,%.0f] 的障礙：" % [x0, x1, y0, y1])
	for bk in _blockers:
		var c: Vector2
		if bk["t"] == "seg":
			c = (bk["a"] + bk["b"]) * 0.5
		else:
			c = bk["c"]
		if c.x >= x0 and c.x <= x1 and c.y >= y0 and c.y <= y1:
			print("[blkdump] ", bk)
	print("[blkdump] DONE")
	_quit_test(0)

# ---------- 訓練場 UI 驗收（-- trainshot）----------
# 不驗內部值先行：開真的訓練場畫面 → 拍圖 → 點真的「升級」按鈕 → 驗池扣了、等級加了
# → 再拍圖。訊號路徑（training_up → _on_training_up → show_training 刷新）全程真跑。
func _trainshot() -> void:
	_test_mode = true
	await get_tree().create_timer(0.6).timeout
	_growth = {"pool": 500, "lv": {"assault": 2}}
	_open_training()
	await get_tree().create_timer(0.6).timeout
	await _snap("res://trainshot_before.png")
	var fails := 0
	var b := _find_btn("升級")
	if b == null:
		print("[train] FAIL 找不到任何可按的升級按鈕")
		fails += 1
	else:
		_send_click(b.get_global_rect().get_center())
		await get_tree().create_timer(0.5).timeout
		var pool: int = int(_growth["pool"])
		var lv_sum := 0
		for k in _growth["lv"]:
			lv_sum += int(_growth["lv"][k])
		print("[train] 點升級後 pool=%d（應 <500）lv合計=%d（應 3） %s"
				% [pool, lv_sum, "OK" if (pool < 500 and lv_sum == 3) else "FAIL"])
		if pool >= 500 or lv_sum != 3:
			fails += 1
	await _snap("res://trainshot_after.png")
	# 反驗證：池歸零後所有升級按鈕都要 disabled（不可負債升級）
	_growth["pool"] = 0
	ui.show_training(0, _growth["lv"])
	await get_tree().create_timer(0.4).timeout
	var any_enabled := false
	for n in ui.root.find_children("*", "Button", true, false):
		var bb := n as Button
		if bb.text.contains("升級") and not bb.disabled:
			any_enabled = true
	print("[train] 池=0 時升級按鈕全部鎖定 %s" % ("OK" if not any_enabled else "FAIL(還能負債升級)"))
	if any_enabled:
		fails += 1
	print("[train] FAILS=%d" % fails)
	print("[train] DONE")
	get_tree().quit(1 if fails > 0 else 0)

func _stress_nearest_enemy(u):
	var best = null
	var bd := 1e18
	for e in units:
		if e["side"] == u["side"] or not e["alive"] or not is_instance_valid(e["node"]):
			continue
		var d: float = Vector2(float(e["wx"]) - float(u["wx"]), float(e["wy"]) - float(u["wy"])).length_squared()
		if d < bd:
			bd = d
			best = e
	return best

# 回合末全員掃描：出界／陷進實體／浮空陷地（載具的貼地規則不同，只驗步兵）。
# ⚠ 浮空/陷地要**複查**：走下河堤的自由落體、被推上台階的限速爬升，
#   單一瞬間都可能 |dy|>0.35，那是物理正常。0.9 秒後還沒回到地面才是 bug
#   （走查台同一條教訓：連續四次取樣才算）。
func _stress_sweep() -> int:
	var mwp: float = map_data.get("w", 960)
	var mhp: float = map_data.get("h", 600)
	var n := 0
	var recheck: Array = []
	for u in units:
		if not u["alive"] or not is_instance_valid(u["node"]):
			continue
		var wp: Vector3 = u["node"].global_position
		var now := _live_px(u)
		var who: String = "%s(%s)" % [u["cls"], ("我方" if u["side"] == player_side else "敵方")]
		if now.x < -1.0 or now.y < -1.0 or now.x > mwp + 1.0 or now.y > mhp + 1.0:
			print("[stress] FAIL 出界 %s px=(%.0f,%.0f)" % [who, now.x, now.y])
			n += 1
		# ⚠ 半徑要跟每幀解算用的**同一個**（2026-08-03）：先前掃描一律用 BODY_R(0.42m)，
		#   但 _solid_bodies 對載具用的是 VEHICLE_R(1.6m)。同一台坦克兩個數字，
		#   於是「解算覺得沒問題、掃描說陷進去了」這種縫永遠修不完。
		var chk_r: float = VEHICLE_R if Unit.is_vehicle_cls(u["cls"]) else BODY_R
		var fixed: Vector3 = _resolve_solids(wp, chk_r, u)
		if not _flies_over_solids(u) 				and Vector2(fixed.x - wp.x, fixed.z - wp.z).length() > 0.06:
			# ⚠ 只印座標不夠：2026-08-02 為了同一個座標連改四次都沒中，
			#   因為看不出「是什麼把人推開」。斷言必須指出來源。
			print("[stress] FAIL 陷進實體 %s px=(%.0f,%.0f) 來源=%s"
					% [who, now.x, now.y, _why_solid(wp, chk_r, u)])
			n += 1
		if not Unit.is_vehicle_cls(u["cls"]):
			if absf(wp.y - _ground_height(wp)) > 0.35:
				recheck.append(u)
	if not recheck.is_empty():
		await get_tree().create_timer(0.9).timeout
		for u2 in recheck:
			if not u2["alive"] or not is_instance_valid(u2["node"]):
				continue
			var wp2: Vector3 = u2["node"].global_position
			var dy2: float = wp2.y - _ground_height(wp2)
			if absf(dy2) > 0.35:
				print("[stress] FAIL 浮空/陷地 %s(%s) dy=%.2fm（複查 0.9s 後仍未回地面）"
						% [u2["cls"], ("我方" if u2["side"] == player_side else "敵方"), dy2])
				n += 1
	return n

# 使用者 2026-07-27：「反驗證是要實際你自己玩過全部的功能都沒有問題才叫修好」。
# 這裡不驗任何內部指標，只做玩家會做的事：切換單位、走進屋子、停下來、按姿勢鍵，
# 每一步都留一張玩家視角的圖，並印出「玩家看得到的那個結果」。
func _playtest() -> void:
	if not await _boot_to_battle("play"): _quit_test(1); return
	var fails := 0

	# A) 切換單位鍵（畫面外的隊友要能叫得出來）
	var before_sel = selected
	_tap_key(KEY_TAB)
	await get_tree().create_timer(0.5).timeout
	var ok_cycle: bool = selected != null and selected != before_sel
	print("[play][切換單位] 按 Tab 後 selected=%s %s"
			% [(selected["cls"] if selected != null else "null"), "OK" if ok_cycle else "FAIL"])
	if not ok_cycle: fails += 1
	await _snap("res://play_cycle.png")

	# B) 點兵下令 → 第三人稱
	var pu = _deployed[0]
	_send_click(cam.unproject_position(pu["node"].global_position + Vector3(0, 1.0, 0)))
	await get_tree().create_timer(0.4).timeout
	if not cam.is_tps():
		print("[play][下令] FAIL 沒進第三人稱"); _quit_test(1); return
	print("[play][下令] 第三人稱 OK")

	# C) 停下來不可以自動蹲回去（使用者回報）
	pu["node"].want_cover = true            # 就算判定成「在掩體裡」也不該自動蹲
	await get_tree().create_timer(1.6).timeout
	var c_idle: float = pu["node"]._crouch
	print("[play][停下不自動蹲] want_cover=true 靜置 1.6s 後 _crouch=%.2f %s"
			% [c_idle, "OK" if c_idle < 0.05 else "FAIL(又自己蹲回去了)"])
	if c_idle >= 0.05: fails += 1
	await _snap("res://play_stand.png")

	# D) 姿勢鍵三顆都要真的有效
	# ⚠ 姿勢鍵是「每幀輪詢 Input.is_key_pressed 抓上升緣」，同一幀按下又放開輪詢看不到，
	#   必須按住至少一幀以上（這是測試寫法的坑，不是遊戲的 bug）。
	await _hold_key(KEY_C, 0.12); await get_tree().create_timer(1.2).timeout
	var c_c: float = pu["node"]._crouch
	var st_c: String = str(pu["node"]._state)
	await _snap("res://play_key_c.png")
	await _hold_key(KEY_Z, 0.12); await get_tree().create_timer(1.4).timeout
	var c_z: float = pu["node"]._prone
	await _snap("res://play_key_z.png")
	await _hold_key(KEY_SPACE, 0.12); await get_tree().create_timer(1.4).timeout
	var c_s: float = maxf(pu["node"]._crouch, pu["node"]._prone)
	await _snap("res://play_key_space.png")
	# ⚠ 混合值到 1 不等於畫面上蹲下去了：按 C 走的是 stance_cmd，
	#   而動畫分支以前只看 want_cover → 人站著、_crouch=1.00，斷言照樣通過。
	#   所以要連「動畫狀態真的切到 crouch」一起驗。
	print("[play][姿勢鍵] C→_crouch=%.2f 動畫=%s %s ／ Z→_prone=%.2f %s ／ Space→最大姿勢值=%.2f %s"
			% [c_c, st_c, "OK" if (c_c > 0.8 and st_c == "crouch") else "FAIL(值對但動畫沒切)",
			c_z, "OK" if c_z > 0.8 else "FAIL", c_s, "OK" if c_s < 0.05 else "FAIL"])
	if c_c <= 0.8 or st_c != "crouch" or c_z <= 0.8 or c_s >= 0.05: fails += 1

	# D2) ★原地跑步（使用者連續三輪回報）：按住 W 走一段、放開、等 1 秒，
	#     動畫狀態必須回到 idle。舊寫法的狀態回歸白名單漏了 run/walk/sprint，
	#     於是鍵盤移動過的角色永遠停在跑步動畫。
	#     ⚠ 這條斷言要看 `_state`（實際在播的動畫），不是看「有沒有在移動」——
	#       「有沒有在移動」是對的，錯的是動畫沒跟著回去。
	await _hold_key(KEY_W, 1.0)
	await get_tree().create_timer(1.0).timeout
	var st_stop: String = str(pu["node"]._state)
	print("[play][停下不原地跑步] 放開 W 一秒後動畫=%s 移動中=%s %s"
			% [st_stop, pu["node"].is_moving(),
			"OK" if st_stop == "idle" else "FAIL(還在播移動動畫＝原地跑步)"])
	if st_stop != "idle": fails += 1
	await _snap("res://play_stop_idle.png")

	# D3) ★鏡頭抖動（使用者：「進入建築物畫面會一直跳」）：
	#     角色完全靜止時，逐幀量鏡頭位移。約束若寫在「平滑之後的實際位置」上，
	#     平滑往外推、修正往內拉，每幀互相打架＝畫面持續抖動，這裡量得出來。
	var jit_max := 0.0
	var jit_prev: Vector3 = cam.global_position
	var jt := 0.0
	while jt < 1.5:
		await get_tree().process_frame
		jt += get_process_delta_time()
		jit_max = maxf(jit_max, jit_prev.distance_to(cam.global_position))
		jit_prev = cam.global_position
	print("[play][鏡頭不抖] 角色靜止 1.5 秒，鏡頭每幀最大位移=%.4fm %s"
			% [jit_max, "OK" if jit_max < 0.02 else "FAIL(鏡頭在震盪)"])
	if jit_max >= 0.02: fails += 1

	# D4) ★手不可以在背後（使用者：「我不知道你是頭裝反還是手裝反，就是手會在後面」）。
	#     把鏡頭轉 180 度，等身體轉過來，然後量「持槍手在胸口的前面還是後面」。
	#     ⚠ 這條斷言的關鍵是**量前後方向**，不是量「手臂骨頭在不在」——
	#       手臂一直都在，錯的是它被 IK 拉到身體後面（量存在性會通過，量方向才抓得到）。
	var yaw0: float = cam.tps_yaw
	cam.tps_yaw = yaw0 + 180.0
	await get_tree().create_timer(1.6).timeout
	# ⚠ `pu["node"]` 是 Dictionary 取值＝Variant，`:=` 推不出型別（Parse Error）。要明寫。
	var sk_a: Array = (pu["node"] as Node3D).find_children("*", "Skeleton3D", true, false)
	if not sk_a.is_empty():
		var ska := sk_a[0] as Skeleton3D
		var ci := ska.find_bone("Chest")
		var hi2 := ska.find_bone("Hand.R")
		if ci >= 0 and hi2 >= 0:
			var cw: Vector3 = ska.global_transform * ska.get_bone_global_pose(ci).origin
			var hw: Vector3 = ska.global_transform * ska.get_bone_global_pose(hi2).origin
			var fwd_b: Vector3 = pu["node"].facing_dir()
			var ahead: float = (hw - cw).dot(fwd_b)
			var yaw_gap: float = rad_to_deg(absf(wrapf(deg_to_rad(cam.tps_yaw)
					- pu["node"].rotation.y, -PI, PI)))
			print("[play][手在身體前面] 鏡頭轉 180 度後：持槍手在胸口前方 %.3fm、"
					% ahead + "身體與鏡頭夾角 %.0f 度 %s"
					% [yaw_gap, "OK" if (ahead > 0.05 and yaw_gap < 20.0)
					else "FAIL(手在背後／身體沒跟著鏡頭轉)"])
			if ahead <= 0.05 or yaw_gap >= 20.0: fails += 1
	await _snap("res://play_arm_front.png")

	# E) 走進最近的建築：驗屋頂淡出、鏡頭不穿牆
	# 走進屋子要走一段路，AP 會先用完（AP 用盡＝停下，看起來像被擋住）。
	# ⚠ 補 AP 一定要在 _begin_action 之後，它會 ×0.7^N 重算（2026-07-26 的假通過就是這樣來的）。
	acting["ap"] = 9999.0
	acting["ap_max"] = 9999.0
	var bd = _nearest_building(_live_px(pu))
	if bd == null:
		print("[play][進屋] 這張圖沒有建築，跳過")
	else:
		var door: Vector2 = bd.doors[0] if not bd.doors.is_empty() else bd.rect.get_center()
		# 走到門口再進去：用真的操作（轉向 + 按 W），不瞬移。
		# 直線不通就用遊戲自己的 _avoid_goal 繞（新 ch01 圖部署區到營舍之間有工事線，
		# 直線走法會卡在沙包上磨蹭——玩家自己也會繞，測試不該比玩家笨）。
		# 進門要走三段：門外定位點 → 門內定位點 → 屋中心。
		# 直接朝「屋中心」走的話，從門口側邊 1m 起步會斜切進牆面、沿牆磨蹭永遠
		# 進不了門洞（play 第四輪軌跡：x 在 881↔905 之間 ping-pong、y 卡在牆外 771）。
		var bctr: Vector2 = bd.rect.get_center()
		var ddv: Vector2 = door - bctr
		var outward: Vector2 = Vector2(signf(ddv.x), 0.0) if absf(ddv.x) > absf(ddv.y) \
				else Vector2(0.0, signf(ddv.y))
		var stage: Vector2 = door + outward * 26.0     # 門外 1.3m
		var inner: Vector2 = door - outward * 26.0     # 門內 1.3m
		# ⚠⚠ 容差不可以比門洞半寬還大（2026-08-04）：門外定位點原本容差 0.8m，
		#   於是人可以「合格地」停在門洞**旁邊 0.75m 的牆前面**，接著往北就是撞牆，
		#   而診斷顯示四個關鍵點全都沒有障礙——不是碰撞問題，是**對位問題**。
		#   這也是 play 時好時壞的真因：幀率不同 → 停的位置不同 → 有時剛好對準門。
		#   門洞約 1m 寬，容差收到 0.3m 才保證人真的站在門洞正前方。
		var ok_in := await _walk_to_px(pu, stage, 30.0, 0.3)
		for _detour in 4:
			if ok_in:
				break
			var mwp2: float = map_data.get("w", 960)
			var mhp2: float = map_data.get("h", 600)
			var way: Vector3 = _avoid_goal(pu["node"].global_position,
					_to3d(stage.x, stage.y), BODY_R)
			var wp2 := Vector2(way.x / WORLD_SCALE + mwp2 * 0.5,
					way.z / WORLD_SCALE + mhp2 * 0.5)
			if wp2.distance_to(_live_px(pu)) * WORLD_SCALE < 1.0:
				break
			await _walk_to_px(pu, wp2, 10.0)
			ok_in = await _walk_to_px(pu, stage, 30.0, 0.3)
		if ok_in:
			ok_in = await _walk_to_px(pu, inner, 14.0, 0.5)
		if ok_in:
			ok_in = await _walk_to_px(pu, bctr, 14.0)
		var inside: bool = bd.inside(_live_px(pu).x, _live_px(pu).y)
		var here_px := _live_px(pu)
		print("[play][進屋] 走進去=%s（人在 px(%.0f,%.0f)、門在 px(%.0f,%.0f)、屋框 %s）"
				% ["OK" if inside else "FAIL(走不進去)", here_px.x, here_px.y,
				door.x, door.y, bd.rect])
		if not inside:
			fails += 1
			print("[play][進屋] 收工時還差 %.1fm、最後兩秒前進 %.2fm → %s"
					% [_walk_left, _walk_gain,
					"停滯不前（真的走不過去）" if _walk_gain < 0.15 else "還在前進、只是時間不夠"])
			# ⚠ 只印「走不進去」等於沒說原因（lessons 0b：斷言要指出兇手）。
			#   把門口這條路上的三個關鍵點各問一次「是什麼在推人」。
			for tag_pt in [["人所在", here_px], ["門外定位點", stage],
					["門口", door], ["門內定位點", inner]]:
				var pt: Vector2 = tag_pt[1]
				print("[play][進屋] %s px=(%.0f,%.0f) 阻擋=%s"
						% [tag_pt[0], pt.x, pt.y,
						_why_solid(_to3d(pt.x, pt.y), BODY_R, pu)])
		await get_tree().create_timer(1.2).timeout
		await _snap("res://play_indoor.png")
		# 鏡頭不可以停在牆的另一側：從角色頭部到鏡頭之間不能有牆
		var head: Vector3 = pu["node"].global_position + Vector3(0, 1.5, 0)
		var k: float = _wall_ray(head, cam.global_position)
		print("[play][鏡頭穿牆] 頭→鏡頭的牆體命中比例=%.2f（1.00＝沒穿牆）%s"
				% [k, "OK" if k > 0.985 else "FAIL(鏡頭在牆外/牆裡)"])
		if k <= 0.985: fails += 1
		var bi := _buildings.find(bd)
		# ★鏡頭在屋裡時屋頂**要留著**（不然室內變成一個沒有蓋子的箱子，
		#   使用者：「在裡面會變成感覺沒有牆壁一樣可以看到外面」）
		var a_in: float = float(_roof_a.get(bi, 1.0))
		print("[play][室內留屋頂] 鏡頭在屋裡時屋頂 alpha=%.2f %s"
				% [a_in, "OK(室內是室內)" if a_in > 0.65 else "FAIL(屋頂被淡掉，室內看得到天空)"])
		if a_in <= 0.65: fails += 1
		# 離開行動模式（鏡頭回到俯瞰）後，屋頂才該淡出——那是給俯瞰看屋裡有誰用的
		_end_action()
		await get_tree().create_timer(1.2).timeout
		var alpha: float = float(_roof_a.get(bi, 1.0))
		print("[play][俯瞰淡屋頂] 鏡頭在屋外時屋頂 alpha=%.2f %s"
				% [alpha, "OK(看得到屋裡的人)" if alpha < 0.35 else "FAIL(屋頂還蓋著，屋內的人點不到)"])
		if alpha >= 0.35: fails += 1
		await get_tree().create_timer(0.2).timeout
		selected = null
		_send_click(cam.unproject_position(pu["node"].global_position + Vector3(0, 1.0, 0)))
		await get_tree().create_timer(0.4).timeout
		print("[play][屋內點兵] selected=%s %s"
				% [(selected["cls"] if selected != null else "null"), "OK" if selected != null else "FAIL(點不到)"])
		if selected == null: fails += 1
		await _snap("res://play_indoor_pick.png")

	# F) 屋內四面環顧：使用者 2026-07-27「建築物裡人物在裡面會變成感覺沒有牆壁一樣可以看到外面」。
	#    站在屋子正中央，把鏡頭轉四個方向各拍一張——四張都該看到牆。
	if bd != null:
		_send_click(cam.unproject_position(pu["node"].global_position + Vector3(0, 1.0, 0)))
		await get_tree().create_timer(0.4).timeout
		acting["ap"] = 9999.0
		await _walk_to_px(pu, bd.rect.get_center(), 8.0)
		for k in 4:
			cam.tps_yaw = float(k) * 90.0
			await get_tree().create_timer(0.7).timeout
			await _snap("res://play_in_look%d.png" % k)
		print("[play][屋內環顧] 已拍四個方向 play_in_look0~3.png")

	# F2) ★遊戲裡近拍英雄：使用者的截圖顯示「沒有手、武器，或在背後」，
	#     但我的隔離驗證台（ArmShot）拍出來手臂與槍都在。差別一定在「遊戲裡」這條路徑上，
	#     所以要在**真實戰場**用戰術鏡頭繞著英雄拍四圈，跟使用者看到的同框比對。
	var hero_node: Node3D = pu["node"]
	_end_action()
	await get_tree().create_timer(0.4).timeout
	cam.clear_tps()
	cam.set_follow(null)
	for ang_i in 4:
		cam.focus = hero_node.global_position + Vector3(0, 1.05, 0)
		cam.dist = 3.4
		cam.pitch_deg = 10.0
		cam.yaw = float(ang_i) * PI * 0.5
		await get_tree().create_timer(0.7).timeout
		await _snap("res://play_hero%d.png" % ang_i)
	var sk_h := hero_node.find_children("*", "Skeleton3D", true, false)
	if not sk_h.is_empty():
		var skx := sk_h[0] as Skeleton3D
		var names := []
		for bn in ["UpperArm.L", "LowerArm.L", "Hand.L", "UpperArm.R", "LowerArm.R", "Hand.R"]:
			var bix := skx.find_bone(bn)
			names.append("%s=%s" % [bn, "有" if bix >= 0 else "缺"])
		print("[play][英雄骨頭] cls=%s 模型骨數=%d %s" % [pu["cls"], skx.get_bone_count(), " ".join(names)])
	print("[play][英雄近拍] play_hero0~3.png（手臂與武器要在畫面上）")

	# G) 固體不可互穿（使用者回報「人誤會穿過牆壁、戰車」）。
	#    ⚠ 這裡**不隔離**任何障礙——使用者是在完整戰場上撞到的，隔離出來的測試證明不了。
	var solid_fail := 0
	if bd != null:
		# G-1 對著外牆走 5 秒：不可以進到室內
		var bc: Vector2 = bd.rect.get_center()
		var wall_y: float = bc.y + bd.rect.size.y * 0.5
		var start := Vector2(bc.x + bd.rect.size.x * 0.33, wall_y + 4.5 / WORLD_SCALE)
		_end_action()
		await get_tree().create_timer(0.3).timeout
		cp = 6
		pu["node"].global_position = _to3d(start.x, start.y)
		pu["wx"] = start.x
		pu["wy"] = start.y
		_begin_action(pu)
		pu["ap"] = 9999.0
		pu["ap_max"] = 9999.0
		cam.tps_yaw = 180.0                      # 朝 -z＝往北，正對南牆（避開門，偏 1/3 屋寬）
		await get_tree().create_timer(0.4).timeout
		await _hold_key(KEY_W, 5.0)
		var inb: bool = bd.inside(_live_px(pu).x, _live_px(pu).y)
		print("[play][撞牆] 對外牆走 5 秒：進到室內=%s %s"
				% [inb, "OK(牆擋住了)" if not inb else "FAIL(人穿牆進去了)"])
		if inb:
			solid_fail += 1
		await _snap("res://play_wall.png")
	# G-1a ★窗戶下方的牆不可以穿過（使用者：「特別是有窗戶、門一定會」）。
	#      門洞在規則上就是通路（唯一入口，這是設計），但**窗戶不是**——
	#      窗台以下是實心牆，人不可能從窗戶「走」進去。
	# ⚠ 最近的那棟剛好是武器庫（kind=depot，**故意不開窗**），
	#   直接用 bd 會靜默跳過這一項＝等於沒驗。要挑一棟真的有窗的。
	var wbd = null
	for b3 in _buildings:
		if not b3.windows.is_empty():
			wbd = b3
			break
	if wbd != null:
		var wpx: Vector2 = wbd.windows[0]
		var bcw: Vector2 = wbd.rect.get_center()
		var outw: Vector2 = (wpx - bcw).normalized()
		_end_action()
		await get_tree().create_timer(0.3).timeout
		cp = 6
		var wstart: Vector2 = wpx + outw * (4.0 / WORLD_SCALE)
		pu["node"].global_position = _to3d(wstart.x, wstart.y)
		pu["wx"] = wstart.x
		pu["wy"] = wstart.y
		_begin_action(pu)
		pu["ap"] = 9999.0
		pu["ap_max"] = 9999.0
		var tow: Vector3 = _to3d(wpx.x, wpx.y) - pu["node"].global_position
		cam.tps_yaw = rad_to_deg(atan2(tow.x, tow.z))
		await get_tree().create_timer(0.4).timeout
		await _hold_key(KEY_W, 4.0)
		var in_win: bool = wbd.inside(_live_px(pu).x, _live_px(pu).y)
		print("[play][撞窗戶] 對著窗戶走 5 秒：進到室內=%s %s"
				% [in_win, "OK(窗台下是實心牆)" if not in_win else "FAIL(從窗戶走進去了)"])
		if in_win:
			solid_fail += 1
		await _snap("res://play_window.png")

	# G-1b 室內家具也不可以穿過（使用者實拍：人站在木箱裡面）
	if bd != null and not bd.solids_local.is_empty():
		var fsl = bd.solids_local[0]
		var fpx: Vector2 = bd._local_to_px(Vector2(float(fsl[0]), float(fsl[1])))
		var fr_m: float = float(fsl[2])
		_end_action()
		await get_tree().create_timer(0.3).timeout
		cp = 6
		var fstart: Vector2 = fpx + Vector2(1.0, 0.0) * (3.0 / WORLD_SCALE)
		pu["node"].global_position = _to3d(fstart.x, fstart.y)
		pu["wx"] = fstart.x
		pu["wy"] = fstart.y
		_begin_action(pu)
		pu["ap"] = 9999.0
		pu["ap_max"] = 9999.0
		var tof: Vector3 = _to3d(fpx.x, fpx.y) - pu["node"].global_position
		cam.tps_yaw = rad_to_deg(atan2(tof.x, tof.z))
		await get_tree().create_timer(0.4).timeout
		await _hold_key(KEY_W, 4.0)
		var fgap: float = Vector2(_live_px(pu).x - fpx.x, _live_px(pu).y - fpx.y).length() * WORLD_SCALE
		print("[play][撞室內家具] 對家具走 4 秒：離家具中心 %.2fm（家具半徑 %.2fm）%s"
				% [fgap, fr_m, "OK(擋住了)" if fgap > fr_m * 0.85 else "FAIL(穿過家具)"])
		if fgap <= fr_m * 0.85:
			solid_fail += 1
		await _snap("res://play_furniture.png")

	# G-2 對著戰車走 5 秒：不可以穿過車體
	var veh = null
	for u2 in units:
		if u2["alive"] and Unit.is_vehicle_cls(u2["cls"]):
			veh = u2
			break
	if veh == null:
		# 這張圖第一回合沒有載具就自己生一台來撞（SKIP 等於沒驗，而使用者是真的撞到了）
		var tank_cls := ""
		for ck in GameData.class_base.keys():
			if Unit.is_vehicle_cls(String(ck)):
				tank_cls = String(ck)
				break
		if tank_cls != "":
			var tp := Vector2(_live_px(pu).x + 90.0, _live_px(pu).y)
			veh = _spawn_unit(tank_cls, 1 - player_side, tp.x, tp.y, false)
			await get_tree().create_timer(0.5).timeout
			print("[play][撞戰車] 場上沒有載具，生成一台 ", tank_cls, " 來撞")
	if veh == null:
		print("[play][撞戰車] SKIP 這份資料沒有載具兵種")
	else:
		# ★★2026-07-27 使用者實測：「從戰車後面可以穿過車尾走到車子中間」。
		#   舊斷言量的是「離車心的距離 > 車半徑 1.6m」——人站在車尾內部 1.6m 處
		#   （車體半長 3.0m）照樣通過。**量錯維度＝白驗**，這是本專案第四次踩到。
		#   改成兩件事：
		#     ① 四個方向都撞（車頭／車尾／左側／右側），車尾正是他回報的那個方向
		#     ② 判準改「在車體座標系裡有沒有進到盒子內」，不是離車心多遠
		# ⚠ 走 6 秒會被敵方警戒射擊打死，下一行讀 _live_px 就炸「previously freed」
		var tank_save := _shield(pu)
		# ⚠ 先把車搬到淨空地：實測有一次起點在山坡裡，人 6 秒只走了 0.1m，
		#   而「離車體很遠」在只有下限的舊斷言裡照樣印 OK ——前提不成立的測試等於沒測。
		var tspot := _open_spot([10.0, 8.0, 6.0])
		veh["node"].global_position = _to3d(tspot.x, tspot.y)
		veh["wx"] = tspot.x
		veh["wy"] = tspot.y
		await get_tree().create_timer(0.4).timeout
		var dir_i := 0
		for dir_name in ["車尾", "車頭", "左側", "右側"]:
			dir_i += 1
			var vobb := _vehicle_obb(veh)
			var ax: Vector2 = vobb["ax"]                   # 車身前後軸（px 平面）
			var ay := Vector2(-ax.y, ax.x)
			var away: Vector2 = {"車尾": -ax, "車頭": ax, "左側": -ay, "右側": ay}[dir_name]
			# ⚠ 判準要用**這台車實際的**碰撞盒，不可用坦克常數（2026-08-02）：
			#   換成立繪生成模型後車體是 6.2m（半長 3.1m）、常數還寫 3.00，
			#   0.1m 的差被容差吃掉＝測試對「碰撞盒錯了」這件事失去敏感度。
			#   驅逐艦 18m 更是差一個量級。實際值就在 OBB 裡，直接取。
			var hl_m: float = (vobb["e"] as Vector2).x * WORLD_SCALE
			var hw_m: float = (vobb["e"] as Vector2).y * WORLD_SCALE
			var start_m: float = (hl_m if dir_name in ["車尾", "車頭"] else hw_m) + 4.0
			_end_action()
			await get_tree().create_timer(0.3).timeout
			cp = 6
			var sp2: Vector2 = vobb["c"] + away * (start_m / WORLD_SCALE)
			pu["node"].global_position = _to3d(sp2.x, sp2.y)
			pu["wx"] = sp2.x
			pu["wy"] = sp2.y
			_begin_action(pu)
			pu["ap"] = 9999.0
			pu["ap_max"] = 9999.0
			var tov: Vector3 = veh["node"].global_position - pu["node"].global_position
			cam.tps_yaw = rad_to_deg(atan2(tov.x, tov.z))
			await get_tree().create_timer(0.4).timeout
			await _hold_key(KEY_W, 6.0)
			# 換算到車體座標系：|沿車軸| 與 |沿車寬| 只要有一個超出盒子就是在車外
			var fin: Vector2 = _live_px(pu) - vobb["c"]
			var la: float = absf(fin.dot(ax)) * WORLD_SCALE      # 沿車身前後
			var lb: float = absf(fin.dot(ay)) * WORLD_SCALE      # 沿車身左右
			# 離車體「表面」多遠：人是 0.42m 的圓，貼上去時應該正好停在 0.42m
			var surf: float = maxf(la - hl_m, lb - hw_m)
			# ⚠ 兩端都要驗（本專案第三次踩到單邊門檻）：
			#   下限＝沒穿進車體；**上限＝真的走到車邊**。少了上限的話，
			#   「人卡在別的東西上、根本沒走到坦克」也會印 OK ——前提不成立的測試等於沒測。
			var reached: bool = surf < BODY_R + 0.8
			var ok_tank: bool = surf > BODY_R - 0.1 and reached
			var verdict: String = "OK(被車擋住)"
			if surf <= BODY_R - 0.1:
				verdict = "FAIL(穿進車體 %.2fm)" % (BODY_R - surf)
			elif not reached:
				verdict = "FAIL(前提不成立：走了 6 秒還離車體 %.2fm，根本沒撞到)" % surf
			print("[play][撞戰車] 從%s走 6 秒：離車體表面 %.2fm｜車體座標 沿車軸 %.2fm(半長%.2f)／沿車寬 %.2fm(半寬%.2f) %s"
					% [dir_name, surf, la, hl_m, lb, hw_m, verdict])
			if not ok_tank:
				solid_fail += 1
			await _snap("res://play_tank_%d.png" % dir_i)
		_unshield(pu, tank_save)
	fails += solid_fail

	print("[play] FAILS=%d" % fails)
	print("[play] DONE")
	_quit_test(0)

func _tap_key(code: Key) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = true
	Input.parse_input_event(e)
	var u := InputEventKey.new()
	u.keycode = code
	u.physical_keycode = code
	u.pressed = false
	Input.parse_input_event(u)

func _nearest_building(p: Vector2):
	var best = null
	var bd_d := 1e9
	for b in _buildings:
		var d: float = b.rect.get_center().distance_to(p)
		if d < bd_d:
			bd_d = d
			best = b
	return best

# 用「真的按鍵」走到地圖上某個 px 座標（先把鏡頭轉到目標方向再按 W）。
# ⚠ 不可以直接設座標——使用者要求驗收一律「用走的」，瞬移證明不了碰撞與鏡頭。
# 逾時時的兩種情況要分得出來（2026-08-04）：「停滯不前」是真 bug，
# 「還在前進但時間不夠」只是預算太緊。放寬預算若不附這個判別，就等於掩蓋 bug。
var _walk_gain := 0.0        # 最後兩秒縮短了多少距離（公尺）
var _walk_left := 0.0        # 收工時還差多少
func _walk_to_px(u, target_px: Vector2, secs: float, tol := 1.1) -> bool:
	var t3 := _to3d(target_px.x, target_px.y)
	var gain_t: float = Time.get_ticks_msec() / 1000.0 + 2.0
	var gain_from := 1e9
	var deadline: float = Time.get_ticks_msec() / 1000.0 + secs
	var down := InputEventKey.new()
	down.keycode = KEY_W
	down.physical_keycode = KEY_W
	down.pressed = true
	Input.parse_input_event(down)
	var arrived := false
	var log_t: float = 0.0
	var check_t: float = Time.get_ticks_msec() / 1000.0 + 0.7
	var last_d: float = 1e9
	var strafe: Key = KEY_D
	while Time.get_ticks_msec() / 1000.0 < deadline:
		var here: Vector3 = u["node"].global_position
		var to := t3 - here
		to.y = 0.0
		if to.length() < tol:
			arrived = true
			break
		cam.tps_yaw = rad_to_deg(atan2(to.x, to.z))     # 鏡頭朝目標，W＝往鏡頭前方走
		var now: float = Time.get_ticks_msec() / 1000.0
		_walk_left = to.length()
		if gain_from > 1e8:
			gain_from = to.length()
		if now > gain_t:
			_walk_gain = gain_from - to.length()
			gain_from = to.length()
			gain_t = now + 2.0
		if now > log_t:
			log_t = now + 1.0
			print("[play][走路] 還差 %.1fm　AP=%.0f　px=(%.0f,%.0f)"
					% [to.length(), float(u.get("ap", 0.0)), _live_px(u).x, _live_px(u).y])
		# 撞到障礙就側移繞過去——真人玩家就是這樣走的。
		# 少了這段，測試會把「路上有一段磚牆」誤判成「進不了建築」。
		if now > check_t:
			check_t = now + 0.7
			if last_d - to.length() < 0.08:
				# ⚠⚠ 2026-08-04：舊版是「左右輪流試」（D 0.75 秒、換 A 0.75 秒），
				#   淨位移為零。實測軌跡：人貼在南牆外側 y=771 來回擺盪
				#   870→901→880→904→883→905，永遠在門洞東邊 2m，進不了門
				#   ——這就是 play「走不進屋」時好時壞的真因（幀率決定擺到哪一邊停）。
				#   真人玩家會往**空的那一側**繞。改成先量兩側 1.2m 有沒有實體，
				#   哪邊空就往哪邊；兩邊都空就選比較接近目標的那邊。
				var fwd2 := Vector3(to.x, 0.0, to.z).normalized()
				var rightv := Vector3(-fwd2.z, 0.0, fwd2.x)
				var free_r: bool = _resolve_solids(here + rightv * 1.2, BODY_R, u)						.distance_to(here + rightv * 1.2) < 0.05
				var free_l: bool = _resolve_solids(here - rightv * 1.2, BODY_R, u)						.distance_to(here - rightv * 1.2) < 0.05
				if free_r != free_l:
					strafe = KEY_D if free_r else KEY_A
				elif free_r and free_l:
					# 兩邊都空：往「側移之後離目標比較近」的那一側
					var dr: float = (here + rightv * 1.2).distance_to(t3)
					var dl: float = (here - rightv * 1.2).distance_to(t3)
					strafe = KEY_D if dr < dl else KEY_A
				var sd := InputEventKey.new()
				sd.keycode = strafe; sd.physical_keycode = strafe; sd.pressed = true
				Input.parse_input_event(sd)
				await get_tree().create_timer(0.75).timeout
				var su := InputEventKey.new()
				su.keycode = strafe; su.physical_keycode = strafe; su.pressed = false
				Input.parse_input_event(su)
				check_t = Time.get_ticks_msec() / 1000.0 + 0.7
			last_d = to.length()
		await get_tree().process_frame
	var up := InputEventKey.new()
	up.keycode = KEY_W
	up.physical_keycode = KEY_W
	up.pressed = false
	Input.parse_input_event(up)
	await get_tree().process_frame
	return arrived

func _shotseq() -> void:
	for i in 5:
		await get_tree().create_timer(1.2).timeout
		await _snap("res://seq_%d.png" % i)
		print("[shotseq] seq_%d st=%d" % [i, st])
	_quit_test(0)

# 主選單 → 章節 → 簡報 → 對話 → 部署 → 開戰。
# e2e 與 playtest 共用，兩邊都必須走「真的按 UI」這條路（測試從中間插進去是驗證盲區）。
# 測試模式旗標：walk/stress/play/e2e 設起。打贏不可以動 user://unlocked.txt——
# 壓測跑贏第 15 章會把使用者的真實戰役進度整條解鎖（反驗證時抓到的髒污路徑）。
var _test_mode := false

# 測試指定章節：`-- walk ch07`／`-- stress ch12`。沒給就第 1 章。
func _test_chapter() -> int:
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with("ch") and s.substr(2).is_valid_int():
			return clampi(int(s.substr(2)), 1, GameData.story.size())
	return 1

func _boot_to_battle(tag: String, deploy_n := 1) -> bool:
	_test_mode = true
	_growth = {"pool": 0, "lv": {}}   # 測試不吃使用者的養成存檔：結果要可重現
	await get_tree().create_timer(0.6).timeout
	print("[%s] 1 主選單 → 劇情戰役" % tag)
	if not await _click_btn("劇情戰役"): return false
	var chn := _test_chapter()
	print("[%s] 2 章節 %02d" % [tag, chn])
	if chn > _unlocked():
		# 只在畫面上解鎖（不寫 user://），讓測試點得到按鈕；使用者進度不動
		ui.show_story(GameData.story.size())
		await get_tree().create_timer(0.3).timeout
	var chb := _find_btn("%02d" % chn)
	if chb == null: print("[%s] FAIL 無章節按鈕" % tag); return false
	# 章節清單是 ScrollContainer：第 10 章以後在畫面外，直接點會點到別的東西
	# （ch10~15 壓測整排「找不到出擊」的真因）。先捲到按鈕再點。
	var sc: Node = chb.get_parent()
	while sc != null and not (sc is ScrollContainer):
		sc = sc.get_parent()
	if sc is ScrollContainer:
		(sc as ScrollContainer).scroll_vertical = maxi(0, int(chb.position.y) - 60)
		await get_tree().create_timer(0.25).timeout
	_send_click(chb.get_global_rect().get_center())
	await get_tree().create_timer(0.5).timeout
	print("[%s] 3 簡報 → 出擊" % tag)
	if not await _click_btn("出擊"): return false
	print("[%s] 4 對話：連點推進 (st=%d)" % [tag, st])
	var guard := 0
	while st == St.DIALOGUE and guard < 40:
		_send_click(Vector2(640, 300))
		await get_tree().create_timer(0.12).timeout
		guard += 1
	print("[%s]   對話結束 st=%d (應為 DEPLOY=%d)" % [tag, st, St.DEPLOY])
	if st != St.DEPLOY: print("[%s] FAIL 沒進到部署" % tag); return false
	print("[%s] 5 部署：點卡片 → 點藍框放置" % tag)
	var cards := ui.root.find_children("*", "Button", true, false)
	var card_btn: Button = null
	for n in cards:
		var b := n as Button
		if b.flat and b.size.x > 250:
			card_btn = b; break
	if card_btn == null: print("[%s] FAIL 找不到部署卡" % tag); return false
	_send_click(card_btn.get_global_rect().get_center())
	await get_tree().create_timer(0.3).timeout
	var z := _my_zone()
	var wp := _to3d(z.get("x", 0) + z.get("w", 300) * 0.5, z.get("y", 0) + z.get("h", 200) * 0.5)
	_send_click(cam.unproject_position(wp + Vector3(0, 0.05, 0)))
	await get_tree().create_timer(0.4).timeout
	# 加碼部署（壓測要多兵）：每次重新找卡片（清單會隨部署刷新）。
	# 放置點在藍框內試多個候選（中心點附近可能已被上一個兵佔住或壓到障礙），
	# 全部放不進去要大聲印——靜默跳過等於沒驗（ch01 壓測第一輪就吃過這虧）。
	for extra_i in range(1, deploy_n):
		var before_n := _deployed.size()
		# ⚠ 要點「第 extra_i+1 張」卡：具名英雄每場只能出一次，重複點第一張
		#   會被 _try_place 的「該隊員已出戰」擋下（ch01 壓測第二輪抓到的真因）
		var all_cards: Array = []
		for n2 in ui.root.find_children("*", "Button", true, false):
			var b2 := n2 as Button
			if b2.flat and b2.size.x > 250:
				all_cards.append(b2)
		if extra_i >= all_cards.size():
			print("[%s]   加碼部署 %d：名冊只有 %d 張卡，有幾個算幾個" % [tag, extra_i, all_cards.size()])
			break
		var cb2: Button = all_cards[extra_i]
		_send_click(cb2.get_global_rect().get_center())
		await get_tree().create_timer(0.3).timeout
		var zw: float = z.get("w", 300)
		var zh: float = z.get("h", 200)
		for frac in [Vector2(0.3, 0.5), Vector2(0.7, 0.5), Vector2(0.5, 0.28),
				Vector2(0.5, 0.72), Vector2(0.25, 0.28), Vector2(0.75, 0.72)]:
			var wp_e := _to3d(z.get("x", 0) + zw * frac.x, z.get("y", 0) + zh * frac.y)
			_send_click(cam.unproject_position(wp_e + Vector3(0, 0.05, 0)))
			await get_tree().create_timer(0.35).timeout
			if _deployed.size() > before_n:
				break
		if _deployed.size() == before_n:
			print("[%s]   加碼部署 %d FAIL：藍框內 6 個候選點都放不進去" % [tag, extra_i])
	print("[%s]   已部署數=%d%s" % [tag, _deployed.size(), (" OK" if _deployed.size() > 0 else " FAIL(放不下去)")])
	if _deployed.is_empty(): return false
	print("[%s] 6 開始戰鬥" % tag)
	if not await _click_btn("開始戰鬥"): return false
	await get_tree().create_timer(0.8).timeout
	print("[%s]   st=%d (應為 CMD=%d)" % [tag, st, St.CMD])
	return true

func _e2e() -> void:
	if not await _boot_to_battle("e2e"): _quit_test(1); return
	print("[e2e] 7 選兵 → 點地面移動")
	var pu = _deployed[0]
	_send_click(cam.unproject_position(pu["node"].global_position + Vector3(0, 1.0, 0)))
	await get_tree().create_timer(0.25).timeout
	print("[e2e]   選取=", "OK" if selected != null else "FAIL(點不到兵)")
	print("[e2e]   第三人稱=%s" % ("OK" if cam.is_tps() else "FAIL(沒進第三人稱)"))
	var before: Vector3 = pu["node"].global_position
	var bpx := _live_px(pu)
	await _hold_key(KEY_W, 1.5)
	var moved: float = before.distance_to(pu["node"].global_position)
	var apx := _live_px(pu)
	print("[e2e]   位移=%.2fm 終點 px=(%.0f,%.0f) %s" % [moved, apx.x, apx.y,
			"OK" if moved > 0.5 else "FAIL(人沒動)"])
	# 站著不動不可以往下沉（鐵律 0：重力只作用到落地為止，不是無止盡下拉）。
	# 使用者 2026-07-26 回報「啟動遊戲有一直往下拉」——加重力那批的回歸，量得出來。
	var sink_u = _deployed[0]
	sink_u["node"].stop()
	await get_tree().create_timer(0.4).timeout
	var y0: float = sink_u["node"].global_position.y
	var my0: float = sink_u["node"]._model.position.y
	var cy0: float = cam.global_position.y
	await get_tree().create_timer(3.0).timeout
	var dy_body: float = sink_u["node"].global_position.y - y0
	var dy_model: float = sink_u["node"]._model.position.y - my0
	var dy_cam: float = cam.global_position.y - cy0
	print("[sinkchk] 靜止 3 秒的垂直漂移：身體 %+.3fm 模型 %+.3fm 鏡頭 %+.3fm %s"
			% [dy_body, dy_model, dy_cam,
			"OK(沒有下沉)" if (absf(dy_body) < 0.05 and absf(dy_model) < 0.05
			and absf(dy_cam) < 0.20) else "FAIL(一直往下拉)"])
	await _snap("res://e2e_battle.png")
	# ★玩家視角近照：ActionTest 用的是通用測試模型，遊戲裡是英雄模型（骨架不同）。
	#   驗證台過不等於遊戲裡對——使用者連續回報「手臂還是不見」，要用這張圖對質。
	var hero = _deployed[0]
	cam.clear_tps()
	cam.set_follow(null)
	# ⚠ QA 反驗證抓到：狙擊手在空地會自動趴下，所以這張「待機」拍到的是趴姿，
	#   整條「站姿手臂」的證據線是空的。要拍站姿就得先關掉自動趴姿並等它站起來。
	hero["node"].want_prone = false
	hero["node"].want_cover = false
	hero["node"].stop()
	await get_tree().create_timer(1.4).timeout
	cam.focus = hero["node"].global_position + Vector3(0, 1.1, 0)
	cam.dist = 3.2
	cam.pitch_deg = 8.0
	cam.yaw = deg_to_rad(35.0)
	await get_tree().create_timer(0.4).timeout
	await _snap("res://e2e_hero_idle.png")
	# 蹲姿移動（使用者 2026-07-26：「連蹲姿移動也是，連手上武器也不見」）
	hero["node"].want_cover = true
	hero["node"].move_to(hero["node"].global_position + hero["node"].facing_dir() * 5.0)
	await get_tree().create_timer(0.8).timeout
	cam.focus = hero["node"].global_position + Vector3(0, 0.9, 0)
	await _snap("res://e2e_hero_crouchwalk.png")
	hero["node"].want_cover = false
	hero["node"].move_to(hero["node"].global_position + hero["node"].facing_dir() * 6.0)
	await get_tree().create_timer(0.7).timeout
	cam.focus = hero["node"].global_position + Vector3(0, 1.1, 0)
	await _snap("res://e2e_hero_run.png")
	# 趴姿在英雄模型上的實況：側面＋正面各一張（背後視角看不出手腳，踩過兩次）
	hero["node"].stop()
	hero["node"].want_prone = true
	await get_tree().create_timer(1.6).timeout
	# ★移動中的匍匐連拍（QA 反驗證指出：先前的 crawl_side*.png 都拍在放開 W 之後，
	#   拍到的是靜止趴姿，根本無法回答「像不像在移動」）。
	#   這裡先把鏡頭擺好，再一邊移動一邊每 0.25 秒拍一張。
	var cf: Vector3 = hero["node"].facing_dir()
	cam.dist = 4.0
	cam.pitch_deg = 6.0
	cam.yaw = atan2(cf.z, cf.x)
	hero["node"].move_to(hero["node"].global_position + cf * 8.0)
	for ci in 4:
		await get_tree().create_timer(0.25).timeout
		cam.focus = hero["node"].global_position + Vector3(0, 0.45, 0)
		await _snap("res://crawl_move_%d.png" % ci)
	hero["node"].stop()
	await get_tree().create_timer(0.4).timeout
	var hp0: Vector3 = hero["node"].global_position
	var hf: Vector3 = hero["node"].facing_dir()
	cam.focus = hp0 + Vector3(0, 0.5, 0)
	cam.dist = 4.0
	cam.pitch_deg = 6.0
	cam.yaw = atan2(hf.z, hf.x)          # 正側面
	await get_tree().create_timer(0.5).timeout
	await _snap("res://e2e_hero_prone_side.png")
	cam.yaw = atan2(hf.x, hf.z) + PI     # 正前方
	await get_tree().create_timer(0.4).timeout
	await _snap("res://e2e_hero_prone_front.png")
	# 英雄模型的骨架名單：趴姿/IK 都用 hr_ 骨名（Hips/UpperLeg.L/Shoulder.R…），
	# 英雄若是別套骨架（Mixamo 41 骨）就會整段安靜失效＝畫面上人被扭成一根管子。
	var hsk: Array = hero["node"].find_children("*", "Skeleton3D", true, false)
	if hsk.is_empty():
		print("[bonechk] 英雄沒有骨架！")
	else:
		var sk2: Skeleton3D = hsk[0]
		var miss: Array = []
		for bn in ["Hips", "Abdomen", "Torso", "Chest", "Neck", "Head",
				"Shoulder.R", "UpperArm.R", "LowerArm.R", "Hand.R", "Wrist.R",
				"UpperLeg.L", "LowerLeg.L", "Foot.L"]:
			if sk2.find_bone(bn) < 0:
				miss.append(bn)
		print("[bonechk] cls=%s 骨數=%d 找不到的骨=%s" % [hero["cls"], sk2.get_bone_count(), miss])
		var nm: Array = []
		for i in mini(sk2.get_bone_count(), 20):
			nm.append(sk2.get_bone_name(i))
		print("[bonechk] 前 20 根骨名=", nm)
		print("[bonechk] want_prone=%s _prone=%.2f" % [hero["node"].want_prone,
				hero["node"]._prone])
	print("[e2e] DONE")
	_quit_test(0)

# 送出「真正的」滑鼠事件走完整派送鏈（UI → _unhandled_input），才驗得到「點擊被 UI 吃掉」這類病
func _send_click(pos: Vector2) -> void:
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = pos
		get_viewport().push_input(ev)

# 合成按鍵：第三人稱是用 WASD 走，測試也必須走同一條路
# （Input.parse_input_event 會更新 Input.is_key_pressed 的內部狀態，push_input 不會）
# 按下／放開鍵（不含等待）。走查台要「按著走、邊走邊檢查」，
# 不能用 _hold_key（那支會 await 整段時間，中途沒辦法取樣）。
func _press_key(code: Key, down_state: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = down_state
	Input.parse_input_event(ev)

func _hold_key(code: Key, secs: float) -> void:
	var down := InputEventKey.new()
	down.keycode = code
	down.physical_keycode = code
	down.pressed = true
	Input.parse_input_event(down)
	await get_tree().create_timer(secs).timeout
	var up := InputEventKey.new()
	up.keycode = code
	up.physical_keycode = code
	up.pressed = false
	Input.parse_input_event(up)
	await get_tree().process_frame

# 按住鍵並在期間分段取樣位置（不放開鍵，否則每段之間的停頓會蓋掉要量的東西）。
# 用來驗「移動是不是脈動的」——等速與脈動在靜態圖上分不出來，只能量。
# 匍匐專用：按住鍵並**逐幀**取樣腿與手的幾何。
# ⚠ 為什麼不能沿用「走一段停一下量一次」：匍匐是週期動作，3 個離散取樣點
#   落在週期的哪個相位純看運氣——膝蓋收到最前面只佔一個週期的 15%，
#   量到的極值會隨機通過或失敗。週期動作一定要取**整段的極值**。
func _hold_key_crawlscan(code: Key, secs: float, u: Node3D) -> Dictionary:
	var down := InputEventKey.new()
	down.keycode = code
	down.physical_keycode = code
	down.pressed = true
	Input.parse_input_event(down)
	var kf_min := 9.9
	var kf_max := -9.9
	var sp_min := 9.9
	var sp_max := -9.9
	var hf_min := 9.9
	var hf_max := -9.9
	var ka_min := 999.0
	var ka_max := -999.0
	var t := 0.0
	while t < secs:
		await get_tree().process_frame
		t += get_process_delta_time()
		var rg = u._rig
		var kl: Vector3 = rg.bone_pos("LowerLeg.L")
		var kr: Vector3 = rg.bone_pos("LowerLeg.R")
		var hipp: Vector3 = rg.bone_pos("UpperLeg.R")
		var fwdv: Vector3 = u.facing_dir()
		var sp: float = kl.distance_to(kr)
		sp_min = minf(sp_min, sp)
		sp_max = maxf(sp_max, sp)
		var kf: float = (kr - hipp).dot(fwdv)
		kf_min = minf(kf_min, kf)
		kf_max = maxf(kf_max, kf)
		var hl: Vector3 = rg.bone_pos(u._hand_l)
		var hf: float = (hl - u.global_position).dot(fwdv)
		hf_min = minf(hf_min, hf)
		hf_max = maxf(hf_max, hf)
		var thigh: Vector3 = kr - hipp
		var shin: Vector3 = rg.bone_pos("Foot.R") - kr
		if thigh.length() > 0.001 and shin.length() > 0.001:
			var ka: float = rad_to_deg(thigh.angle_to(shin))
			ka_min = minf(ka_min, ka)
			ka_max = maxf(ka_max, ka)
	var up := InputEventKey.new()
	up.keycode = code
	up.physical_keycode = code
	up.pressed = false
	Input.parse_input_event(up)
	await get_tree().process_frame
	return {"kf": [kf_min, kf_max], "sp": [sp_min, sp_max],
			"hf": [hf_min, hf_max], "ka": [ka_min, ka_max]}

func _hold_key_sampled(code: Key, secs: float, n: int, node: Node3D) -> Array:
	var down := InputEventKey.new()
	down.keycode = code
	down.physical_keycode = code
	down.pressed = true
	Input.parse_input_event(down)
	var out: Array = []
	var prev: Vector3 = node.global_position
	for i in n:
		await get_tree().create_timer(secs / float(n)).timeout
		var now: Vector3 = node.global_position
		out.append(Vector2(now.x - prev.x, now.z - prev.z).length())
		prev = now
	var up := InputEventKey.new()
	up.keycode = code
	up.physical_keycode = code
	up.pressed = false
	Input.parse_input_event(up)
	await get_tree().process_frame
	return out

# 驗收台截圖一律收進 res://qa/（使用者 2026-07-26：檔案要歸類，別散在專案根目錄）。
# 呼叫端照舊寫 "res://xxx.png"，這裡統一改寫路徑，不必動幾十處呼叫。
const QA_DIR := "res://qa/"
func _qa_path(p: String) -> String:
	if not p.begins_with("res://") or p.trim_prefix("res://").contains("/"):
		return p
	DirAccess.make_dir_recursive_absolute(QA_DIR)
	return QA_DIR + p.trim_prefix("res://")

func _snap(p: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var out := _qa_path(p)
	img.save_png(out)
	print("[selftest] saved ", out)

func _selftest() -> void:
	await get_tree().create_timer(0.5).timeout
	await _snap("res://st_menu.png")
	_open_brief(1)
	await get_tree().create_timer(0.6).timeout
	await _snap("res://st_brief.png")     # 名冊立繪
	var ch: Dictionary = GameData.story[0]
	_open_dialogue(ch)
	await get_tree().create_timer(0.7).timeout
	await _snap("res://st_dialogue1.png")  # 大立繪對話（第1句）
	# 前進兩句（切到右側立繪）
	for i in 3:
		ui._typing = false
		ui._dlg_i += 1
		if ui._dlg_i < ui._dlg_script.size():
			ui._dlg_step()
		await get_tree().create_timer(0.5).timeout
	await _snap("res://st_dialogue2.png")  # 雙立繪
	# 直接進部署
	ui._dlg_script = []
	_open_deploy(ch)
	await get_tree().create_timer(0.4).timeout
	var z := _my_zone()
	_on_deploy_pick("sniper", true)
	_try_place(z.get("x", 100) + 60, z.get("y", 250) + 60)
	_on_deploy_pick("rifleman", true)
	_try_place(z.get("x", 100) + 120, z.get("y", 250) + 60)
	_on_deploy_pick("engineer", true)
	_try_place(z.get("x", 100) + 180, z.get("y", 250) + 100)
	await get_tree().create_timer(0.5).timeout
	await _snap("res://st_deploy.png")
	_start_battle()
	await get_tree().create_timer(0.8).timeout
	# 選一個兵看角色卡
	if _deployed.size() > 0:
		selected = _deployed[0]
		cam.set_follow(selected["node"])
		var c: Dictionary = GameData.characters.get(selected["cls"], {})
		ui.show_charcard(selected["cls"], "★" + selected["char_name"], c.get("trait", {}).get("desc", ""), 100, 100)
	await get_tree().create_timer(1.0).timeout
	await _snap("res://st_battle.png")
	# 動態驗證：真實遊戲路徑下的「移動朝向」（治靜態截圖漏掉動態 bug）
	# 驗「模型正面向量 vs 實際移動方向」的夾角（不比對 rotation 數值——那會被模型正面軸慣例騙過去）
	for t in [[200.0, 0.0], [-200.0, 0.0], [0.0, 200.0], [0.0, -200.0]]:
		var uu = _deployed[0]
		var from: Vector3 = uu["node"].global_position
		var dest := _to3d(uu["wx"] + t[0], uu["wy"] + t[1])
		uu["node"].move_to(dest)
		await get_tree().create_timer(1.0).timeout
		var want_dir: Vector3 = dest - from
		want_dir.y = 0.0
		want_dir = want_dir.normalized()
		var face: Vector3 = uu["node"].facing_dir()
		var deg: float = rad_to_deg(acos(clamp(face.dot(want_dir), -1.0, 1.0)))
		print("[facechk] move=(%.0f,%.0f) 正面與移動夾角=%.1f度 %s" % [t[0], t[1], deg, "OK" if deg < 15.0 else "FAIL"])
	# ★真實操作路徑驗證：模擬「滑鼠點兵選取 → 點地面移動」，確認人物真的會動
	# （治「只測 move_to() 直呼、沒測點擊路徑」的驗證盲區）
	await get_tree().create_timer(0.5).timeout
	selected = null
	var pu = _deployed[0]
	var sp_unit: Vector2 = cam.unproject_position(pu["node"].global_position + Vector3(0, 1.0, 0))
	_send_click(sp_unit)
	await get_tree().create_timer(0.25).timeout
	print("[movechk] 合成點擊選取 selected=", "OK" if selected != null else "FAIL(點擊被吃掉/選不到兵)")
	print("[movechk] 點兵後進入第三人稱 %s" % ("OK" if cam.is_tps() else "FAIL"))
	var p_before: Vector3 = pu["node"].global_position
	# ⚠ 要驗的是「按 W 人會走」，不是「這個方向剛好沒東西」：戰場變成實體之後
	#   （沙包、柵欄、樹都擋人），朝向亂給就有機會一開始就頂著沙包，位移 0.3m
	#   被誤判成「人沒動」。先挑一個 3m 內確定走得通的方向再走。
	for deg_try in [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0]:
		var dv := Vector3(sin(deg_to_rad(deg_try)), 0.0, cos(deg_to_rad(deg_try)))
		if _path_clear(p_before, p_before + dv * 3.0, BODY_R):
			cam.tps_yaw = deg_try
			break
	await get_tree().create_timer(0.3).timeout
	await _hold_key(KEY_W, 1.2)
	var moved: float = p_before.distance_to(pu["node"].global_position)
	# FAIL 時要看得出「為什麼沒動」：姿勢（趴著只有 0.8m/s）／AP／有沒有被擋住
	print("[movechk] 第三人稱前進位移=%.2fm（_prone=%.2f _crouch=%.2f AP=%.0f yaw=%.0f）%s"
			% [moved, pu["node"]._prone, pu["node"]._crouch, float(pu.get("ap", 0.0)),
			cam.tps_yaw, "OK" if moved > 0.5 else "FAIL(人沒動)"])
	# ---- 行動模式 AP/CP（GDD/01 §1-2）----
	# 上面那次點擊本身就是「下令」，所以這裡先驗它扣了 CP、也給了 AP
	var cp0: int = cp
	print("[apchk] 下令扣 CP：本回合上限=%d 現在=%d %s" % [_turn_cp(), cp,
			"OK" if cp == _turn_cp() - 1 else "FAIL"])
	print("[apchk] 進入行動模式 acting=%s AP=%.0f/%.0f %s" % [
			"有" if acting != null else "無", float(acting["ap"]) if acting else -1.0,
			float(acting["ap_max"]) if acting else -1.0,
			"OK" if acting != null and acting["ap"] > 0.0 else "FAIL"])
	cam.dist = 14.0
	cam.pitch_deg = 40.0
	await get_tree().create_timer(0.5).timeout
	await _snap("res://ap_mode.png")     # AP 條與行動範圍圈要看得到
	# 走到 AP 歸零：一次點很遠的地方，應只走到 AP 允許的最遠處
	var ap_before: float = acting["ap"]
	var mid0: Vector3 = _to3d(map_data.get("w", 960) * 0.5, map_data.get("h", 600) * 0.5)
	var reach_m: float = _ap_reach_dir(acting, mid0 - acting["node"].global_position)
	# ⚠ 先把第三人稱視角轉向地圖中心再往前走。
	#   單位常常就站在地圖邊緣，朝外走會被 _clamp_to_map 夾住原地踏步，
	#   看起來像「AP 沒扣、人不動」，其實是撞牆（2026-07-26 花了三輪才查出來）。
	var mid: Vector3 = _to3d(map_data.get("w", 960) * 0.5, map_data.get("h", 600) * 0.5)
	var to_mid: Vector3 = mid - pu["node"].global_position
	cam.tps_yaw = rad_to_deg(atan2(to_mid.x, to_mid.z))
	await get_tree().create_timer(0.4).timeout
	var q_before: Vector3 = pu["node"].global_position
	# 按住前進直到 AP 見底。時間要照「最慢的情況」抓：站在掩體旁會自動蹲行，
	# 速度只有 1.35m/s 而不是 3m/s，用 3m/s 抓時間會提早放手（實測 9.6/12.4m）。
	await _hold_key(KEY_W, reach_m / 1.2 + 2.0)
	var run_m: float = q_before.distance_to(pu["node"].global_position)
	print("[apchk] AP 上限內移動：可走 %.1fm 實走 %.1fm 剩餘 AP=%.0f %s" % [
			reach_m, run_m, float(acting["ap"]),
			"OK" if absf(run_m - reach_m) < 1.2 and acting["ap"] < 1.0 else "FAIL"])
	# AP 歸零後仍可原地開火一次，第二次要被擋
	var foe = null
	for x in units:
		if x["alive"] and x["side"] != player_side:
			foe = x
			break
	if foe != null:
		_fire(acting, foe)
		await get_tree().create_timer(0.6).timeout
		print("[apchk] 每次行動只能開火一次 fired=%s %s" % [acting["fired"],
				"OK" if bool(acting["fired"]) else "FAIL"])
	# 同一單位再次下令：AP 上限應降為 0.7 倍
	var full_ap: float = float(GameData.class_base.get(pu["cls"], {}).get("ap", 150))
	_end_action()
	_begin_action(pu)
	print("[apchk] 重複下令 AP 上限 %.0f→%.0f（應為 0.7 倍） %s" % [full_ap, float(pu["ap_max"]),
			"OK" if absf(float(pu["ap_max"]) - full_ap * 0.7) < 1.0 else "FAIL"])
	_end_action()
	print("[apchk] 結束行動 acting=%s %s" % ["無" if acting == null else "有", "OK" if acting == null else "FAIL"])
	cp = cp0
	# ---- Phase2 掩體系統驗證 ----
	var sb := {}
	for c in _covers:
		if c["type"] == "sandbag":
			sb = c
			break
	if sb.is_empty():
		print("[coverchk] FAIL 場上沒有沙包掩體")
	else:
		var tu = _deployed[0]
		# A) 站在沙包旁、射手在沙包那一側 → 應有遮蔽
		tu["wx"] = sb["wx"] + 20.0
		tu["wy"] = sb["wy"]
		var fx: float = sb["wx"] - 300.0     # 射手在沙包外側
		# 隔離：只留這一個沙包，才驗得到「方向性」本身（否則附近建築會混進來）
		var all_covers := _covers
		_covers = [sb]
		var cov_front: float = cover_at(tu["wx"], tu["wy"], fx, sb["wy"])
		# B) 射手繞到背後 → 遮蔽應消失（方向性掩體）
		var cov_back: float = cover_at(tu["wx"], tu["wy"], sb["wx"] + 300.0, sb["wy"])
		# C) 遠離掩體 → 無遮蔽
		var cov_open: float = cover_at(sb["wx"] + 600.0, sb["wy"] + 600.0, fx, sb["wy"])
		_covers = all_covers
		print("[coverchk] 沙包正面遮蔽=%.2f %s" % [cov_front, "OK" if cov_front > 0.4 else "FAIL"])
		print("[coverchk] 繞背後遮蔽=%.2f %s" % [cov_back, "OK" if cov_back < 0.01 else "FAIL(方向性失效)"])
		print("[coverchk] 空曠地遮蔽=%.2f %s" % [cov_open, "OK" if cov_open < 0.01 else "FAIL"])
		# D) 蹲姿：站到掩體旁應自動蹲下
		tu["node"].stop()                         # 先停下前面 facechk 的移動，否則不會蹲
		tu["node"].global_position = _to3d(tu["wx"], tu["wy"])
		_update_cover_state(tu)
		await get_tree().create_timer(0.9).timeout
		var crouched: bool = tu["node"]._crouch > 0.8
		print("[coverchk] 掩體旁自動蹲姿 crouch=%.2f %s" % [tu["node"]._crouch, "OK" if crouched else "FAIL"])
		cam.set_follow(null)
		cam.focus = tu["node"].global_position + Vector3(0, 0.8, 0)
		cam.dist = 6.5
		await get_tree().create_timer(0.6).timeout
		await _snap("res://cover_crouch.png")
		# E) 移動中應站起
		tu["node"].move_to(_to3d(tu["wx"] + 400.0, tu["wy"]))
		await get_tree().create_timer(0.5).timeout
		print("[coverchk] 移動中站起 crouch=%.2f %s" % [tu["node"]._crouch, "OK" if tu["node"]._crouch < 0.5 else "FAIL"])
		# F) 近拍：把兵移到空地、鏡頭壓低到人身高，站姿/蹲姿各拍一張。
		#    戰術鏡頭離很遠，姿勢好壞在戰場俯瞰圖上根本看不出來——不近拍就等於沒驗。
		var u3: Unit = tu["node"]
		u3.stop()
		u3.global_position = _to3d(tu["wx"] + 300.0, tu["wy"] + 300.0)
		u3.want_cover = false
		u3.want_prone = false
		cam.focus = u3.global_position + Vector3(0, 1.0, 0)
		cam.dist = 3.2
		cam.pitch_deg = 12.0
		await get_tree().create_timer(0.9).timeout
		await _snap("res://close_stand.png")
		u3.want_cover = true
		await get_tree().create_timer(1.0).timeout
		await _snap("res://close_crouch.png")
		# G) 臥射：狙擊手在開闊地（無掩體）應自動趴下
		u3.want_cover = false
		tu["wx"] += 900.0
		tu["wy"] += 900.0
		u3.global_position = _to3d(tu["wx"], tu["wy"])
		cam.focus = u3.global_position + Vector3(0, 0.5, 0)
		_update_cover_state(tu)
		print("[pronechk] 兵種=%s 掩體=%s want_prone=%s %s" % [
			tu.get("cls", "?"), tu.get("cover", ""), u3.want_prone, "OK" if u3.want_prone else "FAIL"])
		await get_tree().create_timer(1.4).timeout
		print("[pronechk] 趴姿混合值=%.2f %s" % [u3._prone, "OK" if u3._prone > 0.9 else "FAIL"])
		await _snap("res://close_prone.png")
		u3.want_prone = false
		await get_tree().create_timer(1.2).timeout
		print("[pronechk] 解除後起身=%.2f %s" % [u3._prone, "OK" if u3._prone < 0.1 else "FAIL"])
		# H) 警戒射擊（GDD/01 §3）：敵人在我方步槍兵面前移動 → 應被自動迎擊
		var alert_u = null   # 具警戒能力的我方單位（步槍兵）
		var eu = null        # 敵方單位
		for x in units:
			if x["alive"] and x["side"] == player_side and x["cls"] == "rifleman" and alert_u == null:
				alert_u = x
			if x["alive"] and x["side"] != player_side and eu == null:
				eu = x
		if alert_u == null or eu == null:
			print("[alertchk] SKIP 場上缺步槍兵或敵軍")
		else:
			var rng: float = float(alert_u["weapon"].get("range", 200)) * ALERT_RANGE_K
			eu["wx"] = alert_u["wx"] + rng * 0.5
			eu["wy"] = alert_u["wy"]
			eu["node"].global_position = _to3d(eu["wx"], eu["wy"])
			eu["node"].visible = true
			var hp0: float = eu["hp"]
			_alert_shots = 0
			eu["node"].move_to(_to3d(eu["wx"], eu["wy"] + 400.0))   # 橫越我方正面
			cam.focus = alert_u["node"].global_position + Vector3(0, 1.0, 0)
			cam.dist = 9.0
			cam.pitch_deg = 28.0
			await get_tree().create_timer(1.6).timeout
			await _snap("res://close_alert.png")
			print("[alertchk] 敵人移動遭迎擊 次數=%d %s" % [_alert_shots, "OK" if _alert_shots > 0 else "FAIL"])
			print("[alertchk] 迎擊有扣血 %.0f→%.0f %s" % [hp0, eu["hp"],
					"OK" if eu["hp"] < hp0 else "（全部落空，機率問題不算 FAIL）"])
			# 狙擊手沒有警戒能力：連計時器都不該被建立（GDD §3 明列無警戒兵種）
			var sn = _deployed[0]
			print("[alertchk] 狙擊手(%s,alert=%s)不參與警戒 %s" % [sn["cls"], _can_alert(sn["cls"]),
					"OK" if (not sn.has("_alert_t") and not _can_alert(sn["cls"])) else "FAIL(被算進警戒了)"])
			eu["node"].stop()
			# 建築擋視線（GDD/01 §3 要求視線無阻擋、§5 建築完全阻擋）：隔離只留一棟才驗得準
			# ⚠ 先前隔離的是 _covers，但 _los_clear 讀的是 _buildings（牆線段），
			#   等於完全沒隔離：別棟房子把「從旁邊繞過去」那條線也擋掉，兩項都被判 FAIL。
			# ⚠ 門開在牆的正中央，穿過建築正中心的線剛好從門洞穿過去（那是對的行為）。
			#   要驗「牆擋視線」就必須避開門洞，所以往旁邊偏半個房子的 55%。
			if _buildings.is_empty():
				print("[alertchk] SKIP 場上沒有建築")
			else:
				var keep_bl := _buildings
				var one_bd = _buildings[0]
				_buildings = [one_bd]
				var bp: Vector2 = one_bd.rect.get_center()
				var bhw: float = one_bd.rect.size.x * 0.5
				var bhh: float = one_bd.rect.size.y * 0.5
				var off_y: float = bhh * 0.55
				var thru: bool = not _los_clear(bp + Vector2(-bhw - 60.0, off_y),
						bp + Vector2(bhw + 60.0, off_y))
				var side_ok: bool = _los_clear(bp + Vector2(-bhw - 100.0, bhh + 80.0),
						bp + Vector2(bhw + 100.0, bhh + 80.0))
				_buildings = keep_bl
				print("[alertchk] 建築擋視線 穿過牆被擋=%s 從旁邊繞過看得到=%s %s"
						% [thru, side_ok, "OK" if (thru and side_ok) else "FAIL"])
		# I-0) AI 決策狀態機（GDD/01 §6）：直接驗 _ai_plan 的判斷，純函式不受時序干擾
		var ai_u = null
		for x in units:
			if x["alive"] and x["side"] != player_side:
				ai_u = x
				break
		if ai_u != null:
			var keep_cls: String = ai_u["cls"]
			var keep_hp: float = ai_u["hp"]
			var cases := [
				["rifleman", 1.0, "推進到射程 0.6 倍"],
				["rifleman", 0.2, "殘血撤退"],
				["sniper", 1.0, "狙擊手找血最少的"],
				["mg", 1.0, "機槍兵佔掩體警戒"],
				["at", 1.0, "火箭兵"],
			]
			for c in cases:
				ai_u["cls"] = c[0]
				ai_u["hp"] = float(ai_u["maxhp"]) * float(c[1])
				var pl := _ai_plan(ai_u)
				print("[aiplanchk] %s hp=%d%% → %s %s" % [c[0], int(float(c[1]) * 100), pl["why"],
						"OK" if str(pl["why"]).begins_with(str(c[2])) else "FAIL(應為 %s)" % c[2]])
			ai_u["cls"] = keep_cls
			ai_u["hp"] = keep_hp
			# 狙擊手要挑血最少的：把某個我方單位打成殘血，看它會不會被指名
			var weak = null
			for x in units:
				if x["alive"] and x["side"] == player_side:
					weak = x
			if weak != null:
				var keep_w: float = weak["hp"]
				weak["hp"] = 5.0
				ai_u["cls"] = "sniper"
				var pl2 := _ai_plan(ai_u)
				print("[aiplanchk] 狙擊手指名血最少者 %s %s" % [
						"是" if pl2["target"] == weak else "否",
						"OK" if pl2["target"] == weak else "FAIL"])
				weak["hp"] = keep_w
				ai_u["cls"] = keep_cls
		# I-1) 坦克（GDD/01 §4 剋制兩條、§1 CP 成本、§3 車載機槍警戒）
		var rifleman_w := {"weapon": GameData.weapon_of(nation[player_side], "rifleman"), "cls": "rifleman"}
		var at_w := {"weapon": GameData.weapon_of(nation[player_side], "at"), "cls": "at"}
		var tank_t := {"weapon": {}, "cls": "tank"}
		var inf_t := {"weapon": {}, "cls": "rifleman"}
		var d_rifle_tank: int = GameData.damage(_wrap(rifleman_w), _wrap(tank_t))
		var d_at_tank: int = GameData.damage(_wrap(at_w), _wrap(tank_t))
		var d_at_inf: int = GameData.damage(_wrap(at_w), _wrap(inf_t))
		var d_rifle_inf: int = GameData.damage(_wrap(rifleman_w), _wrap(inf_t))
		print("[tankchk] 步槍打坦克=%d（應為 1 刮漆） %s" % [d_rifle_tank, "OK" if d_rifle_tank == 1 else "FAIL"])
		print("[tankchk] 火箭打坦克=%d 步槍打步兵=%d %s" % [d_at_tank, d_rifle_inf,
				"OK" if d_at_tank > 50 else "FAIL(火箭開不了罐頭)"])
		print("[tankchk] 火箭打步兵=%d（有 ×0.6 濺傷減半） %s" % [d_at_inf,
				"OK" if d_at_inf < int(float(at_w["weapon"].get("atk", 180)) * 0.75) else "FAIL"])
		var t_dummy := {"cls": "tank", "weapon": GameData.weapon_of(nation[player_side], "tank")}
		print("[tankchk] 坦克下令成本=%d CP %s" % [_order_cost(t_dummy), "OK" if _order_cost(t_dummy) == 2 else "FAIL"])
		var aw := _alert_weapon(t_dummy)
		print("[tankchk] 坦克警戒用 %s(atk %d) 而非主砲(atk %d) %s" % [aw.get("type", "?"), int(aw.get("atk", 0)),
				int(t_dummy["weapon"].get("atk", 0)),
				"OK" if int(aw.get("atk", 999)) < int(t_dummy["weapon"].get("atk", 0)) else "FAIL"])
		# 真的生一台上場：載具走的是完全不同的分支，不實際生成等於沒驗
		var tk = _spawn_unit("tank", player_side, clampf(tu["wx"] + 260.0, 60.0, float(map_data.get("w", 960)) - 60.0),
				clampf(tu["wy"] + 120.0, 60.0, float(map_data.get("h", 600)) - 60.0), false)
		_refresh_visibility()
		var tk_from: Vector3 = tk["node"].global_position
		cam.set_follow(null)
		cam.focus = tk_from + Vector3(0, 1.2, 0)
		cam.dist = 12.0
		cam.pitch_deg = 24.0
		tk["node"].move_to(_clamp_to_map(tk_from + Vector3(0, 0, 9.0)))
		await get_tree().create_timer(2.4).timeout
		await _snap("res://tank_ingame.png")
		var tk_moved: float = tk_from.distance_to(tk["node"].global_position)
		print("[tankchk] 坦克在遊戲內生成並移動 %.1fm %s" % [tk_moved, "OK" if tk_moved > 1.0 else "FAIL"])
		# I-2) 部位命中（GDD/01 §4）＋射擊預測面板（GDD/13）
		var sh2 := {"weapon": GameData.weapon_of(nation[player_side], "sniper"), "cls": "sniper"}
		var inf2 := {"weapon": {}, "cls": "rifleman"}
		var hb: float = GameData.hit_chance(_wrap(sh2), _wrap(inf2), 100.0, "body")
		var hh: float = GameData.hit_chance(_wrap(sh2), _wrap(inf2), 100.0, "head")
		var db: int = GameData.damage(_wrap(sh2), _wrap(inf2), "body")
		var dh: int = GameData.damage(_wrap(sh2), _wrap(inf2), "head")
		print("[partchk] 頭部命中 %.0f%%→%.0f%%（應為 0.55 倍） %s" % [hb * 100, hh * 100,
				"OK" if absf(hh - hb * 0.55) < 0.02 else "FAIL"])
		# 允許 ±1：傷害是最後才四捨五入，2 倍後的尾數本來就會差一點
		print("[partchk] 頭部傷害 %d→%d（應為 2 倍） %s" % [db, dh, "OK" if absi(dh - db * 2) <= 1 else "FAIL"])
		var atw := {"weapon": GameData.weapon_of(nation[player_side], "at"), "cls": "at"}
		var tk2 := {"weapon": {}, "cls": "tank"}
		var dbody: int = GameData.damage(_wrap(atw), _wrap(tk2), "body")
		var drad: int = GameData.damage(_wrap(atw), _wrap(tk2), "radiator")
		print("[partchk] 散熱器傷害 %d→%d（應為 3 倍） %s" % [dbody, drad, "OK" if drad == dbody * 3 else "FAIL"])
		# 幾何：散熱器只有繞到坦克背後才可選
		tk["node"].rotation.y = 0.0                      # 坦克面向 +Z
		var front_sh := {"node": tk["node"], "cls": "at", "wx": 0.0, "wy": 0.0}
		var probe := Node3D.new()
		add_child(probe)
		var fake := {"node": probe, "cls": "at"}
		probe.global_position = tk["node"].global_position + Vector3(0, 0, 6)   # 車頭方向
		var parts_front: int = _aim_parts(fake, tk).size()
		probe.global_position = tk["node"].global_position - Vector3(0, 0, 6)   # 車尾方向
		var parts_back: int = _aim_parts(fake, tk).size()
		probe.queue_free()
		print("[partchk] 正面可選部位=%d 背面=%d %s" % [parts_front, parts_back,
				"OK" if parts_front == 1 and parts_back == 2 else "FAIL(散熱器判定不對)"])
		# 真實操作路徑：行動模式中點敵人 → 應跳出射擊面板 → 點部位才開火
		var foe2 = null
		for x in units:
			if x["alive"] and x["side"] != player_side:
				foe2 = x
				break
		if foe2 != null:
			foe2["node"].global_position = tu["node"].global_position + Vector3(3, 0, 0)
			foe2["wx"] = _live_px(foe2).x
			foe2["wy"] = _live_px(foe2).y
			foe2["node"].visible = true
			_end_action()
			cp = 6
			_begin_action(tu)
			cam.set_follow(null)
			cam.focus = tu["node"].global_position + Vector3(0, 1.0, 0)
			cam.dist = 8.0
			await get_tree().create_timer(0.4).timeout
			_send_click(cam.unproject_position(foe2["node"].global_position + Vector3(0, 1.0, 0)))
			await get_tree().create_timer(0.35).timeout
			print("[partchk] 點敵人跳出射擊面板 %s" % ("OK" if ui.fire_panel_open() else "FAIL"))
			await _snap("res://fire_panel.png")
			var pb := _find_btn("頭部")
			if pb != null:
				_send_click(pb.get_global_rect().get_center())
				await get_tree().create_timer(0.6).timeout
				print("[partchk] 點部位後真的開火 fired=%s 面板已關=%s %s" % [
						bool(tu.get("fired", false)), not ui.fire_panel_open(),
						"OK" if bool(tu.get("fired", false)) and not ui.fire_panel_open() else "FAIL"])
			else:
				print("[partchk] FAIL 面板上找不到頭部選項")
			_end_action()
		# I-3) 地形（GDD/14 §1）：壕溝深度、丘陵高度、單位是否真的貼著地形
		if terrain != null:
			var trs = map_data.get("trenches", [])
			if trs.is_empty():
				print("[terrainchk] SKIP 這張圖沒有壕溝資料")
			else:
				var tp = trs[0]["pts"][0]
				var tx: float = float(tp[0])
				var ty: float = float(tp[1])
				var h_in: float = terrain.height_at(tx, ty)
				var h_out: float = terrain.height_at(tx + float(trs[0].get("w", 44)) * 2.4, ty)
				print("[terrainchk] 壕溝內 %.2fm vs 溝外 %.2fm（應低於 1m 以上） %s" % [h_in, h_out,
						"OK" if h_out - h_in > 1.0 else "FAIL"])
				print("[terrainchk] 壕溝登記為掩體 %s" % ("OK" if terrain.in_trench(tx, ty) else "FAIL"))
				# 把兵放進壕溝：貼地邏輯應該把他降下去
				var su = _deployed[0]
				su["node"].stop()
				su["node"].global_position = _to3d(tx, ty)
				su["wx"] = tx
				su["wy"] = ty
				_update_cover_state(su)
				await get_tree().create_timer(0.8).timeout
				var uy: float = su["node"].global_position.y
				print("[terrainchk] 單位在溝內高度 %.2fm（應貼著溝底 %.2fm） %s" % [uy, h_in,
						"OK" if absf(uy - h_in) < 0.25 else "FAIL(沒貼地)"])
				print("[terrainchk] 溝內自動取得掩體 cover=%s %s" % [su.get("cover", ""),
						"OK" if su.get("cover", "") != "" else "FAIL"])
				cam.set_follow(null)
				cam.focus = su["node"].global_position
				cam.dist = 14.0
				cam.pitch_deg = 18.0
				await get_tree().create_timer(0.5).timeout
				await _snap("res://terrain_trench.png")
			var hills = map_data.get("hills", [])
			if hills.is_empty():
				print("[terrainchk] 這張圖(%s)沒有 hills 資料，只有基礎起伏" % map_data.get("id", "?"))
			else:
				var hill_top: float = terrain.height_at(float(hills[0].get("x", 0)), float(hills[0].get("y", 0)))
				print("[terrainchk] 丘陵頂端高度 %.2fm %s" % [hill_top, "OK" if hill_top > 1.5 else "FAIL(太平)"])
			# 工事近照（GDD/14 §7）：沙包與壕溝護壁的質感只有近拍才看得出來，
			# 遠景圖上它們只是幾個色塊。
			# 挑離建築最遠的那堆沙包來拍：第一堆剛好在建築陰影裡，
			# 拍出來整堆是深藍黑，看不出袋子的形狀與顏色。
			var sbs = map_data.get("sandbags", [])
			if not sbs.is_empty():
				var sb0 = sbs[0]
				var best_d := -1.0
				for cand_sb in sbs:
					var cpx := Vector2(float(cand_sb.get("x", 0)), float(cand_sb.get("y", 0)))
					var near := 99999.0
					for bdz in _buildings:
						near = minf(near, cpx.distance_to(bdz.rect.get_center()))
					if near > best_d:
						best_d = near
						sb0 = cand_sb
				var sbx: float = float(sb0.get("x", 0)) + float(sb0.get("w", 40)) * 0.5
				var sby: float = float(sb0.get("y", 0)) + float(sb0.get("h", 24)) * 0.5
				cam.set_follow(null)
				cam.focus = _to3d(sbx, sby) + Vector3(0, 0.6, 0)
				cam.dist = 6.0
				cam.pitch_deg = 18.0
				print("[fortdiag] 沙包中心 px=(%.0f,%.0f) w=%.0f h=%.0f" % [sbx, sby,
						float(sb0.get("w", 40)), float(sb0.get("h", 24))])
				await get_tree().create_timer(0.6).timeout
				await _snap("res://fort_sandbag.png")
			var trs2 = map_data.get("trenches", [])
			if not trs2.is_empty() and not trs2[0].get("pts", []).is_empty():
				var tp0 = trs2[0]["pts"][0]
				cam.focus = _to3d(float(tp0[0]), float(tp0[1])) + Vector3(0, 0.4, 0)
				cam.dist = 6.5
				cam.pitch_deg = 12.0
				await get_tree().create_timer(0.6).timeout
				await _snap("res://fort_trench.png")
			# 全景：地形起伏一定要用遠鏡頭看才判斷得出來
			cam.set_follow(null)
			cam.focus = _to3d(map_data.get("w", 960) * 0.5, map_data.get("h", 600) * 0.5)
			cam.dist = 78.0
			cam.pitch_deg = 34.0
			await get_tree().create_timer(0.6).timeout
			await _snap("res://terrain_overview.png")
		# I-4) 可進入的建築（GDD/14 §2、§5 [buildingchk]）
		if _buildings.is_empty():
			print("[buildingchk] SKIP 這張圖沒有建築")
		else:
			var bd = _buildings[0]
			print("[buildingchk] 牆段=%d 門=%d 窗=%d 樓層=%d %s" % [bd.walls.size(), bd.doors.size(),
					bd.windows.size(), bd.floors,
					"OK" if bd.walls.size() > 4 and bd.doors.size() >= 1 else "FAIL"])
			var bc: Vector2 = bd.rect.get_center()
			# 隔離：場上有好幾棟，不只留一棟就驗不到「從旁邊繞過去」（會被別棟擋到）
			var keep_b := _buildings
			_buildings = [bd]
			var thru: bool = not _los_clear(bc + Vector2(-bd.rect.size.x, 0), bc + Vector2(bd.rect.size.x, 0))
			var past: bool = _los_clear(bc + Vector2(-bd.rect.size.x, bd.rect.size.y * 1.6),
					bc + Vector2(bd.rect.size.x, bd.rect.size.y * 1.6))
			_buildings = keep_b
			print("[buildingchk] 牆擋視線 穿越=%s 從旁邊過=%s %s" % [thru, past,
					"OK" if (thru and past) else "FAIL"])
			# 牆會把人推開、門不會（門洞不是牆段）
			var wall_pt: Vector3 = _to3d(bc.x, bd.rect.position.y)          # 北牆正中
			var pushed: float = _resolve_walls(wall_pt).distance_to(wall_pt)
			var door_pt: Vector3 = _to3d(bd.doors[0].x, bd.doors[0].y)
			var door_push: float = _resolve_walls(door_pt).distance_to(door_pt)
			print("[buildingchk] 牆推開人 %.2fm、門口不推 %.2fm %s" % [pushed, door_push,
					"OK" if pushed > 0.1 and door_push < 0.1 else "FAIL"])
			# ★人要跟實體一樣：不可以把兵直接放進屋裡驗屋頂淡出（那等於繞過牆）。
			#   改成從屋外「用走的」進去：先撞牆證明進不去，再走門證明進得去。
			var iu = _deployed[0]
			iu["node"].stop()
			_end_action()
			cp = 6
			# 隔離：場上建築彼此很近，不只留一棟的話會撞到「隔壁棟」的牆，
			# 看起來像門進不去（實測兵停在門外 1.25m，其實是被鄰棟擋住）。
			var keep_b2 := _buildings
			_buildings = [bd]
			# 中景物件同理要隔離：這一段驗的是「門是不是唯一入口」，
			# 被路邊柵欄擋在門外會誤判成「門進不去」（2026-07-26 實測踩到）。
			var keep_blk0 := _blockers
			_blockers = []
			var door_px: Vector2 = bd.doors[0]
			# (a) 對著實心牆走：門在南牆 32% 處，往旁邊挪 4m 就是牆
			var wall_x: float = door_px.x + 4.0 / WORLD_SCALE
			iu["node"].global_position = _to3d(wall_x, door_px.y + 5.0 / WORLD_SCALE)
			iu["wx"] = wall_x
			iu["wy"] = door_px.y + 5.0 / WORLD_SCALE
			_begin_action(iu)
			cam.tps_yaw = 180.0            # 面向 -Z（往建築走）
			await get_tree().create_timer(0.5).timeout
			await _hold_key(KEY_W, 4.0)
			var in_after_wall: bool = bd.inside(iu["wx"], iu["wy"])
			print("[solidchk] 對著牆走 4 秒：進到室內=%s %s" % [in_after_wall,
					"OK(牆是實體)" if not in_after_wall else "FAIL(穿牆了)"])
			await _snap("res://solid_wall.png")
			# (b) 對著門走：應該真的走得進去
			iu["node"].stop()
			iu["node"].global_position = _to3d(door_px.x, door_px.y + 5.0 / WORLD_SCALE)
			iu["wx"] = door_px.x
			iu["wy"] = door_px.y + 5.0 / WORLD_SCALE
			# 撞牆那段已經把 AP 走光了；AP 歸零就不能再移動，會誤判成「門進不去」
			iu["ap"] = 150.0
			iu["ap_max"] = 150.0
			await get_tree().create_timer(0.4).timeout
			await _hold_key(KEY_W, 4.0)
			var in_after_door: bool = bd.inside(iu["wx"], iu["wy"])
			_buildings = keep_b2
			_blockers = keep_blk0
			print("[solidchk] 對著門走 4 秒：進到室內=%s %s" % [in_after_door,
					"OK(門是唯一入口)" if in_after_door else "FAIL(門進不去)"])
			await get_tree().create_timer(1.2).timeout
			# ★2026-07-27 規則修正：鏡頭**在屋裡**時屋頂要留著（不然室內變成沒有蓋子的箱子，
			#   使用者：「在裡面會變成感覺沒有牆壁一樣可以看到外面」）。
			#   屋頂淡出是給**俯瞰**用的——玩家在天上要看到屋裡有誰。所以分兩段驗。
			print("[buildingchk] 鏡頭在屋內時屋頂留著 alpha=%.2f %s" % [float(_roof_a.get(0, 1.0)),
					"OK" if float(_roof_a.get(0, 1.0)) > 0.65 else "FAIL(室內看得到天空)"])
			await _snap("res://bld_ingame.png")
			cam.clear_tps()
			await get_tree().create_timer(1.2).timeout
			print("[buildingchk] 回俯瞰後屋頂淡出 alpha=%.2f %s" % [float(_roof_a.get(0, 1.0)),
					"OK" if float(_roof_a.get(0, 1.0)) < 0.15 else "FAIL(屋頂還蓋著，屋內的人點不到)"])
			cam.set_follow(null)
			cam.focus = _to3d(bc.x, bc.y) + Vector3(0, 1.0, 0)
			cam.dist = 22.0
			cam.pitch_deg = 30.0
			await get_tree().create_timer(0.6).timeout
			await _snap("res://bld_ingame_out.png")
			_end_action()
		# I-4b) 中景物件與載具也是實體（GDD/14 §2；先前只有建築牆擋人）
		#      一樣「用走的」驗，不用瞬移——瞬移過去只證明座標能設，不證明擋得住。
		#      ⚠ 場上障礙全部保留（不像建築那段只留一棟）：清掉別的障礙會讓畫面上
		#      仍畫著柵欄、人卻站在柵欄裡，拍出來像穿模，而且證明不了真實情況。
		if _blockers.is_empty():
			print("[solidchk] SKIP 這張圖沒有中景障礙")
		else:
			var keep_bld2 := _buildings
			var seg = null
			for bk in _blockers:
				if bk["t"] == "seg" and (seg == null or float(bk["hl"]) > float(seg["hl"])):
					seg = bk
			var solu = _deployed[0]
			var mwp: float = map_data.get("w", 960)
			var mhp: float = map_data.get("h", 600)
			_buildings = []              # 只排除建築，中景障礙照舊全開
			var solu_save := _shield(solu)
			if seg == null:
				print("[solidchk] SKIP 這張圖沒有線段型障礙（護欄/柵欄）")
			else:
				solu["node"].stop()
				_end_action()
				cp = 6
				# ⚠ 障礙的角度是任意的（磚牆殘段隨機轉向），不可以寫死「從 +y 往 -y 走」——
				#   那樣會從旁邊繞過去而誤判成「穿過去了」。要沿牆的法線走，用投影判斷。
				var sn: Vector2 = (seg["b"] - seg["a"]).orthogonal().normalized()
				var smid: Vector2 = seg["m"]
				var sp0: Vector2 = smid + sn * (5.0 / WORLD_SCALE)
				solu["node"].global_position = _to3d(sp0.x, sp0.y)
				solu["wx"] = sp0.x
				solu["wy"] = sp0.y
				_begin_action(solu)
				# ★AP 一定要補在 _begin_action 之後：它會依下令次數重算 AP（×0.7^N），
				#   補在前面會被蓋掉，人走到一半 AP 用盡停下來，看起來就像「被護欄擋住」。
				#   實拍到畫面上寫著 AP 0/24 才抓到這個假通過（2026-07-26）。
				solu["ap"] = 300.0
				solu["ap_max"] = 300.0
				# 朝 -法線方向走（px 的 x/y 對應世界的 x/z）
				cam.tps_yaw = rad_to_deg(atan2(-sn.x, -sn.y))
				await get_tree().create_timer(0.5).timeout
				await _hold_key(KEY_W, 5.0)
				var snow := Vector2(solu["wx"], solu["wy"])
				var proj: float = (snow - smid).dot(sn) * WORLD_SCALE
				var crossed: bool = proj < 0.0
				var gap: float = proj
				var walked: float = sp0.distance_to(snow) * WORLD_SCALE
				var ap_left: float = float(solu["ap"])
				print("[solidchk] 對著障礙走 5 秒：走了 %.2fm、停在前方 %.2fm、越過=%s、剩餘AP=%.0f %s"
						% [walked, gap, crossed, ap_left,
						"OK(擋住了)" if (not crossed and walked > 1.5 and ap_left > 1.0) else "FAIL(穿過去了/沒走到/AP用盡)"])
				await _snap("res://solid_prop.png")
				_end_action()
			# 載具：坦克是 3m 級的鋼鐵，人不可能從中間穿過去。
			# 找一塊「周圍 12m 內沒有任何障礙」的空地，才驗得到是被坦克擋住而不是被柵欄。
			var spot := Vector2(mwp * 0.5, mhp * 0.5)
			# ⚠ 8m 淨空在教學圖（48×30m、六棟建築＋沿岸工事）根本找不到，
			#   於是 found_spot=false、坦克生在雜物堆裡，測出來的 5.52m 是被別的東西擋住。
			#   6m 足夠（走 5 秒約 4m，車體半徑 1.6m），而且找不到時要報 SKIP 不是 FAIL——
			#   前提不成立的測試不算失敗，報 FAIL 會蓋掉真正的問題。
			var clear_r: float = 6.0 / WORLD_SCALE
			var found_spot := false
			for gy in range(2, 19):
				for gx in range(2, 29):
					var c := Vector2(mwp * float(gx) / 30.0, mhp * float(gy) / 20.0)
					var ok := true
					for bk2 in _blockers:
						var cp2: Vector2 = _blk_closest(bk2, c)
						if c.distance_to(cp2) < clear_r:
							ok = false
							break
					if ok:
						for bd3 in keep_bld2:
							if bd3.rect.grow(clear_r).has_point(c):
								ok = false
								break
					if ok:
						spot = c
						found_spot = true
						break
				if found_spot:
					break
			solu["node"].stop()
			_end_action()
			var soltk = _spawn_unit("tank", player_side, spot.x, spot.y, false)
			var man_y: float = spot.y + 6.0 / WORLD_SCALE
			solu["node"].global_position = _to3d(spot.x, man_y)
			solu["wx"] = spot.x
			solu["wy"] = man_y
			await get_tree().create_timer(0.4).timeout
			_begin_action(solu)
			solu["ap"] = 300.0
			solu["ap_max"] = 300.0
			cam.tps_yaw = 180.0
			await get_tree().create_timer(0.4).timeout
			await _hold_key(KEY_W, 5.0)
			# ⚠ 2026-07-27 改：舊寫法量「離車心的 Y 距離 > 1.6m」，人站在車尾內部 1.6m 處
			#   （車體半長 3.0m）照樣通過——使用者實測就是從車尾走進車體中間。
			#   改成換算到車體座標系，看有沒有進到 3.00×1.75 的盒子裡。
			var tobb := _vehicle_obb(soltk)
			var tax: Vector2 = tobb["ax"]
			var tfin: Vector2 = _live_px(solu) - tobb["c"]
			var tla: float = absf(tfin.dot(tax)) * WORLD_SCALE
			var tlb: float = absf(tfin.dot(Vector2(-tax.y, tax.x))) * WORLD_SCALE
			var tgap: float = maxf(tla - VEHICLE_HL, tlb - VEHICLE_HW)   # 離車體表面多遠
			var tank_ok: bool = tgap > BODY_R - 0.1 and tgap < 1.5 and float(solu["ap"]) > 1.0
			print("[solidchk] 對著坦克走 5 秒：空地=%s 離車體表面 %.2fm(沿軸%.2f/沿寬%.2f)、剩餘AP=%.0f %s"
					% [found_spot, tgap, tla, tlb, float(solu["ap"]),
				("OK(載具是實體)" if tank_ok else "FAIL(穿過去了/沒走到/AP用盡)")
				if found_spot else "SKIP(這張圖找不到 6m 淨空的空地，前提不成立)"])
			# ⚠ 這張不能用第三人稱拍：鏡頭會直接埋進車體，整張圖是一片灰＝沒有佐證力
			#   （2026-07-26 實拍到）。切回俯瞰、框住人與坦克，才看得出人停在車體外。
			_end_action()
			cam.clear_tps()
			cam.set_follow(null)
			cam.focus = _to3d(spot.x, spot.y + 3.0 / WORLD_SCALE) + Vector3(0, 1.0, 0)
			cam.dist = 14.0
			cam.pitch_deg = 22.0
			await get_tree().create_timer(0.6).timeout
			await _snap("res://solid_tank.png")
			_unshield(solu, solu_save)
			soltk["alive"] = false
			soltk["node"].queue_free()
			units.erase(soltk)
			_buildings = keep_bld2
		# I-4b2) 沙包：既要擋人也要擋子彈（使用者 2026-07-26 三度指正
		#        「沙包也還沒達到、連子彈也可以穿過這種物體」）。
		#        ⚠ 沙包的障礙先前根本沒進碰撞表（Fortify.blockers 沒被 Main 併進 _blockers），
		#        所以走得過去；彈道則是只看建築牆，所以射得過去。兩件都在這裡驗。
		var sbg = null
		for bks in _blockers:
			if String(bks.get("k", "")) == "sandbag":
				sbg = bks
				break
		if sbg == null:
			print("[sandchk] SKIP 這張圖沒有沙包工事")
		else:
			var sb_n: Vector2 = (sbg["b"] - sbg["a"]).orthogonal().normalized()
			var sb_mid: Vector2 = sbg["m"]
			# 隔離：只留這道沙包。留著別的障礙會讓人被柵欄擋住而假通過（solidchk 踩過），
			# 沙包本身的幾何是 Fortify 畫的、不受 _blockers 影響，所以畫面不會說謊。
			var keep_bld3 := _buildings
			var keep_blk3 := _blockers
			_buildings = []
			_blockers = [sbg]
			# (1) 擋人：對著沙包走 5 秒
			var sbu = _deployed[0]
			var sbu_save := _shield(sbu)
			sbu["node"].stop()
			_end_action()
			cp = 6
			var sb_p0: Vector2 = sb_mid + sb_n * (5.0 / WORLD_SCALE)
			sbu["node"].global_position = _to3d(sb_p0.x, sb_p0.y)
			sbu["wx"] = sb_p0.x
			sbu["wy"] = sb_p0.y
			_begin_action(sbu)
			sbu["ap"] = 300.0
			sbu["ap_max"] = 300.0
			cam.tps_yaw = rad_to_deg(atan2(-sb_n.x, -sb_n.y))
			await get_tree().create_timer(0.5).timeout
			await _hold_key(KEY_W, 5.0)
			var sb_now := Vector2(sbu["wx"], sbu["wy"])
			var sb_proj: float = (sb_now - sb_mid).dot(sb_n) * WORLD_SCALE
			var sb_walked: float = sb_p0.distance_to(sb_now) * WORLD_SCALE
			print("[sandchk] 對著沙包走 5 秒：走了 %.2fm、停在沙包前 %.2fm、越過=%s %s"
					% [sb_walked, sb_proj, sb_proj < 0.0,
					"OK(沙包是實體)" if (sb_proj > 0.35 and sb_walked > 1.5) else "FAIL(穿過沙包了/沒走到)"])
			# ⚠ 截圖要拍得出「人貼在沙包前面停住」：第三人稱是從背後看，
			#   而且人正對著沙包，畫面上只有天空與遠景（第一版拍出來是一片藍天，
			#   證明不了任何事）。改用側面的戰術鏡頭。
			# 相機擺在「人這一側」再斜 35 度：正側面會剛好被旁邊的房子擋掉（實拍到），
			# 沿著沙包方向拍則看不出人與沙包的前後關係。
			cam.clear_tps()
			cam.set_follow(null)
			cam.focus = _to3d(sb_now.x, sb_now.y) + Vector3(0, 0.9, 0)
			cam.dist = 9.0
			cam.pitch_deg = 20.0
			cam.yaw = atan2(sb_n.x, sb_n.y) + deg_to_rad(35.0)
			await get_tree().create_timer(0.6).timeout
			await _snap("res://solid_sandbag.png")
			_end_action()
			_unshield(sbu, sbu_save)
			# (2) 擋子彈：純函式驗四種姿勢組合（不受 AI／時序干擾）
			var sb_a: Vector2 = sb_mid + sb_n * (4.0 / WORLD_SCALE)
			var sb_b: Vector2 = sb_mid - sb_n * (4.0 / WORLD_SCALE)
			var sb_h: float = float(sbg["h"])
			# ⚠ 要把「剛剛用來走路的那個測試兵」排除掉：他就站在沙包旁邊、正好壓在這條
			#   測試線上，而人本身也擋彈道（619e574）。他站著時 body_top=1.75 會把
			#   「瞄頭」那一發擋掉，測出來像是沙包變成無敵牆——量到的其實是自己人。
			#   （2026-07-27：玩家操控期間不再自動蹲之後，他行動結束的瞬間還站著，
			#     這個一直存在的破口才穩定顯形。）
			var shot_body: bool = _shot_clear(sb_a, sb_b, 1.32, 1.15, sbu)      # 站→站的軀幹
			var shot_head: bool = _shot_clear(sb_a, sb_b, 1.32, 1.52, sbu)      # 站→站的頭
			var shot_crouch: bool = _shot_clear(sb_a, sb_b, 0.92, 0.78, sbu)    # 蹲→蹲
			var shot_along: bool = _shot_clear(sb_a, sb_a + (sbg["b"] - sbg["a"]).normalized()
					* (8.0 / WORLD_SCALE), 1.32, 1.15, sbu)                        # 沿著沙包同側射
			print("[sandchk] 沙包高 %.2fm 彈道：站軀幹=%s(應false) 站頭部=%s(應true) 蹲=%s(應false) 同側=%s(應true) %s"
					% [sb_h, shot_body, shot_head, shot_crouch, shot_along,
					"OK(擋子彈且瞄頭仍打得到)" if (not shot_body and shot_head and not shot_crouch
					and shot_along) else "FAIL(子彈穿沙包/沙包變無敵牆)"])
			_buildings = keep_bld3
			_blockers = keep_blk3
		# I-4b3) 沒有東西可以插進固體裡（使用者 2026-07-26 兩次指正：「不管是槍或是人
		#        又或是任何的物品都不可能會跑進去固體裡面」）。這裡量三件事：
		#          1. 身體中心到牆面的距離（>0＝身體沒進牆）
		#          2. 槍口到抵肩點之間有沒有穿過固體（_solid_ray＝1 才算沒穿）
		#          3. 槍口本身在不在室內（在＝槍穿牆進屋了）
		if _buildings.is_empty():
			print("[clipchk] SKIP 場上沒有建築")
		else:
			var keep_bld4 := _buildings
			var keep_blk4 := _blockers
			var cbd = _buildings[0]
			_buildings = [cbd]
			_blockers = []          # 只驗牆，別讓路邊柵欄先把人擋住
			var cu2 = _deployed[0]
			var cu2_save := _shield(cu2)
			# 站在南面牆外，正對牆走（南面有門，所以往東偏 1/3 個房子寬避開門洞）
			var cc: Vector2 = cbd.rect.get_center()
			var cwall_y: float = cc.y + cbd.rect.size.y * 0.5
			var cstart := Vector2(cc.x + cbd.rect.size.x * 0.33, cwall_y + 5.0 / WORLD_SCALE)
			cu2["node"].stop()
			_end_action()
			cp = 6
			cu2["node"].global_position = _to3d(cstart.x, cstart.y)
			cu2["wx"] = cstart.x
			cu2["wy"] = cstart.y
			_begin_action(cu2)
			cu2["ap"] = 300.0
			cu2["ap_max"] = 300.0
			cam.tps_yaw = 180.0          # 朝 -z＝往北，正對南牆
			await get_tree().create_timer(0.5).timeout
			await _hold_key(KEY_W, 4.0)
			# 1) 身體：中心到最近牆線段的距離，扣掉半個牆厚＝身體中心到牆面
			var cp_now := Vector2(cu2["wx"], cu2["wy"])
			var body_gap := 1e9
			for w in cbd.walls:
				var q: Vector2 = Geometry2D.get_closest_point_to_segment(cp_now, w["a"], w["b"])
				body_gap = minf(body_gap, cp_now.distance_to(q) * WORLD_SCALE - Building.WALL_T * 0.5)
			var inside_body: bool = cbd.inside(cp_now.x, cp_now.y)
			# 2)+3) 槍：抵肩點→槍口這一段不可以穿過牆，槍口也不可以落在室內
			var mz: Vector3 = cu2["node"].muzzle_point()
			var gsrc: Vector3 = cu2["node"].gun_src_point()
			var ray_t: float = _solid_ray(gsrc, mz)
			var mzp := Vector2(mz.x / WORLD_SCALE + map_data.get("w", 960) * 0.5,
					mz.z / WORLD_SCALE + map_data.get("h", 600) * 0.5)
			var mz_inside: bool = cbd.inside(mzp.x, mzp.y)
			print("[clipchk] 貼牆 4 秒：身體中心離牆面 %.2fm 進到室內=%s %s"
					% [body_gap, inside_body,
					"OK(人沒進牆)" if (body_gap > 0.15 and not inside_body) else "FAIL(人插進牆/穿牆了)"])
			print("[clipchk] 槍：抵肩→槍口穿過固體比例 t=%.2f（1＝沒穿）槍口在室內=%s 抬槍量=%.2f %s"
					% [ray_t, mz_inside, cu2["node"].muzzle_block(),
					"OK(槍沒插進牆)" if (ray_t > 0.995 and not mz_inside) else "FAIL(槍穿進固體)"])
			# 側面拍：正面拍只看到牆，看不出槍在牆外還是牆內
			cam.clear_tps()
			cam.set_follow(null)
			cam.focus = _to3d(cp_now.x, cp_now.y) + Vector3(0, 1.1, 0)
			# ⚠ 機位要在「人與牆的外側」再斜著看：貼太近或正對牆，畫面會被整片牆填滿
			#   （4.2m 那版實拍就是一面水泥牆，看不到人也看不到槍）。
			cam.dist = 8.0
			cam.pitch_deg = 14.0
			cam.yaw = deg_to_rad(125.0)
			await get_tree().create_timer(0.6).timeout
			await _snap("res://clip_wall.png")
			_end_action()
			_unshield(cu2, cu2_save)
			_buildings = keep_bld4
			_blockers = keep_blk4
		# I-4b4) 物理法則要跟現實一樣（專案鐵律 0，使用者 2026-07-26 核定）。
		#        這裡驗兩條推論：③離地會落下（不是磁吸慢慢飄下去）④站斜坡腳要貼坡面。
		var phu = _deployed[0]
		var phu_save := _shield(phu)
		phu["node"].stop()
		_end_action()
		# ③ 自由落體：抬到地面上方 3m，量落地時間。h=½gt² → 3m 應為 0.78 秒左右。
		var pg: Vector3 = phu["node"].global_position
		var g0: float = terrain.height_at_world(pg)
		phu["node"].global_position = Vector3(pg.x, g0 + 3.0, pg.z)
		var t_fall := 0.0
		while t_fall < 3.0:
			await get_tree().process_frame
			t_fall += get_process_delta_time()
			if phu["node"].global_position.y - g0 < 0.05:
				break
		var ideal: float = sqrt(2.0 * 3.0 / 9.81)
		print("[physchk] 從 3m 落地：實測 %.2fs 理論 %.2fs %s" % [t_fall, ideal,
				"OK(自由落體)" if absf(t_fall - ideal) < 0.25 else "FAIL(不是重力，是磁吸或太慢)"])
		# ④ 斜坡貼合：找一塊有坡度的地，量模型的 up 軸與坡面法線的夾角
		var best_slope := 0.0
		var slope_pos := Vector2.ZERO
		for i in 400:
			var sx: float = randf_range(60.0, map_data.get("w", 960) - 60.0)
			var sy: float = randf_range(60.0, map_data.get("h", 600) - 60.0)
			var sv: float = terrain.slope_at(sx, sy)
			if sv > best_slope and not terrain.in_trench(sx, sy):
				best_slope = sv
				slope_pos = Vector2(sx, sy)
		if best_slope < 0.12:
			print("[physchk] SKIP 這張圖沒有足夠坡度（最陡 %.2f）" % best_slope)
		else:
			phu["node"].global_position = _to3d(slope_pos.x, slope_pos.y)
			phu["node"].want_prone = false
			await get_tree().create_timer(1.2).timeout
			var nrm: Vector3 = phu["node"]._ground_normal()
			var body_up: Vector3 = phu["node"]._model.global_basis.y.normalized()
			var ang_n: float = rad_to_deg(acos(clampf(nrm.dot(Vector3.UP), -1.0, 1.0)))
			var ang_b: float = rad_to_deg(acos(clampf(body_up.dot(nrm), -1.0, 1.0)))
			print("[physchk] 站在 %.0f 度的坡上：身體軸與坡面法線夾角 %.1f 度 %s"
					% [ang_n, ang_b, "OK(身體跟著坡傾斜)" if ang_b < ang_n * 0.7 + 3.0
					else "FAIL(還是直挺挺站著)"])
			await _snap("res://phys_slope.png")
			# ④b 趴在斜坡上也要貼坡（使用者 2026-07-27 指正：趴著是水平浮著）。
			#     身體有 1.9m 長，取樣基線跟著加長，量的才是他實際躺著的那片坡。
			phu["node"].stance_cmd = "prone"
			await get_tree().create_timer(1.4).timeout
			var pnrm: Vector3 = phu["node"]._ground_normal(0.95)
			var pbody: Vector3 = phu["node"]._model.global_basis.y.normalized()
			var pang_n: float = rad_to_deg(acos(clampf(pnrm.dot(Vector3.UP), -1.0, 1.0)))
			var pang_b: float = rad_to_deg(acos(clampf(pbody.dot(pnrm), -1.0, 1.0)))
			print("[physchk] 趴在 %.0f 度的坡上：身體軸與坡面法線夾角 %.1f 度 %s"
					% [pang_n, pang_b, "OK(趴著也貼坡)" if pang_b < pang_n * 0.7 + 3.0
					else "FAIL(趴著是水平浮著)"])
			await _snap("res://phys_slope_prone.png")
			phu["node"].stance_cmd = ""
		_unshield(phu, phu_save)
		# I-4b5) 人也是固體：站著的人擋得住彈道，趴下就讓出火線（鐵律 0①）。
		#        ⚠ 先前隔著幾個人也打得到最後一個，卻又宣稱 1.32m 的沙包擋得住——
		#          同一條「固體不可互穿」，沙包算人不算，這就是使用者說的「有的有有的沒有」。
		if _deployed.size() < 3:
			print("[bodychk] SKIP 這張圖部署不到 3 人")
		else:
			var bk_bld := _buildings
			var bk_blk := _blockers
			_buildings = []
			_blockers = []          # 只驗人體，別讓路邊柵欄先把彈道吃掉
			var sh = _deployed[0]
			var midu = _deployed[1]
			var tg = _deployed[2]
			var bsaves := [_shield(sh), _shield(midu), _shield(tg)]
			var bhome := [sh["node"].global_position, midu["node"].global_position,
					tg["node"].global_position]                   # 同上：三個人都要送回原位
			var org := Vector2(map_data.get("w", 960) * 0.5, map_data.get("h", 600) * 0.5)
			var step: float = 2.0 / WORLD_SCALE          # 三人一直線，間距 2m
			for pair in [[sh, 0.0], [midu, 1.0], [tg, 2.0]]:
				pair[0]["node"].stop()
				pair[0]["node"].want_prone = false
				pair[0]["node"].stance_cmd = "stand"
				pair[0]["node"].global_position = _to3d(org.x + step * float(pair[1]), org.y)
				var pq := _live_px(pair[0])
				pair[0]["wx"] = pq.x
				pair[0]["wy"] = pq.y
			await get_tree().create_timer(1.0).timeout
			var blocked_by_body: bool = not _shot_clear_units(sh, tg)
			# 中間那個趴下＝讓出火線（趴姿全高 0.55m，彈道從 1.32m 出膛）
			midu["node"].stance_cmd = "prone"
			await get_tree().create_timer(1.6).timeout
			var clear_after_prone: bool = _shot_clear_units(sh, tg)
			print("[bodychk] 中間站一個人 擋住彈道=%s(應true)；他趴下後 通了=%s(應true) %s"
					% [blocked_by_body, clear_after_prone,
					"OK(人是固體，趴下讓火線)" if (blocked_by_body and clear_after_prone)
					else "FAIL(人不擋子彈，或趴下也讓不出火線)"])
			midu["node"].stance_cmd = ""
			for bi in 3:
				# ⚠ stance_cmd 是「玩家按鍵指定的姿勢」，留著不清會讓後面的 [crawlchk]
				#   永遠趴不下去（本輪實際踩到，三項假 FAIL）。測試改過的狀態一律還原。
				_deployed[bi]["node"].stance_cmd = ""
				_deployed[bi]["node"].global_position = bhome[bi]
				var bpx := _live_px(_deployed[bi])
				_deployed[bi]["wx"] = bpx.x
				_deployed[bi]["wy"] = bpx.y
			await get_tree().create_timer(0.4).timeout
			for bi2 in 3:
				_unshield(_deployed[bi2], bsaves[bi2])
			_buildings = bk_bld
			_blockers = bk_blk
		# I-4b6) 涉水（鐵律 0⑤）：水深要真的拖慢人。用「走的」量距離，不看係數。
		var wet := Vector2.ZERO
		var wet_d := 0.0
		var dry := Vector2.ZERO
		for wi in 900:
			var wx2: float = randf_range(40.0, map_data.get("w", 960) - 40.0)
			var wy2: float = randf_range(40.0, map_data.get("h", 600) - 40.0)
			var dep: float = terrain.water_depth(wx2, wy2)
			if dep > wet_d:
				wet_d = dep
				wet = Vector2(wx2, wy2)
			elif dep <= 0.0 and dry == Vector2.ZERO and terrain.slope_at(wx2, wy2) < 0.12:
				# ⚠ 陸上對照點必須「真的走得動」：先前只檢查沒水沒坡，結果挑到緊貼柵欄的點，
				#   陸上只走了 0.02m、比水裡還短，比值算出 3583% 這種荒謬數字。
				var dp: Vector3 = _to3d(wx2, wy2)
				# 起點自己也要是空的：_path_clear 只從 0.6m 之後開始取樣，
				# 站在障礙裡的點照樣會通過，結果陸上只走了 0.02m（比水裡還短）。
				var dfix: Vector3 = _resolve_solids(dp, BODY_R, null)
				if Vector2(dfix.x - dp.x, dfix.z - dp.z).length() < 0.01 						and _path_clear(dp, dp + Vector3(3.0, 0, 0), BODY_R) 						and _path_clear(dp, dp + Vector3(-1.0, 0, 0), BODY_R):
					dry = Vector2(wx2, wy2)
		if wet_d < 0.25 or dry == Vector2.ZERO:
			print("[wadechk] SKIP 這張圖沒有可涉的水（最深 %.2fm）" % wet_d)
		else:
			var wu = _deployed[0]
			var wsave := _shield(wu)
			var whome: Vector3 = wu["node"].global_position   # ⚠ 測完一定要送回原位：
			# 後面的 [crawlchk] 用同一個人，把他留在水裡會讓那組整組假 FAIL（本輪實際踩到）
			wu["node"].stop()
			wu["node"].want_prone = false
			wu["node"].stance_cmd = "stand"
			var legs := {}
			for leg in [["land", dry], ["water", wet]]:
				wu["node"].global_position = _to3d((leg[1] as Vector2).x, (leg[1] as Vector2).y)
				await get_tree().create_timer(0.6).timeout
				var p0: Vector3 = wu["node"].global_position
				var tw := 0.0
				while tw < 1.2:
					await get_tree().process_frame
					var dtw: float = get_process_delta_time()
					tw += dtw
					wu["node"].move_dir(Vector3(1, 0, 0), dtw)
				var wmoved: Vector3 = wu["node"].global_position - p0
				legs[leg[0]] = Vector2(wmoved.x, wmoved.z).length()
			var wratio: float = float(legs["water"]) / maxf(0.01, float(legs["land"]))
			print("[wadechk] 水深 %.2fm：陸上走 %.2fm、水裡走 %.2fm（剩 %.0f%%） %s"
					% [wet_d, legs["land"], legs["water"], wratio * 100.0,
					"OK(水真的拖慢人)" if wratio < 0.85 else "FAIL(水只是一張半透明貼圖)"])
			wu["node"].stance_cmd = "prone"
			await get_tree().create_timer(1.4).timeout
			var pval: float = wu["node"]._prone
			print("[wadechk] 在 %.2fm 深的水裡按趴下：趴姿值=%.2f %s" % [wet_d, pval,
					"OK(水裡趴不下去)" if pval < 0.2 else "FAIL(臉泡在水裡還能趴)"])
			wu["node"].stance_cmd = ""
			wu["node"].stance_cmd = ""
			wu["node"].global_position = whome
			var wpx := _live_px(wu)
			wu["wx"] = wpx.x
			wu["wy"] = wpx.y
			await get_tree().create_timer(0.4).timeout
			_unshield(wu, wsave)
		# I-4b7) 樓板是實體（鐵律 0③）：走樓梯上二樓，量他站的高度是不是二樓地板。
		#        ⚠ 先前二樓地板只是畫出來的：站上去高度照 terrain 算＝整個人陷在一樓。
		# ⚠ 逐棟試：某些配置下樓梯口會被室內家具或隔牆堵住，
		#   只取第一棟會把「這一棟剛好堵住」誤報成「樓板功能壞了」。
		var mb_list: Array = []
		for bd2 in _buildings:
			if bd2.floors > 1:
				mb_list.append(bd2)
		var mb = mb_list[0] if not mb_list.is_empty() else null
		if mb == null:
			print("[floorchk] SKIP 這張圖沒有兩層以上的建築")
		else:
			var fu = _deployed[0]
			var fsave := _shield(fu)
			var fhome: Vector3 = fu["node"].global_position   # 同上：測完要回原位
			fu["node"].stop()
			fu["node"].want_prone = false
			fu["node"].stance_cmd = "stand"
			var bhalf := Vector2(mb.rect.size.x * WORLD_SCALE * 0.5,
					mb.rect.size.y * WORLD_SCALE * 0.5)
			# 樓梯底端（_stairs 的幾何：局部 x = half.x-0.8，沿 +z 往上爬）
			fu["node"].global_position = mb.position + Vector3(bhalf.x - 0.8, 0.0, -bhalf.y + 0.5)
			await get_tree().create_timer(0.8).timeout
			var y_before: float = fu["node"].global_position.y - mb.position.y
			var tf := 0.0
			while tf < 4.0:
				await get_tree().process_frame
				var dtf: float = get_process_delta_time()
				tf += dtf
				fu["node"].move_dir(Vector3(0, 0, 1), dtf)
			var y_after: float = fu["node"].global_position.y - mb.position.y
			# 沒爬上去就換下一棟再試（最多三棟）
			var try_i := 1
			while y_after < mb.FLOOR_H * 0.75 and try_i < mini(3, mb_list.size()):
				mb = mb_list[try_i]
				try_i += 1
				bhalf = Vector2(mb.rect.size.x * WORLD_SCALE * 0.5,
						mb.rect.size.y * WORLD_SCALE * 0.5)
				fu["node"].global_position = mb.position + Vector3(bhalf.x - 0.8, 0.0, -bhalf.y + 0.5)
				await get_tree().create_timer(0.8).timeout
				y_before = fu["node"].global_position.y - mb.position.y
				var tf2 := 0.0
				while tf2 < 4.0:
					await get_tree().process_frame
					var dtf2: float = get_process_delta_time()
					tf2 += dtf2
					fu["node"].move_dir(Vector3(0, 0, 1), dtf2)
				y_after = fu["node"].global_position.y - mb.position.y
			print("[floorchk] 沿樓梯往上走 4 秒：離一樓地板 %.2fm → %.2fm（樓高 %.2fm） %s"
					% [y_before, y_after, mb.FLOOR_H,
					"OK(真的走上二樓)" if y_after > mb.FLOOR_H * 0.75 else "FAIL(樓梯爬不上去)"])
			var terr_y: float = terrain.height_at_world(fu["node"].global_position)
			var sup_y: float = _ground_height(fu["node"].global_position)
			print("[floorchk] 二樓腳下支撐面 %.2fm vs 地形高度 %.2fm %s" % [sup_y, terr_y,
					"OK(樓板撐住了)" if sup_y > terr_y + 1.0 else "FAIL(人陷在一樓地面)"])
			await _snap("res://phys_floor2.png")
			fu["node"].stance_cmd = ""
			fu["node"].global_position = fhome
			var fpx := _live_px(fu)
			fu["wx"] = fpx.x
			fu["wy"] = fpx.y
			await get_tree().create_timer(0.4).timeout
			_unshield(fu, fsave)
		# I-4b10) 工事被炸掉時，**三件事必須一起消失**：網格、碰撞、掩體加成。
		#         少任何一件就是「畫面沒了還擋人」或「畫面還在卻穿得過去」——
		#         本專案吃過好幾次這種不一致的虧，所以三件都要斷言。
		if _destructibles.is_empty():
			print("[destroychk] SKIP 這張圖沒有可摧毀的工事")
		else:
			var dd = _destructibles[0]
			var dcen: Vector2 = dd["c"]
			var dnode = dd["node"]
			var blk_before: bool = _blockers.has(dd["blk"])
			# ⚠ 不能用 cover_at 當判準：教學圖的沙包每 55px 一座，鄰座的掩體半徑 52px
			#   會蓋住量測點，炸掉一座數值也不會變（第一版就是這樣「假通過」的）。
			#   改成直接數「這一段自己的掩體登記還在不在」。
			var cov_before := 0
			for c in _covers:
				if String(c.get("type", "")) == "sandbag" 						and Vector2(float(c["wx"]), float(c["wy"])).distance_to(dcen) < float(dd["r"]):
					cov_before += 1
			_destroy_fortifications(dcen, 60.0)
			await get_tree().create_timer(0.4).timeout
			var blk_after: bool = _blockers.has(dd["blk"])
			var cov_after := 0
			for c in _covers:
				if String(c.get("type", "")) == "sandbag" 						and Vector2(float(c["wx"]), float(c["wy"])).distance_to(dcen) < float(dd["r"]):
					cov_after += 1
			var mesh_gone: bool = not is_instance_valid(dnode)
			print("[destroychk] 炸掉一道沙包：網格消失=%s 碰撞消失=%s(炸前有=%s) 掩體登記 %d→%d %s"
					% [mesh_gone, not blk_after, blk_before, cov_before, cov_after,
					"OK(三件一起消失)" if (mesh_gone and blk_before and not blk_after
							and cov_before > 0 and cov_after == 0)
					else "FAIL(有東西沒跟著消失)"])
			# 用走的證明：原本走不過去的位置，炸完走得過去
			var du = _deployed[0]
			var dsave := _shield(du)
			var dhome: Vector3 = du["node"].global_position
			du["node"].stance_cmd = "stand"
			du["node"].global_position = _to3d(dcen.x, dcen.y + 70.0)
			await get_tree().create_timer(0.5).timeout
			var dp0: Vector3 = du["node"].global_position
			var dt := 0.0
			while dt < 3.0:
				await get_tree().process_frame
				var ddt: float = get_process_delta_time()
				dt += ddt
				du["node"].move_dir(Vector3(0, 0, -1), ddt)
			var crossed: bool = _live_px(du).y < dcen.y - 5.0
			print("[destroychk] 炸完往原本被擋的方向走 3 秒：越過=%s %s" % [crossed,
					"OK(真的通了)" if crossed else "FAIL(畫面沒了但還是走不過去)"])
			du["node"].stance_cmd = ""
			du["node"].global_position = dhome
			var dpx := _live_px(du)
			du["wx"] = dpx.x
			du["wy"] = dpx.y
			await get_tree().create_timer(0.4).timeout
			_unshield(du, dsave)
		# I-4b9) 音效必須是 3D 音源（GDD/15 F 整塊先前缺席：開槍是靜音的）。
		#        沒有喇叭可以「聽」，所以驗的是：檔案載得到、播出來的是 AudioStreamPlayer3D、
		#        而且距離衰減參數有設——這三件成立，距離衰減就是引擎在做。
		var sfx_missing: Array = []
		for nm in ["shot_rifle", "shot_carbine", "shot_sniper", "shot_lmg", "shot_cannon",
				"shot_rocket", "explosion", "impact_dirt", "impact_metal", "impact_wood",
				"step_1", "step_2", "step_3", "reload"]:
			if not ResourceLoader.exists("res://assets/audio/sfx/%s.wav" % nm):
				sfx_missing.append(nm)
		print("[sfxchk] 音效檔 14 個缺 %d 個 %s" % [sfx_missing.size(),
				"OK" if sfx_missing.is_empty() else "FAIL(缺 %s)" % str(sfx_missing)])
		var sprobe = Audio.sfx3d("shot_rifle", _to3d(map_data.get("w", 960) * 0.5,
				map_data.get("h", 600) * 0.5))
		if sprobe == null:
			print("[sfxchk] 播不出來 FAIL(sfx3d 回 null)")
		else:
			# ⚠ 屬性要**當場抓進區域變數**：音源播完會自我釋放，
			#   晚一步再讀就是「previously freed instance」（本輪實際踩到）。
			var s_cls: String = sprobe.get_class()
			var s_att: int = sprobe.attenuation_model
			var s_unit: float = sprobe.unit_size
			var s_max: float = sprobe.max_distance
			var s_is3d: bool = sprobe is AudioStreamPlayer3D
			print("[sfxchk] 音源型別=%s 衰減模型=%d 單位距離=%.1fm 最遠=%.0fm %s" % [
					s_cls, s_att, s_unit, s_max,
					"OK(3D 音源，有距離衰減)"
					if (s_is3d and s_max > 10.0 and s_unit > 0.5)
					else "FAIL(不是 3D 或沒設衰減)"])
		# I-4b8) 跑動中手臂與武器不可以消失（使用者 2026-07-27 截圖：畫面上只剩身體）。
		#        真因是 IK 在手臂折疊時算出 NaN 四元數，寫進骨架後整條手臂的蒙皮塌陷。
		#        NaN 不會噴任何錯誤訊息，只能靠「量骨頭座標是不是有限值」抓。
		var au = _deployed[0]
		var asave := _shield(au)
		var ahome: Vector3 = au["node"].global_position
		au["node"].stop()
		au["node"].stance_cmd = ""
		var asks: Array = au["node"]._model.find_children("*", "Skeleton3D", true, false)
		if asks.is_empty():
			print("[armchk] SKIP 這個模型沒有骨架")
		else:
			var ask: Skeleton3D = asks[0]
			var hbi: int = ask.find_bone("Hand.R")
			var sbi: int = ask.find_bone("Shoulder.R")
			if hbi < 0 or sbi < 0:
				print("[armchk] SKIP 找不到 Hand.R/Shoulder.R")
			else:
				var nan_frames := 0
				var reach_min := 9.9
				var reach_max := 0.0
				var ta := 0.0
				var spin := 0.0
				while ta < 3.0:
					await get_tree().process_frame
					var dta: float = get_process_delta_time()
					ta += dta
					spin += dta * 2.2                     # 邊跑邊轉向，逼 IK 走過各種角度
					au["node"].move_dir(Vector3(cos(spin), 0, sin(spin)), dta)
					var hp: Vector3 = ask.get_bone_global_pose(hbi).origin
					var sp: Vector3 = ask.get_bone_global_pose(sbi).origin
					if not (is_finite(hp.x) and is_finite(hp.y) and is_finite(hp.z)):
						nan_frames += 1
						continue
					# 用「相對於整條手臂 rest 長度」的比例，這個骨架的骨長是 0.001 量級，
					# 寫死公尺級門檻會永遠通過（本專案踩過兩次的坑）。
					var rest_len: float = ask.get_bone_rest(hbi).origin.length() + 0.000001
					var rel: float = sp.distance_to(hp) / maxf(rest_len, 0.000001)
					reach_min = minf(reach_min, rel)
					reach_max = maxf(reach_max, rel)
				print("[armchk] 邊跑邊轉 3 秒：NaN 幀=%d、手到肩距離(相對骨長) %.2f~%.2f %s"
						% [nan_frames, reach_min, reach_max,
						"OK(手臂一直在)" if (nan_frames == 0 and reach_min > 0.2 and reach_max < 40.0)
						else "FAIL(手臂算出 NaN 或被拉爆＝畫面上會整條消失)"])
				var gun_ok: bool = au["node"]._gun_node == null or au["node"]._gun_node.visible
				print("[armchk] 跑動後武器仍在場上=%s %s" % [gun_ok,
						"OK" if gun_ok else "FAIL(槍不見了)"])
				await _snap("res://phys_arm_run.png")
		au["node"].global_position = ahome
		var apx := _live_px(au)
		au["wx"] = apx.x
		au["wy"] = apx.y
		await get_tree().create_timer(0.4).timeout
		_unshield(au, asave)
		# I-4c) AI 繞開實體障礙（AI09 [navchk]）：直接驗純函式，不受敵方階段時序干擾
		if _blockers.is_empty():
			print("[navchk] SKIP 這張圖沒有中景障礙")
		else:
			var nseg = null
			for bk3 in _blockers:
				# ⚠ 排除深水圍欄：它是「地圖邊界」不是「繞得過去的障礙」，
				#   而且是全場最長的線段——不排除的話 navchk 等於在要求 AI 繞過整片海。
				if String(bk3.get("k", "")) == "deepwater":
					continue
				if bk3["t"] == "seg" and (nseg == null or float(bk3["hl"]) > float(nseg["hl"])):
					nseg = bk3
			if nseg == null:
				print("[navchk] SKIP 沒有線段型障礙")
			else:
				var keep_b4 := _buildings
				var keep_blk_nav := _blockers
				_buildings = []
				# ⚠ 建築被隔離掉了，屋裡的家具障礙也必須一起隔離——
				#   否則繞路路線會被「一棟不存在的房子裡的木箱」擋住，測出來像是 AI 繞不出去
				#   （2026-07-27 家具變成實體後當場踩到）。
				var nav_blk: Array = []
				for bkn in _blockers:
					if String(bkn.get("k", "")) != "furniture":
						nav_blk.append(bkn)
				_blockers = nav_blk
				var nf: Vector3 = _to3d(nseg["m"].x, nseg["m"].y + 5.0 / WORLD_SCALE)
				var ng: Vector3 = _to3d(nseg["m"].x, nseg["m"].y - 5.0 / WORLD_SCALE)
				var straight: bool = _path_clear(nf, ng, BODY_R)
				var alt: Vector3 = _avoid_goal(nf, ng, BODY_R)
				var alt_ok: bool = _path_clear(nf, alt, BODY_R)
				var turned: bool = alt.distance_to(ng) > 0.5
				_buildings = keep_b4
				_blockers = keep_blk_nav
				print("[navchk] 穿過障礙的直線可行=%s（應為 false） %s" % [straight,
						"OK" if not straight else "FAIL(障礙沒擋住路徑判定)"])
				print("[navchk] 繞路後換了方向=%s、新路徑可行=%s %s" % [turned, alt_ok,
						"OK(會繞開)" if (turned and alt_ok) else "FAIL(繞不出去)"])
		# I-4d) 貼牆時的第三人稱鏡頭（GDD/07 [camchk]）：牆在右手邊時要自動換到左肩，
		#      不然鏡頭被牆推到後腦杓、整個畫面都是牆，等於瞎著打。
		if _buildings.is_empty():
			print("[camchk] SKIP 這張圖沒有建築")
		else:
			var cbd = _buildings[0]
			var cu = _deployed[0]
			cu["node"].stop()
			_end_action()
			cp = 6
			var cwx: float = cbd.rect.get_center().x
			var cwy: float = cbd.rect.position.y - 4.0 / WORLD_SCALE   # 北牆外 4m
			cu["node"].global_position = _to3d(cwx, cwy)
			cu["wx"] = cwx
			cu["wy"] = cwy
			var cu_save := _shield(cu)
			_begin_action(cu)
			cu["ap"] = 300.0
			cu["ap_max"] = 300.0
			cam.tps_yaw = 0.0                    # 面向 +Z＝朝北牆走
			await get_tree().create_timer(0.5).timeout
			await _hold_key(KEY_W, 3.5)          # 用走的貼到牆邊
			cam.tps_yaw = -90.0                  # 轉成沿牆走：牆落在右手邊
			await get_tree().create_timer(1.5).timeout
			var chead: Vector3 = cu["node"].global_position + Vector3(0, 1.52, 0)
			var cdist: float = cam.global_position.distance_to(chead)
			print("[camchk] 貼牆時鏡頭離頭 %.2fm、肩側=%+.2f（-1=左肩） %s" % [cdist, cam._shoulder,
					"OK(沒被牆擠到臉上)" if cdist > 1.5 else "FAIL(鏡頭被壓到後腦杓)"])
			await _snap("res://cam_wall.png")
			_unshield(cu, cu_save)
			_end_action()
		# I-4e) 匍匐前進（GDD/07 [crawlchk]）：趴著移動不可以是「趴著跑」——
		#      播跑步動畫會讓腿在跑、手臂在擺而軀幹壓平，畫面上就是自由式游泳。
		#      ⚠ 選點一定要避開建築：先前隨手取地圖中央，結果人被放進屋裡（實拍到室內草地）。
		var cru = _deployed[0]
		if not is_instance_valid(cru["node"]) or cru["node"]._rig == null:
			print("[crawlchk] SKIP 這個單位沒有骨架工具")
		else:
			cru["node"].stop()
			_end_action()
			cp = 6
			# ⚠ 選點要同時避開建築與樹：只掃一條直線會整段被同一棟房子擋住而退回預設值
			#   （人被放進屋裡）；不避開樹則角色正前方一棵樹就佔掉四分之一畫面。
			var spot_c: Vector2 = _open_spot([14.0, 10.0, 7.0, 5.0, 0.0], 22.0)
			var crx: float = spot_c.x
			var cry: float = spot_c.y
			cru["node"].global_position = _to3d(crx, cry)
			cru["wx"] = crx
			cru["wy"] = cry
			var in_bld := false
			for bdc2 in _buildings:
				if bdc2.inside(crx, cry):
					in_bld = true
			print("[crawlchk] 測試地點在室內=%s %s" % [in_bld,
					"OK(在戶外空地)" if not in_bld else "FAIL(選點又選進屋裡了)"])
			# ⚠ 測試單位在戰場上走五秒多，會被敵方警戒射擊打死，然後 queue_free
			#   ——下一行存取 _rig 就炸「previously freed」。驗姿勢的測試不該被戰鬥干擾。
			var cru_save := _shield(cru)
			cru["node"].want_prone = true
			_begin_action(cru)
			# ⚠ _begin_action 會關掉自動姿勢（玩家操控期間不自動蹲/趴）。
			#   這一組驗的正是「自動臥射 + 爬久了會自己起身」那條路徑，所以要打開回來。
			cru["node"].auto_stance = true
			cru["ap"] = 300.0
			cru["ap_max"] = 300.0
			cam.tps_yaw = 180.0
			await get_tree().create_timer(1.6).timeout       # 等趴下（_prone 收斂）
			var cr_from: Vector3 = cru["node"].global_position
			# 分三段走，每段量一次雙腳的側向張開量：匍匐是左右腿交替蹬地，
			# 這個數值必須隨時間變化——只拍一張靜態圖看不出「有沒有在交替」。
			# 量的是「膝蓋」不是腳：匍匐的特徵是膝蓋先彎、再帶著大腿往外頂，
			# 腳跟其實是折回身體中線的（使用者 2026-07-26 指正）。
			var sc_kf := [9.9, -9.9]
			var sc_sp := [9.9, -9.9]
			var sc_hf := [9.9, -9.9]
			var sc_ka := [999.0, -999.0]
			for seg_i in 3:
				var scan: Dictionary = await _hold_key_crawlscan(KEY_W, 0.55, cru["node"])
				for pair in [["kf", sc_kf], ["sp", sc_sp], ["hf", sc_hf], ["ka", sc_ka]]:
					var got: Array = scan[pair[0]]
					(pair[1] as Array)[0] = minf(float((pair[1] as Array)[0]), float(got[0]))
					(pair[1] as Array)[1] = maxf(float((pair[1] as Array)[1]), float(got[1]))
				await _snap("res://crawl_%d.png" % (seg_i + 1))
				# ★側視近照：第三人稱是從背後看，腿被身體擋住，根本看不出匍匐動作。
				#   驗腿的姿勢一定要有側面圖（使用者三次指正剪刀腳，前兩次我都只有背影圖）。
				var cnode = cru["node"]
				cam.clear_tps()
				cam.set_follow(null)
				cam.focus = cnode.global_position + Vector3(0, 0.35, 0)
				cam.yaw = cnode.rotation.y + PI * 0.5
				cam.dist = 3.0
				cam.pitch_deg = 8.0
				await get_tree().create_timer(0.35).timeout
				await _snap("res://crawl_side%d.png" % (seg_i + 1))
				cam.set_tps(cnode)
				cam.tps_yaw = 180.0
				await get_tree().create_timer(0.2).timeout
			var cr_d: float = cr_from.distance_to(cru["node"].global_position)
			var cr_state: String = str(cru["node"]._state)
			var cr_hip: float = cru["node"]._rig.bone_pos("Hips").y - cru["node"].global_position.y
			var sp_min: float = float(sc_sp[0])
			var sp_max: float = float(sc_sp[1])
			print("[crawlchk] 趴著走 2.1 秒：位移 %.2fm、動畫=%s、髖高 %.2fm %s" % [cr_d, cr_state, cr_hip,
					"OK(是匍匐不是趴著跑)" if (cr_d > 0.6 and cr_d < 2.6 and cr_state != "run"
					and cr_state != "walk" and cr_hip < 0.55 and cr_hip > 0.05)
					else "FAIL(速度/動畫/姿勢不對，髖高<=0 代表人陷進地裡)"])
			print("[crawlchk] 膝蓋外張量 %.2f~%.2f m（擺幅 %.2f，逐幀取極值） %s"
					% [sp_min, sp_max, sp_max - sp_min,
					"OK(雙腿在交替蹬地)" if (sp_max - sp_min) > 0.05 else "FAIL(腿沒動＝只是趴著平移)"])
			# ★剪刀腳判定：匍匐是把膝蓋收到身體「前方」再蹬，剪刀腳是膝蓋往側後張開。
			#   一定要同時有「收到前面」與「蹬回後面」兩端，只驗單邊會被錯誤姿勢矇混過去。
			print("[crawlchk] 右膝相對髖部前後 %.2f~%.2f m（正=在髖前，要一前一後） %s"
					% [sc_kf[0], sc_kf[1],
					"OK(膝蓋收到前面再往後蹬)" if (float(sc_kf[1]) > 0.05 and float(sc_kf[0]) < -0.10)
					else "FAIL(膝蓋沒有收到髖部前方＝在地上往後岔開，不是匍匐)"])
			print("[crawlchk] 左手前伸距離 %.2f~%.2f m（擺幅 %.2f） %s"
					% [sc_hf[0], sc_hf[1], float(sc_hf[1]) - float(sc_hf[0]),
					"OK(手在往前撐地拉行)"
					if (float(sc_hf[1]) - float(sc_hf[0])) > 0.12 and float(sc_hf[1]) > 0.35
					else "FAIL(手沒動＝只有身體在滑)"])
			if float(sc_ka[1]) < -900.0:
				print("[crawlchk] 屈膝角度量不到 FAIL(骨頭抓不到)")
			else:
				# 一樣要兩端：蹬完必須接近伸直，收腿時必須明顯彎——
				# 只驗「最大彎曲角」的話，一條全程半彎的腿也會通過。
				print("[crawlchk] 右膝(動力腿)彎曲角 %.0f~%.0f 度（0=伸直，逐幀取極值） %s"
						% [sc_ka[0], sc_ka[1],
						"OK(收腿彎、蹬完伸直)" if (float(sc_ka[1]) > 30.0 and float(sc_ka[0]) < 22.0)
						else "FAIL(膝蓋沒有真的一彎一伸)"])
			# ★脈動驗證（使用者：「腿在動但完全不像真的在移動」）：
			#   等速平移＋腿在擺動＝人被拖著滑行。真實匍匐是一蹬一停，
			#   所以每一小段的位移必須有明顯落差。
			var segs: Array = await _hold_key_sampled(KEY_W, 1.6, 10, cru["node"])
			if segs.size() >= 4:
				var s_min: float = segs.min()
				var s_max: float = segs.max()
				var ratio: float = s_max / maxf(s_min, 0.0005)
				print("[crawlchk] 每段位移 min=%.3f max=%.3f 落差=%.1f倍 %s" % [s_min, s_max, ratio,
						"OK(一蹬一停，不是等速滑行)" if ratio > 2.0
						else "FAIL(等速平移＝看起來像被拖著滑)"])
			# 持續走就該起身：爬 2.5 秒（約 2m）之後還龜速爬過整個戰場很痛苦。
			# 這條要獨立驗，否則哪天門檻被改壞（改成永不起身或立刻起身）不會有人發現。
			await _hold_key(KEY_W, 3.5)
			var up_hip: float = cru["node"]._rig.bone_pos("Hips").y - cru["node"].global_position.y
			# 直接驗規則本身（趴姿混合值歸零），髖高只當佐證：
			# 起身後若附近有掩體會停在蹲姿（髖高約 0.45），拿站姿高度當門檻會誤判。
			var up_prone: float = float(cru["node"]._prone)
			print("[crawlchk] 連續走 3.5 秒後 趴姿值=%.2f、髖高 %.2fm（趴著是 0.26） %s" % [up_prone, up_hip,
					"OK(自動起身了)" if (up_prone < 0.1 and up_hip > 0.35)
					else "FAIL(一直趴著爬，跨越戰場會很痛苦)"])
			await _snap("res://crawl_standup.png")
			_unshield(cru, cru_save)
			cru["node"].want_prone = false
			_end_action()
		# I-4f) 鍵盤操作（GDD/07；使用者 2026-07-26 要求不要什麼都靠滑鼠）：
		#      方向鍵移動、Q/E 轉視角、C 蹲 / Z 趴 / Space 站起。
		var ku = _deployed[0]
		if not is_instance_valid(ku["node"]):
			print("[keychk] SKIP 沒有可用單位")
		else:
			ku["node"].stop()
			_end_action()
			cp = 6
			var ku_save := _shield(ku)
			var kspot: Vector2 = _open_spot([10.0, 7.0, 5.0, 0.0], 22.0)
			ku["node"].global_position = _to3d(kspot.x, kspot.y)
			ku["wx"] = kspot.x
			ku["wy"] = kspot.y
			ku["node"].want_prone = false
			_begin_action(ku)
			ku["ap"] = 300.0
			ku["ap_max"] = 300.0
			await get_tree().create_timer(0.5).timeout
			# 方向鍵（不是 WASD）要能移動
			var kfrom: Vector3 = ku["node"].global_position
			await _hold_key(KEY_UP, 1.0)
			var kmoved: float = kfrom.distance_to(ku["node"].global_position)
			print("[keychk] 方向鍵↑ 走 1 秒位移 %.2fm %s" % [kmoved,
					"OK" if kmoved > 0.8 else "FAIL(方向鍵不能移動)"])
			# Q/E 轉視角
			var yaw0: float = cam.tps_yaw
			await _hold_key(KEY_Q, 0.6)
			var yaw_d: float = absf(cam.tps_yaw - yaw0)
			print("[keychk] Q 轉視角 %.0f 度 %s" % [yaw_d,
					"OK" if yaw_d > 15.0 else "FAIL(鍵盤轉不動視角＝還是得用滑鼠)"])
			# 姿勢鍵：C 蹲 → Z 趴 → Space 站
			await _hold_key(KEY_C, 0.12)
			await get_tree().create_timer(0.9).timeout
			var c_crouch: float = float(ku["node"]._crouch)
			await _hold_key(KEY_Z, 0.12)
			await get_tree().create_timer(1.2).timeout
			var c_prone: float = float(ku["node"]._prone)
			await _snap("res://key_prone.png")
			await _hold_key(KEY_SPACE, 0.12)
			await get_tree().create_timer(1.2).timeout
			var c_stand: float = float(ku["node"]._prone) + float(ku["node"]._crouch)
			print("[keychk] C 蹲=%.2f → Z 趴=%.2f → Space 站起(蹲+趴)=%.2f %s" % [
					c_crouch, c_prone, c_stand,
					"OK(三個姿勢鍵都有效)" if (c_crouch > 0.7 and c_prone > 0.7 and c_stand < 0.2)
					else "FAIL(姿勢鍵沒作用)"])
			ku["node"].stance_cmd = ""
			_unshield(ku, ku_save)
			_end_action()
		# I) 敵方階段：AI 是否吃 CP/AP、是否真的用走的（不是瞬移）、會不會結束回合
		var epos := {}
		for x in units:
			if x["alive"] and x["side"] != player_side:
				epos[x["node"]] = x["node"].global_position
		var t_start := Time.get_ticks_msec()
		_end_player_turn()
		var cp_start: int = enemy_cp
		var guard := 0
		while st == St.ENEMY and guard < 300:
			await get_tree().create_timer(0.2).timeout
			guard += 1
			if guard == 10:
				await _snap("res://ai_turn.png")     # 敵方階段實拍：AI 是走過來的，不是瞬移
		var secs: float = (Time.get_ticks_msec() - t_start) / 1000.0
		var moved_n := 0
		for k in epos.keys():
			if is_instance_valid(k) and k.global_position.distance_to(epos[k]) > 0.5:
				moved_n += 1
		print("[aichk] 敵方 CP 起始=%d 剩餘=%d %s" % [cp_start, enemy_cp,
				"OK" if enemy_cp < cp_start else "FAIL(沒花 CP)"])
		print("[aichk] 敵方單位真的移動 %d 個 %s" % [moved_n, "OK" if moved_n > 0 else "FAIL"])
		print("[aichk] 敵方階段結束回到指令模式 st=%d 耗時=%.1fs %s" % [st, secs,
				"OK" if st == St.CMD else "FAIL(卡在敵方階段)"])
		print("[aichk] 新回合 CP=%d 回合數=%d %s" % [cp, turn, "OK" if cp == _turn_cp() and turn == 2 else "FAIL"])
		# I) 受擊與陣亡：換骨架後這兩支動作也全部改走重定向，不驗等於沒換完
		#    （判斷用頭部高度：站著約 1.5m，倒地應明顯下降）
		# ⚠ 前面剛跑完敵方階段，原本挑的單位可能已經陣亡並 queue_free，
		#   再讀 _rig 會炸「previously freed」。失效就換一個還活著的頂替。
		if not is_instance_valid(u3) or u3._dead:
			u3 = null
			for uu in units:
				if uu["alive"] and uu["side"] == player_side and is_instance_valid(uu["node"]) 						and not Unit.is_vehicle_cls(uu["cls"]):
					u3 = uu["node"]
					break
		if u3 == null:
			print("[anichk] SKIP 我方單位在敵方階段全滅，沒有對象可驗")
			await _snap("res://perf16_pre.png")
		else:
			await _anichk(u3)
		# 效能：GDD/14 §4 的預算是「16 單位 ≥60FPS」，所以要補到 16 個再量，
		# 只量現場那幾個等於沒驗到預算。
		var zc := _my_zone()
		while units.size() < 16:
			_spawn_unit("rifleman", 1 - player_side,
					float(zc.get("x", 100)) + randf_range(200.0, 700.0),
					float(zc.get("y", 250)) + randf_range(-200.0, 400.0), false)
		_refresh_visibility()
		await get_tree().create_timer(0.8).timeout
		await _snap("res://perf16.png")
		var t0 := Time.get_ticks_usec()
		for i in 60:
			await get_tree().process_frame
		var ms: float = (Time.get_ticks_usec() - t0) / 60000.0
		print("[perf] units=%d 平均幀時=%.1fms (%.0f FPS) %s" % [
			units.size(), ms, 1000.0 / maxf(ms, 0.001), "OK" if ms < 22.0 else "慢"])
	print("[selftest] DONE units=", units.size())
	_quit_test(0)

var _sun: DirectionalLight3D = null
var _fill: DirectionalLight3D = null
var _env: Environment = null
var _sky_mat: ShaderMaterial = null

# 天色時段（讀 maps.json 的 sky 欄位）：夜襲章節就該是夜色，黎明搶灘就該是晨光。
# 先前所有圖共用一組黃昏光——資料裡的 sky 欄位從來沒被讀過。
func _apply_sky(preset_name: String) -> void:
	var pr: Dictionary = Biome.sky_preset(preset_name)
	if _sun != null:
		_sun.rotation_degrees = pr["sun_deg"]
		_sun.light_color = pr["sun_color"]
		_sun.light_energy = pr["sun_energy"]
	if _env != null:
		_env.ambient_light_energy = pr["ambient"]
		_env.fog_light_color = pr["fog"]
	if _sky_mat != null:
		_sky_mat.set_shader_parameter("top_color", pr["top"])
		_sky_mat.set_shader_parameter("horizon_color", pr["horizon"])
		# 地面半球跟著霧色走：沙漠圖地平線下不該是草綠（實拍抓到一圈綠邊）
		var fogc: Color = pr["fog"]
		_sky_mat.set_shader_parameter("ground_horizon", fogc * 0.92)
		_sky_mat.set_shader_parameter("ground_bottom", fogc * 0.42)
		# 夜間雲要暗：雲色也乘時段亮度
		var mulc: Color = pr.get("mul", Color(1, 1, 1))
		_sky_mat.set_shader_parameter("cloud_color", Color(1.0, 0.93, 0.82) * mulc)
		_sky_mat.set_shader_parameter("cloud_shadow", Color(0.52, 0.50, 0.56) * mulc)

func _build_static() -> void:
	# 太陽：暖色、柔邊陰影、角度更斜（拉長影子＝立體感）
	var sun := DirectionalLight3D.new()
	_sun = sun
	sun.rotation_degrees = Vector3(-26, 142, 0)   # 黃昏斜射：影子拉長＝體積感（正午頂光是死白的主因）
	sun.light_color = Color(1.0, 0.87, 0.68)      # 金黃色溫
	sun.light_energy = 1.35
	sun.shadow_enabled = true
	sun.shadow_blur = 1.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 90.0
	sun.directional_shadow_split_1 = 0.06
	sun.directional_shadow_split_2 = 0.16
	sun.directional_shadow_split_3 = 0.42
	# 建築牆面出現規則的點狀噪點＝陰影自我遮蔽(shadow acne)，大平面在斜射光下最明顯。
	# 提高 bias 就乾淨了；代價是接觸陰影稍微離開物體一點點，這個尺度看不出來。
	sun.shadow_normal_bias = 2.6
	sun.shadow_bias = 0.06
	add_child(sun)
	# 補光：從反方向打冷色弱光，避免暗面全黑（治「黑色邊」的觀感）
	var fill := DirectionalLight3D.new()
	_fill = fill
	fill.rotation_degrees = Vector3(-28, -50, 0)
	fill.light_color = Color(0.72, 0.80, 0.95)
	fill.light_energy = 0.22     # Forward+ 的天空環境光比 compat 強很多，補光要跟著收
	fill.shadow_enabled = false
	add_child(fill)

	var e := Environment.new()
	_env = e
	# 天空：漸層＋太陽＋**雲層**（GDD/14 §0a）。
	# 為什麼要自己寫 shader：ProceduralSkyMaterial 沒有雲，一片乾淨漸層在遠鏡頭下
	# 佔畫面上半部卻空無一物，是「場景還不像 3A」剩下最大的一塊面積。
	var sky_mat := ShaderMaterial.new()
	_sky_mat = sky_mat
	var sky_sh := Shader.new()
	sky_sh.code = SKY_SHADER
	sky_mat.shader = sky_sh
	sky_mat.set_shader_parameter("top_color", Color(0.22, 0.38, 0.66))
	sky_mat.set_shader_parameter("horizon_color", Color(0.92, 0.82, 0.66))   # 地平線帶金
	sky_mat.set_shader_parameter("cloud_color", Color(1.0, 0.93, 0.82))
	sky_mat.set_shader_parameter("cloud_shadow", Color(0.52, 0.50, 0.56))
	sky_mat.set_shader_parameter("cloud_cover", 0.52)
	sky_mat.set_shader_parameter("cloud_sharp", 1.6)   # 邊緣更軟：2.6 的雲邊還是切得出多邊形
	sky_mat.set_shader_parameter("drift", 0.004)
	sky_mat.set_shader_parameter("ground_horizon", Color(0.60, 0.64, 0.58))
	sky_mat.set_shader_parameter("ground_bottom", Color(0.26, 0.29, 0.25))
	var sky := Sky.new()
	sky.sky_material = sky_mat
	# 天空只當環境光來源，不必每幀重算輻照度（雲飄得很慢）
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	# ⚠ 2026-07-26 換 Forward+ 後整個場景被洗白（GDD/10 五大事故的「sRGB 洗白」重演）：
	#   compat 時代調的 0.9 環境光在 Forward+ 是過曝的。天空環境光要大幅收斂。
	e.ambient_light_energy = 0.24     # 環境光再收：亮部靠太陽、暗部靠補光，對比才出得來
	# 環境光遮蔽：物件接地處自然變暗，最有效的「不假」來源
	e.ssao_enabled = true
	e.ssao_radius = 1.2
	e.ssao_intensity = 2.6
	e.ssao_power = 1.8
	e.ssao_light_affect = 0.15
	# 遠景霧氣：拉出空間深度
	e.fog_enabled = true
	e.fog_light_color = Color(0.76, 0.72, 0.62)   # 黃昏霾是暖灰，不是冷藍
	e.fog_density = 0.00045      # 0.0010 在遠鏡頭把整片戰場壓成灰綠（實拍），對比全失
	e.fog_sky_affect = 0.0        # 霧吃到天空會把整片天壓成灰色（實拍發現）
	e.fog_aerial_perspective = 0.30   # 遠景要褪成天空色，山脈才有距離感
	# 高度霧：低窪處積霧，戰場才有空氣感（也讓遠處的兵不再像貼紙）
	e.fog_height = 1.5
	e.fog_height_density = 0.035
	# 色調映射＋微光暈：去除死白、增加層次
	# SSIL（螢幕空間間接照明）：低多邊形最缺的就是「光在物體之間彈射」——
	# 草地的綠會反到人腿上、牆面暗部帶到地面色，質感提升比再加模型有效（GDD/14 §0a）。
	e.ssil_enabled = true
	e.ssil_radius = 3.2
	e.ssil_intensity = 0.85
	e.ssil_sharpness = 0.98
	e.ssil_normal_rejection = 1.0
	# 體積霧：晨霧與陽光穿過樹林的光柱，這是「戰場氛圍」最便宜的來源。
	# 貼地那層要厚一點，遠處的樹腳才會沒入霧裡＝景深感。
	e.volumetric_fog_enabled = true
	e.volumetric_fog_density = 0.0042    # 同上：體積霧也要減半，近景才不會霧濛濛
	e.volumetric_fog_albedo = Color(0.86, 0.87, 0.86)   # 偏中性，太藍會把整片戰場染冷
	e.volumetric_fog_length = 96.0
	e.volumetric_fog_detail_spread = 2.0
	e.volumetric_fog_ambient_inject = 0.5
	e.volumetric_fog_sky_affect = 0.0      # 同 fog_sky_affect：吃到天空會把整片天壓灰
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.tonemap_exposure = 1.0
	e.tonemap_white = 4.0
	e.glow_enabled = true
	e.glow_intensity = 0.22
	e.glow_bloom = 0.11
	e.glow_hdr_threshold = 0.95
	e.adjustment_enabled = true
	e.adjustment_saturation = 1.22    # 飽和拉上去：灰綠地面與淡藍遠山是「洗白感」主因
	e.adjustment_contrast = 1.10
	var we := WorldEnvironment.new()
	we.environment = e
	add_child(we)

	cam = TacticalCamera.new()
	add_child(cam)
	cam.dist = 16.0
	cam.pitch_deg = 46.0

# ---------- 流程 ----------
func _open_menu() -> void:
	st = St.MENU
	_teardown_world()
	Audio.bgm("menu")
	ui.show_menu(false)

func _open_story() -> void:
	st = St.STORY
	ui.show_story(_unlocked(), _growth_unlocked())

# ---------- 養成系統（GDD/16）：戰鬥賺經驗 → 訓練場給兵科升級 ----------
var _growth := {"pool": 0, "lv": {}}

func _growth_unlocked() -> bool:
	return _unlocked() > int(GameData.growth.get("unlock_after_ch", 4))

func _load_growth() -> void:
	if FileAccess.file_exists("user://growth.json"):
		var p = JSON.parse_string(FileAccess.get_file_as_string("user://growth.json"))
		if p is Dictionary:
			_growth = {"pool": int(p.get("pool", 0)), "lv": p.get("lv", {})}

func _save_growth() -> void:
	if _test_mode:
		return          # 壓測/走查不可污染玩家真實養成進度（同 unlocked.txt 那條保護）
	var f := FileAccess.open("user://growth.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_growth))

func _open_training() -> void:
	st = St.STORY
	ui.show_training(int(_growth["pool"]), _growth["lv"])

func _on_training_up(cls: String) -> void:
	var lv: int = int(_growth["lv"].get(cls, 0))
	var cost: int = GameData.growth_cost(lv)
	if int(_growth["pool"]) < cost or lv >= int(GameData.growth.get("lv_max", 10)):
		return          # UI 已 disable，這裡是第二道閘（防連點與測試直呼）
	_growth["pool"] = int(_growth["pool"]) - cost
	_growth["lv"][cls] = lv + 1
	_save_growth()
	ui.show_training(int(_growth["pool"]), _growth["lv"])

func _unlocked() -> int:
	var v := 1
	if FileAccess.file_exists("user://unlocked.txt"):
		v = int(FileAccess.get_file_as_string("user://unlocked.txt"))
	return clamp(v, 1, GameData.story.size())

func _set_unlocked(n: int) -> void:
	var f := FileAccess.open("user://unlocked.txt", FileAccess.WRITE)
	if f: f.store_string(str(n))

func _open_brief(n: int) -> void:
	chapter = n
	var ch: Dictionary = GameData.story[n - 1]
	st = St.BRIEF
	ui.show_briefing(ch, func(): _open_dialogue(ch))

func _open_dialogue(ch: Dictionary) -> void:
	st = St.DIALOGUE
	var dlg: Array = ch.get("dialog", [])
	if dlg.is_empty():
		_open_deploy(ch)
	else:
		ui.show_dialogue(dlg, func(): _open_deploy(ch))

func _open_deploy(ch: Dictionary) -> void:
	st = St.DEPLOY
	player_side = ch.get("side", 0)
	nation[player_side] = ch.get("player", "usa")
	nation[1 - player_side] = ch.get("enemy", "russia")
	map_data = GameData.maps.get(ch.get("map", "plain"), {})
	budget_left = map_data.get("budget", 1500)
	_teardown_world()
	_build_ground()
	units = []
	_ai_deploy()
	# 名冊：已解鎖具名
	var roster := []
	for cls in GameData.characters.keys():
		var chr: Dictionary = GameData.characters[cls]
		if chr.get("unlockCh", 1) > chapter:
			continue
		roster.append({"cls": cls, "name": chr.get("name", ""),
				"zh": GameData.class_base.get(cls, {}).get("zh", cls),
				"trait": chr.get("trait", {}).get("desc", ""), "named": true})
	# 劇情模式鐵則（舊版 js/ui.js）：通用清單「沒有雜魚步兵」，只出已解鎖載具。
	# 步兵一律由具名英雄出任（上面名冊已列）；載具依 vehicle_unlock 依章解鎖。
	var allow: Array = map_data.get("allow", ["land"])
	for cls in GameData.class_base.keys():
		var cb: Dictionary = GameData.class_base[cls]
		if not (cb.get("domain", "land") in allow):
			continue
		if not GameData.vehicle_unlock.has(cls):
			continue    # 非載具（步兵）：劇情模式不列通用兵
		if int(GameData.vehicle_unlock[cls]) > chapter:
			continue    # 載具未解鎖：不顯示（召喚限制）
		roster.append({"cls": cls, "name": cb.get("zh", cls), "zh": cb.get("zh", cls),
				"trait": GameData.weapon_of(nation[player_side], cls).get("type", ""),
				"cost": cb.get("cost", 100), "portrait": GameData.portrait_path(cls), "named": false})
	# 具名補上 portrait/cost 欄
	for item in roster:
		if item.get("named", false):
			item["portrait"] = GameData.portrait_path(item["cls"])
			item["cost"] = GameData.class_base.get(item["cls"], {}).get("cost", 100)
	Audio.bgm("battle")
	ui.show_deploy(ch, budget_left, roster, _on_deploy_pick, _start_battle)
	_deployed = []
	_pending_cls = ""
	_pending_named = false
	_placed_named = {}

var _deployed: Array = []
var _pending_cls := ""
var _pending_named := false
var _placed_named := {}

func _on_deploy_pick(cls: String, named: bool) -> void:
	# 選待放置兵種（點戰場藍框才實際放置）
	_pending_cls = cls
	_pending_named = named
	ui.update_budget(budget_left, "已選：%s，點藍框放置" % GameData.class_base.get(cls, {}).get("zh", cls))

func _try_place(wx: float, wy: float) -> void:
	if _pending_cls == "":
		return
	var cls := _pending_cls
	var cb: Dictionary = GameData.class_base.get(cls, {})
	var cost: int = cb.get("cost", 100)
	# 召喚限制：預算
	if cost > budget_left:
		ui.update_budget(budget_left, "點數不足")
		return
	# 召喚限制：具名每場一次
	if _pending_named and _placed_named.has(cls):
		ui.update_budget(budget_left, "該隊員已出戰")
		return
	# 召喚限制：坦克/大型艦上限 2
	if cls == "tank" and _count_cls(player_side, "tank") >= 2:
		ui.update_budget(budget_left, "坦克上限 2")
		return
	if cb.get("big", false) and _count_big(player_side) >= 2:
		ui.update_budget(budget_left, "大型艦上限 2")
		return
	var u = _spawn_unit(cls, player_side, wx, wy, _pending_named)
	_update_cover_state(u)
	_deployed.append(u)
	if _pending_named:
		_placed_named[cls] = true
		Audio.voice(cls, "sel")
	budget_left -= cost
	ui.update_budget(budget_left, "已部署 %s" % cb.get("zh", cls))
	if _pending_named:
		_pending_cls = ""    # 具名放完清除（每場一次）

# 我方階段的 CP：基礎 6 + 存活坦克數（上限 10）。GDD/01 §1。
func _turn_cp() -> int:
	var tanks := 0
	for u in units:
		if u["alive"] and u["side"] == player_side and u["cls"] == "tank":
			tanks += 1
	return mini(CP_BASE + tanks, CP_CAP)

# 下令成本：坦克 2 CP，其餘 1 CP
func _order_cost(u) -> int:
	return 2 if u["cls"] == "tank" else 1

# 進入行動模式：扣 CP、依下令次數遞減 AP 上限
func _begin_action(u) -> bool:
	var cost := _order_cost(u)
	var pool: int = cp if u["side"] == player_side else enemy_cp
	if pool < cost or not u["alive"]:
		return false
	if acting != null and acting != u:
		_end_action()
	if u["side"] == player_side:
		cp -= cost
	else:
		enemy_cp -= cost
	u["orders"] = int(u.get("orders", 0)) + 1
	var full: float = float(GameData.class_base.get(u["cls"], {}).get("ap", 150))
	u["ap"] = full * pow(AP_DECAY, u["orders"] - 1)
	u["ap_max"] = u["ap"]
	u["fired"] = false
	acting = u
	_act_last = u["node"].global_position
	if u["side"] == player_side:
		ui.update_hud(turn, "player", cp, _hud_wx())
		ui.show_ap(u["ap"], u["ap_max"])
		_update_ap_ring()
		# 下令＝進入第三人稱操控（GDD/07）：鏡頭滑到角色背後、滑鼠鎖定成自由視角
		cam.set_tps(u["node"])
		ui.show_crosshair(true)
		# ★★2026-07-27 使用者：「控制人物滑鼠被綁定在準星裡，完全不能動，
		#   這樣要如何點結束行動，我關掉遊戲，等於滑鼠沒有用。」
		#   下令時**不再自動鎖滑鼠**。鎖滑鼠是 FPS 的慣例，但這是戰術遊戲——
		#   螢幕上一直有「結束行動」「AP 條」「角色卡」要點，鎖住游標等於把 UI 廢掉。
		#   改成：游標永遠可用；要自由轉視角的人自己按 Tab 鎖。轉視角本來就有 Q/E。
		_capture_mouse(false)
		ui.flash_msg("操作：WASD 移動　Q/E 轉視角　C 蹲 Z 趴 Space 站　左鍵開火　"
				+ "Tab 鎖滑鼠自由轉視角　Esc 結束行動", Color(0.75, 0.92, 1.0))
		# ★玩家親自操控期間關掉自動姿勢（使用者 2026-07-27：「停下來又自動蹲回去」）。
		#   自動掩體判定原本每次停下就把人壓成蹲姿，玩家想站著看前方也站不起來——
		#   自動判定壓過玩家意圖。姿勢改由 C／Z／Space 全權決定。
		# ⚠ 不可以順手把 stance_cmd 清掉：玩家（與測試）常常是「先指定姿勢再下令」，
		#   清掉等於下令的瞬間把人從趴姿拉回站姿（實測讓 [sandchk] 與 [crawlchk] 一起掛掉）。
		u["node"].auto_stance = false
	return true

# 結束行動：單位進入警戒狀態（GDD/01 §2 最後一條）
func _end_action() -> void:
	if ui != null:
		ui.hide_fire_panel()
		ui.show_crosshair(false)
	if cam != null:
		cam.clear_tps()
	_capture_mouse(false)
	if acting == null:
		return
	acting["node"].stop()
	acting["node"].auto_stance = true      # 交回 AI/自動判定（結束行動後自己找掩體）
	_update_cover_state(acting)
	acting = null
	ui.hide_ap()
	if is_instance_valid(_ap_ring):
		_ap_ring.visible = false

# 剩餘 AP 在**完全平坦**的地形上還能走幾公尺（＝上限，不含地形成本）
func _ap_metres(u) -> float:
	return float(u.get("ap", 0.0)) * PX_PER_AP * WORLD_SCALE

# 剩餘 AP 往某個方向實際走得到多遠（沿路累積地形成本）。
# ★2026-07-27：這是 [apchk] 掛了很久的真因——UI 說可走 11.5m、實走只有 9.0m。
#   扣 AP 時乘了上坡 ×1.5／彈坑 ×2，但顯示的行動範圍用的是「平地上限」，
#   兩邊各算各的。玩家看到的是「圈畫到那裡，走過去卻半路就停」。
#   ⚠ 這裡只改**顯示與點地移動的上限**，移動規則（每幀怎麼扣 AP）完全沒動。
func _ap_reach_dir(u, dir: Vector3, max_steps := 90) -> float:
	var budget: float = _ap_metres(u)
	if budget <= 0.0 or terrain == null:
		return budget
	var d := Vector3(dir.x, 0.0, dir.z)
	if d.length() < 0.0001:
		return budget
	d = d.normalized()
	var mob: String = String(GameData.class_base.get(u["cls"], {}).get("mobility", "foot"))
	var wmul: float = weather_move_mul()
	var step := 0.35
	var pos: Vector3 = u["node"].global_position
	var gone := 0.0
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	for i in max_steps:
		pos += d * step
		var px: float = pos.x / WORLD_SCALE + mw * 0.5
		var py: float = pos.z / WORLD_SCALE + mh * 0.5
		if px < 1.0 or py < 1.0 or px > mw - 1.0 or py > mh - 1.0:
			break
		# 方向要傳進去才分得出上下坡（同一個點往上走與往下走不同價）
		var cost: float = terrain.move_cost(px, py, mob, Vector2(d.x, d.z)) * wmul
		var spend: float = step * cost
		if spend > budget:
			gone += step * (budget / maxf(spend, 0.0001))
			budget = 0.0
			break
		budget -= spend
		gone += step
	return gone

# 行動範圍圈已移除（2026-07-27 使用者：「AP 不用特別再用黃圈去判斷還有多少 AP，
# 右下角就已經有顯示了」）。留空函式讓呼叫端不用改，並確保舊的圈不會殘留在畫面上。
func _update_ap_ring() -> void:
	if is_instance_valid(_ap_ring):
		_ap_ring.visible = false
	return

func _update_ap_ring_unused() -> void:
	if acting == null:
		return
	if not is_instance_valid(_ap_ring):
		_ap_ring = MeshInstance3D.new()
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(1.0, 0.85, 0.35, 0.55)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_ap_ring.material_override = m
		add_child(_ap_ring)
	# ★2026-07-27 使用者回報「黃色線浮空不貼地」的真因：這一圈以前是 TorusMesh，
	#   整圈只有一個高度（角色腳下）。半徑十幾公尺的圈套在起伏地形上，
	#   一半浮在空中、一半埋進土裡，看起來就是一條橫過戰場的黃色浮空帶。
	#   改成逐頂點取地形高度的環帶。
	var r: float = maxf(_ap_metres(acting), 0.05)
	var c: Vector3 = acting["node"].global_position
	# 每幀重建 72 段的貼地環＝每幀 146 次地形取樣，沒必要：半徑或圓心動超過 15cm 才重建。
	if _ap_ring.mesh == null or absf(r - _ap_ring_r) > 0.15 or c.distance_to(_ap_ring_c) > 0.15:
		_ap_ring_r = r
		_ap_ring_c = c
		_ap_ring.mesh = _ground_ring_mesh(c, 72)
	_ap_ring.global_position = Vector3.ZERO
	_ap_ring.visible = true

# 貼地環帶：以 c 為圓心、內外半徑各取一圈，每個頂點的 y 直接問地形。
# 任何「畫在地上的指示線」都要用這個，不可以用固定高度的平面／圓環
# （鐵律 0 的延伸：畫在地上的東西就該貼著地）。
func _ground_ring_mesh(c: Vector3, seg: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pts_in: Array = []
	var pts_out: Array = []
	for i in seg + 1:
		var a: float = TAU * float(i) / float(seg)
		var d := Vector3(cos(a), 0.0, sin(a))
		# 每個方向各自算「這個方向真的走得到多遠」：上坡與彈坑那側的圈會自然凹進來。
		var r_out: float = maxf(_ap_reach_dir(acting, d, 60), 0.05)
		var r_in: float = maxf(r_out - 0.16, 0.02)
		pts_in.append(_ground_pt(c + d * r_in))
		pts_out.append(_ground_pt(c + d * r_out))
	for i in seg:
		for v in [pts_in[i], pts_out[i], pts_out[i + 1], pts_in[i], pts_out[i + 1], pts_in[i + 1]]:
			st.set_normal(Vector3.UP)
			st.add_vertex(v)
	return st.commit()

func _ground_pt(p: Vector3, lift := 0.06) -> Vector3:
	var y: float = p.y
	if terrain != null:
		y = terrain.height_at_world(p)
	return Vector3(p.x, y + lift, p.z)

# 貼地矩形（部署區底色）：以 px 為單位的 Rect 切成格子，每個格點的 y 問地形。
func _ground_rect_mesh(z: Dictionary, lift: float) -> ArrayMesh:
	var x0: float = z.get("x", 0)
	var y0: float = z.get("y", 0)
	var w: float = z.get("w", 300)
	var h: float = z.get("h", 200)
	var nx: int = maxi(2, int(w / 24.0))
	var ny: int = maxi(2, int(h / 24.0))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in nx:
		for j in ny:
			# 水裡不畫：部署區壓到海面上時，那片半透明藍蓋在水上就是一張藍地毯
			#   （使用者 2026-07-27「部署／水面那片不透明藍色塊」的一半原因）。
			if terrain != null and terrain.water_depth(x0 + w * (i + 0.5) / nx,
					y0 + h * (j + 0.5) / ny) > 0.05:
				continue
			var a := _ground_pt(_to3d(x0 + w * i / nx, y0 + h * j / ny), lift)
			var b := _ground_pt(_to3d(x0 + w * (i + 1) / nx, y0 + h * j / ny), lift)
			var c := _ground_pt(_to3d(x0 + w * (i + 1) / nx, y0 + h * (j + 1) / ny), lift)
			var d := _ground_pt(_to3d(x0 + w * i / nx, y0 + h * (j + 1) / ny), lift)
			for v in [a, b, c, a, c, d]:
				st.set_normal(Vector3.UP)
				st.add_vertex(v)
	return st.commit()

# 貼地矩形外框（部署區邊界帶）：沿四條邊鋪一條 band_m 公尺寬的帶子，同樣逐點貼地。
func _ground_rect_border(z: Dictionary, band_m: float) -> ArrayMesh:
	var x0: float = z.get("x", 0)
	var y0: float = z.get("y", 0)
	var w: float = z.get("w", 300)
	var h: float = z.get("h", 200)
	var band: float = band_m / WORLD_SCALE
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var edges := [
		[Vector2(x0, y0), Vector2(x0 + w, y0), Vector2(0, 1)],
		[Vector2(x0 + w, y0), Vector2(x0 + w, y0 + h), Vector2(-1, 0)],
		[Vector2(x0 + w, y0 + h), Vector2(x0, y0 + h), Vector2(0, -1)],
		[Vector2(x0, y0 + h), Vector2(x0, y0), Vector2(1, 0)],
	]
	for e in edges:
		var a: Vector2 = e[0]
		var b: Vector2 = e[1]
		var inw: Vector2 = e[2] * band
		var n: int = maxi(2, int(a.distance_to(b) / 24.0))
		for i in n:
			var p0: Vector2 = a.lerp(b, float(i) / n)
			var p1: Vector2 = a.lerp(b, float(i + 1) / n)
			var q0 := _ground_pt(_to3d(p0.x, p0.y), 0.07)
			var q1 := _ground_pt(_to3d(p1.x, p1.y), 0.07)
			var q2 := _ground_pt(_to3d(p1.x + inw.x, p1.y + inw.y), 0.07)
			var q3 := _ground_pt(_to3d(p0.x + inw.x, p0.y + inw.y), 0.07)
			for v in [q0, q1, q2, q0, q2, q3]:
				st.set_normal(Vector3.UP)
				st.add_vertex(v)
	return st.commit()

func _count_cls(s: int, cls: String) -> int:
	var n := 0
	for u in units:
		if u["alive"] and u["side"] == s and u["cls"] == cls:
			n += 1
	return n

func _count_big(s: int) -> int:
	var n := 0
	for u in units:
		if u["alive"] and u["side"] == s and GameData.class_base.get(u["cls"], {}).get("big", false):
			n += 1
	return n

func _my_zone() -> Dictionary:
	var dz = map_data.get("deploy", [])
	if dz is Array and dz.size() > player_side:
		return dz[player_side]
	return {"x": 100, "y": 250, "w": 300, "h": 200}

# 這一章的難度設定（data/difficulty.json）。鐵律 3：數值不寫在引擎裡。
# ⚠ 非劇情模式（chapter=0）一律當第 1 章，不要拿到 null 就整套行為消失——
#   「設定看起來有、玩起來沒有」是本專案反覆出現的病。
# 章節難度的「地形要變複雜」（使用者 2026-07-28）。
# 做法：把額外的彈坑與沙包工事**加進 map_data**，再讓 Terrain/Fortify 照原本的流程長出來，
# 而不是另外寫一套「難度專用地形」——這樣所有既有規則（掩體、移動成本、焦土、
# 走查判準）都自動適用，不必再維護第二條路徑。
# ⚠ 一定要避開建築與部署區：彈坑長在部署格上＝玩家一放下士兵就掉進坑裡。
func _boost_terrain() -> void:
	var k: float = float(_diff().get("terrain", 0.0))
	if k <= 0.01:
		return
	var mwp: float = map_data.get("w", 960)
	var mhp: float = map_data.get("h", 600)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242 + chapter * 97
	var solids: Array = map_data.get("solids", [])
	var zones: Array = map_data.get("deploy", [])
	var fox: Array = map_data.get("foxholes", []).duplicate()
	var sbs: Array = map_data.get("sandbags", []).duplicate()
	var want_f: int = int(round(7.0 * k))
	var want_s: int = int(round(5.0 * k))
	var got_f := 0
	var got_s := 0
	for _try in 900:
		if got_f >= want_f and got_s >= want_s:
			break
		var px: float = rng.randf_range(mwp * 0.10, mwp * 0.92)
		var py: float = rng.randf_range(mhp * 0.08, mhp * 0.92)
		var r: float = rng.randf_range(22.0, 38.0)
		var bad := false
		for sd in solids:
			var sr := Rect2(float(sd.get("x", 0)), float(sd.get("y", 0)),
					float(sd.get("w", 60)), float(sd.get("h", 60))).grow(r + 30.0)
			if sr.has_point(Vector2(px, py)):
				bad = true
				break
		if not bad:
			for dz in zones:
				var zr := Rect2(float(dz.get("x", 0)), float(dz.get("y", 0)),
						float(dz.get("w", 300)), float(dz.get("h", 200))).grow(r + 24.0)
				if zr.has_point(Vector2(px, py)):
					bad = true
					break
		if not bad and terrain != null:
			pass       # terrain 還沒建好，水域改用資料層判斷（下面）
		if not bad:
			# 水裡不挖坑也不堆沙包：用 maps.json 的水域資料粗判（terrain 這時還沒建）
			for wk in ["waters", "deepwaters", "shallows"]:
				for wr in map_data.get(wk, []):
					if Rect2(float(wr.get("x", 0)), float(wr.get("y", 0)),
							float(wr.get("w", 60)), float(wr.get("h", 60))).grow(r).has_point(Vector2(px, py)):
						bad = true
						break
			for rv in map_data.get("rivers", []):
				var hw: float = float(rv.get("w", 60)) * 0.5 + r
				for i in range((rv.get("pts", []) as Array).size() - 1):
					var a := Vector2(float(rv["pts"][i][0]), float(rv["pts"][i][1]))
					var b := Vector2(float(rv["pts"][i + 1][0]), float(rv["pts"][i + 1][1]))
					if Geometry2D.get_closest_point_to_segment(Vector2(px, py), a, b).distance_to(Vector2(px, py)) < hw:
						bad = true
						break
			var co = map_data.get("coast", null)
			if co != null and not bad:
				for q in co.get("pts", []):
					if absf(py - float(q[1])) < 120.0 and px < float(q[0]) + r + 20.0:
						bad = true
						break
		if bad:
			continue
		if got_f < want_f:
			fox.append({"x": px, "y": py, "r": r})
			got_f += 1
		elif got_s < want_s:
			var horiz: bool = rng.randf() < 0.5
			sbs.append({"x": px, "y": py, "w": (46.0 if horiz else 12.0),
					"h": (12.0 if horiz else 46.0)})
			got_s += 1
	map_data["foxholes"] = fox
	map_data["sandbags"] = sbs
	print("[diff] 地形加碼（×%.2f）：彈坑 +%d、工事 +%d" % [k, got_f, got_s])

func _diff() -> Dictionary:
	var tiers: Array = GameData.difficulty.get("tiers", [])
	if tiers.is_empty():
		push_error("[diff] data/difficulty.json 沒讀到，AI 會退回最簡單的行為")
		return {"enemyCount": 3, "vehicles": 0, "cover": 0.0, "focus": 0.0,
				"flank": 0.0, "alertK": 1.0, "retreatHp": 0.3, "terrain": 0.0}
	var idx: int = clampi(maxi(chapter, 1) - 1, 0, tiers.size() - 1)
	return tiers[idx]

func _ai_deploy() -> void:
	var es := 1 - player_side
	var zone: Dictionary = {}
	var dz = map_data.get("deploy", [])
	if dz is Array and dz.size() > es:
		zone = dz[es]
	else:
		zone = {"x": 560, "y": 250, "w": 300, "h": 200}
	# ★★2026-07-28 使用者裁定：第 6~15 章不解鎖新東西，改用「敵人變多、地形變複雜、
	#   AI 變聰明」爬難度。數量與載具數一律讀 data/difficulty.json。
	# ⚠ 舊版註解寫「載具依 vehicle_unlock」，但**程式從來沒讀過**——敵軍永遠不出載具。
	#   這是本專案的老病：設定看起來有、玩起來沒有。
	var dif: Dictionary = _diff()
	var pool := ["mg", "at", "sniper", "assault", "rifleman", "rifleman", "engineer",
			"mortar", "specops", "sam", "rifleman", "assault"]
	var count: int = int(dif.get("enemyCount", 3))
	var placed_e := 0
	for i in count:
		var cls: String = pool[i % pool.size()]
		if not CLASS_MODEL.has(cls):
			continue
		var wx: float = zone.get("x", 560) + 30 + float(placed_e % 3) * 55.0
		var wy: float = zone.get("y", 250) + 30 + float(placed_e / 3) * 55.0
		# ★★步兵也要有場地限制（2026-08-02 使用者：「不管是人物也好還是載具也好
		#   都要有場地限制並且合理化」）。先前只有載具做了落點檢查，步兵是照網格
		#   硬放——stress ch09（海圖）因此把 engineer/mortar 放在水上，深水圍欄
		#   把人一路推到離地圖邊緣 1m 還在水裡＝「陷進實體」2 筆。
		#   人站的地方必須是人走得到的地方，這跟載具是同一條規則。
		var isp = _inf_spawn_spot(Vector2(wx, wy))
		if isp == null:
			push_error("[diff] 第 %d 章找不到 %s 的合法站位（部署區附近無可站立地面）"
					% [maxi(chapter, 1), cls])
			continue
		var ip: Vector2 = isp
		_spawn_unit(cls, es, ip.x, ip.y, false)
		placed_e += 1
	# 敵方載具：依難度表的數量，且仍受 vehicle_unlock 的章節限制（玩家沒有的敵人也不該有）
	# ⚠⚠ 2026-08-02 修：這裡原本的守衛是 `CLASS_MODEL.has(vc)`，而 CLASS_MODEL 只列
	#   九個**步兵**兵種、從來沒有任何載具鍵 → vpool 恆空 → 第 5 章起敵方載具一台都
	#   不出（只有 push_error 在日誌裡喊，探針不看 stderr 所以 15 章全綠）。
	#   載具是程序化建模的（Unit.spawn → _build_vehicle，根本不讀 model_path），
	#   拿角色模型表當存在性判準在語意上就是錯的。改用與玩家側同一條規則：
	#   類別是否為載具看 Unit.is_vehicle_cls（class_base.mobility），解鎖看 vehicle_unlock。
	var veh_n: int = int(dif.get("vehicles", 0))
	var veh_placed := 0
	var veh_spots: Array = []      # 已放好的載具落點，供最小間距檢查
	if veh_n > 0:
		var vpool: Array = []
		for vc in GameData.vehicle_unlock.keys():
			if int(GameData.vehicle_unlock[vc]) > maxi(chapter, 1):
				continue          # 未解鎖
			if not Unit.is_vehicle_cls(vc):
				push_error("[diff] vehicle_unlock 列了 %s，但 class_base 說它不是載具（mobility）" % vc)
				continue
			if String(GameData.class_base.get(vc, {}).get("domain", "land")) in map_data.get("allow", ["land"]):
				vpool.append(vc)
		if vpool.is_empty():
			push_error("[diff] 第 %d 章要出 %d 台敵方載具，但這張圖沒有任何已解鎖的載具可選"
					% [chapter, veh_n])
		# ⚠⚠ 2026-08-03：不可以照 vehicle_unlock 的鍵序取。
		#   每章只出 1~3 台，照鍵序等於永遠只取到前三種（tank/fighter/attacker），
		#   **四種軍艦一次都沒上場過**——連 ch09「海峽封鎖線」（allow=['sea','air']、
		#   劇本設定就是海上封鎖）出的都是兩架飛機。戰場上有什麼，該由**地圖的作戰域**
		#   決定，不是由資料檔的鍵順序決定。改成依 domain 分組後輪流取（陸→海→空），
		#   海圖至少會有一艘船，陸海空混合圖三種都看得到。
		var by_dom := {}
		for vc3 in vpool:
			var dm3: String = String(GameData.class_base.get(vc3, {}).get("domain", "land"))
			if not by_dom.has(dm3):
				by_dom[dm3] = []
			(by_dom[dm3] as Array).append(vc3)
		var doms: Array = []
		for dm4 in map_data.get("allow", ["land"]):
			if by_dom.has(dm4):
				doms.append(dm4)
		if doms.is_empty():
			doms = by_dom.keys()
		print("[diff] 敵方載具池：%s（依作戰域輪流取：%s）" % [str(by_dom), str(doms)])
		for k in veh_n:
			if vpool.is_empty():
				break
			var dm5: String = String(doms[k % doms.size()])
			var dlist: Array = by_dom[dm5]
			var vc2: String = String(dlist[int(k / doms.size()) % dlist.size()])
			# ⚠ 載具**不可以**沿用步兵的 55px(2.75m) 網格：車長 6.2m、車寬 3.1m，
			#   相鄰兩台一定互穿（鐵律①固體不可互穿）。載具自己一排、間距 150px=7.5m，
			#   並沿部署區底邊排開，避免壓在步兵網格上。
			var vx: float = zone.get("x", 560) + 40 + float(veh_placed) * 150.0
			var vy: float = zone.get("y", 250) + float(zone.get("h", 200)) - 40.0
			# ⚠ 落點必須對該載具的 mobility 合法：ch09/10/13/15 的池子含軍艦，
			#   固定點很可能在陸地上＝軍艦上陸（鐵律 0①，MobilityProbe 會抓）。
			#   反之坦克不能生在深水裡。問 terrain.move_cost 這個單一真相來源。
			var spot = _veh_spawn_spot(vc2, Vector2(vx, vy), veh_spots)
			# ⚠ 找不到位置時**換一台放得下的**，不要就這樣少一台（2026-08-02）：
			#   stress ch10 實測「要 2 台、只生成 1 台」——那張圖敵方部署區附近沒有
			#   夠深的水，驅逐艦無處可放。硬把軍艦塞到 50m 外不合理（敵軍該在自己那側），
			#   改成退而求其次挑池子裡放得下的另一種載具，數量仍照難度表。
			#   全都放不下才是真的該喊。
			if spot == null:
				# ⚠ 退路要**先試同作戰域裡比較小的**，不可以直接跳到別的域（2026-08-03）：
				#   ch13 的 18m 驅逐艦塞不進西岸那條水道，舊寫法照 vpool 順序第一個
				#   就是坦克 → 海圖上的海軍名額被陸軍吃掉。10m 的飛彈快艇其實放得下。
				var alts: Array = vpool.duplicate()
				var dom_of_vc: String = String(GameData.class_base.get(vc2, {}).get("domain", "land"))
				alts.sort_custom(func(a, b):
					var da: bool = String(GameData.class_base.get(a, {}).get("domain", "land")) == dom_of_vc
					var db: bool = String(GameData.class_base.get(b, {}).get("domain", "land")) == dom_of_vc
					if da != db:
						return da            # 同域優先
					return _veh_half(a).x < _veh_half(b).x)   # 再來由小到大
				for alt in alts:
					if alt == vc2:
						continue
					var alt_spot = _veh_spawn_spot(alt, Vector2(vx, vy), veh_spots)
					if alt_spot != null:
						print("[diff] %s 在這張圖沒有合法落點，改放 %s" % [vc2, alt])
						vc2 = alt
						spot = alt_spot
						break
			if spot == null:
				push_error("[diff] 第 %d 章找不到 %s 的合法生成點，池子裡也沒有替代載具放得下（pool=%s）"
						% [maxi(chapter, 1), vc2, str(vpool)])
				continue
			var sp: Vector2 = spot
			_spawn_unit(vc2, es, sp.x, sp.y, false)
			# 記下實際半長：下一台要用「兩台半長之和」算間距（船比車長得多）
			veh_spots.append({"p": sp, "hl": _veh_half(vc2).x})
			veh_placed += 1
			placed_e += 1
	# ⚠ 這行以前印的是 veh_n（**意圖**值），於是「敵載具 1」看起來一切正常、
	#   實際生成 0 台——同一個「設定看起來有、玩起來沒有」的坑印在日誌上還騙了人一次。
	#   改印實際生成數，並在兩者不符時大聲喊。
	if veh_placed != veh_n:
		push_error("[diff] 第 %d 章敵載具要 %d 台、實際只生成 %d 台"
				% [maxi(chapter, 1), veh_n, veh_placed])
	print("[diff] 第 %d 章：敵步兵 %d、敵載具 %d/%d（實際/難度表）、掩體 %.2f 集火 %.2f 側翼 %.2f 地形 %.2f"
			% [maxi(chapter, 1), count, veh_placed, veh_n, float(dif.get("cover", 0.0)),
			float(dif.get("focus", 0.0)), float(dif.get("flank", 0.0)),
			float(dif.get("terrain", 0.0))])

# 替敵方載具找一個「對它的 mobility 合法」的落點（2026-08-02 新增）。
# 為什麼需要這支：敵載具接回去之後，落點合不合法就成了真問題——
#   ・軍艦（naval）在陸地上＝鐵律 0① 違規，MobilityProbe 會抓（terrain_mobility 的
#     ground 欄對 naval 是 null＝不可通行）
#   ・坦克（tracked）落在深水裡同理
# 不自己判斷「這裡是海嗎」，而是問 terrain.move_cost 這個單一真相來源，
# 免得又出現「同一條規則兩份實作」（本專案已因此誤判過一次）。
# 從想要的點開始環形外擴，回傳第一個同時滿足「地形可通行」「與已放載具距離足夠」
# 「在地圖內」的點；找不到回 null（呼叫端會 push_error，不靜默跳過）。
func _veh_spawn_spot(cls: String, want: Vector2, taken: Array):
	var mob: String = String(GameData.class_base.get(cls, {}).get("mobility", "tracked"))
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	var half: Vector2 = _veh_half(cls)      # ★實際尺寸，不是坦克常數（見 _veh_half）
	var margin := 40.0              # 離地圖邊界的安全距離（邊界卡人的老坑）
	# 環形外擴：先試原點，再一圈圈往外找。40px=2m 一階。
	# ⚠⚠ 2026-08-03：軍艦要找**遠**得多（先前上限 24m，ch09 海圖因此一艘船都放不下，
	#   全部退回戰鬥機＝四種軍艦從來沒上場過）。軍艦本來就在外海，不會停在
	#   步兵部署區旁邊 24m 內——搜尋半徑對海軍放到 80m。
	#   但**不可以生到玩家背後**：加一條「必須與 want 在地圖中心的同一側」。
	var naval: bool = mob == "naval"
	# 找不到落點時要說得出「是哪一關卡掉的」——靜默失敗在本專案已造成三次假通過
	var rej_side := 0
	var rej_near := 0
	var rej_terr := 0
	var rej_fit := 0
	var rej_clash := 0
	var rings: int = 41 if naval else 13
	var ctr := Vector2(mw * 0.5, mh * 0.5)
	# ⚠ 「同側」對某些地圖是死路：ch13 的海在**西邊**、敵方部署區在東邊，
	#   於是同側規則把全部水面都排除了（實測剔除 63 個候選點全是水面）。
	#   改成兩段：先找同側，同側沒有就放寬到全圖，但**不可以生在玩家部署區 25m 內**
	#   （軍艦從玩家背後的海上包抄是合理戰術，貼在玩家腳邊生出來則不是）。
	var pl_zone: Dictionary = {}
	if map_data.has("deploy") and (map_data["deploy"] as Array).size() > 0:
		pl_zone = (map_data["deploy"] as Array)[player_side]
	var pl_c := Vector2(float(pl_zone.get("x", 0)) + float(pl_zone.get("w", 0)) * 0.5,
			float(pl_zone.get("y", 0)) + float(pl_zone.get("h", 0)) * 0.5)
	var pass_n: int = 2 if naval else 1
	for pass_i in pass_n:
		for ring in rings:
			var r: float = float(ring) * 40.0
			# ⚠ 取樣密度要隨半徑增加，否則「篩子的網目比水域還大」：
			#   固定 24 個點時，半徑 1600px 的圓周上兩點間隔 419px（21m），
			#   ch13 西岸那條水域就是這樣被整條漏掉的。固定成大約每 6m 一點。
			var steps: int = 1 if ring == 0 else clampi(int(TAU * r / 120.0), 12, 96)
			for s in steps:
				var ang: float = TAU * float(s) / float(steps)
				var p := want + Vector2(cos(ang), sin(ang)) * r
				p.x = clampf(p.x, margin, mw - margin)
				p.y = clampf(p.y, margin, mh - margin)
				if naval and pass_i == 0 and (p - ctr).dot(want - ctr) < 0.0:
					rej_side += 1
					continue            # 第一段：只找自己這一側
				if naval and pass_i == 1 and pl_c != Vector2.ZERO 					and p.distance_to(pl_c) < 25.0 / WORLD_SCALE:
					rej_near += 1
					continue            # 第二段：全圖都可以，但不可貼在玩家部署區旁
				if terrain != null and terrain.move_cost(p.x, p.y, mob) >= BattleTerrain.IMPASSABLE:
					rej_terr += 1
					continue            # 這種地形這台載具過不去
				# ★ 場地限制（2026-08-02 使用者：「戰車不會在巷子裡面出現」）：
				#   地形可通行不等於**塞得進去**。一台車 6.2m×3.5m，生在兩棟房子之間
				#   的窄巷、或緊貼牆與電線桿的夾角，都是不合理的畫面。
				#   車體不是一顆點：沿車軸取車尾／中心／車頭三處，各用車寬半徑問
				#   _resolve_solids（它已涵蓋建築牆、樹、電線桿、柵欄與其他載具）。
				#   任一處會被推開＝這個位置容不下這台車，換下一個候選點。
				if not _veh_fits(p, mob, cls):
					rej_fit += 1
					continue
				# 與已放好的載具保持距離：需要的間距是**兩台各自的半長之和**再加餘裕。
				# ⚠ 先前寫死 150px(7.5m)＝坦克尺寸，驅逐艦半長就有 9m，兩艘船照樣互穿。
				var clash := false
				for t in taken:
					var tp: Vector2 = t["p"]
					var need_px: float = (half.x + float(t["hl"]) + 1.5) / WORLD_SCALE
					if (p - tp).length() < need_px:
						clash = true
						break
				if clash:
					rej_clash += 1
					continue
				if _test_mode and r > 0.0:
					print("[diff] %s 落點外移 %.0fpx（%.0fm）找到合法地形（mob=%s%s）"
							% [cls, r, r * WORLD_SCALE, mob,
							"、放寬到全圖" if naval and pass_i == 1 else ""])
				return p
	# 找不到要說清楚為什麼，不可以靜默失敗（本專案已因靜默跳過造成三次假通過）
	if _test_mode:
		print("[diff] %s 在 %.0fm 內找不到合法落點（mob=%s、半長 %.1fm）"
				% [cls, float(rings) * 40.0 * WORLD_SCALE, mob, half.x]
				+ "　剔除：同側 %d、離玩家太近 %d、地形不可通行 %d、塞不下 %d、與其他載具太近 %d"
				% [rej_side, rej_near, rej_terr, rej_fit, rej_clash])
	return null

# 這個位置容得下一台車嗎（場地限制／不准生在巷子裡）。
# 車體不是一顆點：沿車軸取車尾／中心／車頭三處，各以車寬半徑問 _resolve_solids
# （已涵蓋建築牆、樹、電線桿、柵欄與其他載具）。任一處被推開就是塞不進去。
# 生成時載具一律朝 ±z（_spawn_unit 設 rotation.y = 0 或 PI），所以車軸＝y(px) 方向。
# 空中載具不受地面淨空限制——它在 100m 高，底下有沒有巷子無關。
# 替步兵找一個「人站得住」的落點（2026-08-02）。判準與載具同源，只是換成
# 人的尺度：mobility=foot 的地形成本 ＋ 人的半徑不被實體推開。
# ⚠ 用 _settle 而不是只問 _resolve_solids：這個專案的「站得住」定義是
#   「解算與夾限同時成立」，走查判準也用同一支——同一條規則只能有一份實作。
func _inf_spawn_spot(want: Vector2):
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	var margin := 40.0
	# 25px=1.25m 一階，最多找到 500px=25m 外（部署區本身通常就這個量級）
	for ring in 21:
		var r: float = float(ring) * 25.0
		var steps: int = 1 if ring == 0 else 10
		for s in steps:
			var ang: float = TAU * float(s) / float(steps)
			var p := want + Vector2(cos(ang), sin(ang)) * r
			p.x = clampf(p.x, margin, mw - margin)
			p.y = clampf(p.y, margin, mh - margin)
			if terrain != null and terrain.move_cost(p.x, p.y, "foot") >= BattleTerrain.IMPASSABLE:
				continue          # 深水／不可通行：人不能站在這裡
			var q3: Vector3 = _to3d(p.x, p.y)
			var fixed: Vector3 = _resolve_solids(q3, BODY_R, null)
			if Vector2(fixed.x - q3.x, fixed.z - q3.z).length() > 0.05:
				continue          # 會被實體推開＝站在牆／障礙裡
			# ★★也要離已經站好的人夠遠（2026-08-02）：少了這條，海圖上可站立的
			#   陸地很窄，8 個步兵會全被塞進同一小塊合法區、彼此重疊，接著被解算
			#   互相推開 —— 一路推到水裡（stress ch09「陷進實體」2 筆的真正機制，
			#   夾限點 y=1338 正好是 _clamp_to_map 的距邊 1m）。
			#   兩個人不可能站在同一格：至少要兩個身體半徑。
			var too_close := false
			for u in units:
				if not u["alive"] or not is_instance_valid(u["node"]):
					continue
				var gap_m: float = (Vector2(u["wx"], u["wy"]) - p).length() * WORLD_SCALE
				var need: float = BODY_R * 2.0 + 0.15
				if Unit.is_vehicle_cls(u["cls"]):
					need = _veh_half(u["cls"]).x + BODY_R    # 別站在車體裡
				if gap_m < need:
					too_close = true
					break
			if too_close:
				continue
			return p
	return null

# 從資料讀該載具的碰撞半長／半寬（公尺）。生成前還沒有 Unit 實例，所以與
# Unit._try_build_from_art 讀**同一份**資料（vehicle_look），不可寫死坦克常數：
# ⚠⚠ 驅逐艦半長 9m、登陸艦 7m、潛艇 7.5m，坦克只有 3m。用坦克常數去檢查船，
#   等於 18m 的船只檢查了中間 6m —— 這正是本專案「驅逐艦畫 18m 卻用 6m 碰撞盒」
#   那個坑的變體，只是換到了生成階段（stress ch09/ch10 各 2 筆「陷進實體」）。
func _veh_half(cls: String) -> Vector2:
	var vl = GameData.vehicle_look.get(cls, {})
	if not (vl is Dictionary):
		return Vector2(VEHICLE_HL, VEHICLE_HW)
	var hl: float = float(vl.get("collide_hl", float(vl.get("length_m", 6.2)) * 0.5))
	var hw: float = float(vl.get("collide_hw", VEHICLE_HW))
	return Vector2(hl, hw)

func _veh_fits(p: Vector2, mob: String, cls := "") -> bool:
	if mob == "air":
		return true
	var half: Vector2 = _veh_half(cls) if cls != "" else Vector2(VEHICLE_HL, VEHICLE_HW)
	# ★★已經站在那裡的人也算障礙（2026-08-02，stress ch09/ch10 各 2 筆「陷進實體」）：
	#   步兵先部署、載具後生成，而步兵**不在 _blockers 裡**（它們是 units），
	#   所以 _resolve_solids 看不到他們 → 坦克／軍艦直接生在人身上，
	#   那個人就永遠陷在鋼板裡（鐵律 0①固體不可互穿）。
	#   車體矩形 ＋ 人的半徑：距離不足就是壓到人。
	for u in units:
		if not u["alive"] or not is_instance_valid(u["node"]):
			continue
		if Unit.is_vehicle_cls(u["cls"]):
			continue          # 載具之間的間距由呼叫端的 taken 清單負責
		var d: Vector2 = (Vector2(u["wx"], u["wy"]) - p) * WORLD_SCALE   # 換成公尺
		# 生成時車軸沿 y(px)，所以 y＝沿車長、x＝沿車寬
		if absf(d.y) < half.x + BODY_R and absf(d.x) < half.y + BODY_R:
			return false
	var hl_px: float = half.x / WORLD_SCALE
	for f in [-0.65, 0.0, 0.65]:
		var q := Vector2(p.x, p.y + hl_px * f)
		var q3: Vector3 = _to3d(q.x, q.y)
		var fixed: Vector3 = _resolve_solids(q3, half.y, null)
		if Vector2(fixed.x - q3.x, fixed.z - q3.z).length() > 0.05:
			return false
	return true

func _start_battle() -> void:
	if _count_side(player_side) == 0:
		return
	st = St.CMD
	turn = 1
	cp = _turn_cp()
	if is_instance_valid(_zone_mesh):
		_zone_mesh.visible = false        # 開戰後收起部署藍框
	ui.show_hud()
	ui.show_minimap(func(): return _minimap_data())
	ui.update_hud(turn, "player", cp, _hud_wx())
	_refresh_visibility()
	# 相機框住我方部隊重心
	var c := Vector3.ZERO
	var n := 0
	for u in units:
		if u["side"] == player_side and u["alive"]:
			c += u["node"].global_position
			n += 1
	if n > 0:
		cam.focus = c / n
		cam.dist = 16.0

# ---------- 單位 ----------
func _spawn_unit(cls: String, side_i: int, wx: float, wy: float, named: bool):
	# 戰場＝3D 動畫身體（VC 做法，立繪只留 UI）；player 藍環自然色、enemy 紅環紅疊色。
	# 我方英雄優先用「立繪轉 3D」本人模型（tripo），敵軍/無此模型者用通用兵。
	var mp: String = CLASS_MODEL.get(cls, "res://assets/models/chars/soldier.glb")
	if side_i == player_side and HERO_MODEL.has(cls):
		mp = HERO_MODEL[cls]
	# 外觀 v2（GDD/06）：資料層可覆寫基底。敵我分池——敵軍查 enemy_look
	# （只用 hr_soldier/hr_swat），我方查 char_look（九人各佔一顆），永不同款。
	var lk2: Dictionary = GameData.char_look.get(cls, {}) if side_i == player_side \
			else GameData.enemy_look.get(cls, {})
	if lk2.has("base"):
		if ResourceLoader.exists(String(lk2["base"])):
			mp = String(lk2["base"])
		else:
			# 覆寫指到不存在的資源要大聲喊——靜默退回舊款＝敵我同款悄悄復活
			print("[look] FAIL 基底不存在：%s（cls=%s side=%d），退回 %s"
					% [String(lk2["base"]), cls, side_i, mp])
	if _test_mode:
		print("[look] spawn %s side=%d player_side=%d mp=%s" % [cls, side_i, player_side, mp])
	var node := Unit.spawn(mp, cls, side_i, side_i == player_side)
	add_child(node)
	node.position = _to3d(wx, wy)
	node.rotation.y = 0.0 if side_i == 0 else PI
	node.shot_fired.connect(_on_shot)
	# 生成點若壓在牆上／護欄上就先推出去：兵不該從實體裡冒出來
	if not _buildings.is_empty() or not _blockers.is_empty():
		var fx: Vector3 = _resolve_solids(node.global_position,
				VEHICLE_R if Unit.is_vehicle_cls(cls) else BODY_R, null)
		node.global_position = Vector3(fx.x, node.global_position.y, fx.z)
	# 抵達目的地才重算掩體：原本玩家移動後從沒更新過 cover，
	# 走到沙包後面也不會蹲下、迎擊減傷也算不到（2026-07-25 補齊全動作時發現）。
	node.arrived.connect(func(): _on_unit_arrived(node))
	var cb: Dictionary = GameData.class_base.get(cls, {})
	var chr: Dictionary = GameData.characters.get(cls, {}) if named else {}
	var hp: int = cb.get("hp", 100)
	var wpn: Dictionary = GameData.weapon_of(nation[side_i], cls)
	# 養成（GDD/16）：兵科等級套在出場屬性上——只有玩家側，敵軍不吃
	if side_i == player_side and _growth_unlocked():
		var glv: int = int(_growth["lv"].get(cls, 0))
		if glv > 0:
			var aw: Array = GameData.growth_apply(hp, wpn, glv)
			hp = aw[0]
			wpn = aw[1]
			print("[growth] %s Lv%d 出場 hp=%d acc=%.2f atk=%d"
					% [cls, glv, hp, wpn.get("acc", 0.0), wpn.get("atk", 0)])
	var u := {
		"cls": cls, "side": side_i, "node": node, "wx": wx, "wy": wy,
		"hp": hp, "maxhp": hp, "alive": true,
		"weapon": wpn,
		"named": named, "char_name": chr.get("name", ""),
		"acted": false, "cover": "",
		"orders": 0, "ap": 0.0, "ap_max": float(cb.get("ap", 150)), "fired": false,
	}
	node.set_meta("u", u)
	units.append(u)
	return u

# 把世界座標夾回地圖範圍內：先前沒有這道夾限，單位可以一路走出地圖邊緣、
# 站在虛空上（坦克驗收時實拍到）。留 1m 邊界避免貼邊卡住。
func _clamp_to_map(p: Vector3) -> Vector3:
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	var hx: float = mw * 0.5 * WORLD_SCALE - 1.0
	var hz: float = mh * 0.5 * WORLD_SCALE - 1.0
	return Vector3(clampf(p.x, -hx, hx), p.y, clampf(p.z, -hz, hz))

# 遊戲 px → 3D 世界座標。y 一律取地形高度：地面不再是 y=0（GDD/14 §1）。
func _to3d(wx: float, wy: float) -> Vector3:
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	var y := 0.0
	if terrain != null:
		y = terrain.height_at_mesh(wx, wy)
	return Vector3((wx - mw * 0.5) * WORLD_SCALE, y, (wy - mh * 0.5) * WORLD_SCALE)

func _count_side(s: int) -> int:
	var n := 0
	for u in units:
		if u["alive"] and u["side"] == s:
			n += 1
	return n

# ---------- 迷霧（簡易：敵兵在我方視野內才顯示）----------
func _refresh_visibility() -> void:
	for u in units:
		if u["side"] == player_side:
			continue
		var vis := false
		for p in units:
			if p["side"] != player_side or not p["alive"]:
				continue
			# 視野半徑改讀資料（鐵律 3）：class_base.json 每個兵種都寫了 sight
			# （偵察兵 170、機槍兵 120…），先前全專案寫死 200，兵種差異等於不存在。
			var sight: float = float(GameData.class_base.get(p["cls"], {}).get("sight", SIGHT))
			# 視野扇形（鐵律 0：人看不到背後）。正前 ±60 度全視距，
			# 側面砍到 0.55、背後只剩 0.3 的近距離察覺（餘光與聽覺）。
			if is_instance_valid(p["node"]):
				var pf: Vector3 = p["node"].facing_dir()
				var pv := Vector3(float(u["wx"]) - float(p["wx"]), 0.0,
						float(u["wy"]) - float(p["wy"]))
				if pv.length() > 0.01:
					var adeg: float = rad_to_deg(acos(clampf(pf.dot(pv.normalized()), -1.0, 1.0)))
					sight *= (1.0 if adeg <= 60.0 else (0.55 if adeg <= 110.0 else 0.3))
			sight *= weather_sight_mul() * _light_sight_mul()   # 雨雪與光線都壓低能見度
			for c in _covers:
				if c["type"] == "bush" and Vector2(c["wx"] - u["wx"], c["wy"] - u["wy"]).length() <= c["r"]:
					# 草叢隱蔽（GDD/01 §5a）：蹲伏且尚未開火才真的藏得住（發現距離砍到 0.3）；
					# 站著或開過火只砍一半——草叢不是隱形斗篷。
					var hiding: bool = is_instance_valid(u["node"]) and u["node"]._crouch > 0.5 							and not bool(u.get("fired", false))
					sight = SIGHT * (0.3 if hiding else 0.5)
					break
			if Vector2(u["wx"] - p["wx"], u["wy"] - p["wy"]).length() > sight:
				continue
			# 視線被牆擋住就看不到（GDD/14 §3-3）：躲在屋裡的人只有從門窗的角度才會被發現——
			# 這是「進建築」在戰術上真正的價值，不然屋子只是一塊會擋子彈的裝飾。
			# ⚠ 這裡本來只吃 _los_clear（只有建築牆），所以躲在沙包、樹幹、殘骸後面
			#   等於站在空地上被看光。視線跟彈道吃同一份障礙，只是高度改用眼高。
			if not _sight_clear(p, u):
				continue
			vis = true
			break
		if u["alive"]:                    # 陣亡者交給 die() 淡出，別強制隱藏
			u["node"].visible = vis

# ---------- 輸入 ----------
func _unhandled_input(event: InputEvent) -> void:
	# 第三人稱：Esc 結束行動（同時放開滑鼠），左鍵對準心開火
	if cam != null and cam.is_tps():
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_end_action()
			return
		# Tab：放開／鎖回滑鼠。放開後游標出現，可以直接用滑鼠點敵人、也點得到 UI。
		if event is InputEventKey and event.pressed and event.keycode == KEY_TAB:
			_capture_mouse(Input.mouse_mode != Input.MOUSE_MODE_CAPTURED)
			ui.flash_msg("滑鼠已" + ("鎖定（Tab 放開）" if Input.mouse_mode
					== Input.MOUSE_MODE_CAPTURED else "放開（可點敵人，Tab 鎖回）"),
					Color(0.7, 0.9, 1.0))
			return
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			if ui.fire_panel_open():
				return
			var tgt = _tps_target((event as InputEventMouseButton).position)
			if tgt == null:
				ui.flash_msg("準心沒有對到敵人", Color(1.0, 0.8, 0.5))
				return
			if acting == null or bool(acting.get("fired", false)):
				ui.flash_msg("這次行動已經開過火了", Color(1.0, 0.7, 0.4))
				return
			var dpx := Vector2(tgt["wx"] - acting["wx"], tgt["wy"] - acting["wy"]).length()
			if dpx > float(acting["weapon"].get("range", 200)):
				ui.flash_msg("超出射程", Color(1.0, 0.7, 0.4))
				return
			# 彈道被實體遮住就不能開火（GDD/14 §2）：先前只有建築牆會擋，
			# 沙包／樹／殘骸／坦克在中間也照打，玩家看到的就是子彈穿過去。
			if not _any_part_clear(acting, tgt):
				ui.flash_msg("彈道被遮蔽，換位置或站起來", Color(1.0, 0.7, 0.4))
				return
			var sh2 = acting
			_capture_mouse(false)          # 選部位要用游標
			ui.show_fire_panel(_fire_preview(sh2, tgt), func(part):
				ui.hide_fire_panel()
				if part != "" and acting == sh2 and not bool(sh2.get("fired", false)):
					_fire(sh2, tgt, part)
				# ⚠ 開完火不可以把滑鼠鎖回去（2026-07-27 使用者：鎖住就點不到「結束行動」）
				)
			return
		return
	# 指令模式：Tab／N＝切換到下一個我方單位並把鏡頭帶過去。
	# 使用者 2026-07-27 回報「畫面外的角色點不到」——戰術鏡頭只能拖曳，
	# 走出畫面的隊友等於失聯。切換只做「選取＋鏡頭跟隨」，不花 CP；
	# 要下令仍然是點他（維持「點兵＝花 1 CP」的規則不被誤觸消耗）。
	if st == St.CMD and event is InputEventKey and event.pressed and not event.echo 			and (event.keycode == KEY_TAB or event.keycode == KEY_N):
		_cycle_unit()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if st == St.CMD:
			_click(event.position)
		elif st == St.DEPLOY:
			_deploy_click(event.position)

# 切換到下一個我方存活單位（依部署順序輪替），鏡頭跟過去並顯示角色卡。
func _cycle_unit() -> void:
	var mine: Array = []
	for u in units:
		if u["side"] == player_side and u["alive"] and is_instance_valid(u["node"]):
			mine.append(u)
	if mine.is_empty():
		ui.flash_msg("沒有可切換的單位", Color(1.0, 0.8, 0.4))
		return
	var idx := mine.find(selected)
	var nxt = mine[(idx + 1) % mine.size()] if idx >= 0 else mine[0]
	selected = nxt
	cam.set_follow(nxt["node"])
	var chr: Dictionary = GameData.characters.get(nxt["cls"], {})
	ui.show_charcard(nxt["cls"],
			("★" + nxt["char_name"]) if nxt["named"] else GameData.class_base.get(nxt["cls"], {}).get("zh", nxt["cls"]),
			chr.get("trait", {}).get("desc", ""), int(nxt["hp"]), int(nxt["maxhp"]))
	ui.flash_msg("切換單位（Tab/N）：%d / %d　點他即可下令"
			% [mine.find(nxt) + 1, mine.size()], Color(0.7, 0.9, 1.0))

func _deploy_click(sp: Vector2) -> void:
	if _pending_cls == "":
		return
	var from := cam.project_ray_origin(sp)
	var dir := cam.project_ray_normal(sp)
	if abs(dir.y) < 0.0001:
		return
	var t := -from.y / dir.y
	if t <= 0:
		return
	var hit := from + dir * t
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	var wx: float = hit.x / WORLD_SCALE + mw * 0.5
	var wy: float = hit.z / WORLD_SCALE + mh * 0.5
	# 限制在我方部署藍框內
	var z := _my_zone()
	wx = clamp(wx, z.get("x", 0), z.get("x", 0) + z.get("w", 300))
	wy = clamp(wy, z.get("y", 0), z.get("y", 0) + z.get("h", 200))
	_try_place(wx, wy)

# 點到線段的距離（螢幕空間）
func _dist_to_seg(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var L2 := ab.length_squared()
	if L2 < 0.0001:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / L2, 0.0, 1.0)
	return p.distance_to(a + ab * t)

func _click(sp: Vector2) -> void:
	# 命中判定：點到「腳→頭」整條身體線段都算，門檻隨角色在螢幕上的大小縮放。
	# （治「固定 44px 對準胸口一點」在拉伸/縮放下選不到兵 → 等於不能移動）
	var best = null
	var best_d := 1e9
	for u in units:
		if not u["alive"] or not u["node"].visible:
			continue
		var foot := cam.unproject_position(u["node"].global_position)
		var head := cam.unproject_position(u["node"].global_position + Vector3(0, 1.85, 0))
		var d := _dist_to_seg(sp, foot, head)
		var tol: float = clampf(foot.distance_to(head) * 0.55, 34.0, 140.0)
		if d < tol and d < best_d:
			best_d = d
			best = u
	if best != null:
		if best["side"] == player_side:
			selected = best
			cam.set_follow(best["node"])
			# 點自己人＝下令進入行動模式（花 1 CP，坦克 2 CP）。GDD/01 §1
			if acting != best:
				if not _begin_action(best):
					ui.flash_msg("CP 不足，無法下令", Color(1.0, 0.7, 0.4))
			var chr: Dictionary = GameData.characters.get(best["cls"], {})
			var cv: String = best.get("cover", "")
			var cov_txt := ""
			match cv:
				"sandbag": cov_txt = "　🛡 沙包掩體 (命中-33%)"
				"building": cov_txt = "　🛡 建築掩體 (命中-45%)"
			ui.show_charcard(best["cls"], ("★" + best["char_name"]) if best["named"] else GameData.class_base.get(best["cls"], {}).get("zh", best["cls"]),
					chr.get("trait", {}).get("desc", "") + cov_txt, int(best["hp"]), int(best["maxhp"]))
		elif acting != null and not bool(acting.get("fired", false)):
			# 先給預測再開火（GDD/13）：玩家要看得到命中率與傷害，還能選部位
			var sh = acting
			var tg = best
			var dpx := Vector2(tg["wx"] - sh["wx"], tg["wy"] - sh["wy"]).length()
			if dpx > float(sh["weapon"].get("range", 200)):
				ui.flash_msg("超出射程", Color(1.0, 0.7, 0.4))
				return
			# 彈道被實體遮住就不能開火（GDD/14 §2）：先前只有建築牆會擋，
			# 沙包／樹／殘骸／坦克在中間也照打，玩家看到的就是子彈穿過去。
			if not _any_part_clear(sh, tg):
				ui.flash_msg("彈道被遮蔽，換位置或站起來", Color(1.0, 0.7, 0.4))
				return
			ui.show_fire_panel(_fire_preview(sh, tg), func(part):
				ui.hide_fire_panel()
				if part != "" and acting == sh and not bool(sh.get("fired", false)):
					_fire(sh, tg, part))
		elif acting != null:
			ui.flash_msg("這次行動已經開過火了", Color(1.0, 0.7, 0.4))
		return
	# 點地移動：只有行動模式中的單位能動，且距離受剩餘 AP 限制
	if acting == null:
		return
	var from := cam.project_ray_origin(sp)
	var dir := cam.project_ray_normal(sp)
	if abs(dir.y) < 0.0001:
		return
	var t := -from.y / dir.y
	if t <= 0:
		return
	var hit := from + dir * t
	if terrain != null:
		var gy: float = terrain.height_at_world(hit)
		if absf(dir.y) > 0.0001:
			hit = from + dir * ((gy - from.y) / dir.y)     # 依地形高度重新求交
			hit.y = terrain.height_at_world(hit)
	var here: Vector3 = acting["node"].global_position
	var to := hit - here
	to.y = 0.0
	# 上限跟著方向走（含地形成本），跟畫在地上的圈是同一套算法
	var reach: float = _ap_reach_dir(acting, to)
	if reach < 0.05:
		ui.flash_msg("AP 用盡，只能原地開火或結束行動", Color(1.0, 0.7, 0.4))
		return
	if to.length() > reach:
		hit = here + to.normalized() * reach
	acting["node"].move_to(_clamp_to_map(hit))
	_refresh_visibility()

# 開火（part＝瞄準部位，GDD/01 §4）。AI 與迎擊一律 body（不瞄部位）。
func _fire(shooter, target, part := "body") -> void:
	var dist_px := Vector2(target["wx"] - shooter["wx"], target["wy"] - shooter["wy"]).length()
	# 測試模式印出「誰打誰」：先前日誌只看得到 HP 在掉，看不出**哪個兵種真的開過火**。
	# 新兵種上場時這條特別重要——武裝無人機的存在意義就是「能攻擊人」，
	# 沒有這一行就只能靠 HP 數字猜（靜默通過在本專案已造成三次假通過）。
	if _test_mode:
		print("[fire] %s(%s) → %s(%s) 距離 %.1fm"
				% [String(shooter["cls"]), "我方" if shooter["side"] == player_side else "敵方",
				String(target["cls"]), "我方" if target["side"] == player_side else "敵方",
				dist_px * WORLD_SCALE])
	shooter["node"].shoot_at(target["node"])
	shooter["fired"] = true      # 每次行動只能開火一次；CP 在下令時就扣過了（GDD/01 §1-2）
	ui.update_hud(turn, "player" if st == St.CMD else "enemy", cp, _hud_wx())
	await get_tree().create_timer(0.32).timeout
	if not shooter["alive"] or not target["alive"]:
		return
	# 彈道被實體吃掉＝這一槍打在障礙上（AI 與第三人稱自由射擊都會走到這裡）
	if not _shot_clear_units(shooter, target, part):
		# 打在掩體上也要有聲音——玩家要聽得出「這一槍沒過去」
		var imp: Vector3 = _mid3(shooter, target)
		Audio.impact("dirt", imp)
		_bullet_mark(imp)
		if shooter["side"] == player_side:
			ui.flash_msg("子彈打在掩體上", Color(0.9, 0.8, 0.6))
		_refresh_visibility()
		return
	# 掩體修正（Phase2）：方向性遮蔽最多削 60% 命中
	var cov: float = cover_at(target["wx"], target["wy"], shooter["wx"], shooter["wy"])
	var hc: float = GameData.hit_chance(_wrap(shooter), _wrap(target), dist_px, part) * (1.0 - cov * 0.6)
	hc *= pow(0.7, float(_pen_count(_live_px(shooter), _live_px(target),
			shooter["node"].muzzle_height() if not Unit.is_vehicle_cls(shooter["cls"]) else 1.9,
			target["node"].torso_height() if not Unit.is_vehicle_cls(target["cls"]) else 1.4)))
	if hc > randf():
		Audio.impact("metal" if Unit.is_vehicle_cls(target["cls"]) else "wood",
				target["node"].global_position + Vector3(0, 1.0, 0))
		target["hp"] -= GameData.damage(_wrap(shooter), _wrap(target), part)
		_sync_hp(target)
		if part != "body":
			ui.flash_msg("命中%s！" % ("頭部" if part == "head" else "散熱器"), Color(1.0, 0.9, 0.4))
		if target["hp"] <= 0 and target["alive"]:
			target["alive"] = false
			target["node"].die()          # 淡出傾倒後自我移除
		elif target["alive"]:
			target["node"].take_hit()     # 受擊：立繪換 hurt 表情＋紅閃
	_splash(shooter, target)
	_hear_shot(shooter)
	_refresh_visibility()
	_check_end()

# 範圍傷害（GDD/01 §4）。⚠ `data/weapons.json` 早就寫了 splash（迫砲 36、火箭 24、
# 主砲 30），但**從來沒有被讀過**——迫砲打過去只傷一個人，跟步槍沒有差別。
# 現實裡 60mm 迫砲彈殺傷半徑十幾公尺，範圍就是這類武器存在的理由。
# 命中與否都會爆（沒中就是落在附近），線性衰減到邊緣為 0，掩體照樣減傷。
# 把血量比例同步到 Unit：受傷會拖慢移動、也會拉低命中（鐵律 0）。
func _sync_hp(u) -> void:
	if not is_instance_valid(u["node"]):
		return
	var hp_max: float = float(GameData.class_base.get(u["cls"], {}).get("hp", 100))
	u["node"].hp_ratio = clampf(float(u["hp"]) / maxf(hp_max, 1.0), 0.0, 1.0)

# 彈痕（GDD/15 G2）：打過的地方要留下痕跡。沒有彈痕的戰場，
# 打了十回合看起來還是全新的——使用者對場景的四條判準之一就是「使用痕跡」。
# 用小片深色四邊形貼在命中點，總數有上限（超過就回收最舊的），不會累積成效能問題。
const MARK_MAX := 48
var _marks: Array = []
func _bullet_mark(pos: Vector3) -> void:
	if pos == Vector3.ZERO or world == null:
		return
	var q := QuadMesh.new()
	q.size = Vector2(randf_range(0.10, 0.18), randf_range(0.10, 0.18))
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.06, 0.05, 0.05, 0.85)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.no_depth_test = false
	var mi := MeshInstance3D.new()
	mi.mesh = q
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(mi)
	mi.global_position = pos
	_marks.append(mi)
	while _marks.size() > MARK_MAX:
		var old = _marks.pop_front()
		if is_instance_valid(old):
			old.queue_free()

# 天候（GDD/15 H5）。資料驅動：maps.json 的 weather＝clear/rain/snow。
# ⚠ 不是只加特效：雨雪會壓低能見度、把地面弄濕變滑，這才是天候在戰術上的意義。
#   粒子跟著鏡頭走（只在鏡頭附近下雨），全圖鋪粒子是純浪費。
var weather := "clear"
var _weather_node: GPUParticles3D = null
var _fog_base := 0.012                    # 起霧前的環境霧密度（霧散要收回來）
var _water_mats: Array = []               # 水面材質（時段切換要重餵太陽/天空色）
var _tree_mats: Array = []                # 樹木材質（同上，背光透光的太陽方向）

# 把目前的太陽與天空色餵給所有需要的材質（開戰建置時與時段切換時各呼叫一次）。
# 不做這件事的話，黃昏轉夜後海面還在反射黃昏的天空（兩個世界各過各的時間）。
func _feed_env_uniforms() -> void:
	var sun_v := Vector3(0.45, 0.62, 0.64)
	var sun_c := Vector3(1.0, 0.95, 0.86)
	var sun_e := 1.2
	if _sun != null and is_instance_valid(_sun):
		sun_v = -_sun.global_transform.basis.z
		sun_c = Vector3(_sun.light_color.r, _sun.light_color.g, _sun.light_color.b)
		sun_e = _sun.light_energy
	var top_v = null
	var hor_v = null
	if _sky_mat != null:
		var tc = _sky_mat.get_shader_parameter("top_color")
		var hc = _sky_mat.get_shader_parameter("horizon_color")
		if tc != null: top_v = Vector3(tc.r, tc.g, tc.b)
		if hc != null: hor_v = Vector3(hc.r, hc.g, hc.b)
	for m in _water_mats:
		if not is_instance_valid(m):
			continue
		m.set_shader_parameter("sun_dir", sun_v)
		m.set_shader_parameter("sun_col", sun_c)
		m.set_shader_parameter("sun_energy", sun_e)
		if top_v != null: m.set_shader_parameter("sky_top", top_v)
		if hor_v != null: m.set_shader_parameter("sky_hor", hor_v)
	for m2 in _tree_mats:
		if is_instance_valid(m2):
			m2.set_shader_parameter("sun_dir", sun_v)
# 天色對能見度的影響（鐵律 0）：夜裡看不了那麼遠。
# 先前 sky 只影響畫面色調，戰術上完全沒有差別——夜戰跟白天一樣好打。
func _light_sight_mul() -> float:
	match String(map_data.get("sky", "day")):
		"night": return 0.45
		"dusk", "dawn": return 0.78
		_: return 1.0

func weather_sight_mul() -> float:
	# 查表（GDD/04 天候節）：視野/移動/命中/閃避同一張表，不再各寫各的數字
	return float(GameData.weather_fx(weather).get("sight", 1.0))

func weather_move_mul() -> float:
	return float(GameData.weather_fx(weather).get("move", 1.0))

# ---------- 回合時鐘與動態天氣（GDD/04 天候節；2026-07-28 使用者核定）----------
var clock_hour := 10.0          # 戰場時刻（開戰時由該圖 sky 決定）
var _hpt := 1.0                 # 每回合幾小時（story.json 每章可覆寫 "hpt"）
var _wrng := RandomNumberGenerator.new()

# HUD 右側的「時刻｜天氣」字串
func _hud_wx() -> String:
	return "%02d:00 %s" % [int(fposmod(clock_hour, 24.0)),
			String(GameData.weather_fx(weather).get("zh", ""))]

func _init_clock() -> void:
	var sky: String = String(map_data.get("sky", "day"))
	clock_hour = float(GameData.weather_sys.get("start_hour", {}).get(sky, 10))
	var ch: Dictionary = GameData.story[chapter - 1] if chapter > 0 else {}
	_hpt = float(ch.get("hpt", GameData.weather_sys.get("hpt_default", 1)))
	_wrng.seed = 20260728 + chapter * 97      # 每章固定：測試可重現

# 每回合結束時推進時間、擲天氣。時段跨界→換天色；天氣改變→重建粒子＋提示
func _advance_time_weather() -> void:
	if bool(map_data.get("weather_dyn", true)) == false:
		return
	var tod0: String = GameData.tod_for_hour(clock_hour)
	clock_hour += _hpt
	var tod1: String = GameData.tod_for_hour(clock_hour)
	if tod1 != tod0:
		_apply_sky(tod1)
		_feed_env_uniforms()
		ui.flash_msg("時刻 %02d:00——%s" % [int(fposmod(clock_hour, 24.0)),
				{"dawn": "天亮了", "day": "日上三竿", "dusk": "暮色四合", "night": "夜幕降臨"}.get(tod1, "")],
				Color(0.95, 0.88, 0.6))
	if terrain == null:
		return
	var wn: String = GameData.weather_next(String(terrain.biome.get("key", "grass")), weather, _wrng)
	if wn != weather:
		_apply_weather_change(wn)

func _apply_weather_change(wn: String) -> void:
	if _weather_node != null and is_instance_valid(_weather_node):
		_weather_node.queue_free()
		_weather_node = null
	# 霧散時把環境霧收回基準值（_build_weather 起霧時會抬高）
	if _env != null and weather == "fog" and wn != "fog":
		_env.fog_density = _fog_base
	weather = wn
	map_data["weather"] = wn        # _build_weather 讀 map_data；保持單一入口
	_build_weather()
	_refresh_visibility()           # 能見度變了，迷霧要重算
	var zh: String = String(GameData.weather_fx(wn).get("zh", wn))
	ui.flash_msg("天氣轉變：%s" % zh, Color(0.7, 0.85, 1.0))
	print("[weather] 回合 %d %02d:00 → %s" % [turn, int(fposmod(clock_hour, 24.0)), zh])

# 天候渲染（2026-07-28 使用者：「沙漠為什麼會下雨」）。
# ⚠ 舊版是二分法：不是雪就畫雨——於是 sand（沙暴）與 fog（霧）都在下雨。
#   資料層一直是對的（ch05=sand、ch09/10=fog），是渲染層把三種天氣畫成同一種。
#   每種天氣照物理各給各的：雨＝直落水條、雪＝慢飄小片、沙＝橫飛沙塵、霧＝環境霧（不是粒子）。
func _build_weather() -> void:
	weather = String(map_data.get("weather", "clear"))
	if world == null or weather == "clear":
		return
	_init_clock()
	if weather == "fog":
		# 霧不是粒子——粒子做的霧只會像「下白點」。霧走環境層。
		if _env != null:
			_env.fog_enabled = true
			_fog_base = _env.fog_density
			_env.fog_density = maxf(_env.fog_density, 0.035)
		return
	var pm := ParticleProcessMaterial.new()
	var qm := QuadMesh.new()
	var mat := StandardMaterial3D.new()
	var ps := GPUParticles3D.new()
	match weather:
		"snow":
			pm.direction = Vector3(0.12, -1, 0.08)
			pm.spread = 22.0
			pm.initial_velocity_min = 1.1
			pm.initial_velocity_max = 2.0
			pm.gravity = Vector3(0.6, -0.4, 0.4)
			qm.size = Vector2(0.06, 0.06)
			mat.albedo_color = Color(1, 1, 1, 0.85)
			ps.amount = 520
			ps.lifetime = 5.0
		"sand":
			# 沙暴：沙是被風「吹著走」的，不是掉下來的——主速度水平、
			# 微微下沉，色帶沙黃半透明；密度高、速度快才有「暴」的壓迫感
			pm.direction = Vector3(-1.0, -0.10, 0.18)
			pm.spread = 9.0
			pm.initial_velocity_min = 15.0
			pm.initial_velocity_max = 24.0
			pm.gravity = Vector3(-2.5, -0.5, 0.4)
			qm.size = Vector2(0.14, 0.02)          # 橫向速條（billboard 下讀成風痕）
			mat.albedo_color = Color(0.80, 0.68, 0.46, 0.30)
			ps.amount = 1200
			ps.lifetime = 1.1
		_:      # rain
			pm.direction = Vector3(0.12, -1, 0.08)
			pm.spread = 3.0
			pm.initial_velocity_min = 9.0
			pm.initial_velocity_max = 13.0
			pm.gravity = Vector3(0.6, -2.0, 0.4)
			qm.size = Vector2(0.02, 0.42)
			mat.albedo_color = Color(0.72, 0.78, 0.85, 0.42)
			ps.amount = 900
			ps.lifetime = 1.4
	pm.scale_min = 0.5
	pm.scale_max = 1.0
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(22, 1, 22) if weather != "sand" \
			else Vector3(30, 8, 30)                # 沙暴是一整層，不是頭頂一片
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qm.material = mat
	ps.process_material = pm
	ps.draw_pass_1 = qm
	ps.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ps.visibility_aabb = AABB(Vector3(-40, -30, -40), Vector3(80, 60, 80))
	world.add_child(ps)
	_weather_node = ps

func _weather_follow() -> void:
	if _weather_node == null or cam == null:
		return
	# 雨雪從鏡頭上方 14m 落下；沙暴是貼著地表吹的一整層，掛在鏡頭高度附近
	var wy: float = 3.0 if weather == "sand" else 14.0
	_weather_node.global_position = cam.global_position + Vector3(0, wy, 0)

# 火與煙（GDD/15 G3）。程式生成的粒子，不需要素材：
# 火＝往上飄的橘色小片（重力為負、隨高度變暗），煙＝更大更慢更暗、飄得更高。
# 再加一盞會閃的暖光，夜/黃昏下才有「那邊在燒」的感覺。
# 風向（資料驅動；沒寫就用固定微風）。
# ⚠ 彈道不吃風是**明文例外**：在核定的壓縮尺度下，20m 內側風造成的偏移是公釐級，
#   加進去只會讓命中率變成隨機噪音，不會讓遊戲更真實。
func _wind() -> Vector2:
	var w = map_data.get("wind", null)
	if w is Array and (w as Array).size() >= 2:
		return Vector2(float(w[0]), float(w[1]))
	return Vector2(0.4, 0.2)

# 柔邊圓形貼圖（程式生成，全場共用一張）。
# ★這是「火看起來很假」的第一名原因（使用者 2026-07-27）：粒子用的是**沒有貼圖的方片**，
#   不管顏色調得多好，畫面上每一顆都是一個硬邊的發光正方形＝發光方塊。
#   火與煙的形狀感幾乎全部來自「邊緣要柔」這件事。
static var _soft_tex: GradientTexture2D = null

static func _soft_dot() -> GradientTexture2D:
	if _soft_tex != null:
		return _soft_tex
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 64
	t.height = 64
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	_soft_tex = t
	return _soft_tex

static func _ramp(offsets: Array, cols: Array) -> GradientTexture1D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(offsets)
	g.colors = PackedColorArray(cols)
	var t := GradientTexture1D.new()
	t.gradient = g
	t.width = 64
	return t

static func _curve_tex(pts: Array) -> CurveTexture:
	var c := Curve.new()
	c.min_value = 0.0
	c.max_value = 1.0
	for p in pts:
		c.add_point(Vector2(float(p[0]), float(p[1])))
	var t := CurveTexture.new()
	t.curve = c
	return t

# 火與煙（2026-07-27 重做）。真實的火在畫面上讀得出來，靠的是四件事，缺一件就變成方塊：
#   ① 邊緣柔（柔邊圓貼圖）    ② 生命週期內變色（白熱→橘→暗紅→消失）
#   ③ 生命週期內變大小（火焰往上收細、煙往上擴散變大）  ④ 亂流（直線上升的是噴射口不是火）
# 另外**一定要有煙**：只有火沒有煙時，遠看只是一團亮點，讀不出「這裡在燒」。
func _add_fire(pos: Vector3, radius: float) -> void:
	if world == null:
		return
	# ⚠ 粒子數與燈的範圍都要克制：第一版（46+34 粒、燈半徑 12m、每幀改 energy）
	#   讓 16 單位的幀時從 5.8ms 掉到 11.9ms。火只是背景元素，不值這個價。
	var wind := _wind()
	# [粒數, 壽命, 尺寸, 初速, y 偏移, 散佈, 是否加法混合, 顏色帶, 尺寸曲線]
	var specs := [
		# 火焰：小而多、白熱底→橘→暗紅，往上收細
		{"n": 52, "life": 1.1, "sz": 0.55, "up": 2.8, "y": 0.0, "spread": radius * 0.55,
			"add": true, "grav": 0.25,
			"ramp": _ramp([0.0, 0.22, 0.62, 1.0], [
				Color(1.0, 0.95, 0.70, 0.95), Color(1.0, 0.62, 0.18, 0.85),
				Color(0.85, 0.22, 0.05, 0.45), Color(0.35, 0.06, 0.02, 0.0)]),
			"curve": _curve_tex([[0.0, 0.55], [0.35, 1.0], [1.0, 0.12]])},
		# 餘燼：偶爾飄出來的火星，火有生命感全靠這個
		{"n": 14, "life": 2.2, "sz": 0.075, "up": 3.4, "y": 0.3, "spread": radius * 0.5,
			"add": true, "grav": 0.10,
			"ramp": _ramp([0.0, 0.55, 1.0], [Color(1.0, 0.85, 0.45, 1.0),
				Color(1.0, 0.45, 0.12, 0.8), Color(0.6, 0.15, 0.03, 0.0)]),
			"curve": _curve_tex([[0.0, 1.0], [1.0, 0.25]])},
		# 濃煙：大而淡、往上擴散，被風帶著斜飄。煙柱是「遠處看得到這裡在燒」的唯一線索。
		{"n": 72, "life": 7.0, "sz": 3.0, "up": 2.6, "y": 1.2, "spread": radius * 0.85,
			"add": false, "grav": 0.75,
			"ramp": _ramp([0.0, 0.10, 0.45, 1.0], [
				Color(0.14, 0.12, 0.11, 0.0), Color(0.12, 0.11, 0.10, 0.88),
				Color(0.30, 0.29, 0.28, 0.52), Color(0.55, 0.54, 0.53, 0.0)]),
			"curve": _curve_tex([[0.0, 0.18], [1.0, 1.0]])},
	]
	for spec in specs:
		var pm := ParticleProcessMaterial.new()
		pm.direction = Vector3(0, 1, 0)
		pm.spread = 18.0
		pm.initial_velocity_min = float(spec["up"]) * 0.55
		pm.initial_velocity_max = float(spec["up"])
		# 風把火與煙帶著走；煙越輕、被帶得越明顯
		var wk: float = 2.2 if not bool(spec["add"]) else 1.0
		pm.gravity = Vector3(wind.x * wk, float(spec["grav"]), wind.y * wk)
		pm.scale_min = float(spec["sz"]) * 0.55
		pm.scale_max = float(spec["sz"])
		pm.scale_curve = spec["curve"]
		pm.color_ramp = spec["ramp"]
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		pm.emission_sphere_radius = float(spec["spread"])
		# 亂流：少了它，粒子沿直線上升，看起來像蒸汽噴嘴而不是火
		pm.turbulence_enabled = true
		pm.turbulence_noise_strength = 0.55 if bool(spec["add"]) else 1.1
		pm.turbulence_noise_scale = 2.4
		pm.angle_min = -180.0
		pm.angle_max = 180.0
		pm.angular_velocity_min = -35.0
		pm.angular_velocity_max = 35.0
		var qm := QuadMesh.new()
		qm.size = Vector2.ONE
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = (BaseMaterial3D.BLEND_MODE_ADD if bool(spec["add"])
				else BaseMaterial3D.BLEND_MODE_MIX)
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		mat.billboard_keep_scale = true
		mat.vertex_color_use_as_albedo = true
		mat.albedo_texture = _soft_dot()          # ★柔邊：治「發光方塊」
		mat.disable_receive_shadows = true
		qm.material = mat
		var ps := GPUParticles3D.new()
		ps.amount = int(spec["n"])
		ps.lifetime = float(spec["life"])
		ps.process_material = pm
		ps.draw_pass_1 = qm
		ps.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# 明確給可見範圍，否則引擎每幀要重算粒子包圍盒。煙柱會飄很高，盒子要夠大。
		ps.visibility_aabb = AABB(Vector3(-10, -2, -10), Vector3(20, 30, 20))
		world.add_child(ps)
		ps.global_position = pos + Vector3(0, float(spec["y"]), 0)
	var fl := OmniLight3D.new()
	fl.light_color = Color(1.0, 0.6, 0.25)
	fl.light_energy = 2.0
	fl.omni_range = minf(radius * 3.2, 6.0)
	fl.shadow_enabled = false
	world.add_child(fl)
	fl.global_position = pos + Vector3(0, 0.6, 0)
	_fire_lights.append(fl)

var _fire_lights: Array = []
var _fire_t := 0.0
var _flick_acc := 0.0
func _flicker_fire(delta: float) -> void:
	if _fire_lights.is_empty():
		return
	_fire_t += delta
	# 12Hz 就夠：火光閃動是感覺，不是精確訊號。每幀改 light_energy 會逼引擎重算光照。
	_flick_acc += delta
	if _flick_acc < 0.083:
		return
	_flick_acc = 0.0
	var k: float = 2.4 + 0.9 * sin(_fire_t * 11.0) + 0.5 * sin(_fire_t * 27.0)
	for l in _fire_lights:
		if is_instance_valid(l):
			l.light_energy = k

# 槍聲是情報（GDD/15 F6）。開槍會暴露自己：附近的人會轉頭朝聲音方向。
# ⚠ 這條要在「視野扇形」之後做才有意義——先前 360 度全視野，轉不轉頭都一樣。
#   現在背後只有 0.3 倍視距，所以「被聲音吸引轉身」真的會改變偵察結果。
const HEAR_PX := 460.0        # 聽得到槍聲的距離（比視野遠得多，這是聲音的價值）
func _hear_shot(shooter) -> void:
	if not is_instance_valid(shooter["node"]):
		return
	var sp: Vector2 = _live_px(shooter)
	for u in units:
		if u == shooter or not u["alive"] or not is_instance_valid(u["node"]):
			continue
		if u == acting:
			continue                     # 玩家正在操控的人不要被系統搶走視角
		if Unit.is_vehicle_cls(u["cls"]):
			continue
		var up: Vector2 = _live_px(u)
		if up.distance_to(sp) > HEAR_PX:
			continue
		if u["node"].is_moving():
			continue                     # 正在移動的人不打斷他
		var to: Vector3 = shooter["node"].global_position - u["node"].global_position
		to.y = 0.0
		if to.length() > 0.05:
			u["node"].face_towards_sound(to.normalized())

# 兩人之間的中點（打在掩體上的音源大致位置）
func _mid3(a, b) -> Vector3:
	if not is_instance_valid(a["node"]) or not is_instance_valid(b["node"]):
		return Vector3.ZERO
	return a["node"].global_position.lerp(b["node"].global_position, 0.6) + Vector3(0, 1.0, 0)

func _splash(shooter, center) -> void:
	var w: Dictionary = shooter.get("weapon", {})
	var r_px: float = float(w.get("splash", 0))
	if r_px <= 0.0:
		return
	if is_instance_valid(center["node"]):
		Audio.boom(center["node"].global_position + Vector3(0, 0.6, 0))
	var cx: float = float(center["wx"])
	var cy: float = float(center["wy"])
	var base: int = GameData.damage(_wrap(shooter), _wrap(center), "body")
	var hit_any := 0
	for u in units:
		if u == center or u == shooter or not u["alive"] or not is_instance_valid(u["node"]):
			continue
		var d: float = Vector2(float(u["wx"]) - cx, float(u["wy"]) - cy).length()
		if d >= r_px:
			continue
		var fall: float = 1.0 - d / r_px
		var cov: float = cover_at(u["wx"], u["wy"], cx, cy)
		# 遮蔽陣地（GDD/01 §4b）：壕溝/彈坑裡的人對破片有 defilade 保護
		var defi: float = 1.0
		if terrain != null and not Unit.is_vehicle_cls(u["cls"]):
			defi = GameData.splash_defilade(terrain.in_trench(u["wx"], u["wy"]),
					terrain.in_crater(u["wx"], u["wy"]))
		var dmg: int = int(round(float(base) * fall * (1.0 - cov * 0.5) * defi))
		if dmg <= 0:
			continue
		u["hp"] -= dmg
		_sync_hp(u)
		hit_any += 1
		if u["hp"] <= 0 and u["alive"]:
			u["alive"] = false
			u["node"].die()
		else:
			u["node"].take_hit()
	_destroy_fortifications(Vector2(cx, cy), r_px)
	if hit_any > 0 and shooter["side"] == player_side:
		ui.flash_msg("爆炸波及 %d 人" % hit_any, Color(1.0, 0.75, 0.35))

# 爆炸摧毀工事（GDD/15 G1）。⚠ 三件事必須一起消失，否則就是「畫面沒了但還擋人」
# 或「畫面還在但穿得過去」——本專案吃過好幾次這種不一致的虧：
#   ① 網格 ② _blockers 裡的碰撞 ③ _covers 裡的掩體加成
func _destroy_fortifications(center: Vector2, r_px: float) -> void:
	if r_px <= 0.0:
		return
	var left: Array = []
	for d in _destructibles:
		var dc: Vector2 = d["c"]
		if dc.distance_to(center) > r_px + float(d["r"]) * 0.5:
			left.append(d)
			continue
		if is_instance_valid(d["node"]):
			d["node"].queue_free()
		_blockers.erase(d["blk"])
		_low_blk.erase(d["blk"])
		var keep_cov: Array = []
		for c in _covers:
			if String(c.get("type", "")) == "sandbag" 					and Vector2(float(c["wx"]), float(c["wy"])).distance_to(dc) < float(d["r"]):
				continue
			keep_cov.append(c)
		_covers = keep_cov
		_rebuild_support_box()
		_add_fire(_to3d(dc.x, dc.y) + Vector3(0, 0.3, 0), 0.5)   # 炸完會燒
		ui.flash_msg("工事被摧毀", Color(1.0, 0.6, 0.35))
	_destructibles = left

# 可瞄準的部位（GDD/01 §4）：軀幹永遠可選；步兵可瞄頭；
# 坦克散熱器在尾部，射手必須位於車尾 ±60° 扇形內才打得到——繞背後才是坦克戰的解法。
func _aim_parts(shooter, target) -> Array:
	var out := [{"part": "body", "zh": "軀幹" if target["cls"] != "tank" else "車體"}]
	if target["cls"] == "tank":
		var facing: Vector3 = target["node"].facing_dir()
		var to_shooter: Vector3 = shooter["node"].global_position - target["node"].global_position
		to_shooter.y = 0.0
		if to_shooter.length() > 0.01 and facing.dot(to_shooter.normalized()) < -0.5:
			out.append({"part": "radiator", "zh": "散熱器(尾部)"})
	else:
		out.append({"part": "head", "zh": "頭部"})
	return out

# 射擊預覽：把命中率與預期傷害算給玩家看（GDD/13：命中傷害預測介面）
func _fire_preview(shooter, target) -> Array:
	var dist_px := Vector2(target["wx"] - shooter["wx"], target["wy"] - shooter["wy"]).length()
	var cov: float = cover_at(target["wx"], target["wy"], shooter["wx"], shooter["wy"])
	var out := []
	for p in _aim_parts(shooter, target):
		var hc: float = GameData.hit_chance(_wrap(shooter), _wrap(target), dist_px, p["part"]) * (1.0 - cov * 0.6)
		var dm: int = GameData.damage(_wrap(shooter), _wrap(target), p["part"])
		# 彈道被實體擋住的部位直接標 0%：玩家要看得出「軀幹被沙包擋住、只能打頭」
		var zh: String = p["zh"]
		if not _shot_clear_units(shooter, target, p["part"]):
			hc = 0.0
			zh += "（被遮蔽）"
		out.append({"part": p["part"], "zh": zh, "hit": hc, "dmg": dm})
	return out

# GameData 公式吃 .weapon/.cls，包一層
func _wrap(u: Dictionary):
	var w := _UW.new(u)
	# 地形事實（GDD/01 §4b）由 Main 填——公式在 GameData 只查表，不碰場景。
	# 迎擊射擊包的臨時 dict 沒有座標（sh_w），沒座標就維持中性值＝不修正。
	if terrain != null and u.has("wx"):
		var px: float = float(u["wx"])
		var py: float = float(u["wy"])
		w.wade = maxf(0.0, terrain.water_depth(px, py))
		w.slope = terrain.slope_at(px, py)
		w.elev = terrain.height_at(px, py)
		w.in_crater = terrain.in_crater(px, py)
	var wfx: Dictionary = GameData.weather_fx(weather)
	w.env_acc = float(wfx.get("acc", 1.0))
	w.env_dodge = float(wfx.get("dodge", 1.0))
	return w
class _UW:
	var weapon: Dictionary
	var cls: String
	# 命中率要看姿勢、有沒有在動、還剩多少血（GDD/01 §4）
	var stance_acc := 1.0
	var moving := false
	var hp_ratio := 1.0
	# 地形事實（GDD/01 §4b）：涉水深度／坡度／地面高度／是否在彈坑
	var wade := 0.0
	var slope := 0.0
	var elev := 0.0
	var in_crater := false
	# 天候（GDD/04 天候節）：當射手用 env_acc、當目標用 env_dodge（由 _wrap 填）
	var env_acc := 1.0
	var env_dodge := 1.0
	func _init(u: Dictionary):
		weapon = u["weapon"]
		cls = u["cls"]
		var n = u.get("node", null)
		if n != null and is_instance_valid(n) and not Unit.is_vehicle_cls(cls):
			# 臥射 1.25 / 蹲姿 1.12 / 站姿 1.0——支撐點越多越穩
			stance_acc = 1.0 + 0.25 * n._prone + 0.12 * n._crouch * (1.0 - n._prone)
			moving = n.is_moving()
		var hp_max: float = float(GameData.class_base.get(cls, {}).get("hp", 100))
		hp_ratio = clampf(float(u.get("hp", hp_max)) / maxf(hp_max, 1.0), 0.0, 1.0)

func _on_shot(from_pos: Vector3, to_pos: Vector3) -> void:
	var im := ImmediateMesh.new()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.88, 0.45)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	im.surface_add_vertex(from_pos)
	im.surface_add_vertex(to_pos)
	im.surface_end()
	add_child(mi)
	var fl := OmniLight3D.new()
	fl.light_color = Color(1.0, 0.8, 0.4)
	fl.omni_range = 4.0
	fl.position = from_pos
	add_child(fl)
	_tracers.append({"m": mi, "l": fl, "ttl": 0.15})

# ---------- 回合 ----------
func _end_player_turn() -> void:
	if st != St.CMD:
		return
	st = St.ENEMY
	_end_action()
	for u in units:
		u["acted"] = false
		u["orders"] = 0
	_enemy_queue = []
	for u in units:
		if u["alive"] and u["side"] != player_side:
			_enemy_queue.append(u)
	# 出手順序：先坦克、後步兵（GDD/01 §6），同類再依「離我方最近」排——
	# 最近的先動才有威脅，玩家的迎擊也才有事做。
	_enemy_queue.sort_custom(func(a, b):
		var ta: bool = a["cls"] == "tank"
		var tb: bool = b["cls"] == "tank"
		if ta != tb:
			return ta
		return _dist_to_nearest_foe(a) < _dist_to_nearest_foe(b))
	enemy_cp = _enemy_turn_cp()
	_ai_state = ""
	_enemy_t = 0.6
	ui.update_hud(turn, "enemy", enemy_cp, _hud_wx())

func _dist_to_nearest_foe(u) -> float:
	var best := 1e9
	for x in units:
		if x["alive"] and x["side"] != u["side"]:
			best = minf(best, Vector2(x["wx"] - u["wx"], x["wy"] - u["wy"]).length())
	return best

func _enemy_turn_cp() -> int:
	var tanks := 0
	for u in units:
		if u["alive"] and u["side"] != player_side and u["cls"] == "tank":
			tanks += 1
	return mini(CP_BASE + tanks, CP_CAP)

func _process(delta: float) -> void:
	for tr in _tracers.duplicate():
		tr["ttl"] -= delta
		if tr["ttl"] <= 0:
			tr["m"].queue_free()
			tr["l"].queue_free()
			_tracers.erase(tr)
	_solid_bodies()
	_roof_fade(delta)
	_tps_control(delta)
	_drift_watch_tick(delta)
	_flicker_fire(delta)
	_weather_follow()
	_action_tick(delta)
	_intercept_tick(delta)
	if st == St.ENEMY:
		_enemy_t -= delta
		_ai_t += delta
		if _enemy_t <= 0:
			_enemy_step()
			_enemy_t = 0.25

# ---------- 原地飄移診斷（-- idledrift chNN）----------
# 使用者 2026-08-02 回報「人物停在原地會小飄移」。每幀會動到單位 XZ 的路徑有四條
# （_settle／步兵互推／邊界 clamp／玩家輸入），用猜的必然重蹈 lessons 0b 的覆轍
# （ch09「陷進實體」連改四次座標分毫不動，最後是讓斷言印出「是什麼把人推開」才一次找到）。
# 所以先記帳：每幀每個來源推了多少，跑完印表，最大的那個就是兇手。
# 平時只多一個 bool 判斷，零成本。
var _drift_dbg := false
var _drift := {}            # instance_id -> {cls, settle, pair, clamp, esc, n}
func _drift_add(u, key: String, d: float) -> void:
	if not _drift_dbg or d < 0.000001:
		return
	if not is_instance_valid(u.get("node")):
		return
	var id: int = u["node"].get_instance_id()
	if not _drift.has(id):
		_drift[id] = {"cls": u["cls"], "side": u["side"],
				"settle": 0.0, "pair": 0.0, "clamp": 0.0, "esc": 0, "n": 0}
	_drift[id][key] += d
	_drift[id]["n"] += 1

# ---------- 實玩飄移守望（啟動時加 -- driftwatch）----------
# 使用者 2026-08-02 回報「人物停在原地會小飄移」，但合成輸入（走一段→放開鍵→靜置 8 秒，
# 平地與斜坡都試過）量到的位移只有 0.5 公釐＝重現不出來。
# 與其繼續猜，不如讓使用者照平常玩、由程式當場抓：
#   「沒按任何移動鍵**且** AP 沒在消耗，人卻在動」就記一筆，並附上是誰推的。
# 平時（沒帶參數）完全不執行。
var _drift_watch := false
var _dw_t := 0.0
var _dw_node := Vector2.ZERO
var _dw_mesh := Vector2.ZERO
var _dw_hits := 0
func _drift_watch_tick(delta: float) -> void:
	if not _drift_watch or acting == null or not is_instance_valid(acting.get("node")):
		return
	for k in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT]:
		if Input.is_key_pressed(k):
			_dw_t = 0.0                 # 有在操作就重新計時
			return
	_dw_t += delta
	if _dw_t < 0.5:                     # 剛放開鍵的減速不算飄移
		return
	var node: Node3D = acting["node"]
	var np := Vector2(node.global_position.x, node.global_position.z)
	var mp := _visual_center(node)
	if _dw_node == Vector2.ZERO:
		_dw_node = np
		_dw_mesh = mp
		return
	var dn: float = np.distance_to(_dw_node)
	var dm: float = mp.distance_to(_dw_mesh)
	if dn > 0.01 or dm > 0.01:          # 一公分就算（肉眼看得到的下限）
		_dw_hits += 1
		var acc: Dictionary = _drift.get(node.get_instance_id(), {})
		print("[driftwatch] #%d 沒按鍵 %.1f 秒卻動了：單位 %.3fm／網格 %.3fm"
				% [_dw_hits, _dw_t, dn, dm]
				+ "　來源 settle %.3f pair %.3f clamp %.3f 逃生 %d 次　"
				% [acc.get("settle", 0.0), acc.get("pair", 0.0),
				acc.get("clamp", 0.0), acc.get("esc", 0)]
				+ "座標 (%.2f, %.2f)" % [np.x, np.y])
		_dw_node = np
		_dw_mesh = mp

# 單位「畫面上」的水平中心：合併底下所有 MeshInstance3D 的世界 AABB。
# ⚠ 骨骼在動時節點座標完全不變，量節點等於沒量——要量網格本身。
func _visual_center(n: Node) -> Vector2:
	var box := AABB()
	var first := true
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		# ⚠ 只算**看得見**的：UAL 動作來源那具 Mannequin 是隱藏的（還被丟到 z=-400），
		#   但它的動作自帶根位移，一路飄了 9.3m。把它算進來就會誤報
		#   「網格在飄」——使用者根本看不到它。量測對象要跟使用者的眼睛一致。
		if not m.is_visible_in_tree():
			continue
		var b: AABB = m.global_transform * m.get_aabb()
		box = b if first else box.merge(b)
		first = false
	if first:
		return Vector2.ZERO
	var c: Vector3 = box.get_center()
	return Vector2(c.x, c.z)

# 走到 _settle 逃生分支一次（沒有位移量，只計次）
func _drift_esc(u) -> void:
	if not _drift_dbg or not is_instance_valid(u.get("node")):
		return
	var id: int = u["node"].get_instance_id()
	if not _drift.has(id):
		_drift[id] = {"cls": u["cls"], "side": u["side"],
				"settle": 0.0, "pair": 0.0, "clamp": 0.0, "esc": 0, "n": 0}
	_drift[id]["esc"] += 1

# 這個單位高到不該被地面障礙碰到嗎（鐵律 0②：遮蔽看幾何與高度，不是看標籤）。
# ★單一真相來源：解算（_solid_bodies）與斷言（_stress_sweep／走查）都必須問這一支。
#   2026-08-03 stress ch12 兩次踩到同一個坑的兩半：
#     ① 解算沒判高度 → 14m 巡航的戰鬥機被樹和建築的平面足跡推來推去（「頂著障礙空轉」）
#     ② 只修了解算、斷言沒跟著改 → 掃描照樣報「fighter 陷進實體」
#   門檻 8m：固定翼（14m）一定跳過；武裝直升機（6m）仍要撞得到高樓。
func _flies_over_solids(u) -> bool:
	if not is_instance_valid(u.get("node")) or u["node"].get("_is_air") != true:
		return false
	return u["node"].global_position.y - _ground_height(u["node"].global_position) > 8.0

# 實體約束（GDD/14 §2）：每幀把所有單位推出牆體。
# ⚠ 先前只有「第三人稱操控中的那一個」會吃碰撞，敵方 AI、點擊移動、
#   甚至測試把兵直接放進屋裡都能穿牆——牆等於只對玩家有效。
#   人要跟實體一樣，就不能有任何一條路徑可以繞過碰撞。
func _solid_bodies() -> void:
	for u in units:
		if not u["alive"] or not is_instance_valid(u["node"]):
			continue
		var node = u["node"]
		var r: float = VEHICLE_R if Unit.is_vehicle_cls(u["cls"]) else BODY_R
		if _flies_over_solids(u):
			continue
		# ★ 用 _settle 不用 _resolve_solids：邊界上的單位要同時滿足夾限與實體，
		#   只解算實體的話下一幀又被夾限推回障礙裡（ch01/06/13 卡邊界真因）
		var fixed: Vector3 = _settle(node.global_position, r, u)
		if fixed.distance_squared_to(node.global_position) > 0.000001:
			_drift_add(u, "settle", fixed.distance_to(node.global_position))
			node.global_position = Vector3(fixed.x, node.global_position.y, fixed.z)
			var p := _live_px(u)
			u["wx"] = p.x
			u["wy"] = p.y
			# ★載具連續被推＝它正頂著障礙空轉（stress ch12：坦克六個回合卡在同一座標，
			#   每幀被推出來、下一幀又開回去）。連續 12 幀（0.2 秒）就叫它停車改路。
			if Unit.is_vehicle_cls(u["cls"]):
				u["veh_push_n"] = int(u.get("veh_push_n", 0)) + 1
				if int(u["veh_push_n"]) >= 12:
					u["veh_push_n"] = 0
					if node.has_method("veh_blocked"):
						node.veh_blocked()
						if _test_mode:
							print("[veh] %s 頂著障礙空轉，停車改路 px=(%.0f,%.0f)"
									% [String(u["cls"]), p.x, p.y])
		elif Unit.is_vehicle_cls(u["cls"]):
			u["veh_push_n"] = 0
	# 步兵彼此也是實體（鐵律 0①：固體不可互穿——先前刻意放行，理由是怕 AI 卡死，
	# 但那違反物理；卡死交給既有的「真停滯偵測」收尾，不該靠互穿解決）。
	# 對稱推開：兩人各退一半，誰也不把誰彈飛。已死者不算（屍體可以跨過）。
	var n := units.size()
	for i in n:
		var a = units[i]
		if not a["alive"] or not is_instance_valid(a["node"]) or Unit.is_vehicle_cls(a["cls"]):
			continue
		for j in range(i + 1, n):
			var b = units[j]
			if not b["alive"] or not is_instance_valid(b["node"]) or Unit.is_vehicle_cls(b["cls"]):
				continue
			var pa: Vector3 = a["node"].global_position
			var pb: Vector3 = b["node"].global_position
			var dxz := Vector2(pb.x - pa.x, pb.z - pa.z)
			var d: float = dxz.length()
			var need: float = BODY_R * 2.0 * 0.85      # 肩並肩可以貼近一點，胸貼背不行
			if d >= need or d < 0.0001:
				continue
			var push: Vector2 = dxz / d * (need - d) * 0.5
			_drift_add(a, "pair", push.length())
			_drift_add(b, "pair", push.length())
			a["node"].global_position -= Vector3(push.x, 0, push.y)
			b["node"].global_position += Vector3(push.x, 0, push.y)
			for uu in [a, b]:
				var pp := _live_px(uu)
				uu["wx"] = pp.x
				uu["wy"] = pp.y
	# 地圖邊界對每個人每幀都成立（鐵律 0：世界的邊就是邊）。
	# ⚠ 先前只有玩家鍵盤路徑夾限；上面的推開（推出實體、兩人分開）可以把
	#   站在邊緣的單位一路擠出地圖——ch03 壓測抓到敵兵被擠到 y=-18px。
	for u2 in units:
		if not u2["alive"] or not is_instance_valid(u2["node"]):
			continue
		var pcl: Vector3 = _clamp_to_map(u2["node"].global_position)
		if pcl.distance_squared_to(u2["node"].global_position) > 0.000001:
			_drift_add(u2, "clamp", pcl.distance_to(u2["node"].global_position))
			u2["node"].global_position = Vector3(pcl.x, u2["node"].global_position.y, pcl.z)
			var pq := _live_px(u2)
			u2["wx"] = pq.x
			u2["wy"] = pq.y

# 屋頂淡出（GDD/14 §2）：玩家操控的單位進到室內時，那棟樓的屋頂淡掉，
# 否則第三人稱鏡頭會被屋頂整個擋住、根本看不到自己在做什麼。
var _roof_a := {}
func _roof_fade(delta: float) -> void:
	if _buildings.is_empty():
		return
	# ★2026-07-27 使用者回報「屋內的角色點不到」的真因就在這裡：
	#   舊版只淡出「目前選取／行動中那一個」單位所在的建築，於是形成死結——
	#   要看到屋裡的人才點得到他，要點到他才會淡出屋頂。
	#   改成：**任何一個活著的我方單位在屋裡，那棟就淡出屋頂**。
	var pts: Array = []
	for u in units:
		if u["side"] == player_side and u["alive"] and is_instance_valid(u["node"]):
			pts.append(_live_px(u))
	var watch = acting if acting != null else selected
	if watch != null and is_instance_valid(watch["node"]):
		pts.append(_live_px(watch))     # 行動中的敵人也要看得到（鏡頭會跟拍）
	# ★鏡頭在屋裡時不可以淡出屋頂（2026-07-27 使用者：「建築物裡人物在裡面會變成
	#   感覺沒有牆壁一樣可以看到外面」）。屋頂淡出是給**俯瞰**用的——玩家在天上，
	#   要看到屋裡有誰。第三人稱鏡頭已經在室內時，淡掉屋頂只會讓房間變成一個沒有蓋子的箱子。
	var cam_px := Vector2(-99999.0, -99999.0)
	if cam != null and cam.is_tps():
		cam_px = Vector2(cam.global_position.x / WORLD_SCALE + float(map_data.get("w", 960)) * 0.5,
				cam.global_position.z / WORLD_SCALE + float(map_data.get("h", 600)) * 0.5)
	for i in _buildings.size():
		var bd = _buildings[i]
		var occupied := false
		for p in pts:
			if bd.inside(p.x, p.y):
				occupied = true
				break
		var want: float = 0.0 if occupied else 1.0
		if bd.rect.grow(1.0).has_point(cam_px):
			want = 1.0            # 鏡頭就在這棟裡面：屋頂與天花板留著，室內才是室內
		var cur: float = float(_roof_a.get(i, 1.0))
		cur = move_toward(cur, want, delta * 3.5)
		_roof_a[i] = cur
		bd.set_roof_alpha(cur)

# 小地圖資料（GDD/13）：只給「玩家看得見」的敵人，小地圖不能變成透視外掛。
func _minimap_data() -> Dictionary:
	var us: Array = []
	for u in units:
		if not u["alive"] or not is_instance_valid(u["node"]):
			continue
		if u["side"] != player_side and not u["node"].visible:
			continue
		var p := _live_px(u)
		us.append([p.x, p.y, 0 if u["side"] == player_side else 1])
	var trs: Array = []
	for t in map_data.get("trenches", []):
		trs.append(t.get("pts", []))
	var bls: Array = []
	for bd in _buildings:
		bls.append([bd.rect.position.x, bd.rect.position.y, bd.rect.size.x, bd.rect.size.y])
	var act = null
	if acting != null and is_instance_valid(acting["node"]):
		var ap := _live_px(acting)
		var yaw: float = acting["node"].rotation.y
		if cam.is_tps():
			yaw = deg_to_rad(cam.tps_yaw)
		act = [ap.x, ap.y, yaw]
	return {"mw": float(map_data.get("w", 960)), "mh": float(map_data.get("h", 600)),
			"units": us, "trenches": trs, "buildings": bls, "acting": act,
			"sight": (float(GameData.class_base.get(acting["cls"], {}).get("sight", SIGHT))
					if acting != null else 0.0)}   # 雷達圈＝這個兵種自己的偵測距離

# 滑鼠鎖定：第三人稱要自由轉視角就得鎖游標；但一開面板/回指令模式就要放開，否則點不到 UI。
func _capture_mouse(on: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE

# 第三人稱操控（GDD/07）：WASD 相對鏡頭移動、準心決定瞄準方向。
# AP 照樣由 _action_tick 依「實際位移」扣，兩種操作方式共用同一套經濟。
# 按鍵「剛按下」偵測：姿勢切換不能用 is_key_pressed（按住會每幀切換一次）
var _key_prev := {}
func _key_edge(code: Key) -> bool:
	var now: bool = Input.is_key_pressed(code)
	var was: bool = bool(_key_prev.get(code, false))
	_key_prev[code] = now
	return now and not was

func _tps_control(delta: float) -> void:
	if acting == null or st != St.CMD or not cam.is_tps():
		return
	var node = acting["node"]
	if not is_instance_valid(node) or not acting["alive"]:
		return
	# 準心方向：角色永遠瞄向你看的地方
	var fwd: Vector3 = cam.tps_forward()
	node.aim_point = node.global_position + Vector3(0, 1.4, 0) + fwd * 20.0
	# ★★身體要跟著鏡頭轉（2026-07-27 使用者：「手會在後面」的真因）。
	#   舊版只設 aim_point，身體只在 `move_dir()`（真的在走）時才轉向 →
	#   站著用滑鼠把鏡頭轉到角色後面時，身體還朝原來的方向，
	#   只有手臂與槍被 IK 拉去背後，看起來就是「手裝反了」。
	#   所有第三人稱射擊遊戲在準心舉起時都是「身體對齊視角」，這裡照做。
	if not node.is_moving():
		var want_yaw: float = deg_to_rad(cam.tps_yaw)
		node.rotation.y = lerp_angle(node.rotation.y, want_yaw, minf(1.0, 9.0 * delta))
	if ui.fire_panel_open():
		return                      # 面板開著時不要一邊走一邊選部位
	# 鍵盤轉視角（使用者 2026-07-26：不想什麼都靠滑鼠）。
	# 方向鍵移動是「相對鏡頭」的，鏡頭原本只能用滑鼠轉，等於還是離不開滑鼠。
	var turn := 0.0
	if Input.is_key_pressed(KEY_Q):
		turn += 1.0
	if Input.is_key_pressed(KEY_E):
		turn -= 1.0
	if turn != 0.0:
		cam.tps_yaw += turn * 96.0 * delta
	# 姿勢：C 蹲、Z 趴、Space 站起（按下即切換，不是按住）
	if _key_edge(KEY_C):
		node.stance_cmd = "" if node.stance_cmd == "crouch" else "crouch"
		ui.flash_msg("姿勢：蹲下" if node.stance_cmd == "crouch" else "姿勢：自動", Color(0.7, 0.9, 1.0))
	if _key_edge(KEY_Z):
		node.stance_cmd = "" if node.stance_cmd == "prone" else "prone"
		ui.flash_msg("姿勢：伏臥" if node.stance_cmd == "prone" else "姿勢：自動", Color(0.7, 0.9, 1.0))
	if _key_edge(KEY_SPACE):
		node.stance_cmd = "stand"
		ui.flash_msg("姿勢：站立", Color(0.7, 0.9, 1.0))
	var ix := 0.0
	var iz := 0.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		iz += 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		iz -= 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		ix -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		ix += 1.0
	if ix == 0.0 and iz == 0.0:
		return
	if float(acting["ap"]) <= 0.0:
		return
	var flat := Vector3(fwd.x, 0, fwd.z).normalized()
	# ⚠ 左右相反的真因（使用者 2026-07-26 指正）：Godot 是右手座標、-Z 為前，
	#   前向量 (0,0,-1) 的右手邊是世界 +X。舊寫法 (flat.z, 0, -flat.x) 算出來是 (-1,0,0)
	#   ＝左邊，所以按右鍵往左走。正確是 (-flat.z, 0, flat.x)。
	var right := Vector3(-flat.z, 0, flat.x)
	var dir: Vector3 = (flat * iz + right * ix).normalized()
	var before: Vector3 = node.global_position
	node.move_dir(dir, delta)
	# 邊界與 AP 上限：走到夾限外就把人推回來（AP 由 _action_tick 依實際位移扣）
	var clamped: Vector3 = _settle(node.global_position,
			VEHICLE_R if Unit.is_vehicle_cls(acting["cls"]) else BODY_R, acting)
	node.global_position = Vector3(clamped.x, node.global_position.y, clamped.z)
	if before.distance_to(node.global_position) < 0.0001:
		return

# 第三人稱下開火：取準心最接近的敵人
# 第三人稱選目標（使用者 2026-07-26：「滑鼠是可以輔助，可以點敵軍，而不是只能到準星」）。
# 兩點改法：
#   1. 滑鼠沒被鎖定（按 Tab 放開）時，用**游標位置**選目標＝真的用滑鼠點敵人
#   2. 判定改「腳→頭整條身體線段」＋容差隨螢幕上的人形大小縮放（跟戰術視角的
#      _click 同一套），不再是「距離胸口一點 140px」——遠處敵人只有幾十像素高，
#      舊寫法等於要把準心壓在一個小點上
# `click_at`＝滑鼠點擊事件回報的位置。
# ⚠ 一定要吃事件帶來的座標，不可以只問 `get_viewport().get_mouse_position()`：
#   合成點擊（測試、教學指引）只會給事件座標，不會真的搬動作業系統的游標，
#   於是「點敵人」永遠打不到目標（2026-07-27 改成不鎖游標之後 [partchk] 當場掛掉）。
func _tps_target(click_at := Vector2(-1, -1)):
	var vp := get_viewport().get_visible_rect().size
	var aim_pt: Vector2 = vp * 0.5
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		aim_pt = click_at if click_at.x >= 0.0 else get_viewport().get_mouse_position()
	var best = null
	var bd := 1e9
	for u in units:
		if not u["alive"] or u["side"] == player_side or not u["node"].visible:
			continue
		var foot: Vector2 = cam.unproject_position(u["node"].global_position)
		var head: Vector2 = cam.unproject_position(u["node"].global_position + Vector3(0, 1.85, 0))
		var d: float = _dist_to_seg(aim_pt, foot, head)
		var tol: float = clampf(foot.distance_to(head) * 1.1, 60.0, 220.0)
		if d < tol and d < bd:
			bd = d
			best = u
	return best

# 行動模式每幀：依實際移動距離扣 AP，歸零就停下（GDD/01 §2：不可殘留走不了的尾數）
# 敵我共用同一套扣法——AI 若不吃 AP，玩家受限而敵人不受，那才是真的不公平。
func _action_tick(_delta: float) -> void:
	if acting == null or (st != St.CMD and st != St.ENEMY):
		return
	if not is_instance_valid(acting["node"]) or not acting["alive"]:
		_end_action()
		return
	var mine: bool = acting["side"] == player_side
	var pos: Vector3 = acting["node"].global_position
	# ⚠ AP 必須依「真的走到哪裡」扣，不是依每幀位移的**總和**。
	#   被擋住時人會在碰撞邊界來回抖動，每幀都有一點位移，加總起來 AP 就被扣光了——
	#   玩家看到的是「原地跑步，AP 一直掉」（使用者 2026-07-27 實測）。
	#   低於門檻的抖動一律不算。
	var mdelta := Vector2(pos.x - _act_last.x, pos.z - _act_last.z)
	var moved: float = mdelta.length()
	if moved < 0.004:
		moved = 0.0
	_act_last = pos
	if moved > 0.0:
		# 地形成本（GDD/14 §3-4）：上坡 ×1.5、彈坑 ×2——同樣的距離，難走的地形就是吃更多 AP
		var tcost := 1.0
		if terrain != null:
			tcost = terrain.move_cost(float(acting["wx"]), float(acting["wy"]),
					String(GameData.class_base.get(acting["cls"], {}).get("mobility", "foot")),
					mdelta) * weather_move_mul()
		acting["ap"] = maxf(0.0, float(acting["ap"]) - moved / (PX_PER_AP * WORLD_SCALE) * tcost)
		var p := _live_px(acting)
		acting["wx"] = p.x
		acting["wy"] = p.y
		if acting["ap"] <= 0.0:
			acting["node"].stop()
			if mine:
				ui.flash_msg("AP 用盡", Color(1.0, 0.8, 0.4))
		if mine:
			ui.show_ap(acting["ap"], acting["ap_max"])
			_update_ap_ring()

# 敵方階段（AI09）：與玩家同一套行動經濟——花 CP 下令、移動吃 AP、每次行動開火一次。
# 舊版是「每 1.1 秒把單位硬移 120px」，玩家受 AP 限制而敵人不受，且移動是瞬移不會被迎擊。
func _enemy_step() -> void:
	if _ai_focus != null and not _ai_focus["alive"]:
		_ai_focus = null
	# A) 目前有單位在行動：等它走完/AP 用盡 → 開火 → 收尾
	if acting != null and acting["side"] != player_side:
		if not acting["alive"]:
			_finish_enemy_action()
			return
		var tgt = _ai_target if (_ai_target != null and _ai_target["alive"]) else _nearest_foe(acting)
		var moving: bool = acting["node"].is_moving()
		if _ai_state == "move":
			# 真停滯偵測：單位以為自己在走（is_moving 仍為 true），但每幀被實體推回原地。
			# 沒有這一條就只能等 AP 用盡或 12 秒逾時，畫面上是敵人貼著柵欄抽搐。
			var now_p: Vector3 = acting["node"].global_position
			if now_p.distance_to(_ai_last) < 0.06:
				_ai_stall += _enemy_t
			else:
				_ai_stall = 0.0
			_ai_last = now_p
			var stalled: bool = (not moving) or float(acting["ap"]) <= 0.0 or _ai_stall > 1.2
			if stalled or _ai_t > 12.0:
				_ai_state = "fire"
				if tgt != null and not bool(acting.get("fired", false)):
					var d: float = Vector2(tgt["wx"] - acting["wx"], tgt["wy"] - acting["wy"]).length()
					if d <= float(acting["weapon"].get("range", 200)) and _shot_clear_units(acting, tgt):
						_fire(acting, tgt)
						_enemy_t = 1.0        # 等開火動作演完再收尾
						return
				_finish_enemy_action()
		else:
			_finish_enemy_action()
		return
	# B) 沒單位在行動：派下一個（CP 不足或沒兵可派就結束敵方階段）
	while not _enemy_queue.is_empty():
		var e = _enemy_queue.pop_front()
		if not e["alive"] or not is_instance_valid(e["node"]):
			continue
		if not _begin_action(e):
			break                      # CP 不夠了
		var plan := _ai_plan(e)
		var tgt2 = plan["target"]
		if tgt2 == null and plan["dest"] == null:
			_finish_enemy_action()
			continue
		# 只跟拍「玩家看得見」的敵人：跟著迷霧裡的單位＝整段盯著空草地看（實拍發現）
		if e["node"].visible:
			cam.set_follow(e["node"])
		else:
			cam.set_follow(null)
		ui.update_hud(turn, "enemy", enemy_cp, _hud_wx())
		# 玩家看不見的敵人加速行軍：整場敵方階段實測 21.5 秒太久，
		# 但看得見的那段不能加速——那正是玩家要看、也是迎擊發生的地方。
		e["node"].speed_mul = 1.0 if e["node"].visible else 3.0
		_ai_state = "move"
		_ai_t = 0.0
		_ai_why = str(plan["why"])
		_ai_target = tgt2
		# 目的地：職責行為指定的點（撤退/佔掩體）優先；否則推進到「射程 × range_k」處。
		var here: Vector3 = e["node"].global_position
		var goal: Vector3
		if plan["dest"] != null:
			goal = plan["dest"]
		else:
			var to_t: Vector3 = tgt2["node"].global_position - here
			to_t.y = 0.0
			var want: float = float(e["weapon"].get("range", 200)) * float(plan["range_k"]) * WORLD_SCALE
			goal = here + to_t.normalized() * maxf(to_t.length() - want, 0.0)
		var move_v: Vector3 = goal - here
		move_v.y = 0.0
		var reach: float = _ap_metres(e)
		if move_v.length() <= 0.35:
			_ai_state = "fire"         # 已到位：原地開火
			_enemy_t = 0.4
			return
		var step_goal: Vector3 = here + move_v.normalized() * minf(move_v.length(), reach)
		# 繞開實體障礙（AI09）：直線撞柵欄就換個角度走，別貼著磨到 AP 用盡
		step_goal = _avoid_goal(here, step_goal,
				VEHICLE_R if Unit.is_vehicle_cls(e["cls"]) else BODY_R)
		_ai_last = e["node"].global_position
		_ai_stall = 0.0
		e["node"].move_to(_clamp_to_map(step_goal))
		_enemy_t = 0.3
		return
	_end_enemy_turn()

# ---- 敵方 AI 狀態機（GDD/01 §6，禁止改成不可預測的隨機大雜燴）----
# 每個單位依序評估，取第一個成立者：殘血撤退 → 職責行為 → 無目標推進主堡。
# 回傳 {"target": 單位或 null, "range_k": 想推進到射程的幾倍, "dest": 指定目的地或 null, "why": 說明}
# 集火目標：整個敵方陣營這一回合共用同一個目標。
# ⚠ 每個單位各自挑「最近的」＝火力被平均分散到所有人身上，誰都打不死；
#   集中打一個才是真的戰術。這一格快取每回合清一次（_enemy_step 開頭）。
var _ai_focus = null

func _ai_pick_focus(e, foes: Array):
	if _ai_focus != null and _ai_focus["alive"]:
		return _ai_focus
	# 挑「血最少 ÷ 距離」最高的：快死的、又離得近的，最值得全隊一起打
	var best = null
	var bs := -1.0
	var from := Vector2(float(e["wx"]), float(e["wy"]))
	for x in foes:
		var d: float = maxf(from.distance_to(Vector2(float(x["wx"]), float(x["wy"]))), 1.0)
		var sc: float = (float(x["maxhp"]) - float(x["hp"]) + 20.0) / d * 100.0
		if sc > bs:
			bs = sc
			best = x
	_ai_focus = best
	return best

func _ai_plan(e) -> Dictionary:
	var hp_ratio: float = float(e["hp"]) / maxf(float(e["maxhp"]), 1.0)
	var dif: Dictionary = _diff()
	var foes: Array = []
	for x in units:
		if x["alive"] and x["side"] != e["side"]:
			foes.append(x)
	# 1) 殘血撤退：往自家主堡方向退，並優先躲進掩體
	#    撤退門檻隨章節提高——會撤退療傷的軍隊比死戰到底的難打得多
	if hp_ratio < float(dif.get("retreatHp", 0.3)):
		return {"target": _nearest_foe(e), "range_k": 1.0, "dest": _retreat_dest(e), "why": "殘血撤退"}
	if foes.is_empty():
		return {"target": null, "range_k": 0.6, "dest": _base_dest(1 - e["side"]), "why": "無目標→推進主堡"}
	# 2) 職責行為
	match e["cls"]:
		"at":
			var tank = _pick_foe(foes, "tank", Vector2(float(e["wx"]), float(e["wy"])))
			return {"target": tank if tank != null else _nearest_foe(e), "range_k": 0.6, "dest": null,
					"why": "火箭兵找坦克" if tank != null else "火箭兵無坦克可打"}
		"sniper":
			return {"target": _pick_weakest(foes), "range_k": 0.9, "dest": null, "why": "狙擊手找血最少的"}
		"mg":
			# 機槍兵佔掩體警戒：不推進，就近找掩體站定，靠警戒射擊吃人
			return {"target": _nearest_foe(e), "range_k": 1.0, "dest": _cover_dest(e), "why": "機槍兵佔掩體警戒"}
		"tank":
			return {"target": _pick_valuable(foes), "range_k": 0.6, "dest": null, "why": "坦克轟最高價值目標"}
	# 3) 章節難度行為（data/difficulty.json）。這三件用的都是**專案裡早就有、
	#    但只有機槍兵或根本沒人用**的機制：_cover_dest / 集火 / _avoid_goal 側翼。
	var tgt = _nearest_foe(e)
	var why := "推進到射程 0.6 倍"
	var dest = null
	var rk := 0.6
	var rr := randf()
	if rr < float(dif.get("focus", 0.0)):
		var f = _ai_pick_focus(e, foes)
		if f != null:
			tgt = f
			why = "集火（全隊同一個目標）"
	if randf() < float(dif.get("cover", 0.0)):
		dest = _cover_dest(e)
		rk = 0.85
		why += "＋佔掩體"
	elif randf() < float(dif.get("flank", 0.0)) and tgt != null:
		# 側翼：不從正面推，繞到目標的側後方。_avoid_goal 早就寫好了，先前沒人用。
		var tp := Vector2(float(tgt["wx"]), float(tgt["wy"]))
		var ep := Vector2(float(e["wx"]), float(e["wy"]))
		var dirv: Vector2 = (tp - ep).normalized()
		var side: Vector2 = Vector2(-dirv.y, dirv.x) * (1.0 if randf() < 0.5 else -1.0)
		var want: Vector2 = tp - dirv * (120.0) + side * 170.0
		dest = _avoid_goal(e["node"].global_position, _to3d(want.x, want.y), BODY_R)
		why += "＋側翼迂迴"
	return {"target": tgt, "range_k": rk, "dest": dest, "why": why}

# 找最近的某兵種目標。⚠ 距離要從「發起者」量起，不是從 foes[0] 量（會挑錯人）。
func _pick_foe(foes: Array, cls: String, from: Vector2):
	var best = null
	var bd := 1e9
	for x in foes:
		if x["cls"] != cls:
			continue
		var d: float = from.distance_to(Vector2(float(x["wx"]), float(x["wy"])))
		if d < bd:
			bd = d
			best = x
	return best

func _pick_weakest(foes: Array):
	var best = null
	for x in foes:
		if best == null or float(x["hp"]) < float(best["hp"]):
			best = x
	return best

func _pick_valuable(foes: Array):
	var best = null
	var bv := -1.0
	for x in foes:
		var v: float = float(GameData.class_base.get(x["cls"], {}).get("cost", 50))
		if v > bv:
			bv = v
			best = x
	return best

# 主堡座標（GDD/01 §7 勝利條件用的同一組資料）
func _base_dest(side_i: int):
	for b in map_data.get("bases", []):
		if int(b.get("side", 0)) == side_i:
			return _to3d(float(b.get("x", 0)), float(b.get("y", 0)))
	var z: Dictionary = {}
	var dz = map_data.get("deploy", [])
	if dz is Array and dz.size() > side_i:
		z = dz[side_i]
	return _to3d(float(z.get("x", 0)) + float(z.get("w", 300)) * 0.5, float(z.get("y", 0)) + float(z.get("h", 200)) * 0.5)

# 撤退點：往自家主堡方向，若沿途有掩體就先躲進掩體
func _retreat_dest(e):
	var home = _base_dest(e["side"])
	var cover = _cover_dest(e)
	if cover != null and (cover as Vector3).distance_to(home) < e["node"].global_position.distance_to(home):
		return cover
	return home

# 就近掩體：站在掩體「背對敵人」那一側，才擋得住（掩體是方向性的）
func _cover_dest(e):
	var foe = _nearest_foe(e)
	var here := Vector2(float(e["wx"]), float(e["wy"]))
	var best = null
	var bd := 1e9
	for c in _covers:
		if c["type"] == "bush":
			continue
		var cp := Vector2(float(c["wx"]), float(c["wy"]))
		var d: float = here.distance_to(cp)
		if d < bd and d < 600.0:
			bd = d
			var away := Vector2(1, 0)
			if foe != null:
				away = (cp - Vector2(float(foe["wx"]), float(foe["wy"]))).normalized()
			var stand: Vector2 = cp + away * (float(c["r"]) * 0.75)
			best = _to3d(stand.x, stand.y)
	return best

func _nearest_foe(u):
	var tgt = null
	var td := 1e9
	for x in units:
		if x["side"] != u["side"] and x["alive"]:
			var d := Vector2(x["wx"] - u["wx"], x["wy"] - u["wy"]).length()
			if d < td:
				td = d
				tgt = x
	return tgt

func _finish_enemy_action() -> void:
	if acting != null and is_instance_valid(acting["node"]):
		acting["node"].speed_mul = 1.0
	_end_action()
	_ai_state = ""
	_enemy_t = 0.35

func _end_enemy_turn() -> void:
	_end_action()
	turn += 1
	if turn > 30:
		_win(1 - player_side, "防守方撐過 30 回合")
		return
	_advance_time_weather()      # 回合時鐘：推進時刻、擲天氣（GDD/04 天候節）
	st = St.CMD
	cp = _turn_cp()
	for u in units:
		u["acted"] = false
		u["orders"] = 0
	ui.update_hud(turn, "player", cp, _hud_wx())

# ---------- 警戒射擊（GDD/01 §3：本作靈魂，不可閹割） ----------
# 敵單位「移動中」會被我方警戒單位自動射擊；傷害減半、不消耗 CP、不算該單位已行動。
# 誰有警戒能力＝讀 data/class_base.json 的 alert 欄位（專案鐵律 3：數值只准放 data/）。
# 原本寫死成常數陣列，與資料重複且會不同步——資料裡 specops/tank/sam 都是 true。
func _can_alert(cls: String) -> bool:
	return bool(GameData.class_base.get(cls, {}).get("alert", false))
const ALERT_GAP := {"mg": 0.25}     # 機槍兵間隔減半——這就是機槍兵存在的意義（GDD §3）
const ALERT_GAP_DEFAULT := 0.5
const ALERT_RANGE_K := 0.8          # 警戒射程＝武器射程 ×0.8
const ALERT_DMG_K := 0.5

# 單位「當下」的遊戲座標：wx/wy 在下令當下就跳到終點，迎擊要用畫面上真實的位置。
func _live_px(u) -> Vector2:
	# 節點可能在同一幀內被擊殺釋放（die → queue_free），但 arrived 等訊號還在路上。
	# 死者回傳最後已知座標——比在每個呼叫端各加一層 is_instance_valid 可靠。
	if not is_instance_valid(u.get("node")):
		return Vector2(float(u.get("wx", 0.0)), float(u.get("wy", 0.0)))
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	var p: Vector3 = u["node"].global_position
	return Vector2(p.x / WORLD_SCALE + mw * 0.5, p.z / WORLD_SCALE + mh * 0.5)

func _in_bush(p: Vector2) -> bool:
	for c in _covers:
		if c["type"] == "bush" and Vector2(c["wx"] - p.x, c["wy"] - p.y).length() <= c["r"]:
			return true
	return false

# 視線是否無阻擋（GDD/01 §3 要求、§5「建築/岩石完全阻擋視線」）：
# 線段對圓的最短距離判定，只有 building 類掩體擋線。
func _los_clear(a: Vector2, b: Vector2) -> bool:
	# 牆擋視線（GDD/14 §2）：門窗缺口不擋，所以用「實心牆段」逐段做線段相交，
	# 比舊的圓形近似準得多——站在窗邊就是射得到，站在牆後就是射不到。
	for bd in _buildings:
		for w in bd.walls:
			if _seg_hit(a, b, w["a"], w["b"]):
				return false
	return true

# 從 a 打一條線到 b，回傳最近的牆命中比例（0~1，1＝沒撞到）。鏡頭碰撞用。
# 只看牆的水平投影：牆是落地到頂的，垂直方向不必算。
# 這個世界座標在不在某棟建築室內（鏡頭用：角色在屋裡時鏡頭不可以跑到牆外）
func _pos_indoors(p: Vector3) -> bool:
	var px: float = p.x / WORLD_SCALE + float(map_data.get("w", 960)) * 0.5
	var py: float = p.z / WORLD_SCALE + float(map_data.get("h", 600)) * 0.5
	for bd in _buildings:
		if bd.inside(px, py):
			return true
	return false

# 寬鬆版室內判定（鏡頭約束的「觸發」用）：inside() 內縮 30cm 是給「鏡頭能停哪」用的，
# 拿它當觸發的話，**人貼牆或站門口那 30cm 殼層時觸發條件會斷開**，
# 室內鏡頭約束整個關掉、鏡頭穿出牆外＝隔著牆看到外面（2026-07-28 使用者回報）。
func _pos_indoors_loose(p: Vector3) -> bool:
	var px: float = p.x / WORLD_SCALE + float(map_data.get("w", 960)) * 0.5
	var py: float = p.z / WORLD_SCALE + float(map_data.get("h", 600)) * 0.5
	for bd in _buildings:
		if bd.rect.grow(-1.0).has_point(Vector2(px, py)):
			return true
	return false

# 視線是否越過障礙頂（鐵律 0②：遮蔽看幾何不看標籤）。
# ⚠ _wall_ray 原本是純 2D——1.0m 的鐵絲網把 1.6m 高的視線「擋住」，
#   鏡頭被一道跨得過去的鐵絲網一路往回拉（ch15 壓測 [walkcam] 抓到的兇手）。
#   視線在障礙頂之上就不算擋。h≥6（建築實牆/樹冠）直接當擋，省一次地形取樣。
func _ray_over(a: Vector3, b: Vector3, t: float, h: float, hx: float, hy: float) -> bool:
	if h >= 6.0:
		return false
	var gy: float = terrain.height_at_mesh(hx, hy) if terrain != null else 0.0
	return a.y + (b.y - a.y) * t > gy + h + 0.08

func _wall_ray(a: Vector3, b: Vector3) -> float:
	if _buildings.is_empty() and _blockers.is_empty():
		return 1.0
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	var p1 := Vector2(a.x / WORLD_SCALE + mw * 0.5, a.z / WORLD_SCALE + mh * 0.5)
	var p2 := Vector2(b.x / WORLD_SCALE + mw * 0.5, b.z / WORLD_SCALE + mh * 0.5)
	var best := 1.0
	var d1: Vector2 = p2 - p1
	for bd in _buildings:
		for w in bd.walls:
			var p3: Vector2 = w["a"]
			var p4: Vector2 = w["b"]
			var d2: Vector2 = p4 - p3
			var den: float = d1.cross(d2)
			if absf(den) < 0.00001:
				continue
			var t: float = (p3 - p1).cross(d2) / den
			var u: float = (p3 - p1).cross(d1) / den
			if t > 0.0 and t < best and u > 0.0 and u < 1.0:
				var hp := p1 + d1 * t
				if not _ray_over(a, b, t, float(w.get("h", 99.0)), hp.x, hp.y):
					best = t
	# 樹與粗障礙也要擋鏡頭（半徑 0.35m 以上：樹幹/樹叢/龍牙）。
	# 電線桿 0.32m、柵欄 0.14m 不列入——那麼細的東西一直把鏡頭往回拉很煩，
	# 而且它們本來就遮不住什麼。
	# ⚠ 求交必須取「射線進入圓的那個交點」，不是「線段上離圓心最近的點」：
	#   寫成最近點時，鏡頭落在樹幹內部會算出 t≈1（最近點就是端點本身）＝判定成沒擋到，
	#   鏡頭就停在樹幹裡，整個畫面被樹幹填滿（2026-07-26 實拍匍匐時抓到，查了兩輪）。
	var l2: float = d1.length_squared()
	if l2 > 0.0001:
		var seg_len: float = sqrt(l2)
		for bk in _blockers:
			var rr: float = float(bk["r"])
			# ★★2026-07-27：這裡原本第一行就是 `if bk["t"] != "cir": continue`——
			#   **所有線段型障礙整批被跳過**，而磚牆殘段、紐澤西護欄、木柵欄全是線段。
			#   後果：第三人稱鏡頭照樣鑽進磚牆，室內環顧有一個方向整格畫面是紅磚
			#   （使用者實際玩到）。線段要擋，但只擋「夠厚又夠高」的——
			#   0.14m 的木柵欄一直把鏡頭往回拉很煩，而且它本來也遮不住什麼。
			if bk["t"] == "seg":
				if rr * WORLD_SCALE < 0.18 or float(bk.get("h", 0.0)) < 1.0:
					continue
				# ⚠ 這個迴圈裡的 a/b 是 Vector3（世界座標）；線段求交要用換算好的 px 座標 p1/p2
				var ts: float = _seg_param(p1, p2, bk["a"], bk["b"])
				if ts > 0.0 and ts < best:
					var hps := p1 + d1 * ts
					if not _ray_over(a, b, ts, float(bk.get("h", 0.0)), hps.x, hps.y):
						best = ts
				continue
			# ⚠ 深水圍欄是**看不見的**（h=0，只擋人不擋彈也不該擋鏡頭）。
			#   2026-07-28 加了 52 根樁之後，鏡頭穿牆從 4 次跳到 19 次——
			#   鏡頭被一根畫面上根本不存在的柱子往回拉，玩家只會覺得鏡頭在抽搐。
			#   凡是「規則上的障礙」都不可以參與視覺判定。
			if String(bk.get("k", "")) == "deepwater":
				continue
			if bk["t"] == "obb":
				# 長條形障礙（車輛殘骸）：鏡頭一樣不能鑽進去
				var tb: float = _blk_ray_t(bk, p1, p2)
				if tb > 0.0 and tb < best:
					var hpo := p1 + d1 * tb
					if not _ray_over(a, b, tb, float(bk.get("h", 2.0)), hpo.x, hpo.y):
						best = tb
				continue
			# ⚠ 0.35m 會把樹幹算進來（椰子/松/闊葉的幹是 0.21~0.41m）。
			#   走查實拍：鏡頭被一根椰子樹幹卡住，畫面右半邊全是樹皮。
			#   樹幹很細，鏡頭短暫穿過去幾乎看不出來；鏡頭被細桿子一直往回拉才是災難。
			#   門檻拉到 0.55m ＝只有樹叢(0.85)、龍牙(0.62)、大石這種真的擋得住視線的才算。
			if bk["t"] != "cir" or rr * WORLD_SCALE < 0.55:
				continue
			var c: Vector2 = bk["c"]
			var t_close: float = (c - p1).dot(d1) / l2
			var perp: float = (p1 + d1 * t_close).distance_to(c)
			if perp >= rr:
				continue
			var half: float = sqrt(rr * rr - perp * perp) / seg_len
			var t_enter: float = t_close - half
			if t_enter > 0.0 and t_enter < best:
				var hpc := p1 + d1 * t_enter
				if not _ray_over(a, b, t_enter, float(bk.get("h", 9.0)), hpc.x, hpc.y):
					best = t_enter
	return best

# 診斷版：跟 _wall_ray 同一套過濾，但回傳「最先擋住的是什麼」的描述。
# 只給測試臺印報告用——鏡頭穿牆抓到卻不知道兇手是誰，就只能一輪一輪猜（ch02 教訓）。
func _wall_ray_why(a: Vector3, b: Vector3) -> String:
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	var p1 := Vector2(a.x / WORLD_SCALE + mw * 0.5, a.z / WORLD_SCALE + mh * 0.5)
	var p2 := Vector2(b.x / WORLD_SCALE + mw * 0.5, b.z / WORLD_SCALE + mh * 0.5)
	var best := 1.0
	var why := "（找不到＝可能是 building 牆之外的東西）"
	var d1: Vector2 = p2 - p1
	for bd in _buildings:
		for w in bd.walls:
			var p3: Vector2 = w["a"]
			var d2: Vector2 = (w["b"] as Vector2) - p3
			var den: float = d1.cross(d2)
			if absf(den) < 0.00001:
				continue
			var t: float = (p3 - p1).cross(d2) / den
			var u: float = (p3 - p1).cross(d1) / den
			if t > 0.0 and t < best and u > 0.0 and u < 1.0 \
					and not _ray_over(a, b, t, float(w.get("h", 99.0)),
					(p1 + d1 * t).x, (p1 + d1 * t).y):
				best = t
				why = "建築牆 %s" % [str(bd.rect)]
	var l2: float = d1.length_squared()
	if l2 > 0.0001:
		var seg_len: float = sqrt(l2)
		for bk in _blockers:
			var rr: float = float(bk["r"])
			if bk["t"] == "seg":
				if rr * WORLD_SCALE < 0.18 or float(bk.get("h", 0.0)) < 1.0:
					continue
				var ts: float = _seg_param(p1, p2, bk["a"], bk["b"])
				if ts > 0.0 and ts < best \
						and not _ray_over(a, b, ts, float(bk.get("h", 0.0)),
						(p1 + d1 * ts).x, (p1 + d1 * ts).y):
					best = ts
					why = "線段障礙 k=%s r=%.2fm h=%.2fm" % [str(bk.get("k", "?")),
							rr * WORLD_SCALE, float(bk.get("h", 0.0))]
				continue
			if String(bk.get("k", "")) == "deepwater":
				continue
			if bk["t"] == "obb":
				var tb: float = _blk_ray_t(bk, p1, p2)
				if tb > 0.0 and tb < best \
						and not _ray_over(a, b, tb, float(bk.get("h", 2.0)),
						(p1 + d1 * tb).x, (p1 + d1 * tb).y):
					best = tb
					why = "OBB k=%s" % str(bk.get("k", "車骸"))
				continue
			if bk["t"] != "cir" or rr * WORLD_SCALE < 0.55:
				continue
			var c: Vector2 = bk["c"]
			var t_close: float = (c - p1).dot(d1) / l2
			var perp: float = (p1 + d1 * t_close).distance_to(c)
			if perp >= rr:
				continue
			var half: float = sqrt(rr * rr - perp * perp) / seg_len
			var t_enter: float = t_close - half
			if t_enter > 0.0 and t_enter < best \
					and not _ray_over(a, b, t_enter, float(bk.get("h", 9.0)),
					(p1 + d1 * t_enter).x, (p1 + d1 * t_enter).y):
				best = t_enter
				why = "圓障礙 k=%s r=%.2fm h=%.2fm c=(%.0f,%.0f)" % [str(bk.get("k", "樹/石?")),
						rr * WORLD_SCALE, float(bk.get("h", 0.0)), c.x, c.y]
	return why

# 彈道是否通暢（GDD/01 §3、GDD/14 §2）。
# ⚠ 為什麼不能沿用 _los_clear：那支只掃建築牆，於是沙包、樹、護欄、拒馬、磚牆殘段、
#   卡車殘骸、坦克全都不擋子彈——使用者 2026-07-26 實測「子彈可以穿過這種物體」就是這條。
# ya/yb＝射出點與命中點的離地高度（公尺）。障礙比該處的彈道低就打得過去：
#   蹲在沙包（1.33m）後面被打不到，站起來上半身就露出來——這才合理，
#   而不是「一律擋」（那沙包會變成無敵護盾）或「一律不擋」（現況）。
# 註：高度一律當成「相對各自腳下地面」，不算地形起伏；戰場坡度緩，這個近似夠用。
func _shot_clear(a: Vector2, b: Vector2, ya: float, yb: float,
		ign_a = null, ign_b = null) -> bool:
	for bd in _buildings:
		for w in bd.walls:
			if not _seg_hit(a, b, w["a"], w["b"]):
				continue
			# ⚠ 牆段現在帶高度：整面牆通到屋頂照樣全擋，但**窗台只有 1.0m**。
			#   先前一律全擋 → 窗口射不出去也射不進來，窗戶只是一個貼圖上的洞。
			var wh: float = float(w.get("h", 99.0))
			var tw: float = _seg_param(a, b, w["a"], w["b"])
			if tw < 0.0:
				tw = 0.5
			if lerpf(ya, yb, tw) < wh:
				return false
	var d1: Vector2 = b - a
	var l2: float = d1.length_squared()
	if l2 < 0.0001:
		return true
	var seg_len: float = sqrt(l2)
	for bk in _blockers:
		var t: float = _blk_ray_t(bk, a, b)
		if t <= 0.001 or t >= 1.0:
			continue                  # 貼著障礙開火（t≈0）不算被自己的掩體擋住
		if lerpf(ya, yb, t) < float(bk.get("h", 1.2)):
			# 木柵欄／木桿：子彈穿得過去（鐵律 0②材質差異），只是會偏、會減速。
			# 命中率的懲罰在 _pen_count() 算，這裡只負責「擋不擋」。
			if bool(bk.get("pen", false)):
				continue
			return false
	# 單位本身也是固體（鐵律 0①）。射手與目標本身要排除。
	# 載具＝3m 級的鋼鐵、2.4m 高，任何姿勢的彈道都擋。
	# ⚠ 步兵先前完全不擋彈道，於是隔著三個人也打得到最後一個——這和「1.32m 的沙包擋得住」
	#   直接矛盾（沙包是固體、人不是？）。人一樣看高度：站著擋到 1.75m、蹲 1.22m、
	#   趴 0.55m，所以「隊友趴下讓出火線」在規則層是真的成立，不是演出。
	#   敵我同一條規則——物理不看陣營。
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	for v in units:
		if v == ign_a or v == ign_b or not v["alive"] or not is_instance_valid(v["node"]):
			continue
		# 載具用實際車體盒（3.1×6.0m）——用圓的話車頭與車尾的彈道會直接穿過去
		if Unit.is_vehicle_cls(v["cls"]):
			var tvb: float = _blk_ray_t(_vehicle_obb(v), a, b)
			if tvb > 0.001 and tvb < 1.0:
				return false
			continue
		var vp := Vector2(v["node"].global_position.x / WORLD_SCALE + mw * 0.5,
				v["node"].global_position.z / WORLD_SCALE + mh * 0.5)
		var rv: float = BODY_R / WORLD_SCALE
		var tcv: float = (vp - a).dot(d1) / l2
		var pv: float = (a + d1 * tcv).distance_to(vp)
		if pv >= rv:
			continue
		var tv: float = tcv - sqrt(rv * rv - pv * pv) / seg_len
		if tv <= 0.001 or tv >= 1.0:
			continue
		if lerpf(ya, yb, tv) < v["node"].body_top():
			return false
	return true

# 實體射線：從 a 到 b，回傳最近命中比例（0~1，1＝沒撞到）。牆一律擋；中景障礙
# 只有「比射線在該點的離地高度還高」才擋（槍口 1.3m 高本來就該越過 1.05m 的柵欄）。
# 給 Unit.solid_probe 用（貼牆抬槍）。
# 腳下支撐面（地形 ∪ 建築樓板）。Unit.ground_sampler 走這裡。
# 支撐面粗剔除框＝所有建築與矮障礙的聯集外框。戰場上絕大多數取樣點都在框外，
# 一次 Rect2.has_point 就能省掉整個迴圈。
func _rebuild_support_box() -> void:
	_low_grid = {}
	_has_support = not _buildings.is_empty()
	for bk in _low_blk:
		var bb: Rect2 = _blk_aabb(bk)
		var x0: int = int(floor(bb.position.x / LOWGRID_PX))
		var x1: int = int(floor(bb.end.x / LOWGRID_PX))
		var y0: int = int(floor(bb.position.y / LOWGRID_PX))
		var y1: int = int(floor(bb.end.y / LOWGRID_PX))
		for gx in range(x0, x1 + 1):
			for gy in range(y0, y1 + 1):
				var key := Vector2i(gx, gy)
				if not _low_grid.has(key):
					_low_grid[key] = []
				(_low_grid[key] as Array).append(bk)
		_has_support = true

func _ground_height(p: Vector3) -> float:
	var g: float = terrain.height_at_world(p) if terrain != null else 0.0
	if not _has_support:
		return g
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	var px: float = p.x / WORLD_SCALE + mw * 0.5
	var py: float = p.z / WORLD_SCALE + mh * 0.5

	for bd in _buildings:
		var f: float = bd.floor_at(px, py, p.y)
		if f > g:
			g = f
	# 矮障礙的頂面：踩在 0.22m 的沙包上，腳就在 0.22m，不是穿過去也不是被彈開。
	# 只掃 _low_blk（少數幾個），全表掃會被每幀 5 次的取樣成本吃掉幀時。
	var q := Vector2(px, py)
	var cell: Array = _low_grid.get(Vector2i(int(floor(px / LOWGRID_PX)),
			int(floor(py / LOWGRID_PX))), [])
	for bk in cell:
		if not _blk_inside(bk, q):
			continue
		# 矮障礙頂面也要用「畫面上的地表」當基準（height_at_mesh），
		# 否則沙包頂與腳下地面各用一套算法，人會站在沙包裡（同 pads 那條）
		var top: float = (terrain.height_at_mesh(px, py) if terrain != null else 0.0) \
				+ float(bk.get("h", 0.2))
		if top > g:
			g = top
	return g

func _solid_ray(a: Vector3, b: Vector3) -> float:
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	var p1 := Vector2(a.x / WORLD_SCALE + mw * 0.5, a.z / WORLD_SCALE + mh * 0.5)
	var p2 := Vector2(b.x / WORLD_SCALE + mw * 0.5, b.z / WORLD_SCALE + mh * 0.5)
	var best := 1.0
	for bd in _buildings:
		for w in bd.walls:
			var t: float = _seg_param(p1, p2, w["a"], w["b"])
			if t > 0.0 and t < best:
				best = t
	var d1: Vector2 = p2 - p1
	var l2: float = d1.length_squared()
	if l2 < 0.000001:
		return best
	var seg_len: float = sqrt(l2)
	for bk in _blockers:
		var t2: float = _blk_ray_t(bk, p1, p2)
		if t2 <= 0.0 or t2 >= best:
			continue
		# 高度：射線在該點離地多高，比障礙高就過得去
		var hit3: Vector3 = a.lerp(b, t2)
		var gy: float = terrain.height_at_world(hit3) if terrain != null else 0.0
		if hit3.y - gy < float(bk.get("h", 1.2)):
			best = t2
	return best

# 兩線段的交點在第一條上的比例（0~1），沒交點回 -1
func _seg_param(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> float:
	var d1: Vector2 = p2 - p1
	var d2: Vector2 = p4 - p3
	var den: float = d1.cross(d2)
	if absf(den) < 0.00001:
		return -1.0
	var t: float = (p3 - p1).cross(d2) / den
	var u: float = (p3 - p1).cross(d1) / den
	return t if (u > 0.0 and u < 1.0) else -1.0

# 兩個單位之間「看不看得到」：同一份障礙，但兩端都用眼睛高度
func _sight_clear(observer, target) -> bool:
	var ya: float = 2.20 if Unit.is_vehicle_cls(observer["cls"]) else 1.52
	var yb: float = 1.60 if Unit.is_vehicle_cls(target["cls"]) else 1.20
	if not Unit.is_vehicle_cls(observer["cls"]) and is_instance_valid(observer["node"]):
		ya = observer["node"].eye_height()
	if not Unit.is_vehicle_cls(target["cls"]) and is_instance_valid(target["node"]):
		# 被看的一方用「頭頂稍低」的高度：只要頭露出來就會被發現
		yb = target["node"].eye_height() * 0.95
	return _shot_clear(_live_px(observer), _live_px(target), ya, yb, observer, target)

# 兩個單位之間的彈道是否通暢：高度自動用雙方姿勢（槍口→被瞄的部位）
# part＝瞄的部位：瞄頭的彈道比瞄軀幹高，所以「站在沙包後面的人軀幹打不到、頭打得到」，
# 這正是掩體該有的樣子——不是無敵護盾，也不是裝飾。
# 彈道上穿過幾層「可穿透」障礙（木柵欄、木電線桿）。
# 穿得過去不代表沒有代價：子彈會偏、會減速，所以每穿一層命中率打七折。
func _pen_count(a: Vector2, b: Vector2, ya: float, yb: float) -> int:
	var d1: Vector2 = b - a
	var l2: float = d1.length_squared()
	if l2 < 0.0001:
		return 0
	var seg_len: float = sqrt(l2)
	var n := 0
	for bk in _blockers:
		if not bool(bk.get("pen", false)):
			continue
		var t: float = _blk_ray_t(bk, a, b)
		if t > 0.001 and t < 1.0 and lerpf(ya, yb, t) < float(bk.get("h", 1.2)):
			n += 1
	return n

# 這個單位站得比地形高多少（＝站在幾樓／站在矮牆上）
func _unit_elev(u) -> float:
	if not is_instance_valid(u["node"]) or terrain == null:
		return 0.0
	return maxf(0.0, u["node"].global_position.y - terrain.height_at_world(u["node"].global_position))

# 這個目標是不是在室內（屋頂擋得住拋射彈）
func _target_indoors(u) -> bool:
	var p := _live_px(u)
	for bd in _buildings:
		if bd.inside(p.x, p.y):
			return true
	return false

func _shot_clear_units(shooter, target, part := "body") -> bool:
	# 載具用砲塔／車體高度，不吃姿勢（坦克不會蹲）
	var ya: float = 1.90 if Unit.is_vehicle_cls(shooter["cls"]) else 1.32
	var yb: float = 1.40 if Unit.is_vehicle_cls(target["cls"]) else 1.15
	# 站在二樓射擊，彈道起點就是高 3.1m（鐵律 0②：遮蔽看幾何）。
	# ⚠ 先前高度一律「相對腳下地面」，於是站二樓跟站平地的遮蔽判定完全一樣，
	#   佔領制高點沒有任何好處。
	ya += _unit_elev(shooter)
	yb += _unit_elev(target)
	if not Unit.is_vehicle_cls(shooter["cls"]) and is_instance_valid(shooter["node"]):
		ya = shooter["node"].muzzle_height()
	if not Unit.is_vehicle_cls(target["cls"]) and is_instance_valid(target["node"]):
		yb = target["node"].eye_height() if part == "head" else target["node"].torso_height()
	# 拋射武器（迫砲）＝間接射擊：砲彈從上方落下，掩體擋不住。
	# ⚠ 先前迫砲吃直線判定，於是「arc 標記＋砲管 60 度仰角」全是裝飾，
	#   它跟步槍一樣被 1.3m 的沙包擋住——那迫砲就沒有存在的理由。
	#   屋頂仍然擋得住：躲進建築才不怕迫砲，這是進建築的價值之一。
	if bool(shooter.get("weapon", {}).get("arc", false)):
		return not _target_indoors(target)
	return _shot_clear(_live_px(shooter), _live_px(target), ya, yb, shooter, target)

# 這個目標有沒有任何部位打得到（開火入口用）
func _any_part_clear(shooter, target) -> bool:
	for p in _aim_parts(shooter, target):
		if _shot_clear_units(shooter, target, p["part"]):
			return true
	return false

func _seg_hit(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> bool:
	var d1: Vector2 = p2 - p1
	var d2: Vector2 = p4 - p3
	var den: float = d1.cross(d2)
	if absf(den) < 0.00001:
		return false
	var t: float = (p3 - p1).cross(d2) / den
	var u: float = (p3 - p1).cross(d1) / den
	return t > 0.0 and t < 1.0 and u > 0.0 and u < 1.0

# 牆碰撞：把單位推出牆面（門洞不是牆段，所以走門就進得去）。
# 回傳修正後的世界座標。半徑 0.42m＝一個人的肩寬。
func _resolve_walls(pos: Vector3, radius := 0.42) -> Vector3:
	if _buildings.is_empty():
		return pos
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	var p := Vector2(pos.x / WORLD_SCALE + mw * 0.5, pos.z / WORLD_SCALE + mh * 0.5)
	var r_px: float = radius / WORLD_SCALE
	p = _push_walls_px(p, r_px)
	return Vector3((p.x - mw * 0.5) * WORLD_SCALE, pos.y, (p.y - mh * 0.5) * WORLD_SCALE)

func _push_walls_px(p_in: Vector2, r_px: float) -> Vector2:
	var p := p_in
	# ⚠ walls 存的是「牆的中心線」，只推 r_px 的話身體表面剛好貼在牆面上，
	#   模型的肩膀與背上的槍看起來就插進牆裡（使用者 2026-07-26 指正）。
	#   多推半個牆厚＋2cm 餘裕，人才是真的站在牆外。門洞寬 1.5m，仍過得去。
	r_px += (Building.WALL_T * 0.5 + 0.02) / WORLD_SCALE
	for bd in _buildings:
		if not bd.rect.grow(r_px + 20.0).has_point(p):
			continue
		for w in bd.walls:
			var a: Vector2 = w["a"]
			var b: Vector2 = w["b"]
			var ab: Vector2 = b - a
			var l2: float = ab.length_squared()
			var t: float = 0.0 if l2 < 0.0001 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
			var closest: Vector2 = a + ab * t
			var away: Vector2 = p - closest
			var d: float = away.length()
			if d < r_px and d > 0.0001:
				p = closest + away / d * r_px          # 推出去
			elif d <= 0.0001:
				p = closest + ab.orthogonal().normalized() * r_px
	return p

# ---------- 障礙形狀通用工具（2026-07-27 新增第三種形狀 obb）----------
# 為什麼要新增：長條形的東西用圓形碰撞，長軸兩端一定有一段是空的。
#   坦克 3.1×6.0m 用 r=1.6 的圓 → 車尾 1.4m 可以走進去（使用者實測）。
#   卡車殘骸 4.6×2.1m 用 r=1.5 的圓 → 貨斗兩端各 0.8m 可以走進去。
# 形狀規格（座標一律遊戲 px）：
#   {"t":"cir","c":中心,"r":半徑}
#   {"t":"seg","a":,"b":,"r":半徑,"m":中點,"hl":半長}          ＝膠囊
#   {"t":"obb","c":中心,"ax":單位向量(a 軸),"e":Vector2(半長a,半長b),"r":外皮半徑}
# ⚠ 凡是掃 `_blockers` 的迴圈一律走下面這四支，不要再自己寫 `if bk["t"] == "cir"`——
#   新增形狀時漏掉任何一處，症狀就是「畫得出來但穿得過去」，而且不會有任何錯誤訊息。
func _obb_axes(bk: Dictionary) -> Array:
	var ax: Vector2 = bk["ax"]
	return [ax, Vector2(-ax.y, ax.x)]

func _obb_local(bk: Dictionary, p: Vector2) -> Vector2:
	var ab := _obb_axes(bk)
	var d: Vector2 = p - bk["c"]
	return Vector2(d.dot(ab[0]), d.dot(ab[1]))

func _obb_world(bk: Dictionary, l: Vector2) -> Vector2:
	var ab := _obb_axes(bk)
	return bk["c"] + ab[0] * l.x + ab[1] * l.y

# 障礙上離 p 最近的點（p 在障礙內部時回傳 p 自己夾限後的位置）
func _blk_closest(bk: Dictionary, p: Vector2) -> Vector2:
	match String(bk["t"]):
		"cir":
			return bk["c"]
		"obb":
			var e: Vector2 = bk["e"]
			var l: Vector2 = _obb_local(bk, p)
			return _obb_world(bk, Vector2(clampf(l.x, -e.x, e.x), clampf(l.y, -e.y, e.y)))
		_:
			return Geometry2D.get_closest_point_to_segment(p, bk["a"], bk["b"])

# p 是否在障礙的實體範圍內（給「踩在矮障礙頂面」用）
func _blk_inside(bk: Dictionary, p: Vector2) -> bool:
	if String(bk["t"]) == "obb":
		var e: Vector2 = bk["e"]
		var l: Vector2 = _obb_local(bk, p)
		return absf(l.x) <= e.x and absf(l.y) <= e.y
	return _blk_closest(bk, p).distance_squared_to(p) < pow(float(bk["r"]), 2.0)

# 障礙的外接矩形（給空間格網粗剔除用）
func _blk_aabb(bk: Dictionary) -> Rect2:
	var r: float = float(bk.get("r", 0.0))
	match String(bk["t"]):
		"cir":
			return Rect2(bk["c"] - Vector2(r, r), Vector2(r, r) * 2.0)
		"obb":
			var ab := _obb_axes(bk)
			var e: Vector2 = bk["e"]
			var ext: Vector2 = (ab[0] * e.x).abs() + (ab[1] * e.y).abs()
			return Rect2(bk["c"] - ext, ext * 2.0).grow(r)
		_:
			return Rect2(bk["a"], Vector2.ZERO).expand(bk["b"]).grow(r)

# 把半徑 r_px 的圓（＝人）推到障礙外面。沒重疊就原樣回傳。
# ⚠ 盒內的處理是關鍵：人已經在車體裡的時候要往**最近的那一面**推出去，
#   照「離中心遠離方向」推會把人從車頭彈到車尾去。
func _blk_push(bk: Dictionary, p: Vector2, r_px: float) -> Vector2:
	var need: float = r_px + float(bk.get("r", 0.0))
	if String(bk["t"]) == "obb":
		var e: Vector2 = bk["e"]
		var l: Vector2 = _obb_local(bk, p)
		if absf(l.x) <= e.x and absf(l.y) <= e.y:
			# 在盒內：比較兩個軸向要推多遠，走最淺的那一面
			if (e.x - absf(l.x)) < (e.y - absf(l.y)):
				l.x = (e.x + need) * (1.0 if l.x >= 0.0 else -1.0)
			else:
				l.y = (e.y + need) * (1.0 if l.y >= 0.0 else -1.0)
			return _obb_world(bk, l)
		var cl := Vector2(clampf(l.x, -e.x, e.x), clampf(l.y, -e.y, e.y))
		var away: Vector2 = l - cl
		var d: float = away.length()
		if d >= need:
			return p
		return _obb_world(bk, cl + (away / d if d > 0.0001 else Vector2.RIGHT) * need)
	var closest: Vector2 = _blk_closest(bk, p)
	var away2: Vector2 = p - closest
	var d2: float = away2.length()
	if d2 >= need:
		return p
	return closest + (away2 / d2 if d2 > 0.0001 else Vector2.RIGHT) * need

# 射線 a→b 進入這個障礙的比例。沒打到回 -1。
# ⚠ 一定要回「進入點」而不是「最近點」：起點在障礙內部時最近點會算出 t≈1
#   ＝判定成沒擋到（_wall_ray 那條坑，鏡頭因此停在樹幹裡）。
func _blk_ray_t(bk: Dictionary, a: Vector2, b: Vector2) -> float:
	var d: Vector2 = b - a
	var l2: float = d.length_squared()
	if l2 < 0.000001:
		return -1.0
	var seg_len: float = sqrt(l2)
	match String(bk["t"]):
		"cir":
			var c: Vector2 = bk["c"]
			var rr: float = float(bk["r"])
			var tc: float = (c - a).dot(d) / l2
			if (a + d * tc).distance_to(c) >= rr:
				return -1.0
			var perp: float = (a + d * tc).distance_to(c)
			return tc - sqrt(rr * rr - perp * perp) / seg_len
		"obb":
			# 板塊法（slab）：在盒的座標系下對兩軸各求進出區間，取交集
			var ab := _obb_axes(bk)
			var e: Vector2 = bk["e"]
			var rel: Vector2 = a - bk["c"]
			var o := Vector2(rel.dot(ab[0]), rel.dot(ab[1]))
			var dl := Vector2(d.dot(ab[0]), d.dot(ab[1]))
			var t0 := -1.0e9
			var t1 := 1.0e9
			for i in 2:
				var oi: float = o.x if i == 0 else o.y
				var di: float = dl.x if i == 0 else dl.y
				var ei: float = (e.x if i == 0 else e.y) + float(bk.get("r", 0.0))
				if absf(di) < 0.000001:
					if absf(oi) > ei:
						return -1.0
					continue
				var ta: float = (-ei - oi) / di
				var tb: float = (ei - oi) / di
				if ta > tb:
					var sw: float = ta
					ta = tb
					tb = sw
				t0 = maxf(t0, ta)
				t1 = minf(t1, tb)
			if t0 > t1 or t1 < 0.0:
				return -1.0
			return t0
		_:
			# 粗剔除：整條射線都到不了這段柵欄
			if a.distance_squared_to(bk["m"]) > pow(float(bk["hl"]) + seg_len + float(bk["r"]), 2.0):
				return -1.0
			return _seg_param(a, b, bk["a"], bk["b"])

# 載具的碰撞盒（px，隨車身朝向轉）。
# 為什麼是動態算而不是登記進 `_blockers`：車會開、砲塔會轉，登記的靜態盒隔一幀就過期。
func _vehicle_obb(v) -> Dictionary:
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	var node = v["node"]
	var fwd := Vector2(node.global_transform.basis.z.x, node.global_transform.basis.z.z)
	if fwd.length() < 0.0001:
		fwd = Vector2(0.0, 1.0)
	return {"t": "obb",
			"c": Vector2(node.global_position.x / WORLD_SCALE + mw * 0.5,
					node.global_position.z / WORLD_SCALE + mh * 0.5),
			"ax": fwd.normalized(),
			# ⚠ 半長/半寬向載具本體要（Unit.veh_hl/veh_hw），不可再用坦克的常數：
			#   驅逐艦畫 18m 長卻用 6m 的碰撞盒＝船身大半沒有實體，
			#   跟當年「坦克用圓形碰撞、車頭車尾能穿過去」是同一個錯。
			"e": Vector2(node.veh_hl if "veh_hl" in node else VEHICLE_HL,
					node.veh_hw if "veh_hw" in node else VEHICLE_HW) / WORLD_SCALE,
			"r": 0.0, "h": 2.4}

# 完整實體解算＝建築牆 ＋ 中景物件／樹（Props.blockers）＋ 載具本身。
# ⚠ 2026-07-26 只做了建築牆，結果護欄、拒馬、電線桿、樹、坦克全都能直接穿過去，
#   在第三人稱裡看起來就是「這些東西是畫上去的」。障礙的真相要跟畫出來的一致。
# ignore＝要略過的單位（算自己時不能被自己推）。
# 邊界與實體同時滿足（鐵律0①）。舊寫法 `_clamp_to_map(_resolve_solids(p))` 有順序病：
# 解算把人推出障礙 → 夾限又把人推回障礙裡 → 每幀來回，人永遠卡在邊界線上
# （walk ch01/ch06/ch13 的 16 筆 FAIL 座標全部剛好落在離邊界 1m 那條線）。
# 正解＝交替迭代到同時成立；真的兩邊都不滿足（例如深水圍欄貼著邊界）時，
# 最後一步一律**往地圖內側推**——寧可站進場內，也不可以卡在牆裡。
# 診斷：到底是**什麼**把這個點推開（給「陷進實體」的斷言用）。
# 與 _resolve_solids 逐項對照同一批來源，回報每一項造成的位移，
# 這樣斷言就不只給座標，而是直接指出兇手。
func _why_solid(wp: Vector3, radius: float, ignore) -> String:
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	var p := Vector2(wp.x / WORLD_SCALE + mw * 0.5, wp.z / WORLD_SCALE + mh * 0.5)
	var r_px: float = radius / WORLD_SCALE
	var out: Array = []
	if not _buildings.is_empty():
		var aft: Vector2 = _push_walls_px(p, r_px)
		if aft.distance_to(p) > 0.001:
			out.append("建築牆 %.2fm" % (aft.distance_to(p) * WORLD_SCALE))
	for bk in _blockers:
		if float(bk.get("h", 1.2)) <= STEP_UP and String(bk.get("k", "")) != "deepwater":
			continue
		if not _blk_aabb(bk).grow(r_px).has_point(p):
			continue
		var q: Vector2 = _blk_push(bk, p, r_px)
		if q.distance_to(p) > 0.001:
			out.append("%s/%s %.2fm" % [String(bk.get("t", "?")),
					String(bk.get("k", "-")), q.distance_to(p) * WORLD_SCALE])
	for v in units:
		if v == ignore or not Unit.is_vehicle_cls(v["cls"]) or not is_instance_valid(v["node"]):
			continue
		# ⚠ 高度判定必須跟 _resolve_solids **一模一樣**（2026-08-03，stress ch12）：
		#   少了這一條，14m 高空的戰鬥機會被列進地面坦克的推擠來源，
		#   診斷本身就在誤導人往錯的方向查。同一條規則兩份實作＝本專案的老坑，
		#   而「診斷」也是一份實作。
		if absf(v["node"].global_position.y - wp.y) > 2.5:
			continue
		var q2: Vector2 = _blk_push(_vehicle_obb(v), p, r_px)
		if q2.distance_to(p) > 0.001:
			out.append("載具%s %.2fm" % [String(v["cls"]), q2.distance_to(p) * WORLD_SCALE])
	if terrain != null:
		out.append("水深%.2fm" % terrain.water_depth(p.x, p.y))
	return str(out)

func _settle(pos: Vector3, radius: float, ignore) -> Vector3:
	var p := pos
	for _i in 4:
		var before := p
		p = _clamp_to_map(_resolve_solids(p, radius, ignore))
		if before.distance_squared_to(p) < 0.000001:
			return p
	# 沒收斂＝被夾在邊界與障礙之間。最後手段是往場內退一點點，但有三道限制：
	# ⚠⚠ 2026-08-01 回歸教訓：第一版無限制地「往場內推 12 步（最多 4.2m）」，
	#   在第 7 章把人推**穿過深水圍欄、直接推進河裡**（walk ch07 一次 3357 筆
	#   「走進深水」）。逃生用的位移不可以把人送進另一種不合法狀態——
	#   逃生只能逃到「合法的地方」，否則就是用一個 bug 換另一個更糟的 bug。
	# 診斷用：走到逃生分支的次數。待機時這個數字若不是 0，飄移的兇手就是它
	# （逃生位移每步 0.35m，每幀都走一次就是持續爬行）。
	if _drift_dbg and ignore is Dictionary:
		_drift_esc(ignore)
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	var hx: float = mw * 0.5 * WORLD_SCALE
	var hz: float = mh * 0.5 * WORLD_SCALE
	var near_x: float = minf(absf(p.x + hx), absf(p.x - hx))
	var near_z: float = minf(absf(p.z + hz), absf(p.z - hz))
	# ⚠⚠ 2026-08-04（walk ch01 FAILS=20，20 筆全在同一座標 px(1108,236)）：
	#   限制①原本是「只有貼著邊界（1.6m 內）才啟動逃生」，於是**在地圖內部被夾住的人
	#   完全沒有逃生路徑**——實拍是人卡在一輛卡車殘骸裡出不來，走查因此只抵達 129 段
	#   中的 7 段（卡住之後整段走查就廢了）。
	#   邊界帶那條限制的用意是「別亂推」，不是「內部不准逃」。改成：
	#     · 貼邊界 → 逃生方向以「往場內」為主（原行為不變）
	#     · 在內部 → 逃生方向改用**解算想推的方向**（那就是離開障礙的方向）
	#   距離上限 2.1m、不可退進深水這兩條**維持不變**——ch07 那 3357 筆的教訓是
	#   「逃生不可送進另一種不合法狀態」，換方向不違反它，放寬距離才會。
	var inward: Vector3
	if minf(near_x, near_z) <= 1.6:
		inward = Vector3((1.0 if p.x < 0.0 else -1.0) if near_x <= near_z else 0.0, 0.0,
				0.0 if near_x <= near_z else (1.0 if p.z < 0.0 else -1.0))
	else:
		var want: Vector3 = _resolve_solids(p, radius, ignore)
		var away := Vector3(want.x - p.x, 0.0, want.z - p.z)
		if away.length() < 0.0001:
			return p              # 解算也說不出往哪推＝真的沒被夾住，維持原位
		inward = away.normalized()
	# ⚠⚠ 2026-08-02（stress ch09 海圖）：逃生方向不能只有「垂直邊界往場內」一個。
	#   那張圖的邊界外緣是一條可站的窄地、往內就是深水，於是限制③ 在第一步就
	#   break，單位停在原地＝「陷進實體」，迭代再多次也無解。
	#   現實裡被卡在岸邊的人會**沿著岸走**，不是只能往水裡走。
	#   所以候選方向加上「沿邊界滑動」與兩個斜向；**距離上限與不可進深水維持不變**
	#   ——ch07 那 3357 筆的教訓是「逃生不可送進另一種不合法狀態」，
	#   放寬方向不違反它，放寬距離才會。
	var along := Vector3(inward.z, 0.0, inward.x)      # 與 inward 垂直＝沿著邊界
	var cands: Array = [inward, along, -along,
			(inward + along).normalized(), (inward - along).normalized()]
	# 目前是不是已經泡在深水裡（決定限制③ 怎麼套，見下）
	var cur_depth := 0.0
	if terrain != null:
		cur_depth = terrain.water_depth(p.x / WORLD_SCALE + mw * 0.5,
				p.z / WORLD_SCALE + mh * 0.5)
	var in_deep: bool = cur_depth > BattleTerrain.WADE_MAX
	var best := p
	for d in cands:
		var q := p
		var qd := cur_depth
		var escaped := false
		for _k in 6:                  # 限制②：最多退 6 步（2.1m），不是 4.2m
			var np: Vector3 = q + d * 0.35
			# 限制③：不可退進深水。
			# ⚠⚠ 但這條要寫成「不可變得**更糟**」，不是「下一步必須已經是陸地」
			#   （2026-08-02，stress ch09）：人若已經泡在深水裡（例如被 18m 的
			#   軍艦推下海），每個方向的下一步都還是深水，於是全部 break、
			#   永遠爬不上岸＝「陷進實體」怎麼修都在同一個座標。
			#   現實裡落水的人會往**變淺**的方向走上岸，這才是這條不變量的原意。
			if terrain != null:
				var npx: float = np.x / WORLD_SCALE + mw * 0.5
				var npy: float = np.z / WORLD_SCALE + mh * 0.5
				var nd: float = terrain.water_depth(npx, npy)
				if in_deep:
					if nd >= qd:
						break        # 已在深水：只准往越來越淺的方向爬
				elif nd > BattleTerrain.WADE_MAX:
					break            # 還在陸上：不可以踏進深水
				qd = nd
			q = np
			var chk: Vector3 = _resolve_solids(q, radius, ignore)
			if Vector2(chk.x - q.x, chk.z - q.z).length() < 0.06:
				escaped = true
				break
		if escaped:
			return _clamp_to_map(q)
		# 沒完全脫困也記下走得最遠的那一個：總比留在原地好
		if q.distance_squared_to(p) > best.distance_squared_to(p):
			best = q
	return _clamp_to_map(best)

# ⚠ 這裡原本還有一支 _drop_edge_blockers()：把「離邊界 1.6m 內」的障礙整個丟掉。
#   2026-08-01 移除，因為它是**同一條規則的第二份實作**（本專案反覆踩的坑）：
#   邊界卡人的真因是上面 _settle 講的順序病，實測 ch01 重驗時它丟棄 0 個障礙
#   卻已經 0 FAIL——它沒在解決問題，卻會默默刪掉地圖邊緣的樹與道具（改動關卡設計）。

func _resolve_solids(pos: Vector3, radius := 0.42, ignore = null) -> Vector3:
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	var p := Vector2(pos.x / WORLD_SCALE + mw * 0.5, pos.z / WORLD_SCALE + mh * 0.5)
	var r_px: float = radius / WORLD_SCALE
	# ⚠ 要跑兩輪：被 A 推出去之後可能正好推進 B 裡（車體與牆之間、兩道柵欄的夾角）。
	#   單輪解算的症狀就是「某些角落還是穿得過去」，而且只在特定夾角出現、很難重現。
	#   第二輪沒有任何改變就提早結束，平時不花成本。
	# 四輪（第 N 輪無變化就提早結束）：兩輪在「三個障礙互夾」時仍可能不收斂
	# （walk ch11 電線桿×柵欄實測），平時第二輪就 break、不多花成本。
	for _pass in 4:
		var p0 := p
		if not _buildings.is_empty():
			p = _push_walls_px(p, r_px)
		for bk in _blockers:
			# ⚠ 深水圍欄的 h 登記成 0.0（它不擋子彈），但它擋人——不能被當成「矮到可以踩過去」。
			#   高度欄位在這裡有兩種語意，必須用 k 區分，否則新規則會把海當平地。
			if float(bk.get("h", 1.2)) <= STEP_UP and String(bk.get("k", "")) != "deepwater":
				continue          # 矮障礙用「踩上去」處理（_ground_height），不水平推
			# 粗剔除：外接框都碰不到就不必算
			if not _blk_aabb(bk).grow(r_px).has_point(p):
				continue
			p = _blk_push(bk, p, r_px)
		# 載具＝3m 級的鋼鐵，人不可能從中間穿過去（被撞的一方是人，坦克不讓路）
		for v in units:
			if v == ignore or not Unit.is_vehicle_cls(v["cls"]) or not is_instance_valid(v["node"]):
				continue
			# ⚠⚠ 高度要看（2026-08-02，stress ch09 實測 0.78m）：載具的 OBB 是
			#   **px 平面**的 2D 判定，不看 y。於是在 100m 巡航高度的戰鬥機
			#   （collide_hw=4.9＝翼展）照樣把地面上的人推開，人被推到地圖邊界
			#   夾限線上就成了「陷進實體」。飛機在天上，跟地面的人不在同一層，
			#   本來就不該碰（鐵律 0①講的是固體互穿，不是投影互穿）。
			#   用實際高度差而不是「是不是 air」：武裝直升機低空掠過時仍該撞得到。
			if absf(v["node"].global_position.y - pos.y) > 2.5:
				continue
			p = _blk_push(_vehicle_obb(v), p, r_px)
		if p.distance_squared_to(p0) < 0.000001:
			break
	return Vector3((p.x - mw * 0.5) * WORLD_SCALE, pos.y, (p.y - mh * 0.5) * WORLD_SCALE)

# 路徑是否走得通（AI09 尋路）：沿線每 0.6m 取樣，只要有一點會被實體推開就算不通。
# 為什麼要有這個：AI 是直線推進，戰場變成實體之後，一道柵欄就能讓它貼著磨到
# AP 用盡或 12 秒逾時——玩家看到的是「敵人在原地抽搐」，不是戰術。
func _path_clear(from_p: Vector3, to_p: Vector3, radius: float) -> bool:
	var d: Vector3 = to_p - from_p
	d.y = 0.0
	var total: float = d.length()
	if total < 0.01:
		return true
	var steps: int = maxi(2, int(total / 0.6))
	for i in range(1, steps + 1):
		var q: Vector3 = from_p + d * (float(i) / float(steps))
		var fixed: Vector3 = _resolve_solids(q, radius, null)
		if Vector2(fixed.x - q.x, fixed.z - q.z).length() > 0.02:
			return false
	return true

# 繞開障礙：直線不通就把前進方向左右各偏一點試，取第一條通的。
# 這不是完整 A*——戰場障礙稀疏，偏轉試探已經夠用，而且每次下令只算一次。
# 全部不通就回傳「往原方向走到撞上為止」，交給停滯偵測收尾。
func _avoid_goal(from_p: Vector3, goal: Vector3, radius: float) -> Vector3:
	if _path_clear(from_p, goal, radius):
		return goal
	var d: Vector3 = goal - from_p
	d.y = 0.0
	var dist: float = d.length()
	if dist < 0.01:
		return goal
	var base: float = atan2(d.z, d.x)
	for deg in [20.0, -20.0, 40.0, -40.0, 62.0, -62.0, 85.0, -85.0]:
		var a: float = base + deg_to_rad(deg)
		# 繞路要繞得夠遠才過得去，但不能超過原本想走的距離太多
		var way: Vector3 = from_p + Vector3(cos(a), 0, sin(a)) * dist
		if _path_clear(from_p, way, radius):
			return way
	return goal

# 受擊與陣亡動作驗收（從 _selftest 抽出來：測試對象可能中途陣亡要換人）
func _anichk(u3) -> void:
	# ⚠ 先站起來再測：狙擊手在空地會自動趴下，趴著的頭本來就只有 0.33m，
	#   再倒地也降不了多少，會把「倒地動作正常」誤判成 FAIL（2026-07-27 實測到）。
	u3.stance_cmd = "stand"
	u3.want_prone = false
	await get_tree().create_timer(1.2).timeout
	var head_up: float = u3._rig.bone_pos("Head").y - u3.global_position.y
	u3.take_hit()
	await get_tree().create_timer(0.2).timeout    # 受擊動作很短，太晚量會量到已回 idle
	await _snap("res://close_hit.png")
	print("[anichk] 受擊動作 state=%s %s" % [u3._state, "OK" if u3._state == "hit" else "FAIL"])
	u3.die()
	await get_tree().create_timer(1.8).timeout    # 等倒地動作播完，不然量到半途
	var head_dn: float = u3._rig.bone_pos("Head").y - u3.global_position.y
	await _snap("res://close_death.png")
	print("[anichk] 陣亡倒地 頭高 %.2f→%.2f %s" % [
		head_up, head_dn, "OK" if head_dn < head_up * 0.6 else "FAIL(沒倒下)"])

# 驗收台專用：讓測試對象在測試期間打不死。
# ⚠ 這已經是第三次踩到同一件事（crawlchk / anichk / camchk）：驗姿勢或鏡頭的測試
#   會讓單位在戰場上走好幾秒，敵方警戒射擊一開火它就 queue_free，
#   下一行讀 global_position / _rig 直接炸「previously freed」。
#   驗表現的測試不該被戰鬥干擾——凡是「用走的」超過一兩秒的段落都要先上護盾。
func _shield(u) -> Array:
	var save := [int(u["hp"]), int(u["maxhp"])]
	u["hp"] = 999999
	u["maxhp"] = 999999
	return save

func _unshield(u, save: Array) -> void:
	u["hp"] = save[0]
	u["maxhp"] = save[1]

# 找一塊空地（驗收台用）：離建築與所有實體障礙至少 clear_m 公尺。
# ⚠ 一定要分級放寬：門檻開太高會整張圖找不到，然後退回「地圖中央」——
#   而地圖中央往往就是一棟房子裡（2026-07-26 實測 FAIL 兩項）。
# ⚠ 也要避開敵方單位：驗姿勢的側視圖被敵人擋住就等於沒拍到，
#   而且測試對象會一直「遭到迎擊」干擾畫面（實拍兩張都被擋）。
func _open_spot(clears: Array, away_from_foes := 0.0) -> Vector2:
	var mw2: float = float(map_data.get("w", 960))
	var mh2: float = float(map_data.get("h", 600))
	for clear_m in clears:
		var cr: float = float(clear_m) / WORLD_SCALE
		for gy in range(2, 13):
			for gx in range(2, 19):
				var cand := Vector2(mw2 * float(gx) / 20.0, mh2 * float(gy) / 14.0)
				var bad := false
				for bd2 in _buildings:
					if bd2.rect.grow(maxf(cr, 6.0 / WORLD_SCALE)).has_point(cand):
						bad = true
						break
				if not bad and away_from_foes > 0.0:
					for fu in units:
						if fu["alive"] and fu["side"] != player_side and is_instance_valid(fu["node"]):
							if cand.distance_to(Vector2(fu["wx"], fu["wy"])) < away_from_foes / WORLD_SCALE:
								bad = true
								break
				if not bad and cr > 0.0:
					for bk2 in _blockers:
						var pc: Vector2 = _blk_closest(bk2, cand)
						if cand.distance_to(pc) < cr:
							bad = true
							break
				if not bad:
					return cand
	return Vector2(mw2 * 0.5, mh2 * 0.5)

func _intercept_tick(delta: float) -> void:
	if st != St.CMD and st != St.ENEMY:
		return
	# 1) 誰在移動：躲在草叢裡移動的不觸發警戒（GDD §3 隱蔽）
	var movers: Array = []
	for m in units:
		if not m["alive"] or not is_instance_valid(m["node"]) or not m["node"].is_moving():
			continue
		var mp := _live_px(m)
		if _in_bush(mp):
			continue
		movers.append([m, mp])
	# 2) 每個警戒單位各自計時（節流要跟「有沒有目標」無關，否則會被存成一次爆發）
	for u in units:
		if not u["alive"] or not _can_alert(u["cls"]) or not is_instance_valid(u["node"]):
			continue
		u["_alert_t"] = float(u.get("_alert_t", 0.0)) + delta
		# 警戒射擊間隔隨章節縮短（只作用在敵方——玩家的節奏不該被難度動）
		var gap: float = float(ALERT_GAP.get(u["cls"], ALERT_GAP_DEFAULT))
		if u["side"] != player_side:
			gap /= maxf(float(_diff().get("alertK", 1.0)), 0.2)
		if u["_alert_t"] < gap:
			continue
		if u["node"].is_moving():
			continue                      # 自己在移動中不算警戒狀態（行動結束才進入警戒）
		var up := _live_px(u)
		var rng: float = float(u["weapon"].get("range", 200)) * ALERT_RANGE_K
		var best = null
		var bd := 1e9
		for pair in movers:
			var m = pair[0]
			if m["side"] == u["side"]:
				continue
			var d: float = up.distance_to(pair[1])
			if d <= rng and d < bd and _shot_clear_units(u, m):
				bd = d
				best = m
		if best == null:
			continue
		u["_alert_t"] = 0.0
		_intercept_fire(u, best, bd)

var _alert_shots := 0      # QA 計數：本次迎擊觸發幾次

# 坦克的警戒射擊是「車載機槍」不是主砲（GDD/01 §3）——
# 拿 220 攻擊的主砲當迎擊會直接把步兵一發清掉，完全不合理。
func _alert_weapon(u) -> Dictionary:
	if Unit.is_vehicle_cls(u["cls"]):
		var mg: Dictionary = GameData.weapons.get("lmg", {}).duplicate(true)
		mg["type"] = "lmg"
		return mg
	return u["weapon"]

func _intercept_fire(shooter, target, dist_px: float) -> void:
	_alert_shots += 1
	shooter["node"].shoot_at(target["node"])
	if shooter["side"] == player_side:
		ui.flash_msg("⚠ 迎擊射擊", Color(0.55, 0.85, 1.0))
	else:
		ui.flash_msg("⚠ 遭到迎擊！", Color(1.0, 0.5, 0.4))
	await get_tree().create_timer(0.32).timeout
	if not shooter["alive"] or not target["alive"]:
		return
	var cov: float = cover_at(target["wx"], target["wy"], shooter["wx"], shooter["wy"])
	var sh_w := {"weapon": _alert_weapon(shooter), "cls": shooter["cls"]}
	var hc: float = GameData.hit_chance(_wrap(sh_w), _wrap(target), dist_px) * (1.0 - cov * 0.6)
	if hc > randf():
		var dmg: int = int(round(GameData.damage(_wrap(sh_w), _wrap(target)) * ALERT_DMG_K))
		target["hp"] -= dmg
		if target["hp"] <= 0 and target["alive"]:
			target["alive"] = false
			target["node"].die()
		elif target["alive"]:
			target["node"].take_hit()
	_refresh_visibility()
	_check_end()

# ---------- 勝敗 ----------
func _check_end() -> void:
	if _count_side(player_side) == 0:
		_win(1 - player_side, "我方全滅")
	elif _count_side(1 - player_side) == 0:
		_win(player_side, "敵軍殲滅")

func _win(winner: int, why: String) -> void:
	if st == St.END:
		return
	st = St.END
	var w := winner == player_side
	var ch: Dictionary = GameData.story[chapter - 1] if chapter > 0 else {}
	if w and chapter > 0 and not _test_mode:
		_set_unlocked(min(chapter + 1, GameData.story.size()))
	# 經驗結算（GDD/16 §2）：擊殺＋勝利＋存活進共用經驗池。解鎖前不顯示也不累積。
	var xp_note := ""
	if w and chapter > 0 and _growth_unlocked():
		var g: Dictionary = GameData.growth
		var xp: int = int(g.get("xp_win", 120))
		for u in units:
			if u["side"] != player_side and not u["alive"]:
				xp += int(g.get("xp_kill_vehicle", 90)) if Unit.is_vehicle_cls(u["cls"]) \
						else int(g.get("xp_kill_inf", 40))
			elif u["side"] == player_side and u["alive"]:
				xp += int(g.get("xp_survivor", 15))
		_growth["pool"] = int(_growth["pool"]) + xp
		_save_growth()
		xp_note = "\n獲得經驗 +%d（經驗池 %d，到訓練場升級兵科）" % [xp, int(_growth["pool"])]
	var rank := "A" if w else ""
	Audio.sting("victory" if w else "defeat")
	ui.hide_charcard()
	ui.show_end(w, why, rank, String(ch.get("debrief", "")) + xp_note, _open_menu)

func _teardown_world() -> void:
	for u in units:
		if is_instance_valid(u["node"]):
			u["node"].queue_free()
	units = []
	selected = null
	_water_mats = []
	_tree_mats = []
	_weather_node = null
	if world and is_instance_valid(world):
		world.queue_free()
	world = null

func _build_ground() -> void:
	world = Node3D.new()
	add_child(world)
	_covers = []
	var mw: float = map_data.get("w", 960) * WORLD_SCALE
	var mh: float = map_data.get("h", 600) * WORLD_SCALE
	# 地形（GDD/14 §1）：高度場網格取代平面——丘陵、壕溝、彈坑都在這裡長出來
	terrain = TERRAIN.new()
	world.add_child(terrain)
	_boost_terrain()          # 章節難度：地形變複雜（額外彈坑與工事）
	terrain.build(map_data, WORLD_SCALE)
	_apply_sky(str(map_data.get("sky", "day")))
	_build_water()
	_build_weather()
	# 腳下高度的唯一真相＝地形高度與建築樓板取高者（鐵律 0③）。
	# ⚠ 先前只問地形，站在二樓的人高度照一樓地面算＝整個人陷進樓板裡。
	Unit.ground_sampler = _ground_height
	Unit.water_sampler = func(p: Vector3) -> float: return terrain.water_depth_world(p)
	# 艦艇浮力用的水面高度：與 Terrain 畫水面用同一個常數，兩邊不可各寫各的
	# （否則船會浮在「畫出來的水面」以外的高度）
	# （艦艇移除後不再需要注入水面取樣器——2026-08-04）
	# 聲音遮蔽：音源到鏡頭之間有牆就變悶（Audio.sfx3d 用）
	Audio.los_check = func(p: Vector3) -> bool:
		if cam == null:
			return true
		var mw2: float = map_data.get("w", 960)
		var mh2: float = map_data.get("h", 600)
		var a2 := Vector2(p.x / WORLD_SCALE + mw2 * 0.5, p.z / WORLD_SCALE + mh2 * 0.5)
		var cp: Vector3 = cam.global_position
		var b2 := Vector2(cp.x / WORLD_SCALE + mw2 * 0.5, cp.z / WORLD_SCALE + mh2 * 0.5)
		return _los_clear(a2, b2)
	# 槍口不可以插進固體（使用者 2026-07-26 第二次指正）：把「實體射線」交給 Unit，
	# 它在瞄準時自己判斷要不要抬槍。見 Unit.solid_probe。
	Unit.solid_probe = func(a: Vector3, b: Vector3) -> float: return _solid_ray(a, b)
	# 鏡頭碰撞：把「牆」與「地面」的查詢注入相機（真相在這邊，相機只負責用）
	cam.wall_probe = func(a: Vector3, b: Vector3) -> float: return _wall_ray(a, b)
	cam.ground_probe = func(p: Vector3) -> float: return terrain.height_at_world(p)
	cam.inside_probe = func(p: Vector3) -> bool: return _pos_indoors(p)
	cam.inside_loose_probe = func(p: Vector3) -> bool: return _pos_indoors_loose(p)
	# 地表顏色改走頂點色（見 Terrain._ground_color），材質只要最單純的一顆
	# 地表：顏色仍由頂點色決定（見 Terrain._ground_color），只疊土質的「法線＋粗糙度」，
	# 不疊 albedo——把土色乘上去會把草地染成一片灰泥（實拍踩過）。
	var sm := BattleMats.pbr("Dirt", 2.5, 0.97, Color.WHITE, false).duplicate()
	sm.vertex_color_use_as_albedo = true
	terrain.set_material(sm)
	for c in terrain.trench_covers():
		_covers.append(c)          # 壕溝＝半身掩體
	# 地圖上的草叢區＝隱蔽（GDD/01 §5a）。先前只有散佈的樹被登記成 bush，
	# maps.json 裡的 bushes 從來沒進掩體表，等於草叢畫了但沒有效果。
	for bz in map_data.get("bushes", []):
		_covers.append({"wx": float(bz.get("x", 0)), "wy": float(bz.get("y", 0)),
				"r": float(bz.get("r", 60)), "val": 0.30, "type": "bush"})

	# 建築（GDD/14 §2）：程式生成模組化建築，每棟都有真正的室內空間。
	# 舊做法是擺現成模型的實心外殼＋一個圓形掩體，玩家進不去、視線也只能用圓近似。
	_buildings = []
	_blockers = []          # 重建場景時一定要清，否則上一張地圖的障礙會留在新戰場上
	_bld_blk = []           # 室內家具的碰撞圓（最後與 props/fort 的一起併進 _blockers）
	_low_blk = []
	_fire_lights = []
	_marks = []
	_destructibles = []
	_weather_node = null
	_low_grid = {}
	_has_support = false
	_tree_feet = []
	var solids = map_data.get("solids", [])
	if solids is Array:
		# ⚠ 2026-07-28：上限原本寫死 6 棟。第四章是**村莊**（13 棟民宅）、
		#   第十四章是首都圈街廓（18 棟）——6 棟的村莊不是村莊。
		#   上限拉到 24 並改成「超過才喊」，實際幀時由 [perf] 把關。
		var i := 0
		for sdef in solids:
			if i >= MAX_BUILDINGS:
				push_error("[bldskip] 超過 %d 棟上限，略過 %s"
						% [MAX_BUILDINGS, String(sdef.get("note", "?"))])
				print("[bldskip] FAIL 超過上限 → ", String(sdef.get("note", "?")))
				break
			# ⚠⚠ 2026-07-27：這一行曾經**靜默吃掉兩棟劇情建築**（武器庫、鐘樓）——
			#   40px 邊界讓 x 570~710 的建築被 x 740 起的部署區判定成重疊。
			#   使用者玩到的是「劇情講武器庫與鐘樓，戰場上根本沒有」。
			#   資料是規格，被場景層丟掉一定要大聲喊，不可以只是 continue。
			if _in_any_deploy(sdef):
				push_error("[bldskip] 壓在部署區被丟掉：%s（改 maps.json 的 deploy 讓開，別讓劇情建築消失）"
						% String(sdef.get("note", "?")))
				print("[bldskip] FAIL 壓在部署區 → ", String(sdef.get("note", "?")))
				continue
			# 蓋在水裡的房子跳過（QA 反驗證：海峽圖一棟民房泡在深水正中央）。
			# 房子不會蓋在海裡——佈局資料是舊陸戰版沿用的，場景層要自己守。
			var srect := Rect2(float(sdef.get("x", 0)), float(sdef.get("y", 0)),
					float(sdef.get("w", 60)), float(sdef.get("h", 60)))
			# ⚠ 2026-07-27：舊版只比對水域**矩形**。改成曲線海岸之後那些矩形是空的，
			#   這道防線會整個失效＝房子可以蓋在海裡。改成問地形實際水深（唯一真相）。
			var wet := false
			if terrain != null:
				for fx in 5:
					for fy in 5:
						var qp := srect.position + srect.size * Vector2(fx / 4.0, fy / 4.0)
						if terrain.water_depth(qp.x, qp.y) > 0.05:
							wet = true
							break
					if wet:
						break
			if wet:
				push_error("[bldskip] 泡在水裡被丟掉：%s" % String(sdef.get("note", "?")))
				print("[bldskip] FAIL 泡在水裡 → ", String(sdef.get("note", "?")))
				continue
			var bd = BUILDING.new()
			world.add_child(bd)
			var cx: float = float(sdef.get("x", 0)) + float(sdef.get("w", 60)) * 0.5
			var cy: float = float(sdef.get("y", 0)) + float(sdef.get("h", 60)) * 0.5
			var gy := 0.0
			if terrain != null:
				gy = terrain.height_at_mesh(cx, cy)
			# 樓層改讀資料（鐵律 3）：先前寫死 `2 if i % 2 == 0 else 1`，
			# 於是「鐘樓」跟旁邊的營舍一樣高，劇情說「狙擊組上鐘樓」卻沒有樓可上。
			bd.build(sdef, WORLD_SCALE, map_data.get("w", 960), map_data.get("h", 600),
					gy, int(sdef.get("floors", 2 if i % 2 == 0 else 1)))
			_buildings.append(bd)
			# 劇情戰損（第一章開場第一句就是「雷達站起火了」）。
			# 資料驅動：maps.json 的 solid 標 burning，場景層才長出火與煙——
			# 劇本講的東西必須在戰場上看得到，否則對話與畫面是兩件事。
			if bool(sdef.get("burning", false)):
				_add_fire(bd.position + Vector3(0, float(bd.floors) * 3.1, 0),
						maxf(float(sdef.get("w", 90)), 90.0) * WORLD_SCALE * 0.35)
			# 室內家具進掩體表：進建築的戰術價值不能只有「牆擋子彈」，
			# 屋裡要有東西可以蹲（木箱半身高＝硬掩體，桌子只算部分遮蔽）。
			for fu in bd.furniture:
				var fp: Vector2 = bd._local_to_px(Vector2(float(fu["lx"]), float(fu["lz"])))
				_covers.append({"wx": fp.x, "wy": fp.y,
						"r": float(fu["r"]) / WORLD_SCALE, "val": float(fu["val"]),
						"type": "furniture"})
			# ★★室內家具也要擋人（2026-07-27）：`bd.solids_local` 一直有算，
			#   但 Main 從來沒有讀它 → 室內家具全是裝飾，玩家直接穿過木箱與高櫃
			#   （使用者實拍：人站在木箱裡面）。鐵律 0①：固體不可互穿。
			#   `pen`＝子彈穿得過（木箱木桌本來就不擋彈，擋彈的效果走 _covers 的命中懲罰）。
			#   ⚠ 不可以直接 append 到 `_blockers`：下面那行是
			#     `_blockers = props.blockers + fort.blockers + _water_blk`（整個覆蓋），
			#     append 進去會被無聲清掉——沙包當年就是這樣消失的（2026-07-26）。
			#     所以收在自己的陣列裡，最後一起併。
			for sl in bd.solids_local:
				var sp: Vector2 = bd._local_to_px(Vector2(float(sl[0]), float(sl[1])))
				_bld_blk.append({"t": "cir", "c": sp, "k": "furniture",
						"r": float(sl[2]) / WORLD_SCALE,
						"h": float(sl[3]) if sl.size() > 3 else 0.8, "pen": true})
			# 掩體：建築本體仍登記一個圓（貼著外牆＝硬掩體），視線改吃牆線段
			_covers.append({"wx": cx, "wy": cy,
					"r": maxf(float(sdef.get("w", 60)), float(sdef.get("h", 60))) * 0.85 + 30.0,
					"val": 0.75, "type": "building"})
			i += 1

	# 野戰工事（GDD/14 §7）：沙包牆與壕溝護壁，幾何合併成單一網格
	var fort = FORTIFY.new()
	world.add_child(fort)
	# 邊界安全帶也傳給工事：散落沙包會偏移出牆外，偏進帶內就會變成
	# 「畫著卻穿得過」（見 Fortify._in_edge_band）。帶寬只有一個真相來源＝EDGE_SAFE_M。
	fort.begin(map_data.get("w", 960), map_data.get("h", 600), WORLD_SCALE, terrain, EDGE_SAFE_M)
	# 壕溝護壁：光是地形凹下去像「地上的溝」，有木板與支撐柱才像人挖的工事
	for tr in map_data.get("trenches", []):
		var tpts: Array = []
		for pp in tr.get("pts", []):
			tpts.append(Vector2(float(pp[0]), float(pp[1])))
		if tpts.size() >= 2:
			fort.trench_revet(tpts, float(tr.get("w", 44)) * 0.5)
	# 掩體：沙包（Phase2 掩體系統的實體，先做出來才躲得進去）
	var sandbags = map_data.get("sandbags", [])
	if sandbags is Array:
		for sb in sandbags:
			_covers.append({"wx": sb.get("x", 0) + sb.get("w", 40) * 0.5,
					"wy": sb.get("y", 0) + sb.get("h", 24) * 0.5,
					"r": 52.0, "val": 0.55, "type": "sandbag"})
			fort.sandbag_wall(float(sb.get("x", 0)) + float(sb.get("w", 40)) * 0.5,
					float(sb.get("y", 0)) + float(sb.get("h", 24)) * 0.5,
					float(sb.get("w", 80)), float(sb.get("h", 24)))

	# 中景物件（GDD/14）：道路、路障、拒馬、圍籬、電線桿、瓦礫。
	# 第三人稱一站進戰場，眼睛高度沒東西可看就會覺得空——這層補的就是那個。
	fort.finish()
	var props = PROPS.new()
	world.add_child(props)
	# 邊界安全帶一併傳給 Props：讓它在**生成階段**就避開，
	# 而不是事後由 _strip_edge_blockers 剔碰撞、留下畫著卻穿得過的柵欄。
	props.build(map_data, WORLD_SCALE, terrain, EDGE_SAFE_M)
	# ⚠ 2026-07-26：這裡先前只吃 props.blockers，沙包牆（Fortify 產的）從來沒進碰撞表，
	#   所以上一批宣稱「所有物體都是實體」時，沙包其實還是可以直接走過去（使用者實測抓到）。
	#   工事的障礙一定要一起併進來。
	# 燒毀的車輛會冒煙（GDD/15 G3）：靜態殘骸看起來像剛擺上去的道具。
	# 只點前兩處，全部點火會太吵也太貴。
	for wi in mini(2, props.wreck_spots.size()):
		var wp: Vector2 = props.wreck_spots[wi]
		_add_fire(_to3d(wp.x, wp.y) + Vector3(0, 0.5, 0), 0.7)
	_destructibles = fort.destructibles
	_blockers = _strip_edge_blockers(props.blockers + fort.blockers + _water_blk + _bld_blk,
			mw / WORLD_SCALE, mh / WORLD_SCALE)
	_pole_spots = props.pole_spots
	_low_blk = []
	for bk0 in _blockers:
		if float(bk0.get("h", 1.2)) <= STEP_UP and String(bk0.get("k", "")) != "deepwater":
			_low_blk.append(bk0)
	_rebuild_support_box()
	# 植被：樹叢散佈（草叢掩蔽＋破除空曠感），樹幹本身也是實體
	_scatter_trees(mw, mh)
	_scatter_city(mw, mh)
	# 草最後鋪：禁草區要用建築的實際佔地，樹腳的草也要等樹放好才知道位置
	if terrain != null:
		var no_rects: Array = []
		for bdg in _buildings:
			no_rects.append(bdg.rect)
		terrain.build_grass(no_rects, _tree_feet)

	# 我方部署藍框（開戰後隱藏）
	var z := _my_zone()
	var zone_mesh := MeshInstance3D.new()
	zone_mesh.name = "DeployZone"
	# ★2026-07-27 使用者回報「部署那片不透明藍色塊，像一張藍地毯」的真因：
	#   這裡本來是一片 PlaneMesh，只有中心點一個高度，蓋在起伏地形上就是一張浮著的毯子；
	#   alpha 0.20 的無光照藍色疊在暗色地面上，看起來還一點都不透。
	#   改成逐格取地形高度的貼地網格、alpha 降到 0.10，再加一圈明顯的邊框——
	#   玩家真正需要看到的是「界線在哪」，不是整片被染藍。
	zone_mesh.mesh = _ground_rect_mesh(z, 0.05)
	var zmat := StandardMaterial3D.new()
	zmat.albedo_color = Color(0.42, 0.78, 1.0, 0.10)
	zmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	zmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	zmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	zone_mesh.material_override = zmat
	world.add_child(zone_mesh)
	var zone_edge := MeshInstance3D.new()
	zone_edge.name = "DeployZoneEdge"
	zone_edge.mesh = _ground_rect_border(z, 0.30)
	var emat := StandardMaterial3D.new()
	emat.albedo_color = Color(0.55, 0.86, 1.0, 0.50)
	emat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	emat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	emat.cull_mode = BaseMaterial3D.CULL_DISABLED
	zone_edge.material_override = emat
	zone_mesh.add_child(zone_edge)      # 掛在藍框底下，一起顯示/隱藏
	_zone_mesh = zone_mesh

	cam.set_follow(null)
	cam.focus = _to3d(z.get("x", 0) + z.get("w", 300) * 0.5, z.get("y", 0) + z.get("h", 200) * 0.5)
	cam.dist = 18.0

# 遞迴累積父階變換算 AABB（先前只用 mi.transform，巢狀模型會算錯→縮放爆掉變巨牆）
func _node_aabb(n: Node, xf: Transform3D, acc: AABB, has: bool) -> Array:
	var cur := xf
	if n is Node3D:
		cur = xf * (n as Node3D).transform
	if n is MeshInstance3D:
		var b: AABB = cur * (n as MeshInstance3D).get_aabb()
		acc = b if not has else acc.merge(b)
		has = true
	for c in n.get_children():
		var r := _node_aabb(c, cur, acc, has)
		acc = r[0]
		has = r[1]
	return [acc, has]

# 依模型實際尺寸縮放到指定高度；回傳「讓底部貼地」所需的 y 偏移
func _fit_prop(node: Node3D, target_h: float) -> float:
	var prev := node.transform
	node.transform = Transform3D.IDENTITY
	var r := _node_aabb(node, Transform3D.IDENTITY, AABB(), false)
	node.transform = prev
	if not r[1]:
		return 0.0
	var ab: AABB = r[0]
	if ab.size.y <= 0.01:
		return 0.0
	var k: float = target_h / ab.size.y
	node.scale = Vector3.ONE * k
	return -ab.position.y * k

# 依單位所在位置更新「是否躲掩體」（會擺蹲姿＋受掩體命中修正）
# 單位走到定點：把邏輯座標對齊實際落點，再重算掩體/姿勢
func _on_unit_arrived(node) -> void:
	for u in units:
		if u["node"] == node:
			var p := _live_px(u)
			u["wx"] = p.x
			u["wy"] = p.y
			_update_cover_state(u)
			_refresh_visibility()
			return

func _update_cover_state(u) -> void:
	var c := cover_here(u["wx"], u["wy"])
	u["cover"] = c.get("type", "")
	if is_instance_valid(u["node"]):
		u["node"].want_cover = not c.is_empty()
		# 狙擊手在無掩體的開闊地會臥射：這是真實狙擊手的標準做法（穩定＋降低被發現）。
		# 有掩體時優先蹲在掩體後，趴著反而看不到目標。
		u["node"].want_prone = c.is_empty() and u.get("cls", "") == "sniper"

# 掩體查詢：目標在 (wx,wy)、射手在 (fx,fy)，回傳遮蔽值 0~1。
# 方向性：掩體必須位於「目標朝射手」那一側 ±75 度內才有效（背後的沙包擋不了正面來的子彈）。
func cover_at(wx: float, wy: float, fx: float, fy: float) -> float:
	var best := 0.0
	var to_shooter := Vector2(fx - wx, fy - wy)
	if to_shooter.length() < 1.0:
		return 0.0
	to_shooter = to_shooter.normalized()
	for c in _covers:
		var d := Vector2(c["wx"] - wx, c["wy"] - wy)
		var dist: float = d.length()
		if dist > c["r"]:
			continue
		if dist > 1.0 and d.normalized().dot(to_shooter) < 0.26:   # cos75°
			continue
		best = maxf(best, float(c["val"]))
	return best

# 該單位所在位置是否處於任何掩體旁（不分方向）——決定是否擺蹲姿
func cover_here(wx: float, wy: float) -> Dictionary:
	for c in _covers:
		if c["type"] == "bush":
			continue
		if Vector2(c["wx"] - wx, c["wy"] - wy).length() <= c["r"]:
			return c
	return {}

# 該矩形是否與任一方部署區重疊（含 40px 邊界）
func _in_any_deploy(sdef: Dictionary) -> bool:
	var dz = map_data.get("deploy", [])
	if not (dz is Array):
		return false
	var m := 40.0
	var ax: float = sdef.get("x", 0) - m
	var ay: float = sdef.get("y", 0) - m
	var aw: float = sdef.get("w", 40) + m * 2.0
	var ah: float = sdef.get("h", 40) + m * 2.0
	for z in dz:
		var bx: float = z.get("x", 0)
		var by: float = z.get("y", 0)
		var bw: float = z.get("w", 0)
		var bh: float = z.get("h", 0)
		if ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by:
			return true
	return false

# （2026-07-28 刪除 _make_sandbag：無人呼叫的死碼。沙包一律走 Fortify.sandbag_wall
#   ——鼓袋剖面＋磚砌交錯＋每袋色差那一套，兩套並存遲早又出「兩種沙包」的不一致。）

# 巨石散佈（沙漠/海岸）：低多邊形球體壓扁＋隨機傾斜，半埋進地（鐵律 0：有重量會下沉）。
# 沙漠沒有樹，中景高度全靠巨石；同時登記碰撞與掩體（大石＝半身硬掩體）。
func _scatter_rocks(gwp: float, ghp: float) -> void:
	var rmul: float = float(terrain.biome.get("rock_mult", 1.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	# ⚠ 5.5 在 48×30m 的舊圖上剛好，地圖放大到 70×50m 之後變成滿地鵝卵蛋（實拍）。
	#   巨石是「點綴」不是地被——密度砍到 2.2，並且下面加上顏色與大小的變化。
	var want: int = int(gwp * ghp / 52000.0 * rmul * 2.2)
	# ★2026-07-29（使用者：「石頭還是太假」）：共用 SphereMesh（平滑法線）＝一窩光滑
	#   的蛋。改用 Trees.build_rock_protos 的碎面原型：稜角、逐面色差、頂白底髒都烘在
	#   頂點色裡；per-instance 色偏照舊由 MultiMesh instance color 乘上去。
	var protos: Array = TREES.build_rock_protos()
	# ★岩石材質（2026-07-31 使用者：「這類似的石頭太假了」）。三個病一起治：
	#   ① 沒有任何貼圖，只有純色＋頂點明暗 → 近看是一塊塑膠
	#   ② 顏色直接取 biome.rock，沙漠圖那是**沙黃色**＝石頭跟地面同色，讀不出是石頭
	#   ③ 岩石沒有 UV → 一般貼圖會被拉扯，必須用三平面投影
	var rock_c: Color = terrain.biome.get("rock", Color(0.5, 0.46, 0.36))
	# 去飽和 55% 並壓暗：岩石是灰褐的礦物，與沙／草的暖色拉開對比才看得出是石頭
	var gray: float = rock_c.get_luminance()
	# 去飽和後要**提亮**回來：Concrete 貼圖本身是中灰(~0.5)，再乘暗色調＋頂點明暗
	# ＝黑剪影（實拍）。tint 用 1.45 讓貼圖細節看得見，對比靠法線圖而不是壓暗。
	# ⚠ 去飽和要夠徹底：0.55 之後仍保留 45% 的沙黃，配上暖陽讀成紫褐（實拍）。
	# 岩石＝礦物灰白，0.82 幾乎全灰、只留一絲地域色偏。
	# ⚠ 不可以用 Color * float：那會把 alpha 也乘上去（實測 alpha=1.45），
	# 明確指定 alpha=1。
	# 去飽和 0.5＋提亮 1.25，再補一點暖偏：Concrete 貼圖本身是冷灰，
	# 全中性 tint 會讓石頭在暖沙上讀成藍紫色（實拍）。暖灰＝沙岩，
	# 與地面同溫但更亮更低飽和，看得出是石頭又不突兀。
	var kb: float = 1.25
	var warm := Color(1.06, 1.0, 0.92)
	rock_c = Color(clampf(lerpf(rock_c.r, gray, 0.5) * kb * warm.r, 0.0, 1.0),
			clampf(lerpf(rock_c.g, gray, 0.5) * kb * warm.g, 0.0, 1.0),
			clampf(lerpf(rock_c.b, gray, 0.5) * kb * warm.b, 0.0, 1.0), 1.0)
	var rmat: BaseMaterial3D = BattleMats.pbr("Concrete", 0.9, 0.98, rock_c)
	rmat = rmat.duplicate() as BaseMaterial3D
	rmat.uv1_triplanar = true          # 岩石無 UV：三平面投影才不會把貼圖拉成條紋
	# ⚠ tile 尺寸要比石頭小很多才看得到顆粒：0.55 等於 1.8m 一格，一顆石頭上
	# 只有一格＝完全看不出貼圖（實拍還是一塊光滑純色）。3.2 ＝ 31cm 一格。
	rmat.uv1_scale = Vector3(3.2, 3.2, 3.2)
	rmat.vertex_color_use_as_albedo = true    # 頂點色只做面的明暗層次
	rmat.normal_enabled = true
	rmat.normal_scale = 1.6            # 法線加重：低多邊形靠它做出岩面的粗糙顆粒
	# 碎面岩的頂點抖動不保證繞序全朝外：背面剔除下某些角度整塊面消失＝破圖
	# （使用者 2026-07-31 實玩回報「石頭破圖」）。雙面渲染，石頭不透明沒代價。
	rmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	print("[rockmat] 型別=%s albedo_tex=%s normal_tex=%s triplanar=%s tint=%s" % [
			rmat.get_class(), str(rmat.albedo_texture != null),
			str(rmat.normal_texture != null), str(rmat.uv1_triplanar),
			str(rmat.albedo_color)])
	var xfs_by: Array = []       # 每個原型自己一份 [Transform3D]
	var cols_by: Array = []
	for _p in protos.size():
		xfs_by.append([])
		cols_by.append([])
	var placed_pos: Array = []   # 最小間距檢查用（原本借 xfs，分流後要自己存）
	var placed := 0
	var guard := 0
	while placed < want and guard < want * 25:
		guard += 1
		var px: float = rng.randf_range(30.0, gwp - 30.0)
		var py: float = rng.randf_range(30.0, ghp - 30.0)
		var tp := Vector2(px, py)
		var bad := false
		for bd2 in _buildings:
			if bd2.rect.grow(4.0 / WORLD_SCALE).has_point(tp):
				bad = true
				break
		if bad or (terrain != null and (terrain.in_trench(px, py) or terrain.in_water(px, py))):
			continue
		# 最小間距：巨石成堆貼在一起就是「一窩蛋」，散開才像地質
		var mypos := Vector2((px - gwp * 0.5) * WORLD_SCALE, (py - ghp * 0.5) * WORLD_SCALE)
		var too_close := false
		for ex in placed_pos:
			if (ex as Vector2).distance_to(mypos) < 3.5:
				too_close = true
				break
		if too_close:
			continue
		var sc: float = rng.randf_range(0.28, 1.35)   # 上限 1.9 的巨石比人還高兩倍，太搶戲
		var ty: float = terrain.height_at_mesh(px, py)
		# ⚠ 縮放係數要留下來：碰撞半徑與高度必須跟**畫出來的那顆石頭**一致，
		#   不能用 sc 亂猜（先前 r 寫 sc*0.9、h 寫 sc*1.0，兩個都不是實際尺寸）。
		var rx: float = rng.randf_range(0.8, 1.4)
		var ry: float = rng.randf_range(0.5, 0.8)
		var b := (Basis(Vector3.UP, rng.randf() * TAU)
				* Basis(Vector3(1, 0, 0), rng.randf_range(-0.25, 0.25))).scaled(
				Vector3(sc * rx, sc * ry, sc))
		# 半埋：底部沉進地面 1/3，石頭才是「長在地裡」不是「擺在地上」
		var pi2: int = rng.randi() % protos.size()
		xfs_by[pi2].append(Transform3D(b, Vector3(mypos.x, ty + sc * 0.28, mypos.y)))
		placed_pos.append(mypos)
		# 與地面的過渡（GDD/06 美術四原則第 4 條）：大石底部堆一圈崩落的碎石。
		# 沒有這一圈，石頭就是「擺在沙上的模型」——輪廓與地面硬切，一眼就假
		# （2026-07-31 沙漠圖實拍）。碎石不登記碰撞（跨得過去）。
		if sc > 0.6:
			for _dbi in range(rng.randi_range(2, 4)):
				var da: float = rng.randf() * TAU
				var dr: float = sc * rng.randf_range(0.85, 1.35)
				var dsc: float = sc * rng.randf_range(0.10, 0.22)
				var dwx: float = mypos.x + cos(da) * dr
				var dwz: float = mypos.y + sin(da) * dr
				var dty: float = terrain.height_at_mesh(
						dwx / WORLD_SCALE + gwp * 0.5, dwz / WORLD_SCALE + ghp * 0.5)
				# ⚠ 碎石要**壓扁＋半埋**：等比例的小石在切割面下看起來就是一顆方糖，
				# 實拍是一地白盒子。壓到 0.35 高、埋掉一半，才像崩落堆積的碎屑。
				var db := (Basis(Vector3.UP, rng.randf() * TAU)
						* Basis(Vector3(1, 0, 0), rng.randf_range(-0.25, 0.25))).scaled(
						Vector3(dsc * rng.randf_range(1.1, 1.8), dsc * 0.35, dsc * rng.randf_range(0.9, 1.4)))
				var dpi: int = rng.randi() % protos.size()
				xfs_by[dpi].append(Transform3D(db, Vector3(dwx, dty - dsc * 0.12, dwz)))
				cols_by[dpi].append(Color(rng.randf_range(0.78, 1.05),
						rng.randf_range(0.78, 1.02), rng.randf_range(0.76, 1.0)))
		# ★2026-07-27：門檻原本是 sc > 0.7，於是**半徑近 1m 的石頭完全沒有碰撞**——
		#   人直接走過去。石頭是石頭，不管大小都不能穿過（鐵律 0①）。
		#   矮的（≤ STEP_UP）由 _ground_height 給頂面支撐＝踩上去，不是繞過去。
		# 幾何：原型岩半徑 ~1.0、半高 0.62（碎面位移 ±30%），再乘縮放；埋 sc*0.28。
		var rock_r: float = sc * maxf(rx, 1.0) * 1.15             # 水平半徑（含位移上緣）
		var rock_h: float = sc * (0.28 + 0.62 * ry)               # 露出地面的高度
		if sc > 0.30:
			_blockers.append({"t": "cir", "c": tp, "r": rock_r / WORLD_SCALE, "h": rock_h})
		# 每顆石頭色偏不同：一整片同色的粉灰色圓球是本專案被指正過的「一片純色」
		cols_by[pi2].append(Color(rng.randf_range(0.72, 1.16), rng.randf_range(0.74, 1.12),
				rng.randf_range(0.70, 1.10)))
		if rock_h > STEP_UP:
			_covers.append({"wx": px, "wy": py, "r": rock_r * 1.05 / WORLD_SCALE,
					"val": 0.5, "type": "sandbag"})
		placed += 1
	if placed_pos.is_empty():
		return
	for pidx in protos.size():
		var lst: Array = xfs_by[pidx]
		if lst.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = protos[pidx]
		mm.instance_count = lst.size()
		for k in lst.size():
			mm.set_instance_transform(k, lst[k])
			mm.set_instance_color(k, cols_by[pidx][k])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Rocks%d" % pidx
		mmi.multimesh = mm
		mmi.material_override = rmat
		world.add_child(mmi)

# 水面（海灘/海峽/港口）：一片起伏的半透明水色平面蓋在水域上。
# 深水對步兵不可通行（鐵律 0：人不會走進兩公尺深的海裡打仗），登記成線段圍欄。
func _build_water() -> void:
	_water_blk = []
	var rects: Array = []
	var deep_rects: Array = []
	for wkey in ["waters", "deepwaters", "shallows"]:
		for wr in map_data.get(wkey, []):
			var rr := Rect2(float(wr.get("x", 0)), float(wr.get("y", 0)),
					float(wr.get("w", 60)), float(wr.get("h", 60)))
			rects.append(rr)
			if wkey == "deepwaters":
				deep_rects.append(rr)
	# 曲線海岸／河道（Terrain._build_shores）：水面要鋪滿它們涵蓋的範圍。
	# 「哪裡是水」仍然逐格問 terrain.water_depth，所以鋪大一點只是多幾個空格子，不會多畫。
	var has_shore: bool = terrain != null and terrain.has_shores()
	if rects.is_empty() and not has_shore:
		return
	# ★★水域一律合成**一片**網格（2026-07-27）。
	#   舊做法是「一個矩形一個 PlaneMesh」，而 maps.json 的 waters/deepwaters/shallows
	#   是三條相鄰（有時重疊）的長條，加上 shallows 還故意下移 6cm →
	#   畫面上是三層半透明的塑膠片疊在一起、有硬接縫、還互相透出對方的邊。
	#   合成一片之後接縫就不存在了；「哪裡是水」交給 terrain.water_depth 逐點判定
	#   （水深 0 的格子直接不畫），所以不需要知道原始矩形怎麼切。
	# ⚠ 近岸網格只鋪「戰場 ± SHORE_PAD_PX」，不是整片海（遠洋交給 _build_far_ocean 的大平面）。
	#   先前直接用 shore_bounds（含遠洋，114×210m）除以上限 48 格 → 每格 2.4×4.4m，
	#   頂點波把每一格頂出不同高度，畫面上是滿版的網格摩爾紋（實拍）。
	var mwp0: float = map_data.get("w", 960)
	var mhp0: float = map_data.get("h", 600)
	var uni: Rect2
	if has_shore:
		uni = Rect2(-SHORE_PAD_PX, -SHORE_PAD_PX,
				mwp0 + 2.0 * SHORE_PAD_PX, mhp0 + 2.0 * SHORE_PAD_PX)
		for rr2 in rects:
			uni = uni.merge(rr2)
	else:
		uni = rects[0]
		for rr2 in rects:
			uni = uni.merge(rr2)
	var mi := MeshInstance3D.new()
	mi.name = "Water"
	mi.mesh = _water_mesh(uni)
	if mi.mesh != null:
		var wmat := ShaderMaterial.new()
		var wsh := Shader.new()
		wsh.code = WATER_SHADER
		wmat.shader = wsh
		# 流向：長條形＝河，沿長邊流；接近正方＝湖／海灣，不流
		var flow_v := Vector2(1.0, 0.0) if uni.size.x >= uni.size.y else Vector2(0.0, 1.0)
		if absf(uni.size.x - uni.size.y) / maxf(uni.size.x, uni.size.y) < 0.35:
			flow_v = Vector2.ZERO
		wmat.set_shader_parameter("flow", flow_v)
		# 河比海流得快（有河道資料就當河看）
		wmat.set_shader_parameter("flow_speed",
				1.9 if not map_data.get("rivers", []).is_empty() else 1.0)
		# 天空反射與太陽閃爍要跟場景的實際光照一致（黃昏的海反射的就是黃昏的天）
		if _sun != null and is_instance_valid(_sun):
			wmat.set_shader_parameter("sun_dir", -_sun.global_transform.basis.z)
			wmat.set_shader_parameter("sun_col",
					Vector3(_sun.light_color.r, _sun.light_color.g, _sun.light_color.b))
			wmat.set_shader_parameter("sun_energy", _sun.light_energy)
		_water_mats.append(wmat)
		if _sky_mat != null:
			var st_c = _sky_mat.get_shader_parameter("top_color")
			var sh_c = _sky_mat.get_shader_parameter("horizon_color")
			if st_c != null:
				wmat.set_shader_parameter("sky_top", Vector3(st_c.r, st_c.g, st_c.b))
			if sh_c != null:
				wmat.set_shader_parameter("sky_hor", Vector3(sh_c.r, sh_c.g, sh_c.b))
		mi.material_override = wmat
		world.add_child(mi)
	# 深水圍欄（曲線海岸版）：沿著岸線往海裡走，走到水深 1.5m（及胸）就下一個樁，
	# 把樁連成折線。這樣圍欄貼著**實際海底地形**，不是一個跟海岸無關的矩形。
	if has_shore:
		_build_far_ocean()
	# 深水圍欄一律走等高線版本（海、河、湖都一樣，規則掛在「水有多深」上）
	_build_deepwater_fence()
	# 深水圍欄：四邊線段障礙（步兵過不去；日後做船再改成「載具可通行」）
	for r in deep_rects:
		var corners := [r.position, Vector2(r.end.x, r.position.y), r.end,
				Vector2(r.position.x, r.end.y)]
		for i in 4:
			var a2: Vector2 = corners[i]
			var b2: Vector2 = corners[(i + 1) % 4]
			_water_blk.append({"t": "seg", "a": a2, "b": b2, "r": 0.3 / WORLD_SCALE,
					"h": 0.0, "k": "deepwater", "m": (a2 + b2) * 0.5,
					"hl": a2.distance_to(b2) * 0.5})

# ★★深水圍欄改成「水深等高線」（2026-07-28 走查台實拍抓到：人站在河口的水裡到胸口）。
#
# 舊版只沿**海岸線**往外找樁，於是「河」完全沒有圍欄。而且第一章的河口是
# 河床下陷 1.25m ＋ 海床下陷疊在一起 ＝ 實測 1.47m，比涉水上限還深。
# 「只處理海、忘了河」是同一類錯誤的第 N 次：規則要掛在**現象**（水有多深）上，
# 不是掛在**資料來源**（coast 還是 river）上。
#
# 做法：掃一遍網格，找出「自己是深水、但隔壁不是」的格子（＝深水的邊界），
# 在每個邊界格放一個圓形障礙。相鄰圓會互相重疊，人（半徑 0.42m）鑽不過去。
# 為什麼不是每幀直接問水深：water_depth 要算 height_at（雜訊＋丘陵＋壕溝＋河海迴圈），
# 每個單位每幀問一次太貴。建置期算一次、變成靜態障礙，執行期零成本。
const DEEP_STEP_PX := 26.0             # 取樣間距（px）＝1.3m
const DEEP_R_M := 0.80                 # 每個樁的半徑（公尺）：相鄰樁要重疊到人鑽不過去
# 圍欄門檻要比 WADE_MAX 淺一段：樁立在「第一個超標樣本」上，樣本間距 1.3m、
# 樁半徑 0.8m，河床坡陡時樁前的縫隙水深已經超標（ch07 壓測實測走到 1.10m）。
# 收緊 0.20m ＝ 樁立在 0.85m 線上，人被擋下時腳下最深不過涉水上限；
# 0.8m 的渡口不受影響（mapgen 渡口深度 ≤ 0.8）。
const DEEP_FENCE_MARGIN := 0.20
func _build_deepwater_fence() -> void:
	if terrain == null:
		return
	var mwp: float = map_data.get("w", 960)
	var mhp: float = map_data.get("h", 600)
	# 只鋪戰場 ±200px：玩家出不了地圖（_clamp_to_map），外海不必立樁
	var x0: float = -200.0
	var y0: float = -200.0
	var nx: int = int((mwp + 400.0) / DEEP_STEP_PX)
	var ny: int = int((mhp + 400.0) / DEEP_STEP_PX)
	var deep: Array = []
	for i in nx + 1:
		var col: Array = []
		for j in ny + 1:
			col.append(terrain.water_depth(x0 + float(i) * DEEP_STEP_PX,
					y0 + float(j) * DEEP_STEP_PX) > WADE_MAX - DEEP_FENCE_MARGIN)
		deep.append(col)
	var n := 0
	for i2 in range(1, nx):
		for j2 in range(1, ny):
			if not deep[i2][j2]:
				continue
			# 邊界＝自己是深水、四鄰有一個不是
			if deep[i2 - 1][j2] and deep[i2 + 1][j2] and deep[i2][j2 - 1] and deep[i2][j2 + 1]:
				continue
			_water_blk.append({"t": "cir",
					"c": Vector2(x0 + float(i2) * DEEP_STEP_PX, y0 + float(j2) * DEEP_STEP_PX),
					"r": DEEP_R_M / WORLD_SCALE, "h": 0.0, "k": "deepwater"})
			n += 1
	# ⚠ 一根樁都沒有時要大聲喊：深水圍欄「登記了卻從來沒生效」是本專案的舊病，
	#   症狀是玩家可以走進外海，而測試看起來一片安靜。
	if n == 0:
		# 只有「資料上宣告過比涉水上限更深的水」卻立不出樁，才是真的壞掉。
		# 第二章的小溪只有 0.8m 深，本來就不該有圍欄——那不是錯誤。
		var declared_deep := false
		var co = map_data.get("coast", null)
		if co != null and float(co.get("depth", 0.0)) > WADE_MAX:
			declared_deep = true
		for rv2 in map_data.get("rivers", []):
			if float(rv2.get("depth", 0.0)) > WADE_MAX:
				declared_deep = true
		if declared_deep:
			push_error("[water] 宣告了深過 %.2fm 的水，卻一根樁都立不出來" % WADE_MAX)
		else:
			print("[water] 這張圖沒有深過 %.2fm 的水，不需要深水圍欄" % WADE_MAX)
	else:
		print("[water] 深水圍欄 %d 根樁（水深 > %.2fm 的邊界）" % [n, WADE_MAX])

# 遠洋：岸邊那片網格只鋪到戰場外 90m，之後海就結束了——實拍看到海在半路被一條
# 直線切斷，外面接著米色的外圍地面。遠洋不需要水深變化（一律最深），
# 所以用一片大平面補到地平線，成本只有兩個三角形。
func _build_far_ocean() -> void:
	var mwp: float = map_data.get("w", 960)
	var mhp: float = map_data.get("h", 600)
	var far: float = 700.0                       # 公尺
	# 只往「海的那一側」鋪，而且**正好接在近岸網格外緣**
	var edge_px: float = (-SHORE_PAD_PX) if terrain.sea_dir() == "west" 			else (mwp + SHORE_PAD_PX)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var x0: float
	var x1: float
	var z0 := -far
	var z1 := far
	if terrain.sea_dir() == "west":
		x1 = (edge_px - mwp * 0.5) * WORLD_SCALE
		x0 = x1 - far * 2.0
	elif terrain.sea_dir() == "east":
		x0 = (edge_px - mwp * 0.5) * WORLD_SCALE
		x1 = x0 + far * 2.0
	else:
		return                                   # 南北向的海還沒有圖用到，不亂猜
	var y: float = BattleTerrain.WATER_SURFACE_Y - 0.03
	for q in [Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1),
			Vector3(x0, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1)]:
		st.set_color(Color(1, 1, 1, 1.0))        # a=1 ＝最深，跟岸邊網格同一套語意
		st.set_normal(Vector3.UP)
		st.add_vertex(q)
	var mi := MeshInstance3D.new()
	mi.name = "OceanFar"
	mi.mesh = st.commit()
	var wm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = WATER_SHADER
	wm.shader = sh
	wm.set_shader_parameter("flow", Vector2(1.0, 0.15))
	# 遠洋只有兩個三角形，逐頂點波沒有意義；靠法線漣漪維持「不是鏡子」
	wm.set_shader_parameter("ripple_far", 0.06)
	# 遠洋跟近岸吃同一組天空／太陽（否則遠近兩片海顏色對不上，接縫立現）
	if _sun != null and is_instance_valid(_sun):
		wm.set_shader_parameter("sun_dir", -_sun.global_transform.basis.z)
		wm.set_shader_parameter("sun_col",
				Vector3(_sun.light_color.r, _sun.light_color.g, _sun.light_color.b))
		wm.set_shader_parameter("sun_energy", _sun.light_energy)
	_water_mats.append(wm)
	if _sky_mat != null:
		var st_c2 = _sky_mat.get_shader_parameter("top_color")
		var sh_c2 = _sky_mat.get_shader_parameter("horizon_color")
		if st_c2 != null:
			wm.set_shader_parameter("sky_top", Vector3(st_c2.r, st_c2.g, st_c2.b))
		if sh_c2 != null:
			wm.set_shader_parameter("sky_hor", Vector3(sh_c2.r, sh_c2.g, sh_c2.b))
	mi.material_override = wm
	mi.extra_cull_margin = far
	world.add_child(mi)

# ★★涉水上限＝這條物理規則的**唯一真相**（2026-07-28）。
#   先前同一條規則有三個數字：深水圍欄用 1.5、走查判準用 1.35、
#   Terrain.move_cost 用 1.35。三個數字就一定會出現「圍欄立在 1.5、
#   人走到 1.49 沒被擋、判準說 >1.35 就是 FAIL」這種永遠修不完的縫。
#   1.35m ＝ 1.75m 的人及胸的高度（鐵律 0⑤：量級用現實值）。
const WADE_MAX := BattleTerrain.WADE_MAX
const SHORE_PAD_PX := 700.0            # 近岸細網格鋪到戰場外多遠（px；700px = 35m）
# 水面網格：把「這一點的水深」烤進頂點色的 alpha，shader 直接拿它當透明度與深淺色。
# ⚠ 為什麼不是一片 PlaneMesh（使用者 2026-07-27：「水面那片不透明藍色塊，像藍地毯」）：
#   ① ALPHA 寫死 0.90＝幾乎不透明，淺灘看不到水底，一律是同一片藍；
#   ② 岸邊只靠矩形 UV 淡出，地形高出水面的地方照樣鋪著藍色 → 藍色蓋在陸地上。
#   改成逐格判水深：全部四角都在水面之上（陸地）的格子直接不畫，
#   水深 0~0.7m 的帶狀區逐漸透明，這就是真實的岸線。
#   （不用 DEPTH_TEXTURE 做岸邊淡出，是因為網頁版走 gl_compatibility，風險太高。）
func _water_mesh(r: Rect2) -> ArrayMesh:
	if terrain == null:
		return null
	# ⚠ 解析度要夠細：河道只有 2.8m 寬，12px(0.6m) 一格才切得出河形。
	#   三角形數是跟**水域面積**成正比不是跟這個框成正比（陸地格子根本不產出），
	#   所以把框放大、格子切細，成本仍然可控。
	var nx: int = clampi(int(r.size.x / 7.0), 4, 200)
	var ny: int = clampi(int(r.size.y / 7.0), 4, 200)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	for i in nx:
		for j in ny:
			var pts := []
			var deep := []
			for corner in [[i, j], [i + 1, j], [i + 1, j + 1], [i, j + 1]]:
				var px: float = r.position.x + r.size.x * float(corner[0]) / float(nx)
				var py: float = r.position.y + r.size.y * float(corner[1]) / float(ny)
				pts.append(Vector3((px - map_data.get("w", 960) * 0.5) * WORLD_SCALE,
						BattleTerrain.WATER_SURFACE_Y,
						(py - map_data.get("h", 600) * 0.5) * WORLD_SCALE))
				deep.append(terrain.water_signed(px, py))
			# ⚠ 判準是「有沒有任何一角接近水面」，不是「有沒有任何一角是水」。
			#   後者會讓格子整格畫或整格不畫，岸線變成一階一階的鋸齒（實拍）。
			#   多留一圈 0.5m 的裙邊：那些頂點 alpha 本來就是 0，而且低於地面會被擋住。
			var keep := false
			for dv in deep:
				if float(dv) > -0.5:
					keep = true
					break
			if not keep:
				continue                       # 整格都是陸地：不要在陸地上鋪藍色
			any = true
			for idx in [0, 1, 2, 0, 2, 3]:
				st.set_normal(Vector3.UP)
				st.set_color(Color(1, 1, 1, clampf(float(deep[idx]) / 0.7, 0.0, 1.0)))
				st.set_uv(Vector2(float(idx % 3), float(idx / 3)))
				st.add_vertex(pts[idx])
	if not any:
		return null
	return st.commit()

# 水面 shader：兩層正弦波起伏＋菲涅耳反光。刻意簡單——手機 WebGL2 也要跑得動。
const WATER_SHADER := """
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back;

uniform vec2 flow = vec2(1.0, 0.25);   // 流向（河水會流，湖面 flow 給 0）
uniform float ripple_far = 0.06;       // 遠處漣漪殘留（0＝鏡子＋摩爾紋，不可為 0）
uniform float flow_speed = 1.0;        // 河比海流得快
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;
// 天空與太陽（由 _build_water 從 _sun/_sky_mat 餵進來）：
// 真實水面一半是「天空的鏡子」——沒有天空反射，水永遠是一張藍色紙。
uniform vec3 sun_dir = vec3(0.45, 0.62, 0.64);   // 指向太陽（世界空間，已正規化）
uniform vec3 sun_col = vec3(1.0, 0.95, 0.86);
// ⚠ 日夜訊號要用光的能量，不能用太陽仰角——夜戰的「月亮」也在天上 44 度，
//   靠仰角判斷的話夜裡的焦散/浪脊光/浪花全都全亮（ch10 實拍一圈青色霓虹）。
uniform float sun_energy = 1.2;
uniform vec3 sky_top = vec3(0.24, 0.44, 0.74);
uniform vec3 sky_hor = vec3(0.80, 0.85, 0.88);

varying vec3 wpos;

// ★★2026-07-28（使用者第三次說水假）：漣漪從「sin 的疊加」換成 **hash 梯度雜訊 FBM**。
//   不管疊幾組正弦、頻率怎麼錯開，正弦的和永遠是規則的燈芯絨／格子紋——
//   人眼對週期性極度敏感，那就是「一看就假」的根源。真實水面的擾動是無週期的。
//   （地形當年也是因為正弦疊加出現規則斜條紋才改成 hash 雜訊，同一個教訓。）
float h21(vec2 p) {
	// ⚠ 座標要先收進小範圍：wpos 可以到 ±700m，直接丟進 fract 會因為浮點精度
	//   在大座標處退化成沿軸的條紋（畫面上就是一片對齊的方格）。
	p = mod(p, 512.0);
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = h21(i);
	float b = h21(i + vec2(1.0, 0.0));
	float c = h21(i + vec2(0.0, 1.0));
	float d = h21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
// 兩層不同方向、不同速度的捲動雜訊。方向不同才有「水在動」的感覺，
// 同方向兩層只是同一張圖在滑。
// ⚠⚠ 每一階都要**轉一個不成比例的角度**再取樣。
//   值雜訊是建在整數格點上的，每一階都用同一個方向疊起來，格點會互相對齊，
//   畫面上就是一整片軸對齊的方格（實拍第一章海面）。
//   天空 shader 當年為了同一件事就留了一個 36.7 度的旋轉矩陣——同一個教訓。
const mat2 WROT = mat2(vec2(0.8018, 0.5977), vec2(-0.5977, 0.8018));
float water_fbm(vec2 p, float t) {
	float n = 0.0;
	// ⚠ 階數與頻率要配合**實際尺度**：水面波長 3~5m 才像海，
	//   0.1m 的細碎波在畫面上是一片乾酪碎粒（第一版實拍就是這樣）。
	n += vnoise(p + vec2(t * 0.20, t * 0.11)) * 0.58;
	p = WROT * p * 2.1;
	n += vnoise(p - vec2(t * 0.31, t * 0.57)) * 0.30;
	p = WROT * p * 2.05;
	n += vnoise(p + vec2(t * 0.72, -t * 0.39)) * 0.12;
	return n;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float t = TIME * 0.9 * flow_speed;
	// ⚠ 頂點起伏一定要隨距離淡出：水面網格是 1.2m 一格，掠角看過去時
	//   0.17m 的高低差會讓每一格變成一個看得見的階梯面——實拍是一整片方格布。
	//   近處要有起伏（那是水在動的證據），遠處交給法線就好。
	float vfade = 1.0 - smoothstep(12.0, 55.0,
			distance(wpos, CAMERA_POSITION_WORLD));
	float a = dot(wpos.xz, normalize(flow + vec2(0.001)));
	VERTEX.y += (sin(a * 0.8 - t * 1.6) * 0.045
			+ (water_fbm(wpos.xz * 0.12, TIME * 0.6) - 0.5) * 0.09) * vfade;
}

void fragment() {
	float d = COLOR.a;                       // 建網格時烤進頂點色的實際水深（0=岸、1=深）
	float vd = length(VERTEX);               // 到鏡頭的距離（VERTEX 在 fragment 是視空間）
	float near_k = 1.0 - smoothstep(18.0, 130.0, vd);
	float amp = mix(ripple_far, 1.0, near_k);

	// ---- 法線：FBM 的梯度（不是 sin），所以沒有任何規則紋路 ----
	float t = TIME * flow_speed;
	vec2 p = wpos.xz * 0.22 + normalize(flow + vec2(0.001)) * t * 0.10;
	float e = 0.16;
	float n0 = water_fbm(p, t);
	float nx = water_fbm(p + vec2(e, 0.0), t) - n0;
	float nz = water_fbm(p + vec2(0.0, e), t) - n0;
	// ⚠ 振幅 5.5 ＝整片海變成雜訊；水面的法線擾動其實很小（波高只有幾公分）
	NORMAL = normalize(NORMAL + vec3(-nx, 0.0, -nz) * (0.85 * amp));

	// ---- 顏色：深度決定；菲涅耳負責「反射天空」——真實水面一半是天空的鏡子 ----
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	float dayness = clamp(sun_energy * 0.85, 0.15, 1.0);
	vec3 shallow_c = vec3(0.20, 0.45, 0.44) * mix(0.40, 1.0, dayness);
	vec3 deep_c = vec3(0.02, 0.09, 0.17) * mix(0.55, 1.0, dayness);
	vec3 body = mix(shallow_c, deep_c, smoothstep(0.06, 0.85, d));
	// 世界空間的法線與反射向量（fragment 的 NORMAL 是視空間，要轉回世界）
	vec3 wn = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 vdir = normalize(wpos - CAMERA_POSITION_WORLD);
	vec3 refl = reflect(vdir, wn);
	// 反射的天空色：往上看到天頂色、掠角看到地平線色（跟天空 shader 同一套漸層）
	vec3 sky_refl = mix(sky_hor, sky_top, pow(clamp(refl.y, 0.0, 1.0), 0.6));

	// ---- 折射：水下的東西會被扭曲。少了這件，水面就是一張貼在地上的色紙 ----
	//   ⚠ 網頁版走 gl_compatibility，SCREEN_TEXTURE 仍可用但要保守：
	//     位移量隨水深與距離收斂，太大會在岸邊把陸地也扯進來。
	vec2 uv_off = vec2(-nx, -nz) * (0.12 * near_k) * clamp(d * 2.0, 0.0, 1.0);
	vec3 under = texture(screen_tex, SCREEN_UV + uv_off).rgb;
	// 水對紅光吸收最快、綠次之、藍最慢（潛水照片偏藍綠就是這個）：
	// 用指數吸收取代單一混色，水下的東西越深越往藍綠沉，不是均勻變暗。
	under *= exp(-vec3(2.6, 1.1, 0.62) * d * 1.9);
	// 淺水焦散：陽光被波面聚焦在水底晃動的亮網。兩層錯角雜訊相乘＝細碎的聚光點。
	float caus = vnoise(wpos.xz * 1.35 + vec2(t * 0.31, -t * 0.22))
			* vnoise(WROT * wpos.xz * 1.62 - vec2(t * 0.18, t * 0.27));
	under *= 1.0 + pow(caus, 3.0) * 2.2 * dayness;
	// 淺水看得到底（折射的畫面佔比高），深水幾乎看不到
	float see_through = (1.0 - smoothstep(0.05, 0.55, d)) * near_k;
	vec3 col = mix(body, mix(under, body, 0.30), see_through);
	// 菲涅耳天空反射：掠角時水面就是天空的鏡子（強度隨距離收一點防遠處死白）
	col = mix(col, sky_refl, fres * mix(0.30, 0.52, near_k));
	// 浪脊透光（假次表面散射）：浪峰薄、陽光穿過去會亮成青綠色——
	// 只在浪峰（fbm 高處）且非鏡面角度時出現，這是「水是液體」的關鍵訊號。
	col += vec3(0.05, 0.16, 0.13) * smoothstep(0.60, 0.86, n0) * near_k * (1.0 - fres) * dayness;
	// 太陽閃爍（sun glint）：反射向量對準太陽的窄高光 × 細碎閃點雜訊。
	// 黃昏的海面那條金色碎光就是它；k 值高＝高光窄，加雜訊才會「碎」。
	float glint = pow(clamp(dot(refl, normalize(sun_dir)), 0.0, 1.0), 220.0);
	float sparkle = 0.45 + 0.55 * vnoise(wpos.xz * 6.5 + vec2(t * 1.3, -t * 0.9));
	col += sun_col * glint * sparkle * 2.4;

	// ---- 岸邊浪花：會一進一退，不是固定寬度的白鑲邊 ----
	//   浪的相位沿著「離岸方向」推進，所以看起來是浪往岸上打
	float wave = sin(dot(wpos.xz, normalize(flow + vec2(0.001))) * 1.6 - TIME * 1.7)
			* 0.5 + 0.5;
	float lap = mix(0.030, 0.075, wave);           // 浪花線的寬度在呼吸
	float foam = (1.0 - smoothstep(0.0, lap, d))
			* (0.55 + 0.45 * water_fbm(wpos.xz * 0.8, TIME * 1.2));
	// 回捲浪（backwash）：主浪花線後面一條更淡、相位相反的碎沫帶——
	// 浪退下去時留在水面上的那層泡，真實岸邊永遠是兩層不是一層。
	float back = (1.0 - smoothstep(lap * 1.6, lap * 4.0, d))
			* smoothstep(0.0, lap * 1.2, d)
			* (1.0 - wave) * water_fbm(wpos.xz * 1.7 + 31.7, TIME * 0.9);
	foam = clamp(foam + back * 0.5, 0.0, 1.0);
	// 浪花的白要跟著時段走：夜戰的泡沫不會自己發光（ch10 實拍是一圈青色霓虹）。
	vec3 foam_c = vec3(0.88, 0.92, 0.93) * dayness * (0.55 + 0.45 * clamp(sky_hor, 0.0, 1.0).g);
	col = mix(col, foam_c, clamp(foam, 0.0, 0.55) * (0.4 + 0.6 * near_k));

	ALBEDO = col;
	// 有折射的地方要不透明（顏色已經含水下畫面），否則會透兩次變得死白
	ALPHA = clamp(max(0.94 * smoothstep(0.0, 0.42, d), see_through * 0.9), 0.0, 0.96);
	// 遠處霧面：避免鏡面把朝霞染成粉紅、也避免高頻法線在遠處產生摩爾紋
	ROUGHNESS = mix(0.58, 0.16, near_k);
	SPECULAR = mix(0.10, 0.45, near_k);
}
"""

# ---------- 城市街區（town / urban；2026-07-27 使用者第 4 項）----------
# `assets/kits/DowntownCity` 有 153 個模組件，但專案**只用到它的貼圖，模型一個都沒用**，
# 於是 town/urban 就是「草原上放六棟程式生成的房子」，完全沒有城市感。
# 三個原則見 CityBlocks.gd 檔頭；這裡負責「排在哪」。
func _scatter_city(gwp: float, ghp: float) -> void:
	if terrain == null or String(terrain.biome.get("key", "")) != "urban":
		return
	var whole := {}
	for n in CITY.WHOLE:
		var d: Dictionary = CITY.load_parts(self, n)
		if not d.is_empty():
			whole[n] = d
	if whole.is_empty():
		# ⚠ 大聲喊：素材沒載到就會靜默變回「空曠草原」，而那正是原本的症狀。
		push_error("[city] 街區模型一個都沒載到（assets/models/city/ 是不是沒 --import？）")
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260728
	var xf_by_mesh := {}
	# 街廓格線：建築最寬 20.6m，留 13m 街道 → 34m 一格。
	# 對齊格線是關鍵：隨機散佈會變成郊區獨棟，沿街連續才是城市。
	var cell := 34.0 / WORLD_SCALE
	var out_px: float = 150.0 / WORLD_SCALE          # 街廓帶往外鋪 150m，做出天際線
	var placed := 0
	var gx: float = -out_px
	while gx < gwp + out_px:
		var gy: float = -out_px
		while gy < ghp + out_px:
			gy += cell
			# 戰場內（含 12m 緩衝）不放：戰場內的可進入建築是 Building.gd 那一套
			if gx > -12.0 / WORLD_SCALE and gx < gwp + 12.0 / WORLD_SCALE 					and gy > -12.0 / WORLD_SCALE and gy < ghp + 12.0 / WORLD_SCALE:
				continue
			if rng.randf() < 0.16:
				continue                              # 空地／停車場，不要排到滿
			var name: String = CITY.WHOLE[rng.randi() % CITY.WHOLE.size()]
			var d2: Dictionary = whole.get(name, {})
			if d2.is_empty():
				continue
			var ab: AABB = d2["aabb"]
			# 貼著街廓邊緣（沿街面），不是擺在格子正中央
			var jx: float = gx + rng.randf_range(-0.10, 0.10) * cell
			var jy: float = gy + rng.randf_range(-0.10, 0.10) * cell
			var ty: float = terrain.height_at_mesh(jx, jy) if terrain != null else 0.0
			var yaw: float = float(rng.randi() % 4) * PI * 0.5 + rng.randf_range(-0.04, 0.04)
			var sc: float = rng.randf_range(0.85, 1.25)
			# 基準高＝腳印四角的最低地形（鐵律 0③ 建築不可懸空）：
			# 取中心點高的話，坡地上角落會懸空、樓底裂縫露出紅磚內面
			# ＝遠看整圈紅光帶（2026-07-31 使用者實拍；固定嵌深 0.6 仍在陡坡漏）
			var hxp: float = ab.size.x * 0.5 * sc / WORLD_SCALE
			var hzp: float = ab.size.z * 0.5 * sc / WORLD_SCALE
			for cx0 in [-1.0, 1.0]:
				for cz0 in [-1.0, 1.0]:
					var rx: float = cx0 * hxp * cos(yaw) - cz0 * hzp * sin(yaw)
					var rz: float = cx0 * hxp * sin(yaw) + cz0 * hzp * cos(yaw)
					ty = minf(ty, terrain.height_at_mesh(jx + rx, jy + rz))
			var base := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * sc),
					Vector3((jx - gwp * 0.5) * WORLD_SCALE,
							ty - ab.position.y * sc - 0.25, (jy - ghp * 0.5) * WORLD_SCALE))
			for part in d2["parts"]:
				var k = part[0]
				if not xf_by_mesh.has(k):
					xf_by_mesh[k] = []
				xf_by_mesh[k].append(base * (part[1] as Transform3D))
			placed += 1
		gx += cell
	# 戰場內：沿道路鋪人行道與街道小物（可通行、不擋路）
	var ground := {}
	for n2 in ["Sidewalk_Straight_3m"]:
		var dg: Dictionary = CITY.load_parts(self, n2)
		if not dg.is_empty():
			ground[n2] = dg
	var props := {}
	for n3 in CITY.PROPS:
		var dp: Dictionary = CITY.load_parts(self, n3)
		if not dp.is_empty():
			props[n3] = dp
	for rd in map_data.get("roads", []):
		var a := Vector2(float(rd.get("x1", 0)), float(rd.get("y1", 0)))
		var b := Vector2(float(rd.get("x2", 0)), float(rd.get("y2", 0)))
		var dirv: Vector2 = (b - a).normalized()
		var nrm := Vector2(-dirv.y, dirv.x)
		var total: float = a.distance_to(b)
		var half: float = float(rd.get("w", 40)) * 0.5 + 1.5 / WORLD_SCALE
		var stepp: float = 3.0 / WORLD_SCALE
		var t := stepp
		while t < total - stepp:
			for sgn in [-1.0, 1.0]:
				var q: Vector2 = a + dirv * t + nrm * half * sgn
				if q.x < 6.0 or q.y < 6.0 or q.x > gwp - 6.0 or q.y > ghp - 6.0:
					continue
				if terrain.in_water(q.x, q.y):
					continue
				var yaw2: float = atan2(dirv.y, dirv.x)
				var ty2: float = terrain.height_at_mesh(q.x, q.y)
				var xf2 := Transform3D(Basis(Vector3.UP, -yaw2),
						Vector3((q.x - gwp * 0.5) * WORLD_SCALE, ty2 + 0.02,
								(q.y - ghp * 0.5) * WORLD_SCALE))
				for key2 in ground:
					var dd: Dictionary = ground[key2]
					for part2 in dd["parts"]:
						var k2 = part2[0]
						if not xf_by_mesh.has(k2):
							xf_by_mesh[k2] = []
						xf_by_mesh[k2].append(xf2 * (part2[1] as Transform3D))
				# 街道小物：每隔幾格放一個（不要每格都放，那會變成一排柱子）
				if rng.randf() < 0.16 and not props.is_empty():
					var pk: String = CITY.PROPS[rng.randi() % CITY.PROPS.size()]
					if props.has(pk):
						var xf3 := Transform3D(Basis(Vector3.UP, rng.randf() * TAU),
								Vector3((q.x - gwp * 0.5) * WORLD_SCALE, ty2 + 0.03,
										(q.y - ghp * 0.5) * WORLD_SCALE))
						for part3 in (props[pk]["parts"] as Array):
							var k3 = part3[0]
							if not xf_by_mesh.has(k3):
								xf_by_mesh[k3] = []
							xf_by_mesh[k3].append(xf3 * (part3[1] as Transform3D))
			t += stepp
	for mk in xf_by_mesh.keys():
		var list: Array = xf_by_mesh[mk]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mk
		mm.instance_count = list.size()
		for k4 in list.size():
			mm.set_instance_transform(k4, list[k4])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "CityBlocks"
		mmi.multimesh = mm
		world.add_child(mmi)
	print("[city] 街廓建築 %d 棟、網格 %d 種" % [placed, xf_by_mesh.size()])

func _scatter_trees(mw: float, mh: float) -> void:
	# ★★2026-07-27 重寫（使用者：「樹木要做到細緻細膩」）。
	# 舊版：全場只有 tree-single 與 pinetrees 兩個 glb，整片森林是同一棵樹複製貼上
	#   （他形容「樹是紙片」）。而且**外圍那片森林的分支完全跳過水域檢查**，
	#   改成曲線海岸之後，遠景整排樹站在海面上（實拍抓到）。
	# 新版：Trees.gd 程式化五個樹種 × 三個變體，per-instance 顏色讓每一棵葉色都不同；
	#   靠水邊改長椰子與灌木；戰場外那片走同一套規則（含水域檢查）。
	var gwp: float = map_data.get("w", 960)
	var ghp: float = map_data.get("h", 600)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260727
	var tmul: float = float(terrain.biome.get("tree_mult", 1.0)) if terrain != null else 1.0
	if terrain != null and float(terrain.biome.get("rock_mult", 0.0)) > 0.01:
		_scatter_rocks(gwp, ghp)
	if tmul < 0.01:
		return
	var bkey: String = String(terrain.biome.get("key", "grass")) if terrain != null else "grass"
	var protos: Dictionary = TREES.build_protos()
	var xf_by_mesh := {}
	var col_by_mesh := {}
	var out_px: float = 88.0 / WORLD_SCALE
	var want: int = int(clampf((gwp + out_px * 2.0) * (ghp + out_px * 2.0) / 26000.0 * tmul,
			40.0, 1400.0))
	var placed := 0
	var guard := 0
	while placed < want and guard < want * 30:
		guard += 1
		var px: float = rng.randf_range(-out_px, gwp + out_px)
		var py: float = rng.randf_range(-out_px, ghp + out_px)
		var outside: bool = px < 0.0 or py < 0.0 or px > gwp or py > ghp
		# 疏密節奏：邊緣成林、中央疏開；再疊低頻雜訊做林塊與空地。
		# 林塊一定要用 hash 值雜訊，正弦疊加會排成規則格狀，遠看像果園。
		var clump: float = terrain._vnoise(px * 0.0035, py * 0.0035) if terrain != null else 0.5
		clump = clampf((clump - 0.34) * 2.7, 0.0, 1.0)
		var chance: float
		if outside:
			chance = 0.05 + 0.80 * clump * clump   # 平方＝林塊更集中、空地更明顯
		else:
			var nx: float = (px / gwp - 0.5) * 2.0
			var ny: float = (py / ghp - 0.5) * 2.0
			var edge: float = clampf((sqrt(nx * nx + ny * ny) - 0.30) / 0.85, 0.0, 1.0)
			chance = edge * (0.15 + 0.85 * clump)
		if rng.randf() > chance:
			continue
		var tp := Vector2(px, py)
		# ★水域檢查對「戰場內外」一視同仁——先前外圍那批完全沒驗，樹長在海裡
		if terrain != null and (terrain.in_trench(px, py) or terrain.in_water(px, py)):
			continue
		if not outside:
			var blocked := false
			for bd2 in _buildings:
				if bd2.rect.grow(5.0 / WORLD_SCALE).has_point(tp):
					blocked = true
					break
			if not blocked:
				for bk in _blockers:
					if tp.distance_to(_blk_closest(bk, tp)) < 2.2 / WORLD_SCALE:
						blocked = true
						break
			if blocked:
				continue
		# 離水多近（3m 內算水邊）：海邊長椰子與灌木，松柏不會長在潮線上
		var near_water := false
		if terrain != null:
			for probe in [Vector2(60, 0), Vector2(-60, 0), Vector2(0, 60), Vector2(0, -60)]:
				if terrain.in_water(px + probe.x, py + probe.y):
					near_water = true
					break
		# 枯樹要長在該長的地方：彈坑與焦土附近的樹本來就被燒死了。
		# 「隨機灑幾棵枯樹」跟「被炸過的那一圈都是枯樹」在畫面上是完全不同的訊息量。
		var burnt := false
		for cr3 in map_data.get("foxholes", []):
			var rr3: float = float(cr3.get("r", 36)) * 2.6
			if tp.distance_to(Vector2(float(cr3.get("x", 0)), float(cr3.get("y", 0)))) < rr3:
				burnt = true
				break
		var kind: String = TREES.pick(bkey, near_water, rng)
		if burnt and rng.randf() < 0.65:
			kind = "dead"
		var vlist: Array = protos[kind]
		var mesh_key: ArrayMesh = vlist[rng.randi() % vlist.size()]
		# 縮放的變異要大（0.62~1.20）：樹種本身已經有兩倍高度差，再乘上這個，
		# 同一片林子裡才會有大樹、中樹、小樹三個層次，而不是一整排等高的人造林。
		var sc: float = rng.randf_range(0.62, 1.20)
		if outside:
			sc *= rng.randf_range(0.88, 1.18)
		var ty: float = terrain.height_at_mesh(px, py) if terrain != null else 0.0
		var lean := Basis(Vector3(1, 0, 0), rng.randf_range(-0.055, 0.055)) * Basis(Vector3(0, 0, 1), rng.randf_range(-0.055, 0.055))
		var base := Transform3D(
				(Basis(Vector3.UP, rng.randf() * TAU) * lean).scaled(Vector3.ONE * sc),
				Vector3((px - gwp * 0.5) * WORLD_SCALE, ty - 0.10 * sc,
						(py - ghp * 0.5) * WORLD_SCALE))
		if not xf_by_mesh.has(mesh_key):
			xf_by_mesh[mesh_key] = []
			col_by_mesh[mesh_key] = []
		xf_by_mesh[mesh_key].append(base)
		# 每一棵的色偏都不同（使用者的判準之一：「材質變化，不是一片純色」）
		col_by_mesh[mesh_key].append(Color(rng.randf_range(0.86, 1.14),
				rng.randf_range(0.88, 1.12), rng.randf_range(0.82, 1.10)))
		if not outside:
			var trunk_r: float = (0.34 if kind != "shrub" else 0.55) * sc
			var hmap := {"shrub": 1.6, "palm": 8.0, "pine": 10.0, "dead": 6.0}
			var trunk_h: float = float(hmap.get(kind, 7.0)) * sc
			_covers.append({"wx": px, "wy": py, "r": (34.0 if kind != "shrub" else 22.0) * sc,
					"val": 0.30, "type": "bush"})
			_tree_feet.append(tp)
			if kind != "shrub":
				# 樹幹擋人也擋彈道（灌木只隱蔽不擋——鐵律 0②看幾何不看標籤）。
				# 邊界帶的排除交給 _strip_edge_blockers 統一處理（原本這裡自己寫死
				# 30px，但沙包/柵欄/岩石也有同樣問題——一條規則只能有一份）。
				_blockers.append({"t": "cir", "c": tp, "r": trunk_r / WORLD_SCALE, "h": trunk_h})
		placed += 1
	# 2026-07-28 使用者：「樹木、特別是樹木上的葉子」要更真實。
	# 換 ShaderMaterial 做三件事：①風搖（整樹低頻搖＋葉面高頻顫）
	# ②葉片背光透光（迎著太陽看樹，葉緣透出暖綠——葉子是薄的，這是「葉」的關鍵訊號）
	# ③樹冠高度明暗（下層葉背光偏暗黃、頂層受光偏亮）。per-instance 色偏照舊吃 COLOR。
	var tmat := ShaderMaterial.new()
	var tsh := Shader.new()
	tsh.code = TREE_SHADER
	tmat.shader = tsh
	if _sun != null and is_instance_valid(_sun):
		tmat.set_shader_parameter("sun_dir", -_sun.global_transform.basis.z)
	_tree_mats.append(tmat)
	for mesh_key2 in xf_by_mesh.keys():
		var list: Array = xf_by_mesh[mesh_key2]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mesh_key2
		mm.instance_count = list.size()
		for k in list.size():
			mm.set_instance_transform(k, list[k])
			mm.set_instance_color(k, col_by_mesh[mesh_key2][k])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Trees"
		mmi.multimesh = mm
		mmi.material_override = tmat
		world.add_child(mmi)


# 樹木 shader（GDD/06；2026-07-28 樹葉真實化）。
# ⚠ 葉/幹用「頂點色綠紅差」區分，不另做 surface——樹是合併網格＋MultiMesh，
#   多一個 surface 就多一倍 draw call。COLOR＝網格頂點色 × 每棵樹的 instance 色偏。
# ⚠ 風搖寫在 vertex：位移量隨高度平方（樹根不動、樹梢擺最多），時間項用兩個
#   不成比例的頻率相加——單一 sin 會整片森林同步擺，像跳團體操（空間相位用世界座標打散）。
const TREE_SHADER := """
shader_type spatial;
render_mode cull_disabled;

uniform vec3 sun_dir = vec3(0.45, 0.62, 0.64);

varying vec3 vcol;
varying float leafm;    // 1＝葉、0＝幹（頂點色綠紅差）
varying float hfrac;    // 樹內高度 0~1（樹冠明暗用）
varying vec3 wpv;

void vertex() {
	vcol = COLOR.rgb;
	leafm = clamp((COLOR.g - COLOR.r) * 4.0, 0.0, 1.0);
	hfrac = clamp(VERTEX.y / 6.0, 0.0, 1.0);
	vec3 wp0 = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float ph = wp0.x * 0.35 + wp0.z * 0.53;      // 每棵樹相位不同：森林不齊步擺
	float sw = sin(TIME * 1.05 + ph) * 0.6 + sin(TIME * 1.71 + ph * 1.31) * 0.4;
	vec2 wind = vec2(0.83, 0.55);
	// 整樹搖：樹梢 ~6cm，樹根 0；葉多搖一點（枝葉柔、樹幹硬）
	VERTEX.xz += wind * sw * 0.055 * hfrac * hfrac * (0.45 + 0.55 * leafm);
	// 葉面顫：高頻小振幅，只有葉子有——近看時「葉子各自在動」就是這個
	VERTEX.y += sin(TIME * 5.3 + ph * 7.7 + VERTEX.x * 3.1) * 0.014 * leafm;
	wpv = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// 樹冠明暗：下層葉暗黃（吃不到光的老葉）、頂層亮綠——只作用在葉上
	vec3 grad = mix(vec3(0.82, 0.86, 0.76), vec3(1.06, 1.05, 0.97), hfrac);
	ALBEDO = vcol * mix(vec3(1.0), grad, leafm);
	ROUGHNESS = 0.94;
	// 背光透光（假 SSS）：太陽在樹後、鏡頭迎光看，薄葉透出暖綠。
	// 用 EMISSION 疊，不然正面陰影會把它吃掉。
	float bl = pow(max(dot(normalize(wpv - CAMERA_POSITION_WORLD),
			normalize(sun_dir)), 0.0), 4.0);
	EMISSION = vec3(0.10, 0.15, 0.05) * bl * leafm;
}
"""

# 天空 shader（雲層）：fbm 雜訊雲＋日盤＋大氣輝光。
# ⚠ 雲的 UV 要把視線投影到「一個高處的平面」：直接用 EYEDIR.xz 會讓雲在頭頂糊成一團、
#   地平線附近完全沒有雲。除以 (dir.y + 常數) 才有透視，雲才會往地平線收窄。
# ⚠ 雲要在地平線淡出（smoothstep），否則雲片會硬切在地平線上像貼紙。
# ⚠ 太陽在 -LIGHT0_DIRECTION（LIGHT0_DIRECTION 是「光射向哪」，太陽在反方向）。
const SKY_SHADER := """
shader_type sky;

uniform vec3 top_color : source_color = vec3(0.20, 0.40, 0.76);
uniform vec3 horizon_color : source_color = vec3(0.72, 0.82, 0.90);
uniform vec3 cloud_color : source_color = vec3(1.0, 0.99, 0.96);
uniform vec3 cloud_shadow : source_color = vec3(0.55, 0.60, 0.68);
uniform float cloud_cover = 0.42;
uniform float cloud_sharp = 2.6;
uniform vec3 ground_horizon : source_color = vec3(0.62, 0.66, 0.62);
uniform vec3 ground_bottom : source_color = vec3(0.28, 0.31, 0.27);
uniform float drift = 0.004;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);   // quintic：二階連續，格點邊界才不留菱形硬邊
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// ⚠ 每一階都要旋轉座標：value noise 的格點是軸對齊的，直接 p *= 2.0 疊起來會讓
//   雲出現一格一格的矩形階梯邊（第一版實拍就是滿天的方塊，看起來像壞掉的貼圖）。
//   旋轉一個非特殊角度就把方向性打散了。
const mat2 ROT = mat2(vec2(0.8018, 0.5977), vec2(-0.5977, 0.8018));   // 約 36.7 度

float fbm(vec2 p) {
	float s = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 6; i++) {
		s += vnoise(p) * amp;
		p = ROT * p * 2.03 + vec2(1.7, -2.3);
		amp *= 0.5;
	}
	return s;
}

void sky() {
	vec3 dir = normalize(EYEDIR);
	float h = clamp(dir.y, 0.0, 1.0);
	vec3 col = mix(horizon_color, top_color, pow(h, 0.55));
	// 地平線以下要有地面半球色，否則往下看是天空的淺色，遠景圖裡地圖邊緣會露出白邊
	if (dir.y < 0.0) {
		col = mix(ground_horizon, ground_bottom, pow(clamp(-dir.y, 0.0, 1.0), 0.5));
	}
	vec3 sun_dir = -LIGHT0_DIRECTION;
	float sd = max(dot(dir, sun_dir), 0.0);
	col += LIGHT0_COLOR * pow(sd, 900.0) * 8.0;      // 日盤
	col += LIGHT0_COLOR * pow(sd, 6.0) * 0.12;       // 大氣輝光
	if (dir.y > 0.004) {
		vec2 uv = dir.xz / (dir.y + 0.30) * 0.42 + vec2(TIME * drift, TIME * drift * 0.6);   // 分母加大：天頂的雲不再被投影擠成銳角多邊形
		float n1 = fbm(uv * 1.6);
		float n2 = fbm(uv * 4.1 + 7.0);
		// fbm 值域大約 0.15~0.85（平均 0.5），所以門檻要落在這個區間裡才有雲。
		// 域扭曲：把取樣座標本身用另一組雜訊推開，雲的輪廓才不會沿著格線走
		vec2 warp = vec2(fbm(uv * 0.9 + 3.1), fbm(uv * 0.9 + 8.7)) - 0.5;
		float n1w = fbm(uv * 1.6 + warp * 1.4);
		float n = n1w * 0.68 + n2 * 0.32;
		float thr = mix(0.68, 0.30, clamp(cloud_cover, 0.0, 1.0));
		// 柔邊要夠寬（0.16）：太窄會把插值的幾何邊直接切出來變成多邊形雲
		float d = smoothstep(thr, thr + 0.16, n);
		d *= smoothstep(0.0, 0.18, dir.y);
		float lit = clamp(n2 * 0.7 + sd * 0.3, 0.0, 1.0);
		col = mix(col, mix(cloud_shadow, cloud_color, lit), d);
	}
	COLOR = col;
}
"""
