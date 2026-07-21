# GDD/13 Godot 4 遷移計畫（2026-07-21 使用者裁定立案）

> 裁定原文：「不管是距離感或是實際的任何動作還有姿態還是不太行，建議改你說的引擎試試看」。
> 本文件＝遷移的唯一權威。HTML5 版凍結維護（不再加功能，僅修致命 bug），保留部署當對照組。

## 為什麼是 Godot 4

| 面向 | 說明 |
|------|------|
| 動畫 | AnimationTree 狀態機＋blend＋root motion 原生支援——正是本作三輪修不好的痛點 |
| 授權 | MIT 免費，商業發售零抽成（使用者目標：做成遊戲軟體發售） |
| 平台 | 一鍵匯出 Windows/mac/Linux/Android/iOS/Web（Steam 可上） |
| 工程型態 | 專案全文字檔（.tscn/.gd/.tres）＝AI 可直接撰寫與 diff；.glb 原生匯入 |
| 對照 | Unity（收費政策風險/工程二進位多）、Unreal（規模殺雞用牛刀、C++ 門檻）不選 |

## 資產與內容的去留

**全部帶走（引擎中立）**：
- `godot/data/*.json`：nations/class_base/weapons/maps/story/characters/vehicle_unlock/terrain_mobility（2026-07-21 已自 js 導出）
- 立繪：assets/portraits-cut/（透明 PNG 45 張）＋ portraits-full 原圖
- 3D 模型：assets/models/**/*.glb（Godot 原生匯入；**b64 通道退役**——Godot 桌面版不經瀏覽器下載，防毒攔截問題自然消失）
- 劇本/數值/研究：GDD/、research/ 全部沿用；BGM/音效檔沿用

**重寫（引擎相關）**：
- 渲染（three.js→Godot 場景樹）、相機、輸入、UI（Control 節點重做鳴潮風）、
  戰鬥規則層（combat/fog/ai 由 js 移植 GDScript，邏輯照抄公式不變）

## 分期（每期結束＝可玩可驗收）

- **P0 骨架（本輪）**：godot/ 專案可開啟可執行——地面、戰術相機（平移/縮放/跟隨）、
  自 JSON 生成單位、點地移動＋walk/idle 切換、點敵開槍（aim→shoot→曳光）。
  ＝直接對決三大痛點（動作/姿態/距離感）的最小驗證場。
- **P1 垂直切片**：第 1 章完整可玩（部署→BLiTZ 回合→迷霧→勝敗→對話演出）
- **P2 規則全量**：九兵種+海空、警戒射擊、掩體、章節特規、養成/羈絆/敵將
- **P3 內容**：15 章、UI 全套（鳴潮風 Control 重做）、音訊
- **P4 發佈**：Windows exe＋Web 匯出雙軌，手機觸控
- **P5 商業化**：Steam 頁面、成就、雲存檔（另立專案）

## 風險與對策

1. **雙版本維護** → HTML5 版凍結，只留對照。
2. **GDScript 移植錯誤** → 公式照 GDD/01/02 重驗，關鍵戰鬥數值寫單元測試（GUT 或 assert 場景）。
3. **AI 無頭迭代** → Godot 有 `--headless` CLI：匯入、跑場景、匯出全可指令化；
   截圖驗證用 `--write-movie` 或 viewport texture 存檔，維持「成品級驗收」紀律。
4. **引擎二進位取得** → 需使用者核可下載官方 Godot 4.3 stable win64（zip 免安裝 ~55MB，godotengine.org）。

## 工作模式（AI×Godot）

- 所有場景以 GDScript 程式化建構為主、.tscn 保持極簡（降低手寫場景檔語法風險）
- 驗收一律跑 headless 匯入＋啟動 log＋畫面輸出，證據入回報（延續 2026-07-21 成品級驗收鐵則）
