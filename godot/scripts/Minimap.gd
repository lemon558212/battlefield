# Minimap.gd — 戰場小地圖（GDD/13 資訊視覺化）。
# 存在理由：改成第三人稱之後，玩家只看得到角色前方那一小塊，
# 整場的敵我位置、壕溝、建築全部失去感覺。小地圖把「戰棋的全局」還給玩家。
# 只畫「玩家看得見的東西」：敵人隱形時不畫，才不會變成透視外掛。
extends Control

var provider: Callable = Callable()      # 由 Main 注入：回傳要畫的資料
var _t := 0.0

const BG := Color(0.05, 0.07, 0.09, 0.80)
const FRAME := Color(0.945, 0.757, 0.353, 0.9)
const TRENCH := Color(0.45, 0.38, 0.26, 0.95)
const BLD := Color(0.62, 0.60, 0.55, 0.95)
const ALLY := Color(0.36, 0.61, 1.0)
const FOE := Color(1.0, 0.36, 0.30)
const ACT := Color(1.0, 0.9, 0.4)
const RING := Color(0.36, 0.90, 0.60, 0.30)     # 偵測半徑（雷達圈）
const GHOST := Color(1.0, 0.36, 0.30, 0.55)     # 最後已知位置（雷達殘影）

# 雷達殘影（使用者 2026-07-27：「小地圖是雷達的概念」）。
# 只畫「現在偵測得到」的敵人會讓小地圖一閃一閃、無法用來判斷戰況；
# 真實雷達的做法是保留最後一次回波並隨時間衰減。玩家看到的是
# 「他剛才在這裡」，不是「他現在在這裡」——這既符合雷達，也不會變成透視外掛。
const GHOST_TTL := 6.0
var _ghosts: Array = []          # 每筆 {p: Vector2(px), t: 剩餘秒數}

func _process(delta: float) -> void:
	_t += delta
	for g in _ghosts:
		g["t"] -= delta
	_ghosts = _ghosts.filter(func(g): return float(g["t"]) > 0.0)
	if _t > 0.08:                        # 12Hz 就夠，小地圖不必每幀重畫
		_t = 0.0
		queue_redraw()

# 記錄／更新一筆雷達回波（同一個位置附近就刷新，不要疊出一串點）
func _mark_ghost(p: Vector2) -> void:
	for g in _ghosts:
		if (g["p"] as Vector2).distance_to(p) < 24.0:
			g["p"] = p
			g["t"] = GHOST_TTL
			return
	_ghosts.append({"p": p, "t": GHOST_TTL})

func _draw() -> void:
	if not provider.is_valid():
		return
	var d: Dictionary = provider.call()
	if d.is_empty():
		return
	var mw: float = d.get("mw", 960.0)
	var mh: float = d.get("mh", 600.0)
	var sz: Vector2 = size
	var k: float = minf(sz.x / mw, sz.y / mh)
	var off := Vector2((sz.x - mw * k) * 0.5, (sz.y - mh * k) * 0.5)
	draw_rect(Rect2(Vector2.ZERO, sz), BG, true)
	draw_rect(Rect2(Vector2.ZERO, sz), FRAME, false, 2.0)
	for t in d.get("trenches", []):
		var pts: Array = t
		for i in range(pts.size() - 1):
			draw_line(off + Vector2(pts[i][0], pts[i][1]) * k,
					off + Vector2(pts[i + 1][0], pts[i + 1][1]) * k, TRENCH, 3.0)
	for b in d.get("buildings", []):
		draw_rect(Rect2(off + Vector2(b[0], b[1]) * k, Vector2(b[2], b[3]) * k), BLD, true)
	# 敵人的雷達殘影：先畫（在實心點下面），空心圈代表「最後已知」不是「現在」
	for g in _ghosts:
		var gp: Vector2 = off + (g["p"] as Vector2) * k
		var fade: float = clampf(float(g["t"]) / GHOST_TTL, 0.0, 1.0)
		draw_arc(gp, 4.0, 0.0, TAU, 12, Color(GHOST.r, GHOST.g, GHOST.b, GHOST.a * fade), 1.5)
	for u in d.get("units", []):
		var p: Vector2 = off + Vector2(u[0], u[1]) * k
		var col: Color = ALLY if u[2] == 0 else FOE
		draw_circle(p, 3.0, col)
		if u[2] == 1:
			_mark_ghost(Vector2(u[0], u[1]))
	var a = d.get("acting", null)
	if a != null:
		var p2: Vector2 = off + Vector2(a[0], a[1]) * k
		# 雷達圈：這個單位偵測得到的範圍。少了它，玩家無從判斷
		# 「小地圖上沒有紅點」是安全還是只是看不到。
		var sight: float = float(d.get("sight", 0.0))
		if sight > 0.0:
			draw_arc(p2, sight * k, 0.0, TAU, 48, RING, 1.5)
		draw_circle(p2, 5.0, ACT)
		# 視野方向：讓玩家一眼知道自己面向戰場的哪一邊
		var dir := Vector2(sin(float(a[2])), cos(float(a[2])))
		draw_line(p2, p2 + dir * 14.0, ACT, 2.0)
