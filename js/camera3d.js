/* ============================================================
 * camera3d.js — 第三人稱偽 3D 相機與投影（權威：GDD/07）
 * 職責：只做「世界座標(960×600 平面) → 螢幕座標」的透視投影。
 *   不含任何遊戲規則；combat/fog/ai/net 一律不經此檔。
 * 座標約定：
 *   世界 (wx,wy) = 現有俯視平面座標（+x 右、+y 下）；wz = 離地高度（向上為正）。
 *   單位 facing 以弧度表示，+x 方向 = facing 0（與 sprites.js 一致）。
 * 相機：置於選中單位「後方偏上」，yaw 對齊單位 facing，pitch 為俯角。
 * 依賴：無（純數學）。被 game.js 於 act 狀態呼叫。
 * ============================================================ */
"use strict";

const Camera3D = {
  // 螢幕（canvas 邏輯尺寸，與 index.html 一致）
  W: 960, H: 600,

  // 兩種相機模式的參數
  // follow：跟隨選中單位的第三人稱（行動模式）
  fDist: 62, fHeight: 76, fPitch: 0.34, fFocal: 470,   // 2026-07-19 拉近：操作角色要有主角存在感（原 84/104/0.36）
  // overview：斜角俯瞰整個戰場（部署/指令/敵方回合）—露出天空與前景地面
  oPitch: 0.50, oFocal: 430, oHeight: 430, oBack: 400,

  // 目前生效的投影參數（project/unproject/horizonY/depthOf 皆讀這些）
  pitch: 0.36, focal: 470, nearZ: 1,
  mode: "overview",
  zoom: 1,             // 縮放（滾輪/雙指捏合）：<1 拉近、>1 拉遠，clamp 見 setZoom
  setZoom(z){ this.zoom = Math.max(0.4, Math.min(2.4, z)); },
  pan: { x: 0, y: 0 }, // 俯瞰平移（世界座標偏移；拖曳空地改變）
  panBy(dxScreen, dyScreen, map){
    // 「抓住地圖」語感：內容跟著手指走。靈敏度=畫面中心的世界單位/像素
    const sens = this.ch / this.focal * 1.15;
    const fx = Math.cos(this.yaw), fy = Math.sin(this.yaw);   // 前向
    const rx = -Math.sin(this.yaw), ry = Math.cos(this.yaw);  // 螢幕右
    this.pan.x += fx * dyScreen * sens - rx * dxScreen * sens;
    this.pan.y += fy * dyScreen * sens - ry * dxScreen * sens;
    const mw = (map && map.w) || 960, mh = (map && map.h) || 600;
    this.pan.x = Math.max(-mw, Math.min(mw, this.pan.x));
    this.pan.y = Math.max(-mh * 0.8, Math.min(mh * 0.8, this.pan.y));
  },
  resetView(){ this.zoom = 1; this.pan.x = 0; this.pan.y = 0; },

  // 目前生效相機狀態（project/unproject 讀這些）
  cx: 0, cy: 0, ch: 0, yaw: 0,
  // 目標狀態（applyFor 每幀朝此平滑內插 = P4 進出轉場）
  t: { cx: 0, cy: 0, ch: 0, yaw: 0, pitch: 0.36, focal: 470, mode: "overview" },
  _init: false,
  easeRate: 10.46,      // 秒制指數阻尼；60fps 時 k≈0.16

  /* 依遊戲狀態算目標相機並平滑靠近。輸入事件只讀最後渲染狀態，不得呼叫 instant。 */
  applyFor(G, instant, dt){
    // 敵方行動跟拍（dept-04 2026-07-21）＋防亂跳（同日使用者回饋「跳來跳去很亂」）：
    // 每個行動計畫只做一次跟拍決策——敵兵一旦被看見即鎖定跟拍到該行動結束，
    // 不因可見性閃爍在跟拍↔俯瞰之間來回切；隱形敵兵全程俯瞰（迷霧公平性）。
    const plan = G.state === "enemy" ? G.curPlan : null;
    if (plan !== this._foePlan){ this._foePlan = plan; this._foeLock = false; }
    const foe = plan && plan.unit;
    if (foe && foe.alive && !this._foeLock && G.enemyVisible(foe)) this._foeLock = true;
    if (G.state === "act" && G.sel) this.update(G.sel, this.t);
    else if (foe && foe.alive && this._foeLock) this.update(foe, this.t);
    else this.setOverview(G.map, G.playerSide, this.t);
    if (instant || !this._init){ this._snap(); this._init = true; }
    else this._ease(dt);
    return this;
  },

  _snap(){
    const t = this.t; this.cx = t.cx; this.cy = t.cy; this.ch = t.ch;
    this.yaw = t.yaw; this.pitch = t.pitch; this.focal = t.focal; this.mode = t.mode;
  },
  _ease(dt){
    dt = Math.max(0, Math.min(0.05, Number.isFinite(dt) ? dt : 1 / 60));
    const t = this.t, k = 1 - Math.exp(-this.easeRate * dt);
    this.cx += (t.cx - this.cx) * k; this.cy += (t.cy - this.cy) * k; this.ch += (t.ch - this.ch) * k;
    this.pitch += (t.pitch - this.pitch) * k; this.focal += (t.focal - this.focal) * k;
    let d = t.yaw - this.yaw; while (d > Math.PI) d -= 2 * Math.PI; while (d < -Math.PI) d += 2 * Math.PI;
    this.yaw += d * k;
    this.mode = t.mode; // 模式（準心/射程門檻）立即切換，相機再平滑追上
  },

  /* follow：相機退到選中單位後上方，yaw = 單位面向。寫入 out（預設 this=立即） */
  update(u, out){
    out = out || this;
    const f = (u && typeof u.facing === "number") ? u.facing : 0;
    const z = Math.max(0.6, Math.min(1.8, this.zoom));   // 跟隨模式縮放範圍較窄
    out.mode = "follow"; out.pitch = this.fPitch; out.focal = this.fFocal;
    out.yaw = f;
    out.cx = u.x - Math.cos(f) * this.fDist * z;
    out.cy = u.y - Math.sin(f) * this.fDist * z;
    out.ch = this.fHeight * z;
    return out;
  },

  /* overview：從玩家一側斜角高空俯瞰全場（依地圖大小取景 + zoom）。寫入 out */
  setOverview(map, playerSide, out){
    out = out || this;
    const mw = (map && map.w) || 960, mh = (map && map.h) || 600;
    const s = Math.max(mw / 960, mh / 600) * this.zoom;   // 地圖倍率 × 使用者縮放
    out.mode = "overview"; out.pitch = this.oPitch; out.focal = this.oFocal;
    const base = map && (map.bases || []).find(b => b.side === playerSide);
    const lookPlus = base ? base.x < mw / 2 : true;       // 玩家在左半 → 面向 +x
    out.yaw = lookPlus ? 0 : Math.PI;
    out.ch = this.oHeight * s;
    out.cx = (lookPlus ? -this.oBack * s : mw + this.oBack * s) + this.pan.x; // 退到玩家邊界外＋拖曳平移
    out.cy = mh / 2 + this.pan.y;
    return out;
  },

  /* 允許外部（測試/轉場）直接設定相機姿態 */
  set(cx, cy, ch, yaw){
    this.cx = cx; this.cy = cy; this.ch = ch; this.yaw = yaw; return this;
  },

  /* 世界點 → 螢幕。回傳 {sx,sy,depth,scale} 或 null（在相機後方/太近被剔除）
   * 步驟：平移到相機空間 → 繞垂直軸轉 -yaw（對齊面向）→ 繞水平軸俯 pitch → 透視除法。 */
  project(wx, wy, wz){
    wz = wz || 0;
    const dx = wx - this.cx, dy = wy - this.cy, dz = wz - this.ch;

    // 繞垂直軸旋轉 -yaw：fwd = 沿面向前方分量，side = 右手側分量
    const cyaw = Math.cos(this.yaw), syaw = Math.sin(this.yaw);
    const fwd  =  dx * cyaw + dy * syaw;
    const side = -dx * syaw + dy * cyaw;

    // 繞水平（右）軸俯 pitch：depth = 視線前向深度，up = 視平面上方分量
    const cp = Math.cos(this.pitch), sp = Math.sin(this.pitch);
    const depth = fwd * cp - dz * sp;   // 前向深度（>0 在相機前）
    const up    = fwd * sp + dz * cp;   // 視平面垂直分量（上為正）

    if (depth <= this.nearZ) return null;

    const scale = this.focal / depth;
    const sx = this.W / 2 + side * scale;
    const sy2 = this.H / 2 - up * scale;
    return { sx, sy: sy2, depth, scale };
  },

  /* 只算前向深度（供 render3d 對線段做 nearZ 裁剪，不需完整投影）。 */
  depthOf(wx, wy, wz){
    const dx = wx - this.cx, dy = wy - this.cy, dz = (wz || 0) - this.ch;
    const fwd = dx * Math.cos(this.yaw) + dy * Math.sin(this.yaw);
    return fwd * Math.cos(this.pitch) - dz * Math.sin(this.pitch);
  },

  /* 地平線螢幕 y（無窮遠地面點的投影，只依 pitch/focal）。上方為天空、下方為地面。 */
  horizonY(){ return this.H / 2 - Math.tan(this.pitch) * this.focal; },

  /* 螢幕點 → 地面世界座標（wz=0 的反投影）。回傳 [wx,wy] 或 null（點在地平線以上/相機後方）。
   * 供 act 模式輸入：把觸控點還原成地面座標，沿用現有 moveTarget / unitAt。 */
  unproject(sx, sy){
    const a = (sx - this.W / 2) / this.focal;   // = side/depth
    const b = (this.H / 2 - sy) / this.focal;   // = up/depth
    const cp = Math.cos(this.pitch), sp = Math.sin(this.pitch);
    const dz = -this.ch;                          // 地面 wz=0
    const denom = sp - b * cp;
    if (denom <= 1e-6) return null;               // 地平線以上，無地面交點
    const fwd = -dz * (b * sp + cp) / denom;
    if (fwd <= this.nearZ) return null;
    const depth = fwd * cp - dz * sp;
    const side = a * depth;
    const cyaw = Math.cos(this.yaw), syaw = Math.sin(this.yaw);
    const dx = fwd * cyaw - side * syaw;
    const dy = fwd * syaw + side * cyaw;
    return [this.cx + dx, this.cy + dy];
  },

  /* ---- 單元測試校正（GDD/07 §驗證判準 P1）----
   * 設一個已知相機：單位在 (480,300) 面向 +x。
   * 斷言：正前方地面點落畫面中央附近、正右方點落右側、相機後方點回 null。
   * 回傳 true/PASS，並 console 記錄。純測試，不影響遊戲。 */
  selfTest(){
    const save = { cx:this.cx, cy:this.cy, ch:this.ch, yaw:this.yaw };
    // 模擬選中單位 (480,300)，面向 +x（facing 0）
    this.update({ x:480, y:300, facing:0 });

    const results = [];
    const ok = (name, cond, info) => { results.push({ name, pass:!!cond, info }); return !!cond; };

    // 1) 正前方地面點：單位前方 100px → 應落畫面中央附近（sx≈480）
    const front = this.project(580, 300, 0);
    ok("正前方落中央", front && Math.abs(front.sx - this.W/2) < 6, front && `sx=${front.sx.toFixed(1)}`);

    // 2) 正右方點（面向右手側 = 世界 +y）100px → 應落畫面右半（sx>480）
    const right = this.project(480, 400, 0);
    ok("正右方落右側", right && right.sx > this.W/2 + 20, right && `sx=${right.sx.toFixed(1)}`);

    // 3) 相機後方點 → 應被剔除回 null
    const behind = this.project(300, 300, 0);
    ok("相機後方回null", behind === null, behind ? `sx=${behind.sx.toFixed(1)}` : "null");

    // 4) 近大遠小：近點 scale 應大於遠點
    const near = this.project(560, 300, 0), far = this.project(760, 300, 0);
    ok("近大遠小", near && far && near.scale > far.scale,
       near && far && `near=${near.scale.toFixed(2)} far=${far.scale.toFixed(2)}`);

    // 5) 反投影往復：project 後 unproject 應還原地面點
    const p = this.project(620, 340, 0);
    const back = p && this.unproject(p.sx, p.sy);
    ok("反投影往復", back && Math.hypot(back[0] - 620, back[1] - 340) < 0.5,
       back && `(${back[0].toFixed(1)},${back[1].toFixed(1)})`);

    this.set(save.cx, save.cy, save.ch, save.yaw); // 還原
    const allPass = results.every(r => r.pass);
    const tag = allPass ? "PASS" : "FAIL";
    console.log(`%c[Camera3D.selfTest] ${tag}`, allPass ? "color:#4fd05e" : "color:#e04b3a");
    for (const r of results) console.log(`  ${r.pass ? "✓" : "✗"} ${r.name}${r.info ? "  (" + r.info + ")" : ""}`);
    return allPass;
  }
};
