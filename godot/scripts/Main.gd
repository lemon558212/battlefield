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
var budget_left := 0
var _tracers: Array = []
var _enemy_queue: Array = []
var _enemy_t := 0.0
var _zone_mesh: MeshInstance3D = null
# 掩體登記表（GDD/13 Phase2）：每筆＝{wx,wy,r,val,type}，座標為遊戲 px。
# val＝遮蔽強度 0~1；sandbag 硬掩體、building 全掩體、bush 只給隱蔽(降敵視野)不擋彈。
var _covers: Array = []

const GROUND_SHADER := """
shader_type spatial;
uniform vec3 grass_a = vec3(0.34, 0.45, 0.24);
uniform vec3 grass_b = vec3(0.47, 0.57, 0.31);
uniform vec3 dirt    = vec3(0.44, 0.39, 0.28);
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
	var before: Vector3 = pu["node"].global_position
	var dest := _to3d(pu["wx"] + 150.0, pu["wy"] + 100.0)
	_send_click(cam.unproject_position(dest + Vector3(0, 0.02, 0)))
	await get_tree().create_timer(1.5).timeout
	var moved: float = before.distance_to(pu["node"].global_position)
	print("[e2e]   位移=%.2fm %s" % [moved, "OK" if moved > 0.5 else "FAIL(人沒動)"])
	await _snap("res://e2e_battle.png")
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

func _snap(p: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(p)
	print("[selftest] saved ", p)

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
	var p_before: Vector3 = pu["node"].global_position
	var ground := _to3d(pu["wx"] + 150.0, pu["wy"] + 100.0)
	var sp_ground: Vector2 = cam.unproject_position(ground + Vector3(0, 0.02, 0))
	_send_click(sp_ground)
	await get_tree().create_timer(1.2).timeout
	var moved: float = p_before.distance_to(pu["node"].global_position)
	print("[movechk] 點地面後位移=%.2fm %s" % [moved, "OK" if moved > 0.5 else "FAIL(人沒動)"])
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
	var far := _to3d(pu["wx"] + 900.0, pu["wy"])
	var q_before: Vector3 = pu["node"].global_position
	_send_click(cam.unproject_position(far + Vector3(0, 0.02, 0)))
	await get_tree().create_timer(reach_m / 3.0 + 1.5).timeout
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
			var bl := {}
			for c in _covers:
				if c["type"] == "building":
					bl = c
					break
			if bl.is_empty():
				print("[alertchk] SKIP 場上沒有建築掩體")
			else:
				var keep := _covers
				_covers = [bl]
				var bp := Vector2(bl["wx"], bl["wy"])
				var thru: bool = not _los_clear(bp - Vector2(bl["r"] + 60.0, 0), bp + Vector2(bl["r"] + 60.0, 0))
				var side_ok: bool = _los_clear(bp + Vector2(-100.0, bl["r"] + 60.0), bp + Vector2(100.0, bl["r"] + 60.0))
				_covers = keep
				print("[alertchk] 建築擋視線 穿越=%s 繞過=%s %s" % [thru, side_ok,
						"OK" if (thru and side_ok) else "FAIL"])
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
		# 效能：每單位每幀都在做重定向＋雙手 IK＋手指，換骨架後必須實測
		var t0 := Time.get_ticks_usec()
		for i in 60:
			await get_tree().process_frame
		var ms: float = (Time.get_ticks_usec() - t0) / 60000.0
		print("[perf] units=%d 平均幀時=%.1fms (%.0f FPS) %s" % [
			units.size(), ms, 1000.0 / maxf(ms, 0.001), "OK" if ms < 22.0 else "慢"])
	print("[selftest] DONE units=", units.size())
	get_tree().quit(0)

func _build_static() -> void:
	# 太陽：暖色、柔邊陰影、角度更斜（拉長影子＝立體感）
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, 128, 0)
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	sun.shadow_blur = 1.4
	sun.directional_shadow_max_distance = 80.0
	add_child(sun)
	# 補光：從反方向打冷色弱光，避免暗面全黑（治「黑色邊」的觀感）
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-28, -50, 0)
	fill.light_color = Color(0.72, 0.80, 0.95)
	fill.light_energy = 0.35
	fill.shadow_enabled = false
	add_child(fill)

	var e := Environment.new()
	# 程序天空（漸層＋太陽）取代死板純色背景
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.38, 0.55, 0.82)
	sky_mat.sky_horizon_color = Color(0.78, 0.84, 0.88)
	sky_mat.ground_bottom_color = Color(0.40, 0.44, 0.38)
	sky_mat.ground_horizon_color = Color(0.72, 0.78, 0.80)
	sky_mat.sun_angle_max = 12.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.9
	# 環境光遮蔽：物件接地處自然變暗，最有效的「不假」來源
	e.ssao_enabled = true
	e.ssao_radius = 1.6
	e.ssao_intensity = 2.2
	e.ssao_power = 1.6
	# 遠景霧氣：拉出空間深度
	e.fog_enabled = true
	e.fog_light_color = Color(0.70, 0.77, 0.84)
	e.fog_density = 0.0035
	e.fog_sky_affect = 0.08
	# 色調映射＋微光暈：去除死白、增加層次
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.tonemap_exposure = 0.98
	e.tonemap_white = 6.0
	e.glow_enabled = true
	e.glow_intensity = 0.12
	e.glow_bloom = 0.08
	e.adjustment_enabled = true
	e.adjustment_saturation = 1.12
	e.adjustment_contrast = 1.06
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
	return true

# 結束行動：單位進入警戒狀態（GDD/01 §2 最後一條）
func _end_action() -> void:
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

func _to3d(wx: float, wy: float) -> Vector3:
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	return Vector3((wx - mw * 0.5) * WORLD_SCALE, 0, (wy - mh * 0.5) * WORLD_SCALE)

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
			for c in _covers:                       # 躲樹叢＝隱蔽，被發現距離砍半
				if c["type"] == "bush" and Vector2(c["wx"] - u["wx"], c["wy"] - u["wy"]).length() <= c["r"]:
					sight = SIGHT * 0.5
					break
			if Vector2(u["wx"] - p["wx"], u["wy"] - p["wy"]).length() <= sight:
				vis = true
				break
		if u["alive"]:                    # 陣亡者交給 die() 淡出，別強制隱藏
			u["node"].visible = vis

# ---------- 輸入 ----------
func _unhandled_input(event: InputEvent) -> void:
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
			_fire(acting, best)          # 每次行動只能開火一次（GDD/01 §2）
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
	acting["node"].move_to(hit)
	_refresh_visibility()

func _fire(shooter, target) -> void:
	var dist_px := Vector2(target["wx"] - shooter["wx"], target["wy"] - shooter["wy"]).length()
	shooter["node"].shoot_at(target["node"])
	shooter["fired"] = true      # 每次行動只能開火一次；CP 在下令時就扣過了（GDD/01 §1-2）
	ui.update_hud(turn, "player" if st == St.CMD else "enemy", cp)
	await get_tree().create_timer(0.32).timeout
	# 掩體修正（Phase2）：方向性遮蔽最多削 60% 命中
	var cov: float = cover_at(target["wx"], target["wy"], shooter["wx"], shooter["wy"])
	var hc: float = GameData.hit_chance(_wrap(shooter), _wrap(target), dist_px) * (1.0 - cov * 0.6)
	if hc > randf():
		target["hp"] -= GameData.damage(_wrap(shooter), _wrap(target))
		if target["hp"] <= 0 and target["alive"]:
			target["alive"] = false
			target["node"].die()          # 淡出傾倒後自我移除
		elif target["alive"]:
			target["node"].take_hit()     # 受擊：立繪換 hurt 表情＋紅閃
	_refresh_visibility()
	_check_end()

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
	# 先動離我方最近的：那才是真的有威脅的單位（也讓玩家的迎擊有事可做）
	_enemy_queue.sort_custom(func(a, b): return _dist_to_nearest_foe(a) < _dist_to_nearest_foe(b))
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
	_action_tick(delta)
	_intercept_tick(delta)
	if st == St.ENEMY:
		_enemy_t -= delta
		_ai_t += delta
		if _enemy_t <= 0:
			_enemy_step()
			_enemy_t = 0.25

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
		acting["ap"] = maxf(0.0, float(acting["ap"]) - moved / (PX_PER_AP * WORLD_SCALE))
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
		var tgt = _nearest_foe(acting)
		var moving: bool = acting["node"].is_moving()
		if _ai_state == "move":
			var stalled: bool = (not moving) or float(acting["ap"]) <= 0.0
			if stalled or _ai_t > 12.0:
				_ai_state = "fire"
				if tgt != null and not bool(acting.get("fired", false)):
					var d: float = Vector2(tgt["wx"] - acting["wx"], tgt["wy"] - acting["wy"]).length()
					if d <= float(acting["weapon"].get("range", 200)) and _los_clear(_live_px(acting), _live_px(tgt)):
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
		var tgt2 = _nearest_foe(e)
		if tgt2 == null:
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
		# 目標點：推進到「射程 0.7 倍」處，並受剩餘 AP 限制（GDD/09：推進到射程內再開火）
		var here: Vector3 = e["node"].global_position
		var to_t: Vector3 = tgt2["node"].global_position - here
		to_t.y = 0.0
		var want: float = float(e["weapon"].get("range", 200)) * 0.7 * WORLD_SCALE
		var step: float = maxf(to_t.length() - want, 0.0)
		var reach: float = _ap_metres(e)
		if step <= 0.05:
			_ai_state = "fire"         # 已在射程內：原地開火
			_enemy_t = 0.4
			return
		e["node"].move_to(here + to_t.normalized() * minf(step, reach))
		_enemy_t = 0.3
		return
	_end_enemy_turn()

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
	for c in _covers:
		if c["type"] != "building":
			continue
		var p := Vector2(c["wx"], c["wy"])
		var ab := b - a
		var l2: float = ab.length_squared()
		var t: float = 0.0 if l2 < 0.0001 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
		if a.lerp(b, t).distance_to(p) <= float(c["r"]):
			return false
	return true

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
			if d <= rng and d < bd and _los_clear(up, pair[1]):
				bd = d
				best = m
		if best == null:
			continue
		u["_alert_t"] = 0.0
		_intercept_fire(u, best, bd)

var _alert_shots := 0      # QA 計數：本次迎擊觸發幾次

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
	var hc: float = GameData.hit_chance(_wrap(shooter), _wrap(target), dist_px) * (1.0 - cov * 0.6)
	if hc > randf():
		var dmg: int = int(round(GameData.damage(_wrap(shooter), _wrap(target)) * ALERT_DMG_K))
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
	# 地面：用 shader 做草地色斑＋土痕，取代單一死綠平面
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(mw * 2.2, mh * 2.2)
	pm.subdivide_width = 24
	pm.subdivide_depth = 24
	ground.mesh = pm
	var sh := Shader.new()
	sh.code = GROUND_SHADER
	var sm := ShaderMaterial.new()
	sm.shader = sh
	ground.material_override = sm
	world.add_child(ground)

	# 建築：依實際 AABB 自動縮放到合理樓高（治「放大2.5倍變黑色巨牆」）
	var solids = map_data.get("solids", [])
	var bmodels := ["res://assets/models/house-b.glb", "res://assets/models/townhouse-b.glb",
			"res://assets/models/twostory.glb", "res://assets/models/smallbuilding.glb"]
	if solids is Array:
		var i := 0
		for sdef in solids:
			if i >= 6:
				break
			# 建築不得生成在任一方部署區內（否則擋兵、且貼著鏡頭變成一道巨牆）
			if _in_any_deploy(sdef):
				continue
			_covers.append({"wx": sdef.get("x", 0) + sdef.get("w", 40) * 0.5,
					"wy": sdef.get("y", 0) + sdef.get("h", 40) * 0.5,
					"r": maxf(sdef.get("w", 40), sdef.get("h", 40)) * 0.85 + 30.0,
					"val": 0.75, "type": "building"})
			var mp: String = bmodels[i % bmodels.size()]
			if ResourceLoader.exists(mp):
				var b := (load(mp) as PackedScene).instantiate()
				world.add_child(b)
				var dy: float = _fit_prop(b, 5.2 if i % 2 == 0 else 3.6)   # 樓高 3.6~5.2m
				b.position = _to3d(sdef.get("x", 0) + sdef.get("w", 40) * 0.5,
						sdef.get("y", 0) + sdef.get("h", 40) * 0.5) + Vector3(0, dy, 0)
				b.rotation.y = randf() * TAU
			i += 1

	# 掩體：沙包（Phase2 掩體系統的實體，先做出來才躲得進去）
	var sandbags = map_data.get("sandbags", [])
	if sandbags is Array:
		for sb in sandbags:
			_covers.append({"wx": sb.get("x", 0) + sb.get("w", 40) * 0.5,
					"wy": sb.get("y", 0) + sb.get("h", 24) * 0.5,
					"r": 52.0, "val": 0.55, "type": "sandbag"})
			_make_sandbag(_to3d(sb.get("x", 0) + sb.get("w", 40) * 0.5, sb.get("y", 0) + sb.get("h", 24) * 0.5),
					float(sb.get("w", 80)), float(sb.get("h", 24)))

	# 植被：樹叢散佈（草叢掩蔽＋破除空曠感）
	_scatter_trees(mw, mh)

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

func _scatter_trees(mw: float, mh: float) -> void:
	var tm := ["res://assets/models/tree-single.glb", "res://assets/models/pinetrees.glb"]
	var avail: Array[String] = []
	for t in tm:
		if ResourceLoader.exists(t):
			avail.append(t)
	if avail.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260724
	for i in 26:
		var t := (load(avail[i % avail.size()]) as PackedScene).instantiate()
		world.add_child(t)
		var dy: float = _fit_prop(t, rng.randf_range(3.0, 5.5))
		# 邊緣多、中央少（不擋戰場）
		var ang := rng.randf() * TAU
		var r: float = rng.randf_range(0.55, 1.05)
		t.position = Vector3(cos(ang) * mw * r, dy, sin(ang) * mh * r)
		t.rotation.y = rng.randf() * TAU
		# 樹叢＝隱蔽（降低被發現距離），不擋子彈
		var gw: float = map_data.get("w", 960)
		var gh: float = map_data.get("h", 600)
		_covers.append({"wx": t.position.x / WORLD_SCALE + gw * 0.5,
				"wy": t.position.z / WORLD_SCALE + gh * 0.5,
				"r": 40.0, "val": 0.30, "type": "bush"})
