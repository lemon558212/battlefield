# Locomotion.gd — 角色運動狀態機（2026-08-07 動作流暢度升級）。
#
# 職責只有四件，全部與「畫面上看起來像不像真的在走」直接相關：
#   ① 速度積分：加速度／減速度／煞停，取代原本「按下去就全速、放開就 0」
#   ② 轉向：角速度受限的平滑轉身，低速轉得慢（有重量）、高速轉得快（腳能蹬地修正）
#   ③ 步態選擇：idle / walk / run / sprint / crouch_walk，含遲滯與最短停留，不會臨界抖
#   ④ 踏頻同步：把動畫播放倍率鎖在實際速度上 ← **這條才是治滑步的主結構**
#
# ★★關於 ④ 的推導（依專案鐵律 0「物理法則＝真實世界」，不用魔術數字）：
#   動畫是原地踏步（root motion 已被 _strip_root_motion 抽走），位移純由程式給。
#   一個 locomotion 循環＝左右各踏一步＝2 步。所以這支動畫「原生」對應的速度是
#       native = (2 步 / 動畫週期秒) × 單步步幅
#   步幅取真實值（走 0.75m、跑 1.5m、衝刺 2.0m、蹲行 0.62m）。
#   要讓腳不打滑，只需要
#       speed_scale = 實際速度 / native
#   這是從動畫自己的長度算出來的，換一套動作庫也照樣成立，不必手調。
#
# 為什麼不上 AnimationTree/BlendSpace：本專案的姿勢有一大半是程式化寫骨骼
# （_aim_pose 的持槍 IK、趴姿、蹲姿全走 skeleton_updated），AnimationTree 會接管
# 骨骼寫入時序，等於把已驗證的那套推倒重來。踏頻同步 + 交叉淡入拿到的是
# 一樣的視覺結果，風險低一個數量級。這是取捨，不是「做不到」——見報告末尾。
class_name Locomotion
extends RefCounted

const PROFILE := preload("res://scripts/LocomotionProfile.gd")

var p: LocomotionProfile

# ---- 輸出狀態（Unit 與 Debug overlay 都讀這裡）----
var velocity := Vector3.ZERO      # 水平速度（世界座標，y 恆為 0）
var speed := 0.0                  # velocity.length()
var target_speed := 0.0           # 這一幀想要達到的速度
var gait := "idle"                # idle / walk / run / sprint / crouch_walk
var yaw_err := 0.0                # 目前朝向與目標朝向的差（rad）
var angular_speed := 0.0          # 這一幀實際轉了多少（rad/s）
var turn_in_place := false        # true＝角度差太大，先轉身不前進
var cadence_scale := 1.0          # 這一幀套給 AnimationPlayer 的 speed_scale
var grounded := true

var _gait_hold := 0.0             # 目前步態已經維持了多久


func _init(profile: LocomotionProfile = null) -> void:
	p = profile if profile != null else PROFILE.new()


# ---------------------------------------------------------------- 速度
# 朝 dir 加速到 target_spd。dir 必須是水平單位向量。
# 減速用 decel、加速用 accel：真人煞車比起步快，這個不對稱就是「重量感」。
func accelerate(dir: Vector3, target_spd: float, delta: float) -> void:
	target_speed = target_spd
	var want: Vector3 = Vector3(dir.x, 0.0, dir.z) * target_spd
	var rate: float = p.accel if want.length() >= velocity.length() else p.decel
	if not grounded:
		rate *= p.air_control
	velocity = velocity.move_toward(want, rate * delta)
	velocity.y = 0.0
	speed = velocity.length()


# 鬆手滑行（hard=false）或主動收腳煞停（hard=true）
func brake(delta: float, hard := false) -> void:
	target_speed = 0.0
	var rate: float = p.brake_decel if hard else p.decel
	if not grounded:
		rate *= p.air_control
	velocity = velocity.move_toward(Vector3.ZERO, rate * delta)
	speed = velocity.length()


# 立即歸零：只給「死亡／被強制停住／傳送」這種狀態轉換用，不可拿來當停步
func kill_velocity() -> void:
	velocity = Vector3.ZERO
	speed = 0.0
	target_speed = 0.0


# 目前速度需要多長距離才煞得住（公尺）。點擊移動靠這個決定「何時開始收腳」，
# 不然就是等速衝到目的地再瞬停——那正是「像輪子滑出去」的來源。
func braking_distance() -> float:
	return (speed * speed) / (2.0 * maxf(p.brake_decel, 0.01))


# 這一幀的實際位移（公尺）。Unit 拿去累加步伐、餵給貼地。
func frame_move(delta: float) -> Vector3:
	return velocity * delta


# ---------------------------------------------------------------- 轉向
# 角速度受限的平滑轉身，回傳新的 yaw。
# ⚠ 不用 lerp_angle(cur, target, k)：那是「每幀吃掉固定比例」，剩餘角度愈小轉愈慢，
#   大角度時又會第一幀就甩過去一大截——看起來就是「突然轉向」再拖尾。
#   真人轉身是**角速度**受限的，所以這裡限制的是 rad/s。
func step_yaw(cur_yaw: float, target_yaw: float, delta: float) -> float:
	var err: float = wrapf(target_yaw - cur_yaw, -PI, PI)
	yaw_err = err
	_update_turn_gate(err)
	# 速度愈高轉得愈快：跑起來可以用腳蹬地修方向，原地轉身只能靠碎步
	var t: float = clampf(speed / maxf(p.run_speed, 0.01), 0.0, 1.0)
	var rate: float = lerpf(p.turn_rate_slow, p.turn_rate_fast, t)
	# 收尾緩衝：快轉到定位時把角速度收下來，避免「等速轉到剛好然後硬停」
	var ease: float = deg_to_rad(p.turn_ease_deg)
	if absf(err) < ease and ease > 0.0001:
		rate *= maxf(absf(err) / ease, 0.12)
	var step: float = clampf(err, -rate * delta, rate * delta)
	angular_speed = absf(step) / maxf(delta, 0.0001)
	return wrapf(cur_yaw + step, -PI, PI)


# 原地轉身閘門（含遲滯）：角度差大於 turn_in_place_deg 就停下來轉，
# 轉到小於 turn_release_deg 才放行。兩個門檻錯開才不會在臨界值來回抖。
func _update_turn_gate(err: float) -> void:
	var a: float = absf(err)
	if turn_in_place:
		if a < deg_to_rad(p.turn_release_deg):
			turn_in_place = false
	elif a > deg_to_rad(p.turn_in_place_deg):
		turn_in_place = true


# ---------------------------------------------------------------- 步態
# 依**實際速度**挑步態（不是依按鍵、也不是依設定速度）。
# 被牆擋住時實際速度會掉到 0，步態自然回 idle＝不會原地跑步。
# available：Unit.anim_names，缺哪支動作就往下退，不會播到不存在的片段。
func pick_gait(available: Dictionary, crouching: bool, delta: float) -> String:
	_gait_hold += delta
	var want: String = _raw_gait(crouching)
	if want != gait:
		# 最短停留：擋掉 1~2 幀的速度雜訊造成的動畫抽搐
		if _gait_hold >= p.gait_min_hold or want == "idle" or gait == "idle":
			gait = want
			_gait_hold = 0.0
	return _fallback(gait, available)


func _raw_gait(crouching: bool) -> String:
	# 遲滯：往上切用門檻值，往下切要再低 gait_hysteresis，避免臨界來回跳
	var h: float = p.gait_hysteresis
	var idle_th: float = p.idle_speed + (h * 0.4 if gait != "idle" else 0.0)
	if speed < idle_th:
		return "idle"
	if crouching:
		return "crouch_walk"
	var run_th: float = p.walk_to_run - (h if gait in ["run", "sprint"] else 0.0)
	if speed < run_th:
		return "walk"
	var sp_th: float = p.run_to_sprint - (h if gait == "sprint" else 0.0)
	if speed < sp_th:
		return "run"
	return "sprint"


# 動作庫缺片段時的退階（絕不呼叫不存在的動畫）
func _fallback(g: String, available: Dictionary) -> String:
	match g:
		"sprint":
			if available.has("sprint"): return "sprint"
			if available.has("run"): return "run"
			return _fallback("walk", available)
		"run":
			if available.has("run"): return "run"
			if available.has("walk"): return "walk"
			return "idle"
		"walk":
			if available.has("walk"): return "walk"
			if available.has("run"): return "run"
			return "idle"
		"crouch_walk":
			if available.has("crouch_walk"): return "crouch_walk"
			if available.has("crouch"): return "crouch"
			return _fallback("walk", available)
		_:
			return "idle"


# 步態切換該用多長的淡入（秒）。起停要比同族互切慢一點，
# 因為 idle↔run 的姿勢差最大，硬切最容易被看出跳幀。
func blend_time(from_g: String, to_g: String) -> float:
	if from_g == "idle" and to_g != "idle":
		return p.blend_start
	if to_g == "idle" and from_g != "idle":
		return p.blend_stop
	return p.blend_gait


# ---------------------------------------------------------------- 踏頻
# 動畫播放倍率＝實際速度 / 這支動畫的原生速度（推導見檔頭）。
# clip_len＝該片段長度（秒）。回傳 1.0 代表「不知道怎麼算，維持原速」。
func cadence(clip_len: float) -> float:
	if gait == "idle" or clip_len <= 0.01 or speed <= 0.001:
		cadence_scale = 1.0
		return 1.0
	var stride: float = p.stride_of(gait)
	var native: float = (2.0 / clip_len) * stride
	if native <= 0.01:
		cadence_scale = 1.0
		return 1.0
	cadence_scale = clampf(speed / native, p.cadence_min, p.cadence_max)
	return cadence_scale


# 目前步態下、走一步的距離（公尺）。腳步聲與濺水用同一個尺，
# 這樣「動畫的一步」與「聽到的一步」永遠對得上。
func step_length() -> float:
	return maxf(p.stride_of(gait), 0.25)


# 除錯字串（給 Debug overlay）
func debug_line() -> String:
	return "%s spd=%.2f/%.2f cad=%.2f yawErr=%.0f° %s" % [
			gait, speed, target_speed, cadence_scale,
			rad_to_deg(yaw_err), "TURN" if turn_in_place else ""]
