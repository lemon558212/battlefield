# -*- coding: utf-8 -*-
"""
batch-tripo.py — 8 名角色 image-to-3D 全自動管線 + 2K 貼圖移植 + base64 打包
流程/角色：上傳立繪→image_to_model(20k面,2K貼圖)→下載基底(2K貼圖來源)→rig→6動畫→
下載→合併(引用 merge-tripo-anims)→UV相同則移植2K貼圖→輸出 glb+b64 js
用法：python tools/batch-tripo.py <KEY> [chars...]
"""
import json, os, sys, time, base64, hashlib, struct, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util
_spec = importlib.util.spec_from_file_location("mt", os.path.join(os.path.dirname(os.path.abspath(__file__)), "merge-tripo-anims.py"))
mt = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(mt)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEY = sys.argv[1]
CHARS = sys.argv[2:] or ["mg", "rifleman", "assault", "engineer", "specops", "at", "mortar", "sam"]
H = {"Authorization": "Bearer " + KEY, "Content-Type": "application/json"}

def post(body):
    req = urllib.request.Request("https://api.tripo3d.ai/v2/openapi/task", data=json.dumps(body).encode(), headers=H)
    d = json.load(urllib.request.urlopen(req, timeout=60))
    if d["code"] != 0: raise RuntimeError(str(d))
    return d["data"]["task_id"]

def wait(tid, tag):
    for _ in range(120):
        req = urllib.request.Request(f"https://api.tripo3d.ai/v2/openapi/task/{tid}", headers={"Authorization": "Bearer " + KEY})
        d = json.load(urllib.request.urlopen(req, timeout=30))["data"]
        if d["status"] == "success": return d["output"]
        if d["status"] in ("failed", "banned", "cancelled"): raise RuntimeError(tag + " " + d["status"])
        time.sleep(10)
    raise RuntimeError(tag + " timeout")

def upload(path):
    boundary = "b" + hashlib.md5(path.encode()).hexdigest()
    img = open(path, "rb").read()
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"p.jpg\"\r\n"
            "Content-Type: image/jpeg\r\n\r\n").encode() + img + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request("https://api.tripo3d.ai/v2/openapi/upload/sts", data=body,
        headers={"Authorization": "Bearer " + KEY, "Content-Type": f"multipart/form-data; boundary={boundary}"})
    d = json.load(urllib.request.urlopen(req, timeout=120))
    if d["code"] != 0: raise RuntimeError(str(d))
    return d["data"]["image_token"]

def uv_hash(js, bin_):
    """取三角形數最多 mesh 的 TEXCOORD_0 位元組雜湊（判斷 UV 是否一致）"""
    best = None; bestn = -1
    for mesh in js.get("meshes", []):
        for prim in mesh.get("primitives", []):
            uv = prim.get("attributes", {}).get("TEXCOORD_0")
            if uv is None: continue
            acc = js["accessors"][uv]
            if acc["count"] > bestn: bestn = acc["count"]; best = acc
    if best is None: return None
    bv = js["bufferViews"][best["bufferView"]]
    s = bv.get("byteOffset", 0)
    return hashlib.md5(bin_[s:s + bv["byteLength"]]).hexdigest()

def transplant(dst_path, src_path):
    """把 src(2K基底) 的 images 移植進 dst(合併動畫版)；UV 不符則放棄"""
    dj, db = mt.read_glb(dst_path); sj, sb = mt.read_glb(src_path)
    if uv_hash(dj, db) != uv_hash(sj, sb): return False
    if len(dj.get("images", [])) != len(sj.get("images", [])): return False
    db = bytearray(db)
    for di, si in zip(dj["images"], sj["images"]):
        sbv = sj["bufferViews"][si["bufferView"]]
        data = sb[sbv.get("byteOffset", 0): sbv.get("byteOffset", 0) + sbv["byteLength"]]
        pad = (4 - len(db) % 4) % 4; db.extend(b"\x00" * pad)
        off = len(db); db.extend(data)
        dbv = dj["bufferViews"][di["bufferView"]]
        dbv["byteOffset"] = off; dbv["byteLength"] = len(data)
    dj["buffers"] = [{"byteLength": len(db)}]
    mt.write_glb(dst_path, dj, bytes(db))
    return True

def b64_wrap(cls, glb_path):
    b64 = base64.b64encode(open(glb_path, "rb").read()).decode()
    out = os.path.join(ROOT, "js", f"model-data-{cls}.js")
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(f"/* {cls} 模型 base64 封裝（防毒攔截備援通道） */\n")
        f.write("window.MODEL_B64 = window.MODEL_B64 || {};\n")
        f.write(f'window.MODEL_B64.{cls} = "{b64}";\n')

for cls in CHARS:
    try:
        t0 = time.time()
        time.sleep(20)                       # 角色間隔，避開 API 限流(403)
        print(f"=== {cls} ===", flush=True)
        tok = upload(os.path.join(ROOT, "assets", "portraits-full", f"{cls}.jpg"))
        mid = post({"type": "image_to_model", "file": {"type": "jpg", "file_token": tok},
                    "face_limit": 20000, "texture_size": 2048})
        base_out = wait(mid, "model"); print("  model OK", flush=True)
        base_glb = os.path.join(ROOT, f"t-{cls}-base.glb")
        urllib.request.urlretrieve(base_out["pbr_model"], base_glb)
        rid = post({"type": "animate_rig", "original_model_task_id": mid})
        wait(rid, "rig"); print("  rig OK", flush=True)
        anims = {}
        for a in ["idle", "walk", "run", "shoot", "hurt", "fall"]:
            anims[a] = post({"type": "animate_retarget", "original_model_task_id": rid, "animation": "preset:" + a})
        files = {}
        for a, tid in anims.items():
            out = wait(tid, a)
            fp = os.path.join(ROOT, f"t-{cls}-{a}.glb")
            urllib.request.urlretrieve(out["model"], fp); files[a] = fp
        print("  anims OK", flush=True)
        merged = os.path.join(ROOT, "assets", "models", "chars", f"{cls}-tripo.glb")
        # 直接呼叫 merge 模組 main 邏輯：以 idle 為基底
        sys.argv = ["x", merged, files["idle"], f"walk={files['walk']}", f"run={files['run']}",
                    f"shoot={files['shoot']}", f"hit={files['hurt']}", f"death={files['fall']}"]
        try: mt.main()
        except SystemExit: pass
        hd = transplant(merged, base_glb)
        print(f"  2K transplant: {'OK' if hd else 'SKIP(UV不符)'}", flush=True)
        b64_wrap(cls, merged)
        print(f"  done {cls} ({int(time.time()-t0)}s, {os.path.getsize(merged)} bytes)", flush=True)
    except SystemExit:
        pass
    except Exception as e:
        print(f"  !! {cls} FAILED: {e}", flush=True)
print("ALL DONE", flush=True)
