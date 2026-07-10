/* ============================================================
 * fog.js — 戰爭迷霧與視野（權威：GDD/05）
 * 三態：unseen(未探索,全黑) / explored(已探索,暗) / visible(可見)
 * ============================================================ */
"use strict";

const FOG_CELL = 32;

const Fog = {
  visible: new Set(),
  explored: new Set(),
  enabled: true,
  _cols: 0, _rows: 0,

  key(cx, cy){ return cx + "," + cy; },

  reset(){ this.visible.clear(); this.explored.clear(); },

  /* 開局把整張地圖標為已探索：地形全程可見（戰場女武神式），
     迷霧只體現在「敵人未偵察到就不顯示」，而非遮黑地形 */
  exploreAll(){
    this._cols = Math.ceil(((Game.map&&Game.map.w)||960) / FOG_CELL);
    this._rows = Math.ceil(((Game.map&&Game.map.h)||600) / FOG_CELL);
    for (let cx = 0; cx < this._cols; cx++)
      for (let cy = 0; cy < this._rows; cy++)
        this.explored.add(this.key(cx, cy));
  },

  /* 依當前我方單位重算可見格（GDD/05 §3）。移動每 0.1s 或回合切換時呼叫 */
  recompute(){
    if (!Game.map) return;
    this.visible.clear();
    this._cols = Math.ceil((Game.map.w||960) / FOG_CELL);
    this._rows = Math.ceil((Game.map.h||600) / FOG_CELL);
    for (const u of Game.units){
      if (!u.alive || u.side !== Game.playerSide) continue;
      let R = u.sight;
      if (NATIONS[u.nationId].trait.id === "intel_superiority") R *= 1.2; // 以色列
      const minx = Math.max(0, Math.floor((u.x - R) / FOG_CELL));
      const maxx = Math.min(this._cols - 1, Math.floor((u.x + R) / FOG_CELL));
      const miny = Math.max(0, Math.floor((u.y - R) / FOG_CELL));
      const maxy = Math.min(this._rows - 1, Math.floor((u.y + R) / FOG_CELL));
      for (let cx = minx; cx <= maxx; cx++){
        for (let cy = miny; cy <= maxy; cy++){
          const px = cx * FOG_CELL + FOG_CELL / 2, py = cy * FOG_CELL + FOG_CELL / 2;
          if (Math.hypot(px - u.x, py - u.y) > R) continue;
          if (!u.flying && Combat.losBlocked(Game.map, u.x, u.y, px, py)) continue; // 地面視線被 solid 擋
          const k = this.key(cx, cy);
          this.visible.add(k); this.explored.add(k);
        }
      }
    }
  },

  state(x, y){
    const k = this.key(Math.floor(x / FOG_CELL), Math.floor(y / FOG_CELL));
    if (this.visible.has(k)) return 2;
    if (this.explored.has(k)) return 1;
    return 0;
  },
  visibleAt(x, y){ return !this.enabled || this.state(x, y) === 2; },

  /* 給 AI 用：side 陣營是否看得到 target（GDD/05 §5，AI 公平性） */
  sideCanSee(side, target){
    if (!this.enabled) return true;
    for (const u of Game.units){
      if (!u.alive || u.side !== side) continue;
      let R = u.sight;
      if (NATIONS[u.nationId].trait.id === "intel_superiority") R *= 1.2;
      if (u.cls === "sam" && target.flying) R = u.airSight || R;
      if (dist(u, target) <= R && Combat.canSee(Game.map, u, target, Game.turn)) return true;
    }
    return false;
  },

  /* 渲染迷霧遮罩層（在敵單位之後、我方單位之前呼叫）
     設計原則：地形永遠看得清（戰場女武神式），迷霧只做「未偵察」的淡暗提示，
     真正的資訊隱藏是「敵人不顯示」（由 Game.enemyVisible 負責），不是遮黑地形 */
  render(ctx){
    if (!this.enabled) return;
    for (let cx = 0; cx < this._cols; cx++){
      for (let cy = 0; cy < this._rows; cy++){
        const s = this.state(cx * FOG_CELL, cy * FOG_CELL);
        if (s === 2) continue;
        ctx.fillStyle = s === 1 ? "rgba(10,14,20,0.12)" : "rgba(8,12,20,0.34)";
        ctx.fillRect(cx * FOG_CELL, cy * FOG_CELL, FOG_CELL, FOG_CELL);
      }
    }
  }
};
