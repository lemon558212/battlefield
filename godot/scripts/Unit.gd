# Unit.gd — 戰場單位＝3D 動畫身體（GDD/13，2026-07-22 使用者拍板：戰場改 3D 模型、立繪只留 UI）。
# 這是 VC 本尊做法：立繪管 identity（選單/對話/角色卡），戰場上是能走/蹲/進掩體的 3D 模型（治「用飄的」）。
# 動作合理化由 AnimationPlayer 原生保證：走路必踏步、開火先舉槍轉身面向目標、受擊/陣亡有動作。
# 地基取自 git b93c0cb 的舊 Unit.gd。
class_name Unit
extends Node3D

signal shot_fired(from_pos: Vector3, to_pos: Vector3)
# 地形取樣器（由 Main 在建好地形後注入）：所有單位一律貼著地形站，
# 地面不再是 y=0，否則走上丘陵會埋進土裡、走進壕溝會浮在空中（GDD/14 §1）。
static var ground_sampler: Callable = Callable()
# 實體探測（由 Main 注入 _wall_ray）：從 a 到 b 打一條線，回傳最近命中比例（1＝沒撞到）。
# 用途：槍口不可以插進牆裡（使用者 2026-07-26：「不管是槍或是人又或是任何的物品
# 都不可能會跑進去固體裡面」）。貼牆時的正解是抬槍（真實的 high port 持槍），
# 不是讓槍穿過去。
static var solid_probe: Callable = Callable()
# 抵達目的地：Main 要靠這個重算掩體狀態，否則玩家移動到掩體後不會自動蹲下
signal arrived

# 賽璐璐描邊（往鳴潮卡通渲染靠）：背面沿法線外擴、只塗深色，形成輪廓線。
const OUTLINE_SHADER := """
shader_type spatial;
render_mode cull_front, unshaded, shadows_disabled;
uniform float width = 0.014;
uniform vec4 line_color : source_color = vec4(0.06, 0.06, 0.08, 1.0);
void vertex() { VERTEX += NORMAL * width; }
void fragment() { ALBEDO = line_color.rgb; }
"""
static var _outline_mat: ShaderMaterial

static func _get_outline() -> ShaderMaterial:
	if _outline_mat == null:
		var sh := Shader.new()
		sh.code = OUTLINE_SHADER
		_outline_mat = ShaderMaterial.new()
		_outline_mat.shader = sh
	return _outline_mat

# 給模型所有 StandardMaterial3D 加描邊 next_pass + 卡通化(降高光/加邊緣光感)
static func _cel_shade(model: Node) -> void:
	for m in model.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var cnt: int = maxi(mi.get_surface_override_material_count(), 1)
		for si in cnt:
			var base := mi.get_active_material(si)
			if base is StandardMaterial3D:
				var d := (base as StandardMaterial3D).duplicate()
				d.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
				d.roughness = maxf(d.roughness, 0.6)
				d.rim_enabled = true
				d.rim = 0.35
				d.rim_tint = 0.4
				d.next_pass = _get_outline()
				mi.set_surface_override_material(si, d)

const WALK_SPEED := 3.0    # 6 太快像滑行；戰術步行速度更真（治滑步）
const TURN_SPEED := 12.0   # 轉身要快，短距離移動也能先轉正再跑

# 語意動作 → Quaternius 片段名（優先），找不到再 regex 泛匹配（相容其他模型）
const Q_MAP := {
	"idle": "Idle_Gun_Pointing", "walk": "Walk", "run": "Run",
	"aim": "Idle_Gun_Pointing", "shoot": "Gun_Shoot", "run_shoot": "Run_Shoot",
	"hit": "HitRecieve", "death": "Death", "wave": "Wave",
}
# hr_ 骨架的角色沒有內建動畫，動作全部來自 UAL 動作庫（真人 mocap）並即時重定向。
const UAL_MAP := {
	"idle": "Pistol_Idle", "walk": "Walk", "run": "Jog_Fwd",
	"aim": "Pistol_Aim_Neutral", "shoot": "Pistol_Shoot", "run_shoot": "Jog_Fwd",
	"hit": "Hit_Chest", "death": "Death01", "wave": "Interact",
	"crouch": "Crouch_Idle", "crouch_walk": "Crouch_Fwd", "reload": "Pistol_Reload",
	# 2026-07-25 補齊全動作：長距離衝刺、工兵修理/治療、佔領據點、赤手待機
	"sprint": "Sprint", "fix": "Fixing_Kneeling", "capture": "Interact", "idle_relaxed": "Idle",
}
# 雙手 IK 會把手鎖在槍上，其他動作全被鎖死看不出來，故分兩級放手：
# 雙手全放（槍留在右手掛點上，動畫怎麼擺就怎麼擺）
const FREEHAND_STATES := ["fix", "capture", "idle_relaxed", "death"]
# 只放左手：右手仍握著槍、槍維持低姿預備，左手去拿彈匣／護住傷處——
# 換彈若雙手全放，長槍會被舉成一根直挺挺的旗杆（2026-07-25 實拍發現）。
const LEFTHAND_FREE := ["reload", "hit"]
# 匍匐（蛙式）的角度規格——使用者 2026-07-26 親自給的：髖外展 30~45 度、屈膝 30~45 度
# 匍匐（低姿匍匐）的大腿方向，以「水平面上距離正後方的角度」表示：
#   0°＝腿打直往後、90°＝膝在正側方、>90°＝膝蓋收到髖部**前面**。
# ⚠⚠ 2026-07-27 使用者第四次說「趴姿移動的動作還是沒變」，真因就在這裡：
#   舊值 12°~42° 代表大腿**全程都在髖部後方**（cos42°=0.74 仍朝後），
#   驗證台量到膝蓋永遠在髖後 0.41m。那不是匍匐，是兩腿往後岔開在地上磨。
#   真實低姿匍匐是：① 屈膝把膝蓋收到腋下旁邊（明顯超過 90°，膝在髖前）
#   ② 腳掌蹬地 ③ 髖伸展把身體推出去 ④ 換邊。收不到前面就沒有東西可以蹬。
const PRONE_HIP_BACK := 8.0     # 蹬完：腿幾乎打直往後
const PRONE_HIP_UP := 108.0     # 收腿到底：膝蓋在髖部前方（cos108°=-0.31）
const PRONE_KNEE_MIN := 8.0
const PRONE_KNEE_MAX := 48.0
# ★★停下來要回 idle 的狀態清單（2026-07-27，使用者連續三輪回報「原地跑步」的真因）。
#   舊寫法是 `_state == "shoot" or _state == "" or _state == "hit" or _state == "crouch"`
#   ——**"run"/"walk"/"sprint"/"crouch_walk" 都不在裡面**。
#   鍵盤移動走的是 `move_dir()`，它會 `_play("run")` 然後 `_process` 在
#   `if _dir_moving: return` 那裡提早返回；鬆開鍵之後 `_dir_moving` 是 false，
#   流程雖然走到底了，卻因為 "run" 不在清單裡而永遠不回 idle →
#   **跑步動畫無限循環，連結束行動都不會停**。
#   ⚠ 教訓：這種「白名單式的狀態回歸」只要漏一個狀態就會卡住，
#     而且卡住的是「玩家最常看到的那個狀態」。清單要含全部移動狀態。
const IDLE_BACK := ["", "shoot", "hit", "crouch", "run", "walk", "sprint", "crouch_walk", "aim"]

# 會循環播放的動作（其餘播一次就回 idle）
const LOOP_KEYS := ["idle", "idle_relaxed", "walk", "run", "sprint", "aim", "crouch", "crouch_walk", "fix"]

const RX_MAP := {
	"idle": "(?i)idle", "walk": "(?i)walk", "run": "(?i)^run$|running",
	"aim": "(?i)aim|point", "shoot": "(?i)shoot|fire|attack|gun",
	"hit": "(?i)hit|receive", "death": "(?i)death|die", "wave": "(?i)wave",
}

var side: int = 0
var cls: String = "rifleman"
var anim: AnimationPlayer = null
var anim_names := {}
var _move_target = null
var _shoot_target = null
var _state := ""
var _shoot_timer := 0.0
var _busy_until := 0.0        # shoot/hit 播放鎖
var _dead := false
var _die_fade := 0.0
var _model: Node3D = null
var _gun_node: Node3D = null
var _gun_mount: Node3D = null
var _gun_fixed := false
var _gun_fix_wait := 0        # 等動畫姿勢真的套上骨骼再校正（同幀 advance 讀不到新姿勢）
const RIG := preload("res://scripts/Retarget.gd")
var _rig = null                # IK / 俯仰 / 握拳工具（綁在本模型骨架上）
var _anim_src: Node3D = null   # UAL 動作來源（模型自身沒有動畫時用它 + 重定向）
var _retarget := false         # true＝動作來自 UAL 重定向
var _gun_armed := false        # 有真實武器模型才做程式化持槍姿
var _gun_len_scale := 1.0      # 網格 → 真實槍長的縮放
var _gun_len := 1.0            # 槍全長（公尺）：貼牆抬槍要用
var _muzzle_block := 0.0       # 目前抬槍角度（度）：貼牆時槍口朝天，平滑過渡
var _muzzle_world := Vector3.ZERO   # 這一幀的槍口世界座標（驗證用：槍口不可在固體內）
var _gun_src_world := Vector3.ZERO  # 這一幀的抵肩點世界座標
var _gun_stock := Vector3.ZERO # 抵肩點（mesh 座標）
var _gun_grip := Vector3.ZERO  # 右手握把
var _gun_fore := Vector3.ZERO  # 左手前護木
var _gun_carry_xf := Transform3D.IDENTITY   # 攜行時的 local 變換（校正結果，離開瞄準要還原）
var _aiming := false
var aim_point = null           # 由 Main/射擊流程指定的瞄準目標點（世界座標）
const UAL_ANIMS := "res://assets/models/anims/ual_standard.glb"
# ⚠ 2026-07-25：重定向到「遊戲內這具骨架」會把身體扭壞（換到 hr_ 骨架時正常），
# 判斷是該骨架 rest 差異問題，待修；先關掉、退回原本的壓低身體蹲法，不把壞的留在遊戲裡。
const USE_RETARGET_CROUCH := false
static var _crouch_pose := {}   # 全體共用：蹲姿只需算一次，不必每個單位都揹一份動畫來源
static var _crouch_busy := false
const CROUCH_DEPTH := 0.14   # 蹲下時髖部下沉
const CROUCH_BACK := 0.05    # 髖部同時後移（少了這個會變成坐椅子）
const STANCE_W := 0.16       # 雙腳站距（半寬）   # 蹲下時身體下沉高度
const ANKLE_H := 0.08        # 腳踝骨離地高度
const PRONE_H := 0.26        # 趴姿時髖部離地高度（人趴著髖部大約在這個高度）
const PRONE_SPEED := 0.8     # 匍匐前進速度（實際軍事匍匐約 0.7~1 m/s，比走路慢得多）
const CRAWL_RATE := 3.4      # 匍匐擺動頻率（每公尺約一個循環）
const VEH_SPEED := 4.2       # 履帶車速（比步兵快，但轉向慢）
const VEH_TURN := 1.8        # 履帶車轉向速率（步兵 12，坦克要笨重）
const CROUCH_WALK_MAX := 4.0 # 掩體區內移動幾公尺以內用蹲行（再遠就站起來跑）
const SHOTS_PER_MAG := 3     # 打幾發換一次彈匣
var _shots := 0
# 後座力：雙手被 IK 鎖在槍上，射擊動作本身幾乎看不出來——不加這個「開槍」在畫面上是無聲無息的
var _recoil := 0.0
const RECOIL_DECAY := 5.5
var _reload_at := 0.0        # >0＝這個時間點該接換彈動作
const LEG_AXIS := 0      # 這具骨架的膝蓋彎曲軸（三軸掃描驗得）
var _gun_pos := Vector3.ZERO
# 移動速度倍率：敵方階段用來加速「玩家根本看不到」的行軍段，免得每回合空等。
# 看得見的敵人一律 1.0——那段是玩家要看的（也是迎擊發生的地方）。
var speed_mul := 1.0
var want_prone := false        # 趴姿：全身伏地出槍（狙擊/壓制用）
# 玩家用鍵盤指定的姿勢（"" = 交給自動判定）。使用者 2026-07-26 要求
# 蹲/趴/起立要能自己按鍵控制，不是只由「有沒有掩體」自動決定。
var stance_cmd := ""
var _prone := 0.0
var _crawl := 0.0              # 匍匐動作相位（只在趴著移動時前進）
var _crawl_amt := 0.0          # 匍匐擺動強度（起停漸進，靜止臥射時為 0）
var _prone_hold := 0.0         # 趴著持續移動了多久（超過門檻就起身）
const PRONE_BREAK_T := 2.5     # 短按＝爬著微調位置（約 2m）；一直走就起身，不然龜速很痛苦
var want_cover := false        # 由 Main 依所在位置設定；靜止時自動擺蹲姿
# 自動姿勢總開關。玩家親自操控（第三人稱行動模式）時關掉——
# 使用者 2026-07-27：「停下來又自動蹲回去」，自動掩體判定壓過玩家意圖。
# 關掉之後姿勢完全由 C／Z／Space 決定，AI 與非操控中的單位不受影響。
# 關掉之後「自動蹲掩體」與「狙擊手自動臥射」都不生效，姿勢完全由 C/Z/Space 決定。
var auto_stance := true
var _model_base_y := 0.0
var _crouch := 0.0             # 0=站 1=蹲（平滑過渡）
# 正面軸校正改「轉模型子節點」，Unit.rotation.y 一律代表「+Z 為正面」的純朝向。
# ⚠ 絕不可用檔名判斷模型慣例（2026-07-23 血淚：重定向後檔名沒了 "tripo" 兩字，
#   校正失效、90 度偏差整個回來）。改用「骨架骨名」判斷＝內容決定，改名不會壞。
func facing_dir() -> Vector3:
	return Vector3(sin(rotation.y), 0.0, cos(rotation.y))

# 角色自己的右手邊。
# ⚠⚠ 絕不可用 `global_basis.x` 當「右」（2026-07-27 手臂塌陷的真因）：
#   Godot 的 basis.x 是「正面為 -Z」慣例下的右方，而本專案的角色正面是 **+Z**，
#   兩者剛好差 180°。實測 Shoulder.L 在 +X、Shoulder.R 在 -X，
#   也就是 basis.x 指的是角色的**左**邊。
#   後果：右肘的極向量被推到身體左側、左肘推到右側 → 兩條手臂都被逼著橫越胸腔，
#   相對肩骨的擺動角接近 180°，線性混合蒙皮把那一圈頂點平均成長度 0 → 手臂消失。
#   （Main.gd 的移動早在 50928ac 修過同一個錯，Unit.gd 這半邊當時沒跟著修。）
# ⚠ 只用於「位置／方向」。當**旋轉軸**用的地方（俯仰、後座、抬槍）沿用 basis.x：
#   那些角度是照著反的軸調出來的，換軸必須同時反號，等於白改。
func right_dir() -> Vector3:
	return facing_dir().cross(Vector3.UP)

# tripo 系骨架(Hip/L_Upperarm/L_Thigh)網格正面朝 +X → 模型需轉 -90° 才對齊 +Z；
# Quaternius 系(Hips/UpperArm.L)本就朝 +Z → 0。
static func _forward_fix(model: Node) -> float:
	var sks := model.find_children("*", "Skeleton3D", true, false)
	if sks.is_empty():
		return 0.0
	var sk := sks[0] as Skeleton3D
	if sk.find_bone("L_Upperarm") >= 0 or sk.find_bone("L_Thigh") >= 0:
		return -PI / 2.0
	return 0.0

# 載具（履帶/艦艇/航空）走完全不同的分支：沒有骨架、沒有人形動畫、沒有持槍 IK。
# 判斷讀 data/class_base.json 的 mobility，不寫死兵種名（鐵律 3）。
static func is_vehicle_cls(c: String) -> bool:
	return GameData.class_base.get(c, {}).get("mobility", "foot") in ["tracked", "naval", "air"]

static func spawn(model_path: String, p_cls: String, p_side: int, is_player: bool) -> Unit:
	var u := Unit.new()
	u.cls = p_cls
	u.side = p_side
	if is_vehicle_cls(p_cls):
		u._build_vehicle(p_cls, is_player)
		u._add_ring_and_shadow(is_player, 2.9)   # 環要比車體寬才看得到（車寬 3.1m）
		return u
	var packed: PackedScene = null
	if model_path != "" and ResourceLoader.exists(model_path):
		packed = load(model_path)
	if packed == null and ResourceLoader.exists("res://assets/models/chars/soldier.glb"):
		# ⚠⚠ 靜默退回舊模型是本專案踩過的坑（2026-07-25），而且症狀非常誤導：
		#   舊 soldier.glb 是土黃色、骨名是 Wrist.R/Foot 父階錯誤，
		#   現在的 IK 全部照 hr_ 骨名寫，套不上去就是「沒有手臂、沒有武器」。
		#   絕對不可以再靜默——要大聲喊出來。
		push_error("[Unit] 模型載入失敗，退回舊 soldier.glb！path=%s exists=%s cls=%s"
				% [model_path, ResourceLoader.exists(model_path), p_cls])
		print("[modelfallback] FAIL 退回舊模型 path=%s cls=%s" % [model_path, p_cls])
		packed = load("res://assets/models/chars/soldier.glb")
	if packed:
		var model := packed.instantiate()
		u._model = model
		u.add_child(model)
		u._fit_model(model)
		# 立繪本人模型（own_look）：骨長啟發式會把人拉到 1.9m+，違反真實尺度。
		# 這類模型是單一蒙皮網格、AABB 可信，直接把網格身高歸一化到 1.75m
		# （體型差異由 char_look.build 控制，不在這裡疊）。
		if is_player and bool(GameData.char_look.get(p_cls, {}).get("own_look", false)):
			u._normalize_height(model, 1.75)
		model.rotation.y = _forward_fix(model)   # ★正面軸對齊：讓模型正面朝 Unit 的 +Z
		if is_player:
			u._apply_look(model, p_cls)                    # 依立繪配色換裝（2026-07-24）
		else:
			# 外觀 v2：敵軍穿制式冷灰綠制服（enemy_look.palette），再壓淡紅疊色保識別。
			# 舊的 40% 紅疊色把敵軍畫成一隊紅人——真軍隊沒有紅制服（合理化鐵則）。
			# 外觀 v2：敵軍冷灰綠制服＋紅臂章識別（_attach_gear 加掛）。
			# ⚠ 不可再全身紅疊色：暗綠制服 × 16% 紅 × 兩次可讀性提亮＝全部布料
			#   收斂成肉膚色，整排敵軍看起來裸體（lookshots 實測 albedo 對上算式）。
			u._apply_palette(model, GameData.enemy_look.get("palette", {}))
		u._attach_gear(model, p_cls, is_player)            # 頭具/背具（外觀 v2）
		u._apply_build(model, p_cls, is_player)            # 體型微調
		var aps := model.find_children("*", "AnimationPlayer", true, false)
		# 注意：FBX 匯入可能產生「空的 AnimationPlayer」，那也算沒有動畫，
		# 否則會走進原生動畫分支卻一支都播不出來，角色停在 rest 姿勢。
		if aps.is_empty() or (aps[0] as AnimationPlayer).get_animation_list().is_empty():
			u._make_anim_source()
		elif true:
			u.anim = aps[0]
			u._map_anims()
			u._strip_root_motion()
		u._attach_weapon(model, p_cls)
	u._add_ring_and_shadow(is_player, 1.0)
	return u

# 腳下識別環＋接觸陰影（載具用同一套，只是放大）
# 腳下的識別環與接觸陰影：要跟著坡面躺平。
# ⚠ 固定水平的環在斜坡上有一半會埋進土裡、另一半浮在空中（實拍：站在土堤上時
#   藍環只剩半圈）——跟行動範圍圈是同一個病，只是尺寸小所以拖到現在才處理。
var _ring: MeshInstance3D = null
var _ring_shadow: MeshInstance3D = null

var _ring_r := 0.0
var _ring_at := Vector3(1e9, 0, 0)

func _align_ring() -> void:
	if _ring == null or not is_instance_valid(_ring) or not ground_sampler.is_valid():
		return
	# 逐頂點問地面高度重建環帶——跟行動範圍圈同一套。
	# 只轉基底（對齊坡面法線）在山脊上不夠：地面是彎的，平面環一定有一段埋進去。
	if global_position.distance_to(_ring_at) < 0.12:
		return
	_ring_at = global_position
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg := 40
	var pin: Array = []
	var pout: Array = []
	for i in seg + 1:
		var a: float = TAU * float(i) / float(seg)
		var d := Vector3(cos(a), 0.0, sin(a))
		pin.append(_ring_pt(d * _ring_r))
		pout.append(_ring_pt(d * (_ring_r + 0.10)))
	for i in seg:
		for v in [pin[i], pout[i], pout[i + 1], pin[i], pout[i + 1], pin[i + 1]]:
			st.set_normal(Vector3.UP)
			st.add_vertex(v)
	_ring.mesh = st.commit()
	_ring.position = Vector3.ZERO
	if _ring_shadow != null and is_instance_valid(_ring_shadow):
		var n: Vector3 = _ground_normal()
		if n.length() > 0.001:
			var side: Vector3 = n.cross(Vector3(0, 0, 1))
			if side.length() < 0.01:
				side = n.cross(Vector3(1, 0, 0))
			side = side.normalized()
			_ring_shadow.basis = Basis(side, n.normalized(),
					side.cross(n.normalized()).normalized()) * Basis(Vector3(1, 0, 0), -PI * 0.5)

# 環上一點：以單位為中心的局部偏移，y 直接問地面（回傳局部座標）
func _ring_pt(off: Vector3) -> Vector3:
	var w: Vector3 = global_position + off
	var gy: float = float(ground_sampler.call(w))
	return Vector3(off.x, gy - global_position.y + 0.07, off.z)

func _add_ring_and_shadow(is_player: bool, scale_k: float) -> void:
	var ring := MeshInstance3D.new()
	ring.name = "Ring"
	_ring_r = 0.62 * scale_k
	ring.position.y = 0.0
	_ring = ring
	var rm := StandardMaterial3D.new()
	rm.albedo_color = Color(0.36, 0.61, 1.0) if is_player else Color(1.0, 0.36, 0.30)
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.material_override = rm
	add_child(ring)
	var sh := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(1.4 * scale_k, 1.0 * scale_k)
	sh.mesh = qm
	sh.rotation_degrees.x = -90
	sh.position.y = 0.04
	_ring_shadow = sh
	var shm := StandardMaterial3D.new()
	shm.albedo_color = Color(0, 0, 0, 0.26)
	shm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sh.material_override = shm
	add_child(sh)

# 縮放到 1.8m。蒙皮網格的 get_aabb() 不可靠（soldier.glb 曾被量成 41m 高 → 巨人橫跨畫面），
# 故「有骨架就用骨頭靜止姿勢的實際高度」量測，最可靠；並加安全夾限，寧可不縮放也不爆掉。
func _fit_model(model: Node) -> void:
	var h := 0.0
	var base_y := 0.0
	var sks := model.find_children("*", "Skeleton3D", true, false)
	if not sks.is_empty():
		var sk := sks[0] as Skeleton3D
		var lo := INF
		var hi := -INF
		for i in sk.get_bone_count():
			var t := sk.get_bone_global_rest(i)
			lo = minf(lo, t.origin.y)
			hi = maxf(hi, t.origin.y)
		if hi > lo:
			h = (hi - lo) * 1.12          # 骨頭頂點約在頭頂之下，補一點頭高
			base_y = lo
	if h <= 0.01:
		var aabb := _merged_aabb(model)
		h = aabb.size.y
		base_y = aabb.position.y
	if h <= 0.01:
		return
	var k: float = 1.8 / h
	if k < 0.02 or k > 50.0:
		push_warning("Unit._fit_model 縮放異常 k=%f h=%f，改用原尺寸" % [k, h])
		return
	model.scale = Vector3.ONE * k
	model.position.y = -base_y * k
	_model_base_y = model.position.y

# 把模型實際網格身高歸一化到 target_h（_fit_model 之後再修一次）
func _normalize_height(model: Node, target_h: float) -> void:
	var box := _merged_aabb(model)
	# _merged_aabb 量的是模型局部座標，還要乘上 _fit_model 已套的縮放才是實際身高
	var mdl := model as Node3D
	var h: float = box.size.y * mdl.scale.y
	if h < 0.5 or h > 5.0:
		push_warning("Unit._normalize_height 量到異常身高 %.2f，跳過" % h)
		return
	var k: float = target_h / h
	mdl.scale *= k
	mdl.position.y = -(box.position.y) * mdl.scale.y
	_model_base_y = mdl.position.y

# 遞迴累積父階變換算 AABB。
# ⚠ 舊版只用 mi.transform（沒累積父階），巢狀模型會被量得極小 → _fit_model 縮放暴衝
#   → 單位變成一個橫跨畫面的巨人（使用者看到的「場景黑色邊/灰色巨牆」真因，2026-07-24）。
func _aabb_rec(n: Node, xf: Transform3D, acc: AABB, has: bool) -> Array:
	var cur := xf
	if n is Node3D:
		cur = xf * (n as Node3D).transform
	if n is MeshInstance3D:
		var b: AABB = cur * (n as MeshInstance3D).get_aabb()
		acc = b if not has else acc.merge(b)
		has = true
	for c in n.get_children():
		var r := _aabb_rec(c, cur, acc, has)
		acc = r[0]
		has = r[1]
	return [acc, has]

func _merged_aabb(node: Node) -> AABB:
	var prev := (node as Node3D).transform
	(node as Node3D).transform = Transform3D.IDENTITY
	var r := _aabb_rec(node, Transform3D.IDENTITY, AABB(), false)
	(node as Node3D).transform = prev
	return r[0] if r[1] else AABB()

# 換裝：用內建 3D 模型 + 依角色立繪配色重新上色（data/char_look.json）。
# 模型材質具名(Hair/Skin/Eye/Eyebrows/各衣著色)，依名稱分部位套色；皮膚與眼睛不動。
const _KEEP := ["skin", "eye", "eyebrow", "moustache", "teeth", "mouth", "visor"]
func _apply_look(model: Node, p_cls: String) -> void:
	var look: Dictionary = GameData.char_look.get(p_cls, {})
	# 立繪本人（tripo）模型自帶 2K 烘焙貼圖＝角色本來的樣子，絕不可再拿配色乘上去
	# （暗色外套色 × 貼圖＝整身變暗）。own_look 走材質修正分支，旗標在 char_look.json。
	if bool(look.get("own_look", false)):
		_fix_hero_mats(model)
		return
	_apply_palette(model, look)

# tripo glb 的 metallicFactor 缺省＝glTF 預設 1.0（全金屬）：diffuse 全黑、albedo 變
# 鏡面 F0，就是試點實拍「太暗太油」的物理成因。金屬度歸零、粗糙度拉滿，
# 貼圖層次由 ORM 綠通道（roughness）保留。
func _fix_hero_mats(model: Node) -> void:
	var fixed := 0
	for m in model.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var cnt: int = maxi(mi.get_surface_override_material_count(), 1)
		for si in cnt:
			var base := mi.get_active_material(si)
			if not (base is StandardMaterial3D):
				continue
			var dup: StandardMaterial3D = (base as StandardMaterial3D).duplicate()
			dup.metallic = 0.0
			dup.roughness = 1.0
			dup.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
			_add_rim(dup)
			mi.set_surface_override_material(si, dup)
			fixed += 1
	if fixed == 0:
		print("[look] FAIL %s 本人模型沒有任何材質被修正（材質型別不符？）" % cls)

# 依調色盤重刷全身材質（我方吃 char_look 各角色色；敵軍吃 enemy_look 統一制服色）
func _apply_palette(model: Node, look: Dictionary) -> void:
	if look.is_empty():
		return
	var c_hair := Color(look.get("hair", "#333333"))
	var c_coat := Color(look.get("coat", "#3b3b3b"))
	var c_low := Color(look.get("lower", "#4a4a4a"))
	var c_acc := Color(look.get("accent", "#7a7a7a"))
	var recolored := 0
	for m in model.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var cnt: int = maxi(mi.get_surface_override_material_count(), 1)
		for si in cnt:
			var base := mi.get_active_material(si)
			if not (base is StandardMaterial3D):
				continue
			var nm: String = (base as StandardMaterial3D).resource_name.to_lower()
			var keep := false
			for k in _KEEP:
				if nm.contains(k):
					keep = true
					break
			if keep:
				continue
			var src: Color = (base as StandardMaterial3D).albedo_color
			var target: Color
			if nm.contains("hair"):
				target = c_hair
			else:
				# 依原色明度分派：亮的走下身/點綴色，暗的走主外套色，保留原模型的層次
				var lum := src.get_luminance()
				if lum > 0.62:
					target = c_low
				elif lum > 0.34:
					target = c_acc
				else:
					target = c_coat
			# 保留原模型的明暗層次：直接刷單一色會把「深色戰術裝＋更深的護具」壓成一團黑，
			# 遠看就是一個剪影（hr_w_Swat 換上韓沐霜配色時整個人變黑，2026-07-25 實拍）。
			# 作法＝取角色的色相、乘回原材質的相對亮度。
			var t_lum: float = maxf(target.get_luminance(), 0.06)
			# ⚠ 這個係數是用來保留原模型的明暗層次，但範圍開太大（0.6~1.7）時，
			#   每個部位都被拉回它原本的亮度，角色配色等於沒有作用——
			#   hr_w_Swat 原本整身淺灰，套上任何配色出來都還是整身淺灰（實拍證實）。
			#   收窄到 0.78~1.30：層次還在，但主色真的看得出來。
			var shade: float = clampf(src.get_luminance() / t_lum, 0.78, 1.30)
			var toned := Color(clampf(target.r * shade, 0.0, 1.0), clampf(target.g * shade, 0.0, 1.0),
					clampf(target.b * shade, 0.0, 1.0), target.a)
			var dup := (base as StandardMaterial3D).duplicate()
			dup.albedo_color = _readable(src.lerp(toned, 0.92))
			_add_rim(dup)
			mi.set_surface_override_material(si, dup)
			recolored += 1
	# 換色一件都沒成功要大聲喊：新基底的材質若不是 StandardMaterial3D，
	# 整套配色會靜默失效——角色穿著原模型預設色出場（lookshots 抓到整身紅的艾拉）
	if recolored == 0:
		print("[look] FAIL %s 沒有任何材質被換色（材質型別不符？）" % cls)

# ---------- 裝具與體型（GDD/06 外觀 v2）----------
const GEAR := preload("res://scripts/Gear.gd")
const HEAD_BONES := ["Head", "head"]
const SPINE_BONES := ["Spine2", "Chest", "Spine1", "Spine", "spine_02", "Spine02", "Spine01"]
var _gear_fix: Array = []      # [{mount, node}]：進場景樹後做縮放/朝向補償（同槍械的坑）

func _attach_gear(model: Node, p_cls: String, is_player: bool) -> void:
	var look: Dictionary = GameData.char_look.get(p_cls, {}) if is_player \
			else GameData.enemy_look.get(p_cls, {})
	if look.is_empty():
		return
	var pal: Dictionary = look if is_player else GameData.enemy_look.get("palette", {})
	var main_c := Color(pal.get("coat", "#4a4a46"))
	var acc_c := Color(pal.get("accent", "#6a6a60"))
	var sks := model.find_children("*", "Skeleton3D", true, false)
	if sks.is_empty():
		return
	var sk := sks[0] as Skeleton3D
	var specs: Array = [[String(look.get("head", "")), HEAD_BONES, Vector3(0, 0.02, 0)],
			[String(look.get("pack", "")), SPINE_BONES, Vector3(0, 0.0, 0)]]
	if not is_player:
		# 敵軍識別＝左臂紅臂章（真實軍隊的敵我識別做法；全身紅疊色已證實會把
		# 暗色制服洗成肉色）
		specs.append(["armband", ["L_Upperarm", "UpperArm.L", "Shoulder.L"], Vector3.ZERO])
	for spec in specs:
		var item: String = spec[0]
		if item == "" or item == "none":
			continue
		var bone := ""
		for b in spec[1]:
			if sk.find_bone(b) >= 0:
				bone = b
				break
		if bone == "":
			print("[gear] FAIL %s 找不到掛骨 %s" % [item, str(spec[1])])
			continue
		var node := GEAR.build(item, main_c, acc_c)
		if node == null:
			continue
		var mount := BoneAttachment3D.new()
		mount.name = "GearMount_" + item
		mount.bone_name = bone
		sk.add_child(mount)
		mount.add_child(node)
		_gear_fix.append({"m": mount, "n": node, "off": spec[2]})

# 裝具縮放/朝向補償：BoneAttachment 世界縮放非 1（此類模型 100 倍，同槍械的坑）。
# 一次性：頭盔跟著頭骨轉，之後不再重算。朝向對齊 Unit 本體（+Z＝臉的朝向）。
func _fix_gear() -> void:
	if _gear_fix.is_empty() or not is_inside_tree():
		return
	var done: Array = []
	for g in _gear_fix:
		var mount: BoneAttachment3D = g["m"]
		if not mount.is_inside_tree():
			continue
		var node: Node3D = g["n"]
		# 跟 _fix_gun_scale 同一套公式（那套已在槍上驗證過）：
		# bone 基底相對 Unit 的朝向取逆 × 期望朝向，再除掛點世界縮放。
		var wrist := (global_transform.affine_inverse() * mount.global_transform).basis.orthonormalized()
		var ws: Vector3 = mount.global_transform.basis.get_scale()
		var s: float = maxf((absf(ws.x) + absf(ws.y) + absf(ws.z)) / 3.0, 0.0001)
		var b := (wrist.inverse() * Basis.IDENTITY).scaled(Vector3.ONE * (1.0 / s))
		node.transform = Transform3D(b, b * (g["off"] as Vector3))
		done.append(g)
	for g2 in done:
		_gear_fix.erase(g2)

# 體型微調（build=[寬,高]）：套在 _fit_model 之後的模型節點上，±8% 內
func _apply_build(model: Node, p_cls: String, is_player: bool) -> void:
	var look: Dictionary = GameData.char_look.get(p_cls, {}) if is_player \
			else GameData.enemy_look.get(p_cls, {})
	var bld = look.get("build", null)
	if bld is Array and bld.size() >= 2:
		var w: float = clampf(float(bld[0]), 0.92, 1.08)
		var h: float = clampf(float(bld[1]), 0.94, 1.06)
		if model is Node3D:
			(model as Node3D).scale *= Vector3(w, h, w)

# 角色的可讀性下限（2026-07-27）：黃昏側逆光下，深色戰術裝的 albedo 只有 0.06~0.10，
# 一旦人站在建築陰影裡就變成一片純黑剪影——使用者看到的「沒有手臂」有一半是這個，
# 因為手臂與軀幹之間的明暗差被壓成 0，整個人只剩輪廓。
# 角色是玩家唯一要一直盯著看的東西，把明度下限拉到 0.30 並保留色相。
# ⚠ 不可以用「低於門檻就拉到門檻」的夾限：所有深色部位會被壓成同一個亮度，
#   角色變成一團沒有層次的米色（2026-07-27 實拍，一次就看出來）。
#   要用 gamma 提亮——暗的還是比中間調暗，只是整體離開「純黑」那一段。
# ⚠ 提太多也不行：0.62 把深色戰術裝提到跟褲子一樣亮，整個人變成一團沒有層次的米色
#   （2026-07-27 實拍第二次）。0.80 只把「近乎純黑」那一段拉離黑，中亮調幾乎不動。
const CHAR_GAMMA := 0.80      # v' = v^0.80：0.06→0.11、0.24→0.33、0.60→0.66
const CHAR_MIN_V := 0.13      # 提亮後仍太暗的再補一個地板，避免在陰影裡變純黑

func _readable(c: Color) -> Color:
	var v: float = maxf(maxf(c.r, c.g), c.b)
	if v < 0.001:
		return c
	var k: float = maxf(pow(v, CHAR_GAMMA), CHAR_MIN_V) / v
	return Color(minf(c.r * k, 1.0), minf(c.g * k, 1.0), minf(c.b * k, 1.0), c.a)

# 邊緣光：讓角色在逆光/陰影裡仍然有一圈輪廓亮邊，跟背景分得開。
# 這不是寫實的做法，是可讀性——所有第三人稱遊戲都在角色身上加這個。
func _add_rim(m: StandardMaterial3D) -> void:
	# ⚠ 強度要克制：低多邊形角色的法線大多偏離視線，rim 0.55 會讓整個人泛白
	#   （2026-07-27 實拍：士兵變成一尊石膏像）。0.22 只在真正的輪廓邊亮起來。
	m.rim_enabled = true
	m.rim = 0.22
	m.rim_tint = 0.6

func _tint(model: Node, tint: Color, strength: float) -> void:
	if strength <= 0.001:
		return
	for m in model.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var cnt: int = maxi(mi.get_surface_override_material_count(), 1)
		for si in cnt:
			var base := mi.get_active_material(si)
			if base is StandardMaterial3D:
				var dup := (base as StandardMaterial3D).duplicate()
				dup.albedo_color = _readable(dup.albedo_color.lerp(tint, strength))
				_add_rim(dup)
				mi.set_surface_override_material(si, dup)

# 武器改回「握在手裡」（2026-07-25）：揹背只是繞過掛點縮放暴衝，並非修好。
# 真因：BoneAttachment3D 的世界縮放非 1（此類模型為 100 倍），不補償就會把槍放大成巨牆。
# 現改為掛右手腕骨 + 縮放補償 + 依網格實際尺寸自動校正握把，武器才真的在手上。
# 兵種若有真實武器模型就用，沒有的沿用程式生成外形（機槍/火箭筒/迫砲/防空）。
const WEAPON_MODEL := {
	"rifleman": ["res://assets/models/weapons/AssaultRifle_1.obj", 0.90],
	"sniper": ["res://assets/models/weapons/SniperRifle_1.obj", 1.25],
	"specops": ["res://assets/models/weapons/SubmachineGun_1.obj", 0.62],
	"assault": ["res://assets/models/weapons/Shotgun_1.obj", 0.95],
	"engineer": ["res://assets/models/weapons/Pistol_1.obj", 0.22],
}
const HAND_BONES := ["Wrist.R", "Hand.R", "hand_r"]
# 程式生成武器（無真實模型的兵種）的三個持槍關鍵點：槍托／右手握把／左手前護木。
# 座標＝_make_gun 的慣例：local +Z＝槍口、原點在握把附近。
# 迫砲不是肩射武器（砲管本身已含 60° 仰角），故錨點下移到腰際、雙手扶砲管與握把。
const PROC_GRIP := {
	"mg":     [Vector3(0, 0.00, -0.28), Vector3(0, -0.06, -0.02), Vector3(0, -0.05, 0.26)],
	"at":     [Vector3(0, -0.02, -0.04), Vector3(0, -0.10, 0.04), Vector3(0, -0.09, 0.30)],
	"sam":    [Vector3(0, -0.02, -0.06), Vector3(0, -0.10, 0.02), Vector3(0, -0.09, 0.28)],
	"mortar": [Vector3(0, -0.14, -0.10), Vector3(0, -0.09, 0.00), Vector3(0, 0.22, 0.28)],
}
# 抵肩點下移量（0＝抵右肩窩）。迫砲抱在腰際，抵肩會變成「拿砲管當狙擊槍」。
const PROC_POCKET_DROP := {"mortar": 0.40}
# 槍口軸換算：真實武器模型（obj）槍管沿 +X，程式生成的沿 +Z。
const PROC_AXIS_FIX := Basis(Vector3(0, 0, -1), Vector3(0, 1, 0), Vector3(1, 0, 0))
var _gun_axis_fix := Basis.IDENTITY
# 手骨命名在各包不一致（舊 soldier.glb＝Wrist.R、hr_ 骨架＝Hand.R）。
# ⚠ 寫死名稱時 IK 會「安靜地失敗」——槍架好了、雙手卻垂在身側，很難一眼看出（2026-07-25）。
var _hand_r := "Wrist.R"
var _hand_l := "Wrist.L"

func _attach_weapon(model: Node, p_cls: String) -> void:
	var sks := model.find_children("*", "Skeleton3D", true, false)
	if sks.is_empty():
		return
	var sk := sks[0] as Skeleton3D
	var bone := ""
	for b in HAND_BONES:
		if sk.find_bone(b) >= 0:
			bone = b
			break
	if bone == "":
		return
	_hand_r = bone
	_hand_l = ("Hand.L" if sk.find_bone("Hand.L") >= 0 else "Wrist.L")
	var mount := BoneAttachment3D.new()
	mount.name = "WeaponMount"
	mount.bone_name = bone
	sk.add_child(mount)
	var gun: Node3D
	if WEAPON_MODEL.has(p_cls):
		var mi := MeshInstance3D.new()
		mi.mesh = load(WEAPON_MODEL[p_cls][0])
		gun = mi
	else:
		gun = _make_gun(p_cls)
	mount.add_child(gun)
	_gun_node = gun
	_gun_mount = mount
	_gun_fixed = false         # 交由 _fix_gun_scale 在進場景樹後補償縮放
	_rig = RIG.new()
	if _anim_src != null:
		var ssk := _anim_src.find_children("*", "Skeleton3D", true, false)
		if not ssk.is_empty():
			print("[rig] ", cls, " 重定向骨對數=", _rig.setup(ssk[0] as Skeleton3D, sk))
		else:
			_rig.bind(sk)
	else:
		_rig.bind(sk)
	# 動畫每幀都會覆寫骨骼姿勢，IK 必須等它寫完才套，否則手臂會被打回動畫姿勢。
	if sk.has_signal("skeleton_updated"):
		sk.skeleton_updated.connect(_on_skeleton_updated)
	# 量出槍身上的三個關鍵點（mesh 座標）：抵肩的槍托、右手握把、左手前護木
	if gun is MeshInstance3D and WEAPON_MODEL.has(p_cls):
		var ab: AABB = (gun as MeshInstance3D).get_aabb()
		var raw: float = ab.size.x
		if raw > 0.0001:
			_gun_len_scale = float(WEAPON_MODEL[p_cls][1]) / raw
		_gun_len = float(WEAPON_MODEL[p_cls][1])
		_gun_stock = Vector3(ab.position.x + 0.03 * raw, ab.position.y + 0.62 * ab.size.y, ab.get_center().z)
		_gun_grip = Vector3(ab.position.x + 0.30 * raw, ab.position.y + 0.46 * ab.size.y, ab.get_center().z)
		_gun_fore = Vector3(ab.position.x + 0.46 * raw, ab.position.y + 0.56 * ab.size.y, ab.get_center().z)
		_gun_armed = true
	elif PROC_GRIP.has(p_cls):
		# 沒有真實武器模型的兵種（機槍/火箭筒/防空）：程式生成的槍身尺寸是自己定的，
		# 三個關鍵點直接寫死即可，一樣能抵肩出槍——原本這裡沒設 _gun_armed，
		# 導致 _aim_pose 整段提早返回，這幾個兵種連蹲姿修正都吃不到。
		var g: Array = PROC_GRIP[p_cls]
		_gun_stock = g[0]
		_gun_grip = g[1]
		_gun_fore = g[2]
		_gun_len_scale = 1.0
		_gun_len = 1.15                # 程式生成的槍身（機槍/火箭筒）大致長度
		_gun_axis_fix = PROC_AXIS_FIX     # 程式生成的槍口是 +Z，瞄準基底以 +X 為槍口
		_gun_armed = true

# ---------- 載具：程式生成低多邊形車體（沒有現成模型，風格與場景一致）----------
# 尺寸照真實主戰坦克比例：車體長 6.2m、寬 3.3m、含砲塔高 2.4m（人 1.8m 當基準尺）。
# 慣例同步兵：+Z＝正面；砲塔可獨立轉向瞄準。
var _is_vehicle := false
var _turret: Node3D = null
var _barrel_len := 3.6

func _build_vehicle(p_cls: String, is_player: bool) -> void:
	_is_vehicle = true
	var root := Node3D.new()
	root.name = "Vehicle"
	add_child(root)
	_model = root
	_model_base_y = 0.0
	var body := _mat(Color(0.36, 0.40, 0.30), 0.25, 0.72) if is_player else _mat(Color(0.42, 0.30, 0.26), 0.25, 0.72)
	var dark := _mat(Color(0.10, 0.10, 0.11), 0.4, 0.6)
	var steel := _mat(Color(0.22, 0.24, 0.22), 0.6, 0.45)
	# 車體：下段厚、上段收窄（避免像一塊磚）
	var hull := _box(3.1, 0.75, 5.6, body); hull.position.y = 0.95; root.add_child(hull)
	var glacis := _box(2.9, 0.42, 1.9, body); glacis.position = Vector3(0, 1.42, 1.5)
	glacis.rotation_degrees.x = -18.0; root.add_child(glacis)
	var deck := _box(2.9, 0.30, 3.4, body); deck.position = Vector3(0, 1.40, -0.7); root.add_child(deck)
	# 履帶：兩側各一條，加負重輪
	for sgn in [-1.0, 1.0]:
		var track := _box(0.50, 0.86, 6.0, dark)
		track.position = Vector3(sgn * 1.62, 0.55, 0.0)
		root.add_child(track)
		# 負重輪要比履帶寬一點才露得出來，否則整條履帶是一塊黑板（實拍發現）
		for i in 6:
			var wheel := _cyl(0.34, 0.66, steel)
			wheel.rotation_degrees.z = 90
			wheel.position = Vector3(sgn * 1.62, 0.45, -2.2 + i * 0.88)
			root.add_child(wheel)
		var idler := _cyl(0.26, 0.68, steel)
		idler.rotation_degrees.z = 90
		idler.position = Vector3(sgn * 1.62, 0.86, 2.6)
		root.add_child(idler)
	# 砲塔（獨立節點，可轉向）
	_turret = Node3D.new()
	_turret.name = "Turret"
	_turret.position = Vector3(0, 1.58, -0.35)
	root.add_child(_turret)
	var tur := _box(2.3, 0.62, 2.7, body); tur.position.y = 0.31; _turret.add_child(tur)
	var cheek := _box(1.5, 0.44, 1.0, body); cheek.position = Vector3(0, 0.30, 1.5)
	cheek.rotation_degrees.x = -12.0; _turret.add_child(cheek)
	var mantlet := _box(0.9, 0.5, 0.5, steel); mantlet.position = Vector3(0, 0.32, 1.9); _turret.add_child(mantlet)
	var barrel := _cyl(0.11, _barrel_len, dark)
	barrel.rotation_degrees.x = 90
	barrel.position = Vector3(0, 0.34, 1.9 + _barrel_len * 0.5)
	_turret.add_child(barrel)
	var brake := _cyl(0.17, 0.5, steel)
	brake.rotation_degrees.x = 90
	brake.position = Vector3(0, 0.34, 1.9 + _barrel_len - 0.1)
	_turret.add_child(brake)
	# 車長機槍（GDD/01 §3：坦克靠車載機槍警戒）
	var cmg := _box(0.12, 0.12, 0.7, dark); cmg.position = Vector3(0.75, 0.72, 0.9); _turret.add_child(cmg)
	var hatch := _cyl(0.34, 0.16, steel); hatch.position = Vector3(0.75, 0.66, 0.3); _turret.add_child(hatch)
	# 側裙板與排氣（剪影辨識度）
	for sgn2 in [-1.0, 1.0]:
		var skirt := _box(0.1, 0.5, 4.6, steel)
		skirt.position = Vector3(sgn2 * 1.7, 1.05, -0.2)
		root.add_child(skirt)
	var exhaust := _cyl(0.18, 0.5, dark); exhaust.rotation_degrees.z = 90
	exhaust.position = Vector3(-1.2, 1.35, -2.6); root.add_child(exhaust)
	if not is_player:
		_tint(root, Color(0.9, 0.2, 0.16), 0.25)

# 砲塔轉向目標（載具沒有骨架，瞄準就是轉砲塔）
func _aim_turret(delta: float) -> void:
	if _turret == null:
		return
	var tgt = aim_point
	if tgt == null:
		if _turret.rotation.y != 0.0:
			_turret.rotation.y = lerp_angle(_turret.rotation.y, 0.0, minf(1.0, 2.0 * delta))
		return
	var local: Vector3 = global_transform.affine_inverse() * (tgt as Vector3)
	var want := atan2(local.x, local.z)
	_turret.rotation.y = lerp_angle(_turret.rotation.y, want, minf(1.0, 3.0 * delta))

func _mat(col: Color, metal: float, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.metallic = metal
	m.roughness = rough
	return m

# 依兵種造出剪影可辨的專屬武器（GDD/02：狙擊槍/機槍/火箭筒/防空/迫砲/步槍）。
# 慣例：local +Z＝槍口方向，武器原點在握把附近，掛右手腕 Wrist.R。
func _make_gun(p_cls: String) -> Node3D:
	var root := Node3D.new()
	var metal := _mat(Color(0.13, 0.13, 0.14), 0.7, 0.42)
	var dark := _mat(Color(0.07, 0.07, 0.08), 0.8, 0.35)
	var poly := _mat(Color(0.10, 0.11, 0.12), 0.1, 0.7)   # 塑膠件
	var wood := _mat(Color(0.30, 0.20, 0.12), 0.0, 0.75)
	var glass := _mat(Color(0.25, 0.45, 0.55), 0.2, 0.15)
	match p_cls:
		"sniper":
			var rec := _box(0.05, 0.10, 0.42, metal); rec.position.z = 0.0; root.add_child(rec)
			var bar := _cyl(0.011, 0.62, dark); bar.rotation_degrees.x = 90; bar.position.z = 0.52; root.add_child(bar)
			var brake := _cyl(0.022, 0.06, dark); brake.rotation_degrees.x = 90; brake.position.z = 0.85; root.add_child(brake)
			var scope := _cyl(0.022, 0.20, dark); scope.rotation_degrees.x = 90; scope.position = Vector3(0, 0.10, 0.06); root.add_child(scope)
			var lens := _cyl(0.020, 0.02, glass); lens.rotation_degrees.x = 90; lens.position = Vector3(0, 0.10, 0.17); root.add_child(lens)
			var stock := _box(0.045, 0.13, 0.24, poly); stock.position = Vector3(0, -0.02, -0.30); root.add_child(stock)
			var mag := _box(0.035, 0.11, 0.06, poly); mag.position = Vector3(0, -0.10, -0.02); root.add_child(mag)
			_bipod(root, 0.62)
		"mg":
			var rec := _box(0.07, 0.12, 0.40, metal); root.add_child(rec)
			var bar := _cyl(0.018, 0.46, dark); bar.rotation_degrees.x = 90; bar.position.z = 0.44; root.add_child(bar)
			for i in 5:
				var fin := _cyl(0.026, 0.012, dark); fin.rotation_degrees.x = 90; fin.position.z = 0.30 + i * 0.03; root.add_child(fin)
			var box := _box(0.11, 0.11, 0.13, poly); box.position = Vector3(0.02, -0.10, -0.06); root.add_child(box)  # 彈鼓/彈箱
			var stock := _box(0.05, 0.12, 0.22, poly); stock.position = Vector3(0, -0.01, -0.30); root.add_child(stock)
			_bipod(root, 0.58)
		"at":
			var tube := _cyl(0.048, 0.78, dark); tube.rotation_degrees.x = 90; tube.position.z = 0.30; root.add_child(tube)
			var cone := _conemesh(0.048, 0.085, 0.10, dark); cone.rotation_degrees.x = -90; cone.position.z = -0.14; root.add_child(cone)  # 後噴口
			var warhead := _conemesh(0.055, 0.02, 0.10, _mat(Color(0.35,0.28,0.12),0.3,0.6)); warhead.rotation_degrees.x = 90; warhead.position.z = 0.72; root.add_child(warhead)
			var sight := _box(0.02, 0.07, 0.04, metal); sight.position = Vector3(0, 0.075, 0.20); root.add_child(sight)
			var grip := _box(0.03, 0.09, 0.05, poly); grip.position = Vector3(0, -0.09, 0.12); root.add_child(grip)
		"sam":
			var tube := _box(0.09, 0.09, 0.62, poly); tube.position.z = 0.24; root.add_child(tube)   # 方形發射管
			var tip := _conemesh(0.05, 0.006, 0.09, metal); tip.rotation_degrees.x = 90; tip.position.z = 0.58; root.add_child(tip)
			var seeker := _box(0.06, 0.05, 0.05, glass); seeker.position = Vector3(0.06, 0.03, 0.10); root.add_child(seeker)
			var grip := _box(0.03, 0.09, 0.05, poly); grip.position = Vector3(0, -0.09, 0.06); root.add_child(grip)
		"mortar":
			var mtube := _cyl(0.032, 0.70, metal); mtube.rotation_degrees.x = 60; mtube.position = Vector3(0, 0.14, 0.16); root.add_child(mtube)
			var basep := _box(0.20, 0.02, 0.20, dark); basep.position = Vector3(0, -0.14, -0.10); root.add_child(basep)
			var grip := _box(0.03, 0.09, 0.05, poly); grip.position = Vector3(0, -0.09, 0.0); root.add_child(grip)
		_:
			# 步槍/卡賓（rifleman/assault/specops/engineer 等）
			var rec := _box(0.05, 0.10, 0.30, metal); root.add_child(rec)
			var bar := _cyl(0.012, 0.30, dark); bar.rotation_degrees.x = 90; bar.position.z = 0.30; root.add_child(bar)
			var hand := _box(0.045, 0.06, 0.16, poly); hand.position.z = 0.18; root.add_child(hand)
			var mag := _box(0.035, 0.13, 0.055, poly); mag.position = Vector3(0, -0.11, -0.01); mag.rotation_degrees.x = 12; root.add_child(mag)
			var stock := _box(0.045, 0.10, 0.18, poly); stock.position = Vector3(0, -0.01, -0.24); root.add_child(stock)
			var sight := _box(0.015, 0.045, 0.10, metal); sight.position = Vector3(0, 0.075, 0.02); root.add_child(sight)
	return root

func _bipod(root: Node3D, front_z: float) -> void:
	var m := _mat(Color(0.08, 0.08, 0.09), 0.6, 0.5)
	for sgn in [-1.0, 1.0]:
		var leg := _cyl(0.006, 0.24, m)
		leg.rotation_degrees = Vector3(28, 0, sgn * 22)
		leg.position = Vector3(sgn * 0.05, -0.12, front_z * 0.55)
		root.add_child(leg)

func _conemesh(bottom_r: float, top_r: float, h: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.bottom_radius = bottom_r
	cm.top_radius = top_r
	cm.height = h
	mi.mesh = cm
	mi.material_override = mat
	return mi

func _box(x: float, y: float, z: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = Vector3(x, y, z)
	mi.mesh = m
	mi.material_override = mat
	return mi

func _cyl(r: float, h: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = r
	m.bottom_radius = r
	m.height = h
	mi.mesh = m
	mi.material_override = mat
	return mi

func _map_anims() -> void:
	if anim == null: return
	if _retarget:
		var have0 := anim.get_animation_list()
		for k in UAL_MAP.keys():
			if have0.has(UAL_MAP[k]):
				anim_names[k] = UAL_MAP[k]
		_play("idle", 0.0)
		return
	var have := anim.get_animation_list()
	for key in RX_MAP.keys():
		# ⚠ 部分模型(如 soldier.glb)片段名帶 "CharacterArmature|" 前綴，
		# 只做等值比對會失敗→退回 regex 抓到空手的 "Idle"，角色就變成垂手站著、槍飄在旁邊。
		# 故一律比對「| 之後的片段名」。
		if Q_MAP.has(key):
			var want: String = Q_MAP[key]
			var hit := ""
			for n in have:
				if n == want or n.substr(n.rfind("|") + 1) == want:
					hit = n
					break
			if hit != "":
				anim_names[key] = hit
				continue
		var rx := RegEx.new()
		rx.compile(RX_MAP[key])
		for n in have:
			if rx.search(n):
				anim_names[key] = n
				break
	_play("idle", 0.0)

# 抽離根運動：tripo 走/跑動畫把角色往前位移(root bone)，會跟程式移動疊加成滑步/回彈。
# 設 root_motion_track 讓 Godot 把該位移從姿勢抽走→動畫變原地踏步，位移純由程式驅動。
func _strip_root_motion() -> void:
	if anim == null:
		return
	var base: Node = null
	if anim.root_node != NodePath(""):
		base = anim.get_node_or_null(anim.root_node)
	if base == null:
		base = anim.get_parent()
	if base == null:
		return
	var sks := base.find_children("*", "Skeleton3D", true, false)
	if sks.is_empty():
		return
	var sk := sks[0] as Skeleton3D
	var rootbone := -1
	for i in sk.get_bone_count():
		if sk.get_bone_parent(i) == -1:
			rootbone = i
			break
	if rootbone < 0:
		return
	var relp := base.get_path_to(sk)
	anim.root_motion_track = NodePath(str(relp) + ":" + sk.get_bone_name(rootbone))

func _clip_len(key: String) -> float:
	if anim and anim_names.has(key):
		var a := anim.get_animation(anim_names[key])
		if a: return a.length
	return 0.5

func _play(key: String, blend := 0.2) -> void:
	if anim == null or not anim_names.has(key): return
	if _state == key and anim.is_playing(): return
	var clip: String = anim_names[key]
	if key in LOOP_KEYS:
		var a := anim.get_animation(clip)
		if a: a.loop_mode = Animation.LOOP_LINEAR
	anim.play(clip, blend)
	_state = key

# 一次性動作（工兵修理/治療、佔領據點…）：播完之前不會被待機狀態蓋掉。
# ⚠ 直接呼叫 _play 沒用——_process 每幀都會把 shoot/hit/crouch/空 狀態打回 idle。
func perform(key: String, hold := 0.0) -> void:
	if _dead or not anim_names.has(key):
		return
	_play(key, 0.15)
	_busy_until = Time.get_ticks_msec() / 1000.0 + (hold if hold > 0.0 else maxf(0.6, _clip_len(key)))

# 立即中止移動/射擊（到位後擺蹲姿、或被打斷時用）
func stop() -> void:
	_move_target = null
	_shoot_target = null

# 貼地（依專案鐵律 0「物理法則＝真實世界」重寫）。
# ⚠ 舊版是「用 lerp 把 y 收斂到地面高度」＝上下都靠磁吸。現實裡人離地會**落下**
#   （走出壕溝邊、被推離高處），不是慢慢飄下去；而踩上坡是被地面推上去，
#   有速度上限但不會延遲。所以兩個方向要分開處理。
const GRAVITY := 9.81          # m/s²，真實重力（鐵律 0：量級用現實值）
const CLIMB_SPEED := 2.4       # 上坡被地面抬起的速度上限（m/s）
var _fall_v := 0.0             # 目前垂直速度（往下為負）

# 車體半長／半寬（同 Main.VEHICLE_HL / VEHICLE_HW，改一邊要改兩邊）
const VEH_HL := 3.00
const VEH_HW := 1.75

# 支撐高度。步兵是一雙腳＝取一個點就夠；載具是 6.0×3.5m 的鋼板，
# 只取車心的話地形一有起伏，車頭或車尾就會插進土裡（鐵律 0①：固體不可互穿）。
# 取「車心」與「四角平均」的較高者：
#   平面斜坡 → 四角平均＝車心，維持原樣（傾斜會把兩端補回去）
#   凹地（車身橫跨一個坑）→ 平均較高，車被撐起來，不會沉進坑裡
#   凸丘（車跨在峰上）→ 平均較低，仍然踩在峰頂，兩端懸空＝現實就是這樣
func _support_height() -> float:
	var gy: float = float(ground_sampler.call(global_position))
	if not _is_vehicle:
		# ⚠ 2026-07-30 撤銷「腳掌面積 ±0.18m 取最高」：物理上就是錯的——
		#   重心出了支撐面就該倒/掉，max 取樣讓人永久墊高在任何低物邊緣，
		#   而走查檢查用單點取樣＝同一條規則兩種算法，一夜炸出 400+ 筆浮空回歸。
		#   步兵支撐＝身體中心單點（重心在支撐面內才算踩著），與檢查同源。
		return gy
	var f: Vector3 = facing_dir()
	var r := Vector3(f.z, 0.0, -f.x)
	var sum := 0.0
	for sa in [-1.0, 1.0]:
		for sb in [-1.0, 1.0]:
			sum += float(ground_sampler.call(
					global_position + f * (VEH_HL * sa) + r * (VEH_HW * sb)))
	return maxf(gy, sum * 0.25)

func _stick_to_ground(delta: float) -> void:
	if not ground_sampler.is_valid():
		return
	var gy: float = _support_height()
	var dy: float = global_position.y - gy
	if dy > 0.02:
		# 在地面上方＝自由落體
		_fall_v -= GRAVITY * delta
		global_position.y += _fall_v * delta
		if global_position.y <= gy:
			global_position.y = gy
			_fall_v = 0.0
	elif dy < -0.6:
		# 深度穿地（比任何台階都深）＝狀態本身不合法：人不可能在山體裡面。
		# 陡坡上水平推進比 CLIMB_SPEED 快時會逐漸沉進坡體（ch11 壓測抓到 -2.64m），
		# 這種情況直接回貼地面——「地面把你推出來」沒有速度上限（鐵律 0①）。
		global_position.y = gy
		_fall_v = 0.0
	elif dy < -0.001:
		# 地面在腳底上方（踩上坡／被推上台階）：限速抬起，不瞬移
		global_position.y = minf(gy, global_position.y + CLIMB_SPEED * delta)
		_fall_v = 0.0
	else:
		_fall_v = 0.0
	_tilt_to_slope(delta)

# 站在斜坡上，身體軸線要隨坡面傾斜（鐵律 0 推論④）。
# ⚠ 只套在站姿與蹲姿：趴姿另有一整套骨骼寫入（見 _aim_pose 的 prone 段），
#   兩邊搶著寫同一個 transform 會互相抵銷——這是本專案踩過的老坑。
# ⚠ 傾斜寫在 _model 子節點，不可動 Unit 本體的 rotation（那是朝向，還被 IK 與彈道吃）。
const MAX_TILT_DEG := 22.0
func _tilt_to_slope(delta: float) -> void:
	if _model == null or _dead:
		return
	# ⚠ 舊版一遇趴姿就把傾斜歸零＝人趴在斜坡上是水平浮著（使用者 2026-07-27 指正）。
	#   當初關掉是怕跟趴姿骨骼互相抵銷，但趴姿寫的是**骨骼**、這裡寫的是**模型節點**，
	#   兩者不同層，不會打架。真正要改的是取樣尺度：站著只佔一個腳掌，
	#   趴著身體有 1.9m 長，靠 ±0.35m 取樣量不出他實際躺在什麼坡面上。
	# ⚠ 取樣尺度必須配合物體自己的尺寸（鐵律 0④）：站著只佔一個腳掌用 0.35m，
	#   趴著身體 1.9m 長用 0.95m，而**載具 6m 長**還用 0.35m 的話，量到的是地形雜訊
	#   而不是車身真正跨過的那片坡——結果就是車身傾斜角不對、一端插進土裡
	#   （2026-07-27 我自己的測試截圖拍到坦克埋在土丘裡）。
	var samp: float = lerpf(0.35, 0.95, clampf(_prone, 0.0, 1.0))
	if _is_vehicle:
		samp = VEH_HL * 0.7
	var n: Vector3 = _ground_normal(samp)
	# 把坡面法線轉到角色的局部座標，才知道要往前後還是左右傾
	var fwd: Vector3 = facing_dir()
	var right: Vector3 = Vector3(fwd.z, 0.0, -fwd.x)
	var pitch: float = clampf(asin(clampf(n.dot(fwd), -1.0, 1.0)), 
			-deg_to_rad(MAX_TILT_DEG), deg_to_rad(MAX_TILT_DEG))
	var roll: float = clampf(asin(clampf(n.dot(right), -1.0, 1.0)),
			-deg_to_rad(MAX_TILT_DEG), deg_to_rad(MAX_TILT_DEG))
	var k: float = clampf(delta * 8.0, 0.0, 1.0)
	_model.rotation.x = lerpf(_model.rotation.x, pitch, k)
	_model.rotation.z = lerpf(_model.rotation.z, -roll, k)

# 腳下坡面法線：用四點取樣（±0.35m）估斜率，不必動到 Terrain 的介面
func _ground_normal(d := 0.35) -> Vector3:
	if not ground_sampler.is_valid():
		return Vector3.UP
	var p: Vector3 = global_position
	var hx1: float = ground_sampler.call(p + Vector3(d, 0, 0))
	var hx0: float = ground_sampler.call(p - Vector3(d, 0, 0))
	var hz1: float = ground_sampler.call(p + Vector3(0, 0, d))
	var hz0: float = ground_sampler.call(p - Vector3(0, 0, d))
	return Vector3(-(hx1 - hx0) / (2.0 * d), 1.0, -(hz1 - hz0) / (2.0 * d)).normalized()

# 涉水（鐵律 0⑤：尺寸、速度一律真實量級）。
# ⚠ 先前 waters/shallows 只是一張半透明貼圖：人沉在 1.2m 深的水裡，照 3m/s 行軍、
#   姿勢不變、也不會被拖慢。deepwaters 有圍欄擋著，可涉的水反而完全沒有物理。
# 實測量級（美軍徒涉資料）：及膝 0.4m 約剩七成、及腰 0.9m 約剩四成、
# 及胸 1.3m 幾乎走不動。深過 0.35m 也不可能維持匍匐——臉會泡在水裡。
static var water_sampler: Callable = Callable()

func water_depth() -> float:
	if not water_sampler.is_valid() or _is_vehicle:
		return 0.0        # 載具涉水另有規則（履帶車可涉 1m），目前不套
	return float(water_sampler.call(global_position))

# 負重（鐵律 0⑤）：背 12kg 機槍與彈藥的人跟輕裝偵察兵不可能同速。
# 用 class_base 既有的 mobility 欄位當重量級別，不另外發明資料。
func load_mul() -> float:
	match String(GameData.class_base.get(cls, {}).get("mobility", "foot")):
		"scout": return 1.12
		"heavy": return 0.84
		_: return 1.0

# 傷勢（鐵律 0）：剩 1 滴血跟滿血跑一樣快是不合理的。
var hp_ratio := 1.0            # 由 Main 在扣血時更新
func hurt_mul() -> float:
	return 0.62 + 0.38 * clampf(hp_ratio, 0.0, 1.0)

# 體力（鐵律 0）：人不可能全速跑一整場。跑越久越慢，停下來會恢復。
# 只影響站姿移動——蹲行與匍匐本來就慢，再疊體力會變成完全動不了。
var stamina := 1.0
const STAM_DRAIN := 0.055      # 每秒消耗（全速時）
const STAM_REGEN := 0.10       # 每秒恢復（靜止時）
func stamina_mul() -> float:
	return 0.72 + 0.28 * clampf(stamina, 0.0, 1.0)

func _tick_stamina(delta: float, running: bool) -> void:
	if _dead:
		return
	if running and _prone < 0.5 and _crouch < 0.5:
		stamina = maxf(0.0, stamina - STAM_DRAIN * delta * maxf(1.0, speed_mul))
	else:
		stamina = minf(1.0, stamina + STAM_REGEN * delta)

# 加速度與慣性（鐵律 0：有質量的東西不會瞬間到全速、也不會瞬間停住）。
# ⚠ 停止用較大的減速度：人煞停確實比起步快，而且拖太久會影響「停在障礙前幾公尺」
#   這類量測的可讀性。3m/s 以 14m/s² 煞停＝滑行 0.32m，接近真實。
const ACCEL := 9.0
const DECEL := 14.0
var _vel := Vector3.ZERO

func wade_mul() -> float:
	var dep: float = water_depth()
	if dep <= 0.05:
		return 1.0
	return clampf(1.0 - dep * 0.63, 0.18, 1.0)

# 被槍聲吸引轉頭（GDD/15 F6）。只轉朝向、不移動，也不打斷正在做的事。
func face_towards_sound(dir: Vector3) -> void:
	if _dead or dir.length() < 0.01:
		return
	_heard_dir = Vector3(dir.x, 0, dir.z).normalized()
	_heard_t = 2.2
var _heard_dir := Vector3.ZERO
var _heard_t := 0.0

func _tick_hearing(delta: float) -> void:
	if _heard_t <= 0.0 or _dead or _dir_moving or _move_target != null or _shoot_target != null:
		return
	_heard_t -= delta
	rotation.y = lerp_angle(rotation.y, atan2(_heard_dir.x, _heard_dir.z),
			minf(1.0, TURN_SPEED * 0.5 * delta))

# 是否正在移動中（警戒射擊要判斷「誰在動」與「誰在原地警戒」）
func is_moving() -> bool:
	return (_move_target != null or _dir_moving) and not _dead

# 腳步聲（GDD/14 §音響）：依**實際走過的距離**計步，不是計時——
# 這樣蹲行、涉水、受傷變慢時步頻會自動跟著慢下來，不會出現「腳在地上打滑卻照常噠噠噠」。
var _step_acc := 0.0
const STEP_LEN := 0.78          # 成年人步幅約 0.75~0.8m
func _tick_steps(moved: float) -> void:
	if _dead or _is_vehicle:
		return
	if _prone > 0.5:
		return                  # 匍匐沒有腳步聲（這正是趴著前進的價值）
	_step_acc += moved
	if _step_acc < STEP_LEN:
		return
	_step_acc = 0.0
	var dep: float = water_depth()
	if dep > 0.08:
		_splash_fx(dep)              # 踩在水裡要濺水，不然人像走在玻璃上
	Audio.step(global_position, _crouch > 0.5 or dep > 0.08)

# 涉水水花（2026-07-28 使用者：「濺出來的水還是一樣太假」）。
# ★真因跟當年「火是發光方塊」完全同一個：**粒子用的是沒有貼圖的白色方片**。
#   1×1 的 unshaded 白 QuadMesh billboard 在畫面上就是一個白色正方形，
#   顏色、大小怎麼調都還是方形。這已經是同一個坑的第三次（火→煙→水花）。
# 真實的踩水是三件事同時發生，缺一件就假：
#   ① 水珠：小（2~6cm）、圓、有重量會落回水面、數量多
#   ② 水幕：腳掌推開的那一片薄水花，貼著水面往外散、扁平
#   ③ 漣漪：水面上擴散的圓環（這件最重要——沒有它，水花像是「在玻璃上撒白點」）
static var _drop_tex: GradientTexture2D = null
static func _drop_dot() -> GradientTexture2D:
	if _drop_tex != null:
		return _drop_tex
	# ⚠⚠ 一定要用 offsets/colors **陣列**一次設定。
	#   我第一版寫 set_offset(0,..) / add_point(..) / set_color(1,..)——
	#   `add_point` 是**依 offset 排序插入**的，插完之後索引 1 已經不是最後一點了，
	#   於是「最後一點設成全透明」實際上改到了中間那點，真正的最後一點保持
	#   Gradient 預設的**不透明白**。結果每一顆水珠外緣都是一圈實心白，
	#   十幾顆疊起來就是使用者截圖裡那團白色物體。
	#   （Main._soft_dot 當年就是用陣列寫的，我沒照抄才踩到。）
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.42, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 1.0), Color(1, 1, 1, 0.42), Color(1, 1, 1, 0.0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 48
	t.height = 48
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	_drop_tex = t
	return _drop_tex

func _splash_quad(sz: Vector2, col: Color, unshaded := true) -> QuadMesh:
	var qm := QuadMesh.new()
	qm.size = sz
	var mt := StandardMaterial3D.new()
	if unshaded:
		mt.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mt.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mt.albedo_color = col
	mt.albedo_texture = _drop_dot()          # ★柔邊：治「白色方片」
	mt.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if not unshaded else mt.blend_mode
	mt.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mt.cull_mode = BaseMaterial3D.CULL_DISABLED
	qm.material = mt
	return qm

func _splash_fx(dep: float) -> void:
	var k: float = clampf(dep / 0.9, 0.25, 1.0)      # 越深濺得越大
	var host := get_tree().current_scene
	if host == null:
		return
	var surf_y: float = global_position.y + minf(dep, 0.9) * 0.9
	# ① 水珠：小而多，有重力會落回水面
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 55.0
	pm.initial_velocity_min = 0.9 * k
	pm.initial_velocity_max = 2.6 * k
	pm.gravity = Vector3(0, -9.8, 0)
	# ⚠ 實測 ParticleProcessMaterial 的 scale_min/max 沒有生效（粒子仍以 1m 的方片在畫，
	#   用 1.75m 比例尺量出白團直徑 1.2m）。尺寸改成寫進 **QuadMesh 本身**，
	#   scale 只做小幅隨機——這樣不管那個屬性有沒有效，大小都是對的。
	pm.scale_min = 0.7
	pm.scale_max = 1.6                              # 2~5.5cm 的水珠（先前 4~11cm 太大）
	pm.damping_min = 0.4
	pm.damping_max = 1.2
	pm.color = Color(0.88, 0.94, 0.98)
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.16
	var ps := GPUParticles3D.new()
	ps.amount = 22
	ps.lifetime = 0.7
	ps.one_shot = true
	ps.explosiveness = 0.95
	ps.process_material = pm
	ps.draw_pass_1 = _splash_quad(Vector2(0.045, 0.045), Color(0.92, 0.96, 1.0, 0.75))
	ps.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	host.add_child(ps)
	ps.global_position = Vector3(global_position.x, surf_y, global_position.z)
	ps.emitting = true
	# ② 水幕：貼著水面往外散的扁平薄片（腳掌推開的那一片）
	var pm2 := ParticleProcessMaterial.new()
	pm2.direction = Vector3(0, 0.25, 0)
	pm2.spread = 88.0                                  # 幾乎是平的一圈
	pm2.initial_velocity_min = 1.2 * k
	pm2.initial_velocity_max = 2.4 * k
	pm2.gravity = Vector3(0, -6.0, 0)
	pm2.scale_min = 0.7
	pm2.scale_max = 1.5
	pm2.damping_min = 2.0
	pm2.damping_max = 4.0
	pm2.color = Color(0.92, 0.96, 1.0)
	pm2.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm2.emission_sphere_radius = 0.20
	var ps2 := GPUParticles3D.new()
	ps2.amount = 12
	ps2.lifetime = 0.42
	ps2.one_shot = true
	ps2.explosiveness = 1.0
	ps2.process_material = pm2
	ps2.draw_pass_1 = _splash_quad(Vector2(0.10, 0.075), Color(0.94, 0.97, 1.0, 0.40))
	ps2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	host.add_child(ps2)
	ps2.global_position = Vector3(global_position.x, surf_y + 0.02, global_position.z)
	ps2.emitting = true
	# one-shot 粒子要自己收：涉水走一段路會留下幾百個節點（舊版就有這個漏）
	get_tree().create_timer(1.2).timeout.connect(func():
		if is_instance_valid(ps): ps.queue_free()
		if is_instance_valid(ps2): ps2.queue_free())
	# ③ 水面漣漪：一個貼著水面擴散的圓環。少了這件，水花像「在玻璃上撒白點」。
	var ring := MeshInstance3D.new()
	var rq := QuadMesh.new()
	rq.size = Vector2(0.42, 0.42)
	ring.mesh = rq
	var rmat := StandardMaterial3D.new()
	rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rmat.albedo_color = Color(0.95, 0.98, 1.0, 0.38)
	rmat.albedo_texture = _ring_tex()
	rmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	rq.material = rmat
	ring.rotation_degrees.x = -90.0                    # 平躺在水面上
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	host.add_child(ring)
	ring.global_position = Vector3(global_position.x, surf_y + 0.012, global_position.z)
	var tw := ring.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector3.ONE * (2.4 * k), 0.9).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(rmat, "albedo_color:a", 0.0, 0.85)
	tw.chain().tween_callback(ring.queue_free)

# 漣漪圓環貼圖：中空的環（不是實心圓——實心圓擴散起來是一團白霧，不是漣漪）
static var _ring_texture: GradientTexture2D = null
static func _ring_tex() -> GradientTexture2D:
	if _ring_texture != null:
		return _ring_texture
	# 中空的環（實心圓擴散起來是一團白霧，不是漣漪）。同樣用陣列設定。
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.70, 0.84, 0.94, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.0),
			Color(1, 1, 1, 0.85), Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 96
	t.height = 96
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	_ring_texture = t
	return _ring_texture

# 沒有輸入時把殘速滑完（由 _process 每幀呼叫）。人放開腳步不會瞬間釘在地上。
# ⚠ 2026-07-27 使用者規格：「不會有原地跑步，停下就停下，沒有按按鍵就不會走」。
#   我先前為了「慣性」加了放開鍵後的滑行——那違反這條規格，已移除。
#   起步仍保留加速度（那不會造成「沒按鍵還在動」），但**放開鍵就是立刻停**。
func _coast(delta: float) -> void:
	_tick_stamina(delta, false)
	_vel = Vector3.ZERO

# 第三人稱直接操控（GDD/07）：每幀給一個世界方向就走，不設目的地。
# 與點擊移動共用同一套 AP 扣除（Main._action_tick 量的是「實際位移」，兩種都吃得到）。
var _dir_moving := false
# 近期實際淨位移（判斷「有沒有真的在前進」，用來擋掉原地跑步）
var _moved_recent := 1.0
var _win_from := Vector3.ZERO
var _move_win := 0.0
func move_dir(dir: Vector3, delta: float) -> void:
	if _dead or dir.length() < 0.01:
		return
	_move_target = null
	_shoot_target = null
	_busy_until = 0.0
	_dir_moving = true
	var d := Vector3(dir.x, 0, dir.z).normalized()
	rotation.y = lerp_angle(rotation.y, atan2(d.x, d.z), minf(1.0, TURN_SPEED * 0.6 * delta))
	# 趴著移動＝匍匐前進，不是趴著跑。播跑步動畫會讓腿在跑、手臂在擺，
	# 而軀幹又被趴姿骨骼壓平——畫面上就是自由式游泳（使用者 2026-07-26 指正）。
	if _prone > 0.5:
		# ★脈動式前進（使用者 2026-07-26：「腿在動但完全不像真的在移動」）：
		#   等速平移＋腿在擺動＝人被拖著滑行。真實匍匐是「一蹬一停」——蹬地那下
		#   往前衝，收腿時幾乎不動。速度必須跟著蹬地相位走，腳才不會在地上打滑。
		#   |sin| 的平均值是 2/π≈0.637，除掉它才能維持設定的平均速度。
		_crawl += delta * CRAWL_RATE
		# 左右腿交替蹬地＝一個週期推進兩次；|sin| 的平均是 2/π≈0.637
		# ⚠ 2026-07-27 修正相位：舊版用 |sin(_crawl)|，峰值落在「收腿收到底」那一刻，
		#   等於膝蓋往前收的同時身體也往前衝——腳在地上是往前刮的，看起來就是打滑。
		#   身體只能在**髖伸展（腿往後蹬）**那半段前進，也就是收腿量由大變小的時候。
		#   左腿的收放區間是 sin>0、右腿是 sin<0，各自「正在變小」的那半段才算蹬地。
		var cs: float = cos(_crawl)
		var sn: float = sin(_crawl)
		var drive := 0.0
		if sn > 0.0 and cs < 0.0:
			drive = -cs           # 左腿正在往後蹬
		elif sn < 0.0 and cs > 0.0:
			drive = cs            # 右腿正在往後蹬
		# drive 在整個週期的平均是 1/π≈0.3183，除掉它才能維持設定的平均速度
		var thrust: float = (0.12 + 0.88 * drive) / 0.4001
		global_position += d * PRONE_SPEED * thrust * wade_mul() * hurt_mul() * delta
		_prone_hold += delta        # 持續走就會超過門檻，_update_crouch 會讓他起身
		_play("idle")          # 腿與軀幹全交給 _aim_pose 的匍匐擺動，動畫層不要插手
		return
	_tick_stamina(delta, true)
	var spd: float = WALK_SPEED * (0.45 if _crouch > 0.5 else speed_mul) 			* wade_mul() * load_mul() * hurt_mul() * stamina_mul()
	_vel = _vel.move_toward(d * spd, ACCEL * delta)
	global_position += _vel * delta
	_tick_steps(_vel.length() * delta)
	# ★動畫必須跟著**實際位移**，不是跟著按鍵。被牆或雜物擋住時人根本沒有前進，
	#   卻照播跑步動畫＝原地跑步（使用者 2026-07-27 指正）。
	#   淨位移由 Main 的碰撞解算之後才知道，所以看的是「上一小段實際走了多遠」。
	_move_win += delta
	if _move_win >= 0.25:
		_moved_recent = global_position.distance_to(_win_from)
		_win_from = global_position
		_move_win = 0.0
	if _moved_recent < 0.03:
		_play("idle")            # 推不動就站著推，不要空踩腳
		return
	if _crouch > 0.5 and anim_names.has("crouch_walk"):
		_play("crouch_walk")
	else:
		_play("run" if anim_names.has("run") else "walk")

# 目前姿勢的「眼睛高度」（GDD/07）：第三人稱鏡頭要跟著姿勢降下來。
# 趴著時鏡頭還吊在站姿的 1.52m，人會被草叢淹沒、玩家看不到自己在哪（實拍到）。
# 趴姿不取真實眼高（那太貼地，整個畫面都是草），取略高於身體的 0.95m。
func eye_height() -> float:
	return lerpf(lerpf(1.52, 1.05, clampf(_crouch, 0.0, 1.0)), 0.95, clampf(_prone, 0.0, 1.0))

# 槍口高度（公尺）：彈道從這裡射出。跟眼高不同——出槍的手比眼睛低，
# 趴姿更明顯（貼地出槍 0.32m），這個差距就是「趴在沙包後面根本射不出去」的來源。
# 槍口／抵肩點的世界座標（[clipchk] 用：要能量出槍有沒有插進固體）
func muzzle_point() -> Vector3:
	return _muzzle_world

func gun_src_point() -> Vector3:
	return _gun_src_world

func muzzle_block() -> float:
	return _muzzle_block

func muzzle_height() -> float:
	return lerpf(lerpf(1.32, 0.92, clampf(_crouch, 0.0, 1.0)), 0.32, clampf(_prone, 0.0, 1.0))

# 軀幹中心高度（公尺）：被瞄的點。彈道要打到這個高度才算命中得到。
func torso_height() -> float:
	return lerpf(lerpf(1.15, 0.78, clampf(_crouch, 0.0, 1.0)), 0.28, clampf(_prone, 0.0, 1.0))

# 身體最高點（公尺）＝頭頂。彈道要「比這個高」才飛得過這個人的頭上（鐵律 0①：
# 人也是固體，不會讓子彈穿過去）。趴著的人只有 0.55m，站著擋到 1.75m——
# 所以「隊友趴下讓火線」在這裡是真的成立的，不是演出。
func body_top() -> float:
	return lerpf(lerpf(1.75, 1.22, clampf(_crouch, 0.0, 1.0)), 0.55, clampf(_prone, 0.0, 1.0))

func move_to(p: Vector3) -> void:
	if _dead: return
	_shoot_target = null
	_busy_until = 0.0        # 移動命令要能打斷修理/佔領這類一次性動作，否則玩家點了不動
	_move_target = Vector3(p.x, 0.0, p.z)

func shoot_at(target: Unit) -> void:
	if _dead: return
	if _is_vehicle:
		_move_target = null
		_shoot_target = target
		_shoot_timer = 0.6                     # 砲塔轉過去要時間
		aim_point = target.global_position + Vector3(0, 1.2, 0)
		return
	# 合理化時序：轉身 → 舉槍(aim) → 0.3s 後 shoot 並發曳光
	_move_target = null
	_shoot_target = target
	_shoot_timer = 0.3
	aim_point = target.global_position + Vector3(0, 1.2, 0)   # 瞄胸口，槍口會依高低差自動抬壓
	_face_towards(target.global_position, 1.0)
	_play("aim", 0.12)

func take_hit() -> void:
	if _dead: return
	if _is_vehicle:
		_tint(_model, Color(1.0, 0.5, 0.2), 0.35)   # 載具沒有受擊動作，用車體閃紅代替
		return
	var now := Time.get_ticks_msec() / 1000.0
	_play("hit", 0.05)
	_busy_until = now + max(0.4, _clip_len("hit"))

func die() -> void:
	if _dead: return
	if _is_vehicle:
		_dead = true
		_move_target = null
		_shoot_target = null
		_die_fade = 2.0
		_tint(_model, Color(0.12, 0.12, 0.12), 0.6)  # 燒焦
		return
	_dead = true
	_move_target = null
	_shoot_target = null
	_play("death", 0.1)
	_die_fade = max(1.0, _clip_len("death"))   # 播完死亡動畫再淡出移除

func _face_towards(p: Vector3, k: float) -> void:
	var d := p - global_position
	d.y = 0.0
	if d.length() < 0.05: return
	rotation.y = lerp_angle(rotation.y, atan2(d.x, d.z), k)

# 槍械尺度補償：BoneAttachment 的世界縮放要等節點進場景樹才算得準
# （soldier.glb 掛點世界縮放極大，不補償這把 0.5m 的槍會變成 80+ 公尺長條＝「灰色巨牆」）。
func _fix_gun_scale() -> void:
	# 只校正一次：校正後槍即自然跟隨手骨擺動。
	# 若每幀重算會把槍鎖成永遠水平朝前，走路時手在擺、槍不動，反而脫節。
	if _gun_fixed or _gun_mount == null or _gun_node == null:
		return
	if not is_inside_tree() or not _gun_mount.is_inside_tree():
		return
	_gun_fixed = true
	# ⚠ 校正必須在「瞄準姿勢」下做，不能用第一幀的垂手靜止姿：
	#   校正完槍就固定跟著手骨走，若基準是垂手姿，動畫把手抬起來時槍口會跟著翹上天。
	if _gun_fix_wait < 6:
		_gun_fix_wait += 1
		_gun_fixed = false
		return
	# 動態對齊：讀「手腕在模型空間的朝向」反算，使槍口朝角色正前、瞄具朝上，
	# 不論模型/動畫幀差異都成立（治火箭筒指天、狙擊槍穿身）。
	# 以 Unit 本體為參考（_model 內部另有正面軸校正，拿它當基準會對錯方向）
	var wrist := (global_transform.affine_inverse() * _gun_mount.global_transform).basis.orthonormalized()
	var ws := _gun_mount.global_transform.basis.get_scale()
	var s: float = (absf(ws.x) + absf(ws.y) + absf(ws.z)) / 3.0
	if s < 0.0001:
		s = 1.0
	var desired := Basis.IDENTITY     # 程式生成的武器：槍口已是 +Z
	var scale_f := 1.0
	var grip := Vector3.ZERO
	if _gun_node is MeshInstance3D and WEAPON_MODEL.has(cls):
		var ab: AABB = (_gun_node as MeshInstance3D).get_aabb()
		var raw: float = ab.size.x
		if raw > 0.0001:
			scale_f = float(WEAPON_MODEL[cls][1]) / raw   # 依真實槍長換算，各槍網格尺寸不一
		desired = Basis(Vector3(0, 0, 1), Vector3(0, 1, 0), Vector3(-1, 0, 0))   # 槍管 +X → 角色正前 +Z
		# 握把柄：槍身後端往前 30%、下緣往上 46%（取槍管中線會讓槍浮在手掌上方）
		grip = Vector3(ab.position.x + 0.30 * raw, ab.position.y + 0.46 * ab.size.y, ab.get_center().z)
	var b := (wrist.inverse() * desired).scaled(Vector3.ONE * (scale_f / s))
	_gun_node.transform = Transform3D(b, -(b * grip))
	_gun_carry_xf = _gun_node.transform

# 蹲姿：Quaternius 動畫組沒有 crouch，故以「壓低身體＋前傾」模擬躲在掩體後。
# 移動中一律站起（跑步蹲著不合理）。
func _update_crouch(delta: float) -> void:
	if _model == null or _is_vehicle:
		return
	# 鬆開方向鍵就重置：停下來重新臥射，再走又是一次短距離匍匐
	if not _dir_moving and _move_target == null:
		_prone_hold = maxf(0.0, _prone_hold - delta * 2.0)
	# 玩家按鍵優先：按了趴就趴（而且不受 PRONE_BREAK_T 自動起身限制——
	# 那條是給「自動臥射」用的，玩家明確要趴就不該被系統拉起來）。
	var ptarget := 0.0
	if stance_cmd == "prone":
		ptarget = 1.0 if not _dead else 0.0
	elif stance_cmd == "" and auto_stance:
		# ⚠ 玩家操控期間連「自動臥射」也要關（2026-07-27 實測 [movechk]：
		#   狙擊手一被下令就自動趴下，玩家按 W 只能以 0.24~0.8m/s 匍匐，
		#   畫面上就是「人不會動」——跟使用者抱怨的自動蹲是同一個病）。
		ptarget = 1.0 if (want_prone and not _dead and _move_target == null
				and _prone_hold < PRONE_BREAK_T) else 0.0
	# 水深過腳踝就趴不下去：臉會泡在水裡（鐵律 0：現實怎樣就怎樣）。
	# 這條凌駕玩家按鍵——按 Z 也趴不進 0.5m 的水裡，這不是操作限制是物理。
	if water_depth() > 0.35:
		ptarget = 0.0
	_prone = move_toward(_prone, ptarget, delta * 2.4)
	# 掩體區內小幅移動＝蹲行（真人在掩體後不會站起來走）；長距離移動才站起來跑。
	var short_hop: bool = _move_target != null and global_position.distance_to(_move_target) < CROUCH_WALK_MAX
	var stay_low: bool = auto_stance and want_cover and not _dead and (_move_target == null or short_hop)
	if stance_cmd == "crouch":
		stay_low = not _dead
	elif stance_cmd == "stand" or stance_cmd == "prone":
		stay_low = false
	var target: float = 0.0 if _prone > 0.01 else (1.0 if stay_low else 0.0)
	_crouch = move_toward(_crouch, target, delta * 3.2)
	# 起身還原：趴姿把 _model.position.y 壓下去 1m 多，解除趴姿時那行就不再執行，
	# y 會卡在低位＝人陷在地面下（實測髖高 -0.05m）。兩個姿勢都歸零時要把高度收回來。
	# ⚠ 這是唯一的例外：只在「沒有任何姿勢在寫高度」時才動，不會跟 _aim_pose 搶。
	# ⚠ 條件不是「_crouch 也要歸零」：這副骨架有真人蹲姿動畫，手寫蹲姿那段根本不執行，
	#   於是 _crouch=1 時沒有任何人在寫 y，趴姿殘留的下壓就永遠留著（實測髖高 -0.05m）。
	#   判準是「有沒有人正在手寫高度」，不是「蹲了沒」。
	var hand_crouch: bool = _crouch > 0.001 and not anim_names.has("crouch")
	if _model != null and _prone <= 0.02 and not hand_crouch:
		_model.position.y = move_toward(_model.position.y, _model_base_y, delta * 2.5)
	# ⚠ 這裡只更新混合值，不碰模型位置/旋轉。
	# 姿勢與貼地一律由 _aim_pose（骨架更新後）負責——兩邊都寫會互相抵銷，
	# 症狀是「蹲下去又被推回來」，看起來像只把腳塞進地裡（2026-07-25 實測）。
	if _rig == null:
		_model.rotation.x = 0.13 * _crouch
		_model.position.y = _model_base_y - 0.42 * _crouch   # 無骨架工具的模型：沿用舊權宜做法
		_model.rotation.x = 0.0

func _process(delta: float) -> void:
	_stick_to_ground(delta)
	_align_ring()
	if _is_vehicle:
		_vehicle_process(delta)
		return
	_fix_gun_scale()
	_fix_gear()
	# 重定向模式：模型本身沒有動畫在寫骨骼，skeleton_updated 永遠不會發，
	# 所以姿勢必須由這裡主動驅動（也不會與任何動畫打架，因為根本沒有）。
	if _retarget:
		_on_skeleton_updated()
	_recoil = maxf(0.0, _recoil - delta * RECOIL_DECAY)
	_update_crouch(delta)
	if _dead:
		_die_fade -= delta
		if _die_fade <= 0.4 and _model:      # 動畫播完後最後 0.4s 淡出
			var k: float = clamp(_die_fade / 0.4, 0.0, 1.0)
			_fade(k)
		if _die_fade <= 0.0:
			queue_free()
		return
	var now := Time.get_ticks_msec() / 1000.0
	if _shoot_target != null:
		_face_towards(_shoot_target.global_position, 0.5)
		aim_point = _shoot_target.global_position + Vector3(0, 1.2, 0)
		_shoot_timer -= delta
		if _shoot_timer <= 0.0:
			_play("shoot", 0.05)
			_busy_until = now + max(0.5, _clip_len("shoot"))
			_shots += 1
			if _shots % SHOTS_PER_MAG == 0:
				_reload_at = _busy_until          # 這一發打完接著換彈匣
			_recoil = 1.0
			_muzzle_flash()
			# 槍聲從槍口發出（3D 音源）。先前開一槍是完全靜音的。
			Audio.gun(String(GameData.class_base.get(cls, {}).get("wtype", "rifle")),
					_muzzle_world if _muzzle_world != Vector3.ZERO
					else global_position + Vector3(0, 1.35, 0))
			shot_fired.emit(global_position + Vector3(0, 1.35, 0),
					_shoot_target.global_position + Vector3(0, 1.2, 0))
			_shoot_target = null
			aim_point = null
		return
	if _dir_moving:
		_dir_moving = false          # 由 Main 每幀重新設定；沒設就代表玩家鬆開了方向鍵
		return
	_coast(delta)                    # 鬆開方向鍵後把殘速滑完（慣性）
	_tick_hearing(delta)             # 聽到槍聲會轉頭
	if now < _busy_until:
		return
	# 換彈：射擊動作播完才接，否則會蓋掉開槍那一下
	if _reload_at > 0.0 and now >= _reload_at:
		_reload_at = 0.0
		Audio.reload_click(global_position + Vector3(0, 1.1, 0))
		if anim_names.has("reload"):
			_play("reload", 0.12)
			_busy_until = now + max(0.6, _clip_len("reload"))
			return
	if _move_target != null:
		var d: Vector3 = _move_target - global_position
		d.y = 0.0
		if d.length() < 0.15:
			_move_target = null
			_play("idle")
			arrived.emit()
			return
		# VC 做法：先轉身面向目標，面向差太大時原地轉身不前進（治「面向一個方向跑」）
		var target_yaw := atan2(d.x, d.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, min(1.0, TURN_SPEED * delta))
		var ang := absf(wrapf(target_yaw - rotation.y, -PI, PI))
		if ang > 0.6:
			_play("idle")        # 還沒轉正：原地轉身
		else:
			var stp: float = (WALK_SPEED * (0.45 if _crouch > 0.5 else speed_mul)
					* wade_mul() * load_mul() * hurt_mul()) * delta
			global_position += d.normalized() * stp
			_tick_steps(stp)
			if _crouch > 0.5 and anim_names.has("crouch_walk"):
				_play("crouch_walk")              # 蹲行：掩體後移動不站起來
			elif speed_mul > 1.5 and anim_names.has("sprint"):
				_play("sprint")                   # 加速行軍用衝刺動作，腳步才跟得上速度
			else:
				_play("run" if anim_names.has("run") else "walk")
	# ⚠⚠ 條件不可以只看 `want_cover`（＝自動掩體判定）：玩家按 C 是寫 `stance_cmd`，
	#   於是「_crouch 混合值到 1、但動畫還是站姿」——畫面上人根本沒有蹲下去。
	#   ★而且 `-- play` 斷言 `_crouch == 1.00` 照樣通過（2026-07-27 連拍才抓到）：
	#     這正是「這個數字在錯誤情況下會不會也通過？」那條教訓的又一次現形。
	#   判準要用**實際的蹲姿混合值**，它同時涵蓋自動判定與玩家按鍵兩條路。
	elif _crouch > 0.5 and _prone < 0.5 and anim_names.has("crouch"):
		_play("crouch")   # 有真人蹲姿動作（UAL Crouch_Idle 重定向）就直接播，不再用幾何硬湊
		# ⚠ 趴著時不可以播蹲姿動畫：那支動作會寫滿全身骨骼，再被趴姿覆寫等於兩層打架
	elif _state in IDLE_BACK:
		_play("idle")

# 載具每幀：沒有動畫狀態機，只有「轉向→前進」與砲塔瞄準。
const VEH_ACCEL := 1.6         # 履帶車起步加速度（m/s²）
const VEH_DECEL := 2.4         # 煞停
var _veh_spd := 0.0

func _vehicle_process(delta: float) -> void:
	_aim_turret(delta)
	if _dead:
		_die_fade -= delta
		if _model:
			_model.position.y = lerpf(_model.position.y, -0.35, minf(1.0, delta * 1.5))   # 中彈後車體下沉
			_model.rotation.z = lerpf(_model.rotation.z, 0.12, minf(1.0, delta * 1.2))
		if _die_fade <= 0.6:
			_fade(clampf(_die_fade / 0.6, 0.0, 1.0))
		if _die_fade <= 0.0:
			queue_free()
		return
	var now := Time.get_ticks_msec() / 1000.0
	if _shoot_target != null:
		aim_point = _shoot_target.global_position + Vector3(0, 1.2, 0)
		_shoot_timer -= delta
		if _shoot_timer <= 0.0:
			_busy_until = now + 0.8
			shot_fired.emit(_muzzle_pos(), _shoot_target.global_position + Vector3(0, 1.2, 0))
			_recoil = 1.0
			_shoot_target = null
			aim_point = null
		return
	_recoil = maxf(0.0, _recoil - delta * RECOIL_DECAY)
	if _turret:
		_turret.position.z = -0.35 - 0.25 * _recoil          # 火砲後座
	if now < _busy_until:
		return
	if _move_target != null:
		var d: Vector3 = _move_target - global_position
		d.y = 0.0
		if d.length() < 0.25:
			_move_target = null
			arrived.emit()
			return
		var yaw := atan2(d.x, d.z)
		# ⚠ 載具慣性（鐵律 0）：30 噸的車不可能瞬間到速、瞬間停住，也不可能原地打轉
		#   之後立刻全速前進。加速度取 1.6m/s²、煞停 2.4m/s²（履帶車實際量級），
		#   而且**轉向速率隨速度下降**——高速時轉不動，這就是轉向半徑。
		var turn_rate: float = VEH_TURN / (1.0 + _veh_spd * 0.55)
		rotation.y = lerp_angle(rotation.y, yaw, minf(1.0, turn_rate * delta))
		var ang := absf(wrapf(yaw - rotation.y, -PI, PI))
		var want: float = (VEH_SPEED * speed_mul) if ang < 0.35 else 0.0
		var rate: float = VEH_ACCEL if want > _veh_spd else VEH_DECEL
		_veh_spd = move_toward(_veh_spd, want, rate * delta)
		if _veh_spd > 0.01:
			global_position += facing_dir() * _veh_spd * delta   # 只能往車頭方向走

# 砲口世界座標（曳光/火光起點）
func _muzzle_pos() -> Vector3:
	if _turret == null:
		return global_position + Vector3(0, 1.6, 0)
	return _turret.global_transform * Vector3(0, 0.34, 1.9 + _barrel_len)

func _fade(k: float) -> void:
	for m in _model.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var cnt: int = maxi(mi.get_surface_override_material_count(), 1)
		for si in cnt:
			var mm := mi.get_active_material(si)
			if mm is StandardMaterial3D:
				var d := (mm as StandardMaterial3D).duplicate()
				d.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				d.albedo_color.a = k
				mi.set_surface_override_material(si, d)

# 程式化持槍姿（GDD/13，2026-07-25）：模型自帶動畫是「單手指槍」，長槍必須雙手才合理。
# 作法同真實遊戲的疊加瞄準層：槍托抵右肩、槍口指向目標，再用 IK 把兩隻手抓上槍。
# 移動中不套用（跑步時雙手鎖在槍上會與跑步動畫打架），改回攜行姿。
# ★★時間積分只能算一次／幀（2026-07-27）。
#   本函式掛在 `skeleton_updated` 上，而收尾的 force_update_all_bone_transforms()
#   會讓訊號在同一幀再發一次 → 一幀跑兩次。裡面 `move_toward(…, 每幀固定量)` 這類
#   逐幀積分因此被算兩次：第二次讀到的 `_dir_moving` 已經被 Unit._process 清掉，
#   `+0.06` 當場被 `-0.06` 抵銷，匍匐擺動永遠停在 0（[crawlchk] 三項一起 FAIL）。
#   ⚠ 通則：任何「每幀累加/收斂」的狀態都不可以寫在一幀可能被呼叫多次的回呼裡。
var _pose_frame := -1

func _aim_pose() -> void:
	if not _gun_armed or _rig == null or _gun_node == null or not _gun_fixed or _model == null:
		return
	var fresh: bool = int(Engine.get_process_frames()) != _pose_frame
	_pose_frame = int(Engine.get_process_frames())
	var sks := _model.find_children("*", "Skeleton3D", true, false)
	if sks.is_empty():
		return
	var sk := sks[0] as Skeleton3D
	if USE_RETARGET_CROUCH and not _crouch_pose.is_empty() and _crouch > 0.001:
		_rig.blend_pose(_crouch_pose, _crouch, false)   # 先蹲，IK 再疊上去；髖位移交給模型下壓
	# 趴姿（2026-07-25 重做）：UAL 動作庫沒有 prone，只能程式化。
	# ⚠ 不可用「把整個模型 rotation.x 轉 90°」——模型節點另有正面軸校正，
	#   轉出來的軸不對，而且腳會翹到天上。改成骨骼層：髖部與雙腿一起繞髖關節前倒，
	#   再把整個人降到地面高度。腿必須一起 orbit，因為它們掛在 Root 不跟髖部走。
	if _prone > 0.001:
		var fwd := facing_dir()
		var rgt := global_basis.x.normalized()        # 旋轉軸用（角度照這個軸調出來的）
		var rgt_pos := right_dir()                    # ★位置用：大腿左右擺放，用錯會兩腿交叉
		var hips: Vector3 = _rig.bone_pos("Hips")
		# 軀幹：脊椎方向指向前上方（臥射是上身微抬、以雙肘撐地，不是整個人壓平）
		_rig.point_bone("Hips", "Abdomen", (fwd * 0.92 + Vector3.UP * 0.39).normalized(), _prone)
		# 頭抬起來看前方（鐵律 0：人在匍匐時要觀察前方，不是把臉埋進土裡——實拍抓到）
		_rig.add_world_rotation("Neck", rgt, deg_to_rad(-24.0) * _prone)
		_rig.add_world_rotation("Head", rgt, deg_to_rad(-20.0) * _prone)
		# 匍匐擺動（2026-07-26）：靜止臥射時 sw 全為 0＝原本的姿勢，一動才擺。
		# 匍匐的辨識特徵是「一腿屈膝外張蹬地、身體隨之側滾」，不是雙腿一起划。
		var crawling: float = 1.0 if (is_moving() and _prone > 0.5) else 0.0
		if fresh:
			_crawl_amt = move_toward(_crawl_amt, crawling, 0.06)  # 起停要漸進，否則會抽一下
		if _crawl_amt > 0.001:
			# 身體隨著蹬地的那一腿側滾——這是匍匐看起來「有在使力」的來源
			_rig.add_world_rotation("Hips", fwd, deg_to_rad(11.0) * sin(_crawl) * _crawl_amt)
			_rig.add_world_rotation("Abdomen", fwd, deg_to_rad(6.0) * sin(_crawl) * _crawl_amt)
			# ★骨盆偏擺（蛇行）：收右腿時骨盆往右轉、蹬地時轉回——真實匍匐的軀幹是
			#   S 形蠕動，不是一塊硬板往前滑（實拍側視三格全程僵直，這是「像被拖著走」
			#   剩下的最大原因；膝蓋動作在身體另一側，側視根本看不到）。
			_rig.add_world_rotation("Hips", Vector3.UP, deg_to_rad(10.0) * sin(_crawl) * _crawl_amt)
			_rig.add_world_rotation("Abdomen", Vector3.UP, deg_to_rad(-6.0) * sin(_crawl) * _crawl_amt)
			# 上身在蹬地瞬間撐起、收腿時放低（跟 bob 同相位）：肘撐的動作感
			_rig.add_world_rotation("Abdomen", rgt, deg_to_rad(-7.0) * sin(_crawl * 2.0) * _crawl_amt)
		# ★腿：蛙式（使用者 2026-07-26 親自定義的規格）
		#   「膝蓋彎曲 30-45 度，胯下整個向外 30-45 度，然後身體向前，再換腳」
		#   先前是大腿方向從正後方擺到正前方＝**鐘擺**，側視就是腿在地上前後掃。
		#   蛙式是：大腿在**水平面上向外張開**（髖外展），膝同時彎、小腿收向中線，
		#   蹬完伸直收回，換另一腿。角度直接用度數算，不再用向量係數硬湊
		#   （湊出來的角度沒人知道實際幾度，也就無法對照使用者給的規格）。
		for sd in ["L", "R"]:
			var sgn: float = -1.0 if sd == "L" else 1.0
			# 左右腿相位差半圈＝交替（使用者：「再換腳」）
			var ph: float = _crawl + (0.0 if sd == "L" else PI)
			var ab: float = maxf(sin(ph), 0.0) * _crawl_amt      # 0=併攏 1=張到最開
			_rig.place_bone("UpperLeg." + sd,
					hips + rgt_pos * sgn * (0.07 + 0.06 * ab) - fwd * 0.02, _prone)
			# 大腿：由「正後方」在水平面往外轉（髖外展 12°→42°），全程貼地
			var abd: float = deg_to_rad(PRONE_HIP_BACK
					+ (PRONE_HIP_UP - PRONE_HIP_BACK) * ab)
			var thigh: Vector3 = (-fwd).rotated(Vector3.UP, abd * sgn)
			thigh = (thigh - Vector3.UP * 0.06).normalized()
			_rig.point_bone("UpperLeg." + sd, "LowerLeg." + sd, thigh, _prone)
			# 小腿：由大腿再往身體中線轉＝屈膝。與大腿的夾角就是膝角度（8°→44°），
			# 所以「膝蓋彎 30-45 度」是寫死的規格，不是湊出來的。
			var knee: float = deg_to_rad(PRONE_KNEE_MIN
					+ (PRONE_KNEE_MAX - PRONE_KNEE_MIN) * ab)
			var shin: Vector3 = thigh.rotated(Vector3.UP, -knee * sgn)
			shin = (shin - Vector3.UP * 0.05).normalized()
			_rig.point_bone("LowerLeg." + sd, "Foot." + sd, shin, _prone)
		# 腳掌壓平：趴著的人腳背貼地、腳尖朝後外側。先前沒管腳掌，它跟著小腿翹向天空。
		for sd2 in ["L", "R"]:
			var fi: int = sk.find_bone("Foot." + sd2)
			if fi >= 0:
				_rig.point_bone("LowerLeg." + sd2, "Foot." + sd2,
						(-fwd * 0.92 - Vector3.UP * 0.39).normalized(), _prone * 0.55)
		# 貼地：量髖部離地多少，整個模型降下去（只有這裡寫高度，避免兩處互相抵銷）
		# ⚠ 要用「相對目前位置再修正」的收斂寫法：寫成 base - (量到的高度) 會左右震盪
		#   （量到的高度本身就含上一幀的修正量），畫面上就是趴著上下抖。
		# 身體隨著蹬地起伏：撐起→前送→落下。少了這個，整個人像貼在地板上平移。
		var bob: float = 0.030 * sin(_crawl * 2.0) * _crawl_amt
		var hip_y: float = _rig.bone_pos("Hips").y - global_position.y
		_model.position.y = clampf(_model.position.y - (hip_y - (PRONE_H + bob)) * _prone,
				_model_base_y - 1.2, _model_base_y + 0.1)
	# 蹲姿（換法 2026-07-25）：不再猜骨頭該繞哪個軸轉——那條路三個軸實測都失敗。
	# 改用「壓低身體 → 用 IK 把雙腳釘回地面」，膝蓋就會被幾何關係自然頂彎。
	# 這是真實遊戲做無動畫蹲姿的標準手法，且沿用已驗證可用的雙骨 IK（手臂誤差僅 6cm）。
	# ⚠ 除錯提醒：在 skeleton_updated 內「當幀讀回」骨骼位置會拿到舊值，
	#   看起來像 IK 沒作用，其實畫面是對的——要看渲染結果，不要信同幀讀數。
	# 蹲姿（2026-07-25 定案）：手寫屈膝 + 依「小腿末端」自動貼地。
	# 先前判定「三個軸都無效」是誤判——量尺用了 Foot 骨，
	# 而此骨架的 Foot 父階是 Root、不跟著腿動，量到的永遠是同一個數。
	if _crouch > 0.001 and not anim_names.has("crouch"):
		_model.position.z = 0.0
		_model.rotation.x = 0.0
		var rightax := global_basis.x.normalized()
		_rig.add_world_rotation("Abdomen", rightax, deg_to_rad(20.0) * _crouch)   # 上身前傾，去掉坐姿感
		_rig.add_world_rotation("Torso", rightax, deg_to_rad(10.0) * _crouch)
		for sd in ["L", "R"]:
			_rig.bend_bone("UpperLeg." + sd, LEG_AXIS, 18.0, _crouch)
			_rig.bend_bone("LowerLeg." + sd, LEG_AXIS, -26.0, _crouch)
		# 自動貼地：用小腿末端當腳踝，把身體降到剛好踩地（不再猜固定位移）
		var ankle: Vector3 = _rig.leg_end("LowerLeg.L", "Foot.L")
		if ankle != Vector3.ZERO:
			var drop: float = ankle.y - (global_position.y + ANKLE_H)
			_model.position.y = clampf(_model.position.y - drop, _model_base_y - 1.0, _model_base_y + 0.1)
	# 移動中改「低姿預備」而不是放掉槍：原本一移動就還原成掛在手上，
	# 結果是空手跑步動畫＋一把槍飄在手邊，長槍單手拎著跑非常假（2026-07-25 補齊全動作）。
	# 真實做法＝上半身覆蓋：雙手仍持槍、槍口略朝下前方，腿部照跑步動畫走。
	_aiming = (not _dead) and not (_state in FREEHAND_STATES)
	if not _aiming:
		if _dead:
			_drop_gun()      # ★陣亡＝槍掉在地上，不是「斜背在背上」（見 _drop_gun）
			return
		_stow_gun(sk)        # 雙手要做別的事：把槍斜背到背上（不然長槍會插進地面）
		return
	var si := sk.find_bone("Shoulder.R")
	if si < 0:
		return
	var moving: bool = _move_target != null or (_state in LEFTHAND_FREE)
	var tgt: Vector3 = global_position + facing_dir() * 8.0 + Vector3.UP * 1.2
	if moving:
		tgt = global_position + facing_dir() * 5.0 + Vector3.UP * 0.35   # 低姿預備：槍口略朝下
	elif aim_point != null:
		tgt = aim_point
	var right := global_basis.x.normalized()
	# 0) 蹲姿是真人「低姿潛行」動作：上身前傾 35°、頭朝地面——戰鬥中看不到前方也架不了槍。
	#    故沿上半身骨鏈逐節扳回（腰保留一點前傾才自然），頭是子骨會跟著一起抬起來。
	if _crouch > 0.001 and anim_names.has("crouch"):
		_rig.add_world_rotation("Abdomen", right, deg_to_rad(-9.0) * _crouch)
		_rig.add_world_rotation("Torso", right, deg_to_rad(-11.0) * _crouch)
		_rig.add_world_rotation("Chest", right, deg_to_rad(-11.0) * _crouch)
	# 1) 上半身與頭先跟著俯仰——會動到肩膀位置，故必須排在算抵肩點之前
	#    視線高度取真實頭骨位置：蹲下時眼睛會低半個身子，用固定 1.45m 會讓槍口一直往下壓。
	var eye := global_position + Vector3.UP * 1.45
	var hi := sk.find_bone("Head")
	if hi >= 0:
		eye = sk.global_transform * sk.get_bone_global_pose(hi).origin
	var pitch: float = asin(clampf((tgt - eye).normalized().y, -1.0, 1.0))
	_rig.add_world_rotation("Chest", right, -pitch * 0.45)
	_rig.add_world_rotation("Head", right, -pitch * 0.40)
	# 2) 槍：槍托抵右肩窩、槍口指向目標
	var pocket: Vector3 = (sk.global_transform * sk.get_bone_global_pose(si).origin) \
			- Vector3.UP * (0.06 + float(PROC_POCKET_DROP.get(cls, 0.0)))
	# 匍匐時持槍的右手也要跟著異側循環前伸／後扒（使用者分解動作步驟 2~4）：
	# 抵肩點沿正面前後移動，相位＝_crawl（與「左腿張開」同時），與左手差半圈。
	if _prone > 0.5 and _crawl_amt > 0.01:
		pocket += facing_dir() * (0.16 * sin(_crawl)) * _crawl_amt
	var aim: Vector3 = (tgt - pocket).normalized()
	if _recoil > 0.001:
		aim = aim.rotated(right, -deg_to_rad(8.0) * _recoil).normalized()   # 槍口上跳
		pocket -= aim * 0.06 * _recoil                                      # 槍身後退抵肩
		_rig.add_world_rotation("Chest", right, -deg_to_rad(5.0) * _recoil) # 上身後仰一下
	if PROC_POCKET_DROP.has(cls):
		aim = facing_dir()      # 迫砲：砲管自帶仰角，方向只取水平，否則會被拉成平射
	# ★貼牆抬槍：槍口前方 _gun_len 內有固體就把槍抬起來（最多 62 度）。
	#   先前沒有這段，站在牆邊瞄準時整支步槍會穿進牆裡——固體不該被任何東西穿過。
	#   探測從「抵肩點」出發，因為槍是從那裡往前伸的。
	# ⚠ 抬槍的角度必須由「可用長度」反算，不能用「受阻比例 × 固定角度」：
	#   牆在半個槍長處時，比例式只抬 31 度，cos31°=0.86 → 槍口水平還伸出 0.86 個槍長，
	#   照樣插進牆裡（實測 t=0.64、槍口落在室內＝FAIL）。
	#   要讓槍口水平投影 ≤ 可用長度 d，需要的角度就是 acos(d / 槍長)。
	var need_deg := 0.0
	if solid_probe.is_valid() and _gun_len > 0.01:
		var reach: float = _gun_len * 1.15
		var t_hit: float = float(solid_probe.call(pocket, pocket + aim * reach))
		if t_hit < 0.999:
			var d: float = t_hit * reach - 0.12          # 扣 12cm 餘裕：槍口別貼著牆面
			var ratio: float = clampf(d / _gun_len, 0.0, 1.0)
			need_deg = rad_to_deg(acos(ratio))
	# 平滑：每秒最多轉 240 度，抬槍與放下都不會瞬間跳
	if fresh:
		_muzzle_block = move_toward(_muzzle_block, need_deg, get_process_delta_time() * 240.0)
	if _muzzle_block > 0.5:
		# 繞右手軸往上轉＝槍口朝天（真實的 high port 持槍），同時把槍往後收貼近身體
		var lift: float = minf(_muzzle_block, 86.0)
		aim = aim.rotated(right, deg_to_rad(lift)).normalized()
		pocket -= facing_dir() * (0.12 * clampf(lift / 60.0, 0.0, 1.0))
	var up_ref := Vector3.UP
	if absf(aim.dot(up_ref)) > 0.97:
		up_ref = facing_dir()                    # 目標近乎正上/正下時叉積會退化
	var z_axis := aim.cross(up_ref).normalized()
	var y_axis := z_axis.cross(aim).normalized()
	var b := Basis(aim * _gun_len_scale, y_axis * _gun_len_scale, z_axis * _gun_len_scale) * _gun_axis_fix
	var xf := Transform3D(b, pocket + aim * 0.02 - b * _gun_stock)
	# 3) 兩手抓上槍（右手握把、左手前護木）＋手指握攏
	# ★先把手臂鏈重置回 rest：IK 是疊加式的，直接疊在動畫的擺臂扭轉上會讓上臂
	#   local 旋轉極端到蒙皮塌陷（畫面上手臂整條消失，只剩一小截手浮在槍上）。
	# ⚠ 肩骨現在也要重置：2026-07-27 起 ik_two_bone 會讓肩骨分攤一部分擺動，
	#   而 _rotate_bone 是疊加式的。不是每支動畫都會 key 到 Shoulder，
	#   沒 key 到的那幾支會逐幀累加，肩膀幾秒內就轉到背後去。
	_rig.reset_bones(["Shoulder.R", "UpperArm.R", "LowerArm.R", _hand_r])
	if not (_state in LEFTHAND_FREE):
		_rig.reset_bones(["Shoulder.L", "UpperArm.L", "LowerArm.L", _hand_l])
	# 肘部極向量：兩肘都朝下外側，這是持槍的自然姿勢；沒有約束會扭成怪解
	# 肘部極向量：⚠ 不可以只用「往下」——實拍放大看到肘被壓到臀部高度、前臂幾乎垂直，
	# 遠景讀起來就是「沒有手臂」（使用者說的「跑步兩隻手不見」有一半是這個）。
	# 真實持槍是肘部收在**肋骨高度的後外側**，所以極向量要含「往後」的成分。
	var down := (-Vector3.UP * 0.5 - facing_dir() * 0.55).normalized()
	var rightv := right_dir()          # ★位置用途，必須是真正的右邊（見 right_dir 註解）
	# ⚠⚠ 肘部極向量必須把手肘推到**身體輪廓之外**（使用者 2026-07-27 第二次指正
	#   「還是沒有手臂」的真因）。舊值只有「下＋外」，握把離肩膀只有 0.35m、
	#   手臂卻有 0.55m，手肘一定要折出去；缺少「往後」的分量時它就折進胸腔，
	#   從背後看＝軀幹上直接長出一把槍和兩隻手，上臂前臂整段藏在身體剪影裡。
	#   真實抵肩射擊的右肘是「外展、略微下垂、明顯在身體後方」。
	# ⚠ 2026-07-27 再修：舊極向量「往後」的合成分量（0.88）比「往外」（0.72）還大，
	#   肘被推到軀幹正後方 → 正面看整條上臂藏在身體剪影裡，只剩兩隻手浮在槍上（實拍證實）。
	#   實際抵肩射擊的持槍肘是**明顯向側外抬起**，往後只是輔助。改成以外展為主。
	_rig.ik_two_bone("UpperArm.R", "LowerArm.R", _hand_r, xf * _gun_grip,
			(rightv * 0.95 - Vector3.UP * 0.34 - facing_dir() * 0.22).normalized(),
			"Shoulder.R", 0.30)
	_rig.curl_fingers(".R", 0, 55.0, 35.0)
	# 匍匐時左手離開前護木，往前撐地拉行（右手仍握把把槍拖著走）。
	# ★這是趴姿唯一「看得見」的推進動作——腿在身體後方被身體與草擋住，
	#   光靠腿動，玩家看到的仍然是一個人平貼地面往前滑（使用者 2026-07-26 回饋）。
	if _prone > 0.5 and _crawl_amt > 0.01:
		var fwd2 := facing_dir()
		# 伸手→抓地→拉回：與腿的蹬地相位相反（手腳交替，跟走路一樣）
		var ph_arm: float = _crawl + PI
		var reach: float = 0.62 + 0.30 * sin(ph_arm)
		var lift: float = 0.13 + 0.10 * maxf(sin(ph_arm), 0.0)      # 伸的時候抬起，拉的時候貼地
		var hand_t: Vector3 = global_position + fwd2 * reach 				- rightv * 0.30 + Vector3.UP * lift
		_rig.ik_two_bone("UpperArm.L", "LowerArm.L", _hand_l, hand_t,
				(down * 0.55 - rightv * 0.8).normalized())
		_rig.curl_fingers(".L", 0, 30.0, 20.0)
	elif not (_state in LEFTHAND_FREE):
		# ⚠ 左臂的肘部極向量必須朝「左外側」（-rightv）。原本寫成 +rightv＝往身體內側，
		#   左肘被夾進胸口、上臂整段藏進軀幹剪影裡，看起來就是「手臂不見了」
		#   （使用者 2026-07-26 指正）。右臂朝右外側，兩邊是鏡像。
		# 左肘：托前護木的手肘是「往下、略微內收、在身體前下方」——
		# 跟右肘鏡像但不對稱，這是抵肩姿勢的實際樣子。
		# 托前護木的手肘＝**明顯往下**、略往左外側；朝後的分量會把它塞進軀幹（同右肘）。
		_rig.ik_two_bone("UpperArm.L", "LowerArm.L", _hand_l, xf * _gun_fore,
				(-Vector3.UP * 0.62 - rightv * 0.74 + facing_dir() * 0.10).normalized(),
				"Shoulder.L", 0.42)
		_rig.curl_fingers(".L", 0, 55.0, 35.0)
	# ★★收尾一定要強制刷新骨架（2026-07-27，左臂撕裂的真因，查了四輪）。
	#   本函式是在 `skeleton_updated` 訊號「裡面」改骨頭的，蒙皮矩陣已經為這一幀算過；
	#   最後寫入的那條鏈（左臂晚於右臂）趕不上，於是**一部分頂點跟著骨頭、
	#   一部分留在 rest**，畫面上就是兩條從手肘拉到 A-pose 位置的長薄片。
	#   ⚠ 這種錯誤下所有骨骼指標都正常（骨長不變、手誤差 0、無縮放、無鏡像、
	#     相對 rest 的角度左右對稱），只有**看渲染結果**才抓得到。
	sk.force_update_all_bone_transforms()
	# 4) 最後才擺槍：IK 會動到手骨→掛點跟著動，先擺會被帶偏
	_gun_node.global_transform = xf
	_gun_src_world = pocket
	_muzzle_world = pocket + aim * _gun_len
	_crouch_offset()

# 陣亡：槍脫手掉在地上（2026-07-27 使用者：「倒下手臂跟武器也在背後」）。
# ⚠ 真因：陣亡走的是 `_stow_gun`（斜背），而斜背的槍身軸取**世界座標的上方**——
#   人已經躺平了，槍還是直挺挺豎著，畫面上就是一把槍浮在屍體旁邊。
#   人死了手會鬆開，槍會掉在地上——這是鐵律 0，不是演出選擇。
var _gun_dropped := false

func _drop_gun() -> void:
	if _gun_node == null or not is_instance_valid(_gun_node):
		return
	if _gun_dropped:
		return
	_gun_dropped = true
	# 從手腕掛點移到 Unit 底下（跟著屍體一起淡出／清除，不會留下孤兒節點）
	var xf_keep: Transform3D = _gun_node.global_transform
	var par := _gun_node.get_parent()
	if par != null:
		par.remove_child(_gun_node)
	add_child(_gun_node)
	_gun_node.global_transform = xf_keep
	# 平躺在身體旁邊的地面上，槍口朝角色面向的方向、略微歪斜（沒有人的槍會擺得筆直）
	var fwd := facing_dir().rotated(Vector3.UP, randf_range(-0.6, 0.6))
	var side := right_dir()
	var gp: Vector3 = global_position + side * randf_range(0.18, 0.42) + fwd * 0.15
	var gy: float = gp.y
	if ground_sampler.is_valid():
		gy = float(ground_sampler.call(gp))
	var z_axis := fwd.cross(Vector3.UP).normalized()
	if z_axis.length() < 0.01:
		return
	var y_axis := z_axis.cross(fwd).normalized()
	var b := Basis(fwd * _gun_len_scale, y_axis * _gun_len_scale,
			z_axis * _gun_len_scale) * _gun_axis_fix
	_gun_node.global_transform = Transform3D(b,
			Vector3(gp.x, gy + 0.055, gp.z) - b * _gun_grip)

# 收槍：斜背在背上。修理/佔領/赤手待機時雙手放開，槍若還掛在手腕上會垂直插進地面。
func _stow_gun(sk: Skeleton3D) -> void:
	var ci := sk.find_bone("Chest")
	if ci < 0 or _gun_node == null:
		return
	var chest: Vector3 = sk.global_transform * sk.get_bone_global_pose(ci).origin
	var fwd := facing_dir()
	var rightv := right_dir()          # ★位置用途：槍要斜背在右肩，用 basis.x 會背到左肩
	var anchor: Vector3 = chest - fwd * 0.15 + Vector3.UP * 0.02
	var axis: Vector3 = (Vector3.UP * 0.72 + rightv * 0.62).normalized()   # 槍口朝右上斜掛
	var z_axis := axis.cross(fwd).normalized()
	if z_axis.length() < 0.001:
		return
	var y_axis := z_axis.cross(axis).normalized()
	var b := Basis(axis * _gun_len_scale, y_axis * _gun_len_scale, z_axis * _gun_len_scale) * _gun_axis_fix
	_gun_node.global_transform = Transform3D(b, anchor - b * _gun_grip)

var _in_pose := false          # skeleton_updated 內改骨骼會再觸發信號，需防遞迴
func _on_skeleton_updated() -> void:
	if _in_pose:
		return
	_in_pose = true
	# 重定向必須在這裡做（不是在 _aim_pose 裡）：_aim_pose 以「有武器模型」為前提會提早返回，
	# 但動作是全體都需要的。
	if _retarget and _rig != null:
		_rig.apply()
	_aim_pose()
	_in_pose = false

# 蹲姿：模型自帶動畫組沒有 crouch，改由 UAL 動作庫的 Crouch_Idle 重定向過來。
# 只在第一個單位生成時算一次，結果存成靜態姿勢表全體共用（省掉每單位一份骨架與動畫播放器）。
func _capture_crouch() -> void:
	if _model == null or not ResourceLoader.exists(UAL_ANIMS):
		return
	var sks := _model.find_children("*", "Skeleton3D", true, false)
	if sks.is_empty():
		return
	var sk := sks[0] as Skeleton3D
	var src := (load(UAL_ANIMS) as PackedScene).instantiate()
	add_child(src)
	src.position = Vector3(0, 0, -500)
	for mi in src.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).visible = false
	var aps := src.find_children("*", "AnimationPlayer", true, false)
	var ssk := src.find_children("*", "Skeleton3D", true, false)
	if aps.is_empty() or ssk.is_empty():
		src.queue_free()
		return
	var ap2 := aps[0] as AnimationPlayer
	if not ap2.has_animation("Crouch_Idle"):
		src.queue_free()
		return
	ap2.play("Crouch_Idle")
	ap2.seek(0.6, true)
	await get_tree().process_frame
	await get_tree().process_frame
	var rt2 = RIG.new()
	var n: int = rt2.setup(ssk[0] as Skeleton3D, sk)
	rt2.apply()
	_crouch_pose = rt2.capture_pose()
	print("[crouch] 擷取完成 pairs=", n, " bones=", (_crouch_pose["rot"] as Dictionary).size())
	src.queue_free()

func _ready() -> void:
	if USE_RETARGET_CROUCH and _crouch_pose.is_empty() and not _crouch_busy:
		_crouch_busy = true
		_capture_crouch()
# 蹲姿位移：手寫屈膝尚未成功前，先用單純的整體下壓（幅度縮小，避免腳明顯陷地）。
# 重點是「只有這裡會寫模型高度」，不再與其他地方互相覆蓋。
func _crouch_offset() -> void:
	if _model == null:
		return
	if _crouch <= 0.001 and _prone <= 0.001:
		_model.position.y = _model_base_y
		_model.position.z = 0.0
		_model.rotation.x = 0.0

# 建立 UAL 動作來源：hr_ 骨架的角色沒有內建動畫，動作全部來自這個真人 mocap 庫。
# 來源本身的網格隱藏並移出視野，只當「姿勢提供者」。
func _make_anim_source() -> void:
	if not ResourceLoader.exists(UAL_ANIMS):
		return
	var src := (load(UAL_ANIMS) as PackedScene).instantiate()
	add_child(src)
	src.position = Vector3(0, 0, -400)
	for mi in src.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).visible = false
	var aps := src.find_children("*", "AnimationPlayer", true, false)
	if aps.is_empty():
		src.queue_free()
		return
	_anim_src = src
	_retarget = true
	anim = aps[0]
	_map_anims()


# 槍口火光要**照亮環境**（GDD/15 E2）。先前只有一片自發光貼片，
# 夜戰或黃昏逆光時開槍，周圍完全沒有變化——現實中槍口焰是很強的瞬間光源，
# 它同時也是「暴露自己位置」這件事在畫面上的表現。
func _muzzle_flash() -> void:
	if _is_vehicle:
		return
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.86, 0.55)
	l.light_energy = 8.0
	l.omni_range = 5.0
	l.shadow_enabled = false          # 一閃即逝，開陰影只是白付成本
	get_tree().current_scene.add_child(l)
	l.global_position = (_muzzle_world if _muzzle_world != Vector3.ZERO
			else global_position + Vector3(0, 1.35, 0))
	var tw := create_tween()
	tw.tween_property(l, "light_energy", 0.0, 0.07)
	tw.tween_callback(l.queue_free)
