# Retarget.gd — 執行期骨骼重定向：把「來源骨架的動畫姿勢」轉印到「目標骨架」。
# 用途：Quaternius 角色包(Humanoid Rig 命名)與 Universal Animation Library(UE 命名)骨名不同，
#       但同為人形，故以「全域姿勢相對於自身 rest 的差量」轉印，不需改動素材或匯入設定。
class_name Retarget
extends RefCounted

# 來源(UAL/UE 命名) -> 目標(Quaternius Humanoid Rig 命名)
const MAP := {
	"pelvis": "Hips",
	"spine_01": "Abdomen",
	"spine_02": "Torso",
	"spine_03": "Chest",
	"neck_01": "Neck",
	"Head": "Head",
	"clavicle_l": "Shoulder.L", "upperarm_l": "UpperArm.L", "lowerarm_l": "LowerArm.L", "hand_l": "Hand.L",
	"clavicle_r": "Shoulder.R", "upperarm_r": "UpperArm.R", "lowerarm_r": "LowerArm.R", "hand_r": "Hand.R",
	"thigh_l": "UpperLeg.L", "calf_l": "LowerLeg.L", "foot_l": "Foot.L",
	"thigh_r": "UpperLeg.R", "calf_r": "LowerLeg.R", "foot_r": "Foot.R",
}

# 同一套 Quaternius 骨架在不同包裡手骨名不同（Hand.R / Wrist.R），找不到就試替代名
const ALT := {"Hand.L": "Wrist.L", "Hand.R": "Wrist.R"}

var _src: Skeleton3D
var _dst: Skeleton3D
var _pairs: Array = []      # [src_idx, dst_idx]
var _detached: Array = []   # [src_idx, dst_idx]：目標骨掛在 Root（不跟著髖部走）→ 位置也要自己補
var _hips: Array = [-1, -1]
var _height_ratio := 1.0
var _ratio_ok := false      # 體型比例必須在「進場景樹後」才量得到（global_transform 才有效）

# 只綁目標骨架：遊戲內用模型自帶動畫，不需要來源姿勢，但仍要用 IK/俯仰/握拳這些工具。
func bind(dst: Skeleton3D) -> void:
	_dst = dst

func setup(src: Skeleton3D, dst: Skeleton3D) -> int:
	_src = src
	_dst = dst
	_pairs.clear()
	_detached.clear()
	_ratio_ok = false
	for s in MAP.keys():
		var si := src.find_bone(s)
		var dname: String = MAP[s]
		var di := dst.find_bone(dname)
		if di < 0 and ALT.has(dname):
			di = dst.find_bone(ALT[dname])
		if si < 0 or di < 0:
			continue
		_pairs.append([si, di])
		if s == "pelvis":
			_hips = [si, di]
		elif _broken_parent(src, dst, si, di):
			# 目標骨架把大腿直接掛在 Root（hr_ 骨架就是這樣）：旋轉照轉沒問題，
			# 但髖部下沉時它不會跟著走 → 蹲下變成「上半身沉下去、腿還站著」。
			# 這類骨頭的位置也要自己補上。
			_detached.append([si, di])
	return _pairs.size()

# 體型比例：以「世界座標」的髖高度換算位移。
# ⚠ 必須等骨架進場景樹後才量：global_transform 在樹外回傳單位矩陣，
#   量到的是骨架空間原始值（此類 FBX 為 100 倍且 Z 軸向上），比例會整個錯。
func _ensure_ratio() -> void:
	if _ratio_ok or _hips[0] < 0 or not _dst.is_inside_tree() or not _src.is_inside_tree():
		return
	var sh: float = (_src.global_transform * _src.get_bone_global_rest(_hips[0]).origin).y
	var dh: float = (_dst.global_transform * _dst.get_bone_global_rest(_hips[1]).origin).y
	if absf(sh) > 0.0001:
		_height_ratio = dh / sh
	_ratio_ok = true

# 把「來源骨相對自身 rest 的世界位移」轉印到目標骨，並換回該骨相對父骨的 local 位置。
func _copy_position(si: int, di: int) -> void:
	var s_xf := _src.global_transform
	var rest_w: Vector3 = s_xf * _src.get_bone_global_rest(si).origin
	var pose_w: Vector3 = s_xf * _src.get_bone_global_pose(si).origin
	var target_w: Vector3 = (_dst.global_transform * _dst.get_bone_global_rest(di).origin) \
		+ (pose_w - rest_w) * _height_ratio
	var in_skel: Vector3 = _dst.global_transform.affine_inverse() * target_w
	var dp := _dst.get_bone_parent(di)
	if dp >= 0:
		in_skel = _dst.get_bone_global_pose(dp).affine_inverse() * in_skel
	_dst.set_bone_pose_position(di, in_skel)

func apply() -> void:
	# 兩邊骨架空間可能不同軸向（glTF 為 Y-up、FBX 匯入常帶 -90°X），
	# 故一律換算到世界座標再轉回目標骨架空間，否則差量會套錯軸。
	_ensure_ratio()
	var s_root := _src.global_basis.get_rotation_quaternion()
	var d_root := _dst.global_basis.get_rotation_quaternion()
	var d_root_inv := d_root.inverse()
	for p in _pairs:
		var si: int = p[0]
		var di: int = p[1]
		var s_rest_w := s_root * _src.get_bone_global_rest(si).basis.get_rotation_quaternion()
		var s_pose_w := s_root * _src.get_bone_global_pose(si).basis.get_rotation_quaternion()
		var d_rest_w := d_root * _dst.get_bone_global_rest(di).basis.get_rotation_quaternion()
		# 目標骨的世界朝向＝來源世界朝向 × (兩者 rest 的固定差)
		var target_w := s_pose_w * s_rest_w.inverse() * d_rest_w
		var target_skel := d_root_inv * target_w
		var dp := _dst.get_bone_parent(di)
		var parent_q := Quaternion.IDENTITY
		if dp >= 0:
			parent_q = _dst.get_bone_global_pose(dp).basis.get_rotation_quaternion()
		_dst.set_bone_pose_rotation(di, parent_q.inverse() * target_skel)
	# 髖部位移（蹲下/跳躍需要）：全程走世界座標，最後再換回目標骨架的 local，
	# 這樣才同時吃得下「軸向不同」與「FBX 單位放大 100 倍」兩件事。
	if _hips[0] >= 0:
		_copy_position(_hips[0], _hips[1])
	# 掛在 Root 的肢體（hr_ 骨架的大腿）：位置不會跟著髖部走，必須一起補，
	# 否則蹲下時只有上半身沉下去、腿還直挺挺站著（2026-07-25 蹲姿失敗的真因）。
	for p in _detached:
		_copy_position(p[0], p[1])

# 解析式雙骨 IK（含極向量約束肘部朝向）。
# CCD 沒有肘部約束，會收斂到「手臂扭轉一圈」的怪解——蒙皮會塌成一條細長怪物（2026-07-25 實測）。
# 此版本先把手臂指向目標，再依 pole 指定的方向把肘彎到正確的解。
func ik_two_bone(upper: String, lower: String, hand: String, target_world: Vector3, pole_world: Vector3) -> bool:
	var ui := _dst.find_bone(upper)
	var li := _dst.find_bone(lower)
	var hi := _dst.find_bone(hand)
	if ui < 0 or li < 0 or hi < 0:
		return false
	var xf := _dst.global_transform
	var to_skel := xf.affine_inverse()
	var target: Vector3 = to_skel * target_world
	var pole: Vector3 = (to_skel.basis * pole_world).normalized()

	var a: Vector3 = _dst.get_bone_global_pose(ui).origin
	var b: Vector3 = _dst.get_bone_global_pose(li).origin
	var c: Vector3 = _dst.get_bone_global_pose(hi).origin
	var l1 := a.distance_to(b)
	var l2 := b.distance_to(c)
	# ⚠⚠ 容差一律用「相對骨長」，不可寫死公尺級常數（2026-07-26 使用者指正
	#   「跑步兩隻手不見」的真因就在這裡）：hr_ 骨架的手臂 rest 長度只有 0.001~0.003
	#   （骨架空間被放大約 1000 倍），寫死的 0.001 等於整條手臂的 33%。
	#   於是餘弦定理的 d 被夾成垃圾值 → 肘角亂算 → 上臂被亂轉到蒙皮塌陷，
	#   畫面上是「手貼在槍上、上臂整條消失」（手還對得上，是因為最後一步又把前臂指回目標）。
	var reach: float = l1 + l2
	if reach < 0.000001:
		return false
	var eps: float = reach * 0.002
	var to_t: Vector3 = target - a
	if to_t.length() < eps:
		return false
	var d: float = clampf(to_t.length(), absf(l1 - l2) + reach * 0.02, reach * 0.98)
	var dir := to_t.normalized()

	# 1) 先讓整條手臂指向目標
	# ⚠⚠ 這裡曾經是「跑步時手臂與武器整個消失」的真兇（使用者 2026-07-27 截圖）：
	#   手臂完全折疊時 c（手）會落回 a（肩）附近，(c-a).normalized() 變成零向量，
	#   Quaternion(零向量, dir) 產出 NaN → 骨骼 global pose 變 NaN →
	#   蒙皮頂點跑到無限遠＝**整條手臂連同掛在手上的槍一起從畫面上消失**（身體還在）。
	#   NaN 一旦寫進骨架就會沿著子骨傳下去，所以退化情況一定要在寫入前擋掉。
	var arm_vec: Vector3 = c - a
	if arm_vec.length() < eps:
		return false
	_rotate_bone(ui, Quaternion(arm_vec.normalized(), dir))
	b = _dst.get_bone_global_pose(li).origin
	c = _dst.get_bone_global_pose(hi).origin

	# 2) 依餘弦定理把肘彎到該有的角度，彎曲平面由 pole 決定
	var want := acos(clampf((l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d), -1.0, 1.0))
	var cur := acos(clampf((b - a).normalized().dot(dir), -1.0, 1.0))
	# 同上：叉積的量級跟骨長成正比，門檻也要相對化
	var axis: Vector3 = dir.cross(b - a)
	if axis.length() < eps * 0.01:
		axis = dir.cross(pole)
	if axis.length() < eps * 0.01:
		axis = dir.cross(Vector3.UP)
	if axis.length() < eps * 0.01:
		return false
	_rotate_bone(ui, Quaternion(axis.normalized(), want - cur))
	b = _dst.get_bone_global_pose(li).origin

	# 2.5) 繞手臂軸旋轉，把肘部轉到極向量那一側。
	# 少了這步，肘會停在數學上任意的一側——外觀就是手臂扭轉一圈、蒙皮塌成細長條。
	var e_perp: Vector3 = (b - a) - dir * (b - a).dot(dir)
	var p_perp: Vector3 = pole - dir * pole.dot(dir)
	if e_perp.length() > eps * 0.01 and p_perp.length() > 0.0001:
		e_perp = e_perp.normalized()
		p_perp = p_perp.normalized()
		var ang := atan2(e_perp.cross(p_perp).dot(dir), e_perp.dot(p_perp))
		_rotate_bone(ui, Quaternion(dir, ang))
		b = _dst.get_bone_global_pose(li).origin
	c = _dst.get_bone_global_pose(hi).origin

	# 3) 前臂補齊，讓手落在目標
	if (c - b).length() > eps * 0.01 and (target - b).length() > eps * 0.01:
		_rotate_bone(li, Quaternion((c - b).normalized(), (target - b).normalized()))
	return true

# 對骨骼疊加一段「骨架空間」的旋轉（換算成該骨相對父骨的 local 姿勢）
func _rotate_bone(bi: int, q: Quaternion) -> void:
	# 最後一道防線：非有限的四元數（NaN/inf）絕不可以寫進骨架——
	# 寫進去之後整條骨鏈的蒙皮會塌陷成看不見，而且不會有任何錯誤訊息。
	if not (is_finite(q.x) and is_finite(q.y) and is_finite(q.z) and is_finite(q.w)):
		return
	var g := _dst.get_bone_global_pose(bi).basis.get_rotation_quaternion()
	var p := _dst.get_bone_parent(bi)
	var pq := Quaternion.IDENTITY
	if p >= 0:
		pq = _dst.get_bone_global_pose(p).basis.get_rotation_quaternion()
	_dst.set_bone_pose_rotation(bi, pq.inverse() * (q * g))

# 手臂 IK（CCD 迭代）：把手骨拉到指定世界座標，用於左手扶槍前握把。
# 免費動作庫只有「手槍」姿勢(雙手併攏)，長槍必須靠 IK 才不會變成單手托著步槍的假動作。
func ik_reach(upper: String, lower: String, hand: String, target_world: Vector3, iterations: int = 4) -> bool:
	var ui := _dst.find_bone(upper)
	var li := _dst.find_bone(lower)
	var hi := _dst.find_bone(hand)
	if ui < 0 or li < 0 or hi < 0:
		return false
	var to_skel := _dst.global_transform.affine_inverse()
	var target: Vector3 = to_skel * target_world
	for _i in iterations:
		for bi in [li, ui]:
			var pivot: Vector3 = _dst.get_bone_global_pose(bi).origin
			var cur: Vector3 = _dst.get_bone_global_pose(hi).origin
			var v1: Vector3 = cur - pivot
			var v2: Vector3 = target - pivot
			if v1.length() < 0.0001 or v2.length() < 0.0001:
				continue
			var swing := Quaternion(v1.normalized(), v2.normalized())
			var g := _dst.get_bone_global_pose(bi).basis.get_rotation_quaternion()
			var pi_ := _dst.get_bone_parent(bi)
			var pq := Quaternion.IDENTITY
			if pi_ >= 0:
				pq = _dst.get_bone_global_pose(pi_).basis.get_rotation_quaternion()
			_dst.set_bone_pose_rotation(bi, pq.inverse() * (swing * g))
	return true

# 在世界座標對單一骨骼疊加一段旋轉，用於瞄準時上半身/頭跟著俯仰。
func add_world_rotation(bone: String, axis_world: Vector3, angle: float) -> void:
	var bi := _dst.find_bone(bone)
	if bi < 0 or is_zero_approx(angle):
		return
	var d_root := _dst.global_basis.get_rotation_quaternion()
	var q := Quaternion(axis_world.normalized(), angle)
	var w := d_root * _dst.get_bone_global_pose(bi).basis.get_rotation_quaternion()
	var target_skel := d_root.inverse() * (q * w)
	var dp := _dst.get_bone_parent(bi)
	var pq := Quaternion.IDENTITY
	if dp >= 0:
		pq = _dst.get_bone_global_pose(dp).basis.get_rotation_quaternion()
	_dst.set_bone_pose_rotation(bi, pq.inverse() * target_skel)

# 讓「骨頭→子骨」的方向對準指定的世界方向（絕對式，不是疊加）。
# ⚠ 疊加式（add_world_rotation）擺靜態姿勢很脆弱：同一幀被呼叫兩次角度就翻倍，
#   實測趴姿的腿轉了 108° 而不是指定的 82°，人就變成腳朝天（2026-07-25）。
#   絕對式重複套用結果不變，姿勢用這個。
func point_bone(bone: String, child: String, dir_world: Vector3, weight: float = 1.0) -> void:
	var bi := _dst.find_bone(bone)
	var ci := _dst.find_bone(child)
	if bi < 0 or ci < 0 or weight <= 0.001:
		return
	var to_skel := _dst.global_transform.affine_inverse().basis
	var dir: Vector3 = (to_skel * dir_world).normalized()
	var a: Vector3 = _dst.get_bone_global_pose(bi).origin
	var b: Vector3 = _dst.get_bone_global_pose(ci).origin
	var cur: Vector3 = (b - a).normalized()
	if cur.length() < 0.0001 or dir.length() < 0.0001:
		return
	var q := Quaternion(cur, dir)
	if weight < 0.999:
		q = Quaternion.IDENTITY.slerp(q, clampf(weight, 0.0, 1.0))
	_rotate_bone(bi, q)

# 把骨頭放到指定的世界座標（絕對式）。掛在 Root 的腿要跟著髖部走就靠這個。
func place_bone(bone: String, pos_world: Vector3, weight: float = 1.0) -> void:
	var bi := _dst.find_bone(bone)
	if bi < 0 or weight <= 0.001:
		return
	var cur_w: Vector3 = _dst.global_transform * _dst.get_bone_global_pose(bi).origin
	var want: Vector3 = cur_w.lerp(pos_world, clampf(weight, 0.0, 1.0))
	var in_skel: Vector3 = _dst.global_transform.affine_inverse() * want
	var dp := _dst.get_bone_parent(bi)
	if dp >= 0:
		in_skel = _dst.get_bone_global_pose(dp).affine_inverse() * in_skel
	_dst.set_bone_pose_position(bi, in_skel)

# 讀骨頭的世界座標（擺完姿勢要量貼地高度用）
func bone_pos(bone: String) -> Vector3:
	var bi := _dst.find_bone(bone)
	if bi < 0:
		return Vector3.ZERO
	return _dst.global_transform * _dst.get_bone_global_pose(bi).origin

# 繞著某個世界座標的樞紐旋轉骨骼：朝向與位置一起轉。
# 趴姿需要這個——hr_ 骨架的大腿掛在 Root，只轉髖部的話腿會留在原地站著，
# 人就變成「上半身趴下、腿還立正」。
func orbit_bone(bone: String, axis_world: Vector3, angle: float, pivot_world: Vector3) -> void:
	var bi := _dst.find_bone(bone)
	if bi < 0 or is_zero_approx(angle):
		return
	var q := Quaternion(axis_world.normalized(), angle)
	# 位置：先換到世界座標繞樞紐轉，再換回相對父骨的 local
	var w: Vector3 = _dst.global_transform * _dst.get_bone_global_pose(bi).origin
	var moved: Vector3 = pivot_world + q * (w - pivot_world)
	var in_skel: Vector3 = _dst.global_transform.affine_inverse() * moved
	var dp := _dst.get_bone_parent(bi)
	if dp >= 0:
		in_skel = _dst.get_bone_global_pose(dp).affine_inverse() * in_skel
	_dst.set_bone_pose_position(bi, in_skel)
	add_world_rotation(bone, axis_world, angle)

# 手指彎曲成握持狀。免費動作庫的手是張開的，不彎手指就會像「手掌貼著槍」而非握住。
const FINGERS := ["Index", "Middle", "Ring", "Pinky"]

func curl_fingers(side: String, axis: int, degrees: float, thumb_degrees: float = 0.0) -> void:
	var ax := Vector3.RIGHT
	if axis == 1:
		ax = Vector3.UP
	elif axis == 2:
		ax = Vector3.BACK
	for i in _dst.get_bone_count():
		var n := _dst.get_bone_name(i)
		if not n.ends_with(side):
			continue
		var deg := 0.0
		for f in FINGERS:
			if n.begins_with(f):
				deg = degrees
				break
		if deg == 0.0 and n.begins_with("Thumb"):
			deg = thumb_degrees
		if deg == 0.0:
			continue
		var rest := _dst.get_bone_rest(i).basis.get_rotation_quaternion()
		_dst.set_bone_pose_rotation(i, rest * Quaternion(ax, deg_to_rad(deg)))

# 擷取「目標骨架被重定向後的姿勢」成一張表：{骨名: local 旋轉} + 髖部位移。
# 用途：蹲姿這種靜態姿勢不必讓每個單位都揹一份動畫來源，算一次快取全體共用。
func capture_pose() -> Dictionary:
	var out := {"rot": {}, "hips": Vector3.ZERO, "hips_bone": ""}
	for p in _pairs:
		var di: int = p[1]
		out["rot"][_dst.get_bone_name(di)] = _dst.get_bone_pose_rotation(di)
	if _hips[1] >= 0:
		out["hips"] = _dst.get_bone_pose_position(_hips[1])
		out["hips_bone"] = _dst.get_bone_name(_hips[1])
	return out

# 把快取的姿勢以 weight 混入目前（動畫產生的）姿勢。weight=0 完全不影響。
func blend_pose(pose: Dictionary, weight: float, with_hips: bool = true) -> void:
	if weight <= 0.001 or _dst == null:
		return
	var w: float = clampf(weight, 0.0, 1.0)
	var rots: Dictionary = pose.get("rot", {})
	for bname in rots.keys():
		var bi := _dst.find_bone(bname)
		if bi < 0:
			continue
		_dst.set_bone_pose_rotation(bi, _dst.get_bone_pose_rotation(bi).slerp(rots[bname], w))
	if not with_hips:
		return
	var hb: String = pose.get("hips_bone", "")
	if hb != "":
		var hi := _dst.find_bone(hb)
		if hi >= 0:
			_dst.set_bone_pose_position(hi, _dst.get_bone_pose_position(hi).lerp(pose["hips"], w))

# 以 rest 為基準，對骨骼施加一段固定角度（手寫姿勢用）。
# 重定向在某些骨架會扭壞，手寫姿勢則完全可控——蹲/趴這種靜態姿勢用這個最穩。
func bend_bone(bone: String, axis: int, degrees: float, weight: float = 1.0) -> void:
	var bi := _dst.find_bone(bone)
	if bi < 0 or weight <= 0.001:
		return
	var ax := Vector3.RIGHT
	if axis == 1:
		ax = Vector3.UP
	elif axis == 2:
		ax = Vector3.BACK
	# ⚠ 必須用「讀出目前姿勢再疊加」的寫法。
	# 直接 set_bone_pose_rotation 寫死 local 姿勢在此時機會被吃掉（動畫仍會蓋回去），
	# 實測完全無效——與有效的 add_world_rotation 對照才發現差別在這裡（2026-07-25）。
	var g := _dst.get_bone_global_pose(bi).basis.get_rotation_quaternion()
	var axis_world := (g * ax).normalized()
	_rotate_bone(bi, Quaternion(axis_world, deg_to_rad(degrees) * clampf(weight, 0.0, 1.0)))

# 姿勢擺完後量「最低的腳骨」離地多少，回傳需要補的高度（正值＝要往上抬）。
# 治「蹲下時腳陷進地面」：不靠猜的固定位移，直接量出來。
func ground_offset(foot_bones: Array) -> float:
	if _dst == null:
		return 0.0
	var lo := INF
	for b in foot_bones:
		var bi := _dst.find_bone(b)
		if bi < 0:
			continue
		lo = minf(lo, (_dst.global_transform * _dst.get_bone_global_pose(bi).origin).y)
	if lo == INF:
		return 0.0
	return -lo

# 算出「小腿末端（腳踝）」的世界位置。
# ⚠ 不可直接讀腳骨：此類 Quaternius 骨架的 Foot 骨父階是 Root（不是 LowerLeg），
#   腳骨不跟著腿動，拿它量高度或當 IK 末端都會得到垃圾數據（2026-07-25 血淚）。
#   改用「rest 空間裡小腿骨→腳骨的向量」換算，與骨架命名/軸向慣例無關。
func leg_end(lower: String, foot: String) -> Vector3:
	var li := _dst.find_bone(lower)
	var fi := _dst.find_bone(foot)
	if li < 0 or fi < 0:
		return Vector3.ZERO
	var shin_local: Vector3 = _dst.get_bone_global_rest(li).affine_inverse() * _dst.get_bone_global_rest(fi).origin
	return _dst.global_transform * (_dst.get_bone_global_pose(li) * shin_local)

# 父子關係健檢：找出「目標骨掛在骨架根部、但來源骨其實在肢體鏈中間」的骨頭。
# hr_ 骨架的 UpperLeg.L/R 就掛在 Root——旋轉照轉沒問題（父骨 Root 不動，反而穩），
# 但位置不會跟著髖部走，所以這種骨頭要另外補位置（見 _detached）。
# 先前的做法是把它整根排除，結果就是「蹲下時腿完全不動」。
func _broken_parent(src: Skeleton3D, dst: Skeleton3D, si: int, di: int) -> bool:
	var sp := src.get_bone_parent(si)
	var dp := dst.get_bone_parent(di)
	if sp < 0 or dp < 0:
		return false
	return dst.get_bone_name(dp) == "Root" and src.get_bone_name(sp) != "root"

# 把指定骨頭的姿勢重置回 rest（用於「IK 前先清乾淨」）。
# ⚠ 為什麼需要：ik_two_bone 是「在當下姿勢上疊加旋轉」。動畫（例如跑步擺臂）本身已經
#   把上臂繞自身軸扭轉了一大角度，IK 再疊上去，最終 local 旋轉極端到蒙皮塌陷——
#   畫面上就是「手臂整條消失、只剩一小截手浮在槍上」（使用者 2026-07-26 指正
#   「跑步兩隻手不見」，實拍發現待機也一樣）。
func reset_bones(names: Array) -> void:
	if _dst == null:
		return
	for n in names:
		var bi: int = _dst.find_bone(String(n))
		if bi < 0:
			continue
		_dst.set_bone_pose_rotation(bi, _dst.get_bone_rest(bi).basis.get_rotation_quaternion())
