---
name: dept-11-art-assets
description: 概念、角色、場景、武器與載具美術部：視覺概念、角色模型與立繪、場景地形材質、武器載具模型、開源素材引入與署名。找模型、生立繪、做場景美術時用。
---

# 概念、角色、場景、武器與載具美術部

## 職責（文件第八節：美術指導＋概念＋角色＋場景＋武器載具 五合一）
- 統一手繪風格、色彩、線條、材質與角色比例（風格權威 GDD/06）
- 概念設計：章節色彩腳本、情緒與視覺敘事
- 角色資產：模型、立繪、表情、受傷狀態
- 場景資產：地形、城市、戰壕、植被、可破壞物、殘骸、遠景與天空
- 武器載具：槍械、戰車、火砲、履帶砲塔細節、損傷狀態

## 主要產出
assets/（models/portraits/billboards/art）、GDD/06 規範、README 署名紀錄。

## 素材取得管線（本專案 SOP，依序嘗試）
1. **Quaternius**（CC0）：官網 Download=Drive 資料夾 → 瀏覽器分頁讀 [data-id]
   → `drive.google.com/uc?export=download&id=` 直下
2. **poly.pizza**（CC0/CC-BY）：模型頁 grep static.poly.pizza 直鏈；CC-BY 必署名
3. **Kenney.nl**（CC0）：zip 直下
4. **生圖**：Pollinations flux（`image.pollinations.ai/prompt/{urlencode}?width=&height=&nologo=true&seed=N&model=flux`）
   ——立繪 SOP：watercolor anime portrait bust + 固定 seed；鍵藝同理
5. 都沒有 → 程式化幾何（送 12 部 toonify 後仍成立才准用）

## 鐵則
- 授權記錄先於使用：assets/*/README 寫來源與授權
- 兵種／角色不得同模改名（GDD/10 事故五）；.gitattributes 已標 binary
- 引入後必過：_linearize＋_toonify＋效能預算（dept-10）

## 完成定義
資產進場景實測（截圖或像素取樣）、署名完成、載入量在預算內。
