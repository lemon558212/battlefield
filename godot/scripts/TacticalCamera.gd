# TacticalCamera.gd — 戰術相機（GDD/13 P0）：拖曳平移／滾輪縮放／點兵跟隨
class_name TacticalCamera
extends Camera3D

var focus := Vector3.ZERO         # 注視點（地面）
var dist := 22.0                  # 距離（縮放）
var pitch_deg := 52.0
var yaw := 0.0
var follow_node: Node3D = null
var _dragging := false
# ---- 第三人稱行動模式（GDD/07）----
# 指令模式＝斜角俯瞰；一旦下令操作某個單位，鏡頭滑到他背後上方，變成第三人稱。
# 這是「臨場感」的來源：玩家用角色的眼睛看戰場，而不是從天上點小人。
var tps_node: Node3D = null       # 非 null＝第三人稱模式
var tps_yaw := 0.0                # 玩家用滑鼠控制的視角朝向
var tps_pitch := -6.0
var tps_dist := 3.1
const TPS_SHOULDER := 0.62        # 過肩偏移：角色不擋準心
const TPS_EYE := 1.52
var mouse_sens := 0.14
var _shoulder := 1.0              # 目前在哪一側肩膀（1＝右、-1＝左，換肩時平滑過渡）
# 鏡頭碰撞用的回呼（由 Main 注入，因為牆與地形的真相在 Main/Terrain 那邊）：
#   wall_probe.call(from, to) -> float  最近命中比例 0~1（1＝沒撞到）
#   ground_probe.call(pos) -> float     該點的地面高度
var wall_probe: Callable = Callable()
var ground_probe: Callable = Callable()
#   inside_probe.call(pos) -> bool        這個世界座標是不是在某棟建築室內（嚴格：內縮 30cm，
#                                         給「鏡頭能停哪」用）
#   inside_loose_probe.call(pos) -> bool  寬鬆版（幾乎整個腳印）：給「角色在不在室內」的
#                                         **觸發**用。用嚴格版當觸發的話，人貼牆/站門口那
#                                         30cm 殼層會讓約束斷開，鏡頭穿出牆外（使用者回報
#                                         「很容易從牆壁看到外面」的真因）。
var inside_probe: Callable = Callable()
var inside_loose_probe: Callable = Callable()

var _tps_snap := false
func set_tps(n: Node3D) -> void:
	# 切到很遠的另一個單位時要用「剪接」不是「平移」：平滑飛越會讓鏡頭
	# 穿過沿路每一棟建築（ch02 壓測 22 次鏡頭穿牆的主因，玩家切兵也看得到）。
	# VC 本家也是快切。6m 內仍平滑（同一個交火圈裡的隊友）。
	if n != null and global_position.distance_to(n.global_position) > 6.0:
		_tps_snap = true
	tps_node = n
	if n != null:
		tps_yaw = rad_to_deg(n.rotation.y)
		tps_pitch = -6.0

func clear_tps() -> void:
	tps_node = null

func is_tps() -> bool:
	return tps_node != null and is_instance_valid(tps_node)

# 準心指向的世界方向（角色瞄準與射擊都吃這個）
func tps_forward() -> Vector3:
	var yr := deg_to_rad(tps_yaw)
	var pr := deg_to_rad(tps_pitch)
	return Vector3(sin(yr) * cos(pr), sin(pr), cos(yr) * cos(pr)).normalized()

func _ready() -> void:
	_apply()

func set_follow(n: Node3D) -> void:
	follow_node = n

func _over_ui() -> bool:
	# 指標壓在 UI 控件上時，滾輪/拖曳交給 UI，別動 3D 場景（治部署欄連動 3D）
	return get_viewport().gui_get_hovered_control() != null

func _unhandled_input(event: InputEvent) -> void:
	if is_tps():
		# 轉視角有三條路，玩家用哪條都行：
		#   ① 按住右鍵拖曳（游標沒被鎖住時的主要方式）
		#   ② Tab 鎖住游標後直接移動滑鼠（想要 FPS 手感的人用）
		#   ③ Q/E（完全不用滑鼠）
		# ⚠ 預設**不鎖游標**：這是戰術遊戲，螢幕上一直有「結束行動」要點
		#   （2026-07-27 使用者：鎖住等於滑鼠沒有用、只能關掉遊戲）。
		if event is InputEventMouseMotion and (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
				or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)):
			var m := event as InputEventMouseMotion
			tps_yaw -= m.relative.x * mouse_sens
			tps_pitch = clampf(tps_pitch - m.relative.y * mouse_sens, -35.0, 22.0)
		elif event is InputEventMouseButton:
			var b := event as InputEventMouseButton
			if b.button_index == MOUSE_BUTTON_WHEEL_UP:
				tps_dist = clampf(tps_dist - 0.3, 1.6, 6.0)
			elif b.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				tps_dist = clampf(tps_dist + 0.3, 1.6, 6.0)
		return
	if event is InputEventMouseButton and _over_ui():
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			dist = clamp(dist * 0.9, 6.0, 60.0)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dist = clamp(dist * 1.1, 6.0, 60.0)
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = mb.pressed
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		follow_node = null
		var right := global_transform.basis.x
		var fwd := -global_transform.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		focus -= (right * mm.relative.x + fwd * -mm.relative.y) * dist * 0.0016

func _process(delta: float) -> void:
	if is_tps():
		_apply_tps(delta)
		return
	if follow_node != null and is_instance_valid(follow_node):
		# 注視點抬到胸高，立繪不會被螢幕下緣切成巨頭
		var aim := follow_node.global_position + Vector3(0, 1.1, 0)
		focus = focus.lerp(aim, 1.0 - exp(-8.0 * delta))
	_apply()

# 第三人稱：相機在角色右後上方，看向準心方向。位置用指數收斂，跑起來才不會抖。
func _apply_tps(delta: float) -> void:
	var yr := deg_to_rad(tps_yaw)
	var pr := deg_to_rad(tps_pitch)
	var fwd := Vector3(sin(yr), 0, cos(yr))
	# ⚠ 正面是 +Z 的慣例下，右邊＝fwd × UP＝(-fwd.z, 0, fwd.x)。
	#   寫成 (fwd.z, 0, -fwd.x) 是左邊——過肩鏡頭一直掛在左肩上（同 50928ac 修過的左右相反）。
	var right := Vector3(-fwd.z, 0, fwd.x)
	# 眼高跟著姿勢走（站/蹲/趴），否則趴著時鏡頭仍吊在站姿高度、人被草淹沒
	var eye: float = TPS_EYE
	if tps_node.has_method("eye_height"):
		eye = float(tps_node.eye_height())
	var head: Vector3 = tps_node.global_position + Vector3(0, eye, 0)
	# 自動換肩（GDD/07）：貼著牆往右靠時，右肩鏡頭會被牆推到臉前、畫面整片牆。
	# 主流 TPS 的解法不是硬拉近，而是換到另一邊肩膀——那邊通常是空的。
	var k_r := 1.0
	var k_l := 1.0
	if wall_probe.is_valid():
		k_r = float(wall_probe.call(head, _tps_want(head, fwd, right, pr, 1.0)))
		k_l = float(wall_probe.call(head, _tps_want(head, fwd, right, pr, -1.0)))
	# 右肩優先：只有明顯比較差才換過去，否則鏡頭會在兩肩之間來回搖
	var side_want: float = 1.0 if k_r >= k_l - 0.18 else -1.0
	_shoulder = move_toward(_shoulder, side_want, delta * 3.0)
	var want: Vector3 = _tps_want(head, fwd, right, pr, _shoulder)
	# 鏡頭碰撞：牆擋住就把鏡頭拉近。不做這個，第三人稱一貼牆就會看穿牆壁，臨場感全毀。
	# 下限 0.06 太近＝鏡頭黏在後腦杓上，畫面被牆佔滿；換肩之後這裡只需要輕微修正。
	# ★★2026-07-27 使用者回報「室內鏡頭穿牆，畫面被巨大牆面塞滿」的真因：
	#   下限被夾在 0.30——牆就貼在角色背後時 k 只有 0.05，卻硬留 30% 的距離
	#   （tps_dist 3.1m 的 30% ＝ 0.93m），鏡頭正好停在牆的另一側。
	#   室內牆到牆常常不到 2m，這個下限在物理上不可能滿足。
	#   改成可以一路收到 0.04（近乎第一人稱）——牆在後面時本來就該貼著看，
	#   這是所有 TPS 的標準行為，總比讓玩家看一片牆好。
	# ★★所有約束一律套在「目標位置 want」上，**不可以在平滑之後再改實際位置**
	#   （2026-07-27 使用者：「進入建築物畫面會一直跳」）。
	#   平滑把鏡頭往外推、修正再把它拉回來，兩者每幀互相打架＝畫面持續抖動。
	#   約束放在 want 上，收斂過程單調、不會震盪。
	if wall_probe.is_valid():
		var k: float = float(wall_probe.call(head, want))
		if k < 1.0:
			want = head.lerp(want, clampf(k - 0.12, 0.04, 1.0))
	# 角色在室內時，鏡頭必須也在同一個房間裡。
	# ⚠ `wall_probe` 是線段對牆段求交：鏡頭若從門窗缺口穿出去再停在牆體裡，
	#   那條線段沒有命中任何牆段，判定不出來（實拍：室內環顧有一格整片紅磚）。
	#   所以用「幾何歸屬」再收一次——二分逼近，找出仍在室內的最遠點。
	var trig: Callable = inside_loose_probe if inside_loose_probe.is_valid() else inside_probe
	if inside_probe.is_valid() and bool(trig.call(tps_node.global_position)):
		if not bool(inside_probe.call(want)):
			var lo := 0.0
			var hi := 1.0
			for _i in 6:
				var mid: float = (lo + hi) * 0.5
				if bool(inside_probe.call(head.lerp(want, mid))):
					lo = mid
				else:
					hi = mid
			want = head.lerp(want, maxf(lo - 0.06, 0.04))
	if ground_probe.is_valid():
		var gy: float = float(ground_probe.call(want)) + 0.45
		if want.y < gy:
			want.y = gy                     # 鏡頭不鑽進地面/壕溝壁
	if _tps_snap:
		global_position = want          # 剪接：新目標的第一幀就定位，不穿場平移
		_tps_snap = false
	else:
		var newp: Vector3 = global_position.lerp(want, 1.0 - exp(-14.0 * delta))
		# 平滑「過程」也不可以穿牆：急轉向時 want 跳到另一側，收斂路徑會瞬間
		# 掃過身旁的貨櫃/牆（ch08/ch12 壓測各抓到 1~2 幀）。這裡只做「往 head 收縮」
		# 的單調修正，不會跟 want 上的約束互相打架（那才是以前畫面抖動的原因）。
		if wall_probe.is_valid():
			var kt: float = float(wall_probe.call(head, newp))
			if kt < 1.0:
				newp = head.lerp(newp, clampf(kt - 0.12, 0.04, 1.0))
		global_position = newp
	var look_at_p: Vector3 = head + tps_forward() * 12.0 + right * TPS_SHOULDER * _shoulder * 0.5
	look_at(look_at_p, Vector3.UP)

# 某一側肩膀的鏡頭位置（side: 1＝右肩、-1＝左肩，中間值是換肩過程）
func _tps_want(head: Vector3, fwd: Vector3, right: Vector3, pr: float, side: float) -> Vector3:
	return head - fwd * tps_dist * cos(pr) + right * TPS_SHOULDER * side 			- Vector3(0, sin(pr), 0) * tps_dist

func _apply() -> void:
	var pr := deg_to_rad(pitch_deg)
	var offset := Vector3(sin(yaw) * cos(pr), sin(pr), cos(yaw) * cos(pr)) * dist
	global_position = focus + offset
	look_at(focus, Vector3.UP)
