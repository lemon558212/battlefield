# -*- coding: utf-8 -*-
"""worker.py — 單件立繪→3D 的實際幹活腳本（由 gen3d.py 在自己的 venv 裡呼叫）。

四步：去背緊裁 → 形狀生成 → 減面 → 貼圖。車輛再多一步拆砲塔。
⚠ 每一步失敗都直接非零離開並印原因，**不做靜默降級**——
  「以為換好了其實是舊的」在本專案踩過三次。
"""
import argparse
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def prep(src: Path, dst: Path) -> None:
    """去背＋緊裁：立繪的水彩噴濺背景會被當成幾何，長出鬚狀雜物（實拍抓到）。"""
    from PIL import Image
    from rembg import remove
    im = Image.open(src).convert("RGBA")
    cut = remove(im)
    bbox = cut.getbbox()
    if bbox is None:
        raise SystemExit(f"[worker] FAIL 去背後整張空白：{src}")
    cut = cut.crop(bbox)
    w, h = cut.size
    side = int(max(w, h) * 1.12)          # 四周留 6%：主體貼邊會讓模型判斷不出輪廓
    canvas = Image.new("RGBA", (side, side), (255, 255, 255, 0))
    canvas.paste(cut, ((side - w) // 2, (side - h) // 2), cut)
    canvas.save(dst)
    print(f"[worker] prep {src.name} -> {canvas.size}", flush=True)


def shape_hunyuan(img: Path, out: Path, res: int, full: bool) -> None:
    import torch
    from PIL import Image
    model_dir = ROOT / ".gen3d" / ("hunyuan-full" if full else "hunyuan-mini")
    sub = "hunyuan3d-dit-v2-0" if full else "hunyuan3d-dit-v2-mini"
    repo = "tencent/Hunyuan3D-2" if full else "tencent/Hunyuan3D-2mini"
    if not (model_dir / sub).exists():
        from huggingface_hub import snapshot_download
        print(f"[worker] 下載權重 {repo} …", flush=True)
        snapshot_download(repo_id=repo, local_dir=str(model_dir),
                          allow_patterns=[f"{sub}/**", "hunyuan3d-vae-v2-*/**"])
    src_dir = model_dir / "_hy3dgen"
    if not (src_dir / "hy3dgen").exists():
        raise SystemExit("[worker] FAIL 缺 hy3dgen 原始碼——先在有 modly 的機器上跑過一次，"
                         "或手動放進 .gen3d/<model>/_hy3dgen")
    sys.path.insert(0, str(src_dir))
    from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline
    pipe = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained(
        str(model_dir), subfolder=sub, use_safetensors=True, device="cuda")
    with torch.no_grad():
        o = pipe(image=Image.open(img).convert("RGBA"), num_inference_steps=50,
                 octree_resolution=res, guidance_scale=5.5, num_chunks=8000,
                 generator=torch.Generator().manual_seed(20260801),
                 output_type="trimesh")
    o[0].export(str(out))
    print(f"[worker] shape(hunyuan {'full' if full else 'mini'}) 面數 {len(o[0].faces)}", flush=True)


def shape_trellis2(img: Path, out: Path, res: int) -> None:
    """TRELLIS.2：微軟開源的 4B 模型，O-Voxel 原生支援開放曲面
    （衣物/髮絲/樹葉）——那正是 Hunyuan 等值面表示法做不好的地方。"""
    import torch
    from PIL import Image
    repo_dir = ROOT / ".gen3d" / "TRELLIS2"
    if not repo_dir.exists():
        import subprocess
        subprocess.run(["git", "clone", "--depth", "1",
                        "https://github.com/microsoft/TRELLIS.2.git", str(repo_dir)],
                       check=True)
    sys.path.insert(0, str(repo_dir))
    os.environ.setdefault("ATTN_BACKEND", "flash-attn")
    from trellis2.pipelines import Trellis2ImageTo3DPipeline
    pipe = Trellis2ImageTo3DPipeline.from_pretrained("microsoft/TRELLIS.2")
    pipe.cuda()
    with torch.no_grad():
        outs = pipe.run(Image.open(img).convert("RGB"),
                        seed=20260801, resolution=res)
    mesh = outs["mesh"][0] if isinstance(outs, dict) else outs[0]
    if hasattr(mesh, "export"):
        mesh.export(str(out))
    else:                                  # 有些版本回傳自家型別，轉 trimesh
        import trimesh
        trimesh.Trimesh(vertices=mesh.vertices.cpu().numpy(),
                        faces=mesh.faces.cpu().numpy()).export(str(out))
    print("[worker] shape(trellis2) 完成", flush=True)


def decimate(src: Path, dst: Path, target: int) -> None:
    import trimesh, fast_simplification as fs
    m = trimesh.load(str(src), force="mesh")
    if len(m.faces) <= target:
        m.export(str(dst))
        return
    v, f = fs.simplify(m.vertices, m.faces, target_count=target)
    m2 = trimesh.Trimesh(vertices=v, faces=f)
    m2.fix_normals()
    m2.export(str(dst))
    print(f"[worker] decimate {len(m.faces)} -> {len(m2.faces)} 面", flush=True)


def paint(mesh: Path, img: Path, out: Path, tex: int) -> bool:
    """Hunyuan paint 上色。裝不起來就回 False（呼叫端保留素模，不靜默假裝有貼圖）。"""
    try:
        model_dir = ROOT / ".gen3d" / "hunyuan-mini"
        sys.path.insert(0, str(model_dir / "_hy3dgen"))
        import torch
        from hy3dgen.texgen import Hunyuan3DPaintPipeline
        from hy3dgen.texgen.differentiable_renderer.mesh_render import MeshRender
        import trimesh
        pipe = Hunyuan3DPaintPipeline.from_pretrained(str(model_dir / "_paint_weights"))
        pipe.render = MeshRender(default_resolution=tex, texture_size=tex)
        with torch.no_grad():
            r = pipe(trimesh.load(str(mesh), force="mesh"), image=str(img))
        (r[0] if isinstance(r, (list, tuple)) else r).export(str(out))
        print(f"[worker] paint {tex}px 完成", flush=True)
        return True
    except Exception as e:
        print(f"[worker] paint 失敗（保留素模）：{type(e).__name__}: {e}", flush=True)
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--res", type=int, default=512)
    ap.add_argument("--faces", type=int, default=100000)
    ap.add_argument("--tex", type=int, default=1024)
    ap.add_argument("--kind", default="char")
    a = ap.parse_args()

    out = Path(a.out)
    tmp = out.parent / "_tmp"
    tmp.mkdir(parents=True, exist_ok=True)
    stem = out.stem
    prep_png = tmp / f"{stem}_prep.png"
    raw = tmp / f"{stem}_raw.glb"
    dec = tmp / f"{stem}_dec.glb"

    prep(Path(a.image), prep_png)
    if a.model == "trellis2":
        shape_trellis2(prep_png, raw, a.res)
    else:
        shape_hunyuan(prep_png, raw, a.res, full=(a.model == "hunyuan-full"))
    decimate(raw, dec, a.faces)
    if not paint(dec, prep_png, out, a.tex):
        import shutil
        shutil.copy(dec, out)          # 素模也算產出，但上面已明確印出「沒有貼圖」

    if a.kind == "vehicle":
        # 砲塔要能獨立轉向，整台單一網格做不到（GDD/01 §3）
        import subprocess
        vl = ROOT / "godot" / "data" / "vehicle_look.json"
        ty = 0.46
        try:
            import json
            ty = float(json.load(open(vl, encoding="utf-8"))
                       .get(stem, {}).get("turret_y", 0.46))
        except Exception:
            pass
        if ty < 0.98:
            subprocess.run([sys.executable, str(ROOT / "tools" / "split_turret.py"),
                            str(out), str(out.with_name(f"{stem}_hull.glb")),
                            str(out.with_name(f"{stem}_turret.glb")), str(ty)])
    print(f"[worker] DONE -> {out}", flush=True)


if __name__ == "__main__":
    main()
