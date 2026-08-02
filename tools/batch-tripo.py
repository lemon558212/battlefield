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
# ★2026-08-02 補上 sniper：九名英雄裡少了韓沐霜（先前她是單獨試點做的），
# 預設清單只有 8 個，直接跑會漏掉她一個人。
_args = [a for a in sys.argv[2:] if not a.startswith("--")]
# 預設**不做** Tripo 動畫（省 6 次點數，動作走專案的 UAL 重定向）。
# 真的要 Tripo 自帶動作才加 --with-anims。
NO_ANIMS = "--with-anims" not in sys.argv
CHARS = _args or ["mg", "rifleman", "assault", "engineer", "specops",
                  "at", "mortar", "sam", "sniper"]
print("[tripo] 角色：%s" % ", ".join(CHARS))
print("[tripo] 動畫：%s" % ("跳過（省點數，動作走 UAL 重定向）" if NO_ANIMS
                            else "向 Tripo 要 6 個（每個都扣點數）"))
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
        # ★★2026-08-02：原始下載檔要**保留並進版控**，不可再當根目錄暫存。
        #   先前 `t-{cls}-base.glb` 寫在專案根目錄、沒進 git、事後被清掉，
        #   結果付費生成的原始資產（含 2K 貼圖來源）整批消失——想換一種處理方式
        #   或重新合併動畫，只能再花一次點數重生成。Tripo 每次生成都扣點數，
        #   原始檔就是錢，必須留下來。
        RAW_DIR = os.path.join(ROOT, "assets", "models", "tripo-raw")
        os.makedirs(RAW_DIR, exist_ok=True)
        base_glb = os.path.join(RAW_DIR, f"{cls}-base.glb")
        urllib.request.urlretrieve(base_out["pbr_model"], base_glb)
        print(f"  原始檔已留存 {os.path.relpath(base_glb, ROOT)}"
              f"（{os.path.getsize(base_glb)} bytes，記得 commit）", flush=True)
        rid = post({"type": "animate_rig", "original_model_task_id": mid})
        wait(rid, "rig"); print("  rig OK", flush=True)
        # ★★2026-08-02 省點數：Tripo 的動畫**不是必需品**。
        #   這個專案有自己的 UAL 重定向系統（Retarget.gd，已成熟），
        #   現行九名角色全部是 anim=0、動作一律由 UAL 即時重定向提供。
        #   Tripo 每個 animate_retarget 都要扣點數，六個就是六次；
        #   跳過它們，每個角色的消耗從「生成＋綁骨＋6 動畫」降到「生成＋綁骨」。
        #   只有在確定要用 Tripo 自帶動作時才開 --with-anims。
        if NO_ANIMS:
            rig_out = wait(rid, "rig-model")
            url = rig_out.get("model") or rig_out.get("pbr_model")
            if not url:
                raise RuntimeError("rig 沒有回傳模型網址：%s" % rig_out)
            # 綁骨的原始下載檔也留一份（理由同 base：綁骨一樣扣點數）
            rig_raw = os.path.join(RAW_DIR, f"{cls}-rigged.glb")
            urllib.request.urlretrieve(url, rig_raw)
            merged_src = os.path.join(ROOT, "godot", "assets", "models", "chars",
                                      f"{cls}-tripo.glb")
            import shutil
            shutil.copyfile(rig_raw, merged_src)
            hd = transplant(merged_src, base_glb)
            print(f"  rig-only OK（跳過 6 個動畫＝省 6 次點數）"
                  f"　2K transplant: {'OK' if hd else 'SKIP(UV不符)'}", flush=True)
            print(f"  done {cls} ({int(time.time()-t0)}s, "
                  f"{os.path.getsize(merged_src)} bytes)", flush=True)
            continue
        anims = {}
        for a in ["idle", "walk", "run", "shoot", "hurt", "fall"]:
            anims[a] = post({"type": "animate_retarget", "original_model_task_id": rid, "animation": "preset:" + a})
        files = {}
        for a, tid in anims.items():
            out = wait(tid, a)
            fp = os.path.join(ROOT, f"t-{cls}-{a}.glb")
            urllib.request.urlretrieve(out["model"], fp); files[a] = fp
        print("  anims OK", flush=True)
        # ★2026-08-02：成品直接落進 **Godot** 的資產目錄。
        # 先前輸出到舊 HTML5 版的 assets/models/chars/，得再手動搬一次到
        # godot/assets/models/chars/ 才會被 Godot 匯入——跑 9 個角色就是搬 9 次，
        # 而且漏搬一個就是「模型明明生成了卻沒上場」。Godot 版是現行主線
        # （HTML5 版已凍結當對照組，不需要新資產）。
        merged = os.path.join(ROOT, "godot", "assets", "models", "chars", f"{cls}-tripo.glb")
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
