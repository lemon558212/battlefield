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
var _hips: Array = [-1, -1]
var _height_ratio := 1.0

# 只綁目標骨架：遊戲內用模型自帶動畫，不需要來源姿勢，但仍要用 IK/俯仰/握拳這些工具。
func bind(dst: Skeleton3D) -> void:
	_dst = dst

func setup(src: Skeleton3D, dst: Skeleton3D) -> int:
	_src = src
	_dst = dst
	_pairs.clear()
	for s in MAP.keys():
		var si := src.find_bone(s)
		var dname: String = MAP[s]
		var di := dst.find_bone(dname)
		if di < 0 and ALT.has(dname):
			di = dst.find_bone(ALT[dname])
		if si >= 0 and di >= 0:
			_pairs.append([si, di])
			if s == "pelvis":
				_hips = [si, di]
	# 體型比例：以「世界座標」的髖高度換算位移。
	# 不可直接取 .y——FBX 骨架多為 Z 軸向上，取 .y 會得到 0，導致蹲下時髖部不下沉、整個人浮空。
	if _hips[0] >= 0:
		var sh: float = (src.global_transform * src.get_bone_global_rest(_hips[0]).origin).y
		var dh: float = (dst.global_transform * dst.get_bone_global_rest(_hips[1]).origin).y
		if absf(sh) > 0.0001:
			_height_ratio = dh / sh
	return _pairs.size()

func apply() -> void:
	# 兩邊骨架空間可能不同軸向（glTF 為 Y-up、FBX 匯入常帶 -90°X），
	# 故一律換算到世界座標再轉回目標骨架空間，否則差量會套錯軸。
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
		var si: int = _hips[0]
		var di: int = _hips[1]
		var s_xf := _src.global_transform
		var rest_w: Vector3 = s_xf * _src.get_bone_global_rest(si).origin
		var pose_w: Vector3 = s_xf * _src.get_bone_global_pose(si).origin
		var target_w: Vector3 = (_dst.global_transform * _dst.get_bone_global_rest(di).origin) \
			+ (pose_w - rest_w) * _height_ratio
		# 世界 → 目標骨架空間 → 該骨相對父骨的 local
		var in_skel: Vector3 = _dst.global_transform.affine_inverse() * target_w
		var dp := _dst.get_bone_parent(di)
		if dp >= 0:
			in_skel = _dst.get_bone_global_pose(dp).affine_inverse() * in_skel
		_dst.set_bone_pose_position(di, in_skel)

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
	if l1 < 0.0001 or l2 < 0.0001:
		return false
	var to_t: Vector3 = target - a
	var d: float = clampf(to_t.length(), absf(l1 - l2) + 0.001, l1 + l2 - 0.001)
	if to_t.length() < 0.0001:
		return false
	var dir := to_t.normalized()

	# 1) 先讓整條手臂指向目標
	_rotate_bone(ui, Quaternion((c - a).normalized(), dir))
	b = _dst.get_bone_global_pose(li).origin
	c = _dst.get_bone_global_pose(hi).origin

	# 2) 依餘弦定理把肘彎到該有的角度，彎曲平面由 pole 決定
	var want := acos(clampf((l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d), -1.0, 1.0))
	var cur := acos(clampf((b - a).normalized().dot(dir), -1.0, 1.0))
	var axis: Vector3 = dir.cross(b - a)
	if axis.length() < 0.0001:
		axis = dir.cross(pole)
	if axis.length() < 0.0001:
		axis = dir.cross(Vector3.UP)
	if axis.length() < 0.0001:
		return false
	_rotate_bone(ui, Quaternion(axis.normalized(), want - cur))
	b = _dst.get_bone_global_pose(li).origin

	# 2.5) 繞手臂軸旋轉，把肘部轉到極向量那一側。
	# 少了這步，肘會停在數學上任意的一側——外觀就是手臂扭轉一圈、蒙皮塌成細長條。
	var e_perp: Vector3 = (b - a) - dir * (b - a).dot(dir)
	var p_perp: Vector3 = pole - dir * pole.dot(dir)
	if e_perp.length() > 0.0001 and p_perp.length() > 0.0001:
		e_perp = e_perp.normalized()
		p_perp = p_perp.normalized()
		var ang := atan2(e_perp.cross(p_perp).dot(dir), e_perp.dot(p_perp))
		_rotate_bone(ui, Quaternion(dir, ang))
		b = _dst.get_bone_global_pose(li).origin
	c = _dst.get_bone_global_pose(hi).origin

	# 3) 前臂補齊，讓手落在目標
	if (c - b).length() > 0.0001 and (target - b).length() > 0.0001:
		_rotate_bone(li, Quaternion((c - b).normalized(), (target - b).normalized()))
	return true

# 對骨骼疊加一段「骨架空間」的旋轉（換算成該骨相對父骨的 local 姿勢）
func _rotate_bone(bi: int, q: Quaternion) -> void:
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
