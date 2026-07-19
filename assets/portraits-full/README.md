# portraits-full — 曙光特遣隊全身立繪

- 產生方式：OpenAI gpt-image-2（付費 API，使用者帳號），2026-07-19
- 生成腳本與提示詞：`tools/gen-portraits.py`（風格：水彩動漫、現代軍武時尚、單人全身、1024x1536）
- 授權：AI 生成內容，依 OpenAI 服務條款輸出權利歸使用者；無第三方素材
- `sniper-conceptsheet.jpg`：韓沐霜概念設定集版（初版提示詞產物，含表情差分/背面圖，僅作內部參考，
  內有誤植英文名與字樣，禁止直接進遊戲 UI）
- `probe2.bin`：API 探測殘留暫存，可刪
- `<key>_<angry|hurt|smile>.jpg`：表情差分（gpt-image-2 images/edits 以基底立繪編輯，
  腳本 `tools/gen-expressions.py`；首批：sniper/mg/engineer 三名主線角色）
- 載具立繪 8 張（tank/destroyer/missileboat/lst/submarine/fighter/attacker/gunship，1536x1024 橫式，
  gpt-image-2，掛載於 js/data-characters.js 的 VEHICLE_ART，角色卡選中載具時顯示）
- 對應角色：見 `js/data-characters.js` 的 `fullPortrait` 欄位（sniper=韓沐霜、mg=雷諾．佛斯、
  rifleman=丁小滿、assault=艾拉．科瓦奇、at=巴頓．歐克、mortar=賽琳．杜瓦、engineer=白老師、
  sam=汀娜．烏梅、specops=影山靜）
