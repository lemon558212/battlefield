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

  reset(){ this.visible.clear(); this.explored.clear(); this._dirty = true; this._htsMap = null; },

  /* 僅供除錯／觀戰使用；正常開戰不得呼叫，否則會破壞 GDD/05 三態迷霧。 */
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
    this.visible.clear(); this._dirty = true;
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
        ctx.fillStyle = s === 1 ? "rgba(10,14,20,0.45)" : "rgba(8,12,20,0.85)";
        ctx.fillRect(cx * FOG_CELL, cy * FOG_CELL, FOG_CELL, FOG_CELL);
      }
    }
  },

  /* 真 3D 主路徑：把世界格投影成透視四邊形，禁止沿用俯視座標整屏覆蓋。
   * 視覺規範（視覺感官部門 2026-07-19）：迷霧＝「晨霧藍灰紗」不是「黑色柏油」——
   * 低解析離屏＋平滑放大得到柔邊，濃度壓低保留地形可讀性。 */
  /* 效能改寫（2026-07-20 dept-10，L-fog）：
   * 1) 地形高度以「格頂點」預計算一次（地形靜態）——原版每幀每格 4 次 heightAt
   * 2) 投影以頂點共享：(cols+1)×(rows+1) 次，原版 4×cells 次（3.7 倍差）
   * 3) 迷霧與相機都沒變 → 直接重貼快取畫面（成本≈0）。原版恆為 40ms/幀等級 */
  _dirty: true,
  markDirty(){ this._dirty = true; },
  renderProjected(ctx, cam, heightAt){
    if(!this.enabled||!cam)return;
    const W=ctx.canvas.width,H=ctx.canvas.height,K=4;
    if(!this._soft||this._soft.width!==Math.ceil(W/K)){ this._soft=document.createElement("canvas");
      this._soft.width=Math.ceil(W/K); this._soft.height=Math.ceil(H/K); this._camSig=null; }
    // 相機簽名：兩個探針點的投影結果（相機任何改變都會反映）
    const pa=cam.project(0,0,0), pb=cam.project((Game.map.w||960),(Game.map.h||600),0);
    const sig=pa&&pb?`${pa.sx|0},${pa.sy|0},${pb.sx|0},${pb.sy|0}`:String(Math.random());
    if(!this._dirty && sig===this._camSig){
      ctx.save(); ctx.imageSmoothingEnabled=true; ctx.drawImage(this._soft,0,0,W,H); ctx.restore();
      return;
    }
    this._dirty=false; this._camSig=sig;
    // 頂點高度預計算（每張地圖一次）
    const cols=this._cols, rows=this._rows;
    if(this._htsMap!==Game.map){
      this._htsMap=Game.map; this._hts=new Float32Array((cols+1)*(rows+1));
      for(let vx=0;vx<=cols;vx++) for(let vy=0;vy<=rows;vy++)
        this._hts[vx*(rows+1)+vy]=(heightAt?heightAt(vx*FOG_CELL,vy*FOG_CELL):0)+0.8;
    }
    // 頂點投影（共享）
    const P=new Array((cols+1)*(rows+1));
    for(let vx=0;vx<=cols;vx++) for(let vy=0;vy<=rows;vy++){
      const i=vx*(rows+1)+vy;
      P[i]=cam.project(vx*FOG_CELL,vy*FOG_CELL,this._hts[i]);
    }
    const sc=this._soft.getContext("2d");
    sc.clearRect(0,0,this._soft.width,this._soft.height);
    const buckets=[[],[]];
    for(let cx=0;cx<cols;cx++){
      for(let cy=0;cy<rows;cy++){
        const s=this.state(cx*FOG_CELL,cy*FOG_CELL);
        if(s===2)continue;
        const p0=P[cx*(rows+1)+cy], p1=P[(cx+1)*(rows+1)+cy], p2=P[(cx+1)*(rows+1)+cy+1], p3=P[cx*(rows+1)+cy+1];
        if(!p0||!p1||!p2||!p3)continue;
        buckets[s].push([p0,p1,p2,p3]);
      }
    }
    for(const s of [0,1]){
      if(!buckets[s].length)continue;
      sc.beginPath();
      for(const pts of buckets[s]){
        sc.moveTo(pts[0].sx/K,pts[0].sy/K);
        for(let i=1;i<pts.length;i++)sc.lineTo(pts[i].sx/K,pts[i].sy/K);
        sc.closePath();
      }
      sc.fillStyle=s===1?"rgba(52,64,84,0.20)":"rgba(38,48,66,0.48)";   // 藍灰紗，非黑塊
      sc.fill();
    }
    ctx.save(); ctx.imageSmoothingEnabled=true;
    ctx.drawImage(this._soft,0,0,W,H);
    ctx.restore();
  }
};
