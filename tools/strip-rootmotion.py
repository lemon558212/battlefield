# -*- coding: utf-8 -*-
"""
strip-rootmotion.py — 就地剝除 glb 指定動畫的根骨位移（治「開槍往後飛/瞬移」）
對 clip 名單中的動畫：找 targeting Root/Hip/Pelvis 的 translation channel，
把 output accessor 所有幀改寫為 idle clip 的首幀值（無 idle 則歸零），
與 js/engine3d.js _sanitizeRootMotion 的載入端消毒邏輯一致。
（舊版釘在「該 clip 自己的首幀」——shoot 首幀本身已偏移，會凍成非零常數瞬移）
用法：python tools/strip-rootmotion.py <glb路徑> <clip1,clip2,...>
"""
import json, struct, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util
_s = importlib.util.spec_from_file_location("mt", os.path.join(os.path.dirname(os.path.abspath(__file__)), "merge-tripo-anims.py"))
mt = importlib.util.module_from_spec(_s); _s.loader.exec_module(mt)

ROOTS = {"Root", "Hip", "Hips", "Pelvis"}

def _root_channels(js, anim, node_names):
    """列出該動畫中 targeting 根骨、float VEC3 的 translation channel 的 (byte偏移, 幀數)。"""
    out = []
    for ch in anim["channels"]:
        if ch["target"].get("path") != "translation": continue
        if node_names[ch["target"]["node"]] not in ROOTS: continue
        sampler = anim["samplers"][ch["sampler"]]
        acc = js["accessors"][sampler["output"]]
        if acc.get("componentType") != 5126 or acc.get("type") != "VEC3": continue
        bv = js["bufferViews"][acc["bufferView"]]
        off = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
        out.append((off, acc["count"], node_names[ch["target"]["node"]]))
    return out

def main():
    path = sys.argv[1]; clips = set(sys.argv[2].split(","))
    js, bin_ = mt.read_glb(path)
    bin_ = bytearray(bin_)
    node_names = [n.get("name", "") for n in js["nodes"]]
    anims = js.get("animations", [])
    # 基準＝idle clip 根骨首幀（同 engine3d._sanitizeRootMotion）；無 idle 則歸零
    ref = (0.0, 0.0, 0.0)
    idle = next((a for a in anims if "idle" in (a.get("name") or "").lower()), None)
    if idle:
        chs = _root_channels(js, idle, node_names)
        if chs:
            ref = struct.unpack_from("<fff", bin_, chs[0][0])
            print(f"  ref = idle 首幀 {tuple(round(v, 4) for v in ref)}")
        else:
            print("  警告：idle clip 無根骨 translation 軌道，基準歸零")
    else:
        print("  警告：找不到 idle clip，基準歸零")
    fixed = 0
    for anim in anims:
        if anim.get("name") not in clips: continue
        for off, n, node in _root_channels(js, anim, node_names):
            for i in range(n):
                struct.pack_into("<fff", bin_, off + i * 12, *ref)   # 全幀覆寫為 idle 首幀
            fixed += 1
            print(f"  {anim['name']}: node {node}, {n} keys flattened")
    mt.write_glb(path, js, bytes(bin_))
    print(f"{os.path.basename(path)}: {fixed} tracks fixed")

if __name__ == "__main__":
    main()
