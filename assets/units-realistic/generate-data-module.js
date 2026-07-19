/*
 * 將 17 張已去背 PNG 機械式打包成瀏覽器可直接開啟的 data URI 模組。
 * 執行：node assets/units-realistic/generate-data-module.js
 * 產物：js/data-unit-art.js（遊戲執行時直接載入，不需要 Node）
 */
"use strict";

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const classes = [
  "rifleman", "assault", "mg", "mortar", "sniper", "at", "engineer", "specops", "tank", "sam",
  "destroyer", "missileboat", "lst", "submarine", "fighter", "attacker", "gunship"
];
const root = __dirname;
const output = path.resolve(root, "../../js/data-unit-art.js");
const data = {};
const hashes = {};

for (const cls of classes){
  const file = path.join(root, `${cls}.png`);
  const bytes = fs.readFileSync(file);
  data[cls] = `data:image/png;base64,${bytes.toString("base64")}`;
  hashes[cls] = crypto.createHash("sha256").update(bytes).digest("hex");
}

const header = `/* ============================================================\n` +
  ` * data-unit-art.js — 由 assets/units-realistic/*.png 機械式生成。\n` +
  ` * 目的：file:// 直接開啟時仍能把來源安全的寫實圖片上傳 WebGL。\n` +
  ` * 請勿手改 base64；修改 PNG 後重跑 generate-data-module.js。\n` +
  ` * ============================================================ */\n` +
  `"use strict";\n\n`;
const body = `const UNIT_ART_DATA = Object.freeze(${JSON.stringify(data, null, 2)});\n` +
  `const UNIT_ART_SHA256 = Object.freeze(${JSON.stringify(hashes, null, 2)});\n`;

fs.writeFileSync(output, header + body, "utf8");
console.log(`Generated ${path.relative(process.cwd(), output)} with ${classes.length} PNG files.`);
