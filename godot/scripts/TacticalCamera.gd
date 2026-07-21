# TacticalCamera.gd — 戰術相機（GDD/13 P0）：拖曳平移／滾輪縮放／點兵跟隨
class_name TacticalCamera
extends Camera3D

var focus := Vector3.ZERO         # 注視點（地面）
var dist := 22.0                  # 距離（縮放）
var pitch_deg := 52.0
var yaw := 0.0
var follow_node: Node3D = null
var _dragging := false

func _ready() -> void:
	_apply()

func set_follow(n: Node3D) -> void:
	follow_node = n

func _over_ui() -> bool:
	# 指標壓在 UI 控件上時，滾輪/拖曳交給 UI，別動 3D 場景（治部署欄連動 3D）
	return get_viewport().gui_get_hovered_control() != null

func _unhandled_input(event: InputEvent) -> void:
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
	if follow_node != null and is_instance_valid(follow_node):
		# 注視點抬到胸高，立繪不會被螢幕下緣切成巨頭
		var aim := follow_node.global_position + Vector3(0, 1.1, 0)
		focus = focus.lerp(aim, 1.0 - exp(-8.0 * delta))
	_apply()

func _apply() -> void:
	var pr := deg_to_rad(pitch_deg)
	var offset := Vector3(sin(yaw) * cos(pr), sin(pr), cos(yaw) * cos(pr)) * dist
	global_position = focus + offset
	look_at(focus, Vector3.UP)
