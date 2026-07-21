# UI.gd — 全介面層（GDD/13）：主選單/章節/簡報名冊/立繪對話/部署/HUD/戰報
# 鳴潮金色風。立繪＝角色 identity 核心（使用者強調要用上生成立繪）。
class_name GameUI
extends CanvasLayer

signal menu_story
signal menu_versus
signal chapter_chosen(n: int)
signal deploy_pick(cls: String, named: bool)
signal deploy_go
signal end_turn
signal back_menu

const GOLD := Color(0.945, 0.757, 0.353)
const CYAN := Color(0.42, 0.78, 1.0)
const INK := Color(0.043, 0.055, 0.071)
const TXT := Color(0.93, 0.95, 0.97)
const SUB := Color(0.62, 0.68, 0.75)
const CARD := Color(0.11, 0.135, 0.17)

var root: Control
var _dlg_cb: Callable
var _dlg_script: Array
var _dlg_i := 0
var _dlg_faces := {"left": "", "right": ""}
var _typing := false
var _type_full := ""
var _type_k := 0
var _type_accum := 0.0

func _ready() -> void:
	layer = 10
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

func _clear() -> void:
	for c in root.get_children():
		c.queue_free()

func _panel(col := Color(0, 0, 0, 0.82)) -> ColorRect:
	var cr := ColorRect.new()
	cr.color = col
	return cr

func _label(txt: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l

func _btn(txt: String, size := 20) -> Button:
	var b := Button.new()
	b.text = txt
	b.add_theme_font_size_override("font_size", size)
	b.custom_minimum_size = Vector2(260, 52)
	return b

# ---------- 主選單 ----------
func show_menu(has_save: bool) -> void:
	_clear()
	var bg := _panel(Color(0.04, 0.05, 0.07, 1.0))
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_CENTER)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 14)
	root.add_child(vb)
	var title := _label("曙光之戰", 54, TXT)
	title.add_theme_color_override("font_color", GOLD)
	vb.add_child(title)
	vb.add_child(_label("DAYBREAK OFFENSIVE", 16, SUB))
	var b1 := _btn("劇　情　戰　役")
	b1.pressed.connect(func(): menu_story.emit())
	vb.add_child(b1)
	var b2 := _btn("遭　遇　戰")
	b2.pressed.connect(func(): menu_versus.emit())
	vb.add_child(b2)
	# 置中
	vb.position = Vector2(get_viewport().get_visible_rect().size.x / 2 - 130,
			get_viewport().get_visible_rect().size.y / 2 - 140)

# ---------- 章節選擇（名冊立繪）----------
func show_story(unlocked: int) -> void:
	_clear()
	var bg := _panel(Color(0.04, 0.05, 0.07, 0.96))
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)
	var head := _mk_banner("CAMPAIGN", "曙光作戰", "2034，無旗幟的戰爭")
	head.position = Vector2(60, 40)
	root.add_child(head)
	var vp := get_viewport().get_visible_rect().size
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(60, 160)
	scroll.custom_minimum_size = Vector2(600, vp.y - 260)
	scroll.size = Vector2(600, vp.y - 260)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var grid := VBoxContainer.new()
	grid.add_theme_constant_override("separation", 8)
	scroll.add_child(grid)
	var story: Array = GameData.story
	for ch in story:
		var n: int = ch.get("n", 0)
		var lock: bool = n > unlocked
		var b := Button.new()
		b.custom_minimum_size = Vector2(560, 46)
		b.add_theme_font_size_override("font_size", 18)
		b.text = "  %02d   %s" % [n, ("🔒 尚未解鎖" if lock else ch.get("title", ""))]
		b.disabled = lock
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		if not lock:
			var nn := n
			b.pressed.connect(func(): chapter_chosen.emit(nn))
		grid.add_child(b)
	var back := _btn("返回主選單", 16)
	back.position = Vector2(60, vp.y - 70)
	back.pressed.connect(func(): back_menu.emit())
	root.add_child(back)

func _mk_banner(tag: String, title: String, sub: String) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(560, 100)
	var bg := _panel(Color(0.11, 0.135, 0.17, 0.95))
	bg.size = Vector2(560, 100)
	c.add_child(bg)
	var bar := ColorRect.new()
	bar.color = GOLD
	bar.size = Vector2(190, 7)
	bar.position = Vector2(-8, 12)
	bar.rotation = deg_to_rad(-4)
	c.add_child(bar)
	var t := _label(tag, 13, GOLD)
	t.position = Vector2(24, 22)
	c.add_child(t)
	var ti := _label(title, 26, TXT)
	ti.position = Vector2(24, 40)
	c.add_child(ti)
	var s := _label(sub, 13, SUB)
	s.position = Vector2(24, 74)
	c.add_child(s)
	return c

# ---------- 簡報（名冊立繪橫排）----------
func show_briefing(ch: Dictionary, on_go: Callable) -> void:
	_clear()
	var bg := _panel(Color(0.04, 0.05, 0.07, 0.96))
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)
	var head := _mk_banner("MISSION %02d" % ch.get("n", 1), ch.get("title", ""), "")
	head.position = Vector2(60, 36)
	root.add_child(head)
	var brief := _label(ch.get("brief", ""), 16, TXT)
	brief.custom_minimum_size = Vector2(760, 0)
	brief.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	brief.position = Vector2(60, 150)
	brief.size = Vector2(760, 120)
	root.add_child(brief)
	# 名冊立繪（只顯示已解鎖）
	var roster := HBoxContainer.new()
	roster.add_theme_constant_override("separation", 10)
	roster.position = Vector2(60, 300)
	root.add_child(roster)
	var n: int = ch.get("n", 1)
	for cls in GameData.characters.keys():
		var chr: Dictionary = GameData.characters[cls]
		if chr.get("unlockCh", 1) > n:
			continue
		var pv := VBoxContainer.new()
		var tr := TextureRect.new()
		var path := GameData.portrait_path(cls)
		if path != "":
			tr.texture = load(path)
		tr.custom_minimum_size = Vector2(120, 150)
		tr.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pv.add_child(tr)
		pv.add_child(_label(chr.get("name", ""), 14, GOLD))
		roster.add_child(pv)
	var go := _btn("🎖 出　擊")
	go.position = Vector2(60, get_viewport().get_visible_rect().size.y - 90)
	go.pressed.connect(func(): on_go.call())
	root.add_child(go)

# ---------- 立繪對話（大立繪＋打字機）----------
func show_dialogue(script: Array, cb: Callable) -> void:
	_dlg_script = script
	_dlg_cb = cb
	_dlg_i = 0
	_dlg_faces = {"left": "", "right": ""}
	_dlg_step()

func _dlg_step() -> void:
	if _dlg_i >= _dlg_script.size():
		_clear()
		if _dlg_cb.is_valid():
			_dlg_cb.call()
		return
	var d: Dictionary = _dlg_script[_dlg_i]
	var who: String = d.get("who", "")
	var cls := GameData.cls_by_name(who)
	var mood: String = d.get("mood", "")
	var img := GameData.portrait_path(cls, mood)
	var side: String = "right" if d.get("pos", "") == "right" else "left"
	if img != "":
		_dlg_faces[side] = img
	_render_dlg(d, side)

func _render_dlg(d: Dictionary, active_side: String) -> void:
	_clear()
	var vp := get_viewport().get_visible_rect().size
	var bg := _panel(Color(0.03, 0.04, 0.05, 0.55))
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)
	# 左右立繪（大）
	for s in ["left", "right"]:
		if _dlg_faces[s] == "":
			continue
		var tr := TextureRect.new()
		# 先定 expand/stretch 再定尺寸：否則指定紋理時最小尺寸被鎖成原圖，之後改模式不回縮 → 爆界
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE          # 尊重框大小，不讓圖比例撐爆
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.clip_contents = true                                  # 超出框一律裁掉，絕不出界
		tr.texture = load(_dlg_faces[s])
		var h := vp.y * 0.66
		var w := h * 0.56
		tr.custom_minimum_size = Vector2(w, h)
		tr.size = Vector2(w, h)
		tr.position = Vector2(vp.x * 0.03 if s == "left" else vp.x * 0.97 - w, vp.y - h - 120)
		# 非說話方壓暗
		tr.modulate = Color(1, 1, 1, 1) if s == active_side else Color(0.45, 0.45, 0.5, 0.9)
		root.add_child(tr)
	# 對話框
	var box := _panel(Color(0.051, 0.067, 0.09, 0.94))
	box.size = Vector2(vp.x * 0.86, 130)
	box.position = Vector2(vp.x * 0.07, vp.y - 150)
	root.add_child(box)
	var edge := ColorRect.new()
	edge.color = GOLD
	edge.size = Vector2(4, 130)
	edge.position = box.position
	root.add_child(edge)
	var who: String = d.get("who", "")
	var cls := GameData.cls_by_name(who)
	var callsign: String = GameData.characters.get(cls, {}).get("callsign", "")
	var name_l := _label(who + ("　「" + callsign + "」" if callsign != "" else ""), 20, GOLD)
	name_l.position = box.position + Vector2(20, 12)
	root.add_child(name_l)
	var txt := _label("", 19, TXT)
	txt.name = "DlgText"
	txt.custom_minimum_size = Vector2(vp.x * 0.82, 0)
	txt.size = Vector2(vp.x * 0.82, 70)
	txt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	txt.position = box.position + Vector2(20, 46)
	root.add_child(txt)
	var hint := _label("▼ (%d/%d)" % [_dlg_i + 1, _dlg_script.size()], 13, SUB)
	hint.position = box.position + Vector2(box.size.x - 90, 104)
	root.add_child(hint)
	# 打字機
	_type_full = d.get("text", "")
	_type_k = 0
	_type_accum = 0.0
	_typing = true

func _process(delta: float) -> void:
	if _typing:
		_type_accum += delta
		while _type_accum >= 0.028 and _type_k < _type_full.length():
			_type_accum -= 0.028
			_type_k += 1
		var lbl := root.find_child("DlgText", true, false)
		if lbl:
			(lbl as Label).text = _type_full.substr(0, _type_k)
		if _type_k >= _type_full.length():
			_typing = false

func _unhandled_input(event: InputEvent) -> void:
	if _dlg_script.is_empty():
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _typing:
			_typing = false
			_type_k = _type_full.length()
			var lbl := root.find_child("DlgText", true, false)
			if lbl:
				(lbl as Label).text = _type_full
		else:
			_dlg_i += 1
			if _dlg_i >= _dlg_script.size():
				_dlg_script = []
				_dlg_step()
			else:
				_dlg_step()

# ---------- 部署面板 ----------
func show_deploy(ch, budget_left: int, roster: Array, on_pick: Callable, on_go: Callable) -> void:
	_clear()
	var vp := get_viewport().get_visible_rect().size
	var side := _panel(Color(0.051, 0.067, 0.09, 0.93))
	side.size = Vector2(340, vp.y)
	side.position = Vector2(vp.x - 340, 0)
	root.add_child(side)
	var head := _mk_banner("MISSION %02d" % (ch.get("n", 1) if ch is Dictionary else 1),
			(ch.get("title", "部署") if ch is Dictionary else "部署"), "選擇出戰隊員")
	head.position = side.position
	head.scale = Vector2(0.6, 0.6)
	root.add_child(head)
	var budget_lbl := _label("部署點數 %d" % budget_left, 15, GOLD)
	budget_lbl.name = "BudgetLbl"
	budget_lbl.position = side.position + Vector2(16, 92)
	root.add_child(budget_lbl)
	# 可捲動清單（治「兵種多超出邊界」）
	var scroll := ScrollContainer.new()
	scroll.position = side.position + Vector2(12, 118)
	scroll.custom_minimum_size = Vector2(320, vp.y - 220)
	scroll.size = Vector2(320, vp.y - 220)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 8)
	scroll.add_child(list)
	for item in roster:
		# 立繪卡（左立繪縮圖＋右文字），召喚不了的不顯示（由呼叫端過濾）
		var card := Control.new()
		card.custom_minimum_size = Vector2(308, 64)
		var cbg := _panel(Color(0.11, 0.135, 0.17, 1.0))
		cbg.size = Vector2(308, 64)
		card.add_child(cbg)
		var tr := TextureRect.new()
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE     # 先定模式再定尺寸，縮圖才不會撐成原圖爆出卡片
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		tr.clip_contents = true
		var pp: String = item.get("portrait", "")
		if pp != "":
			tr.texture = load(pp)
		tr.size = Vector2(56, 64)
		tr.position = Vector2(0, 0)
		card.add_child(tr)
		var nm_l := _label(("★%s ｜%s" % [item["name"], item["zh"]]) if item.get("named", true) else item["zh"], 15, TXT)
		nm_l.position = Vector2(64, 8)
		card.add_child(nm_l)
		var sub_l := _label(item.get("trait", ""), 12, SUB)
		sub_l.position = Vector2(64, 32)
		card.add_child(sub_l)
		var cost_l := _label("%d點" % item.get("cost", 0), 13, GOLD)
		cost_l.position = Vector2(250, 22)
		card.add_child(cost_l)
		var btn := Button.new()
		btn.flat = true
		btn.size = Vector2(308, 64)
		btn.custom_minimum_size = Vector2(308, 64)
		var ic: String = item["cls"]
		var nm = item.get("named", true)
		btn.pressed.connect(func(): on_pick.call(ic, nm))
		card.add_child(btn)
		list.add_child(card)
	var hint := _label("點卡片選人 → 點戰場藍框放置", 12, SUB)
	hint.position = side.position + Vector2(16, vp.y - 108)
	hint.name = "DeployHint"
	root.add_child(hint)
	var go := _btn("開 始 戰 鬥 ▶", 18)
	go.position = side.position + Vector2(16, vp.y - 80)
	go.pressed.connect(func(): on_go.call())
	root.add_child(go)

func update_budget(left: int, msg := "") -> void:
	var l := root.find_child("BudgetLbl", true, false)
	if l:
		(l as Label).text = "部署點數 %d" % left
	if msg != "":
		var h := root.find_child("DeployHint", true, false)
		if h:
			(h as Label).text = msg

# ---------- 戰鬥 HUD ----------
func show_hud() -> void:
	_clear()
	var head := _mk_banner("PLAYER PHASE", "第 1 回合", "")
	head.name = "HudBanner"
	head.position = Vector2(20, 16)
	head.scale = Vector2(0.7, 0.7)
	root.add_child(head)
	var et := _btn("結束回合", 16)
	et.name = "EndTurnBtn"
	et.position = Vector2(20, get_viewport().get_visible_rect().size.y - 70)
	et.pressed.connect(func(): end_turn.emit())
	root.add_child(et)

func update_hud(turn: int, phase: String, cp: int) -> void:
	var head := root.find_child("HudBanner", true, false)
	if head == null:
		return
	for c in head.get_children():
		if c is Label:
			var l := c as Label
			if l.get_theme_color("font_color") == GOLD and l.position.y < 30:
				l.text = "ENEMY PHASE" if phase == "enemy" else "PLAYER PHASE"
			elif l.position.y > 30 and l.position.y < 60:
				l.text = "第 %d 回合｜CP %d" % [turn, cp]

# 戰場角色卡（選中單位大立繪）
func show_charcard(cls: String, disp_name: String, trait_desc: String, hp: int, maxhp: int) -> void:
	var card := root.find_child("CharCard", false, false)
	if card:
		card.queue_free()
	if cls == "":
		return
	var vp := get_viewport().get_visible_rect().size
	var c := Control.new()
	c.name = "CharCard"
	root.add_child(c)
	var bg := _panel(Color(0.07, 0.086, 0.055, 0.86))
	bg.size = Vector2(230, 150)
	c.add_child(bg)
	var pbg := ColorRect.new()      # 立繪襯底（淺灰藍，深色立繪在此才看得見）
	pbg.color = Color(0.34, 0.4, 0.5, 1.0)
	pbg.position = Vector2(6, 6)
	pbg.size = Vector2(92, 138)
	c.add_child(pbg)
	var tr := TextureRect.new()     # 固定框＋裁切，縮圖穩定顯示在名字左側
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE          # 先定模式再定尺寸（見對話立繪同註）
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	tr.clip_contents = true
	var p := GameData.portrait_path(cls)
	if p != "":
		tr.texture = load(p)
	tr.position = Vector2(6, 6)
	tr.custom_minimum_size = Vector2(92, 138)
	tr.size = Vector2(92, 138)
	c.add_child(tr)
	c.add_child(_named_lbl(disp_name, 16, TXT, Vector2(104, 12)))
	c.add_child(_named_lbl(trait_desc, 12, SUB, Vector2(104, 44)))
	c.add_child(_named_lbl("HP %d/%d" % [hp, maxhp], 13, GOLD, Vector2(104, 110)))
	c.position = Vector2(14, vp.y - 164)

func hide_charcard() -> void:
	var card := root.find_child("CharCard", false, false)
	if card:
		card.queue_free()

func _named_lbl(txt: String, size: int, col: Color, pos: Vector2) -> Label:
	var l := _label(txt, size, col)
	l.position = pos
	return l

# ---------- 戰報 ----------
func show_end(win: bool, why: String, rank: String, debrief: String, on_ok: Callable) -> void:
	_clear()
	var bg := _panel(Color(0.03, 0.04, 0.05, 0.9))
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)
	var vp := get_viewport().get_visible_rect().size
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	vb.position = Vector2(vp.x / 2 - 300, 80)
	root.add_child(vb)
	var tag := _label("MISSION COMPLETE" if win else "MISSION FAILED", 18, GOLD if win else Color(0.88, 0.35, 0.25))
	vb.add_child(tag)
	vb.add_child(_label("勝 利" if win else "敗 北", 46, TXT))
	if win and rank != "":
		vb.add_child(_label("評價　" + rank, 30, GOLD))
	vb.add_child(_label(why, 16, SUB))
	if debrief != "":
		var db := _label(debrief, 15, TXT)
		db.custom_minimum_size = Vector2(600, 0)
		db.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vb.add_child(db)
	var ok := _btn("回主選單", 18)
	ok.pressed.connect(func(): on_ok.call())
	vb.add_child(ok)
