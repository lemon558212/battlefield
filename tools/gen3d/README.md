# gen3d — 立繪→3D 模型生成（可搬移到別台電腦跑）

## 這是什麼、為什麼存在

把 `godot/assets/portraits/` 的立繪（9 名角色＋8 種載具）生成 3D 模型。

存在理由：使用者有兩台機器，一台 8GB VRAM、一台 **64GB**。
Claude 只能操作「當前對話所在的那一台」，**無法跨機器執行**。
所以把整條管線做成一鍵腳本進版控——在哪台跑都一樣，
腳本自己偵測 VRAM 決定用哪個模型與品質檔位。

## 在 64GB 那台怎麼跑（三行）

```bash
git pull
python tools/gen3d/gen3d.py plan      # 先看它決定用什麼設定（不動手）
python tools/gen3d/gen3d.py setup     # 建 venv、裝相依、抓權重（只需一次，約 30 分）
python tools/gen3d/gen3d.py run       # 生成全部 17 件（可中斷續跑）
```

跑完把成果推回來，另一台就能接進遊戲：

```bash
git add godot/assets/models/gen3d && git commit -m "chore(素材): gen3d 產出" && git push
```

## 檔位對照（腳本自動選，也可 `--profile` 強制）

| VRAM | 檔位 | 形狀模型 | 解析度 | 貼圖 |
|------|------|----------|--------|------|
| ≥40GB | ultra | TRELLIS.2 (4B) | 1536^3 | 2048 |
| ≥22GB | high | TRELLIS.2 (4B) | 1024^3 | 2048 |
| ≥14GB | medium | Hunyuan3D-2 (1.1B) | 512^3 | 2048 |
| <14GB | low | Hunyuan3D-2mini (0.6B) | 512^3 | 1024 |

門檻是**實測**出來的，不是猜的：8GB 上 octree 512＋貼圖 2048 跑四小時未完成、
150k 面配 2048 貼圖直接 CUDA OOM。

## 已知的坑（都踩過，寫下來免得重蹈）

- **Windows 長路徑**：venv 放太深（實測 75 字元）會在裝 open3d 時炸掉。
  腳本固定放在專案根的 `.gen3d/`，不要搬。
- **本機編譯 CUDA 元件會失敗**：VS 2026 + CUDA 12.9 的 `cudafe++` 直接崩潰。
  TRELLIS.2 的 cumesh/flex-gemm/nvdiffrast/o-voxel 一律裝**現成 wheel**
  （`pozzettiandrea.github.io/cuda-wheels`，有 Windows/Linux × cp310~314 × cu124~130）。
- **Blackwell(sm120) 只能 cu128 起跳**：torch cu124 在 5060/5090 上跑不動。
- **立繪的水彩背景會被當成幾何**：不去背直接生成，肩膀旁會長出鬚狀雜物（實拍抓到）。
  `worker.py` 的 `prep()` 一律先去背緊裁。
- **不做靜默降級**：貼圖失敗就明確印出「保留素模」，不可讓人以為已經有貼圖。

## 產出怎麼進遊戲

- 角色：`godot/data/char_look.json` 的 `<兵種>.base` 指到模型路徑，
  跑 `Godot --path godot/ -- lookshots` 驗收（含九人外觀唯一性斷言）。
- 載具：檔名放進 `godot/assets/models/vehicles/`，
  `Unit._try_build_from_art()` 會自動優先採用；沒有才退回程式生成幾何（會大聲印）。
  砲塔要能轉，所以車輛會自動用 `tools/split_turret.py` 依
  `vehicle_look.json` 的 `turret_y` 拆成 `_hull` / `_turret` 兩件。
  驗收：`Godot --path godot/ res://scenes/VehicleProbe.tscn`
  （斷言：碰撞盒不可遠小於幾何、各機種剪影不可雷同）。
