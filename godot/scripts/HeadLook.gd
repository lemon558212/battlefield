# HeadLook.gd — 頭部注視（2026-08-07）。
#
# 為什麼要有這個：現在的角色不管旁邊發生什麼事，臉永遠朝著身體正面。
# 真人不是這樣——身體往一個方向走、眼睛盯著威脅，這是「有在觀察戰場」在畫面上
# 唯一看得出來的表現（鐵律 0：現實怎樣就怎樣）。
#
# 做法：在動畫與 _aim_pose 都算完之後，對 胸→頸→頭 三根骨頭各補一份世界軸旋轉。
#   ① 三根骨頭是父子鏈，旋轉會往下累積 ⇒ 頭最終轉到的角度 = 三個 share 的**總和**。
#      所以 look_head_share + look_neck_share + look_chest_share 要等於 1.0
#      （預設 0.55 + 0.25 + 0.20），不是「各自轉多少」而是「各自分攤多少」。
#      分攤而不是只轉頭，是因為人轉頭超過 ~45° 時肩胸一定會跟著帶——
#      只轉頭會變成貓頭鷹。
#   ② 用 add_world_rotation（相對骨頭**當前世界朝向**疊加）而不是姿勢表：
#      這種寫法完全不吃 rest pose，所以跟 FootIK 一樣三系骨架都能安全套用，
#      不必像 _aim_pose 那樣被「只做 Quaternius」擋住。
#   ③ 夾限與收斂：脖子轉不到 180°（look_yaw_max/look_pitch_max），
#      目標瞬間換人時頭要「轉過去」而不是瞬移（look_speed）。
#
# ⚠ 一定要在 _aim_pose 之後呼叫：趴姿那段自己會抬頭，順序反了會被蓋掉。
class_name HeadLook
extends RefCounted

# 分攤的骨頭，由外往內（順序＝套用順序，父骨先轉，子骨的世界朝向才是「已經被帶過」的）
const CHAIN := ["Chest", "Neck", "Head"]

var p: LocomotionProfile

# ---- 輸出（Debug overlay 與量測讀）----
var yaw := 0.0                 # 目前實際偏轉（弧度，相對身體正面；正=角色的左）
var pitch := 0.0               # 目前實際俯仰（弧度，正=往上看）
var active := false            # 這一幀有沒有真的轉
var has_target := false

var _rig = null
var _warm := false             # 第一次直接跳到目標，不然生成瞬間會看到頭甩過去


func _init(profile: LocomotionProfile) -> void:
	p = profile


func bind(rig) -> void:
	_rig = rig
	_warm = false


func is_ready() -> bool:
	return _rig != null and p != null and p.look_at_enabled


# 主入口。
#   target   世界座標（null＝沒有注視目標，頭回正）
#   head_pos 頭骨的世界座標（呼叫端已經算過，不重複查）
#   forward/right 角色的正面／右方（right 必須是 Unit.right_dir()，不是 basis.x）
#   want     外部權重（死亡／趴姿／載具＝0）
func apply(target, head_pos: Vector3, forward: Vector3, right: Vector3,
		want: float, delta: float) -> void:
	active = false
	if not is_ready():
		return
	var w: float = clampf(want, 0.0, 1.0) * p.look_at_strength
	# ---------- 想看哪裡 ----------
	var want_yaw := 0.0
	var want_pitch := 0.0
	has_target = false
	if target != null and w > 0.001 and head_pos != Vector3.ZERO:
		var to: Vector3 = (target as Vector3) - head_pos
		if to.length() > 0.25:            # 目標貼在臉上就別轉了（角度會亂跳）
			var f: Vector3 = forward.normalized()
			var r: Vector3 = right.normalized()
			var flat := Vector3(to.x, 0.0, to.z)
			if flat.length() > 0.01:
				has_target = true
				var fl: Vector3 = flat.normalized()
				# 正 = 角色的左邊。理由見下面 add_world_rotation 的軸向說明。
				want_yaw = -atan2(fl.dot(r), fl.dot(f))
				want_pitch = atan2(to.y, flat.length())
	# 夾限：脖子轉不到 180°。超過範圍就是「看不到」，頭停在極限角
	# （身體要不要跟著轉是 Locomotion 的事，注視不負責轉身）。
	want_yaw = clampf(want_yaw, -deg_to_rad(p.look_yaw_max), deg_to_rad(p.look_yaw_max))
	want_pitch = clampf(want_pitch, -deg_to_rad(p.look_pitch_max), deg_to_rad(p.look_pitch_max))
	if not has_target:
		want_yaw = 0.0
		want_pitch = 0.0

	# ---------- 收斂 ----------
	var k: float = clampf(delta * p.look_speed, 0.0, 1.0)
	if _warm:
		yaw = lerpf(yaw, want_yaw, k)
		pitch = lerpf(pitch, want_pitch, k)
	else:
		yaw = want_yaw
		pitch = want_pitch
		_warm = true
	if absf(yaw) < 0.002 and absf(pitch) < 0.002:
		return

	# ---------- 套到骨頭 ----------
	# 軸向（本專案的角色正面是 +Z，right_dir() = facing × UP）：
	#   繞 UP 轉正角 → 正面往 +X 走 = 角色的**左**（所以 yaw 正 = 往左看）
	#   繞 right_dir 轉正角 → 正面往上抬（所以 pitch 正 = 往上看）
	# ⚠ 這兩個符號是推導出來的，不是試出來的——但推導也會錯，
	#   所以 `-- locochk` 有一條「左右各看一次，頭的世界朝向差值必須等於兩者夾角」
	#   的斷言在守（符號反了會立刻變成負值，測試就會 FAIL）。
	var shares := {
		"Chest": p.look_chest_share,
		"Neck": p.look_neck_share,
		"Head": p.look_head_share,
	}
	var up := Vector3.UP
	var r2: Vector3 = right.normalized()
	for b in CHAIN:
		var s: float = float(shares[b]) * w
		if s <= 0.001:
			continue
		if absf(yaw) > 0.0005:
			_rig.add_world_rotation(b, up, yaw * s)
		if absf(pitch) > 0.0005:
			_rig.add_world_rotation(b, r2, pitch * s)
	active = true


func debug_line() -> String:
	if not is_ready():
		return "注視 關"
	if not active:
		return "注視 待機%s" % ("（有目標）" if has_target else "")
	return "注視 yaw%+.0f° pitch%+.0f°%s" % [
			rad_to_deg(yaw), rad_to_deg(pitch), "" if has_target else "（回正中）"]
