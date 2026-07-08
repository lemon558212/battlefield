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

  // 可調參數（GDD/07 §架構：D≈70,H≈90 待調）
  dist: 78,          // 相機在單位後方的水平距離 D
  height: 96,        // 相機離地高度 H
  pitch: 0.62,       // 俯角（弧度，約 35.5°）
  focal: 520,        // 焦距（決定 FOV；960 寬 → 視角約 85°）
  nearZ: 1,          // 近裁剪：深度 <= nearZ 視為在相機後方/太近，剔除

  // 目前相機狀態（由 update() 設定）
  cx: 0, cy: 0, ch: 0, yaw: 0,

  /* 依選中單位設定相機（yaw = 單位面向；相機退到其後上方） */
  update(u){
    const f = (u && typeof u.facing === "number") ? u.facing : 0;
    this.yaw = f;
    this.cx = u.x - Math.cos(f) * this.dist;
    this.cy = u.y - Math.sin(f) * this.dist;
    this.ch = this.height;
    return this;
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

    this.set(save.cx, save.cy, save.ch, save.yaw); // 還原
    const allPass = results.every(r => r.pass);
    const tag = allPass ? "PASS" : "FAIL";
    console.log(`%c[Camera3D.selfTest] ${tag}`, allPass ? "color:#4fd05e" : "color:#e04b3a");
    for (const r of results) console.log(`  ${r.pass ? "✓" : "✗"} ${r.name}${r.info ? "  (" + r.info + ")" : ""}`);
    return allPass;
  }
};
