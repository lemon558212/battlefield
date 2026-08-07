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
## 戰術移動速度。
## ★★2026-08-07 使用者裁定 3.0 → 2.0，理由是量出來的，不是手感喜好：
##   這套動畫管線（UAL 重定向到 hr_ 骨架）的「接觸腳往後掃的速度」**飽和在 1.3~1.5 m/s**。
##   證據一：換片段沒用——Walk / Jog_Fwd / Sprint / Run_Fwd 四支全試，
##           滑步比值 0.453 / 0.476 / 0.470 / 0.444，差異在雜訊內。
##   證據二：加快播放沒用——speed_scale 從 1.0 掃到 2.40（2.4 倍），
##           接觸期腳速紋風不動（1.27~1.30 m/s），而線性模型預測應該掉到 0.54。
##           （播放倍率本身確實生效：設定 1.16 vs 實測播放頭前進 1.17 秒。）
##   ⇒ 身體速度超過約 1.9 m/s，腳就追不上，多出來的全部變成打滑。
##   2.0 m/s 實測滑步比值 0.122 / 0.127 / 0.142（跑三次），遠低於 0.35 門檻。
##   2.0 m/s = 7.2 km/h＝真實的負重行軍速度，不違背鐵律 0。
##   ⚠ AP 是按**實際位移**扣的，所以「一次行動能走多遠」完全不變，
##     只是走完那段距離的實際等待時間變長。要恢復手感就調這個值，
##     但改回 3.0 之前先想清楚滑步會一起回來。
@export var run_speed: float = 2.00
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
## walk → run 的切換速度（m/s）。
## ⚠ 不可以貼近 run_speed(3.0)：實際速度會因地形、涉水、體力上下浮動，
##   門檻設 2.25 時等速跑 2.5s 內量到 4~5 次步態切換＝動畫在抽搐。
##   壓到 1.9 並把遲滯拉到 0.45，浮動就吃不到門檻了。
## ★★2026-08-07：這個值**故意設在 run_speed 之上**，讓一般戰術移動落在 walk 步態。
##   看起來很怪，但這是量出來的結論，不是失誤：
##       run_speed=2.0 + walk_to_run=1.90（用 Walk 片段）→ 滑步 0.122/0.127/0.142
##       run_speed=2.0 + walk_to_run=1.35（用 Jog_Fwd）  → 滑步 0.548/0.567/0.527
##   同樣的速度，只因為換了片段就差 4 倍。**Jog_Fwd 重定向到 hr_ 骨架之後腿幾乎不掃**，
##   而 Walk 是好的。所以一般移動一律走 Walk（配上踏頻同步加速播放＝快步行軍）。
##   run / sprint 步態現在只在「加速行軍」（speed_mul>1.5）時才會出現，
##   那個情況下仍會有滑步——已知限制，要治本得換一支可用的跑步動作。
@export var walk_to_run: float = 1.90
## run → sprint 的切換速度（m/s）
@export var run_to_sprint: float = 4.10
## 步態切換遲滯（m/s）：往回切要比往上切低這麼多，避免臨界來回跳
@export var gait_hysteresis: float = 0.45
## 步態最短停留時間（秒）：擋住短暫的速度波動造成的動畫抽搐。
## 0.18 太短——地形起伏、擦到雜物都會讓速度掉一下，實測等速跑 2.5s 內
## 仍會切換 4 次。人不會在半秒內把步態改三次，0.35 是符合現實的下限。
@export var gait_min_hold: float = 0.35
## 各步態的**單步步幅**（公尺）。踏頻同步靠它把「動畫週期」換算成「該有的速度」：
##     native = (2 步 / 週期秒) × 步幅，  speed_scale = 實際速度 / native
## stride_run 取 1.13 是推導值不是調出來的：Jog_Fwd 週期 0.93s，要讓它的原生速度
## 等於本專案的實際跑速 2.44 m/s，步幅就必須是 2.44 × 0.93 ÷ 2 = 1.13m。
## ⚠ 曾經掃描 0.65 / 0.85 / 1.13 想找滑步最低點，結果是 0.544 / 0.675 / 0.476
## ——非單調。因為量測的局間變異（±0.08）已經和效果同量級，再掃就是對雜訊擬合。
## 真正要往下壓，需要的是原生速度接近 3 m/s 的跑步動作，不是繼續調這個數字。
@export var stride_walk: float = 0.75
@export var stride_run: float = 1.13
@export var stride_sprint: float = 2.00
@export var stride_crouch: float = 0.62
## 播放倍率夾限。
## ⚠ 這不只是安全帶，它是**動作資產與移動速度不匹配的警報線**：
##   實測 UAL Jog_Fwd 的原生速度只有約 1.26 m/s（作者是照慢跑做的），
##   而本專案的戰術移動速度是 3.0 m/s ⇒ 需要 2.4 倍才對得上腳步。
##   夾在 1.9 的結果是「同步已盡力、但仍差 25%」＝殘留滑步。
##   治本要動的是資產或速度設定，不是這兩個數字（見報告「尚缺少的動畫資產」）。
## 執行期自動量測動畫原生速度（預設關閉）。
## ★2026-08-07 的實測結論，寫下來免得有人以為關掉只是懶：
##   概念是對的——「接觸腳相對身體往後掃的速度」就是零滑步時該有的身體速度，
##   不需要步幅、也不需要接觸期占比。但**訊號雜訊太大**：逐幀差分同時吃到
##   地形取樣抖動與模型傾斜，同一支 Jog_Fwd 三次量到 1.05 / 4.31 / 5.48 m/s，
##   中位數與 80 百分位差 5 倍。這種估計比固定常數更不穩定，開著會讓手感每局不同。
##   要啟用，先解決訊號品質（低通 + 只在平地直線時取樣 + 多局取共識）。
@export var cadence_auto_calibrate: bool = false
@export var cadence_min: float = 0.55
@export var cadence_max: float = 2.40

# ---------- 動畫混合 ----------
@export_group("動畫混合")
## 同族步態互切（walk↔run）的淡入時間（秒）
@export var blend_gait: float = 0.22
## 靜止↔移動的淡入時間（秒）。起步比停步略快，人起步是「蹬」出去的
@export var blend_start: float = 0.16
@export var blend_stop: float = 0.26

# ---------- 腳步 IK ----------
@export_group("腳步 IK")
## 總開關（開啟，但 Unit._apply_foot_ik 只讓 Quaternius/hr_ 骨架通過）。
## ★★2026-08-07 血淚，寫下來免得有人把那道骨架限制當成多餘的保護而拿掉：
##   foot IK 需要「骨頭的世界座標」，而它是用
##       Skeleton3D.global_transform * get_bone_global_pose(i)
##   算出來的。這個值**不保證等於蒙皮後網格實際渲染的位置**——當 MeshInstance3D
##   與 Skeleton3D 的變換不一致時（tripo 立繪本人模型就是），兩者會差一大截。
##   實測 tripo_han：角色原點 y=0.14m，但髖骨讀出來 y=-2.05m，差了 2.2m。
##   在那個前提下把腳「貼」到地面，等於把整具骨架往地底拉 → 畫面上人整個不見了。
##   要擴到其他骨架系，先解決空間對齊（把 skin bind pose 納入換算），
##   並且在 `-- locochk` 量到「靜止時兩腳踝離地誤差 < 0.12m」之後再說。
@export var foot_ik_enabled: bool = true
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
