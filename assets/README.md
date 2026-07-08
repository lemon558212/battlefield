# assets/ — 單位美術素材（選用）

美術採「程式化向量 + 圖片覆蓋」雙軌。**沒有任何圖片時遊戲完全正常**（自動用向量繪製）。

## 放圖規則（想用真實素材時）
放到 `assets/units/`，優先序：
1. `assets/units/{國別}_{兵種}.png` — 該國該兵種專屬（最優先）
2. `assets/units/{兵種}.png` — **兵種共用**（放這 17 張就能覆蓋全部 14 國，最省事）
3. 都沒有 → 程式化向量

- 國別 id：usa uk korea japan taiwan china thailand vietnam ukraine russia iran israel germany france
- 兵種 key：rifleman assault mg mortar sniper at engineer specops tank sam destroyer missileboat lst submarine fighter attacker gunship
- 範例：只放 `tank.png`、`rifleman.png`… 共 17 張，全國通用。

## 圖片要求
- 48×48 透明背景 PNG、俯視、**正面朝右**（引擎依單位面向自動旋轉）

## 已掛載素材（2026-07-08，兵種共用圖）

陸戰兵種與坦克已改用 Kenney CC0 俯視素材（其餘國別/海空維持向量 fallback）：

| 兵種 key | 來源檔（Kenney） | 備註 |
|----------|------------------|------|
| rifleman/assault/mg/mortar/sniper/at/engineer/sam | Topdown Shooter — Soldier 1（軍綠，各姿勢） | 已朝右，直接縮放至 48×48 |
| specops | Topdown Shooter — Hitman 1 silencer（黑衣消音） | 特種識別 |
| tank | Top-down Tanks — tankGreen + barrelGreen 合成 | 原朝上，旋轉 90° 使砲口朝右 |

- 來源包：`kenney.nl/assets/top-down-shooter`、`kenney.nl/assets/top-down-tanks`，授權 **CC0**（免署名可商用）。
- 海空兵種（destroyer/missileboat/lst/submarine/fighter/attacker/gunship）Kenney 無合適俯視素材，維持程式化向量。
- 圖片模式無向量 edge stroke，`sprites.js` 於圖片下方補「側色識別環」（藍=我方/紅=敵方）維持敵我辨識。

## 免費可商用素材來源（CC0）
- Kenney.nl（https://kenney.nl）：Top-down Tanks、Topdown Shooter 等，CC0 免署名可商用（風格化，非照片級）
- OpenGameArt.org 篩 CC0
> 注意：真實「照片級」俯視軍事素材的 CC0 授權極少；多數寫實素材有版權，請確認授權再用。
