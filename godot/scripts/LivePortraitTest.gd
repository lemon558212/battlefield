# LivePortraitTest.gd — 立繪「網格變形」動作試作（Godot 內建，Live2D 同原理，不切零件）
# 單張立繪鋪成網格，用 canvas 頂點著色器依高度變形：呼吸擺動/瞄準前傾/開火後座/受擊震紅/陣亡傾倒淡出。
# 跑法：Godot --path . res://scenes/LivePortraitTest.tscn ；會存 lp_*.png 五態截圖。
extends Node2D

const TEX := "res://assets/portraits/sniper.png"
const SHADER := """
shader_type canvas_item;
uniform float breath = 1.0;
uniform float lean = 0.0;
uniform float recoil = 0.0;
uniform float shake = 0.0;
uniform float fall = 0.0;
uniform float t_off = 0.0;
void vertex() {
	float up = 1.0 - UV.y;                 // 0=腳 1=頭：越上面動越多
	float t = TIME + t_off;
	float dx = sin(t*2.0 + up*2.2) * 7.0 * up * breath;   // 呼吸＋布料擺動
	dx += lean * up * 44.0;                // 瞄準前傾
	dx += -recoil * up * 40.0;             // 開火後座
	dx += shake * sin(t*70.0) * 11.0 * up; // 受擊震
	VERTEX.x += dx;
	VERTEX.y += -abs(dx) * 0.04;
	// 陣亡：繞腳底往側傾倒
	VERTEX.x += sin(fall*1.4) * up * 240.0 * fall;
	VERTEX.y += (1.0 - cos(fall*1.4)) * up * 140.0 * fall;
}
void fragment() {
	vec4 c = texture(TEXTURE, UV);
	c.a *= (1.0 - fall*0.9);               // 陣亡淡出
	c.rgb = mix(c.rgb, vec3(1.0,0.3,0.3), clamp(shake,0.0,1.0)*0.45); // 受擊紅閃
	COLOR = c;
}
"""

var mat: ShaderMaterial

func _ready() -> void:
	var tex: Texture2D = load(TEX)
	var disp := Vector2(440, 660)                      # 顯示尺寸
	var mi := MeshInstance2D.new()
	mi.mesh = _grid_mesh(disp, 14, 22)
	mi.texture = tex
	mi.position = Vector2(640, 380)
	mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SHADER
	mat.shader = sh
	mi.material = mat
	add_child(mi)
	var bg := ColorRect.new()                          # 深底襯托
	bg.color = Color(0.10, 0.12, 0.15)
	bg.size = Vector2(1280, 760)
	bg.z_index = -10
	add_child(bg)
	if "selftest" in OS.get_cmdline_user_args():
		_run()

func _grid_mesh(size: Vector2, nx: int, ny: int) -> ArrayMesh:
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for j in ny + 1:
		for i in nx + 1:
			var u := float(i) / nx
			var v := float(j) / ny
			verts.append(Vector2((u - 0.5) * size.x, (v - 0.5) * size.y))
			uvs.append(Vector2(u, v))
	for j in ny:
		for i in nx:
			var a := j * (nx + 1) + i
			var b := a + 1
			var c := a + (nx + 1)
			var d := c + 1
			idx.append_array([a, b, c, b, d, c])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am

func _pose(breath: float, lean: float, recoil: float, shake: float, fall: float) -> void:
	mat.set_shader_parameter("breath", breath)
	mat.set_shader_parameter("lean", lean)
	mat.set_shader_parameter("recoil", recoil)
	mat.set_shader_parameter("shake", shake)
	mat.set_shader_parameter("fall", fall)

func _snap(p: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(p)
	print("[lp] saved ", p)

func _run() -> void:
	await get_tree().create_timer(0.4).timeout
	_pose(1.0, 0.0, 0.0, 0.0, 0.0)                       # 待機
	await get_tree().create_timer(0.4).timeout
	await _snap("res://lp_idle.png")
	_pose(1.0, 1.0, 0.0, 0.0, 0.0)                       # 瞄準前傾
	await get_tree().create_timer(0.3).timeout
	await _snap("res://lp_aim.png")
	_pose(1.0, 0.6, 1.0, 0.0, 0.0)                       # 開火後座
	await get_tree().create_timer(0.05).timeout
	await _snap("res://lp_fire.png")
	_pose(1.0, 0.0, 0.0, 1.0, 0.0)                       # 受擊震紅
	await get_tree().create_timer(0.08).timeout
	await _snap("res://lp_hurt.png")
	_pose(1.0, 0.0, 0.0, 0.0, 1.0)                       # 陣亡傾倒淡出
	await get_tree().create_timer(0.3).timeout
	await _snap("res://lp_death.png")
	print("[lp] DONE")
	get_tree().quit(0)
