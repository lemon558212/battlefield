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

func _process(delta: float) -> void:
	_t += delta
	if _t > 0.08:                        # 12Hz 就夠，小地圖不必每幀重畫
		_t = 0.0
		queue_redraw()

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
	for u in d.get("units", []):
		var p: Vector2 = off + Vector2(u[0], u[1]) * k
		var col: Color = ALLY if u[2] == 0 else FOE
		draw_circle(p, 3.0, col)
	var a = d.get("acting", null)
	if a != null:
		var p2: Vector2 = off + Vector2(a[0], a[1]) * k
		draw_circle(p2, 5.0, ACT)
		# 視野方向：讓玩家一眼知道自己面向戰場的哪一邊
		var dir := Vector2(sin(float(a[2])), cos(float(a[2])))
		draw_line(p2, p2 + dir * 14.0, ACT, 2.0)
