# Main.gd — 遊戲總機（GDD/13 全量搬遷）：狀態機串起主選單→章節→簡報→立繪對話→部署→
# 回合戰鬥(CP/移動/開槍/簡易迷霧)→勝敗→戰報。戰場身體 Quaternius，角色 identity 走立繪。
extends Node3D

enum St { MENU, STORY, BRIEF, DIALOGUE, DEPLOY, CMD, ENEMY, END }

const CLASS_MODEL := {
	"rifleman": "res://assets/models/chars/rifleman.glb", "sniper": "res://assets/models/chars/sniper.glb",
	"mg": "res://assets/models/chars/mg.glb", "assault": "res://assets/models/chars/assault.glb",
	"at": "res://assets/models/chars/at.glb", "mortar": "res://assets/models/chars/mortar.glb",
	"engineer": "res://assets/models/chars/engineer.glb", "specops": "res://assets/models/chars/specops.glb",
	"sam": "res://assets/models/chars/sam.glb",
}
const HERO_MODEL := {   # 立繪轉 3D 本人模型（僅我方英雄用；其餘暫用通用兵，待生成補齊）
	"sniper": "res://assets/models/chars/sniper-tripo3.glb",
	"rifleman": "res://assets/models/chars/rifleman-tripo.glb",
	"mg": "res://assets/models/chars/mg-tripo.glb",
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
var cp_max := 5
var budget_left := 0
var _tracers: Array = []
var _enemy_queue: Array = []
var _enemy_t := 0.0

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
	ui.back_menu.connect(_open_menu)
	_open_menu()
	if "selftest" in OS.get_cmdline_user_args():
		_selftest()

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
	print("[selftest] DONE units=", units.size())
	get_tree().quit(0)

func _build_static() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, 38, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.78, 0.82, 0.88)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.85, 0.88, 0.95)
	e.ambient_light_energy = 0.5
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
	_deployed.append(u)
	if _pending_named:
		_placed_named[cls] = true
		Audio.voice(cls, "sel")
	budget_left -= cost
	ui.update_budget(budget_left, "已部署 %s" % cb.get("zh", cls))
	if _pending_named:
		_pending_cls = ""    # 具名放完清除（每場一次）

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
	cp = cp_max
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
	var cb: Dictionary = GameData.class_base.get(cls, {})
	var chr: Dictionary = GameData.characters.get(cls, {}) if named else {}
	var hp: int = cb.get("hp", 100)
	var u := {
		"cls": cls, "side": side_i, "node": node, "wx": wx, "wy": wy,
		"hp": hp, "maxhp": hp, "alive": true,
		"weapon": GameData.weapon_of(nation[side_i], cls),
		"named": named, "char_name": chr.get("name", ""),
		"acted": false,
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
			if Vector2(u["wx"] - p["wx"], u["wy"] - p["wy"]).length() <= SIGHT:
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

func _click(sp: Vector2) -> void:
	var best = null
	var best_d := 44.0
	for u in units:
		if not u["alive"] or not u["node"].visible:
			continue
		var wsp := cam.unproject_position(u["node"].global_position + Vector3(0, 1.0, 0))
		var d := wsp.distance_to(sp)
		if d < best_d:
			best_d = d
			best = u
	if best != null:
		if best["side"] == player_side:
			selected = best
			cam.set_follow(best["node"])
			var chr: Dictionary = GameData.characters.get(best["cls"], {})
			ui.show_charcard(best["cls"], ("★" + best["char_name"]) if best["named"] else GameData.class_base.get(best["cls"], {}).get("zh", best["cls"]),
					chr.get("trait", {}).get("desc", ""), int(best["hp"]), int(best["maxhp"]))
		elif selected != null and cp > 0 and not selected["acted"]:
			_fire(selected, best)
		return
	# 點地移動
	if selected == null or cp <= 0 or selected["acted"]:
		return
	var from := cam.project_ray_origin(sp)
	var dir := cam.project_ray_normal(sp)
	if abs(dir.y) < 0.0001:
		return
	var t := -from.y / dir.y
	if t <= 0:
		return
	var hit := from + dir * t
	selected["node"].move_to(hit)
	# 反算回遊戲座標
	var mw: float = map_data.get("w", 960)
	var mh: float = map_data.get("h", 600)
	selected["wx"] = hit.x / WORLD_SCALE + mw * 0.5
	selected["wy"] = hit.z / WORLD_SCALE + mh * 0.5
	_refresh_visibility()

func _fire(shooter, target) -> void:
	var dist_px := Vector2(target["wx"] - shooter["wx"], target["wy"] - shooter["wy"]).length()
	shooter["node"].shoot_at(target["node"])
	shooter["acted"] = true
	cp = max(0, cp - 1)
	ui.update_hud(turn, "player" if st == St.CMD else "enemy", cp)
	await get_tree().create_timer(0.32).timeout
	if GameData.hit_chance(_wrap(shooter), _wrap(target), dist_px) > randf():
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
	for u in units:
		u["acted"] = false
	_enemy_queue = []
	for u in units:
		if u["alive"] and u["side"] != player_side:
			_enemy_queue.append(u)
	_enemy_t = 0.6
	ui.update_hud(turn, "enemy", 0)

func _process(delta: float) -> void:
	for tr in _tracers.duplicate():
		tr["ttl"] -= delta
		if tr["ttl"] <= 0:
			tr["m"].queue_free()
			tr["l"].queue_free()
			_tracers.erase(tr)
	if st == St.ENEMY:
		_enemy_t -= delta
		if _enemy_t <= 0:
			_enemy_step()
			_enemy_t = 1.1

func _enemy_step() -> void:
	if _enemy_queue.is_empty():
		# 敵回合結束
		turn += 1
		if turn > 30:
			_win(1 - player_side, "防守方撐過 30 回合")
			return
		st = St.CMD
		cp = cp_max
		for u in units:
			u["acted"] = false
		ui.update_hud(turn, "player", cp)
		return
	var e = _enemy_queue.pop_front()
	if not e["alive"]:
		return
	# 找最近我方 → 可見則跟拍 + 開槍，否則移動靠近
	var tgt = null
	var td := 1e9
	for u in units:
		if u["side"] == player_side and u["alive"]:
			var d := Vector2(u["wx"] - e["wx"], u["wy"] - e["wy"]).length()
			if d < td:
				td = d
				tgt = u
	if tgt == null:
		return
	cam.set_follow(e["node"])
	if td <= e["weapon"].get("range", 200):
		_fire(e, tgt)
	else:
		var dirp := Vector2(tgt["wx"] - e["wx"], tgt["wy"] - e["wy"]).normalized() * 120.0
		e["wx"] += dirp.x
		e["wy"] += dirp.y
		e["node"].move_to(_to3d(e["wx"], e["wy"]))
		_refresh_visibility()

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
	var mw: float = map_data.get("w", 960) * WORLD_SCALE
	var mh: float = map_data.get("h", 600) * WORLD_SCALE
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(mw * 1.4, mh * 1.4)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.42, 0.52, 0.30)
	ground.material_override = gm
	world.add_child(ground)
	# 建築（依 map solids 略放幾棟）
	var solids = map_data.get("solids", [])
	var models := ["res://assets/models/house-b.glb", "res://assets/models/townhouse-b.glb", "res://assets/models/twostory.glb"]
	if solids is Array:
		var i := 0
		for s in solids:
			if i >= 6:
				break
			var packed: PackedScene = load(models[i % models.size()])
			if packed:
				var b := packed.instantiate()
				world.add_child(b)
				b.position = _to3d(s.get("x", 0) + s.get("w", 40) * 0.5, s.get("y", 0) + s.get("h", 40) * 0.5)
				b.scale = Vector3.ONE * 2.5
			i += 1
	# 我方部署藍框（半透明地面標記）
	var z := _my_zone()
	var zone_mesh := MeshInstance3D.new()
	var zpm := PlaneMesh.new()
	zpm.size = Vector2(z.get("w", 300) * WORLD_SCALE, z.get("h", 200) * WORLD_SCALE)
	zone_mesh.mesh = zpm
	var zmat := StandardMaterial3D.new()
	zmat.albedo_color = Color(0.42, 0.78, 1.0, 0.22)
	zmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	zmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	zone_mesh.material_override = zmat
	zone_mesh.position = _to3d(z.get("x", 0) + z.get("w", 300) * 0.5, z.get("y", 0) + z.get("h", 200) * 0.5) + Vector3(0, 0.05, 0)
	world.add_child(zone_mesh)
	# 相機框住我方部署區
	cam.set_follow(null)
	cam.focus = _to3d(z.get("x", 0) + z.get("w", 300) * 0.5, z.get("y", 0) + z.get("h", 200) * 0.5)
	cam.dist = 18.0
