#!/usr/bin/env python
# glb_decimate.py — 把 Tripo 之類的高面數 GLB 減面到可以進遊戲的量級。
#
# 為什麼要自己寫：本機沒有 Blender，也沒有 meshoptimizer 的 Python binding。
# 用的是「網格分群（vertex clustering）」——把空間切成格子，每格的頂點合併成一個代表點。
# 這是做 100 倍以上極端減面的標準手法（品質不如 quadric error metrics，但本專案
# 走低多邊形路線，格子造成的稜角反而符合美術方向）。
#
# 保留：骨骼索引與權重（JOINTS_0/WEIGHTS_0）、UV、材質與貼圖、skin 與骨架節點。
# UV 接縫用「座標 + 粗量化 UV」當分群鍵，否則接縫兩側會被合併、貼圖會被拉扯。
#
# 用法：
#   python tools/glb_decimate.py <來源.glb> <輸出.glb> [目標三角形數]

import struct, json, sys, base64
import numpy as np

CT = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16,
      5125: np.uint32, 5126: np.float32}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def read_glb(path):
    with open(path, "rb") as f:
        magic, ver, total = struct.unpack("<III", f.read(12))
        assert magic == 0x46546C67, "不是 GLB"
        js = None
        bin_ = b""
        while f.tell() < total:
            clen, ctype = struct.unpack("<II", f.read(8))
            data = f.read(clen)
            if ctype == 0x4E4F534A:
                js = json.loads(data.decode("utf-8"))
            elif ctype == 0x004E4942:
                bin_ = data
        return js, bin_


def acc_array(j, bin_, idx):
    a = j["accessors"][idx]
    bv = j["bufferViews"][a["bufferView"]]
    off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    n = a["count"]
    nc = NCOMP[a["type"]]
    dt = CT[a["componentType"]]
    stride = bv.get("byteStride")
    itemsize = np.dtype(dt).itemsize * nc
    if stride and stride != itemsize:
        out = np.empty((n, nc), dtype=dt)
        for i in range(n):
            s = off + i * stride
            out[i] = np.frombuffer(bin_, dtype=dt, count=nc, offset=s)
        return out
    arr = np.frombuffer(bin_, dtype=dt, count=n * nc, offset=off)
    return arr.reshape(n, nc)


def cluster(pos, uv, cells, uv_bins):
    lo = pos.min(axis=0)
    hi = pos.max(axis=0)
    span = np.maximum(hi - lo, 1e-9)
    cell = span.max() / cells
    gi = np.floor((pos - lo) / cell).astype(np.int64)
    key = [gi[:, 0], gi[:, 1], gi[:, 2]]
    if uv is not None and uv_bins > 0:
        ui = np.floor(np.clip(uv, 0.0, 0.999999) * uv_bins).astype(np.int64)
        key += [ui[:, 0], ui[:, 1]]
    keys = np.stack(key, axis=1)
    # 用 void view 做多欄位 unique：比字串鍵快得多，1M 頂點也只要幾秒
    v = np.ascontiguousarray(keys).view(
        np.dtype((np.void, keys.dtype.itemsize * keys.shape[1])))
    _, first, inv = np.unique(v.ravel(), return_index=True, return_inverse=True)
    return inv.astype(np.int64), first.astype(np.int64)


def build(src, dst, target_tris=12000):
    j, bin_ = read_glb(src)
    prim = j["meshes"][0]["primitives"][0]
    at = prim["attributes"]
    pos = acc_array(j, bin_, at["POSITION"]).astype(np.float32)
    idx = acc_array(j, bin_, prim["indices"]).astype(np.int64).ravel()
    nrm = acc_array(j, bin_, at["NORMAL"]) if "NORMAL" in at else None
    uv = acc_array(j, bin_, at["TEXCOORD_0"]).astype(np.float32) if "TEXCOORD_0" in at else None
    jt = acc_array(j, bin_, at["JOINTS_0"]) if "JOINTS_0" in at else None
    wt = acc_array(j, bin_, at["WEIGHTS_0"]) if "WEIGHTS_0" in at else None
    tris0 = len(idx) // 3
    print(f"來源：頂點 {len(pos):,}　三角形 {tris0:,}")

    if nrm is not None and nrm.dtype != np.float32:      # BYTE normalized → float
        info = np.iinfo(nrm.dtype)
        nrm = np.maximum(nrm.astype(np.float32) / info.max, -1.0)

    # 二分搜尋格數，逼近目標三角形數
    lo_c, hi_c = 8, 400
    best = None
    for _ in range(12):
        c = (lo_c + hi_c) // 2
        inv, first = cluster(pos, uv, c, 8)
        tri = inv[idx].reshape(-1, 3)
        ok = (tri[:, 0] != tri[:, 1]) & (tri[:, 1] != tri[:, 2]) & (tri[:, 0] != tri[:, 2])
        n_t = int(ok.sum())
        if best is None or abs(n_t - target_tris) < abs(best[0] - target_tris):
            best = (n_t, c, inv, first, tri, ok)
        if n_t > target_tris:
            hi_c = c - 1
        else:
            lo_c = c + 1
        if lo_c > hi_c:
            break
    n_t, c, inv, first, tri, ok = best
    tri = tri[ok]
    # 去掉重複三角形（分群後常出現同一組三個代表點）
    st = np.sort(tri, axis=1)
    v = np.ascontiguousarray(st).view(np.dtype((np.void, st.dtype.itemsize * 3)))
    _, keep = np.unique(v.ravel(), return_index=True)
    tri = tri[np.sort(keep)]
    print(f"分群：格數 {c}　新頂點 {len(first):,}　新三角形 {len(tri):,}")

    # 只保留真的被用到的代表點，並重新編號
    used = np.unique(tri.ravel())
    remap = np.full(len(first), -1, dtype=np.int64)
    remap[used] = np.arange(len(used))
    tri = remap[tri]
    rep = first[used]                      # 代表點在原始頂點陣列中的索引

    out = {"POSITION": pos[rep].astype(np.float32)}
    if nrm is not None:
        n = nrm[rep].astype(np.float32)
        ln = np.linalg.norm(n, axis=1, keepdims=True)
        out["NORMAL"] = (n / np.maximum(ln, 1e-6)).astype(np.float32)
    if uv is not None:
        out["TEXCOORD_0"] = uv[rep].astype(np.float32)
    if jt is not None:
        out["JOINTS_0"] = jt[rep].astype(np.uint8)
    if wt is not None:
        w = wt[rep].astype(np.float32)
        s = w.sum(axis=1, keepdims=True)
        w = np.where(s > 0, w / np.maximum(s, 1e-6), 0.0)
        w8 = np.round(w * 255.0).astype(np.int32)
        # uint8 正規化權重必須剛好加總 255，否則 Godot 會出現權重漂移
        diff = 255 - w8.sum(axis=1)
        w8[np.arange(len(w8)), w8.argmax(axis=1)] += diff
        out["WEIGHTS_0"] = np.clip(w8, 0, 255).astype(np.uint8)

    ind_dtype = np.uint16 if len(rep) < 65536 else np.uint32
    indices = tri.astype(ind_dtype).ravel()

    # ---- 重建 GLB ----
    blob = bytearray()
    bvs = []
    accs = []

    def add_bv(data, target=None):
        while len(blob) % 4:
            blob.append(0)
        off = len(blob)
        blob.extend(data)
        bv = {"buffer": 0, "byteOffset": off, "byteLength": len(data)}
        if target:
            bv["target"] = target
        bvs.append(bv)
        return len(bvs) - 1

    def add_acc(arr, typ, ctype, norm=False, target=34962):
        bvi = add_bv(arr.tobytes(), target)
        a = {"bufferView": bvi, "componentType": ctype, "count": int(arr.shape[0]),
             "type": typ}
        if norm:
            a["normalized"] = True
        if typ == "VEC3" and ctype == 5126:
            a["min"] = [float(x) for x in arr.min(axis=0)]
            a["max"] = [float(x) for x in arr.max(axis=0)]
        accs.append(a)
        return len(accs) - 1

    new_attrs = {}
    new_attrs["POSITION"] = add_acc(out["POSITION"], "VEC3", 5126)
    if "NORMAL" in out:
        new_attrs["NORMAL"] = add_acc(out["NORMAL"], "VEC3", 5126)
    if "TEXCOORD_0" in out:
        new_attrs["TEXCOORD_0"] = add_acc(out["TEXCOORD_0"], "VEC2", 5126)
    if "JOINTS_0" in out:
        new_attrs["JOINTS_0"] = add_acc(out["JOINTS_0"], "VEC4", 5121)
    if "WEIGHTS_0" in out:
        new_attrs["WEIGHTS_0"] = add_acc(out["WEIGHTS_0"], "VEC4", 5121, norm=True)
    idx_acc = add_acc(indices.reshape(-1, 1), "SCALAR",
                      5123 if ind_dtype == np.uint16 else 5125, target=34963)

    # inverseBindMatrices 原封搬過去
    if j.get("skins"):
        ibm_i = j["skins"][0].get("inverseBindMatrices")
        if ibm_i is not None:
            ibm = acc_array(j, bin_, ibm_i).astype(np.float32)
            bvi = add_bv(ibm.tobytes())
            accs.append({"bufferView": bvi, "componentType": 5126,
                         "count": int(ibm.shape[0]), "type": "MAT4"})
            j["skins"][0]["inverseBindMatrices"] = len(accs) - 1

    for im in j.get("images", []):
        if "bufferView" in im:
            bv = j["bufferViews"][im["bufferView"]]
            o = bv.get("byteOffset", 0)
            im["bufferView"] = add_bv(bin_[o:o + bv["byteLength"]])

    j["bufferViews"] = bvs
    j["accessors"] = accs
    prim["attributes"] = new_attrs
    prim["indices"] = idx_acc
    j["meshes"][0]["primitives"] = [prim]
    j["buffers"] = [{"byteLength": len(blob)}]
    j.pop("meshopt", None)

    js = json.dumps(j, separators=(",", ":")).encode("utf-8")
    while len(js) % 4:
        js += b" "
    while len(blob) % 4:
        blob.append(0)
    total = 12 + 8 + len(js) + 8 + len(blob)
    with open(dst, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(js), 0x4E4F534A))
        f.write(js)
        f.write(struct.pack("<II", len(blob), 0x004E4942))
        f.write(bytes(blob))
    print(f"輸出：{dst}　{total/1048576:.1f} MB　"
          f"三角形 {len(tri):,}（原 {tris0:,}，剩 {len(tri)*100.0/tris0:.2f}%）")


if __name__ == "__main__":
    src = sys.argv[1]
    dst = sys.argv[2]
    tgt = int(sys.argv[3]) if len(sys.argv) > 3 else 12000
    build(src, dst, tgt)
