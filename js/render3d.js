/* ============================================================
 * render3d.js — 行動模式(act)偽 3D 場景渲染（權威：GDD/07 P2）
 * 職責：只在 state==="act" 時，用 Camera3D 把現有 2D 世界(960×600 平面)
 *   繪成第三人稱偽 3D 畫面。指令/部署/敵方回合維持俯視（不經此檔）。
 * 不含任何遊戲規則：可見性沿用 Game.enemyVisible、座標/HP 全用現有欄位。
 *   立繪為 P2 佔位（程式化站姿剪影），P5 再接美術素材。
 * 依賴：Camera3D（投影）、Sprites.colorsFor（配色）、NATIONS、Game（唯讀狀態）。
 * ============================================================ */
"use strict";

const Render3D = {
  SKY_TOP: "#7fb0dc", SKY_HOR: "#d3e3ef",
  GRID: 80,                       // 地面格線間距（世界單位）

  draw(ctx, G){
    const cam = Camera3D, m = G.map;
    cam.applyFor(G);                       // 依狀態選 follow / overview 相機
    const act = (cam.mode === "follow");
    const W = cam.W, H = cam.H;
    const hy = Math.max(0, Math.min(H, cam.horizonY()));

    // 天空：上藍→暖霧三段漸層
    if (hy > 0){
      const sky = ctx.createLinearGradient(0, 0, 0, hy);
      sky.addColorStop(0, "#5f97cf"); sky.addColorStop(0.55, "#9ec2e0"); sky.addColorStop(1, "#ecdfc4");
      ctx.fillStyle = sky; ctx.fillRect(0, 0, W, hy);
      // 太陽光暈（右上）
      const sun = ctx.createRadialGradient(W * 0.74, hy * 0.42, 3, W * 0.74, hy * 0.42, Math.max(80, hy * 1.4));
      sun.addColorStop(0, "rgba(255,246,218,0.6)"); sun.addColorStop(1, "rgba(255,246,218,0)");
      ctx.fillStyle = sun; ctx.fillRect(0, 0, W, hy);
    }
    // 地面底色
    ctx.fillStyle = m.ground || "#7a8f5a"; ctx.fillRect(0, hy, W, H - hy);
    // 地面縱深光影：遠處偏暗、前景落陰（增加立體）
    const gg = ctx.createLinearGradient(0, hy, 0, H);
    gg.addColorStop(0, "rgba(55,62,44,0.30)"); gg.addColorStop(0.28, "rgba(0,0,0,0)"); gg.addColorStop(1, "rgba(0,0,0,0.20)");
    ctx.fillStyle = gg; ctx.fillRect(0, hy, W, H - hy);
    // 地平線暖色大氣霧化
    const fog = ctx.createLinearGradient(0, hy, 0, hy + 120);
    fog.addColorStop(0, "rgba(236,223,196,0.65)"); fog.addColorStop(1, "rgba(236,223,196,0)");
    ctx.fillStyle = fog; ctx.fillRect(0, hy, W, 120);

    // 地面格線（透視縱深提示）
    ctx.strokeStyle = "rgba(255,255,255,0.09)"; ctx.lineWidth = 1;
    for (let x = 0; x <= 960; x += this.GRID) this._seg(ctx, cam, x, 0, x, 600, 0);
    for (let y = 0; y <= 600; y += this.GRID) this._seg(ctx, cam, 0, y, 960, y, 0);

    // 地面貼附裝飾（平面，畫在立體物件之下）
    this._decals(ctx, cam, m);
    // 部署階段：畫出我方部署區（地面藍色虛線框）
    if (G.state === "deploy" && m.deploy){ const z = m.deploy[G.playerSide]; if (z) this._deployZone(ctx, cam, z); }
    if (act && G.sel && G.sel.weapon) this._rangeRing(ctx, cam, G.sel);

    // 立體物件（建築盒 + 單位立繪 + 主堡），依深度由遠到近排序
    const draws = [];
    for (const s of (m.solids || [])){
      const d = cam.depthOf(s.x + s.w / 2, s.y + s.h / 2, 0);
      draws.push({ d, fn: () => this._box(ctx, cam, s) });
    }
    for (const b of (m.bunkers || [])){
      const d = cam.depthOf(b.x + b.w / 2, b.y + b.h / 2, 0);
      draws.push({ d, fn: () => this._bunker(ctx, cam, b) });
    }
    for (const b of m.bases){
      const d = cam.depthOf(b.x, b.y, 0);
      draws.push({ d, fn: () => this._base(ctx, cam, b, G) });
    }
    for (const u of G.units){
      if (!u.alive) continue;
      const isP = u.side === G.playerSide;
      if (!isP && !G.enemyVisible(u)) continue;
      const d = cam.depthOf(u.x, u.y, 0);
      if (d <= cam.nearZ) continue;
      draws.push({ d, fn: () => this._unit(ctx, cam, u, isP, G) });
    }
    draws.sort((a, b) => b.d - a.d);
    for (const it of draws) it.fn();

    // 特效（畫在最上層）
    for (const f of G.fx) this._fx(ctx, cam, f);

    // 邊角壓暗（電影感 vignette）
    const vig = ctx.createRadialGradient(W / 2, H * 0.52, H * 0.42, W / 2, H * 0.52, H * 0.95);
    vig.addColorStop(0, "rgba(0,0,0,0)"); vig.addColorStop(1, "rgba(0,0,0,0.26)");
    ctx.fillStyle = vig; ctx.fillRect(0, 0, W, H);

    // 準心（僅行動模式）
    if (act) this._crosshair(ctx, W, H, hy);
  },

  /* 部署區：地面矩形虛線框 */
  _deployZone(ctx, cam, z){
    const sp = this._projPoly(cam, [[z.x, z.y], [z.x + z.w, z.y], [z.x + z.w, z.y + z.h], [z.x, z.y + z.h]], 0);
    if (!sp) return;
    ctx.strokeStyle = "#2e6fd8"; ctx.setLineDash([8, 6]); ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(sp[0].sx, sp[0].sy);
    for (let i = 1; i < sp.length; i++) ctx.lineTo(sp[i].sx, sp[i].sy);
    ctx.closePath(); ctx.stroke(); ctx.setLineDash([]);
    ctx.fillStyle = "rgba(46,111,216,0.10)"; this._fillPoly(ctx, sp);
  },

  /* 世界線段 → 螢幕，對 nearZ 裁剪（避免相機後方點爆掉） */
  _seg(ctx, cam, ax, ay, bx, by, z){
    let da = cam.depthOf(ax, ay, z), db = cam.depthOf(bx, by, z);
    const n = cam.nearZ + 0.5;
    if (da < n && db < n) return;
    if (da < n){ const t = (n - da) / (db - da); ax += (bx - ax) * t; ay += (by - ay) * t; }
    else if (db < n){ const t = (n - db) / (da - db); bx += (ax - bx) * t; by += (ay - by) * t; }
    const A = cam.project(ax, ay, z), B = cam.project(bx, by, z);
    if (!A || !B) return;
    ctx.beginPath(); ctx.moveTo(A.sx, A.sy); ctx.lineTo(B.sx, B.sy); ctx.stroke();
  },

  /* 投影多邊形（所有角需在前方，否則回 null） */
  _projPoly(cam, pts, z){
    const out = [];
    for (const p of pts){ const s = cam.project(p[0], p[1], z); if (!s) return null; out.push(s); }
    return out;
  },
  _fillPoly(ctx, sp){
    ctx.beginPath(); ctx.moveTo(sp[0].sx, sp[0].sy);
    for (let i = 1; i < sp.length; i++) ctx.lineTo(sp[i].sx, sp[i].sy);
    ctx.closePath(); ctx.fill();
  },

  /* 地面平面裝飾：水域、礁石、樹叢、沙包 */
  _decals(ctx, cam, m){
    const quad = (r, fill) => { const sp = this._projPoly(cam, [[r.x, r.y], [r.x + r.w, r.y], [r.x + r.w, r.y + r.h], [r.x, r.y + r.h]], 0); if (sp){ ctx.fillStyle = fill; this._fillPoly(ctx, sp); } };
    for (const w of (m.deepwaters || [])) quad(w, "#244b66");
    for (const w of (m.waters || [])) quad(w, "#356782");
    for (const w of (m.shallows || [])) quad(w, "#6ea3b8");
    for (const w of (m.reefs || [])) quad(w, "#5a5f52");
    for (const s of (m.sandbags || [])) quad(s, "#a8905c");
    // 工事（地面平面）
    for (const t of (m.trenches || [])){ quad({ x: t.x - 2, y: t.y - 2, w: t.w + 4, h: t.h + 4 }, "#6a5c44"); quad(t, "#332c1f"); }
    for (const w of (m.wires || [])) quad(w, "rgba(45,45,45,0.85)");
    const pit = (h, fill) => { const c = cam.project(h.x, h.y, 0); if (!c) return; ctx.fillStyle = fill; ctx.beginPath(); ctx.ellipse(c.sx, c.sy, h.r * c.scale, h.r * c.scale * 0.5, 0, 0, 7); ctx.fill(); };
    for (const h of (m.craters || [])){ pit(h, "rgba(0,0,0,0.30)"); pit({ x: h.x, y: h.y, r: h.r * 0.7 }, "#4a3d2c"); }
    for (const h of (m.foxholes || [])) pit({ x: h.x, y: h.y, r: h.r }, "#3f3626");
    for (const b of (m.bushes || [])){
      const c = cam.project(b.x, b.y, 0); if (!c) continue;
      ctx.fillStyle = "rgba(47,82,40,0.9)";
      ctx.beginPath(); ctx.ellipse(c.sx, c.sy, b.r * c.scale, b.r * c.scale * 0.5, 0, 0, 7); ctx.fill();
    }
  },

  /* 射程圈：沿地面取樣成環 */
  _rangeRing(ctx, cam, u){
    ctx.strokeStyle = "rgba(255,255,255,0.32)"; ctx.setLineDash([5, 6]); ctx.lineWidth = 1.5;
    ctx.beginPath(); let started = false;
    for (let i = 0; i <= 48; i++){
      const a = i / 48 * Math.PI * 2, x = u.x + Math.cos(a) * u.weapon.range, y = u.y + Math.sin(a) * u.weapon.range;
      if (cam.depthOf(x, y, 0) <= cam.nearZ){ started = false; continue; }
      const s = cam.project(x, y, 0); if (!s){ started = false; continue; }
      if (!started){ ctx.moveTo(s.sx, s.sy); started = true; } else ctx.lineTo(s.sx, s.sy);
    }
    ctx.stroke(); ctx.setLineDash([]);
  },

  /* 建築 → 擠出成 3D 盒 */
  _box(ctx, cam, s){
    const HB = 42; // 建築高度（世界單位）
    const bc = [[s.x, s.y], [s.x + s.w, s.y], [s.x + s.w, s.y + s.h], [s.x, s.y + s.h]];
    const bot = this._projPoly(cam, bc, 0), top = this._projPoly(cam, bc, HB);
    if (!bot || !top) return;
    // 落地陰影
    ctx.fillStyle = "rgba(0,0,0,0.22)"; this._fillPoly(ctx, bot);
    // 四面牆（不透明，畫序由遠到近）
    const wallShade = ["#5c5952", "#666259", "#726d63", "#615d55"];
    const order = [0, 1, 2, 3].sort((i, j) =>
      ((cam.depthOf((bc[(i + 1) % 4][0] + bc[i][0]) / 2, (bc[(i + 1) % 4][1] + bc[i][1]) / 2, 0))) -
      ((cam.depthOf((bc[(j + 1) % 4][0] + bc[j][0]) / 2, (bc[(j + 1) % 4][1] + bc[j][1]) / 2, 0))));
    for (let k = order.length - 1; k >= 0; k--){ const i = order[k], j = (i + 1) % 4;
      ctx.fillStyle = wallShade[i]; this._fillPoly(ctx, [bot[i], bot[j], top[j], top[i]]);
    }
    // 頂面
    ctx.fillStyle = "#7f7a70"; this._fillPoly(ctx, top);
    ctx.strokeStyle = "#403d38"; ctx.lineWidth = 1.5; this._fillPathStroke(ctx, top);
  },
  _fillPathStroke(ctx, sp){ ctx.beginPath(); ctx.moveTo(sp[0].sx, sp[0].sy); for (let i = 1; i < sp.length; i++) ctx.lineTo(sp[i].sx, sp[i].sy); ctx.closePath(); ctx.stroke(); },

  /* 碉堡：低矮混凝土盒 + 射口帶（可進入掩蔽） */
  _bunker(ctx, cam, b){
    const HB = 26;
    const bc = [[b.x, b.y], [b.x + b.w, b.y], [b.x + b.w, b.y + b.h], [b.x, b.y + b.h]];
    const bot = this._projPoly(cam, bc, 0), top = this._projPoly(cam, bc, HB);
    const mid = this._projPoly(cam, bc, HB * 0.5);
    if (!bot || !top) return;
    ctx.fillStyle = "rgba(0,0,0,0.22)"; this._fillPoly(ctx, bot);
    const wall = ["#8a877d", "#949187", "#9c998f", "#807d74"];
    const order = [0, 1, 2, 3].sort((i, j) =>
      cam.depthOf((bc[(i + 1) % 4][0] + bc[i][0]) / 2, (bc[(i + 1) % 4][1] + bc[i][1]) / 2, 0) -
      cam.depthOf((bc[(j + 1) % 4][0] + bc[j][0]) / 2, (bc[(j + 1) % 4][1] + bc[j][1]) / 2, 0));
    for (let k = order.length - 1; k >= 0; k--){ const i = order[k], j = (i + 1) % 4;
      ctx.fillStyle = wall[i]; this._fillPoly(ctx, [bot[i], bot[j], top[j], top[i]]);
      if (mid){ ctx.strokeStyle = "#2a2723"; ctx.lineWidth = 3; this._line(ctx, mid[i].sx, mid[i].sy, mid[j].sx, mid[j].sy); } // 射口帶
    }
    ctx.fillStyle = "#a6a399"; this._fillPoly(ctx, top);
    ctx.strokeStyle = "#4a473f"; ctx.lineWidth = 1.5; this._fillPathStroke(ctx, top);
  },

  /* 主堡：地面圓 + 旗桿 */
  _base(ctx, cam, b, G){
    const g = cam.project(b.x, b.y, 0), topf = cam.project(b.x, b.y, 40);
    if (!g) return;
    const col = b.side === G.playerSide ? "#2e6fd8" : "#c23b22";
    ctx.fillStyle = col; ctx.globalAlpha = 0.5;
    ctx.beginPath(); ctx.ellipse(g.sx, g.sy, 16 * g.scale, 16 * g.scale * 0.5, 0, 0, 7); ctx.fill(); ctx.globalAlpha = 1;
    if (topf){ ctx.strokeStyle = "#cfcfcf"; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(g.sx, g.sy); ctx.lineTo(topf.sx, topf.sy); ctx.stroke();
      ctx.fillStyle = col; ctx.beginPath(); ctx.moveTo(topf.sx, topf.sy); ctx.lineTo(topf.sx + 18 * g.scale, topf.sy + 4 * g.scale); ctx.lineTo(topf.sx, topf.sy + 9 * g.scale); ctx.fill(); }
  },

  /* 單位 billboard（面向相機的站姿剪影，P2 佔位；P5 換立繪） */
  _unit(ctx, cam, u, isP, G){
    const air = u.domain === "air" ? 52 : 0;
    const ground = cam.project(u.x, u.y, 0);
    const baseA = cam.project(u.x, u.y, air);
    const figH = u.cls === "tank" ? 16 : u.domain === "sea" ? 12 : u.domain === "air" ? 11 : 21;
    const topA = cam.project(u.x, u.y, air + figH);
    if (!baseA || !topA) return;
    const h = Math.max(7, baseA.sy - topA.sy), sc = baseA.scale;
    const c = Sprites.colorsFor(u), edge = isP ? "#5b9bff" : "#ff6f5a";

    // 地面陰影（空中單位陰影在正下方地面）
    if (ground){ ctx.fillStyle = "rgba(0,0,0,0.28)"; ctx.beginPath(); ctx.ellipse(ground.sx, ground.sy, u.r * ground.scale, u.r * ground.scale * 0.45, 0, 0, 7); ctx.fill();
      if (air && baseA){ ctx.strokeStyle = "rgba(0,0,0,0.25)"; ctx.lineWidth = 1; ctx.beginPath(); ctx.moveTo(ground.sx, ground.sy); ctx.lineTo(baseA.sx, baseA.sy); ctx.stroke(); } }

    // 視角：由「單位面向 vs 相機看向」決定 前/後/側（自機相機在其後 → 顯示背面）
    let rel = (((u.facing - cam.yaw) % (2 * Math.PI)) + 3 * Math.PI) % (2 * Math.PI) - Math.PI; // [-π,π]
    const va = Math.abs(rel);
    const view = va < Math.PI * 0.4 ? "back" : va > Math.PI * 0.6 ? "front" : "side";
    const sside = rel > 0 ? 1 : -1;   // 側面時武器/朝向的左右

    const cx = baseA.sx, by = baseA.sy; // 立繪底部中心
    ctx.save();
    if (u.cls === "tank") this._bbTank(ctx, cx, by, h, c, edge, view, sside);
    else if (u.domain === "sea") this._bbShip(ctx, cx, by, h, c, edge);
    else if (u.domain === "air") this._bbAir(ctx, cx, by, h, c, edge);
    else this._bbSoldier(ctx, cx, by, h, c, edge, u, view, sside);
    ctx.restore();

    // 血條（立繪頂上）
    const bw = Math.max(14, (u.cls === "tank" ? 30 : 20) * sc * 0.5), bx = cx - bw / 2, y0 = topA.sy - 6;
    ctx.fillStyle = "#222"; ctx.fillRect(bx, y0, bw, 3);
    ctx.fillStyle = u.hp > u.maxhp * 0.3 ? "#4fd05e" : "#e04b3a"; ctx.fillRect(bx, y0, bw * Math.max(0, Math.min(1, u.hp / u.maxhp)), 3);
    if (G.sel === u){ ctx.strokeStyle = "#ffd83d"; ctx.lineWidth = 2; ctx.strokeRect(bx - 1, y0 - 1, bw + 2, 5); }
    // 選中/瞄準標記
    if (G.aimTarget === u && ground){ ctx.strokeStyle = "#ff5a4a"; ctx.lineWidth = 2; ctx.beginPath(); ctx.arc(cx, (topA.sy + by) / 2, h * 0.6, 0, 7); ctx.stroke(); }
  },

  /* 士兵立繪：依 view(front/back/side) 畫向，自機在相機後方 → back */
  _bbSoldier(ctx, cx, by, h, c, edge, u, view, sside){
    const w = h * 0.44, dir = sside || 1;
    const skin = "#d9b48a";
    // 腿
    ctx.fillStyle = c.dark;
    ctx.fillRect(cx - w * 0.30, by - h * 0.40, w * 0.22, h * 0.40);
    ctx.fillRect(cx + w * 0.08, by - h * 0.40, w * 0.22, h * 0.40);
    // 身體（軀幹）
    ctx.fillStyle = c.uniform; ctx.strokeStyle = edge; ctx.lineWidth = 1.4;
    const bodyW = view === "side" ? w * 0.66 : w;
    this._roundRect(ctx, cx - bodyW / 2, by - h * 0.80, bodyW, h * 0.44, bodyW * 0.24); ctx.fill(); ctx.stroke();
    // 軀幹亮面（立體感）
    ctx.fillStyle = "rgba(255,255,255,0.10)"; ctx.fillRect(cx - bodyW / 2, by - h * 0.80, bodyW, h * 0.14);

    const gunL = (u.cls === "sniper" || u.cls === "at" || u.cls === "mg") ? w * 1.05 : w * 0.75;
    const gunW = (u.cls === "mg" || u.cls === "at") ? 3 : 2;
    ctx.lineCap = "round";

    if (view === "back"){
      // 背包 + 背帶（背面辨識）
      ctx.fillStyle = c.dark; this._roundRect(ctx, cx - bodyW * 0.32, by - h * 0.74, bodyW * 0.64, h * 0.30, 2); ctx.fill();
      ctx.strokeStyle = "rgba(0,0,0,0.4)"; ctx.lineWidth = 1.4;
      this._line(ctx, cx - bodyW * 0.22, by - h * 0.80, cx - bodyW * 0.22, by - h * 0.44);
      this._line(ctx, cx + bodyW * 0.22, by - h * 0.80, cx + bodyW * 0.22, by - h * 0.44);
      // 槍口從肩側微露
      ctx.strokeStyle = c.metal; ctx.lineWidth = gunW;
      this._line(ctx, cx + bodyW * 0.4, by - h * 0.66, cx + bodyW * 0.4, by - h * 0.30);
    } else if (view === "front"){
      // 胸前裝備 + 武器橫持
      ctx.strokeStyle = "rgba(0,0,0,0.35)"; ctx.lineWidth = 1.4;
      this._line(ctx, cx - bodyW * 0.22, by - h * 0.78, cx + bodyW * 0.22, by - h * 0.50);
      ctx.strokeStyle = c.metal; ctx.lineWidth = gunW;
      this._line(ctx, cx - w * 0.5, by - h * 0.52, cx + w * 0.2, by - h * 0.60);
    } else {
      // 側面：武器朝 dir
      ctx.strokeStyle = c.metal; ctx.lineWidth = gunW;
      this._line(ctx, cx, by - h * 0.54, cx + dir * gunL, by - h * 0.56);
    }

    // 頭 + 頭盔
    const hy = by - h * 0.86;
    if (view !== "back"){ ctx.fillStyle = skin; ctx.beginPath(); ctx.arc(cx + (view === "side" ? dir * h * 0.03 : 0), hy + h * 0.03, h * 0.10, 0, 7); ctx.fill(); }
    ctx.fillStyle = c.dark; ctx.beginPath(); ctx.arc(cx, hy, h * 0.12, Math.PI, 0); ctx.fill();      // 頭盔罩
    ctx.fillRect(cx - h * 0.12, hy, h * 0.24, h * 0.03);                                              // 帽簷
    ctx.fillStyle = c.accent; ctx.fillRect(cx - h * 0.05, hy - h * 0.03, h * 0.10, h * 0.03);         // 兵種色標

    // 兵種字（在頭上方）
    ctx.fillStyle = "#fff"; ctx.font = "bold " + Math.max(8, h * 0.2).toFixed(0) + "px sans-serif"; ctx.textAlign = "center";
    const L = { rifleman: "步", assault: "突", mg: "機", mortar: "迫", sniper: "狙", at: "火", engineer: "工", specops: "特", sam: "防" }[u.cls] || "";
    if (h > 26) ctx.fillText(L, cx, by - h * 1.02);   // 夠大才標字，避免遠處雜亂
  },

  /* 坦克立繪：依 view 畫車體與砲管朝向 */
  _bbTank(ctx, cx, by, h, c, edge, view, sside){
    const w = h * 2.0, dir = sside || 1;
    ctx.strokeStyle = edge; ctx.lineWidth = 1.5;
    // 履帶
    ctx.fillStyle = c.dark; ctx.fillRect(cx - w / 2, by - h * 0.52, w, h * 0.52);
    ctx.fillStyle = "#1c1f19"; for (let gx = -w / 2; gx < w / 2; gx += w * 0.12) ctx.fillRect(cx + gx, by - h * 0.52, w * 0.05, h * 0.52);
    // 車體
    ctx.fillStyle = c.uniform; this._roundRect(ctx, cx - w * 0.46, by - h * 0.86, w * 0.92, h * 0.42, 3); ctx.fill(); ctx.stroke();
    ctx.fillStyle = "rgba(255,255,255,0.10)"; ctx.fillRect(cx - w * 0.46, by - h * 0.86, w * 0.92, h * 0.12);
    // 砲塔
    ctx.fillStyle = c.metal; ctx.beginPath(); ctx.arc(cx, by - h * 0.86, h * 0.34, 0, 7); ctx.fill();
    ctx.strokeStyle = c.metal; ctx.lineWidth = 3.5;
    if (view === "back"){
      // 尾部：排氣柵 + 無砲管朝前（砲管朝遠方，僅露短段）
      ctx.fillStyle = "#3a3f36"; ctx.fillRect(cx - w * 0.3, by - h * 0.56, w * 0.6, h * 0.10);
      ctx.strokeStyle = c.metal; ctx.beginPath(); ctx.moveTo(cx, by - h * 0.92); ctx.lineTo(cx, by - h * 1.02); ctx.stroke();
    } else if (view === "front"){
      // 車頭：頭燈 + 砲管朝觀者（短）
      ctx.beginPath(); ctx.moveTo(cx, by - h * 0.90); ctx.lineTo(cx, by - h * 1.05); ctx.stroke();
      ctx.fillStyle = "#e8e0a0"; ctx.beginPath(); ctx.arc(cx - w * 0.34, by - h * 0.5, h * 0.06, 0, 7); ctx.arc(cx + w * 0.34, by - h * 0.5, h * 0.06, 0, 7); ctx.fill();
    } else {
      // 側面：砲管朝 dir
      ctx.beginPath(); ctx.moveTo(cx, by - h * 0.92); ctx.lineTo(cx + dir * w * 0.5, by - h * 0.96); ctx.stroke();
    }
    ctx.fillStyle = "#e8c06a"; ctx.fillRect(cx - w * 0.42, by - h * 0.44, h * 0.14, h * 0.14); // 弱點
  },

  _bbShip(ctx, cx, by, h, c, edge){
    const w = h * 2.6;
    ctx.fillStyle = c.steel; ctx.strokeStyle = edge; ctx.lineWidth = 1.4;
    ctx.beginPath(); ctx.moveTo(cx - w / 2, by - h * 0.4); ctx.lineTo(cx + w / 2, by - h * 0.4); ctx.lineTo(cx + w * 0.36, by); ctx.lineTo(cx - w * 0.42, by); ctx.closePath(); ctx.fill(); ctx.stroke();
    ctx.fillStyle = c.dark; ctx.fillRect(cx - w * 0.12, by - h * 0.9, w * 0.24, h * 0.5);
  },

  _bbAir(ctx, cx, by, h, c, edge){
    const w = h * 2.2;
    ctx.fillStyle = c.steel; ctx.strokeStyle = edge; ctx.lineWidth = 1.4;
    ctx.beginPath(); ctx.ellipse(cx, by - h * 0.5, w * 0.16, h * 0.5, 0, 0, 7); ctx.fill(); ctx.stroke();
    ctx.fillStyle = c.uniform; ctx.beginPath(); ctx.moveTo(cx - w / 2, by - h * 0.5); ctx.lineTo(cx + w / 2, by - h * 0.5); ctx.lineTo(cx, by - h * 0.75); ctx.closePath(); ctx.fill();
  },

  _roundRect(ctx, x, y, w, h, r){ ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r); ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath(); },
  _line(ctx, x1, y1, x2, y2){ ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke(); },

  /* 特效投影（tracer/boom/hitfx/death） */
  _fx(ctx, cam, f){
    if (f.type === "tracer"){
      const A = cam.project(f.x1, f.y1, 6), B = cam.project(f.x2, f.y2, 6); if (!A || !B) return;
      const k = 1 - f.t / 0.25; ctx.strokeStyle = (f.hit ? "rgba(255,225,120," : "rgba(210,210,210,") + k.toFixed(2) + ")"; ctx.lineWidth = 2;
      ctx.beginPath(); ctx.moveTo(A.sx, A.sy); ctx.lineTo(B.sx, B.sy); ctx.stroke();
    } else if (f.type === "boom"){
      const s = cam.project(f.x, f.y, 6); if (!s) return; const k = f.t / 0.5;
      ctx.fillStyle = "rgba(255,120,40," + ((1 - k) * 0.75).toFixed(2) + ")"; ctx.beginPath(); ctx.arc(s.sx, s.sy, f.r * (0.5 + k * 0.5) * s.scale, 0, 7); ctx.fill();
      ctx.fillStyle = "rgba(255,235,150," + (1 - k).toFixed(2) + ")"; ctx.beginPath(); ctx.arc(s.sx, s.sy, f.r * 0.3 * (1 - k) * s.scale, 0, 7); ctx.fill();
    } else if (f.type === "hitfx"){
      const s = cam.project(f.x, f.y, 14); if (!s) return;
      ctx.fillStyle = f.heal ? "#5eff8a" : "#ffe08a"; ctx.font = "bold 13px sans-serif"; ctx.textAlign = "center";
      ctx.globalAlpha = 1 - f.t / 0.9; ctx.fillText(f.heal ? f.dmg : "-" + f.dmg, s.sx, s.sy - f.t * 22); ctx.globalAlpha = 1;
    }
  },

  /* 畫面中央準心（瞄準用，P3 接開火） */
  _crosshair(ctx, W, H, hy){
    const cx = W / 2, cy = (hy + H) / 2 - 30;
    ctx.strokeStyle = "rgba(255,255,255,0.6)"; ctx.lineWidth = 1.5;
    ctx.beginPath(); ctx.moveTo(cx - 10, cy); ctx.lineTo(cx - 3, cy); ctx.moveTo(cx + 3, cy); ctx.lineTo(cx + 10, cy);
    ctx.moveTo(cx, cy - 10); ctx.lineTo(cx, cy - 3); ctx.moveTo(cx, cy + 3); ctx.lineTo(cx, cy + 10); ctx.stroke();
    ctx.beginPath(); ctx.arc(cx, cy, 1.5, 0, 7); ctx.fillStyle = "rgba(255,255,255,0.6)"; ctx.fill();
  }
};
