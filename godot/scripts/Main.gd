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
# 掩體登記表（GDD/13 Phase2）：每筆＝{wx,wy,r,val,type}，座標為遊戲 px。
# val＝遮蔽強度 0~1；sandbag 硬掩體、building 全掩體、bush 只給隱蔽(降敵視野)不擋彈。
var _covers: Array = []
# 新腳本的 class_name 要等編輯器掃描過才註冊得到，直接用會 Parse Error（2026-07-26 踩到）。
# 用 preload 引用最保險，不依賴 .godot 的類別快取。
const TERRAIN := preload("res://scripts/Terrain.gd")
const BUILDING := preload("res://scripts/Building.gd")
const PROPS := preload("res://scripts/Props.gd")
const FORTIFY := preload("res://scripts/Fortify.gd")
var _buildings: Array = []             # 場上所有建築（牆線段＝視線與碰撞的真相）
var terrain = null                     # 地形高度真相（GDD/14）
# 中景物件與樹的實體障礙（形狀定義見 Props.blockers），座標為遊戲 px。
var _blockers: Array = []
var _tree_feet: Array = []             # 樹腳位置（px）：Terrain 在樹底補草做過渡
const BODY_R := 0.42                   # 步兵肩寬半徑
const VEHICLE_R := 1.6                 # 載具車體半徑（坦克 3.1m 寬）

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
	ui.end_action.connect(_end_action)
	ui.back_menu.connect(_open_menu)
	_open_menu()
	if "e2e" in OS.get_cmdline_user_args():
		_e2e()
	elif "selftest" in OS.get_cmdline_user_args():
		_selftest()
	elif "shotseq" in OS.get_cmdline_user_args():
		_shotseq()
	elif "mapshots" in OS.get_cmdline_user_args():
		_mapshots()

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
	for id in GameData.maps.keys():
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
	get_tree().quit(0)

func _shotseq() -> void:
	for i in 5:
		await get_tree().create_timer(1.2).timeout
		await _snap("res://seq_%d.png" % i)
		print("[shotseq] seq_%d st=%d" % [i, st])
	get_tree().quit(0)

func _e2e() -> void:
	await get_tree().create_timer(0.6).timeout
	print("[e2e] 1 主選單 → 劇情戰役")
	if not await _click_btn("劇情戰役"): get_tree().quit(1); return
	print("[e2e] 2 章節 01")
	var chb := _find_btn("01")
	if chb == null: print("[e2e] FAIL 無章節按鈕"); get_tree().quit(1); return
	_send_click(chb.get_global_rect().get_center())
	await get_tree().create_timer(0.5).timeout
	print("[e2e] 3 簡報 → 出擊")
	if not await _click_btn("出擊"): get_tree().quit(1); return
	print("[e2e] 4 對話：連點推進 (st=", st, ")")
	var guard := 0
	while st == St.DIALOGUE and guard < 40:
		_send_click(Vector2(640, 300))
		await get_tree().create_timer(0.12).timeout
		guard += 1
	print("[e2e]   對話結束 st=", st, " (應為 DEPLOY=", St.DEPLOY, ")")
	if st != St.DEPLOY: print("[e2e] FAIL 沒進到部署"); get_tree().quit(1); return
	print("[e2e] 5 部署：點卡片 → 點藍框放置")
	var cards := ui.root.find_children("*", "Button", true, false)
	var card_btn: Button = null
	for n in cards:
		var b := n as Button
		if b.flat and b.size.x > 250:
			card_btn = b; break
	if card_btn == null: print("[e2e] FAIL 找不到部署卡"); get_tree().quit(1); return
	_send_click(card_btn.get_global_rect().get_center())
	await get_tree().create_timer(0.3).timeout
	var z := _my_zone()
	var wp := _to3d(z.get("x", 0) + z.get("w", 300) * 0.5, z.get("y", 0) + z.get("h", 200) * 0.5)
	_send_click(cam.unproject_position(wp + Vector3(0, 0.05, 0)))
	await get_tree().create_timer(0.4).timeout
	print("[e2e]   已部署數=", _deployed.size(), (" OK" if _deployed.size() > 0 else " FAIL(放不下去)"))
	if _deployed.is_empty(): get_tree().quit(1); return
	print("[e2e] 6 開始戰鬥")
	if not await _click_btn("開始戰鬥"): get_tree().quit(1); return
	await get_tree().create_timer(0.8).timeout
	print("[e2e]   st=", st, " (應為 CMD=", St.CMD, ")")
	print("[e2e] 7 選兵 → 點地面移動")
	var pu = _deployed[0]
	_send_click(cam.unproject_position(pu["node"].global_position + Vector3(0, 1.0, 0)))
	await get_tree().create_timer(0.25).timeout
	print("[e2e]   選取=", "OK" if selected != null else "FAIL(點不到兵)")
	print("[e2e]   第三人稱=%s" % ("OK" if cam.is_tps() else "FAIL(沒進第三人稱)"))
	var before: Vector3 = pu["node"].global_position
	await _hold_key(KEY_W, 1.5)
	var moved: float = before.distance_to(pu["node"].global_position)
	print("[e2e]   位移=%.2fm %s" % [moved, "OK" if moved > 0.5 else "FAIL(人沒動)"])
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
	cam.focus = hero["node"].global_position + Vector3(0, 1.1, 0)
	cam.dist = 3.2
	cam.pitch_deg = 8.0
	cam.yaw = deg_to_rad(35.0)
	await get_tree().create_timer(0.6).timeout
	await _snap("res://e2e_hero_idle.png")
	hero["node"].move_to(hero["node"].global_position + hero["node"].facing_dir() * 6.0)
	await get_tree().create_timer(0.7).timeout
	cam.focus = hero["node"].global_position + Vector3(0, 1.1, 0)
	await _snap("res://e2e_hero_run.png")
	# 趴姿在英雄模型上的實況：側面＋正面各一張（背後視角看不出手腳，踩過兩次）
	hero["node"].stop()
	hero["node"].want_prone = true
	await get_tree().create_timer(1.6).timeout
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
	get_tree().quit(0)

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
	print("[movechk] 第三人稱前進位移=%.2fm %s" % [moved, "OK" if moved > 0.5 else "FAIL(人沒動)"])
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
	var reach_m: float = _ap_metres(acting)
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
			print("[buildingchk] 進屋後屋頂淡出 alpha=%.2f %s" % [float(_roof_a.get(0, 1.0)),
					"OK" if float(_roof_a.get(0, 1.0)) < 0.15 else "FAIL"])
			await _snap("res://bld_ingame.png")
			cam.clear_tps()
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
			var clear_r: float = 8.0 / WORLD_SCALE
			var found_spot := false
			for gy in range(2, 13):
				for gx in range(2, 19):
					var c := Vector2(mwp * float(gx) / 20.0, mhp * float(gy) / 14.0)
					var ok := true
					for bk2 in _blockers:
						var cp2: Vector2 = bk2["c"] if bk2["t"] == "cir" 								else Geometry2D.get_closest_point_to_segment(c, bk2["a"], bk2["b"])
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
			var tgap: float = (solu["wy"] - soltk["wy"]) * WORLD_SCALE
			print("[solidchk] 對著坦克走 5 秒：空地=%s 停在車體外 %.2fm、剩餘AP=%.0f %s"
					% [found_spot, tgap, float(solu["ap"]),
					"OK(載具是實體)" if (tgap > VEHICLE_R * 0.9 and tgap < 3.5 and float(solu["ap"]) > 1.0)
					else "FAIL(穿過去了/沒走到/AP用盡)"])
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
			var shot_body: bool = _shot_clear(sb_a, sb_b, 1.32, 1.15)      # 站→站的軀幹
			var shot_head: bool = _shot_clear(sb_a, sb_b, 1.32, 1.52)      # 站→站的頭
			var shot_crouch: bool = _shot_clear(sb_a, sb_b, 0.92, 0.78)    # 蹲→蹲
			var shot_along: bool = _shot_clear(sb_a, sb_a + (sbg["b"] - sbg["a"]).normalized()
					* (8.0 / WORLD_SCALE), 1.32, 1.15)                        # 沿著沙包同側射
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
		_unshield(phu, phu_save)
		# I-4c) AI 繞開實體障礙（AI09 [navchk]）：直接驗純函式，不受敵方階段時序干擾
		if _blockers.is_empty():
			print("[navchk] SKIP 這張圖沒有中景障礙")
		else:
			var nseg = null
			for bk3 in _blockers:
				if bk3["t"] == "seg" and (nseg == null or float(bk3["hl"]) > float(nseg["hl"])):
					nseg = bk3
			if nseg == null:
				print("[navchk] SKIP 沒有線段型障礙")
			else:
				var keep_b4 := _buildings
				_buildings = []
				var nf: Vector3 = _to3d(nseg["m"].x, nseg["m"].y + 5.0 / WORLD_SCALE)
				var ng: Vector3 = _to3d(nseg["m"].x, nseg["m"].y - 5.0 / WORLD_SCALE)
				var straight: bool = _path_clear(nf, ng, BODY_R)
				var alt: Vector3 = _avoid_goal(nf, ng, BODY_R)
				var alt_ok: bool = _path_clear(nf, alt, BODY_R)
				var turned: bool = alt.distance_to(ng) > 0.5
				_buildings = keep_b4
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
			cru["ap"] = 300.0
			cru["ap_max"] = 300.0
			cam.tps_yaw = 180.0
			await get_tree().create_timer(1.6).timeout       # 等趴下（_prone 收斂）
			var cr_from: Vector3 = cru["node"].global_position
			# 分三段走，每段量一次雙腳的側向張開量：匍匐是左右腿交替蹬地，
			# 這個數值必須隨時間變化——只拍一張靜態圖看不出「有沒有在交替」。
			# 量的是「膝蓋」不是腳：匍匐的特徵是膝蓋先彎、再帶著大腿往外頂，
			# 腳跟其實是折回身體中線的（使用者 2026-07-26 指正）。
			var spreads: Array = []
			var knee_angles: Array = []
			var knee_fwd: Array = []
			var hand_fwd: Array = []
			for seg_i in 3:
				await _hold_key(KEY_W, 0.55)
				var rg = cru["node"]._rig
				var kl: Vector3 = rg.bone_pos("LowerLeg.L")
				var kr: Vector3 = rg.bone_pos("LowerLeg.R")
				spreads.append(kl.distance_to(kr))
				# 依 STP 21-1-SMCT，low crawl 的動力腿是右腿、左腿伸直拖在身後。
				# 這個測試原本量左腿，於是「左腿本來就該伸直」被誤判成剪刀腳 FAIL。
				# 量錯維度＝白修，本專案第二次踩到，所以改量右腿。
				var hipp: Vector3 = rg.bone_pos("UpperLeg.R")
				var thigh: Vector3 = kr - hipp
				var shin: Vector3 = rg.bone_pos("Foot.R") - kr
				if thigh.length() > 0.001 and shin.length() > 0.001:
					knee_angles.append(rad_to_deg(thigh.angle_to(shin)))
				# ★剪刀腳判定：匍匐是把膝蓋收到身體「前方」蹬地，剪刀腳是膝蓋往側後張開。
				#   只量外張量與屈膝角會漏掉這件事（使用者指正三次才抓到）。
				var fwdv: Vector3 = cru["node"].facing_dir()
				knee_fwd.append((kr - hipp).dot(fwdv))
				# 左手要往前撐地拉行：趴姿唯一看得見的推進動作
				var hl: Vector3 = rg.bone_pos(cru["node"]._hand_l)
				hand_fwd.append((hl - cru["node"].global_position).dot(fwdv))
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
			var sp_min: float = spreads.min()
			var sp_max: float = spreads.max()
			print("[crawlchk] 趴著走 2.1 秒：位移 %.2fm、動畫=%s、髖高 %.2fm %s" % [cr_d, cr_state, cr_hip,
					"OK(是匍匐不是趴著跑)" if (cr_d > 0.6 and cr_d < 2.6 and cr_state != "run"
					and cr_state != "walk" and cr_hip < 0.55 and cr_hip > 0.05)
					else "FAIL(速度/動畫/姿勢不對，髖高<=0 代表人陷進地裡)"])
			print("[crawlchk] 膝蓋外張量 %.2f/%.2f/%.2f m（差 %.2f） %s" % [spreads[0], spreads[1],
					spreads[2], sp_max - sp_min,
					"OK(雙腿在交替蹬地)" if (sp_max - sp_min) > 0.05 else "FAIL(腿沒動＝只是趴著平移)"])
			if not knee_fwd.is_empty():
				var kf_max: float = knee_fwd.max()
				print("[crawlchk] 右膝相對髖部前後 %.2f/%.2f/%.2f m（正=在前方蹬地） %s" % [
						knee_fwd[0], knee_fwd[1], knee_fwd[2],
						"OK(膝蓋往前收)" if kf_max > 0.05 else "FAIL(膝蓋往側後張＝剪刀腳)"])
			if hand_fwd.size() >= 3:
				var hf_min: float = hand_fwd.min()
				var hf_max: float = hand_fwd.max()
				print("[crawlchk] 左手前伸距離 %.2f/%.2f/%.2f m（擺幅 %.2f） %s" % [hand_fwd[0],
						hand_fwd[1], hand_fwd[2], hf_max - hf_min,
						"OK(手在往前撐地拉行)" if (hf_max - hf_min) > 0.12 and hf_max > 0.35
						else "FAIL(手沒動＝只有身體在滑)"])
			if knee_angles.is_empty():
				print("[crawlchk] 屈膝角度量不到 FAIL(骨頭抓不到)")
			else:
				var ka_max: float = knee_angles.max()
				print("[crawlchk] 右膝(動力腿)彎曲角 %.0f/%.0f/%.0f 度（0=伸直，最大 %.0f） %s" % [knee_angles[0],
						knee_angles[1], knee_angles[2], ka_max,
						"OK(膝蓋真的有彎)" if ka_max > 30.0 else "FAIL(腿是伸直的＝剪刀腿不是匍匐)"])
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
	get_tree().quit(0)

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
	ui.show_story(_unlocked())

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
		ui.update_hud(turn, "player", cp)
		ui.show_ap(u["ap"], u["ap_max"])
		_update_ap_ring()
		# 下令＝進入第三人稱操控（GDD/07）：鏡頭滑到角色背後、滑鼠鎖定成自由視角
		cam.set_tps(u["node"])
		ui.show_crosshair(true)
		_capture_mouse(true)
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
	_update_cover_state(acting)
	acting = null
	ui.hide_ap()
	if is_instance_valid(_ap_ring):
		_ap_ring.visible = false

# 剩餘 AP 還能走幾公尺
func _ap_metres(u) -> float:
	return float(u.get("ap", 0.0)) * PX_PER_AP * WORLD_SCALE

# 行動範圍圈：VC 用 AP 條，這裡再加一圈地面指示，玩家才知道還能走多遠
func _update_ap_ring() -> void:
	if acting == null:
		return
	if not is_instance_valid(_ap_ring):
		_ap_ring = MeshInstance3D.new()
		_ap_ring.mesh = TorusMesh.new()
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(1.0, 0.85, 0.35, 0.55)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ap_ring.material_override = m
		add_child(_ap_ring)
	var r: float = maxf(_ap_metres(acting), 0.05)
	var tm := _ap_ring.mesh as TorusMesh
	tm.inner_radius = maxf(r - 0.12, 0.02)
	tm.outer_radius = r
	_ap_ring.global_position = acting["node"].global_position + Vector3(0, 0.05, 0)
	_ap_ring.visible = true

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

func _ai_deploy() -> void:
	var es := 1 - player_side
	var zone: Dictionary = {}
	var dz = map_data.get("deploy", [])
	if dz is Array and dz.size() > es:
		zone = dz[es]
	else:
		zone = {"x": 560, "y": 250, "w": 300, "h": 200}
	# 敵軍鏡射玩家進度：載具未解鎖不出、步兵數 = 已解鎖具名+1
	var named_n := 0
	for cls in GameData.characters.keys():
		if GameData.characters[cls].get("unlockCh", 1) <= chapter:
			named_n += 1
	var pool := ["mg", "at", "sniper", "assault", "rifleman", "rifleman", "engineer"]
	var count = min(named_n + 1, pool.size())
	for i in count:
		var cls: String = pool[i]
		if not CLASS_MODEL.has(cls):
			continue
		var wx: float = zone.get("x", 560) + 30 + (i % 3) * 55
		var wy: float = zone.get("y", 250) + 30 + int(i / 3) * 55
		_spawn_unit(cls, es, wx, wy, false)

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
	ui.update_hud(turn, "player", cp)
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
	var u := {
		"cls": cls, "side": side_i, "node": node, "wx": wx, "wy": wy,
		"hp": hp, "maxhp": hp, "alive": true,
		"weapon": GameData.weapon_of(nation[side_i], cls),
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
		y = terrain.height_at(wx, wy)
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
			var sight := SIGHT
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
			var tgt = _tps_target()
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
				if cam.is_tps():
					_capture_mouse(true))
			return
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if st == St.CMD:
			_click(event.position)
		elif st == St.DEPLOY:
			_deploy_click(event.position)

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
	var reach: float = _ap_metres(acting)
	if reach < 0.05:
		ui.flash_msg("AP 用盡，只能原地開火或結束行動", Color(1.0, 0.7, 0.4))
		return
	# 超出 AP 的點：走到能走的最遠處（而不是不理玩家或直接走完）
	var here: Vector3 = acting["node"].global_position
	var to := hit - here
	to.y = 0.0
	if to.length() > reach:
		hit = here + to.normalized() * reach
	acting["node"].move_to(_clamp_to_map(hit))
	_refresh_visibility()

# 開火（part＝瞄準部位，GDD/01 §4）。AI 與迎擊一律 body（不瞄部位）。
func _fire(shooter, target, part := "body") -> void:
	var dist_px := Vector2(target["wx"] - shooter["wx"], target["wy"] - shooter["wy"]).length()
	shooter["node"].shoot_at(target["node"])
	shooter["fired"] = true      # 每次行動只能開火一次；CP 在下令時就扣過了（GDD/01 §1-2）
	ui.update_hud(turn, "player" if st == St.CMD else "enemy", cp)
	await get_tree().create_timer(0.32).timeout
	if not shooter["alive"] or not target["alive"]:
		return
	# 彈道被實體吃掉＝這一槍打在障礙上（AI 與第三人稱自由射擊都會走到這裡）
	if not _shot_clear_units(shooter, target, part):
		if shooter["side"] == player_side:
			ui.flash_msg("子彈打在掩體上", Color(0.9, 0.8, 0.6))
		_refresh_visibility()
		return
	# 掩體修正（Phase2）：方向性遮蔽最多削 60% 命中
	var cov: float = cover_at(target["wx"], target["wy"], shooter["wx"], shooter["wy"])
	var hc: float = GameData.hit_chance(_wrap(shooter), _wrap(target), dist_px, part) * (1.0 - cov * 0.6)
	if hc > randf():
		target["hp"] -= GameData.damage(_wrap(shooter), _wrap(target), part)
		if part != "body":
			ui.flash_msg("命中%s！" % ("頭部" if part == "head" else "散熱器"), Color(1.0, 0.9, 0.4))
		if target["hp"] <= 0 and target["alive"]:
			target["alive"] = false
			target["node"].die()          # 淡出傾倒後自我移除
		elif target["alive"]:
			target["node"].take_hit()     # 受擊：立繪換 hurt 表情＋紅閃
	_refresh_visibility()
	_check_end()

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
	return _UW.new(u)
class _UW:
	var weapon: Dictionary
	var cls: String
	func _init(u: Dictionary):
		weapon = u["weapon"]
		cls = u["cls"]

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
	ui.update_hud(turn, "enemy", enemy_cp)

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
	_action_tick(delta)
	_intercept_tick(delta)
	if st == St.ENEMY:
		_enemy_t -= delta
		_ai_t += delta
		if _enemy_t <= 0:
			_enemy_step()
			_enemy_t = 0.25

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
		var fixed: Vector3 = _resolve_solids(node.global_position, r, u)
		if fixed.distance_squared_to(node.global_position) > 0.000001:
			node.global_position = Vector3(fixed.x, node.global_position.y, fixed.z)
			var p := _live_px(u)
			u["wx"] = p.x
			u["wy"] = p.y
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
			a["node"].global_position -= Vector3(push.x, 0, push.y)
			b["node"].global_position += Vector3(push.x, 0, push.y)
			for uu in [a, b]:
				var pp := _live_px(uu)
				uu["wx"] = pp.x
				uu["wy"] = pp.y

# 屋頂淡出（GDD/14 §2）：玩家操控的單位進到室內時，那棟樓的屋頂淡掉，
# 否則第三人稱鏡頭會被屋頂整個擋住、根本看不到自己在做什麼。
var _roof_a := {}
func _roof_fade(delta: float) -> void:
	if _buildings.is_empty():
		return
	var watch = acting if acting != null else selected
	var px := -99999.0
	var py := -99999.0
	if watch != null and is_instance_valid(watch["node"]):
		var lp := _live_px(watch)
		px = lp.x
		py = lp.y
	for i in _buildings.size():
		var bd = _buildings[i]
		var want: float = 0.0 if bd.inside(px, py) else 1.0
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
			"units": us, "trenches": trs, "buildings": bls, "acting": act}

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
	var clamped: Vector3 = _clamp_to_map(_resolve_solids(node.global_position,
			VEHICLE_R if Unit.is_vehicle_cls(acting["cls"]) else BODY_R, acting))
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
func _tps_target():
	var vp := get_viewport().get_visible_rect().size
	var aim_pt: Vector2 = vp * 0.5
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		aim_pt = get_viewport().get_mouse_position()
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
	var moved: float = Vector2(pos.x - _act_last.x, pos.z - _act_last.z).length()
	_act_last = pos
	if moved > 0.0:
		# 地形成本（GDD/14 §3-4）：上坡 ×1.5、彈坑 ×2——同樣的距離，難走的地形就是吃更多 AP
		var tcost := 1.0
		if terrain != null:
			tcost = terrain.move_cost(float(acting["wx"]), float(acting["wy"]))
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
		ui.update_hud(turn, "enemy", enemy_cp)
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
func _ai_plan(e) -> Dictionary:
	var hp_ratio: float = float(e["hp"]) / maxf(float(e["maxhp"]), 1.0)
	var foes: Array = []
	for x in units:
		if x["alive"] and x["side"] != e["side"]:
			foes.append(x)
	# 1) 殘血撤退：往自家主堡方向退，並優先躲進掩體
	if hp_ratio < 0.3:
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
	return {"target": _nearest_foe(e), "range_k": 0.6, "dest": null, "why": "推進到射程 0.6 倍"}

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
	st = St.CMD
	cp = _turn_cp()
	for u in units:
		u["acted"] = false
		u["orders"] = 0
	ui.update_hud(turn, "player", cp)

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
			if bk["t"] != "cir" or rr * WORLD_SCALE < 0.35:
				continue
			var c: Vector2 = bk["c"]
			var t_close: float = (c - p1).dot(d1) / l2
			var perp: float = (p1 + d1 * t_close).distance_to(c)
			if perp >= rr:
				continue
			var half: float = sqrt(rr * rr - perp * perp) / seg_len
			var t_enter: float = t_close - half
			if t_enter > 0.0 and t_enter < best:
				best = t_enter
	return best

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
			if _seg_hit(a, b, w["a"], w["b"]):
				return false          # 牆從地板通到屋頂，任何姿勢都擋
	var d1: Vector2 = b - a
	var l2: float = d1.length_squared()
	if l2 < 0.0001:
		return true
	var seg_len: float = sqrt(l2)
	for bk in _blockers:
		var t: float
		if bk["t"] == "cir":
			# 求「射線進入圓」的那個交點，不是最近點（_wall_ray 那條踩過的坑）
			var c: Vector2 = bk["c"]
			var rr: float = float(bk["r"])
			var tc: float = (c - a).dot(d1) / l2
			var perp: float = (a + d1 * tc).distance_to(c)
			if perp >= rr:
				continue
			t = tc - sqrt(rr * rr - perp * perp) / seg_len
		else:
			if a.distance_squared_to(bk["m"]) > pow(float(bk["hl"]) + seg_len + float(bk["r"]), 2.0):
				continue              # 粗剔除：整條彈道都到不了這段柵欄
			t = _seg_param(a, b, bk["a"], bk["b"])
		if t <= 0.001 or t >= 1.0:
			continue                  # 貼著障礙開火（t≈0）不算被自己的掩體擋住
		if lerpf(ya, yb, t) < float(bk.get("h", 1.2)):
			return false
	# 載具：3m 級的鋼鐵，2.4m 高，任何姿勢的彈道都擋。射手與目標本身要排除。
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	for v in units:
		if v == ign_a or v == ign_b or not v["alive"] or not Unit.is_vehicle_cls(v["cls"]):
			continue
		if not is_instance_valid(v["node"]):
			continue
		var vp := Vector2(v["node"].global_position.x / WORLD_SCALE + mw * 0.5,
				v["node"].global_position.z / WORLD_SCALE + mh * 0.5)
		var rv: float = VEHICLE_R / WORLD_SCALE
		var tcv: float = (vp - a).dot(d1) / l2
		var pv: float = (a + d1 * tcv).distance_to(vp)
		if pv >= rv:
			continue
		var tv: float = tcv - sqrt(rv * rv - pv * pv) / seg_len
		if tv > 0.001 and tv < 1.0:
			return false
	return true

# 實體射線：從 a 到 b，回傳最近命中比例（0~1，1＝沒撞到）。牆一律擋；中景障礙
# 只有「比射線在該點的離地高度還高」才擋（槍口 1.3m 高本來就該越過 1.05m 的柵欄）。
# 給 Unit.solid_probe 用（貼牆抬槍）。
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
		var t2: float
		if bk["t"] == "cir":
			var c: Vector2 = bk["c"]
			var rr: float = float(bk["r"])
			var tc: float = (c - p1).dot(d1) / l2
			var perp: float = (p1 + d1 * tc).distance_to(c)
			if perp >= rr:
				continue
			t2 = tc - sqrt(rr * rr - perp * perp) / seg_len
		else:
			t2 = _seg_param(p1, p2, bk["a"], bk["b"])
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
func _shot_clear_units(shooter, target, part := "body") -> bool:
	# 載具用砲塔／車體高度，不吃姿勢（坦克不會蹲）
	var ya: float = 1.90 if Unit.is_vehicle_cls(shooter["cls"]) else 1.32
	var yb: float = 1.40 if Unit.is_vehicle_cls(target["cls"]) else 1.15
	if not Unit.is_vehicle_cls(shooter["cls"]) and is_instance_valid(shooter["node"]):
		ya = shooter["node"].muzzle_height()
	if not Unit.is_vehicle_cls(target["cls"]) and is_instance_valid(target["node"]):
		yb = target["node"].eye_height() if part == "head" else target["node"].torso_height()
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

# 完整實體解算＝建築牆 ＋ 中景物件／樹（Props.blockers）＋ 載具本身。
# ⚠ 2026-07-26 只做了建築牆，結果護欄、拒馬、電線桿、樹、坦克全都能直接穿過去，
#   在第三人稱裡看起來就是「這些東西是畫上去的」。障礙的真相要跟畫出來的一致。
# ignore＝要略過的單位（算自己時不能被自己推）。
func _resolve_solids(pos: Vector3, radius := 0.42, ignore = null) -> Vector3:
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	var p := Vector2(pos.x / WORLD_SCALE + mw * 0.5, pos.z / WORLD_SCALE + mh * 0.5)
	var r_px: float = radius / WORLD_SCALE
	if not _buildings.is_empty():
		p = _push_walls_px(p, r_px)
	for bk in _blockers:
		var need: float = r_px + float(bk["r"])
		var closest: Vector2
		if bk["t"] == "cir":
			closest = bk["c"]
		else:
			# 粗剔除：離線段中點超過（半長＋需要距離）就不可能碰到
			if p.distance_squared_to(bk["m"]) > pow(float(bk["hl"]) + need, 2.0):
				continue
			closest = Geometry2D.get_closest_point_to_segment(p, bk["a"], bk["b"])
		var away: Vector2 = p - closest
		var d: float = away.length()
		if d < need:
			p = closest + (away / d if d > 0.0001 else Vector2.RIGHT) * need
	# 載具＝3m 級的鋼鐵，人不可能從中間穿過去（被撞的一方是人，坦克不讓路）
	for v in units:
		if v == ignore or not Unit.is_vehicle_cls(v["cls"]) or not is_instance_valid(v["node"]):
			continue
		var vp := Vector2(v["node"].global_position.x / WORLD_SCALE + mw * 0.5,
				v["node"].global_position.z / WORLD_SCALE + mh * 0.5)
		var need_v: float = r_px + VEHICLE_R / WORLD_SCALE
		var away_v: Vector2 = p - vp
		var dv: float = away_v.length()
		if dv < need_v:
			p = vp + (away_v / dv if dv > 0.0001 else Vector2.RIGHT) * need_v
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
						var pc: Vector2 = bk2["c"] if bk2["t"] == "cir" 								else Geometry2D.get_closest_point_to_segment(cand, bk2["a"], bk2["b"])
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
		var gap: float = float(ALERT_GAP.get(u["cls"], ALERT_GAP_DEFAULT))
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
	if w and chapter > 0:
		_set_unlocked(min(chapter + 1, GameData.story.size()))
	var rank := "A" if w else ""
	Audio.sting("victory" if w else "defeat")
	ui.hide_charcard()
	ui.show_end(w, why, rank, ch.get("debrief", ""), _open_menu)

func _teardown_world() -> void:
	for u in units:
		if is_instance_valid(u["node"]):
			u["node"].queue_free()
	units = []
	selected = null
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
	terrain.build(map_data, WORLD_SCALE)
	_apply_sky(str(map_data.get("sky", "day")))
	_build_water()
	Unit.ground_sampler = func(p: Vector3) -> float: return terrain.height_at_world(p)
	# 槍口不可以插進固體（使用者 2026-07-26 第二次指正）：把「實體射線」交給 Unit，
	# 它在瞄準時自己判斷要不要抬槍。見 Unit.solid_probe。
	Unit.solid_probe = func(a: Vector3, b: Vector3) -> float: return _solid_ray(a, b)
	# 鏡頭碰撞：把「牆」與「地面」的查詢注入相機（真相在這邊，相機只負責用）
	cam.wall_probe = func(a: Vector3, b: Vector3) -> float: return _wall_ray(a, b)
	cam.ground_probe = func(p: Vector3) -> float: return terrain.height_at_world(p)
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
	_tree_feet = []
	var solids = map_data.get("solids", [])
	if solids is Array:
		var i := 0
		for sdef in solids:
			if i >= 6:
				break
			if _in_any_deploy(sdef):
				continue
			# 蓋在水裡的房子跳過（QA 反驗證：海峽圖一棟民房泡在深水正中央）。
			# 房子不會蓋在海裡——佈局資料是舊陸戰版沿用的，場景層要自己守。
			var srect := Rect2(float(sdef.get("x", 0)), float(sdef.get("y", 0)),
					float(sdef.get("w", 60)), float(sdef.get("h", 60)))
			var wet := false
			for wkey2 in ["waters", "deepwaters", "shallows"]:
				for wr2 in map_data.get(wkey2, []):
					if srect.intersects(Rect2(float(wr2.get("x", 0)), float(wr2.get("y", 0)),
							float(wr2.get("w", 60)), float(wr2.get("h", 60)))):
						wet = true
						break
				if wet:
					break
			if wet:
				continue
			var bd = BUILDING.new()
			world.add_child(bd)
			var cx: float = float(sdef.get("x", 0)) + float(sdef.get("w", 60)) * 0.5
			var cy: float = float(sdef.get("y", 0)) + float(sdef.get("h", 60)) * 0.5
			var gy := 0.0
			if terrain != null:
				gy = terrain.height_at(cx, cy)
			bd.build(sdef, WORLD_SCALE, map_data.get("w", 960), map_data.get("h", 600),
					gy, 2 if i % 2 == 0 else 1)
			_buildings.append(bd)
			# 室內家具進掩體表：進建築的戰術價值不能只有「牆擋子彈」，
			# 屋裡要有東西可以蹲（木箱半身高＝硬掩體，桌子只算部分遮蔽）。
			for fu in bd.furniture:
				var fp: Vector2 = bd._local_to_px(Vector2(float(fu["lx"]), float(fu["lz"])))
				_covers.append({"wx": fp.x, "wy": fp.y,
						"r": float(fu["r"]) / WORLD_SCALE, "val": float(fu["val"]),
						"type": "furniture"})
			# 掩體：建築本體仍登記一個圓（貼著外牆＝硬掩體），視線改吃牆線段
			_covers.append({"wx": cx, "wy": cy,
					"r": maxf(float(sdef.get("w", 60)), float(sdef.get("h", 60))) * 0.85 + 30.0,
					"val": 0.75, "type": "building"})
			i += 1

	# 野戰工事（GDD/14 §7）：沙包牆與壕溝護壁，幾何合併成單一網格
	var fort = FORTIFY.new()
	world.add_child(fort)
	fort.begin(map_data.get("w", 960), map_data.get("h", 600), WORLD_SCALE, terrain)
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
	props.build(map_data, WORLD_SCALE, terrain)
	# ⚠ 2026-07-26：這裡先前只吃 props.blockers，沙包牆（Fortify 產的）從來沒進碰撞表，
	#   所以上一批宣稱「所有物體都是實體」時，沙包其實還是可以直接走過去（使用者實測抓到）。
	#   工事的障礙一定要一起併進來。
	_blockers = props.blockers + fort.blockers
	# 植被：樹叢散佈（草叢掩蔽＋破除空曠感），樹幹本身也是實體
	_scatter_trees(mw, mh)
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
	var zpm := PlaneMesh.new()
	zpm.size = Vector2(z.get("w", 300) * WORLD_SCALE, z.get("h", 200) * WORLD_SCALE)
	zone_mesh.mesh = zpm
	var zmat := StandardMaterial3D.new()
	zmat.albedo_color = Color(0.42, 0.78, 1.0, 0.20)
	zmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	zmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	zone_mesh.material_override = zmat
	zone_mesh.position = _to3d(z.get("x", 0) + z.get("w", 300) * 0.5, z.get("y", 0) + z.get("h", 200) * 0.5) + Vector3(0, 0.05, 0)
	world.add_child(zone_mesh)
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

func _make_sandbag(pos: Vector3, w_px: float, h_px: float) -> void:
	var holder := Node3D.new()
	world.add_child(holder)
	holder.position = pos
	var long_x: bool = w_px >= h_px
	var count := 5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.62, 0.57, 0.42)
	mat.roughness = 0.95
	for row in 2:
		for i in count:
			var bag := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(0.62, 0.28, 0.42)
			bag.mesh = bm
			bag.material_override = mat
			var off: float = (float(i) - (count - 1) * 0.5) * 0.60 + (0.3 if row == 1 else 0.0)
			bag.position = Vector3(off if long_x else 0.0, 0.16 + row * 0.27, 0.0 if long_x else off)
			if not long_x:
				bag.rotation.y = PI / 2.0
			bag.rotation.y += randf_range(-0.08, 0.08)
			holder.add_child(bag)

# 巨石散佈（沙漠/海岸）：低多邊形球體壓扁＋隨機傾斜，半埋進地（鐵律 0：有重量會下沉）。
# 沙漠沒有樹，中景高度全靠巨石；同時登記碰撞與掩體（大石＝半身硬掩體）。
func _scatter_rocks(gwp: float, ghp: float) -> void:
	var rmul: float = float(terrain.biome.get("rock_mult", 1.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var want: int = int(gwp * ghp / 52000.0 * rmul * 5.5)   # 10.0 密到像一地鵝卵蛋（QA 實拍）
	var sm := SphereMesh.new()
	sm.radial_segments = 7
	sm.rings = 4
	sm.radius = 1.0
	sm.height = 1.5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = terrain.biome.get("rock", Color(0.5, 0.46, 0.36))
	mat.roughness = 0.97
	sm.material = mat
	var xfs: Array = []
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
		var too_close := false
		for ex in xfs:
			if Vector2((ex as Transform3D).origin.x, (ex as Transform3D).origin.z).distance_to(
					Vector2((px - gwp * 0.5) * WORLD_SCALE, (py - ghp * 0.5) * WORLD_SCALE)) < 3.5:
				too_close = true
				break
		if too_close:
			continue
		var sc: float = rng.randf_range(0.30, 1.9)
		var ty: float = terrain.height_at(px, py)
		var b := (Basis(Vector3.UP, rng.randf() * TAU)
				* Basis(Vector3(1, 0, 0), rng.randf_range(-0.25, 0.25))).scaled(
				Vector3(sc * rng.randf_range(0.8, 1.4), sc * rng.randf_range(0.5, 0.8), sc))
		# 半埋：底部沉進地面 1/3，石頭才是「長在地裡」不是「擺在地上」
		xfs.append(Transform3D(b, Vector3((px - gwp * 0.5) * WORLD_SCALE,
				ty + sc * 0.28, (py - ghp * 0.5) * WORLD_SCALE)))
		if sc > 0.7:
			_blockers.append({"t": "cir", "c": tp, "r": sc * 0.9 / WORLD_SCALE, "h": sc * 1.0})
			_covers.append({"wx": px, "wy": py, "r": sc * 0.95 / WORLD_SCALE,
					"val": 0.5, "type": "sandbag"})
		placed += 1
	if xfs.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = sm
	mm.instance_count = xfs.size()
	for k in xfs.size():
		mm.set_instance_transform(k, xfs[k])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Rocks"
	mmi.multimesh = mm
	world.add_child(mmi)

# 水面（海灘/海峽/港口）：一片起伏的半透明水色平面蓋在水域上。
# 深水對步兵不可通行（鐵律 0：人不會走進兩公尺深的海裡打仗），登記成線段圍欄。
func _build_water() -> void:
	var rects: Array = []
	for wkey in ["waters", "deepwaters", "shallows"]:
		for wr in map_data.get(wkey, []):
			rects.append([Rect2(float(wr.get("x", 0)), float(wr.get("y", 0)),
					float(wr.get("w", 60)), float(wr.get("h", 60))), wkey])
	if rects.is_empty():
		return
	for pair in rects:
		var r: Rect2 = pair[0]
		var pm := PlaneMesh.new()
		pm.size = Vector2(r.size.x * WORLD_SCALE, r.size.y * WORLD_SCALE)
		pm.subdivide_width = 24
		pm.subdivide_depth = 24
		var mi := MeshInstance3D.new()
		mi.mesh = pm
		var wmat := ShaderMaterial.new()
		var wsh := Shader.new()
		wsh.code = WATER_SHADER
		wmat.shader = wsh
		mi.material_override = wmat
		var c: Vector2 = r.get_center()
		mi.position = Vector3((c.x - map_data.get("w", 960) * 0.5) * WORLD_SCALE, -0.30,
				(c.y - map_data.get("h", 600) * 0.5) * WORLD_SCALE)
		world.add_child(mi)
		# 深水圍欄：四邊線段障礙（高度 3m＝人與彈道都擋不住的別想，這是水不是牆，
		# 但步兵確實過不去；日後做船再改成「載具可通行」）
		if pair[1] == "deepwaters":
			var corners := [r.position, Vector2(r.end.x, r.position.y), r.end,
					Vector2(r.position.x, r.end.y)]
			for i in 4:
				var a2: Vector2 = corners[i]
				var b2: Vector2 = corners[(i + 1) % 4]
				_blockers.append({"t": "seg", "a": a2, "b": b2, "r": 0.3 / WORLD_SCALE,
						"h": 0.0, "m": (a2 + b2) * 0.5, "hl": a2.distance_to(b2) * 0.5})

# 水面 shader：兩層正弦波起伏＋菲涅耳反光。刻意簡單——手機 WebGL2 也要跑得動。
const WATER_SHADER := """
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back;

void vertex() {
	float t = TIME * 0.9;
	VERTEX.y += sin(VERTEX.x * 0.7 + t) * 0.06 + sin(VERTEX.z * 1.1 + t * 1.3) * 0.05;
}

void fragment() {
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	// 邊緣淡出：矩形水塊的硬直角像貼上去的色紙（QA 反驗證指出）。
	// ⚠ 不可用 floor() 的方塊雜訊做參差——會變成棋盤格（第一版實拍）。
	//   改用連續的正弦擾動，邊界才是自然的曲線。
	float edge = min(min(UV.x, 1.0 - UV.x), min(UV.y, 1.0 - UV.y));
	float wob = 0.012 * (sin(UV.x * 47.0) + sin(UV.y * 39.0 + 1.7));
	// 深度感：離岸越遠越深越暗（淺水帶偏綠、深水偏靛）
	float deep = smoothstep(0.0, 0.22, edge);
	vec3 shallow_c = vec3(0.30, 0.50, 0.48);
	vec3 deep_c = vec3(0.05, 0.15, 0.26);
	ALBEDO = mix(mix(shallow_c, deep_c, deep), vec3(0.62, 0.74, 0.78), fres * 0.7);
	ALPHA = 0.88 * smoothstep(0.0, 0.05 + wob, edge);
	ROUGHNESS = 0.06;
	SPECULAR = 0.7;
}
"""

func _scatter_trees(mw: float, mh: float) -> void:
	var tm := ["res://assets/models/tree-single.glb", "res://assets/models/pinetrees.glb"]
	var avail: Array[String] = []
	for t in tm:
		if ResourceLoader.exists(t):
			avail.append(t)
	if avail.is_empty():
		return
	var gwp: float = map_data.get("w", 960)
	var ghp: float = map_data.get("h", 600)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260724
	# ⚠ 一棵樹一個節點＝一次 draw call：26 棵就已經是 26 次，要鋪成森林只能用 MultiMesh。
	#   先量一棵的體型（沿用 _fit_prop 的邏輯），再把同一份 mesh 實例化幾百次。
	var xf_by_mesh := {}          # mesh → [Transform3D...]（一個 glb 可能有好幾個 surface 節點）
	var proto := {}
	for path in avail:
		var inst := (load(path) as PackedScene).instantiate()
		add_child(inst)
		var h: float = 4.2
		var dy: float = _fit_prop(inst, h)
		var parts: Array = []
		for mi in inst.find_children("*", "MeshInstance3D", true, false):
			var m3 := mi as MeshInstance3D
			if m3.mesh == null:
				continue
			parts.append([m3.mesh, inst.global_transform.affine_inverse() * m3.global_transform])
		proto[path] = {"parts": parts, "dy": dy, "h": h}
		remove_child(inst)
		inst.queue_free()
	# 疏密節奏（GDD/14 §0a）：邊緣成林、中央疏開（戰場中央要留得下打法），
	# 再疊一層低頻雜訊做出林塊與空地，不要平均散佈那種假森林。
	# 範圍要含「戰場外的地形」：Terrain 在戰場外還鋪了 90m（否則遠鏡頭看到地圖是塊浮空積木），
	# 那片先前完全光禿——實拍全景時戰場只佔畫面中央一小塊，四周是空綠地。
	var out_px: float = 88.0 / WORLD_SCALE
	# 樹量吃生態倍率（森林 2.2×、沙漠 0×——沙漠沒有樹，空缺由巨石補）
	var tmul: float = float(terrain.biome.get("tree_mult", 1.0)) if terrain != null else 1.0
	if tmul < 0.01:
		_scatter_rocks(gwp, ghp)
		return
	var want: int = int(clampf((gwp + out_px * 2.0) * (ghp + out_px * 2.0) / 26000.0 * tmul,
			40.0, 1400.0))
	var placed := 0
	var guard := 0
	while placed < want and guard < want * 30:
		guard += 1
		var px: float = rng.randf_range(-out_px, gwp + out_px)
		var py: float = rng.randf_range(-out_px, ghp + out_px)
		var outside: bool = px < 0.0 or py < 0.0 or px > gwp or py > ghp
		# 戰場內：邊緣多、中央少（中央要留得下打法）；戰場外：成片森林把空曠遮掉。
		# ⚠ 林塊要用 hash 值雜訊，不可用正弦疊加——那會排成規則格狀，遠鏡頭一眼看破像果園
		#   （地形雜訊那次的同一個教訓）。
		var clump: float = terrain._vnoise(px * 0.0035, py * 0.0035) if terrain != null else 0.5
		clump = clampf((clump - 0.34) * 2.7, 0.0, 1.0)      # 拉開對比：有密林也要有空地
		var chance: float
		if outside:
			chance = 0.12 + 0.88 * clump
		else:
			var nx: float = (px / gwp - 0.5) * 2.0
			var ny: float = (py / ghp - 0.5) * 2.0
			var edge: float = clampf((sqrt(nx * nx + ny * ny) - 0.30) / 0.85, 0.0, 1.0)
			chance = edge * (0.15 + 0.85 * clump)
		if rng.randf() > chance:
			continue
		var tp := Vector2(px, py)
		var blocked := false
		if outside:
			var path3: String = avail[rng.randi() % avail.size()]
			var pr3: Dictionary = proto[path3]
			var sc3: float = rng.randf_range(0.65, 1.9)
			var ty3: float = terrain.height_at(px, py) if terrain != null else 0.0
			var lean3 := Basis(Vector3(1, 0, 0), rng.randf_range(-0.06, 0.06)) 					* Basis(Vector3(0, 0, 1), rng.randf_range(-0.06, 0.06))
			var base3 := Transform3D(
					(Basis(Vector3.UP, rng.randf() * TAU) * lean3).scaled(Vector3.ONE * sc3),
					Vector3((px - gwp * 0.5) * WORLD_SCALE,
							ty3 + float(pr3["dy"]) * sc3 - 0.12 * sc3,
							(py - ghp * 0.5) * WORLD_SCALE))
			for part3 in pr3["parts"]:
				var k3 = part3[0]
				if not xf_by_mesh.has(k3):
					xf_by_mesh[k3] = []
				xf_by_mesh[k3].append(base3 * (part3[1] as Transform3D))
			placed += 1
			continue
		for bd2 in _buildings:
			if bd2.rect.grow(5.0 / WORLD_SCALE).has_point(tp):
				blocked = true
				break
		if not blocked and terrain != null and (terrain.in_trench(px, py)
				or terrain.in_water(px, py)):
			blocked = true      # 壕溝與水裡不長樹（實拍海灘的樹站在海面上）
		if not blocked:
			for bk in _blockers:
				var cq: Vector2 = bk["c"] if bk["t"] == "cir" 						else Geometry2D.get_closest_point_to_segment(tp, bk["a"], bk["b"])
				if tp.distance_to(cq) < 2.2 / WORLD_SCALE:
					blocked = true
					break
		if blocked:
			continue
		var path2: String = avail[rng.randi() % avail.size()]
		var pr: Dictionary = proto[path2]
		var sc: float = rng.randf_range(0.62, 1.6)
		var ty: float = terrain.height_at(px, py) if terrain != null else 0.0
		# 樹要「長進地裡」而不是站在地面上：底部略微下沉，再加隨機傾斜。
		# 全部筆直等高的樹一眼看破是複製貼上（使用者 2026-07-26 指正場景不真實）。
		var lean := Basis(Vector3(1, 0, 0), rng.randf_range(-0.05, 0.05)) 				* Basis(Vector3(0, 0, 1), rng.randf_range(-0.05, 0.05))
		var base := Transform3D(
				(Basis(Vector3.UP, rng.randf() * TAU) * lean).scaled(Vector3.ONE * sc),
				Vector3((px - gwp * 0.5) * WORLD_SCALE,
						ty + float(pr["dy"]) * sc - 0.12 * sc, (py - ghp * 0.5) * WORLD_SCALE))
		for part in pr["parts"]:
			var key = part[0]
			if not xf_by_mesh.has(key):
				xf_by_mesh[key] = []
			xf_by_mesh[key].append(base * (part[1] as Transform3D))
		# 樹叢比單株粗；同時登記掩體（樹叢＝隱蔽）
		var clus: bool = path2.ends_with("pinetrees.glb")
		# ⚠ 只有戰場內的樹登記掩體與碰撞：背景森林幾百棵，全登記的話
		#   _resolve_solids 每幀要多跑幾百次，碰撞成本會被背景吃掉。
		if not outside:
			_covers.append({"wx": px, "wy": py, "r": 34.0 * sc, "val": 0.30, "type": "bush"})
			_tree_feet.append(tp)
			# h：樹幹一路擋到上面（不管站著蹲著趴著，彈道都被擋）
			_blockers.append({"t": "cir", "c": tp,
					"r": (0.85 if clus else 0.40) * sc / WORLD_SCALE, "h": 4.2 * sc})
		placed += 1
	if terrain != null and float(terrain.biome.get("rock_mult", 0.0)) > 0.01:
		_scatter_rocks(gwp, ghp)
	for mesh_key in xf_by_mesh.keys():
		var list: Array = xf_by_mesh[mesh_key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh_key
		mm.instance_count = list.size()
		for k in list.size():
			mm.set_instance_transform(k, list[k])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Trees"
		mmi.multimesh = mm
		world.add_child(mmi)


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
