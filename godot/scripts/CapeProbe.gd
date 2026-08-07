# CapeProbe.gd — 立繪本人模型（tripo）網格結構重新檢視（2026-08-07 使用者指正）。
#
# 使用者說：「人物、武器、手、頭髮都跟披風黏在一起，而且感覺有些應該是圖的空白處，
#            但還是生成出遊戲裡」。
# 這支就是去證實／證偽這句話，用的是網格自己的資料，不是看畫面猜：
#   ① 有幾個 MeshInstance3D、幾個 surface  → 部位有沒有被分開
#   ② **連通元件（island）分析**            → 幾何上到底是「一整塊」還是「多塊」
#      union-find 走過每個三角形，位置相同的頂點先焊在一起（跨 UV 縫也算同一點）。
#      如果整具角色只有 1 個 island，那「武器/手/頭髮/披風黏在一起」就是字面意義的事實：
#      它們是同一塊連通的三角網，沒有任何辦法只讓披風動而其他不動。
#   ③ 每個 island 的 AABB 與三角數        → 離身體很遠的小碎塊＝立繪空白處被重建成幾何
#   ④ 骨骼影響數                          → 有沒有可獨立驅動的自由度
extends Node3D

const TARGETS := [
	"res://assets/models/chars/tripo_han.glb",
	"res://assets/models/chars/sniper-tripo3.glb",
	"res://assets/models/chars/hr_w_Swat.fbx",     # 對照組：正常的分件角色
]

func _ready() -> void:
	for path in TARGETS:
		if not ResourceLoader.exists(path):
			print("[mesh] 缺檔 ", path)
			continue
		print("\n======== ", path.get_file(), " ========")
		var root := (load(path) as PackedScene).instantiate()
		add_child(root)
		_dump(root)
		root.queue_free()
	get_tree().quit(0)


func _dump(root: Node) -> void:
	var mis: Array = root.find_children("*", "MeshInstance3D", true, false)
	print("  MeshInstance3D 數量：%d %s" % [mis.size(),
			"← 全身只有一個網格節點＝部位沒有被分開" if mis.size() == 1 else ""])
	for m in mis:
		var mi := m as MeshInstance3D
		var mesh := mi.mesh
		if mesh == null:
			continue
		print("  ── 網格 %s：surface=%d 材質=%s" % [mi.name, mesh.get_surface_count(),
				_mat_names(mi, mesh)])
		for si in mesh.get_surface_count():
			_islands(mesh, si)


func _mat_names(mi: MeshInstance3D, mesh: Mesh) -> String:
	var out: Array = []
	for si in mesh.get_surface_count():
		var mat := mi.get_active_material(si)
		out.append(mat.resource_name if mat != null and mat.resource_name != "" else "(無名)")
	return ", ".join(out)


# 連通元件分析。焊接容差用整具模型尺寸的萬分之一，跨 UV 縫的重複頂點會被視為同一點
# （不焊的話每個 UV 島都會被算成獨立元件，結論會完全相反——這是這類分析最常見的錯誤）。
func _islands(mesh: Mesh, si: int) -> void:
	var arrays: Array = mesh.surface_get_arrays(si)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx = arrays[Mesh.ARRAY_INDEX]
	if verts.size() == 0:
		print("      surface %d：空" % si)
		return
	var full: AABB = AABB(verts[0], Vector3.ZERO)
	for v in verts:
		full = full.expand(v)
	var tol: float = maxf(full.size.length() * 0.0002, 0.00001)
	# --- 焊接：把位置量化成格點，同格視為同一頂點 ---
	var weld: Dictionary = {}          # 量化鍵 -> 代表索引
	var rep: PackedInt32Array = PackedInt32Array()
	rep.resize(verts.size())
	for i in verts.size():
		var v: Vector3 = verts[i]
		var key: String = "%d_%d_%d" % [roundi(v.x / tol), roundi(v.y / tol), roundi(v.z / tol)]
		if weld.has(key):
			rep[i] = int(weld[key])
		else:
			weld[key] = i
			rep[i] = i
	# --- union-find over 三角形 ---
	var parent: PackedInt32Array = PackedInt32Array()
	parent.resize(verts.size())
	for i in verts.size():
		parent[i] = rep[i]
	var tri_count := 0
	if idx == null or idx.size() == 0:
		# 沒有索引＝逐三角形頂點列表
		tri_count = verts.size() / 3
		for t in tri_count:
			_union(parent, rep[t * 3], rep[t * 3 + 1])
			_union(parent, rep[t * 3], rep[t * 3 + 2])
	else:
		tri_count = idx.size() / 3
		for t in tri_count:
			_union(parent, rep[idx[t * 3]], rep[idx[t * 3 + 1]])
			_union(parent, rep[idx[t * 3]], rep[idx[t * 3 + 2]])
	# --- 統計每個元件 ---
	var comp: Dictionary = {}          # root -> {n, aabb}
	for i in verts.size():
		if rep[i] != i:
			continue                    # 只算代表點，避免重複計數
		var r: int = _find(parent, i)
		if comp.has(r):
			comp[r]["n"] = int(comp[r]["n"]) + 1
			comp[r]["aabb"] = (comp[r]["aabb"] as AABB).expand(verts[i])
		else:
			comp[r] = {"n": 1, "aabb": AABB(verts[i], Vector3.ZERO)}
	var list: Array = comp.values()
	list.sort_custom(func(a, b): return int(a["n"]) > int(b["n"]))
	print("      surface %d：頂點 %d（焊接後 %d）三角 %d → **連通元件 %d 個**"
			% [si, verts.size(), weld.size(), tri_count, list.size()])
	var body: AABB = list[0]["aabb"]
	for i in mini(list.size(), 12):
		var c: Dictionary = list[i]
		var ab: AABB = c["aabb"]
		var far: float = ab.get_center().distance_to(body.get_center())
		var tag := ""
		if i == 0:
			tag = "← 主體"
			if float(c["n"]) / float(weld.size()) > 0.9:
				tag += "（佔全部頂點的 %.0f%%＝武器/手/頭髮/披風全在這一塊裡，幾何上焊死）" \
						% (100.0 * float(c["n"]) / float(weld.size()))
		elif float(c["n"]) < float(weld.size()) * 0.02:
			tag = "← 碎塊（%.0f%% 頂點，離主體 %.2fm）＝很可能是立繪空白處被重建出來的雜訊" \
					% [100.0 * float(c["n"]) / float(weld.size()), far]
		print("        元件#%-2d 頂點%-7d 尺寸 %.2f×%.2f×%.2f  %s"
				% [i, int(c["n"]), ab.size.x, ab.size.y, ab.size.z, tag])
	if list.size() > 12:
		print("        …另有 %d 個更小的元件" % (list.size() - 12))


func _find(parent: PackedInt32Array, i: int) -> int:
	var r := i
	while parent[r] != r:
		r = parent[r]
	while parent[i] != r:
		var nxt := parent[i]
		parent[i] = r
		i = nxt
	return r


func _union(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[rb] = ra
