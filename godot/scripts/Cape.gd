# Cape.gd — 分段披風＋次級運動（2026-08-07 使用者：「披風整個看起來適硬的」）。
#
# ★為什麼要自己做，而不是修模型：
#   立繪本人模型（tripo_han.glb）經量測是**單一焊死網格**——15133 頂點焊接後 8016 個，
#   連通元件只有 1 個（100%）。身體、武器、雙手、頭髮、披風在幾何上是同一塊三角網，
#   而且骨架裡一根衣襬骨都沒有。在那個資產上，披風的自由度是 0，
#   不管動畫多好、著色器多花俏，它都只能跟著軀幹做剛體運動＝使用者看到的「硬」。
#   所以正解是：角色回到分件式骨架，披風另外做成**自己有關節的東西**。
#
# 做法（低多邊形＋彈簧鏈，與本專案樹/岩石同一套哲學）：
#   把披風切成 N 段，每段是一片梯形，父子相接掛在胸椎骨上。
#   每段有自己的角度與角速度，用彈簧-阻尼收斂到「目標角度」，而目標來自：
#     ① 重力       → 靜止時自然垂下（這是 rest）
#     ② 前進速度   → 布料落後於身體，往後掀（阻力）
#     ③ 轉向角速度 → 往轉彎的外側甩
#     ④ 風         → 低頻擾動，讓站著不動時也不是死的
#   關鍵在「延遲逐段累積」：第 2 段追第 1 段、第 3 段追第 2 段……
#   這個相位差就是布料看起來像布料、而不是一塊掛著的板子的全部原因。
class_name CharCape
extends Node3D

# ---- 形狀（公尺，真實量級）----
# ★2026-08-07 第一版做成「背後一整片」，實拍發現第三人稱鏡頭在角色背後，
#   一片 0.9m 寬的不透明布就是把整個角色蓋掉——既看不到人，也看不出布在動。
#   回頭看立繪：那件披風是**開襟的**，從雙肩垂下、分成左右兩條尖尾襬，
#   中間露出身體。照立繪做同時解決兩件事：識別度對得上，而且人看得見。
const SEGMENTS := 6             # 段數：越多越像布，但每段都是一次矩陣運算
const LENGTH := 1.02            # 單條尾襬長度（及小腿）
const TOP_W := 0.115            # 肩部半寬
const MID_W := 0.20             # 中段最寬（往外張）
const TIP_W := 0.045            # 尾端收成尖角（立繪上是尖的）
const THICK := 0.010
const SHOULDER_X := 0.155       # 兩條尾襬掛在肩膀左右各多遠
const FLARE_DEG := 13.0         # 靜態外張角（布搭在肩上自然往外撇）

# ---- 動力學 ----
const REST_BACK := 7.0          # 靜止時自然往後貼的角度（度）
const DRAG_PER_MS := 12.0       # 每 1 m/s 前進速度讓披風往後掀幾度
const DRAG_MAX := 48.0
const SWAY_PER_RADS := 16.0     # 每 1 rad/s 轉向往外甩幾度
const SWAY_MAX := 32.0
const STIFF := 44.0             # 彈簧勁度
const DAMP := 7.0               # 阻尼
const LAG := 0.62               # 每往下一段，目標角度乘這個係數＝延遲逐段累積
const WIND_AMP := 2.6           # 無風時的微擾（度）
const WIND_RATE := 1.7

# 兩條尾襬各自獨立模擬（同步擺動立刻穿幫，所以連相位都要錯開）
var _chain := {"L": [], "R": []}
var _ang := {"L": [], "R": []}
var _vel := {"L": [], "R": []}
var _t := 0.0
var _phase := 0.0


# main_c/acc_c：主色與滾邊色（由 char_look 的立繪配色帶進來）
static func build(main_c: Color, acc_c: Color, phase: float = 0.0) -> CharCape:
	var c := CharCape.new()
	c.name = "Cape"
	c._phase = phase
	c._make(main_c, acc_c)
	return c


func _make(main_c: Color, acc_c: Color) -> void:
	var seg_len: float = LENGTH / float(SEGMENTS)
	for sd in ["L", "R"]:
		var sgn: float = -1.0 if sd == "L" else 1.0
		var root := Node3D.new()
		root.name = "CapeRoot" + sd
		root.position = Vector3(SHOULDER_X * sgn, 0.0, 0.0)
		root.rotation.z = deg_to_rad(-FLARE_DEG * sgn)   # 往外撇
		add_child(root)
		var parent: Node3D = root
		for i in SEGMENTS:
			var n := Node3D.new()
			n.name = "Cape%s%d" % [sd, i]
			n.position = Vector3.ZERO if i == 0 else Vector3(0, -seg_len, 0)
			parent.add_child(n)
			var f: float = float(i) / float(SEGMENTS)
			var f2: float = float(i + 1) / float(SEGMENTS)
			var mi := MeshInstance3D.new()
			mi.name = "CapeMesh%s%d" % [sd, i]
			mi.mesh = _panel(_width_at(f), _width_at(f2), seg_len)
			var col: Color = main_c.darkened(0.12 * f)
			if i >= SEGMENTS - 2:
				col = col.lerp(acc_c, 0.20)      # 尾端滾邊
			var mat := StandardMaterial3D.new()
			mat.albedo_color = col
			mat.roughness = 0.95
			mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
			# 雙面：布從背面也看得到，單面會在轉身時整片消失
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			mi.material_override = mat
			n.add_child(mi)
			_chain[sd].append(n)
			_ang[sd].append(Vector2.ZERO)
			_vel[sd].append(Vector2.ZERO)
			parent = n


# 沿長度的寬度曲線：肩窄 → 中段最寬 → 尾端收尖（照立繪的輪廓）
func _width_at(f: float) -> float:
	if f <= 0.42:
		return lerpf(TOP_W, MID_W, f / 0.42)
	return lerpf(MID_W, TIP_W, (f - 0.42) / 0.58)


# 一段梯形布片：上寬 w0、下寬 w1、長 h，往下延伸（原點在上緣中央）。
# 給一點厚度，否則從正側面看是一條線。
func _panel(w0: float, w1: float, h: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for sgn in [1.0, -1.0]:
		var z: float = THICK * 0.5 * sgn
		var a := Vector3(-w0, 0.0, z)
		var b := Vector3(w0, 0.0, z)
		var c := Vector3(w1, -h, z)
		var d := Vector3(-w1, -h, z)
		if sgn > 0.0:
			_tri(st, a, b, c); _tri(st, a, c, d)
		else:
			_tri(st, b, a, d); _tri(st, b, d, c)
	_tri(st, Vector3(-w0, 0, THICK * 0.5), Vector3(-w0, 0, -THICK * 0.5), Vector3(-w1, -h, -THICK * 0.5))
	_tri(st, Vector3(-w0, 0, THICK * 0.5), Vector3(-w1, -h, -THICK * 0.5), Vector3(-w1, -h, THICK * 0.5))
	_tri(st, Vector3(w0, 0, -THICK * 0.5), Vector3(w0, 0, THICK * 0.5), Vector3(w1, -h, THICK * 0.5))
	_tri(st, Vector3(w0, 0, -THICK * 0.5), Vector3(w1, -h, THICK * 0.5), Vector3(w1, -h, -THICK * 0.5))
	st.generate_normals()
	return st.commit()


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a); st.add_vertex(b); st.add_vertex(c)


# 每幀由 Unit 呼叫。
#   local_vel  角色**自身座標系**的水平速度（+Z 前、+X 右）
#   turn_rate  角速度（rad/s，正＝往左轉）
#   dead       死亡：披風失去所有驅動、只剩重力
func tick(delta: float, local_vel: Vector3, turn_rate: float, dead := false) -> void:
	if delta <= 0.0 or _chain["L"].is_empty():
		return
	_t += delta
	for sd in ["L", "R"]:
		var sgn: float = -1.0 if sd == "L" else 1.0
		# ---- 第一段的目標角度 ----
		# 往後掀：正比於前進速度。真實布料阻力是二次的，但 0~5 m/s 這段看不出差別，
		# 而線性不會出現「低速完全不動、高速突然掀起來」的階梯感。
		var back: float = deg_to_rad(REST_BACK)
		var side := 0.0
		if not dead:
			back += deg_to_rad(clampf(local_vel.z * DRAG_PER_MS, -DRAG_MAX * 0.4, DRAG_MAX))
			# 轉彎時外側那條甩得比內側大——兩條同步擺動一眼就看得出是假的
			side += deg_to_rad(clampf(-turn_rate * SWAY_PER_RADS, -SWAY_MAX, SWAY_MAX))
			side += deg_to_rad(clampf(-local_vel.x * DRAG_PER_MS * 0.7, -SWAY_MAX, SWAY_MAX))
			# 微風：站著不動時也不是死板。左右相位差 1.9 rad，不會像雨刷同步
			var ph: float = _phase + (0.0 if sd == "L" else 1.9)
			side += deg_to_rad(WIND_AMP * sin(_t * WIND_RATE + ph)) * sgn
			back += deg_to_rad(WIND_AMP * 0.45 * sin(_t * WIND_RATE * 0.73 + ph * 1.7))
		# ---- 逐段彈簧收斂，目標往下遞減＝延遲累積 ----
		# 這個相位差就是「看起來像布」而不是「一塊掛著的板子」的全部原因。
		var k := 1.0
		var arr: Array = _chain[sd]
		for i in arr.size():
			var target := Vector2(back * k, side * k)
			var a: Vector2 = _ang[sd][i]
			var v: Vector2 = _vel[sd][i]
			# 半隱式歐拉：先更新速度再更新角度，大 delta 時阻尼才不會發散
			v += (target - a) * STIFF * delta
			v *= maxf(1.0 - DAMP * delta, 0.0)
			a += v * delta
			# 夾限：布不會反折到身體前面，也不會甩到水平以上
			a.x = clampf(a.x, deg_to_rad(-12.0), deg_to_rad(74.0))
			a.y = clampf(a.y, deg_to_rad(-48.0), deg_to_rad(48.0))
			_ang[sd][i] = a
			_vel[sd][i] = v
			# 每段只承擔「相對上一段」的那一份，否則角度沿鏈條累加會捲成筒
			var n: Node3D = arr[i]
			n.rotation.x = a.x / float(arr.size())
			n.rotation.z = a.y / float(arr.size())
			k *= LAG
