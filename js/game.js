/* ============================================================
 * game.js — 主狀態機、迴圈、輸入、渲染
 * 狀態：menu → deploy → cmd(指令模式) ⇄ act(行動模式) → enemy → over
 * 規則權威：GDD/01。本檔只實作，不自創規則。
 * ============================================================ */
"use strict";

const Game = {
  canvas:null, ctx:null, state:"menu",
  map:null, units:[], fx:[],
  playerSide:1, nations:{0:null,1:null},
  turn:1, cp:0, cpMax:0,
  sel:null,            // 行動模式中的單位
  selFired:false,      // 該次行動是否已用掉開火機會
  aimTarget:null,
  plans:[], curPlan:null, enemyCpLeft:0, germanyTankDiscountUsed:false,
  budgetLeft:0, deployCls:null,
  keys:{}, lastTs:0, over:null, hintIdx:0,

  /* ---------- 生命週期 ---------- */
  init(){
    this.canvas = document.getElementById("game");
    this.ctx = this.canvas.getContext("2d");
    window.addEventListener("keydown", e=>{ this.keys[e.key.toLowerCase()]=true; });
    window.addEventListener("keyup",   e=>{ this.keys[e.key.toLowerCase()]=false; });
    this.canvas.addEventListener("mousedown", e=>this.onClick(e));
    this.canvas.addEventListener("contextmenu", e=>e.preventDefault());
    UI.showMenu();
    const raf = ts=>{ this.loop(ts); requestAnimationFrame(raf); };
    requestAnimationFrame(raf);
    // 分頁隱藏時 rAF 被瀏覽器暫停，用 interval 後備驅動（注意：背景分頁計時器會被節流至約 1 次/秒，屬瀏覽器行為）
    setInterval(()=>{ if (document.hidden) this.loop(performance.now()); }, 50);
  },

  startBattle(mapId, atkNation, defNation, playerSide){
    this.map = MAPS[mapId];
    this.nations[0]=atkNation; this.nations[1]=defNation;
    this.playerSide = playerSide;
    this.units=[]; this.fx=[]; this.turn=1; this.over=null; this.hintIdx=0;
    this.budgetLeft = this.map.budget;
    this.deployCls = null;
    this.aiDeploy(1-playerSide);
    this.state="deploy";
    UI.showDeploy();
    if (this.map.tutorial) UI.hint(this.map.hints[0]);
  },

  /* 敵方自動部署：標準兵團（GDD/02 cost 合計 ≤ budget） */
  aiDeploy(side){
    const nation = this.nations[side];
    const roster = ["tank","mg","at","sniper","assault","rifleman","rifleman","engineer","specops","mortar"];
    let budget = this.map.budget;
    const zone = this.map.deploy[side];
    let i=0;
    for (const cls of roster){
      const c = unitCost(nation, cls);
      if (c > budget) continue;
      budget -= c;
      let x = zone.x + 30 + (i%3)*50, y = zone.y + 40 + Math.floor(i/3)*90;
      x = clamp(x,zone.x,zone.x+zone.w); y = clamp(y,zone.y,zone.y+zone.h);
      // 避開水域與建築（出生在水裡會白耗 AP）
      let guard=0;
      const bad = ()=> this.map.waters.some(w=>ptInRect(x,y,w)) || this.map.solids.some(s=>circleRectHit(x,y,16,s))
                    || this.units.some(o=>o.alive&&Math.hypot(o.x-x,o.y-y)<o.r+18);
      while (guard++<12 && bad()){ x += 40; if (x>zone.x+zone.w){ x=zone.x+20; y+=45; } }
      this.units.push(makeUnit(nation, cls, side, x, y));
      i++;
    }
  },

  finishDeploy(){
    if (!this.units.some(u=>u.side===this.playerSide)){ UI.log("至少部署一名單位"); return; }
    this.state="cmd";
    this.beginTurn(this.playerSide);
    UI.showBattle();
    if (this.map.tutorial) UI.hint(this.map.hints[1]);
  },

  cpFor(side){
    const tanks = this.units.filter(u=>u.alive&&u.side===side&&u.cls==="tank").length;
    return Math.min(10, 6 + tanks);
  },

  beginTurn(side){
    this.cp = this.cpMax = this.cpFor(side);
    this.germanyTankDiscountUsed = false;
    for (const u of this.units){ if(u.side===side){ u.actedCount=0; } u._iceTimer=0; }
    UI.refreshHud();
  },

  onOwnHalf(u){
    if (!this.map) return false;
    const mid = 480;
    return u.side===0 ? u.x<mid : u.x>mid;
  },

  /* ---------- 輸入 ---------- */
  onClick(e){
    const rect = this.canvas.getBoundingClientRect();
    const x = (e.clientX-rect.left) * (this.canvas.width/rect.width);
    const y = (e.clientY-rect.top) * (this.canvas.height/rect.height);
    if (this.state==="deploy") return this.deployClick(x,y,e.button);
    if (this.state==="cmd")    return this.cmdClick(x,y);
    if (this.state==="act")    return this.actClick(x,y);
  },

  deployClick(x,y,btn){
    const zone = this.map.deploy[this.playerSide];
    if (btn===2){ // 右鍵移除
      const u = this.unitAt(x,y,this.playerSide);
      if (u){ this.units.splice(this.units.indexOf(u),1); this.budgetLeft += u.cost; UI.refreshDeploy(); }
      return;
    }
    if (!this.deployCls) { UI.log("先在右側選擇兵種"); return; }
    if (!ptInRect(x,y,zone)) { UI.log("只能部署在我方藍框區域內"); return; }
    if (this.map.solids.some(s=>circleRectHit(x,y,14,s))) return;
    const c = unitCost(this.nations[this.playerSide], this.deployCls);
    if (c > this.budgetLeft){ UI.log("點數不足"); return; }
    if (this.deployCls==="tank" && this.units.filter(u=>u.side===this.playerSide&&u.cls==="tank").length>=2){ UI.log("坦克每隊最多 2 輛"); return; }
    this.budgetLeft -= c;
    this.units.push(makeUnit(this.nations[this.playerSide], this.deployCls, this.playerSide, x, y));
    UI.refreshDeploy();
  },

  unitAt(x,y,side=null){
    return this.units.find(u=>u.alive && (side===null||u.side===side) && Math.hypot(u.x-x,u.y-y)<=u.r+6);
  },

  cmdClick(x,y){
    const u = this.unitAt(x,y,this.playerSide);
    if (!u) return;
    let cost = u.cls==="tank" ? 2 : 1;
    if (u.cls==="tank" && NATIONS[u.nationId].trait.id==="panzer_doctrine" && !this.germanyTankDiscountUsed){
      cost = 1; // 德國：每回合首次坦克指令 1 CP
    }
    if (this.cp < cost){ UI.log("CP 不足"); return; }
    this.cp -= cost;
    if (cost===1 && u.cls==="tank") this.germanyTankDiscountUsed = true;
    this.enterAction(u);
  },

  enterAction(u){
    this.sel = u; this.selFired = false; this.state="act";
    let mult = Math.pow(0.7, u.actedCount);
    if (NATIONS[u.nationId].trait.id==="rapid_reaction" && this.turn===1) mult *= 1.2; // 法國
    u.ap = u.maxap * mult;
    u.actedCount++;
    for (const e of this.units) e._iceTimer = 0;
    UI.refreshHud();
    if (this.map.tutorial && this.hintIdx<2){ this.hintIdx=2; UI.hint(this.map.hints[2]); }
  },

  endAction(){
    this.sel=null; this.aimTarget=null; UI.hideAim();
    this.state="cmd";
    this.checkVictory();
    if (!this.over && this.cp<=0) this.endTurn();
    UI.refreshHud();
  },

  endTurn(){
    this.sel=null; this.aimTarget=null; UI.hideAim();
    if (this.over) return;
    this.state="enemy";
    this.beginTurn(1-this.playerSide);
    this.plans = AI.planTurn(this.map, 1-this.playerSide);
    this.curPlan = null;
    UI.log("—— 敵方階段 ——");
  },

  actClick(x,y){
    const foe = this.unitAt(x,y);
    if (foe && foe.side!==this.playerSide && Combat.canSee(this.map,this.sel,foe,this.turn)){
      this.aimTarget = foe; UI.showAim(this.sel, foe); return;
    }
    // 工兵修理：點自己坦克
    if (this.sel.cls==="engineer" && foe && foe.side===this.playerSide && foe.cls==="tank"
        && dist(this.sel,foe)<60 && !this.selFired && foe.hp<foe.maxhp){
      foe.hp = Math.min(foe.maxhp, foe.hp+300);
      this.selFired = true;
      this.fx.push({type:"hitfx", x:foe.x,y:foe.y, dmg:"+300", t:0, heal:true});
      UI.log(`${this.sel.label} 修理了 ${foe.label}（+300）`);
    }
  },

  /* 玩家在瞄準面板按下開火 */
  playerFire(part){
    if (this.selFired || !this.aimTarget) return;
    const t = this.aimTarget;
    const ev = Combat.fire(this.map, this.sel, t, part);
    this.pushFx(ev);
    this.selFired = true;
    this.aimTarget = null; UI.hideAim();
    UI.log(`${this.sel.label}（${this.sel.weaponName}）開火`);
    this.checkVictory();
    if (this.map.tutorial && this.hintIdx<4){ this.hintIdx=4; UI.hint(this.map.hints[4]); }
  },

  /* 佔領（GDD/01 §5） */
  tryCapture(){
    const u=this.sel; if(!u||!u.canCap||this.selFired) return;
    const base=this.map.bases.find(b=>b.side!==u.side);
    if (dist(u,base)>34){ UI.log("需相鄰敵方主堡"); return; }
    if (this.units.some(e=>e.alive&&e.side!==u.side&&dist(e,base)<40)){ UI.log("主堡仍有敵軍駐守"); return; }
    this.selFired=true;
    this.over={winner:u.side, why:"佔領敵方主堡"};
  },

  pushFx(ev){ for(const e of ev){ e.t=0; this.fx.push(e);} },

  /* ---------- 主迴圈 ---------- */
  loop(ts){
    const dt = Math.min(0.05,(ts-this.lastTs)/1000||0.016); this.lastTs=ts;
    if (this.state==="act")   this.updateAct(dt);
    if (this.state==="enemy") this.updateEnemy(dt);
    this.fx = this.fx.filter(f=>(f.t+=dt) < (f.type==="tracer"?0.25:f.type==="boom"?0.5:0.9));
    this.render();
  },

  moveUnit(u, dx, dy, dt){
    let speed = u.cls==="tank" ? 70 : 100; // px/s
    if (this.state==="enemy") speed *= 2.5; // 敵方階段快轉（戰棋慣例，不影響規則）
    let nx = u.x + dx*speed*dt, ny = u.y + dy*speed*dt;
    nx = clamp(nx, u.r, 960-u.r); ny = clamp(ny, u.r, 600-u.r);
    if (this.map.solids.some(s=>circleRectHit(nx,ny,u.r,s))){
      if (!this.map.solids.some(s=>circleRectHit(nx,u.y,u.r,s))) ny=u.y;
      else if (!this.map.solids.some(s=>circleRectHit(u.x,ny,u.r,s))) nx=u.x;
      else return false;
    }
    // 只擋「靠近碰撞對象」的移動；遠離方向放行（可自行脫離重疊死鎖）
    const bump = (px,py)=> this.units.some(o=>o!==u&&o.alive
      && Math.hypot(o.x-px,o.y-py)<o.r+u.r
      && Math.hypot(o.x-px,o.y-py) < Math.hypot(o.x-u.x,o.y-u.y));
    if (bump(nx,ny)){ // 撞到單位：沿軸滑行繞過
      if (!bump(nx,u.y)) ny=u.y;
      else if (!bump(u.x,ny)) nx=u.x;
      else return false;
    }
    const moved = Math.hypot(nx-u.x, ny-u.y);
    let apCost = moved/3; // 1 AP = 3px（GDD/01 §2）
    if (this.map.waters.some(w=>ptInRect(nx,ny,w))) apCost*=2;
    if (Combat.inBush(this.map,u) && NATIONS[u.nationId].trait.id==="tunnel_war") apCost*=0.5; // 越南
    if (u.ap < apCost) return false;
    u.ap -= apCost; u.x=nx; u.y=ny; u.facing=Math.atan2(dy,dx);
    if (!Combat.inBush(this.map,u)) u.revealed = u.revealed; // 進草叢不自動重置暴露
    return moved>0;
  },

  updateAct(dt){
    const u=this.sel; if(!u||!u.alive){ this.endAction(); return; }
    let dx=0,dy=0;
    if (this.keys["w"]||this.keys["arrowup"]) dy-=1;
    if (this.keys["s"]||this.keys["arrowdown"]) dy+=1;
    if (this.keys["a"]||this.keys["arrowleft"]) dx-=1;
    if (this.keys["d"]||this.keys["arrowright"]) dx+=1;
    if (dx||dy){
      const n=Math.hypot(dx,dy);
      const moved = this.moveUnit(u,dx/n,dy/n,dt);
      if (moved){
        this.pushFx(Combat.interceptTick(this.map,u,dt)); // 敵方警戒射擊
        if (!u.alive || u.hp<=0){ this.endAction(); return; }
        if (this.map.tutorial && this.hintIdx<3 && u.ap<u.maxap*0.6){ this.hintIdx=3; UI.hint(this.map.hints[3]); }
      }
    }
    UI.refreshActBar();
    this.checkVictory();
  },

  /* 敵方計畫逐幀執行 */
  updateEnemy(dt){
    if (this.over){ return; }
    if (!this.curPlan){
      this.curPlan = this.plans.shift();
      if (!this.curPlan){ // 敵方回合結束
        this.turn++;
        if (this.turn>30){ this.over={winner:1,why:"防守方撐過 30 回合"}; this.state="over"; UI.showEnd(); return; }
        this.state="cmd"; this.beginTurn(this.playerSide);
        UI.log(`—— 第 ${this.turn} 回合，我方階段 ——`);
        if (this.map.tutorial && this.hintIdx<5){ this.hintIdx=5; UI.hint(this.map.hints[5]); }
        return;
      }
      const p=this.curPlan, mult=Math.pow(0.7,p.unit.actedCount);
      p.unit.ap = p.unit.maxap*mult; p.unit.actedCount++;
      p.fired=false; p.stuck=0; p.age=0; p.detourT=0;
      for (const e of this.units) e._iceTimer=0;
    }
    const p=this.curPlan, u=p.unit;
    if (!u.alive){ this.curPlan=null; return; }
    if ((p.age+=dt) > 15) u.ap = 0; // 計畫超時保險：任何情況下敵回合必然終止
    const d = Math.hypot(p.destX-u.x, p.destY-u.y);
    const target = p.targetId ? this.units.find(t=>t.id===p.targetId&&t.alive) : null;
    const repair = p.repairId ? this.units.find(t=>t.id===p.repairId&&t.alive) : null;
    const canShoot = target && dist(u,target)<=u.weapon.range && Combat.canSee(this.map,u,target,this.turn)
                     && (u.weapon.arc || !Combat.losBlocked(this.map,u.x,u.y,target.x,target.y));
    // 已到預定點卻打不到（視線被擋）→ 改直接朝目標推進，繞出射界
    if (d<=8 && target && !canShoot && u.ap>5 && !p.fired){ p.destX=target.x; p.destY=target.y; return; }
    if (d>8 && u.ap>1 && !(canShoot && dist(u,target)<=u.weapon.range*0.7)){
      if (p.detourT>0){ // 迂迴模式：持續側移 0.5 秒繞過阻塞
        p.detourT-=dt;
        if (!this.moveUnit(u,Math.cos(p.detourA),Math.sin(p.detourA),dt)) p.detourT=0;
      } else {
        const moved=this.moveUnit(u,(p.destX-u.x)/d,(p.destY-u.y)/d,dt);
        if (!moved && (p.stuck+=dt)>0.3){ p.stuck=0; // 卡住：進入迂迴模式
          const side = (p.detourSign = -(p.detourSign||1)); // 左右輪替嘗試
          p.detourA = Math.atan2(p.destY-u.y,p.destX-u.x) + side*Math.PI/2;
          p.detourT = 0.5;
          if (!this.moveUnit(u,Math.cos(p.detourA),Math.sin(p.detourA),dt)) p.detourT=0.25;
        }
      }
      this.pushFx(Combat.interceptTick(this.map,u,dt)); // 我方警戒射擊敵人
      this.checkVictory();
      return;
    }
    // 抵達/夠近：執行一次動作後結束該計畫
    if (!p.fired){
      if (repair && dist(u,repair)<60){ repair.hp=Math.min(repair.maxhp,repair.hp+300);
        this.fx.push({type:"hitfx",x:repair.x,y:repair.y,dmg:"+300",t:0,heal:true});
      } else if (canShoot){
        this.pushFx(Combat.fire(this.map,u,target,p.part||"body"));
        UI.log(`敵 ${u.label}（${u.weaponName}）開火`);
      }
      p.fired=true;
    }
    this.checkVictory();
    this.curPlan=null;
  },

  checkVictory(){
    if (this.over){ if(this.state!=="over"){ this.state="over"; UI.showEnd(); } return; }
    const a=this.units.some(u=>u.alive&&u.side===0), b=this.units.some(u=>u.alive&&u.side===1);
    if (!a||!b){ this.over={winner:a?0:1, why:"殲滅敵方部隊"}; this.state="over"; UI.showEnd(); return; }
    // AI 佔領玩家主堡
    const eSide=1-this.playerSide, base=this.map.bases.find(bs=>bs.side===this.playerSide);
    const capper=this.units.find(u=>u.alive&&u.side===eSide&&u.canCap&&dist(u,base)<30);
    if (capper && !this.units.some(u=>u.alive&&u.side===this.playerSide&&dist(u,base)<40)){
      this.over={winner:eSide, why:"主堡失守"}; this.state="over"; UI.showEnd();
    }
  },

  /* ---------- 渲染 ---------- */
  render(){
    const c=this.ctx, m=this.map;
    c.clearRect(0,0,960,600);
    if (this.state==="menu"||!m) return;
    c.fillStyle=m.ground; c.fillRect(0,0,960,600);
    for (const w of m.waters){ c.fillStyle="#4a7c9e"; c.fillRect(w.x,w.y,w.w,w.h); }
    for (const b of m.bushes){ c.fillStyle="rgba(40,90,35,0.85)"; c.beginPath(); c.arc(b.x,b.y,b.r,0,7); c.fill(); }
    for (const s of m.sandbags){ c.fillStyle="#b09761"; c.fillRect(s.x,s.y,s.w,s.h); c.strokeStyle="#7d6a44"; c.strokeRect(s.x,s.y,s.w,s.h); }
    for (const s of m.solids){ c.fillStyle="#6e6e6e"; c.fillRect(s.x,s.y,s.w,s.h); c.strokeStyle="#4a4a4a"; c.strokeRect(s.x,s.y,s.w,s.h); }
    for (const b of m.bases){
      c.fillStyle = b.side===this.playerSide ? "#2e6fd8" : "#c23b22";
      c.beginPath(); c.arc(b.x,b.y,14,0,7); c.fill();
      c.fillRect(b.x-2,b.y-38,4,26);
      c.beginPath(); c.moveTo(b.x+2,b.y-38); c.lineTo(b.x+22,b.y-32); c.lineTo(b.x+2,b.y-26); c.fill();
    }
    if (this.state==="deploy"){
      const z=m.deploy[this.playerSide];
      c.strokeStyle="#2e6fd8"; c.setLineDash([6,4]); c.lineWidth=2;
      c.strokeRect(z.x,z.y,z.w,z.h); c.setLineDash([]); c.lineWidth=1;
    }
    for (const u of this.units) if(u.alive) this.drawUnit(c,u);
    if (this.state==="act" && this.sel){ // 射程圈
      c.strokeStyle="rgba(255,255,255,0.35)"; c.setLineDash([4,6]);
      c.beginPath(); c.arc(this.sel.x,this.sel.y,this.sel.weapon.range,0,7); c.stroke(); c.setLineDash([]);
    }
    for (const f of this.fx) this.drawFx(c,f);
  },

  drawUnit(c,u){
    const hidden = Combat.inBush(this.map,u) && !u.revealed;
    const isPlayer = u.side===this.playerSide;
    if (hidden && !isPlayer) return; // 敵隱蔽單位不畫
    c.globalAlpha = hidden ? 0.55 : 1;
    const col = NATIONS[u.nationId].uniformColor;
    if (u.cls==="tank"){
      c.fillStyle=col; c.fillRect(u.x-16,u.y-11,32,22);
      c.fillStyle=isPlayer?"#2e6fd8":"#c23b22"; c.fillRect(u.x-7,u.y-6,14,12);
      c.strokeStyle="#222"; c.beginPath(); c.moveTo(u.x,u.y);
      c.lineTo(u.x+Math.cos(u.facing)*24,u.y+Math.sin(u.facing)*24); c.lineWidth=3; c.stroke(); c.lineWidth=1;
      c.fillStyle="#e8c06a"; c.fillRect(u.x+10,u.y+6,5,5); // 散熱器示意
    } else {
      c.fillStyle=col; c.beginPath(); c.arc(u.x,u.y,u.r,0,7); c.fill();
      c.strokeStyle=isPlayer?"#7db4ff":"#ff9d8a"; c.lineWidth=2; c.stroke(); c.lineWidth=1;
      c.fillStyle="#fff"; c.font="9px sans-serif"; c.textAlign="center";
      const letter={rifleman:"步",assault:"突",mg:"機",mortar:"迫",sniper:"狙",at:"火",engineer:"工",specops:"特"}[u.cls];
      c.fillText(letter,u.x,u.y+3);
    }
    // 血條/AP條
    const w=u.cls==="tank"?32:22, x0=u.x-w/2, y0=u.y-u.r-9;
    c.fillStyle="#222"; c.fillRect(x0,y0,w,3);
    c.fillStyle=u.hp>u.maxhp*0.3?"#4fd05e":"#e04b3a"; c.fillRect(x0,y0,w*clamp(u.hp/u.maxhp,0,1),3);
    if (this.sel===u){ c.fillStyle="#222"; c.fillRect(x0,y0+4,w,3);
      c.fillStyle="#ffd83d"; c.fillRect(x0,y0+4,w*clamp(u.ap/u.maxap,0,1),3);
      c.strokeStyle="#ffd83d"; c.beginPath(); c.arc(u.x,u.y,u.r+5,0,7); c.stroke();
    }
    c.globalAlpha=1;
  },

  drawFx(c,f){
    if (f.type==="tracer"){
      c.strokeStyle=f.hit?"rgba(255,220,90,"+(1-f.t/0.25)+")":"rgba(200,200,200,"+(1-f.t/0.25)+")";
      c.beginPath(); c.moveTo(f.x1,f.y1); c.lineTo(f.x2,f.y2); c.stroke();
    } else if (f.type==="boom"){
      c.fillStyle="rgba(255,140,40,"+(1-f.t/0.5)*0.7+")";
      c.beginPath(); c.arc(f.x,f.y,f.r*(0.5+f.t),0,7); c.fill();
    } else if (f.type==="hitfx"){
      c.fillStyle=f.heal?"#5eff8a":"#ffe08a"; c.font="bold 12px sans-serif"; c.textAlign="center";
      c.globalAlpha=1-f.t/0.9; c.fillText(f.heal?f.dmg:"-"+f.dmg, f.x, f.y-14-f.t*22); c.globalAlpha=1;
    } else if (f.type==="death"){
      c.strokeStyle="rgba(60,60,60,"+(1-f.t/0.9)+")";
      c.beginPath(); c.moveTo(f.x-8,f.y-8); c.lineTo(f.x+8,f.y+8); c.moveTo(f.x+8,f.y-8); c.lineTo(f.x-8,f.y+8); c.stroke();
    }
  },

  /* ---------- 平衡快速模擬（GDD/02 §4 驗收用，無地圖抽象戰） ---------- */
  autoBattle(na, nb, sims=100){
    let winA=0;
    for (let s=0;s<sims;s++){
      const A=["rifleman","rifleman","assault","mg","at","sniper","tank"].map(k=>makeUnit(na,k,0,0,0));
      const B=["rifleman","rifleman","assault","mg","at","sniper","tank"].map(k=>makeUnit(nb,k,1,0,0));
      let guard=0;
      while (A.some(u=>u.alive)&&B.some(u=>u.alive)&&guard++<400){
        const order = Math.random()<0.5 ? [[A,B],[B,A]] : [[B,A],[A,B]]; // 隨機先手，消除模擬器偏差
        for (const [team,foes] of order){
          for (const u of team){
            if (!u.alive) continue;
            const alive=foes.filter(f=>f.alive); if(!alive.length) break;
            const t = u.weapon.antiTank ? (alive.find(f=>f.cls==="tank")||alive[0]) : alive[Math.floor(Math.random()*alive.length)];
            for (let i=0;i<u.weapon.shots;i++){
              if (Math.random()<u.weapon.acc*0.8){ t.hp-=Combat.damage(u,t,"body",false); }
            }
            if (t.hp<=0) t.alive=false;
          }
        }
      }
      if (B.every(u=>!u.alive)) winA++;
    }
    const rate=winA/sims;
    console.log(`autoBattle ${na} vs ${nb}：${na} 勝率 ${(rate*100).toFixed(0)}%（合格區間 35%~65%）`);
    return rate;
  }
};
