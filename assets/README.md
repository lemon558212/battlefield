# assets/ — 單位美術素材（選用）

本遊戲美術採「程式化向量 + 圖片覆蓋」雙軌（規格見 `GDD/06-美術規格.md`）。
**沒有任何圖片時遊戲完全正常運作**（自動用程式化向量繪製）。

## 放圖規則（想用真實軍種美術時）

把 PNG 放到 `assets/units/`，檔名格式：

```
{國家id}_{兵種key}.png
```

- 國家 id：usa / uk / korea / japan / taiwan / china / thailand / vietnam / ukraine / russia / iran / israel / germany / france
- 兵種 key：rifleman assault mg mortar sniper at engineer specops tank sam destroyer missileboat lst submarine fighter attacker gunship
- 範例：`usa_tank.png`、`japan_fighter.png`、`taiwan_destroyer.png`

## 圖片要求

- 48×48 像素、透明背景（PNG）
- 俯視角、**正面朝右**（引擎會依單位面向自動旋轉）
- 只要放了對應檔名，引擎下次載入該單位時就會自動改用圖片；缺圖的單位仍用向量繪製。

## 版權提醒

真實軍種照片多有版權，請自備授權素材或自繪。本專案預設不附任何圖片。
