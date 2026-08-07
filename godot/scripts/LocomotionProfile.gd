# LocomotionProfile.gd — 角色運動參數集中管理（2026-08-07）。
#
# 為什麼要有這個檔：升級前，速度／加速度／轉向／步幅這些數字散在 Unit.gd 的
# 十幾個 const 裡（WALK_SPEED、TURN_SPEED、ACCEL、DECEL、STEP_LEN…），
# 而 DECEL 甚至宣告了從來沒人用。參數散落的代價是「改一個手感要翻三千行」，
# 也沒辦法讓不同兵種有不同重量感（狙擊手與工兵不該一樣靈活）。
#
# 全部走 @export：Resource 存成 .tres 就能在 Inspector 調，不必改碼重編。
# 數值一律真實量級（專案鐵律 0⑤）：人走 1.4~1.6 m/s、慢跑 3 m/s、衝刺 5~6 m/s。
class_name LocomotionProfile
extends Resource

# ---------- 速度（m/s，真實量級）----------
@export_group("速度")
## 一般步行：真人行軍速度約 1.4~1.6 m/s
@export var walk_speed: float = 1.55
## 戰術移動（本專案預設值，等同舊 Unit.WALK_SPEED）
@export var run_speed: float = 3.0
## 衝刺：負重的步兵大約 5~6 m/s
@export var sprint_speed: float = 5.2
## 蹲行倍率（乘在 run_speed 上；舊碼寫死 0.45）
@export var crouch_mul: float = 0.45

# ---------- 加減速（m/s²）----------
@export_group("加減速")
## 起步加速度。人從靜止到 3 m/s 大約 0.4s ⇒ 約 7.5 m/s²
@export var accel: float = 8.0
## 一般減速（鬆開方向鍵的慣性滑行）。真人從 3 m/s 滑到停約 0.6~0.8s ⇒ 4~5 m/s²
@export var decel: float = 4.6
## 主動煞停（到達目的地前的收腳）。刻意收腳大約 0.45s 停住 ⇒ 約 6.5 m/s²。
## ⚠ 這個值同時決定「還剩多遠開始減速」：s = v²/(2a)，3 m/s 時約 0.7m。
##   調大＝煞得急（像踩了剎車），調小＝老遠就開始收腳（像滑冰）。
@export var brake_decel: float = 6.5
## 空中／失去支撐時對水平速度的控制力（0=完全沒有，1=跟地面一樣）
@export var air_control: float = 0.25

# ---------- 轉向 ----------
@export_group("轉向")
## 低速轉向角速度（rad/s）。慢慢走時轉身要有重量、不能像陀螺
@export var turn_rate_slow: float = 4.2
## 高速轉向角速度（rad/s）。跑起來慣性大，但腳步能蹬地修正方向，比原地稍快
@export var turn_rate_fast: float = 6.5
## 朝向誤差大於此角度就先原地轉身、不前進（度）
@export var turn_in_place_deg: float = 78.0
## 轉到誤差小於此角度才放行前進（度）。與上面錯開＝遲滯，避免臨界抖動
@export var turn_release_deg: float = 34.0
## 轉向收尾緩衝（度）：誤差進入這個範圍後角速度按比例收斂，避免「轉到定位硬停」
@export var turn_ease_deg: float = 22.0

# ---------- 步態與踏頻同步（治滑步的核心）----------
@export_group("步態與踏頻")
## 低於這個速度視為靜止（m/s）
@export var idle_speed: float = 0.22
## walk → run 的切換速度（m/s）
@export var walk_to_run: float = 2.25
## run → sprint 的切換速度（m/s）
@export var run_to_sprint: float = 4.10
## 步態切換遲滯（m/s）：往回切要比往上切低這麼多，避免臨界來回跳
@export var gait_hysteresis: float = 0.35
## 步態最短停留時間（秒）：擋住 1 幀內來回切造成的動畫抽搐
@export var gait_min_hold: float = 0.18
## 各步態的**單步步幅**（公尺）。踏頻同步就是靠這個把「動畫週期」換算成「該有的速度」
@export var stride_walk: float = 0.75
@export var stride_run: float = 1.50
@export var stride_sprint: float = 2.00
@export var stride_crouch: float = 0.62
## 播放倍率夾限：超出這個範圍代表動畫本身選錯了，硬拉只會變成快轉／慢動作
@export var cadence_min: float = 0.55
@export var cadence_max: float = 1.90

# ---------- 動畫混合 ----------
@export_group("動畫混合")
## 同族步態互切（walk↔run）的淡入時間（秒）
@export var blend_gait: float = 0.22
## 靜止↔移動的淡入時間（秒）。起步比停步略快，人起步是「蹬」出去的
@export var blend_start: float = 0.16
@export var blend_stop: float = 0.26

# ---------- 腳步 IK ----------
@export_group("腳步 IK")
## 總開關。
## ★★2026-08-07 預設關閉，理由寫清楚免得後人以為只是忘了打開：
##   foot IK 需要「骨頭的世界座標」，而它是用
##       Skeleton3D.global_transform * get_bone_global_pose(i)
##   算出來的。這個值**不保證等於蒙皮後網格實際渲染的位置**——當 MeshInstance3D
##   與 Skeleton3D 的變換不一致時（tripo 立繪本人模型就是），兩者會差一大截。
##   實測 tripo_han：角色原點 y=0.14m，但髖骨讀出來 y=-2.05m，差 2.2m。
##   在這個前提下把腳「貼」到地面，等於把整具骨架往地底拉 → 畫面上人整個不見了。
##   要真正打開，先解決空間對齊（把 skin bind pose 納入換算），並且在
##   `-- locochk` 量到「靜止時兩腳踝離地誤差 < 0.12m」之後再說。
##   在那之前，斜坡上的腿部適應由 Unit._legs_to_slope() 的近似法負責（既有行為）。
@export var foot_ik_enabled: bool = false
## IK 權重（0~1）。1＝完全貼地；留一點餘裕可避免動畫本身的抬腳被壓掉
@export var foot_ik_strength: float = 0.85
## 腳踝離地高度（公尺）：腳踝骨不是腳底，貼地要扣掉這一段
@export var ankle_height: float = 0.085
## 骨盆最大下沉（公尺）：兩腳落差太大時整個人要蹲下去一點，腿才構得到
@export var pelvis_drop_max: float = 0.28
## IK 目標的平滑速度（每秒收斂比例），避免踩過草叢邊緣時腳抽動
@export var foot_ik_smooth: float = 12.0
## 兩腳間距半寬（公尺）：骨盆左右各約 17cm
@export var hip_half_width: float = 0.17
## 腳掌跟隨坡面法線的比例（0=永遠水平，1=完全貼坡）
@export var foot_align_slope: float = 0.7

# ---------- 頭部注視 ----------
@export_group("注視")
@export var look_at_enabled: bool = true
## 注視強度總權重
@export var look_at_strength: float = 1.0
## 分攤比例：頭、頸、胸（相加不必為 1，這是各自吃掉的角度比例）
@export var look_head_share: float = 0.55
@export var look_neck_share: float = 0.25
@export var look_chest_share: float = 0.20
## 最大偏轉（度）：脖子不可能轉 180°
@export var look_yaw_max: float = 72.0
@export var look_pitch_max: float = 34.0
## 注視收斂速度（每秒）
@export var look_speed: float = 6.0

# ---------- 效能 ----------
@export_group("效能")
## 超過這個距離（公尺）就降低 IK 更新頻率
@export var ik_lod_distance: float = 28.0
## 遠處單位的 IK 更新間隔（幀）
@export var ik_lod_interval: int = 3
## 超過這個距離乾脆關掉 IK（畫面上一兩公分的誤差看不出來）
@export var ik_cull_distance: float = 55.0


# 依步態回傳單步步幅（公尺）
func stride_of(gait: String) -> float:
	match gait:
		"walk": return stride_walk
		"run": return stride_run
		"sprint": return stride_sprint
		"crouch_walk": return stride_crouch
		_: return stride_walk
