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

func set_tps(n: Node3D) -> void:
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
		if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
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
	var right := Vector3(fwd.z, 0, -fwd.x)
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
	if wall_probe.is_valid():
		var k: float = float(wall_probe.call(head, want))
		if k < 1.0:
			want = head.lerp(want, clampf(k - 0.10, 0.30, 1.0))
	if ground_probe.is_valid():
		var gy: float = float(ground_probe.call(want)) + 0.45
		if want.y < gy:
			want.y = gy                     # 鏡頭不鑽進地面/壕溝壁
	global_position = global_position.lerp(want, 1.0 - exp(-14.0 * delta))
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
