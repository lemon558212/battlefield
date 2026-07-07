/* ============================================================
 * sprites.js — 程式化向量美術 + 圖片覆蓋機制（權威：GDD/06）
 * 雙軌：assets/units/{nation}_{cls}.png 存在則用圖，否則向量 fallback
 * 所有 draw* 在「已 translate 到單位中心、已 rotate 到 facing」的座標系，+x = 正面
 * ============================================================ */
"use strict";

function _srand(seed){ let s = seed % 2147483647; if (s <= 0) s += 2147483646; return () => (s = s * 16807 % 2147483647) / 2147483647; }

const Sprites = {
  imgCache: {},   // key "{nation}_{cls}" -> HTMLImageElement | false

  colorsFor(u){
    const n = NATIONS[u.nationId];
    return { uniform: n.uniformColor, accent: n.flagColors[1] || "#8a8a8a", metal: "#6d726a", dark: "#23271f", steel: "#8a9099" };
  },

  /* 選擇性預載圖片；沒有圖也完全不影響（fallback 向量） */
  tryLoad(u){
    const key = u.nationId + "_" + u.cls;
    if (key in this.imgCache) return this.imgCache[key];
    const img = new Image();
    img.onload = () => { this.imgCache[key] = img; };
    img.onerror = () => { this.imgCache[key] = false; };
    img.src = "assets/units/" + key + ".png";
    this.imgCache[key] = false; // 先設 false，載入成功後 onload 覆蓋
    return false;
  },

  drawBody(ctx, u, isPlayer){
    const edge = isPlayer ? "#7db4ff" : "#ff9d8a";
    // 空中單位：先在地面畫投影
    if (u.domain === "air"){
      ctx.save(); ctx.globalAlpha = 0.22; ctx.fillStyle = "#000";
      ctx.beginPath(); ctx.ellipse(u.x + 7, u.y + 12, u.r, u.r * 0.5, 0, 0, 7); ctx.fill(); ctx.restore();
    }
    const img = this.imgCache[u.nationId + "_" + u.cls];
    ctx.save(); ctx.translate(u.x, u.y); ctx.rotate(u.facing);
    if (img){ ctx.drawImage(img, -u.r - 4, -u.r - 4, (u.r + 4) * 2, (u.r + 4) * 2); ctx.restore(); return; }
    if (u.domain === "sea") this.drawShip(ctx, u, edge);
    else if (u.domain === "air") this.drawAir(ctx, u, edge);
    else if (u.cls === "tank") this.drawTank(ctx, u, edge);
    else this.drawSoldier(ctx, u, edge);
    ctx.restore();
  },

  drawSoldier(ctx, u, edge){
    const c = this.colorsFor(u), R = u.r;
    // 身體
    ctx.fillStyle = c.uniform; ctx.strokeStyle = edge; ctx.lineWidth = 1.5;
    ctx.beginPath(); ctx.ellipse(0, 0, R, R * 0.82, 0, 0, 7); ctx.fill(); ctx.stroke();
    // 迷彩斑塊（以 id 為種子固定）
    const rnd = _srand(u.id + 7); ctx.fillStyle = c.dark;
    for (let i = 0; i < 3; i++){ const a = rnd() * 7, rr = rnd() * R * 0.5; ctx.beginPath(); ctx.arc(Math.cos(a) * rr, Math.sin(a) * rr, R * 0.3, 0, 7); ctx.fill(); }
    // 武器（依兵種造型，朝 +x）
    ctx.strokeStyle = c.metal; ctx.lineCap = "round";
    switch (u.cls){
      case "mg":      ctx.lineWidth = 3.5; this._line(ctx, 2, 0, R + 8, 0); ctx.lineWidth = 2; this._line(ctx, R + 3, -4, R + 3, 4); break; // 粗管+兩腳架
      case "sniper":  ctx.lineWidth = 2;   this._line(ctx, 2, 0, R + 12, 0); ctx.fillStyle = "#bfe3ff"; ctx.beginPath(); ctx.arc(R + 12, 0, 1.6, 0, 7); ctx.fill(); break; // 長管+鏡反光
      case "at":      ctx.lineWidth = 4;   this._line(ctx, -2, -2, R + 9, -2); break; // 肩扛粗筒
      case "mortar":  ctx.lineWidth = 3;   this._line(ctx, -4, 2, 4, -R - 4); break; // 背斜砲管
      case "sam":     ctx.fillStyle = c.steel; ctx.fillRect(-R * 0.5, -R - 3, R, 5); break; // 背飛彈發射箱
      case "engineer":ctx.fillStyle = "#7a6a3a"; ctx.fillRect(-R - 2, -3, 5, 6); ctx.strokeStyle = c.metal; ctx.lineWidth = 2; this._line(ctx, 2, 0, R + 5, 0); break; // 背工具包
      case "specops": ctx.lineWidth = 2;   this._line(ctx, 2, 0, R + 10, 0); ctx.lineWidth = 3; this._line(ctx, R + 7, 0, R + 11, 0); break; // 消音長管
      default:        ctx.lineWidth = 2.5; this._line(ctx, 2, 0, R + 7, 0); // rifleman/assault 標準步槍
    }
    // 頭盔 + 兵種識別色
    ctx.fillStyle = c.dark; ctx.beginPath(); ctx.arc(1, 0, R * 0.5, 0, 7); ctx.fill();
    ctx.fillStyle = c.accent; ctx.beginPath(); ctx.arc(1, 0, R * 0.26, 0, 7); ctx.fill();
    // 兵種字（維持可讀性）
    ctx.rotate(-u.facing); ctx.fillStyle = "#fff"; ctx.font = "8px sans-serif"; ctx.textAlign = "center";
    const L = { rifleman:"步", assault:"突", mg:"機", mortar:"迫", sniper:"狙", at:"火", engineer:"工", specops:"特", sam:"防" }[u.cls] || "";
    ctx.fillText(L, 0, R + 9);
  },

  drawTank(ctx, u, edge){
    const c = this.colorsFor(u);
    ctx.fillStyle = c.uniform; ctx.strokeStyle = edge; ctx.lineWidth = 1.5;
    ctx.fillRect(-16, -11, 32, 22); ctx.strokeRect(-16, -11, 32, 22);
    ctx.fillStyle = c.dark; ctx.fillRect(-16, -12, 32, 3); ctx.fillRect(-16, 9, 32, 3); // 履帶
    ctx.fillStyle = c.metal; ctx.beginPath(); ctx.arc(0, 0, 8, 0, 7); ctx.fill();       // 砲塔
    ctx.lineWidth = 4; ctx.strokeStyle = c.metal; this._line(ctx, 0, 0, 26, 0);          // 砲管
    ctx.fillStyle = "#e8c06a"; ctx.fillRect(-15, 5, 5, 5);                                // 散熱器弱點
  },

  drawShip(ctx, u, edge){
    const c = this.colorsFor(u);
    ctx.strokeStyle = edge; ctx.lineWidth = 1.5;
    if (u.cls === "submarine"){
      ctx.fillStyle = "#3a4550"; ctx.globalAlpha = 0.9;
      ctx.beginPath(); ctx.ellipse(0, 0, 20, 7, 0, 0, 7); ctx.fill(); ctx.stroke(); ctx.globalAlpha = 1;
      ctx.fillStyle = c.dark; ctx.fillRect(-3, -10, 6, 8); // 帆罩/潛望鏡
      return;
    }
    const len = u.cls === "destroyer" ? 44 : u.cls === "lst" ? 40 : 26;
    const wid = u.cls === "lst" ? 15 : u.cls === "destroyer" ? 12 : 8;
    ctx.fillStyle = c.steel;                                  // 船體梭形
    ctx.beginPath(); ctx.moveTo(len * 0.6, 0); ctx.lineTo(len * 0.2, -wid); ctx.lineTo(-len * 0.5, -wid);
    ctx.lineTo(-len * 0.5, wid); ctx.lineTo(len * 0.2, wid); ctx.closePath(); ctx.fill(); ctx.stroke();
    ctx.fillStyle = c.dark; ctx.fillRect(-len * 0.15, -wid * 0.6, len * 0.3, wid * 1.2); // 艦橋
    if (u.cls === "destroyer"){ ctx.fillStyle = c.metal; ctx.lineWidth = 3; ctx.strokeStyle = c.metal; this._line(ctx, len * 0.3, 0, len * 0.6 + 6, 0); } // 主砲
    if (u.cls === "missileboat"){ ctx.fillStyle = "#b05030"; ctx.fillRect(-4, -wid, 8, 4); }  // 飛彈箱
    if (u.cls === "lst"){ ctx.fillStyle = "#4a3f2a"; ctx.fillRect(len * 0.5 - 3, -wid * 0.7, 4, wid * 1.4); } // 艙門
    ctx.fillStyle = c.accent; ctx.fillRect(-len * 0.45, -2, 4, 4);  // 國籍色
  },

  drawAir(ctx, u, edge){
    const c = this.colorsFor(u);
    ctx.fillStyle = c.steel; ctx.strokeStyle = edge; ctx.lineWidth = 1.5;
    if (u.cls === "gunship"){ // 直升機：機身 + 旋翼圓
      ctx.fillStyle = c.dark; ctx.beginPath(); ctx.ellipse(0, 0, 13, 6, 0, 0, 7); ctx.fill(); ctx.stroke();
      this._line(ctx, -13, 0, -22, 0); // 尾樑
      ctx.strokeStyle = "rgba(220,230,240,0.5)"; ctx.lineWidth = 1.5;
      this._line(ctx, -16, -16, 16, 16); this._line(ctx, -16, 16, 16, -16); // 旋翼
      return;
    }
    // 固定翼：機身 + 後掠翼三角
    const sharp = u.cls === "fighter";
    ctx.beginPath(); ctx.moveTo(16, 0); ctx.lineTo(sharp ? 2 : 4, -4); ctx.lineTo(-12, -4); ctx.lineTo(-14, 0);
    ctx.lineTo(-12, 4); ctx.lineTo(sharp ? 2 : 4, 4); ctx.closePath(); ctx.fill(); ctx.stroke();
    ctx.fillStyle = c.uniform; // 後掠翼
    ctx.beginPath(); ctx.moveTo(sharp ? 0 : 2, 0); ctx.lineTo(-14, -14); ctx.lineTo(-10, -14);
    ctx.lineTo(4, -2); ctx.lineTo(4, 2); ctx.lineTo(-10, 14); ctx.lineTo(-14, 14); ctx.closePath(); ctx.fill();
    if (u.cls === "attacker"){ ctx.fillStyle = "#b05030"; ctx.fillRect(-6, -6, 3, 3); ctx.fillRect(-6, 3, 3, 3); } // 掛彈
  },

  _line(ctx, x1, y1, x2, y2){ ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke(); }
};
