# -*- coding: utf-8 -*-
"""gen3d.py — 立繪→3D 模型生成管線（可搬移，跨機器）。

為什麼要有這支：使用者有兩台機器，一台 8GB VRAM、一台 64GB。
Claude 只能操作「當前對話所在的那台」，無法跨機器執行。
所以把整條管線做成一鍵腳本進版控：在哪台跑都一樣，
腳本自己偵測 VRAM 決定用哪個模型與品質檔位，輸出直接落進 repo。

用法（在專案根目錄）：
    python tools/gen3d/gen3d.py setup      # 建 venv、裝相依、抓權重（只需一次）
    python tools/gen3d/gen3d.py plan       # 只印出「這台會用什麼設定」，不動手
    python tools/gen3d/gen3d.py run        # 生成全部（已存在的略過，可中斷續跑）
    python tools/gen3d/gen3d.py run tank sniper   # 只生成指定項目

輸出：godot/assets/models/gen3d/<name>.glb（車輛另出 _hull/_turret）
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

try:      # Windows 主控台預設 cp950，非中文符號會讓腳本整個崩潰
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = Path(__file__).resolve().parents[2]
PORTRAITS = ROOT / "godot" / "assets" / "portraits"
OUT_DIR = ROOT / "godot" / "assets" / "models" / "gen3d"
WORK = ROOT / ".gen3d"                 # venv 與權重（已在 .gitignore）

CHARS = ["rifleman", "assault", "mg", "sniper", "at", "mortar",
         "engineer", "specops", "sam"]
VEHICLES = ["tank", "destroyer", "missileboat", "lst", "submarine",
            "fighter", "attacker", "gunship"]

# 各品質檔位。⚠ 門檻是實測出來的，不是猜的：
#   8GB 上 octree 512＋貼圖 2048 跑四小時未完成、150k 面貼圖直接 OOM。
PROFILES = [
    # (最低VRAM_GB, 名稱, 形狀模型, 解析度, 減面目標, 貼圖邊長)
    (40, "ultra",   "trellis2",      1536, 200000, 2048),
    (22, "high",    "trellis2",      1024, 150000, 2048),
    (14, "medium",  "hunyuan-full",   512, 150000, 2048),
    (0,  "low",     "hunyuan-mini",   512, 100000, 1024),
]


def vram_gb() -> float:
    """偵測本機 VRAM（GB）。偵測不到回 0.0，但**必須讓人知道**——見下方警告。

    ⚠⚠ 2026-08-02 教訓：這裡原本 `except: return 0.0` 完全不吭聲，
    於是 VRAM 偵測失敗時整批悄悄降級成 low 檔位（hunyuan-mini／1024 貼圖），
    跑完 17 件、看起來一切正常，實際上是最低品質。使用者因此以為手上那批是
    TRELLIS.2 ultra，直到從貼圖只有 1024×1024 才反推出來。
    「靜默回退」在這個專案已經造成多次假成功，一律要喊。
    """
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=memory.total", "--format=csv,noheader,nounits"],
            text=True, timeout=20)
        return float(out.strip().splitlines()[0]) / 1024.0
    except Exception as e:
        print("[gen3d] ⚠⚠ 偵測不到 VRAM（nvidia-smi 失敗：%s）" % e)
        print("[gen3d]    → 會被當成 0GB 而選最低檔位 low（hunyuan-mini／1024 貼圖）。")
        print("[gen3d]    → 若這台其實是大顯卡，請先修好 nvidia-smi，或用")
        print("[gen3d]      --profile ultra 明確指定，否則會白跑一整批低品質模型。")
        return 0.0


def pick_profile(force: str = "") -> dict:
    v = vram_gb()
    for lo, name, model, res, faces, tex in PROFILES:
        if force:
            if name != force:
                continue
        elif v < lo:
            continue
        return {"vram": v, "name": name, "model": model, "res": res,
                "faces": faces, "tex": tex}
    # 走到這裡＝沒有任何檔位符合（force 打錯字，或 VRAM 偵測回 0）。
    # ⚠ 不可以安靜地回 low：那正是「跑完才發現是最低品質」的成因。
    if force:
        print("[gen3d] ⚠⚠ 指定的檔位「%s」不存在（可用：ultra/high/medium/low），"
              "已回退 low" % force)
    else:
        print("[gen3d] ⚠⚠ VRAM %.0fGB 不符合任何檔位門檻，回退 low"
              "（hunyuan-mini／1024 貼圖＝最低品質）" % v)
    return {"vram": v, "name": "low", "model": "hunyuan-mini", "res": 512,
            "faces": 100000, "tex": 1024}


def cmd_plan(args):
    p = pick_profile(args.profile)
    todo = args.items or (CHARS + VEHICLES)
    have = [n for n in todo if (OUT_DIR / f"{n}.glb").exists()]
    print(f"[gen3d] 這台 VRAM {p['vram']:.0f}GB → 檔位「{p['name']}」")
    print(f"[gen3d]   形狀模型 {p['model']}／解析度 {p['res']}^3／"
          f"減面 {p['faces']:,} 面／貼圖 {p['tex']}")
    print(f"[gen3d] 待生成 {len(todo) - len(have)} 件，已完成 {len(have)} 件"
          f"（已完成的會略過，可中斷續跑）")
    if p["model"] == "trellis2" and p["vram"] < 22:
        print("[gen3d] ⚠ 這台 VRAM 不足以跑 TRELLIS.2，請不要強制指定 ultra/high")
    missing = [n for n in todo if not (PORTRAITS / f"{n}.png").exists()]
    if missing:
        print(f"[gen3d] ⚠ 缺立繪：{missing}")
    return 0


def _venv_py() -> Path:
    return WORK / "venv" / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


def _run(cmd, **kw):
    print("[gen3d] $", " ".join(str(c) for c in cmd[:6]), "…")
    return subprocess.run(cmd, check=True, **kw)


def cmd_setup(args):
    p = pick_profile(args.profile)
    WORK.mkdir(exist_ok=True)
    py = _venv_py()
    if not py.exists():
        # ⚠ Windows 長路徑限制：venv 放太深會在裝 open3d 時炸掉
        #   （實測 75 字元的路徑就失敗）。放在專案根目錄下的 .gen3d 即可。
        _run([sys.executable, "-m", "venv", str(WORK / "venv")])
    pip = [str(py), "-m", "pip", "install", "-q", "--upgrade"]
    _run(pip + ["pip", "wheel"])
    cu = "cu128"     # Blackwell(sm120) 以後只能 cu128 起跳
    _run([str(py), "-m", "pip", "install", "-q",
          "torch==2.7.0", "torchvision==0.22.0",
          "--index-url", f"https://download.pytorch.org/whl/{cu}"])
    _run([str(py), "-m", "pip", "install", "-q",
          "Pillow", "numpy", "trimesh", "fast_simplification", "rembg",
          "onnxruntime", "huggingface_hub", "diffusers>=0.31.0",
          "transformers>=4.46.0", "accelerate", "einops", "scipy",
          "scikit-image", "xatlas", "pygltflib", "opencv-python-headless"])
    if p["model"] == "trellis2":
        # TRELLIS.2 的四個 CUDA 元件有現成 Windows/Linux wheel，不必本機編譯
        # （本機編譯在 VS2026 上會讓 nvcc 的 cudafe++ 崩潰，實測過）
        base = "https://pozzettiandrea.github.io/cuda-wheels"
        tag = f"cu128torch2.7-cp{sys.version_info.major}{sys.version_info.minor}"
        plat = "win_amd64" if os.name == "nt" else "manylinux_2_35_x86_64"
        for lib, ver in [("cumesh", "0.0.1"), ("flex-gemm", "1.0.0"),
                         ("nvdiffrast", "0.4.0"), ("o-voxel", "0.0.1")]:
            fn = f"{lib.replace('-', '_')}-{ver}%2B{tag}-cp{sys.version_info.major}{sys.version_info.minor}-{plat}.whl"
            url = f"{base}/{lib}/{fn}"
            try:
                _run([str(py), "-m", "pip", "install", "-q", url])
            except subprocess.CalledProcessError:
                print(f"[gen3d] ⚠ {lib} wheel 裝不起來：{url}")
                print("[gen3d]   → 這台可能要改用 medium/low 檔位（見 plan）")
                return 1
    print(f"[gen3d] setup 完成（檔位 {p['name']}）。接著跑：python tools/gen3d/gen3d.py run")
    return 0


def cmd_run(args):
    p = pick_profile(args.profile)
    py = _venv_py()
    if not py.exists():
        print("[gen3d] 還沒 setup —— 先跑 python tools/gen3d/gen3d.py setup")
        return 1
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    todo = args.items or (CHARS + VEHICLES)
    worker = Path(__file__).with_name("worker.py")
    ok, fail, skip = 0, 0, 0
    for name in todo:
        out = OUT_DIR / f"{name}.glb"
        if out.exists() and not args.force:
            skip += 1
            continue
        src = PORTRAITS / f"{name}.png"
        if not src.exists():
            print(f"[gen3d] FAIL {name}：找不到立繪 {src}")
            fail += 1
            continue
        print(f"[gen3d] ===== {name}（{p['name']}）=====", flush=True)
        r = subprocess.run([str(py), str(worker),
                            "--image", str(src), "--out", str(out),
                            "--model", p["model"], "--res", str(p["res"]),
                            "--faces", str(p["faces"]), "--tex", str(p["tex"]),
                            "--kind", "vehicle" if name in VEHICLES else "char"])
        if r.returncode == 0 and out.exists():
            ok += 1
        else:
            print(f"[gen3d] FAIL {name} 生成失敗（保留已完成的，可重跑續做）")
            fail += 1
    print(f"[gen3d] 完成 {ok} 件／失敗 {fail} 件／略過 {skip} 件（已存在）")
    print(f"[gen3d] 輸出在 {OUT_DIR}")
    print("[gen3d] 接著：git add godot/assets/models/gen3d && git commit && git push")
    return 0 if fail == 0 else 1


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for nm, fn in (("plan", cmd_plan), ("setup", cmd_setup), ("run", cmd_run)):
        s = sub.add_parser(nm)
        s.add_argument("items", nargs="*")
        s.add_argument("--profile", default="", help="強制檔位 ultra/high/medium/low")
        s.add_argument("--force", action="store_true", help="已存在也重做")
        s.set_defaults(func=fn)
    a = ap.parse_args()
    return a.func(a)


if __name__ == "__main__":
    raise SystemExit(main())
