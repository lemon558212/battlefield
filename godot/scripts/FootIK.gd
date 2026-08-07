# FootIK.gd — 腳步貼地 IK（2026-08-07）。
#
# 取代 Unit._legs_to_slope() 的「用高度差硬算屈膝角度」近似法。
# 舊法的問題是它從來沒有量過腳實際在哪：它只量了「骨盆左右 ±17cm 的地面高度差」，
# 然後按一個經驗係數（KNEE_PER_M=46°/m）去彎膝蓋。所以
#   ① 走路擺腿時腳早就不在骨盆正下方了，量錯位置＝修錯腿
#   ② 台階、石頭、單腳踩在坡上這些「兩腳踩在不同東西上」的情況完全處理不了
#   ③ 沒有骨盆升降，落差一大就是腿被拉直硬撐或腳陷進土裡
#
# 真 foot IK 的三件事（順序不能換）：
#   ① 量：讀**動畫算完之後**兩腳踝的實際世界位置，各自往下取地面高度
#   ② 沉骨盆：取兩腳需要的最大下沉量，把骨盆（與掛在 Root 的大腿）一起降下去
#   ③ 解腿：雙骨 IK 把腳踝擺到 max(地面+踝高, 動畫原本的高度)
#      —— 用 max 是關鍵：擺盪中的腳本來就該離地，IK 只負責「不准穿地」與
#         「站立腳必須踩到」，不可以把抬起的腳硬拉回地面（那會變成拖著腳走）。
#
# 鐵律 0 對照：①固體不可互穿（腳不進土）、④站斜坡腳要貼坡面。
class_name FootIK
extends RefCounted

const SIDES := ["L", "R"]

var p: LocomotionProfile
var enabled := true

# ---- 輸出（Debug overlay 讀）----
var weight := 0.0              # 目前實際混合權重（0=完全關閉）
var pelvis_drop := 0.0         # 這一幀骨盆下沉了幾公尺
var slope_deg := 0.0           # 腳下坡度（度）
var active := false            # 這一幀有沒有真的解 IK

var _rig = null                # Retarget 實例（由 Unit 注入）
var _sampler: Callable = Callable()
var _ankle_y := {"L": 0.0, "R": 0.0}    # 平滑後的目標高度
var _warm := false             # 第一次要直接跳到目標，不然開場會看到腳從舊位置滑過去
var _frame := 0                # LOD 計數
# 踝高自動校正：「腳踝骨離地多高」每一系骨架都不一樣（Quaternius 約 2cm、
# tripo 立繪模型約 15cm——後者的腳踝骨其實落在小腿中段）。寫死一個 0.085
# 的結果是：對某些骨架永遠把腳往下壓 6cm、對另一些永遠抬高 6cm。
# 所以第一次執行時就地量一次「這副骨架站在地上時腳踝實際多高」，之後都用它。
var _ankle_off := -1.0
# 安全熔斷：一旦量到荒謬的骨骼座標就永久關閉這個單位的 foot IK 並大聲喊。
# 2026-08-07 血淚：漏判 detached 讓骨盆位移每幀疊加，幾秒內骨架被推到 -15m，
# 蒙皮跟著爆開 → **畫面上人整個不見了**，而日誌一行錯誤都沒有。
# IK 這種「每幀在既有姿勢上疊加」的東西一定要有發散偵測，光靠夾限不夠。
var broken := false
var _detach_checked := false
var _leg_detached := false


func _init(profile: LocomotionProfile) -> void:
	p = profile


func bind(rig, ground_sampler: Callable) -> void:
	_rig = rig
	_sampler = ground_sampler
	_warm = false


func is_ready() -> bool:
	return (not broken) and _rig != null and _sampler.is_valid() and p != null and p.foot_ik_enabled


# 主入口。在 skeleton_updated 內、動畫與其他程式化姿勢都寫完之後呼叫。
#   origin        角色腳底的世界座標（Unit.global_position）
#   forward/right 角色的正面／右方（膝蓋朝向與腳掌對齊要用）
#   want          外部要的權重（趴姿/死亡/離地/載具＝0）
#   cam_dist      到攝影機的距離（做 LOD 用；<0 代表不做 LOD）
func apply(origin: Vector3, forward: Vector3, right: Vector3,
		want: float, delta: float, cam_dist: float = -1.0) -> void:
	active = false
	if not is_ready():
		weight = 0.0
		return
	# 權重要平滑進出：跳躍/趴下的瞬間硬關掉，腳會「啪」一下彈回動畫位置
	weight = move_toward(weight, clampf(want, 0.0, 1.0) * p.foot_ik_strength,
			delta * 4.0)
	if weight <= 0.002:
		_warm = false
		return
	# ---- 效能：遠處的兵降頻／關閉（鐵律：一張圖上會有十幾個單位）----
	_frame += 1
	if cam_dist >= 0.0:
		if cam_dist > p.ik_cull_distance:
			return
		if cam_dist > p.ik_lod_distance and (_frame % maxi(p.ik_lod_interval, 1)) != 0:
			return

	# ---------- ① 量：兩腳踝現在在哪、腳下的地面多高 ----------
	var ank := {}          # 動畫算完的腳踝世界座標
	var gy := {}           # 該腳正下方的地面高度
	for sd in SIDES:
		var a: Vector3 = _rig.leg_end("LowerLeg." + sd, "Foot." + sd)
		if a == Vector3.ZERO:
			return          # 這副骨架沒有腿骨，安靜退出（不是錯誤）
		# ★發散偵測：腳踝不可能離角色原點 3m 以上（人只有 1.75m 高）。
		#   量到就代表骨架已經被推壞，這一幀**什麼都不要碰**，並且永久關閉——
		#   繼續解 IK 只會把壞掉的姿勢再疊一層。
		if absf(a.y - origin.y) > 3.0 or Vector2(a.x - origin.x, a.z - origin.z).length() > 2.0:
			broken = true
			weight = 0.0
			# 診斷要一次給足：光說「發散了」沒辦法判斷是 IK 疊加壞的，
			# 還是這副骨架的 leg_end() 本來就回垃圾值（兩者的修法完全不同）。
			push_error(("[footik] 骨架座標發散，已關閉本單位的 foot IK
"
					+ "  腳踝%s=%s 角色原點=%s 距離=%.2fm
"
					+ "  大腿=%s 小腿=%s 髖=%s
"
					+ "  （若第一幀就發散＝leg_end 對這副骨架失效，不是 IK 疊加造成）")
					% [sd, str(a), str(origin), a.distance_to(origin),
					str(_rig.bone_pos("UpperLeg." + sd)), str(_rig.bone_pos("LowerLeg." + sd)),
					str(_rig.bone_pos("Hips"))])
			return
		ank[sd] = a
		gy[sd] = float(_sampler.call(a))
	# ---- 踝高自動校正（只做一次）----
	# 取「兩腳中較低的那一隻」的離地高度＝這副骨架站立時的踝高。
	# 夾在 2~30cm：超出這個範圍代表量到的是壞資料（例如骨架尺度異常），退回設定值。
	if _ankle_off < 0.0:
		var lo_h: float = minf(float(ank["L"].y) - float(gy["L"]),
				float(ank["R"].y) - float(gy["R"]))
		_ankle_off = clampf(lo_h, 0.02, 0.30) if (lo_h > -0.05 and lo_h < 0.5) else p.ankle_height
	# 腳下坡度（除錯與腳掌對齊用）
	var dh: float = float(gy["L"]) - float(gy["R"])
	slope_deg = rad_to_deg(atan2(absf(dh), maxf(p.hip_half_width * 2.0, 0.01)))

	# ---------- ② 沉骨盆 ----------
	# 站立腳＝比較高的那隻踩得到；另一隻要構到更低的地面，就得靠骨盆下沉。
	# 下沉量＝兩腳地面高度差，夾在 pelvis_drop_max 以內（再深就是懸崖，不該用 IK 硬撐）。
	var lowest: float = minf(float(gy["L"]), float(gy["R"]))
	var highest: float = maxf(float(gy["L"]), float(gy["R"]))
	var need: float = clampf(highest - lowest, 0.0, p.pelvis_drop_max)
	var drop: float = -need * weight
	pelvis_drop = drop
	if not _detach_checked:
		_detach_checked = true
		# 大腿掛在誰身上，決定要不要**另外**補一份位移：
		#   掛在 Root（Quaternius hr_）→ 髖部動它不動，要補
		#   父階是骨盆（tripo）        → 髖部一動它就跟著，再補＝移動兩倍且逐幀累積
		_leg_detached = _rig.is_detached("UpperLeg.L") or _rig.is_detached("UpperLeg.R")
	if absf(drop) > 0.0005:
		_rig.shift_pelvis("Hips", drop, 1.0)
		if _leg_detached:
			for sd in SIDES:
				_rig.shift_pelvis("UpperLeg." + sd, drop, 1.0)

	# ---------- ③ 解腿 ----------
	var pole: Vector3 = forward.normalized()      # 膝蓋朝正前方
	var k: float = clampf(delta * p.foot_ik_smooth, 0.0, 1.0)
	for sd in SIDES:
		var a: Vector3 = ank[sd]
		# 動畫原本的高度（骨盆沉了之後也要跟著沉，否則腳會相對抬起來）
		var anim_y: float = a.y + drop
		var ground_target: float = float(gy[sd]) + _ankle_off
		# ★ max：擺盪中的腳保持動畫高度，站立腳才被釘到地面。
		#   反過來寫成「一律等於地面高度」，走路就變成雙腳貼地平移＝滑步。
		var want_y: float = maxf(ground_target, anim_y)
		if not _warm:
			_ankle_y[sd] = want_y
		else:
			_ankle_y[sd] = lerpf(float(_ankle_y[sd]), want_y, k)
		# 目標高度夾在「角色腳底 ±1.2m」內：腳再怎樣也不會跑到頭頂上或地心裡。
		# 這是第二道防線（第一道是上面的發散偵測）——IK 一旦寫壞就會自我放大。
		var target := Vector3(a.x,
				clampf(float(_ankle_y[sd]), origin.y - 1.2, origin.y + 1.2), a.z)
		_rig.ik_leg("UpperLeg." + sd, "LowerLeg." + sd, "Foot." + sd,
				target, pole, weight)
		# 腳骨本身掛在 Root，不會跟著小腿走——解完要把它放回腳踝，
		# 否則小腿轉了、腳掌還留在原地（畫面上是「腳被扯斷」）。
		# 腳骨若掛在 Root 就不會跟著小腿走，解完要放回腳踝（否則畫面上腳被扯斷）。
		# 父階正常的骨架不必做——它本來就跟著走，多寫一次只是浪費。
		if _leg_detached:
			var solved: Vector3 = _rig.leg_end("LowerLeg." + sd, "Foot." + sd)
			if solved != Vector3.ZERO:
				_rig.place_bone("Foot." + sd, solved, weight)
	_warm = true
	active = true

	# ---------- 腳掌跟著坡面 ----------
	# 上下坡時腳尖要跟著抬/壓，不然腳跟騰空、腳尖插進坡裡。
	# 用「腳前後 ±18cm 的地面高度差」估前後坡度，比取整體法線更貼近腳掌實際踩到的面。
	if p.foot_align_slope > 0.001:
		for sd in SIDES:
			var a: Vector3 = ank[sd]
			var f_h: float = float(_sampler.call(a + forward * 0.18))
			var b_h: float = float(_sampler.call(a - forward * 0.18))
			var pitch: float = atan2(f_h - b_h, 0.36)
			if absf(pitch) < 0.02:
				continue
			_rig.add_world_rotation("Foot." + sd, right.normalized(),
					-pitch * p.foot_align_slope * weight)


func debug_line() -> String:
	if broken:
		return "footIK ★已熔斷（骨架座標曾發散）"
	if not active:
		return "footIK off (w=%.2f)" % weight
	return "footIK w=%.2f pelvis=%.3fm slope=%.0f° 踝高%.3fm" % [
			weight, pelvis_drop, slope_deg, _ankle_off]
