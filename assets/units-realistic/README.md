# 寫實召喚單位

- 來源：`assets/art-direction/land-roster-concept-v1.png` 與 `sea-air-roster-concept-v1.png`。
- 產生方式：依 GDD/06 格位裁切，以格位邊界連通的中性背景建立軟 Alpha，再裁去透明外框。
- 檔名：`{兵種key}.png`，共 17 檔；部署卡與戰場 Sprite 對應同一原始格位。
- 用途：Engine3D 寫實 2.5D Sprite，以及 WebGL 不可用時的 Render3D 立繪。
- 直接雙擊支援：`generate-data-module.js` 把 17 張 PNG 原封不動轉成 `js/data-unit-art.js` 的 data URI，避免 `file://` 本機圖片無法上傳 WebGL；這不是另一套美術。
- PNG 更新後執行 `node assets/units-realistic/generate-data-module.js`，再以檔案 SHA-256 與內嵌模組核對一致性。
- 這些 PNG 是去背點陣外觀，不是完整可繞背觀看的 GLB 模型。

重新產生時不得覆蓋原始 `art-direction` 圖集；先視覺驗證武器、天線、砲管、旋翼與艦桅邊緣，再更新本目錄。
