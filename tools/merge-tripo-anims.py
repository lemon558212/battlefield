# -*- coding: utf-8 -*-
"""
merge-tripo-anims.py — 把多個 Tripo retarget glb 的動畫合併進單一 glb（純標準庫）
基底＝idle 檔（含網格+骨架+idle 動畫）；其餘檔只抽 animation 及其 accessor/bufferView/位元組。
動畫名稱重新命名為引擎 pick() 認得的 idle/walk/run/shoot/hit/death（engine3d.js _cloneModel）。
用法：python tools/merge-tripo-anims.py <out.glb> <base_idle.glb> walk=<walk.glb> ...
"""
import json, struct, sys

def read_glb(path):
    with open(path, "rb") as f: data = f.read()
    assert data[:4] == b"glTF", path
    ln = struct.unpack("<I", data[8:12])[0]
    off = 12; js = None; bin_ = b""
    while off < ln:
        clen, ctype = struct.unpack("<II", data[off:off+8]); off += 8
        chunk = data[off:off+clen]; off += clen
        if ctype == 0x4E4F534A: js = json.loads(chunk.decode("utf-8"))
        elif ctype == 0x004E4942: bin_ = chunk
    return js, bin_

def write_glb(path, js, bin_):
    jb = json.dumps(js, separators=(",", ":")).encode("utf-8")
    jb += b" " * ((4 - len(jb) % 4) % 4)
    bin_ += b"\x00" * ((4 - len(bin_) % 4) % 4)
    total = 12 + 8 + len(jb) + 8 + len(bin_)
    with open(path, "wb") as f:
        f.write(b"glTF" + struct.pack("<II", 2, total))
        f.write(struct.pack("<II", len(jb), 0x4E4F534A) + jb)
        f.write(struct.pack("<II", len(bin_), 0x004E4942) + bin_)

def main():
    out = sys.argv[1]; base_path = sys.argv[2]
    extras = [a.split("=", 1) for a in sys.argv[3:]]
    js, bin_ = read_glb(base_path)
    bin_ = bytearray(bin_)
    if js.get("animations"): js["animations"][0]["name"] = "idle"
    name_to_idx = {n.get("name", ""): i for i, n in enumerate(js["nodes"])}

    for clip_name, path in extras:
        sjs, sbin = read_glb(path)
        anim = sjs["animations"][0]
        s_nodes = sjs["nodes"]
        acc_map = {}
        def copy_acc(ai):
            if ai in acc_map: return acc_map[ai]
            acc = dict(sjs["accessors"][ai])
            bv = dict(sjs["bufferViews"][acc["bufferView"]])
            start = bv.get("byteOffset", 0); ln = bv["byteLength"]
            pad = (4 - len(bin_) % 4) % 4
            bin_.extend(b"\x00" * pad)
            new_off = len(bin_)
            bin_.extend(sbin[start:start+ln])
            bv["byteOffset"] = new_off; bv["buffer"] = 0
            js["bufferViews"].append(bv)
            acc["bufferView"] = len(js["bufferViews"]) - 1
            js["accessors"].append(acc)
            acc_map[ai] = len(js["accessors"]) - 1
            return acc_map[ai]
        new_samplers = []
        for sm in anim["samplers"]:
            new_samplers.append({"input": copy_acc(sm["input"]),
                                 "output": copy_acc(sm["output"]),
                                 "interpolation": sm.get("interpolation", "LINEAR")})
        new_channels = []
        for ch in anim["channels"]:
            src_node = s_nodes[ch["target"]["node"]]
            tgt = name_to_idx.get(src_node.get("name", ""))
            if tgt is None: continue                     # 名字對不上就丟棄該軌
            new_channels.append({"sampler": ch["sampler"],
                                 "target": {"node": tgt, "path": ch["target"]["path"]}})
        js.setdefault("animations", []).append(
            {"name": clip_name, "samplers": new_samplers, "channels": new_channels})
        print(f"{clip_name}: {len(new_channels)} tracks")

    js["buffers"] = [{"byteLength": len(bin_)}]
    write_glb(out, js, bytes(bin_))
    import os
    print("out:", out, os.path.getsize(out), "bytes,",
          len(js["animations"]), "animations")

if __name__ == "__main__":
    main()
