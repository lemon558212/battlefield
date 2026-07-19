# 美術方向資產

## style-comparison-v1.png

- 日期：2026-07-10
- 用途：真 3D 戰場美術方向比較。
- 生成方式：Codex 內建 imagegen。
- 三欄由左至右：水彩軍事插畫／高品質風格化 3D／半寫實軍事質感。
- 現行決策：中央欄作為戰場 3D 主方向；左欄作為角色卡與宣傳圖方向；右欄只取材質磨損細節。
- 限制：此圖是概念參考，不是可直接載入 Three.js 的 3D 模型。

後續生圖與模型若需要偏離此方向，先更新 `GDD/06-美術規格.md` 取得共識。

## land-roster-concept-v1.png

- 日期：2026-07-10
- 用途：陸軍 10 兵種的正式召喚外觀，以及後續 3D 建模與裝備輪廓參考。
- 生成方式：Codex 內建 imagegen。
- 格位由左至右、由上至下：rifleman、assault、mg、mortar、sniper、at、engineer、specops、sam、tank。
- 驗收重點：即使不看顏色，也能靠武器、背包與大型裝備輪廓辨識兵種。
- 限制：不是可繞背觀看的 GLB；目前由 `engine3d.js` 裁切去背後作為 3D 場景中的 2.5D Sprite，GLB／程序化模型只作 fallback。

## sea-air-roster-concept-v1.png

- 日期：2026-07-10
- 用途：海軍 4 兵種與空軍 3 兵種的正式召喚外觀，以及後續 3D 建模、掛載與輪廓參考。
- 生成方式：Codex 內建 imagegen；以前一張陸軍設定圖作為風格參考。
- 格位上排：destroyer、missileboat、lst、submarine。
- 格位下排：fighter、attacker、gunship、空白。
- 驗收重點：驅逐艦、飛彈快艇與登陸艦必須靠艦體比例和任務裝備直接區分；戰鬥機、攻擊機與武裝直升機必須靠機體與掛載區分。
- 限制：不是可繞背觀看的 GLB；目前以去背 Sprite 顯示，登陸艦與飛彈快艇的程序化 3D 模型保留為載入失敗時的 fallback。

## 召喚同源使用原則（2026-07-11 使用者更正）

- 部署按鈕直接裁切這兩張 roster 圖的對應格位。
- 戰場端優先載入由相同格位產生的 `assets/units-realistic/{兵種}.png`；缺檔時才即時邊緣去背，召喚前後仍使用同一造型。
- 若圖集載入或去背失敗，才回退 GLB／程序化 3D；任何圖片失敗都不得影響文字、部署或戰鬥功能。
