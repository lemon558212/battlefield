# GlbDecimate.gd — 把高面數 GLB（Tripo 之類）減面到可以進遊戲的量級。
#
# 為什麼在 Godot 裡做，而不是寫個 Python 腳本：
# Tripo 匯出的 GLB 用了 **EXT_meshopt_compression**，頂點與索引都是壓縮過的，
# 純 Python 要先實作 meshopt 解碼器。Godot 的 GLTFDocument 本來就支援這個擴充，
# 讓它解壓縮再取 surface arrays，是最短且不會出錯的路。
#
# 手法：網格分群（vertex clustering）。把空間切格，每格頂點合併成一個代表點。
# 對 100 倍以上的極端減面這是標準做法；本專案走低多邊形路線，
# 分群產生的稜角反而符合美術方向（GDD/14）。
# UV 接縫用「格座標 + 粗量化 UV」當鍵，否則接縫兩側被合併會把貼圖扯開。
# 骨骼索引與權重取代表點的值——同一格內的頂點本來就綁在幾乎相同的骨頭上。
#
# 用法：
#   Godot --path godot/ res://scenes/GlbTool.tscn -- decimate <來源glb> <輸出glb> [目標三角形數]

extends Node3D

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var src := ""
	var dst := ""
	var target := 12000
	for i in args.size():
		if args[i] == "decimate" and i + 2 < args.size():
			src = args[i + 1]
			dst = args[i + 2]
			if i + 3 < args.size():
				target = int(args[i + 3])
	# 檢視模式：把一個 glb 載進來，印骨架資訊並拍一張圖（減面後一定要用看的驗）
	for i2 in args.size():
		if args[i2] == "glbview" and i2 + 1 < args.size():
			await _view(args[i2 + 1])
			return
	if src == "":
		print("[decimate] 用法：-- decimate <來源> <輸出> [目標三角形數]  或  -- glbview <glb>")
		get_tree().quit(1)
		return
	_run(src, dst, target)


func _view(path: String) -> void:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.55, 0.60, 0.52)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 1.15
	var we := WorldEnvironment.new()
	we.environment = e
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38, 22, 0)
	add_child(sun)
	if not ResourceLoader.exists(path):
		print("[glbview] FAIL 檔案不存在或未匯入：", path)
		get_tree().quit(1)
		return
	var node: Node3D = (load(path) as PackedScene).instantiate()
	add_child(node)
	var sks := node.find_children("*", "Skeleton3D", true, false)
	var mis := node.find_children("*", "MeshInstance3D", true, false)
	var tri := 0
	var aabb := AABB()
	for m in mis:
		var mm: Mesh = (m as MeshInstance3D).mesh
		if mm == null:
			continue
		for si in mm.get_surface_count():
			var a: Array = mm.surface_get_arrays(si)
			var ix = a[Mesh.ARRAY_INDEX]
			tri += (ix.size() / 3) if ix != null else 0
		aabb = aabb.merge((m as MeshInstance3D).global_transform * mm.get_aabb())
	var bones := 0
	if not sks.is_empty():
		bones = (sks[0] as Skeleton3D).get_bone_count()
		var names: Array = []
		for b in mini(bones, 8):
			names.append((sks[0] as Skeleton3D).get_bone_name(b))
		print("[glbview] 骨頭數=", bones, " 前八根=", names)
	print("[glbview] 三角形=", tri, " 網格數=", mis.size(), " 尺寸=", aabb.size)
	var cam := Camera3D.new()
	add_child(cam)
	cam.make_current()
	var c: Vector3 = aabb.get_center()
	var r: float = maxf(aabb.size.y, maxf(aabb.size.x, aabb.size.z)) * 0.5
	cam.global_position = c + Vector3(r * 2.4, r * 0.5, r * 2.4)
	cam.look_at(c, Vector3.UP)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(0.6).timeout
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://qa/glb_view.png")
	print("[glbview] 已存 qa/glb_view.png")
	print("[glbview] DONE")
	get_tree().quit(0)


func _run(src: String, dst: String, target: int) -> void:
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	var err := doc.append_from_file(src, st)
	if err != OK:
		print("[decimate] FAIL 讀不到來源：", err)
		get_tree().quit(1)
		return
	var scene: Node = doc.generate_scene(st)
	if scene == null:
		print("[decimate] FAIL 生不出場景")
		get_tree().quit(1)
		return
	add_child(scene)
	var mis := scene.find_children("*", "MeshInstance3D", true, false)
	if mis.is_empty():
		print("[decimate] FAIL 找不到 MeshInstance3D")
		get_tree().quit(1)
		return
	var mi: MeshInstance3D = mis[0]
	var mesh: ArrayMesh = mi.mesh
	print("[decimate] 來源 surface 數=", mesh.get_surface_count())
	var out := ArrayMesh.new()
	var tot_before := 0
	var tot_after := 0
	for si in mesh.get_surface_count():
		var arr: Array = mesh.surface_get_arrays(si)
		var res: Array = _decimate_surface(arr, target)
		tot_before += res[1]
		tot_after += res[2]
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, res[0])
		var m := mesh.surface_get_material(si)
		if m != null:
			out.surface_set_material(si, m)
	mi.mesh = out
	print("[decimate] 三角形 %d → %d（剩 %.2f%%）" % [tot_before, tot_after,
			100.0 * float(tot_after) / maxf(1.0, float(tot_before))])
	# 寫回 GLB：用未壓縮格式輸出，專案匯入時不再需要 meshopt
	var st2 := GLTFState.new()
	var doc2 := GLTFDocument.new()
	var e2 := doc2.append_from_scene(scene, st2)
	if e2 != OK:
		print("[decimate] FAIL 轉回 GLTF：", e2)
		get_tree().quit(1)
		return
	var e3 := doc2.write_to_filesystem(st2, dst)
	print("[decimate] 寫出 ", dst, " err=", e3)
	print("[decimate] DONE")
	get_tree().quit(0 if e3 == OK else 1)


# 回傳 [新的 arrays, 原三角形數, 新三角形數]
func _decimate_surface(arr: Array, target: int) -> Array:
	var pos: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var nrm = arr[Mesh.ARRAY_NORMAL]
	var uv = arr[Mesh.ARRAY_TEX_UV]
	var bones = arr[Mesh.ARRAY_BONES]
	var wts = arr[Mesh.ARRAY_WEIGHTS]
	var tri0: int = idx.size() / 3
	# 包圍盒
	var lo := pos[0]
	var hi := pos[0]
	for v in pos:
		lo = lo.min(v)
		hi = hi.max(v)
	var span: Vector3 = (hi - lo)
	var longest: float = maxf(maxf(span.x, span.y), span.z)
	# 二分搜尋格數，逼近目標三角形數
	var lo_c := 8
	var hi_c := 320
	var best_cells := 64
	var best_diff := 1 << 30
	for _i in 9:
		var c: int = (lo_c + hi_c) / 2
		var n_t: int = _count_tris(pos, uv, idx, lo, longest / float(c))
		if absi(n_t - target) < best_diff:
			best_diff = absi(n_t - target)
			best_cells = c
		if n_t > target:
			hi_c = c - 1
		else:
			lo_c = c + 1
		if lo_c > hi_c:
			break
	var cell: float = longest / float(best_cells)
	# 正式分群
	var key_to_rep := {}
	var vmap := PackedInt32Array()
	vmap.resize(pos.size())
	var reps := PackedInt32Array()
	for i in pos.size():
		var k: String = _key(pos[i], uv, i, lo, cell)
		if key_to_rep.has(k):
			vmap[i] = key_to_rep[k]
		else:
			var ni: int = reps.size()
			key_to_rep[k] = ni
			reps.append(i)
			vmap[i] = ni
	# 三角形重建（退化與重複都丟掉）
	var seen := {}
	var new_idx := PackedInt32Array()
	var t := 0
	while t < idx.size():
		var a: int = vmap[idx[t]]
		var b: int = vmap[idx[t + 1]]
		var c2: int = vmap[idx[t + 2]]
		t += 3
		if a == b or b == c2 or a == c2:
			continue
		var s0: int = mini(a, mini(b, c2))
		var s2: int = maxi(a, maxi(b, c2))
		var s1: int = a + b + c2 - s0 - s2
		var kk: int = s0 * 1000000007 + s1 * 1000003 + s2
		if seen.has(kk):
			continue
		seen[kk] = true
		new_idx.append(a)
		new_idx.append(b)
		new_idx.append(c2)
	# 只留真的被用到的代表點
	var used := {}
	for v in new_idx:
		used[v] = true
	var compact := PackedInt32Array()
	compact.resize(reps.size())
	for i in compact.size():
		compact[i] = -1
	var np := PackedVector3Array()
	var nn := PackedVector3Array()
	var nu := PackedVector2Array()
	var nb := PackedInt32Array()
	var nw := PackedFloat32Array()
	for i in reps.size():
		if not used.has(i):
			continue
		compact[i] = np.size()
		var src_i: int = reps[i]
		np.append(pos[src_i])
		if nrm != null:
			nn.append((nrm as PackedVector3Array)[src_i])
		if uv != null:
			nu.append((uv as PackedVector2Array)[src_i])
		if bones != null:
			for b2 in 4:
				nb.append((bones as PackedInt32Array)[src_i * 4 + b2])
			var sum := 0.0
			for b3 in 4:
				sum += (wts as PackedFloat32Array)[src_i * 4 + b3]
			for b4 in 4:
				nw.append((wts as PackedFloat32Array)[src_i * 4 + b4] / maxf(sum, 0.000001))
	for i in new_idx.size():
		new_idx[i] = compact[new_idx[i]]
	var na := []
	na.resize(Mesh.ARRAY_MAX)
	na[Mesh.ARRAY_VERTEX] = np
	if nrm != null:
		na[Mesh.ARRAY_NORMAL] = nn
	if uv != null:
		na[Mesh.ARRAY_TEX_UV] = nu
	if bones != null:
		na[Mesh.ARRAY_BONES] = nb
		na[Mesh.ARRAY_WEIGHTS] = nw
	na[Mesh.ARRAY_INDEX] = new_idx
	return [na, tri0, new_idx.size() / 3]


func _key(p: Vector3, uv, i: int, lo: Vector3, cell: float) -> String:
	var gx := int(floor((p.x - lo.x) / cell))
	var gy := int(floor((p.y - lo.y) / cell))
	var gz := int(floor((p.z - lo.z) / cell))
	if uv == null:
		return "%d,%d,%d" % [gx, gy, gz]
	var t: Vector2 = (uv as PackedVector2Array)[i]
	# UV 只用 8 格：夠粗，不會把接縫兩側合併，也不會把頂點數撐回去
	return "%d,%d,%d,%d,%d" % [gx, gy, gz, int(t.x * 8.0), int(t.y * 8.0)]


func _count_tris(pos: PackedVector3Array, uv, idx: PackedInt32Array,
		lo: Vector3, cell: float) -> int:
	var m := {}
	var vmap := PackedInt32Array()
	vmap.resize(pos.size())
	var n := 0
	for i in pos.size():
		var k: String = _key(pos[i], uv, i, lo, cell)
		if m.has(k):
			vmap[i] = m[k]
		else:
			m[k] = n
			vmap[i] = n
			n += 1
	var cnt := 0
	var t := 0
	while t < idx.size():
		var a: int = vmap[idx[t]]
		var b: int = vmap[idx[t + 1]]
		var c: int = vmap[idx[t + 2]]
		t += 3
		if a != b and b != c and a != c:
			cnt += 1
	return cnt
