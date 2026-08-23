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
signal training_open
signal training_up(cls: String)
signal training_back
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
var _dlg_txt: Label = null      # 直接持有當前對話文字 Label，不靠 find_child（避免搜到殘影）

func _ready() -> void:
	layer = 10
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_make_debug_overlay()

# ---------- 動作系統 Debug Overlay（F3 開關，2026-08-07）----------
# 為什麼要有：運動狀態（步態、速度、踏頻倍率、IK 權重、坡度）全都是**每幀在變**的量，
# 靠日誌事後看永遠對不上「當下畫面為什麼是這樣」。做成疊加層才能一邊玩一邊對照。
# ⚠ 不掛在 root 底下：root 會被 _clear() 整個清掉（換畫面時），overlay 要活過那個。
# 正式版預設隱藏，不影響效能（隱藏時 _process 直接 return）。
var _dbg: Label = null
var _dbg_src: Callable = Callable()

func _make_debug_overlay() -> void:
	_dbg = Label.new()
	_dbg.name = "LocoDebug"
	_dbg.position = Vector2(12, 96)
	_dbg.add_theme_font_size_override("font_size", 15)
	_dbg.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	_dbg.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_dbg.add_theme_constant_override("outline_size", 4)
	_dbg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dbg.visible = false
	add_child(_dbg)

# Main 注入一個「回傳目前該顯示什麼」的 Callable（UI 不該知道 Unit 的內部結構）
func set_debug_source(src: Callable) -> void:
	_dbg_src = src

func toggle_debug() -> bool:
	if _dbg == null:
		return false
	_dbg.visible = not _dbg.visible
	return _dbg.visible

# ⚠ UI.gd 已經有一支 _process（第 576 行，跑閃字與小地圖）。
#   GDScript 不會警告重複定義，直接變成 Parse Error 而且訊息只說
#   「Could not parse global class GameUI」——看不出是我加了第二支。
#   所以這裡不另開 _process，改由既有那支呼叫。
func _tick_debug() -> void:
	if _dbg == null or not _dbg.visible or not _dbg_src.is_valid():
		return
	_dbg.text = String(_dbg_src.call())

# 立即從樹上移除再釋放：queue_free 是「延遲」刪除，舊節點會殘留一段時間，
# 導致 find_child("DlgText"/"BudgetLbl"/...) 搜到正要被刪的舊節點 → 字寫進垃圾節點、新節點永遠空白。
# （2026-07-22 對話第2句以後沒字的真因，根治整類「按名字搜到殘影」的 bug。）
func _clear() -> void:
	_dlg_txt = null
	for c in root.get_children():
		root.remove_child(c)
		c.queue_free()

# 載圖：優先用匯入資源，失敗則執行期直接讀原始檔（繞過匯入快取，桌面版從源碼跑最穩）
var _tex_cache := {}
func _load_tex(path: String) -> Texture2D:
	if _tex_cache.has(path):
		return _tex_cache[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		var r = load(path)
		if r is Texture2D:
			tex = r
	if tex == null:
		# 匯入失敗(大圖 headless 壓不動)時，讀原始 bytes 自己解碼
		var bytes := PackedByteArray()
		if FileAccess.file_exists(path):
			bytes = FileAccess.get_file_as_bytes(path)
		if bytes.is_empty():
			var abs := ProjectSettings.globalize_path(path)
			if FileAccess.file_exists(abs):
				bytes = FileAccess.get_file_as_bytes(abs)
		if not bytes.is_empty():
			var img := Image.new()
			var err := FAILED
			if path.ends_with(".png"):
				err = img.load_png_from_buffer(bytes)
			else:
				err = img.load_jpg_from_buffer(bytes)
			if err == OK:
				tex = ImageTexture.create_from_image(img)
	_tex_cache[path] = tex
	return tex

# 從全身立繪裁出頭肩區當頭像（去背 PNG 四周有透明留白，直接縮會變小小全身）
func _avatar(tex: Texture2D) -> Texture2D:
	if tex == null:
		return null
	var w := tex.get_width()
	var h := tex.get_height()
	if w <= 0 or h <= 0:
		return tex
	var at := AtlasTexture.new()
	at.atlas = tex
	at.region = Rect2(w * 0.16, h * 0.04, w * 0.68, h * 0.44)   # 頭肩區
	return at

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
	b.focus_mode = Control.FOCUS_NONE
	b.text = txt
	b.add_theme_font_size_override("font_size", size)
	b.custom_minimum_size = Vector2(260, 52)
	return b

# 戰場快訊：迎擊這種「玩家沒下令卻發生的事」一定要有字說明，否則只看到血條莫名其妙掉。
# 同一則訊息連續觸發時只更新既有標籤（機槍兵 0.25 秒一發，會洗版）。
var _flash: Label = null
var _flash_t := 0.0

func flash_msg(txt: String, col := Color(1, 1, 1)) -> void:
	if _flash == null or not is_instance_valid(_flash):
		_flash = _label(txt, 26, col)
		_flash.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_flash.add_theme_constant_override("outline_size", 6)
		_flash.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		root.add_child(_flash)
	_flash.text = txt
	_flash.add_theme_color_override("font_color", col)
	var vw: float = get_viewport().get_visible_rect().size.x
	_flash.size.x = vw
	_flash.position = Vector2(0, 110)
	_flash.modulate.a = 1.0
	_flash_t = 1.4

# ---------- 小地圖 ----------
const MINIMAP := preload("res://scripts/Minimap.gd")
var _minimap: Control = null

func show_minimap(provider: Callable) -> void:
	if is_instance_valid(_minimap):
		return
	var m := Control.new()
	m.set_script(MINIMAP)
	m.name = "Minimap"
	m.size = Vector2(200, 145)
	var vp := get_viewport().get_visible_rect().size
	m.position = Vector2(vp.x - 216, 16)
	m.provider = provider
	root.add_child(m)
	_minimap = m

func hide_minimap() -> void:
	if is_instance_valid(_minimap):
		_minimap.queue_free()
	_minimap = null

# ---------- 準心（第三人稱行動模式）----------
var _cross: Control = null

func show_crosshair(on: bool) -> void:
	if not on:
		if is_instance_valid(_cross):
			_cross.queue_free()
		_cross = null
		return
	if is_instance_valid(_cross):
		return
	var c := Control.new()
	c.name = "Crosshair"
	var vp := get_viewport().get_visible_rect().size
	c.position = vp * 0.5
	for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		var bar := ColorRect.new()
		bar.color = Color(1, 1, 1, 0.85)
		if absf(d.x) > 0.0:
			bar.size = Vector2(9, 2)
			bar.position = Vector2(d.x * 7.0 - (0.0 if d.x > 0 else 9.0), -1)
		else:
			bar.size = Vector2(2, 9)
			bar.position = Vector2(-1, d.y * 7.0 - (0.0 if d.y > 0 else 9.0))
		c.add_child(bar)
	var dot := ColorRect.new()
	dot.color = Color(1, 0.85, 0.35, 0.9)
	dot.size = Vector2(3, 3)
	dot.position = Vector2(-1.5, -1.5)
	c.add_child(dot)
	root.add_child(c)
	_cross = c

# ---------- 射擊面板（GDD/13：命中與傷害預測、部位選擇）----------
# 玩家在按下開火前就該知道「打得中嗎、打得痛嗎」，這是戰棋最基本的資訊揭露。
var _fire_box: Control = null

func show_fire_panel(opts: Array, on_pick: Callable) -> void:
	hide_fire_panel()
	var box := Control.new()
	box.name = "FireBox"
	# 修正明細（GDD/13 資訊揭露）：玩家要看得懂「為什麼只有 38%」。
	# 明細取第一個部位的（掩體、穿透、姿勢、天候、光線對兩個部位都一樣），
	# 部位之間唯一會不同的是「被遮蔽」，那個已經標在按鈕文字上了。
	var why: Array = []
	if opts.size() > 0 and opts[0].has("why"):
		why = opts[0]["why"]
	var h: int = 56 + opts.size() * 54 + 42 + (0 if why.is_empty() else why.size() * 19 + 8)
	var bg := _panel(Color(0.04, 0.05, 0.07, 0.92))
	bg.size = Vector2(330, h)
	box.add_child(bg)
	var bar := ColorRect.new()
	bar.color = GOLD
	bar.size = Vector2(330, 3)
	box.add_child(bar)
	var t := _label("選擇瞄準部位", 17, GOLD)
	t.position = Vector2(14, 12)
	box.add_child(t)
	var y := 46
	for o in opts:
		var b := _btn("%s　命中 %d%%　傷害 %d" % [o["zh"], int(round(float(o["hit"]) * 100.0)), int(o["dmg"])], 16)
		b.custom_minimum_size = Vector2(302, 44)
		b.size = Vector2(302, 44)
		b.position = Vector2(14, y)
		var part: String = o["part"]
		b.pressed.connect(func(): on_pick.call(part))
		box.add_child(b)
		y += 54
	if not why.is_empty():
		for w in why:
			var wl := _label("・" + String(w), 13, Color(0.72, 0.76, 0.80))
			wl.position = Vector2(16, y + 2)
			box.add_child(wl)
			y += 19
		y += 8
	var c := _btn("取消", 14)
	c.custom_minimum_size = Vector2(302, 30)
	c.size = Vector2(302, 30)
	c.position = Vector2(14, y - 4)
	c.pressed.connect(func(): on_pick.call(""))
	box.add_child(c)
	var vp := get_viewport().get_visible_rect().size
	box.position = Vector2(vp.x * 0.5 - 165, vp.y * 0.5 - h * 0.5)
	root.add_child(box)
	_fire_box = box

func hide_fire_panel() -> void:
	if is_instance_valid(_fire_box):
		_fire_box.queue_free()
	_fire_box = null

func fire_panel_open() -> bool:
	return is_instance_valid(_fire_box)

# ---------- 主選單 ----------
func show_menu(has_save: bool) -> void:
	_clear()
	var vpm := get_viewport().get_visible_rect().size
	# 封面主視覺（黎明狙擊手）鋪滿背景，蓋一層漸層暗幕讓標題/按鈕可讀
	var cover_tex := _load_tex("res://assets/art/title-key-visual.jpg")
	if cover_tex:
		var cover := TextureRect.new()
		cover.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		cover.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		cover.texture = cover_tex
		cover.size = vpm
		cover.set_anchors_preset(Control.PRESET_FULL_RECT)
		root.add_child(cover)
		var scrim := _panel(Color(0.03, 0.04, 0.06, 0.45))
		scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
		root.add_child(scrim)
	else:
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
func show_story(unlocked: int, training := false) -> void:
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
		b.focus_mode = Control.FOCUS_NONE
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
	# 訓練場（GDD/16）：第 4 章通關後才出現——沒解鎖就不給看，避免「拿了卻沒地方花」
	if training:
		var tb := _btn("⚙ 訓練場", 16)
		tb.position = Vector2(240, vp.y - 70)
		tb.pressed.connect(func(): training_open.emit())
		root.add_child(tb)

# ---------- 訓練場（GDD/16 §3）：共用經驗池 → 兵科升級，全科同享 ----------
func show_training(pool: int, lvs: Dictionary) -> void:
	_clear()
	var bg := _panel(Color(0.04, 0.05, 0.07, 0.96))
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)
	var head := _mk_banner("TRAINING", "訓練場", "把戰場經驗換成部隊實力")
	head.position = Vector2(60, 40)
	root.add_child(head)
	var vp := get_viewport().get_visible_rect().size
	var pool_lb := Label.new()
	pool_lb.text = "經驗池  %d XP" % pool
	pool_lb.add_theme_font_size_override("font_size", 22)
	pool_lb.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	pool_lb.position = Vector2(660, 76)
	root.add_child(pool_lb)
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(60, 160)
	scroll.custom_minimum_size = Vector2(720, vp.y - 260)
	scroll.size = Vector2(720, vp.y - 260)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var grid := VBoxContainer.new()
	grid.add_theme_constant_override("separation", 8)
	scroll.add_child(grid)
	var g: Dictionary = GameData.growth
	var lv_max: int = int(g.get("lv_max", 10))
	for cls in g.get("trainable", []):
		var lv: int = int(lvs.get(cls, 0))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		var name_lb := Label.new()
		name_lb.custom_minimum_size = Vector2(480, 44)   # 要蓋住最長的效果字串，按鈕欄才對得齊
		name_lb.add_theme_font_size_override("font_size", 18)
		var eff := "HP+%d%%  命中+%.1f%%  攻擊+%d%%" % [
				int(round(float(g.get("hp_per_lv", 0.05)) * lv * 100)),
				float(g.get("acc_per_lv", 0.015)) * lv * 100,
				int(round(float(g.get("atk_per_lv", 0.03)) * lv * 100))]
		name_lb.text = "%s  Lv%d　%s" % [
				GameData.class_base.get(cls, {}).get("zh", cls), lv,
				(eff if lv > 0 else "未訓練")]
		row.add_child(name_lb)
		var up := Button.new()
		up.focus_mode = Control.FOCUS_NONE
		up.custom_minimum_size = Vector2(170, 40)
		if lv >= lv_max:
			up.text = "已滿級"
			up.disabled = true
		else:
			var cost: int = GameData.growth_cost(lv)
			up.text = "升級  %d XP" % cost
			up.disabled = pool < cost
			if not up.disabled:
				var cc := String(cls)
				up.pressed.connect(func(): training_up.emit(cc))
		row.add_child(up)
		grid.add_child(row)
	var back := _btn("返回戰役", 16)
	back.position = Vector2(60, vp.y - 70)
	back.pressed.connect(func(): training_back.emit())
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
	# 對話背景（治「沒背景很奇怪」）：鋪主視覺背景圖 + 暗幕，立繪站在有氛圍的場景前
	var scene_tex := _load_tex("res://assets/art/title-bg.jpg")
	if scene_tex:
		var scene := TextureRect.new()
		scene.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		scene.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		scene.texture = scene_tex
		scene.size = vp
		scene.set_anchors_preset(Control.PRESET_FULL_RECT)
		root.add_child(scene)
	var bg := _panel(Color(0.03, 0.04, 0.05, 0.45))
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
	_dlg_txt = txt
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
	_tick_debug()
	if _flash_t > 0.0 and is_instance_valid(_flash):
		_flash_t -= delta
		if _flash_t < 0.5:
			_flash.modulate.a = clampf(_flash_t / 0.5, 0.0, 1.0)
		if _flash_t <= 0.0:
			_flash.queue_free()
			_flash = null
	if _typing:
		_type_accum += delta
		while _type_accum >= 0.016 and _type_k < _type_full.length():
			_type_accum -= 0.016
			_type_k += 1
		if is_instance_valid(_dlg_txt):
			_dlg_txt.text = _type_full.substr(0, _type_k)
		if _type_k >= _type_full.length():
			_typing = false

# 用 _input（GUI 吃掉事件前先收）：對話畫面的全螢幕背景/立繪/對話框都是 STOP 控件，
# 會攔截點擊，若用 _unhandled_input 會永遠收不到 → 對話卡住無法推進。
func _input(event: InputEvent) -> void:
	if _dlg_script.is_empty():
		return
	var advance := false
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		advance = true
	elif event is InputEventKey and event.pressed and event.keycode in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER]:
		advance = true
	if not advance:
		return
	get_viewport().set_input_as_handled()
	if _typing:
		_typing = false
		_type_k = _type_full.length()
		if is_instance_valid(_dlg_txt):
			_dlg_txt.text = _type_full
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
			tr.texture = _avatar(_load_tex(pp))    # 裁頭肩區當頭像（治全身縮一條、比例怪）
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
		btn.focus_mode = Control.FOCUS_NONE
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
# ---- 行動模式 AP 條（GDD/01 §2）----
# 玩家要看得到「還能走多遠」，不然移動變成盲猜。數字＋長條，兩種都給。
signal end_action
var _ap_box: Control = null

func show_ap(cur: float, mx: float) -> void:
	if _ap_box == null or not is_instance_valid(_ap_box):
		var box := Control.new()
		box.name = "ApBox"
		var bg := _panel(Color(0, 0, 0, 0.72))
		bg.name = "Bg"
		bg.size = Vector2(300, 56)
		box.add_child(bg)
		var l := _label("AP", 16, GOLD)
		l.name = "ApLbl"
		l.position = Vector2(10, 4)
		box.add_child(l)
		var bar_bg := _panel(Color(0.25, 0.25, 0.28, 0.9))
		bar_bg.name = "BarBg"
		bar_bg.position = Vector2(10, 30)
		bar_bg.size = Vector2(280, 14)
		box.add_child(bar_bg)
		var bar := _panel(Color(1.0, 0.82, 0.35, 0.95))
		bar.name = "Bar"
		bar.position = Vector2(10, 30)
		bar.size = Vector2(280, 14)
		box.add_child(bar)
		root.add_child(box)
		_ap_box = box
	var vp := get_viewport().get_visible_rect().size
	_ap_box.position = Vector2(vp.x - 320, vp.y - 76)
	var k: float = 0.0 if mx <= 0.001 else clampf(cur / mx, 0.0, 1.0)
	(_ap_box.find_child("ApLbl", false, false) as Label).text = "AP %d / %d" % [int(cur), int(mx)]
	(_ap_box.find_child("Bar", false, false) as ColorRect).size = Vector2(280.0 * k, 14)
	var eb := root.find_child("EndActBtn", true, false)
	if eb:
		eb.visible = true

func hide_ap() -> void:
	if is_instance_valid(_ap_box):
		_ap_box.queue_free()
	_ap_box = null
	var eb := root.find_child("EndActBtn", true, false)
	if eb:
		eb.visible = false

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
	# 放右下角 AP 條正上方：左下角被角色卡佔滿，擺那裡會被蓋住（實拍發現）
	var ea := _btn("結束行動", 16)
	ea.name = "EndActBtn"
	ea.custom_minimum_size = Vector2(300, 44)
	ea.position = Vector2(get_viewport().get_visible_rect().size.x - 320,
			get_viewport().get_visible_rect().size.y - 132)
	ea.visible = false
	ea.pressed.connect(func(): end_action.emit())
	root.add_child(ea)

func update_hud(turn: int, phase: String, cp: int, wx := "") -> void:
	var head := root.find_child("HudBanner", true, false)
	if head == null:
		return
	for c in head.get_children():
		if c is Label:
			var l := c as Label
			if l.get_theme_color("font_color") == GOLD and l.position.y < 30:
				l.text = "ENEMY PHASE" if phase == "enemy" else "PLAYER PHASE"
			elif l.position.y > 30 and l.position.y < 60:
				l.text = "第 %d 回合｜CP %d" % [turn, cp] + ("" if wx == "" else "｜" + wx)

# 任務目標列（GDD/01 §7、GDD/13）：玩家隨時要知道「這一場要幹嘛、進度到哪」。
# 先前十五章的目標一律是「把人殺光」，所以沒有這一列也不會有人發現——
# 有了任務型態之後，沒有這一列玩家就只能猜。
var _obj_label: Label = null
func show_objective(txt: String) -> void:
	if txt == "":
		if is_instance_valid(_obj_label):
			_obj_label.visible = false
		return
	if not is_instance_valid(_obj_label):
		_obj_label = _label("", 15, Color(0.95, 0.86, 0.55))
		_obj_label.position = Vector2(28, 92)
		root.add_child(_obj_label)
	_obj_label.visible = true
	_obj_label.text = "◈ " + txt

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
