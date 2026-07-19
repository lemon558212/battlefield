# assets/models — 3D 模型（GLB）

| 檔案 | 來源(poly.pizza) | 作者 | 授權 |
|------|------------------|------|------|
| tank.glb | /m/FA5daiyZQq | Quaternius | CC0 |
| soldier.glb | /m/oAArCNHjFB | Quaternius | CC0 |
| destroyer.glb | /m/aYAmfkUYZjg "Simple Battleship" | Thomas de Rivaz | CC-BY 3.0（需署名，已署） |
| submarine.glb | /m/8PgPdFGg3MO | Poly by Google | CC-BY 3.0 |
| fighter.glb | /m/3B3Pa6BHXn1 "Jet" | Poly by Google | CC-BY 3.0 |
| attacker.glb | /m/8VysVKMXN2J "Airplane" | Poly by Google | CC-BY 3.0 |
| gunship.glb | /m/cTzINMr0WdS "Helicopter" | Poly by Google | CC-BY 3.0 |

CC-BY 署名即此檔；引擎（js/engine3d.js loadModels）自動縮放置底＋國別染色；載入失敗回退幾何體組裝。

## 2026-07-17 模型品質閘門

- `rifleman-real-human-final.glb`：通過近距離檢查，可進入正式戰場。
- `*-generated-rigged.glb`：禁止載入。雖然檔案含骨架與八段動畫，但人物表面有破洞、肢體與武器變形，只保留作失敗樣本。
- `quaternius-swat.gltf`：授權為 CC0、結構與動畫完整，但風格明顯偏卡通低模，目前不進入正式戰場。
- 新模型必須先通過同尺寸正面／側面近照、手持武器、走路、射擊及模型缺面檢查，才能加入 `loadModels()`。

## 停用模型（2026-07-11 視覺驗證）

- `fighter.glb` 實際為紅色民用噴射機，並非現代制空戰機。
- `attacker.glb` 實際為橘色雙翼機，並非現代攻擊機。
- 兩檔保留授權與來源紀錄，但 `engine3d.js` 不再載入；遊戲改用可染色的現代軍機 Three.js 組裝模型，之後找到合規 GLB 再替換。
