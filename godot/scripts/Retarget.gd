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

# 目標骨名的替代慣例。呼叫端（Unit.gd 等）一律用 **Quaternius 名**，
# 由 _bone() 負責翻譯成該骨架實際的名字——呼叫端不必知道模型是哪一系。
#
# ⚠⚠ 2026-08-02：這裡原本只有兩個替代名（Hand.L/Hand.R），所以立繪本人模型
#   （tripo 系，骨名是 Hip / L_Upperarm / L_Clavicle 這種前綴式）接進來時，
#   20 對骨只對上 `Head` **1 對**——動作幾乎完全沒被驅動。而且它不會報錯，
#   看起來就只是「動作怪怪的」，非常難查。
#   三系慣例對照（tripo 骨名由 tripo_han.glb 實際列出的 41 骨確認）：
#     Quaternius(hr_/kk_)  tripo(立繪本人)   Mixamo
#     Hips                 Hip               mixamorig:Hips
#     Abdomen              Waist             mixamorig:Spine
#     UpperArm.L           L_Upperarm        mixamorig:LeftArm
const ALT := {
	"Hips": ["Hip", "mixamorig:Hips"],
	"Abdomen": ["Waist", "mixamorig:Spine"],
	"Torso": ["Spine01", "mixamorig:Spine1"],
	"Chest": ["Spine02", "mixamorig:Spine2"],
	"Neck": ["NeckTwist01", "NeckTwist02", "mixamorig:Neck"],
	"Head": ["mixamorig:Head"],
	"Shoulder.L": ["L_Clavicle", "mixamorig:LeftShoulder"],
	"UpperArm.L": ["L_Upperarm", "mixamorig:LeftArm"],
	"LowerArm.L": ["L_Forearm", "mixamorig:LeftForeArm"],
	"Hand.L": ["Wrist.L", "L_Hand", "mixamorig:LeftHand"],
	"Shoulder.R": ["R_Clavicle", "mixamorig:RightShoulder"],
	"UpperArm.R": ["R_Upperarm", "mixamorig:RightArm"],
	"LowerArm.R": ["R_Forearm", "mixamorig:RightForeArm"],
	"Hand.R": ["Wrist.R", "R_Hand", "mixamorig:RightHand"],
	"UpperLeg.L": ["L_Thigh", "mixamorig:LeftUpLeg"],
	"LowerLeg.L": ["L_Calf", "mixamorig:LeftLeg"],
	"Foot.L": ["L_Foot", "mixamorig:LeftFoot"],
	"UpperLeg.R": ["R_Thigh", "mixamorig:RightUpLeg"],
	"LowerLeg.R": ["R_Calf", "mixamorig:RightLeg"],
	"Foot.R": ["R_Foot", "mixamorig:RightFoot"],
}

# 骨名解析：先照原名找，找不到再試該名的替代慣例。
# 所有對外 API 都走這支，這樣「模型用哪一系骨名」只需要在 ALT 維護一處。
func _bone(bname: String) -> int:
	if _dst == null:
		return -1
	var i := _dst.find_bone(bname)
	if i >= 0:
		return i
	for alt in ALT.get(bname, []):
		i = _dst.find_bone(String(alt))
		if i >= 0:
			return i
	return -1

static var DBG := OS.get_cmdline_user_args().has("ikdbg")

# 每根骨屬於哪一段身體（診斷用：可以只轉印其中一段，二分定位哪一段轉印會壞）
const GROUP := {
	"pelvis": "torso", "spine_01": "torso", "spine_02": "torso",
	"spine_03": "torso", "neck_01": "torso", "Head": "torso",
	"clavicle_l": "arms", "upperarm_l": "arms", "lowerarm_l": "arms", "hand_l": "arms",
	"clavicle_r": "arms", "upperarm_r": "arms", "lowerarm_r": "arms", "hand_r": "arms",
	"thigh_l": "legs", "calf_l": "legs", "foot_l": "legs",
	"thigh_r": "legs", "calf_r": "legs", "foot_r": "legs",
}
# 只有這幾根骨的「方向」能可靠反映 **rest 姿勢**（T-pose 還是垂手）。
# ⚠ clavicle（肩骨走向）、foot（腳掌朝向）、hand（手掌朝向）在不同骨架之間
#   本來就差 45~60°，那是骨架設計差異、不是姿勢差異——拿它們當判準會誤判，
#   把正常運作的 hr_ 骨架也「修」一遍（實測會誤判 2~3 對）。
const ALIGN_BONES := ["upperarm_l", "lowerarm_l", "upperarm_r", "lowerarm_r",
		"thigh_l", "calf_l", "thigh_r", "calf_r"]

# 診斷開關：`-- lookshots rigpart=torso` ＝只轉印軀幹，其餘骨頭留在 rest。
# 空字串＝全部轉印（正常行為）。這是為了定位「哪一段的轉印把身體弄壞」。
static var PART := _arg_part()
# 只在帶 rigpose 參數時印（每幀都印會洗掉整份日誌）
static var _diag_pose := "rigpose" in OS.get_cmdline_user_args()
static func _arg_part() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("rigpart="):
			return a.substr(8)
	return ""

var _src: Skeleton3D
var _dst: Skeleton3D
var _pairs: Array = []      # [src_idx, dst_idx]
var _detached: Array = []   # [src_idx, dst_idx]：目標骨掛在 Root（不跟著髖部走）→ 位置也要自己補
var _hips: Array = [-1, -1]
var _height_ratio := 1.0
var _ratio_ok := false      # 體型比例必須在「進場景樹後」才量得到（global_transform 才有效）
# rest 對齊補正：每對骨一個 Quaternion，把「目標骨的 rest 方向」轉到
# 「來源骨的 rest 方向」，讓差量轉印在同一個基準上進行。見 _ensure_align()。
var _align: Array = []
var _align_ok := false

# 只綁目標骨架：遊戲內用模型自帶動畫，不需要來源姿勢，但仍要用 IK/俯仰/握拳這些工具。
func bind(dst: Skeleton3D) -> void:
	_dst = dst

func setup(src: Skeleton3D, dst: Skeleton3D) -> int:
	_src = src
	_dst = dst
	_pairs.clear()
	_detached.clear()
	_ratio_ok = false
	var missing: Array = []
	for s in MAP.keys():
		var si := src.find_bone(s)
		var dname: String = MAP[s]
		var di := dst.find_bone(dname)
		if di < 0:
			# ALT 是**陣列**（一個 Quaternius 名可能對應多系慣例），要逐個試。
			# ⚠ 舊寫法 `dst.find_bone(ALT[dname])` 只吃單一字串，改成陣列後
			#   若不同步修這裡，會變成「永遠找不到替代名」＝比原本更糟。
			for alt in ALT.get(dname, []):
				di = dst.find_bone(String(alt))
				if di >= 0:
					break
		if si < 0 or di < 0:
			if si >= 0:
				missing.append(dname)      # 來源有、目標找不到＝骨名慣例沒收錄
			continue
		_pairs.append([si, di, String(GROUP.get(s, "")), String(s)])
		if s == "pelvis":
			_hips = [si, di]
		elif _broken_parent(src, dst, si, di):
			# 目標骨架把大腿直接掛在 Root（hr_ 骨架就是這樣）：旋轉照轉沒問題，
			# 但髖部下沉時它不會跟著走 → 蹲下變成「上半身沉下去、腿還站著」。
			# 這類骨頭的位置也要自己補上。
			_detached.append([si, di])
	# ★★不可靜默：對上幾對骨決定了「動作到底有沒有被驅動」。
	#   2026-08-02 實測 tripo_han.glb 只對上 1 對（只有 Head 同名），
	#   而它照樣安靜地跑完——畫面上是「動作怪怪的」，完全看不出重定向失敗了。
	#   人形骨架至少該對上軀幹＋四肢，少於 12 對一定是骨名慣例沒收錄。
	if _pairs.size() < 12:
		push_error("[rig] 重定向只對上 %d/%d 對骨，動作不會正確播放。"
				% [_pairs.size(), MAP.size()]
				+ "　目標骨架找不到這些骨：%s ← 把它們的實際骨名補進 Retarget.ALT" % str(missing))
	return _pairs.size()

# 這根骨的「骨頭指向」（rest，骨架空間單位向量）。
# 用最遠的子骨當方向：tripo 的上臂同時有 L_Forearm 與兩根 Twist 子骨，
# 取「第一個」子骨可能拿到 Twist（方向不對），取最遠的才是真正的骨幹方向。
# 末端骨（手、腳）沒有子骨，回零向量＝不做對齊。
func _bone_dir_rest(sk: Skeleton3D, bi: int) -> Vector3:
	var o: Vector3 = sk.get_bone_global_rest(bi).origin
	var best := Vector3.ZERO
	var best_d := 0.0
	for ci in sk.get_bone_count():
		if sk.get_bone_parent(ci) != bi:
			continue
		var v: Vector3 = sk.get_bone_global_rest(ci).origin - o
		var d: float = v.length()
		if d > best_d:
			best_d = d
			best = v
	return best.normalized() if best_d > 0.0001 else Vector3.ZERO

# ★★rest 對齊（2026-08-02）——立繪本人模型能不能動起來的關鍵。
#
# 差量轉印的語意是「來源骨相對**自己的 rest** 轉了多少，目標骨就從**自己的 rest**
# 轉同樣多」。它隱含一個前提：兩邊的 rest 是**同一個姿勢**。
# hr_ 骨架剛好也是 T-pose，所以這個前提一直成立、從沒暴露過。
#
# 立繪本人模型（tripo）打破了它——實測上臂 rest 朝向：
#     UAL(動作來源)：[1.00, 0.00, -0.02]  ＝沿 +X，手臂水平外伸（T-pose）
#     tripo_han    ：[-0.01, -0.96, -0.27] ＝沿 -Y，手臂**垂下**
# UAL 的 idle 手臂相對 T-pose 轉了約 -75°（放下來），套到「本來就垂著」的
# tripo rest 上就是再往下 75° → 手臂穿過身體、纏成一團（實拍證實）。
#
# 所以轉印前要先把目標骨的 rest 方向對齊到來源骨的 rest 方向，
# 兩邊回到同一個基準，再套變化量。對 rest 相同的骨架（hr_）這個補正
# 自動退化成單位四元數，因此不會動到現有角色的行為。
# ⚠ 必須等骨架進場景樹後才算：get_bone_global_rest 本身在樹外可用，
#   但兩邊骨架空間的軸向要靠 global_basis 才能對齊（tripo 是 Z-up、UAL 是 Y-up）。
func _ensure_align() -> void:
	if _align_ok or _src == null or _dst == null:
		return
	if not _dst.is_inside_tree() or not _src.is_inside_tree():
		return
	var s_root := _src.global_basis.orthonormalized().get_rotation_quaternion()
	var d_root := _dst.global_basis.orthonormalized().get_rotation_quaternion()
	_align.clear()
	var aligned := 0
	var max_deg := 0.0
	for p in _pairs:
		var q := Quaternion.IDENTITY
		# 只有四肢主要骨的方向能反映 rest 姿勢（見 ALIGN_BONES）
		if p.size() > 3 and not (String(p[3]) in ALIGN_BONES):
			_align.append(q)
			continue
		var sd: Vector3 = _bone_dir_rest(_src, p[0])
		var dd: Vector3 = _bone_dir_rest(_dst, p[1])
		if sd.length() > 0.0001 and dd.length() > 0.0001:
			# 兩個方向都換到世界座標再求最短弧（骨架空間軸向不同，不可直接比）
			var sw: Vector3 = (s_root * sd).normalized()
			var dw: Vector3 = (d_root * dd).normalized()
			var deg: float = rad_to_deg(acos(clampf(sw.dot(dw), -1.0, 1.0)))
			max_deg = maxf(max_deg, deg)
			# ⚠⚠ 門檻必須夠大（2026-08-02）：要區分兩件不同的事——
			#   ① 骨頭方向的**小差異**（肩寬、四肢比例不同，通常十幾度以內）
			#      ＝正常的骨架差異，差量法本來就吃得下，**不可以動**。
			#      hr_ 骨架有 15~17 對骨落在這一類，補正它們會破壞現有角色的動作。
			#   ② rest **姿勢根本不同**（T-pose 對垂手，接近 90°）＝差量法的前提破了，
			#      必須對齊。立繪本人模型的手臂就是這一類。
			#   45° 落在兩者之間有很大的餘裕（實測 ① 最大約 17°、② 約 76°）。
			if deg > 45.0:
				q = Quaternion(dw, sw)      # 把目標 rest 方向轉到來源 rest 方向
				aligned += 1
		_align.append(q)
	_align_ok = true
	# 診斷（2026-08-05，追「上身前傾 30~45°」）：把**每一對骨**的 rest 方向差都印出來，
	# 不只印最大值。因為 ALIGN_BONES 只補正四肢，軀幹那幾根若也有大角度差，
	# 差量轉印就會把差額一路累到上半身——但舊日誌只印「4/20 對需要補正」，
	# 看不出軀幹到底差多少，等於把最關鍵的那段藏起來了。
	if DBG or aligned > 0:
		for pi2 in _pairs.size():
			var p2: Array = _pairs[pi2]
			var sd2: Vector3 = _bone_dir_rest(_src, p2[0])
			var dd2: Vector3 = _bone_dir_rest(_dst, p2[1])
			if sd2.length() < 0.0001 or dd2.length() < 0.0001:
				continue
			var sw2: Vector3 = (s_root * sd2).normalized()
			var dw2: Vector3 = (d_root * dd2).normalized()
			var dg: float = rad_to_deg(acos(clampf(sw2.dot(dw2), -1.0, 1.0)))
			var seg: String = String(p2[2]) if p2.size() > 2 else "?"
			var bn: String = String(p2[3]) if p2.size() > 3 else "?"
			print("[rigdiff] %-10s %-12s rest 方向差 %6.1f°%s"
					% [seg, bn, dg, "  ← 有補正" if (bn in ALIGN_BONES and dg > 45.0) else ""])
	if DBG or aligned > 0:
		print("[rig] rest 對齊：%d/%d 對骨需要補正（>45°），最大方向差 %.1f°"
				% [aligned, _pairs.size(), max_deg])

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
	_ensure_align()      # rest 姿勢不同的骨架要先對齊，否則變化量會被套兩次
	# 顯式 orthonormalized：basis 帶縮放時取旋轉必須先正規化。
	# （Godot 的 get_rotation_quaternion() 內部已經會做，所以這行是保險而非修正——
	#  2026-08-02 實測加了它對立繪模型的扭曲**沒有改善**，別誤以為這是那個問題的解。）
	var s_root := _src.global_basis.orthonormalized().get_rotation_quaternion()
	var d_root := _dst.global_basis.orthonormalized().get_rotation_quaternion()
	var d_root_inv := d_root.inverse()
	for pi in _pairs.size():
		var p: Array = _pairs[pi]
		# 診斷（rigpart=torso,arms）：只轉印指定的身體段，其餘留在 rest。
		# ⚠ 單獨測一段會有假象：手臂轉到世界絕對朝向、軀幹卻留在 rest，
		#   本來就會不自然。所以要能同時指定多段（逗號分隔）才能分辨真偽。
		if PART != "" and p.size() > 2 and not (String(p[2]) in PART.split(",")):
			continue
		var si: int = p[0]
		var di: int = p[1]
		var s_rest_w := s_root * _src.get_bone_global_rest(si).basis.get_rotation_quaternion()
		var s_pose_w := s_root * _src.get_bone_global_pose(si).basis.get_rotation_quaternion()
		var d_rest_w := d_root * _dst.get_bone_global_rest(di).basis.get_rotation_quaternion()
		# ★rest 對齊補正：先把目標骨的 rest **姿勢**擺到與來源同一基準，
		#   再套變化量。兩邊 rest 姿勢相同時 _align 是單位四元數＝完全等於舊行為。
		#   （沒有這一步，UAL「從 T-pose 放下手臂」的 -75° 會套在「本來就垂手」的
		#    tripo rest 上，手臂穿過身體——見 _ensure_align 的說明。）
		var d_rest_aligned := d_rest_w
		if _align_ok and pi < _align.size():
			d_rest_aligned = (_align[pi] as Quaternion) * d_rest_w
		# 目標骨的世界朝向＝來源世界朝向 × (兩者 rest 的固定差)
		var target_w := s_pose_w * s_rest_w.inverse() * d_rest_aligned
		var target_skel := d_root_inv * target_w
		var dp := _dst.get_bone_parent(di)
		var parent_q := Quaternion.IDENTITY
		if dp >= 0:
			parent_q = _dst.get_bone_global_pose(dp).basis.get_rotation_quaternion()
		_dst.set_bone_pose_rotation(di, parent_q.inverse() * target_skel)
		# 診斷（2026-08-05）：印出**這根骨實際被轉了多少、往哪邊倒**。
		# rest 方向差（_ensure_align 那組）講的是「兩邊 rest 差多少」；
		# 這裡講的是「轉印之後相對自己的 rest 轉了多少」——前傾是後者造成的。
		# 兩個數字要分開看才追得下去。
		if _diag_pose and p.size() > 3 and String(p[2]) == "torso":
			var d_up: Vector3 = (d_rest_w * Vector3.UP).normalized()
			var t_up: Vector3 = (target_w * Vector3.UP).normalized()
			var turn: float = rad_to_deg(acos(clampf(d_up.dot(t_up), -1.0, 1.0)))
			var lean: float = rad_to_deg(asin(clampf(t_up.z - d_up.z, -1.0, 1.0)))
			print("[rigpose] %-12s 轉了 %5.1f 度（前後傾變化 %+5.1f 度，正=往前倒）"
					% [String(p[3]), turn, lean])
	# 診斷（rigpose）：印出**最終姿勢**下「骨盆→頭」這條線的傾角。
	# ⚠ 這是唯一能回答「上身到底有沒有前傾」的數字——前面那些（rest 方向差、
	#   每根骨轉了幾度）都只講局部。眼睛看渲染圖會被大衣輪廓與鏡頭角度騙。
	if _diag_pose:
		var hi := _bone("Hips")
		var he := _bone("Head")
		# ⚠ 找不到就要喊：tripo 的骨叫 Hip 不是 Hips，別名沒對上就會**靜默跳過**，
		#   於是「所有角色都沒前傾」這個結論其實漏掉了唯一要驗的那個角色。
		if hi < 0 or he < 0:
			print("[rigtilt] ⚠ 量不到（Hips=%d Head=%d）骨架=%s，前三根骨：%s/%s/%s"
					% [hi, he, _dst.name,
					_dst.get_bone_name(0) if _dst.get_bone_count() > 0 else "-",
					_dst.get_bone_name(1) if _dst.get_bone_count() > 1 else "-",
					_dst.get_bone_name(2) if _dst.get_bone_count() > 2 else "-"])
		if hi >= 0 and he >= 0:
			var d_rootb := _dst.global_basis.orthonormalized().get_rotation_quaternion()
			var pv: Vector3 = d_rootb * _dst.get_bone_global_pose(hi).origin
			var hv: Vector3 = d_rootb * _dst.get_bone_global_pose(he).origin
			var v: Vector3 = hv - pv
			if v.length() > 0.0001:
				print("[rigtilt] %s：骨盆→頭 與垂直夾角 %.1f 度，前後傾 %.1f 度（正=往前倒）"
						% [_dst.get_bone_name(hi) + "→" + _dst.get_bone_name(he)
						+ "（骨數 %d）" % _dst.get_bone_count(),
						rad_to_deg(v.normalized().angle_to(Vector3.UP)),
						rad_to_deg(atan2(v.z, v.y))])
	# ⚠⚠ 位移轉印只對 Quaternius 骨架做（2026-08-02）。
	#   旋轉走「相對自身 rest 的差量」，跨骨架相對安全；但**位移**依賴
	#   _height_ratio 與兩邊 rest 的幾何比例，是最吃骨架結構的一步。
	#   立繪本人模型（tripo 系：Hip→Pelvis→L_Thigh）實測會被搬成
	#   「上下半身像被拆開、整個人斜躺」——而且骨名 20/20 全對上、日誌全乾淨。
	#   `_broken_parent` 也是照 hr_ 的「大腿掛在 Root」結構寫的，對 tripo 階層會誤判。
	#   在位移轉印支援多骨架系之前，別系骨架只轉印旋轉（蹲姿改由手寫姿勢處理）。
	if rig_kind() == "quaternius":
		# 髖部位移（蹲下/跳躍需要）：全程走世界座標，最後再換回目標骨架的 local，
		# 這樣才同時吃得下「軸向不同」與「FBX 單位放大 100 倍」兩件事。
		if _hips[0] >= 0:
			_copy_position(_hips[0], _hips[1])
		# 掛在 Root 的肢體（hr_ 骨架的大腿）：位置不會跟著髖部走，必須一起補，
		# 否則蹲下時只有上半身沉下去、腿還直挺挺站著（2026-07-25 蹲姿失敗的真因）。
		for p in _detached:
			_copy_position(p[0], p[1])

# 解析式雙骨 IK。
#
# ★★2026-07-27 重寫（使用者第四輪「手臂與武器不見」的真因）：
#   舊版是「疊加式」——① 把整條手臂指向目標 ② 用餘弦定理彎肘 ③ **繞手臂軸把肘轉到極向量側**
#   ④ 前臂補齊。骨頭數字全部是對的（實測骨長不變、手誤差 0.00000、無縮放），
#   但畫面上手臂是一根細針、上臂整段不見。
#   真因是**線性混合蒙皮的 candy-wrapper 塌陷**：步驟 ③ 那一下最多繞骨軸扭 180°，
#   而父骨（Shoulder）沒有跟著扭 → 上臂靠近肩膀那圈頂點在「肩的朝向」與「上臂的朝向」
#   之間做線性內插，兩者相差 180° 時內插結果全部縮到骨軸上＝肉沒了。
#   ⚠ 教訓：骨骼數值正確 ≠ 蒙皮正確。驗 IK 一定要看**渲染出來的圖**，
#     量骨長／手誤差在這種錯誤下 100% 通過。
#
# 現版是「解析式」：直接算出肘該在的座標，再對上臂、前臂各下**一次最小扭轉的擺動**
#   （`Quaternion(from, to)` 本身就是最短弧＝零額外扭轉），全程不繞骨軸旋轉，
#   所以不可能再產生 candy-wrapper。
#
# `shoulder`/`shoulder_k`：讓肩（鎖骨）骨分攤一部分擺動。
#   即使是純擺動，只要上臂相對肩骨轉了接近 180°，肩關節那一圈的蒙皮頂點就會在
#   兩個相反朝向之間做線性內插 → 平均起來長度趨近 0，整段肉塌成一片破碎的薄片
#   （2026-07-27 實拍：右臂修好後左臂仍是一片鋸齒狀薄板，因為左臂要從 rest 的
#   「往左外側」橫越到槍的前護木，擺動角遠大於右臂）。
#   人真的做這動作時肩膀本來就會跟著轉，所以把一部分角度交給肩骨既治病又更真實。
func ik_two_bone(upper: String, lower: String, hand: String, target_world: Vector3,
		pole_world: Vector3, shoulder: String = "", shoulder_k: float = 0.0) -> bool:
	var ui := _bone(upper)
	var li := _bone(lower)
	var hi := _bone(hand)
	if ui < 0 or li < 0 or hi < 0:
		return false
	var xf := _dst.global_transform
	var to_skel := xf.affine_inverse()
	var target: Vector3 = to_skel * target_world
	var pole: Vector3 = (to_skel.basis * pole_world).normalized()

	# 0) 肩骨先分攤：以「肩→手」轉到「肩→目標」所需的擺動，取 shoulder_k 比例套在肩骨上。
	if shoulder != "" and shoulder_k > 0.001:
		var sh_i := _bone(shoulder)
		if sh_i >= 0:
			var a0: Vector3 = _dst.get_bone_global_pose(ui).origin
			var c0: Vector3 = _dst.get_bone_global_pose(hi).origin
			var from0: Vector3 = c0 - a0
			var to0: Vector3 = target - a0
			if from0.length() > 0.000001 and to0.length() > 0.000001:
				var q0 := Quaternion(from0.normalized(), to0.normalized())
				_rotate_bone(sh_i, Quaternion.IDENTITY.slerp(q0, clampf(shoulder_k, 0.0, 1.0)))

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

	# 1) 算出肘該在的世界（骨架空間）座標。
	#    餘弦定理給「上臂與 dir 的夾角 want」，彎曲平面由極向量在垂直於 dir 的分量決定。
	var want := acos(clampf((l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d), -1.0, 1.0))
	var p_perp: Vector3 = pole - dir * pole.dot(dir)
	if p_perp.length() < 0.0001:
		# 極向量與手臂共線＝彎曲平面沒定義，隨便取一個與 dir 垂直的方向，別讓解爆掉
		p_perp = dir.cross(Vector3.UP)
		if p_perp.length() < 0.0001:
			p_perp = dir.cross(Vector3.RIGHT)
	p_perp = p_perp.normalized()
	var elbow: Vector3 = a + dir * (l1 * cos(want)) + p_perp * (l1 * sin(want))

	# 2) 上臂：從「目前肩→肘方向」擺到「肩→目標肘方向」，最短弧＝不帶額外扭轉。
	#    ⚠ 退化保護：手臂完全折疊時 b 會落回 a，零向量進 Quaternion 會產出 NaN，
	#      NaN 一旦寫進骨架就沿子骨傳下去，畫面上是整條手臂連同槍一起消失。
	var up_cur: Vector3 = b - a
	if up_cur.length() < eps * 0.01:
		return false
	_rotate_bone(ui, Quaternion(up_cur.normalized(), (elbow - a).normalized()))
	b = _dst.get_bone_global_pose(li).origin
	c = _dst.get_bone_global_pose(hi).origin

	# 3) 前臂：同樣一次最小扭轉的擺動，把手擺到目標
	var lo_cur: Vector3 = c - b
	var lo_want: Vector3 = target - b
	if lo_cur.length() > eps * 0.01 and lo_want.length() > eps * 0.01:
		_rotate_bone(li, Quaternion(lo_cur.normalized(), lo_want.normalized()))
	if DBG:
		var a2: Vector3 = _dst.get_bone_global_pose(ui).origin
		var b2: Vector3 = _dst.get_bone_global_pose(li).origin
		var c2: Vector3 = _dst.get_bone_global_pose(hi).origin
		var sc_u: Vector3 = _dst.get_bone_global_pose(ui).basis.get_scale()
		var sc_l: Vector3 = _dst.get_bone_global_pose(li).basis.get_scale()
		print("[ik] %s l1=%.5f l2=%.5f |to_t|=%.5f d=%.5f want=%.1f | after l1=%.5f l2=%.5f err=%.5f scaleU=%s scaleL=%s"
				% [upper, l1, l2, to_t.length(), d, rad_to_deg(want),
				a2.distance_to(b2), b2.distance_to(c2), c2.distance_to(target), sc_u, sc_l])
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
	var ui := _bone(upper)
	var li := _bone(lower)
	var hi := _bone(hand)
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
	var bi := _bone(bone)
	# 診斷（rigpose）：印出「要求哪根骨 → 實際找到哪根 → 轉幾度」。
	# ⚠ 這類「靠別名表找骨頭」的呼叫在跨骨架時最危險：找不到就靜默 return
	#   （姿勢整段消失），或找到**別的骨**（轉錯地方）。兩種都不會有錯誤訊息。
	if _diag_pose:
		print("[rigrot] 要求 %-10s → %s，角度 %.1f 度"
				% [bone, ("找不到" if bi < 0 else _dst.get_bone_name(bi)), rad_to_deg(angle)])
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
	var bi := _bone(bone)
	var ci := _bone(child)
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
	var bi := _bone(bone)
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
	var bi := _bone(bone)
	if bi < 0:
		return Vector3.ZERO
	return _dst.global_transform * _dst.get_bone_global_pose(bi).origin

# 讀骨頭在世界座標的某一個軸（0=X 1=Y 2=Z）。
# 頭部注視的驗收要量「頭到底轉去哪」，而 bone_pos 只給位置——頭轉了 60 度
# 位置幾乎不動，光看座標會以為什麼事都沒發生（本專案的假通過清單裡已經有
# 「180° 轉向測試根本沒轉、斷言照樣 OK」這一筆）。
func bone_axis(bone: String, axis: int) -> Vector3:
	var bi := _bone(bone)
	if bi < 0:
		return Vector3.ZERO
	var b: Basis = (_dst.global_transform * _dst.get_bone_global_pose(bi)).basis
	var v: Vector3 = b[clampi(axis, 0, 2)]
	return v.normalized() if v.length() > 0.0001 else Vector3.ZERO

# 繞著某個世界座標的樞紐旋轉骨骼：朝向與位置一起轉。
# 趴姿需要這個——hr_ 骨架的大腿掛在 Root，只轉髖部的話腿會留在原地站著，
# 人就變成「上半身趴下、腿還立正」。
func orbit_bone(bone: String, axis_world: Vector3, angle: float, pivot_world: Vector3) -> void:
	var bi := _bone(bone)
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
# 這具骨架屬於哪一系命名慣例。用**特徵骨名**判斷（內容決定），不看檔名——
# 檔名判斷在本專案已經害過一次（見 Unit._forward_fix 的註解）。
func rig_kind() -> String:
	if _dst == null:
		return "?"
	if _dst.find_bone("L_Upperarm") >= 0 or _dst.find_bone("L_Thigh") >= 0:
		return "tripo"
	if _dst.find_bone("mixamorig:Hips") >= 0:
		return "mixamo"
	if _dst.find_bone("UpperArm.L") >= 0 or _dst.find_bone("Hips") >= 0:
		return "quaternius"
	return "?"

func capture_pose() -> Dictionary:
	# ★★記下「這張姿勢表是從哪一系骨架擷取的」（2026-08-02）。
	#   骨骼旋轉值是相對**該骨架自己的 rest** 算出來的，跨骨架直接套用就是扭曲。
	#   骨名可以映射（_bone 做得到），旋轉值不行——這是兩件不同的事。
	#   實例：hr_ 骨架的蹲姿表套到立繪本人模型（tripo）上，整個人扭成一團。
	var out := {"rot": {}, "hips": Vector3.ZERO, "hips_bone": "", "rig": rig_kind()}
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
	# ⚠⚠ 跨骨架不可套用（2026-08-02）：旋轉值是相對來源骨架的 rest 算的。
	#   `_bone()` 會成功把骨名對上，但值本身是別人的——結果是整個人扭成一團
	#   （立繪本人模型實測）。骨名映射 ≠ 姿勢可移植，這兩件事必須分開。
	#   同系才套；不同系就跳過，交給呼叫端用 bend_bone 那類「以自身 rest 為基準」的手法。
	var src_rig: String = String(pose.get("rig", ""))
	if src_rig != "" and src_rig != rig_kind():
		return
	var w: float = clampf(weight, 0.0, 1.0)
	var rots: Dictionary = pose.get("rot", {})
	for bname in rots.keys():
		var bi := _bone(bname)
		if bi < 0:
			continue
		_dst.set_bone_pose_rotation(bi, _dst.get_bone_pose_rotation(bi).slerp(rots[bname], w))
	if not with_hips:
		return
	var hb: String = pose.get("hips_bone", "")
	if hb != "":
		var hi := _bone(hb)
		if hi >= 0:
			_dst.set_bone_pose_position(hi, _dst.get_bone_pose_position(hi).lerp(pose["hips"], w))

# 以 rest 為基準，對骨骼施加一段固定角度（手寫姿勢用）。
# 重定向在某些骨架會扭壞，手寫姿勢則完全可控——蹲/趴這種靜態姿勢用這個最穩。
func bend_bone(bone: String, axis: int, degrees: float, weight: float = 1.0) -> void:
	if _diag_pose:
		var bi0 := _bone(bone)
		print("[rigrot] bend %-10s → %s，軸 %d、角度 %.1f 度 ×%.2f"
				% [bone, ("找不到" if bi0 < 0 else _dst.get_bone_name(bi0)), axis, degrees, weight])
	var bi := _bone(bone)
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
		var bi := _bone(b)
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
	var li := _bone(lower)
	var fi := _bone(foot)
	if li < 0 or fi < 0:
		return Vector3.ZERO
	var shin_local: Vector3 = _dst.get_bone_global_rest(li).affine_inverse() * _dst.get_bone_global_rest(fi).origin
	return _dst.global_transform * (_dst.get_bone_global_pose(li) * shin_local)

# 腿部雙骨 IK（2026-08-07，foot IK 用）。
# 與 ik_two_bone 的唯一差別，也是為什麼非得另寫一支：**末端不可以讀 Foot 骨的位置**。
# 此類 Quaternius 骨架的 Foot 掛在 Root，`get_bone_global_pose(foot).origin` 完全不跟著
# 腿動（見上面 leg_end 的註解）。拿它當 IK 末端，餘弦定理的 l2 會是一個固定的垃圾值，
# 解出來的膝角每一幀都一樣——看起來就是「IK 沒作用」。這裡一律用 leg_end() 當末端。
#
# target_world＝腳踝該去的世界座標；pole_world＝膝蓋該朝的世界方向（一般是角色正面）。
# weight＜1 時把目標往「目前腳踝位置」拉回，用來做 IK 淡入淡出（跳躍/趴姿要關掉）。
# 回傳 false＝這副骨架沒有這些骨頭或姿勢退化，呼叫端要能安靜略過。
func ik_leg(upper: String, lower: String, foot: String, target_world: Vector3,
		pole_world: Vector3, weight: float = 1.0) -> bool:
	var ui := _bone(upper)
	var li := _bone(lower)
	var fi := _bone(foot)
	if ui < 0 or li < 0 or fi < 0 or weight <= 0.001:
		return false
	var to_skel: Transform3D = _dst.global_transform.affine_inverse()
	var a: Vector3 = _dst.get_bone_global_pose(ui).origin
	var b: Vector3 = _dst.get_bone_global_pose(li).origin
	var c: Vector3 = to_skel * leg_end(lower, foot)
	var l1: float = a.distance_to(b)
	var l2: float = b.distance_to(c)
	var reach: float = l1 + l2
	if reach < 0.000001:
		return false
	# 容差一律用相對骨長（與 ik_two_bone 同一條教訓：hr_ 骨架的骨長只有 0.001 量級，
	# 寫死的公尺級常數會把整條腿判成退化）
	var eps: float = reach * 0.002
	var target: Vector3 = to_skel * target_world
	if weight < 0.999:
		target = c.lerp(target, clampf(weight, 0.0, 1.0))
	var to_t: Vector3 = target - a
	if to_t.length() < eps:
		return false
	# 夾在「可及範圍」內：超伸會把腿拉成一直線再繼續拉，蒙皮會塌
	var d: float = clampf(to_t.length(), absf(l1 - l2) + reach * 0.02, reach * 0.985)
	var dir: Vector3 = to_t.normalized()
	var want: float = acos(clampf((l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d), -1.0, 1.0))
	var pole: Vector3 = (to_skel.basis * pole_world).normalized()
	var p_perp: Vector3 = pole - dir * pole.dot(dir)
	if p_perp.length() < 0.0001:
		p_perp = dir.cross(Vector3.UP)
		if p_perp.length() < 0.0001:
			p_perp = dir.cross(Vector3.RIGHT)
	p_perp = p_perp.normalized()
	var knee: Vector3 = a + dir * (l1 * cos(want)) + p_perp * (l1 * sin(want))
	# ① 大腿：擺到「髖→膝」該有的方向
	var up_cur: Vector3 = b - a
	if up_cur.length() < eps * 0.01:
		return false
	_rotate_bone(ui, Quaternion(up_cur.normalized(), (knee - a).normalized()))
	# ② 小腿：重新量一次末端（大腿轉過之後腳踝也跟著動了），再擺到目標
	b = _dst.get_bone_global_pose(li).origin
	c = to_skel * leg_end(lower, foot)
	var lo_cur: Vector3 = c - b
	var lo_want: Vector3 = target - b
	if lo_cur.length() > eps * 0.01 and lo_want.length() > eps * 0.01:
		_rotate_bone(li, Quaternion(lo_cur.normalized(), lo_want.normalized()))
	return true

# 這根骨頭是不是「掛在骨架根部」（Quaternius hr_ 骨架的大腿就是這樣）。
# foot IK 的骨盆升降必須看這個：
#   掛在 Root  → 髖部移動帶不動它，要另外補一份位移
#   正常父階   → 髖部一移動它就跟著走，**再補一次就是移動兩倍**
# 2026-08-07 的「人物不見了」就是漏判這一條：tripo 骨架的 L_Thigh 父階是 Pelvis，
# 卻被當成 detached 又補了一次位移，每幀疊加，幾秒內骨架被推到 -15m。
func is_detached(bone: String) -> bool:
	var bi := _bone(bone)
	if bi < 0 or _dst == null:
		return false
	var pi := _dst.get_bone_parent(bi)
	if pi < 0:
		return true
	return _dst.get_bone_name(pi) == "Root"

# 骨盆升降（foot IK 的必要配套）：兩腳落差大到腿伸不直時，整個骨盆要沉下來。
# 沒有這一步，站在台階邊緣的人會被 IK 硬把後腳拉長＝腿部過度伸展（3A 也是這樣做的）。
# dy 為負＝往下沉。回傳實際套用量（可能被骨骼缺失擋掉）。
func shift_pelvis(bone: String, dy: float, weight: float = 1.0) -> float:
	var bi := _bone(bone)
	if bi < 0 or absf(dy) < 0.0005 or weight <= 0.001:
		return 0.0
	var cur_w: Vector3 = _dst.global_transform * _dst.get_bone_global_pose(bi).origin
	place_bone(bone, cur_w + Vector3(0.0, dy * clampf(weight, 0.0, 1.0), 0.0), 1.0)
	return dy * clampf(weight, 0.0, 1.0)

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
		var bi: int = _bone(String(n))
		if bi < 0:
			continue
		_dst.set_bone_pose_rotation(bi, _dst.get_bone_rest(bi).basis.get_rotation_quaternion())
