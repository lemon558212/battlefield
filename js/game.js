/* ============================================================
 * game.js — 主狀態機、迴圈、輸入、渲染
 * 狀態：menu → deploy → cmd(指令模式) ⇄ act(行動模式) → enemy → over
 * 規則權威：GDD/01。本檔只實作，不自創規則。
 * ============================================================ */
"use strict";

const ENEMY_SUBSTEPS = 6; // 敵方回合每幀推進的子步數（牆鐘壓縮，見 loop 註解）

const Game = {
  canvas:null, ctx:null, state:"menu",
  map:null, units:[], fx:[],
  playerSide:1, nations:{0:null,1:null},
  turn:1, cp:0, cpMax:0,
  sel:null,            // 行動模式中的單位
  selFired:false,      // 該次行動是否已用掉開火機會
  aimTarget:null,
  moveTarget:null,
  turnOwner:null,        // 連線對戰：目前輪到哪一方（0/1）
  _steer:null, _mouseDown:false,   // 拖曳操控移動狀態
  _mpReady:false, _mpGuestUnits:null,   // 連線布署狀態
  plans:[], curPlan:null, enemyCpLeft:0, germanyTankDiscountUsed:false,
  budgetLeft:0, deployCls:null,
  keys:{}, lastTs:0, over:null, hintIdx:0,

  /* ---------- 生命週期 ---------- */
  init(){
    this.canvas = document.getElementById("game");
    this.ctx = this.canvas.getContext("2d");
    window.addEventListener("keydown", e=>{ this.keys[e.key.toLowerCase()]=true; });
    window.addEventListener("keyup",   e=>{ this.keys[e.key.toLowerCase()]=false; });
    this.canvas.addEventListener("mousedown", e=>{ this._mouseDown=true; this.onClick(e); });
    window.addEventListener("mousemove", e=>{ if(this._mouseDown) this._pointerMove(e.clientX,e.clientY); });
    window.addEventListener("mouseup", ()=>{ this._mouseDown=false; this._pointerUp(); });
    // 手機觸控：touch 轉為點擊（部署放置／下令／行動移動與開火）
    this.canvas.addEventListener("touchstart", e=>{ if(e.cancelable) e.preventDefault(); const t=e.changedTouches[0]; if(t) this.onClickXY(t.clientX,t.clientY,0); }, {passive:false});
    this.canvas.addEventListener("touchmove", e=>{ if(e.cancelable) e.preventDefault(); const t=e.changedTouches[0]; if(t) this._pointerMove(t.clientX,t.clientY); }, {passive:false});
    this.canvas.addEventListener("touchend", e=>{ if(e.cancelable) e.preventDefault(); this._pointerUp(); }, {passive:false});
    this.canvas.addEventListener("contextmenu", e=>e.preventDefault());
    UI.showMenu();
    const raf = ts=>{ this.loop(ts); requestAnimationFrame(raf); };
    requestAnimationFrame(raf);
    // 分頁隱藏時 rAF 被瀏覽器暫停，用 interval 後備驅動（注意：背景分頁計時器會被節流至約 1 次/秒，屬瀏覽器行為）
    setInterval(()=>{ if (document.hidden) this.loop(performance.now()); }, 50);
  },

  startBattle(mapId, atkNation, defNation, playerSide){
    this.map = MAPS[mapId];
    this.enrichMap(this.map); this._bg = null;
    this.nations[0]=atkNation; this.nations[1]=defNation;
    this.playerSide = playerSide;
    this.units=[]; this.fx=[]; this.turn=1; this.over=null; this.hintIdx=0;
    Fog.reset();
    this.budgetLeft = this.map.budget;
    this.deployCls = null;
    this.aiDeploy(1-playerSide);
    this.state="deploy";
    UI.showDeploy();
    if (this.map.tutorial) UI.hint(this.map.hints[0]);
  },

  /* 地圖允許的作戰域（預設純陸戰） */
  mapAllow(){ return this.map.allow || ["land"]; },

  /* 程式化增豐地圖：在中央戰區散佈額外掩體/障礙（避開部署區與主堡），只做一次 */
  enrichMap(m){
    if (m._enriched) return; m._enriched = true;
    let seed=0; for (const ch of m.id) seed=(seed*31+ch.charCodeAt(0))%2147483647;
    const rnd=()=>((seed=(seed*16807+11)%2147483647)/2147483647);
    const zones=m.deploy||[];
    const inDeploy=(x,y)=>zones.some(z=>x>=z.x-10&&x<=z.x+z.w+10&&y>=z.y-10&&y<=z.y+z.h+10);
    const nearBase=(x,y)=>(m.bases||[]).some(b=>Math.hypot(b.x-x,b.y-y)<75);
    const onSolid=(x,y,pad)=>(m.solids||[]).some(s=>x>s.x-pad&&x<s.x+s.w+pad&&y>s.y-pad&&y<s.y+s.h+pad);
    const water=(x,y)=>this.isWater(x,y);
    const place=(ok)=>{ for(let t=0;t<60;t++){ const x=120+rnd()*720, y=50+rnd()*500;
      if(inDeploy(x,y)||nearBase(x,y)) continue; if(ok(x,y)) return {x,y}; } return null; };
    const allow=m.allow||["land"];
    if (allow.includes("land")){
      m.sandbags=m.sandbags||[];
      for(let i=0;i<8;i++){ const p=place((x,y)=>!onSolid(x,y,22)&&!water(x,y)); if(!p)continue;
        m.sandbags.push(rnd()<0.5?{x:p.x,y:p.y,w:46,h:12}:{x:p.x,y:p.y,w:12,h:46}); }
      m.solids=m.solids||[];
      for(let i=0;i<4;i++){ const p=place((x,y)=>!onSolid(x,y,44)&&!water(x,y)); if(!p)continue;
        const sz=26+rnd()*20; m.solids.push({x:p.x,y:p.y,w:sz,h:sz}); }
      m.bushes=m.bushes||[];
      for(let i=0;i<6;i++){ const p=place((x,y)=>!onSolid(x,y,22)&&!water(x,y)); if(!p)continue;
        m.bushes.push({x:p.x,y:p.y,r:22+rnd()*14}); }
    }
    if (allow.includes("sea")){
      m.reefs=m.reefs||[];
      for(let i=0;i<7;i++){ const p=place((x,y)=>water(x,y)); if(!p)continue;
        const sz=26+rnd()*16; m.reefs.push({x:p.x,y:p.y,w:sz,h:sz}); }
    }
  },

  /* 敵方自動部署：三軍預算配額制，各域平分預算避免單一軍種吃光（GDD/04 §1） */
  aiDeploy(side){
    const nation = this.nations[side];
    const allow = this.mapAllow();
    const zone = this.map.deploy[side];
    const perDomain = {
      land:["tank","mg","at","sniper","assault","rifleman","rifleman","engineer","sam"],
      sea:["destroyer","missileboat","submarine","lst"],
      air:["fighter","attacker","gunship"]
    };
    const doms = allow.filter(d=>perDomain[d]);
    const quota = this.map.budget / doms.length;
    for (const dom of doms){
      let b = quota;
      for (const cls of perDomain[dom]){
        const c = unitCost(nation, cls);
        if (c > b) continue;
        const spot = this.findDeploySpot(dom, zone);
        if (!spot) continue;
        b -= c;
        this.units.push(makeUnit(nation, cls, side, spot.x, spot.y));
      }
    }
  },

  /* 在部署區找一個符合作戰域地形的生成點 */
  findDeploySpot(domain, zone){
    for (let t=0;t<100;t++){
      const x = zone.x + 20 + Math.random()*Math.max(1,zone.w-40);
      const y = zone.y + 20 + Math.random()*Math.max(1,zone.h-40);
      if (this.map.solids.some(s=>circleRectHit(x,y,18,s))) continue;
      if (this.units.some(o=>o.alive&&Math.hypot(o.x-x,o.y-y)<o.r+20)) continue;
      if (domain==="sea" && !this.isWater(x,y)) continue;
      if (domain==="land" && (this.inAny(this.map.waters,x,y)||this.inAny(this.map.deepwaters,x,y))) continue;
      return {x,y};
    }
    return null;
  },

  finishDeploy(){
    if (!this.units.some(u=>u.side===this.playerSide)){ UI.log("至少部署一名單位"); return; }
    if (Net.connected){ this.mpReady(); return; }
    this.state="cmd";
    Fog.exploreAll();   // 地形全程可見，迷霧只隱藏未偵察的敵人
    Fog.recompute();
    this.beginTurn(this.playerSide);
    UI.showBattle();
    if (this.map.tutorial) UI.hint(this.map.hints[1]);
  },

  cpFor(side){
    const tanks = this.units.filter(u=>u.alive&&u.side===side&&u.cls==="tank").length;
    return Math.min(10, 6 + tanks);
  },

  /* ---------- 連線對戰（net.js） ---------- */
  // 主機：設定並自動布署雙方預設軍隊，立即開打，廣播初始狀態
  startMP(mapId, atkNation, defNation){
    this.startBattle(mapId, atkNation, defNation, 0); // 主機固定 side 0
    this.aiDeploy(0);                                 // startBattle 已布署 side 1，這裡補 side 0
    this.playerSide = 0; this.turnOwner = 0;
    this.state = "cmd";
    Fog.exploreAll(); Fog.recompute();
    this.beginTurn(0);
    UI.showBattle();
    Net.sendState();
    UI.log("—— 連線對戰開始，你先手 ——");
  },

  // 主機：連線成功後送設定給對方，雙方進入各自布署
  mpHostBegin(mapId, nA, nD){
    Net.send("config", { map:mapId, nA, nD });
    this.startMPDeploy(mapId, nA, nD, 0);
  },
  // 加入方：收到主機設定 → 進入布署
  mpConfig(d){ this.startMPDeploy(d.map, d.nA, d.nD, 1); },

  // 連線布署：各自布署自己那一方（side = 自己）
  startMPDeploy(mapId, nA, nD, myside){
    this.map = MAPS[mapId]; this.enrichMap(this.map); this._bg = null;
    this.nations = { 0:nA, 1:nD };
    this.playerSide = myside;
    this.units = []; this.fx = []; this.turn = 1; this.over = null; this.hintIdx = 0;
    this.budgetLeft = this.map.budget; this.deployCls = null;
    this._mpReady = false; this._mpGuestUnits = null;
    Fog.reset();
    this.state = "deploy";
    UI.showDeploy();
    UI.log(myside===0 ? "你是主持方，布署你的部隊後按「開始戰鬥」" : "你是加入方，布署你的部隊後按「開始戰鬥」");
  },

  // 按下「開始戰鬥」（連線版）：送出我方部隊、視情況開打
  mpReady(){
    this._mpReady = true;
    Net.send("units", { units: this.units.filter(u=>u.side===this.playerSide).map(u=>Net.serUnit(u)) });
    if (Net.myside===0){
      if (this._mpGuestUnits) this._mpHostStart();
      else UI.log("已就緒，等待對方布署完成…");
    } else {
      UI.log("已送出布署，等待主持方開始…");
    }
  },
  // 收到對方部署的部隊
  mpRecvUnits(d){
    if (Net.myside!==0) return;              // 只有主機需要合併
    this._mpGuestUnits = d.units;
    if (this._mpReady) this._mpHostStart();
  },
  // 主機權威合併雙方部隊、開打並廣播
  _mpHostStart(){
    let maxid = 0; for (const u of this.units) if (u.id>maxid) maxid=u.id;
    const opp = this._mpGuestUnits.map(su=>{
      const u = makeUnit(su.nationId, su.cls, 1, su.x, su.y);
      u.id = ++maxid; u.hp=su.hp; u.ap=su.ap; u.facing=su.facing; u.alive=su.alive;
      return u;
    });
    this.units = this.units.filter(u=>u.side===0).concat(opp);
    this.turnOwner = 0; this.playerSide = 0; this.state = "cmd";
    Fog.exploreAll(); Fog.recompute(); this.beginTurn(0);
    UI.showBattle(); Net.sendState();
    UI.log("—— 雙方就緒，開戰！你先手 ——");
  },

  // 連線版換手：不跑 AI，翻面 + 廣播，讓對方接手
  mpEndTurn(){
    this.turnOwner = 1 - this.turnOwner;
    if (this.turnOwner===0) this.turn++;
    if (this.turn>30 && !this.over){ this.over={winner:1, why:"撐過 30 回合"}; }
    this.state = "cmd";
    if (!this.over) this.beginTurn(this.turnOwner);
    if (this.over){ this.state="over"; UI.showEnd(); }
    Net.sendState();
    UI.refreshHud();
    UI.log(this.turnOwner===Net.myside ? "—— 換你行動 ——" : "—— 等待對方行動 ——");
  },

  // 收到對方廣播的權威狀態，重建本機遊戲
  applyNetState(d){
    if (!MAPS[d.map]) return;
    this.map = MAPS[d.map]; this.enrichMap(this.map); this._bg = null;
    this.nations = d.nations;
    this.turn = d.turn; this.cp = d.cp; this.cpMax = d.cpMax; this.over = d.over || null;
    this.turnOwner = d.turnOwner;
    this.playerSide = Net.myside;
    let maxid = 0;
    this.units = d.units.map(su=>{
      const u = makeUnit(su.nationId, su.cls, su.side, su.x, su.y);
      u.id=su.id; u.hp=su.hp; u.ap=su.ap; u.alive=su.alive; u.facing=su.facing;
      u.actedCount=su.actedCount; u.revealed=su.revealed;
      if (su.id>maxid) maxid=su.id;
      return u;
    });
    UNIT_SEQ = Math.max(UNIT_SEQ||1, maxid+1);
    this.sel=null; this.aimTarget=null; this.moveTarget=null;
    this.state = this.over ? "over" : "cmd";
    Fog.exploreAll(); Fog.recompute();
    if (this.over) UI.showEnd(); else UI.showBattle();
    UI.refreshHud();
  },

  beginTurn(side){
    this.cp = this.cpMax = this.cpFor(side);
    this.germanyTankDiscountUsed = false;
    for (const u of this.units){ if(u.side===side){ u.actedCount=0; } u._iceTimer=0; }
    Fog.recompute();
    UI.refreshHud();
  },

  onOwnHalf(u){
    if (!this.map) return false;
    const mid = 480;
    return u.side===0 ? u.x<mid : u.x>mid;
  },

  /* ---------- 輸入 ---------- */
  onClick(e){ this.onClickXY(e.clientX, e.clientY, e.button||0); },
  onClickXY(clientX, clientY, button){
    const rect = this.canvas.getBoundingClientRect();
    const x = (clientX-rect.left) * (this.canvas.width/rect.width);
    const y = (clientY-rect.top) * (this.canvas.height/rect.height);
    if (this.state==="deploy") return this.deployClick(x,y,button);
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
    const dom = CLASS_BASE[this.deployCls].domain;
    if (dom==="sea" && !this.isWater(x,y)){ UI.log("艦艇只能部署在水域（藍色）"); return; }
    if (dom==="land" && (this.inAny(this.map.waters,x,y)||this.inAny(this.map.deepwaters,x,y))){ UI.log("陸軍不能部署在深水，只能上陸或淺灘"); return; }
    const c = unitCost(this.nations[this.playerSide], this.deployCls);
    if (c > this.budgetLeft){ UI.log("點數不足"); return; }
    if (this.deployCls==="tank" && this.units.filter(u=>u.side===this.playerSide&&u.cls==="tank").length>=2){ UI.log("坦克每隊最多 2 輛"); return; }
    if (CLASS_BASE[this.deployCls].big && this.units.filter(u=>u.side===this.playerSide&&CLASS_BASE[u.cls].big).length>=2){ UI.log("大型艦每隊最多 2 艘"); return; }
    if (dom==="air" && this.units.filter(u=>u.side===this.playerSide&&u.domain==="air").length>=4){ UI.log("空軍每隊最多 4 架"); return; }
    this.budgetLeft -= c;
    this.units.push(makeUnit(this.nations[this.playerSide], this.deployCls, this.playerSide, x, y));
    UI.refreshDeploy();
  },

  unitAt(x,y,side=null){
    return this.units.find(u=>u.alive && (side===null||u.side===side) && Math.hypot(u.x-x,u.y-y)<=u.r+6);
  },

  cmdClick(x,y){
    if (Net.connected && Net.myside!==this.turnOwner){ UI.log("等待對方行動…"); return; }
    const u = this.unitAt(x,y,this.playerSide);
    if (!u) return;
    let cost = (u.cls==="tank" || u.big || u.domain==="air") ? 2 : 1; // 坦克/大艦/戰機花 2 CP
    if (u.cls==="tank" && NATIONS[u.nationId].trait.id==="panzer_doctrine" && !this.germanyTankDiscountUsed){
      cost = 1; // 德國：每回合首次坦克指令 1 CP
    }
    if (this.cp < cost){ UI.log("CP 不足"); return; }
    this.cp -= cost;
    if (cost===1 && u.cls==="tank") this.germanyTankDiscountUsed = true;
    this.enterAction(u);
  },

  enterAction(u){
    this.sel = u; this.selFired = false; this.state="act"; this.moveTarget = null;
    let mult = Math.pow(0.7, u.actedCount);
    if (NATIONS[u.nationId].trait.id==="rapid_reaction" && this.turn===1) mult *= 1.2; // 法國
    u.ap = u.maxap * mult;
    u.actedCount++;
    for (const e of this.units) e._iceTimer = 0;
    UI.refreshHud();
    if (this.map.tutorial && this.hintIdx<2){ this.hintIdx=2; UI.hint(this.map.hints[2]); }
  },

  endAction(){
    this.sel=null; this.aimTarget=null; this.moveTarget=null; UI.hideAim();
    this.state="cmd";
    this.checkVictory();
    if (Net.connected && !this.over) Net.sendState();
    if (!this.over && this.cp<=0) this.endTurn();
    UI.refreshHud();
  },

  endTurn(){
    this.sel=null; this.aimTarget=null; UI.hideAim();
    if (this.over) return;
    if (Net.connected){ if(Net.myside===this.turnOwner) this.mpEndTurn(); return; }
    this.state="enemy";
    this.beginTurn(1-this.playerSide);
    this.plans = AI.planTurn(this.map, 1-this.playerSide);
    this.curPlan = null;
    UI.log("—— 敵方階段 ——");
  },

  actClick(x,y){
    if (Net.connected && Net.myside!==this.turnOwner) return;
    const foe = this.unitAt(x,y);
    if (foe && foe.side!==this.playerSide && Combat.canSee(this.map,this.sel,foe,this.turn)){
      this.aimTarget = foe; UI.showAim(this.sel, foe); this._steer=null; return;
    }
    // 工兵修理：點自己坦克
    if (this.sel.cls==="engineer" && foe && foe.side===this.playerSide && foe.cls==="tank"
        && dist(this.sel,foe)<60 && !this.selFired && foe.hp<foe.maxhp){
      foe.hp = Math.min(foe.maxhp, foe.hp+300);
      this.selFired = true;
      this.fx.push({type:"hitfx", x:foe.x,y:foe.y, dmg:"+300", t:0, heal:true});
      UI.log(`${this.sel.label} 修理了 ${foe.label}（+300）`);
      return;
    }
    // 點自己選中的部隊 → 立刻停止
    if (foe===this.sel){ this.moveTarget=null; this._steer=null; return; }
    // 空地：開始操控移動（按住拖曳持續操控、放開即停；快速輕點=走到該點）
    if (!foe){
      this.moveTarget = { x: clamp(x, this.sel.r, 960-this.sel.r), y: clamp(y, this.sel.r, 600-this.sel.r) };
      this._steer = { t: Date.now(), sx:x, sy:y, moved:false };
    }
  },

  /* 拖曳操控：手指/滑鼠移動時持續更新移動目標 */
  _pointerMove(clientX, clientY){
    if (this.state!=="act" || !this._steer || !this.sel) return;
    if (Net.connected && Net.myside!==this.turnOwner) return;
    const [x,y]=this._toWorld(clientX,clientY);
    if (Math.hypot(x-this._steer.sx, y-this._steer.sy)>10) this._steer.moved=true;
    this.moveTarget = { x: clamp(x,this.sel.r,960-this.sel.r), y: clamp(y,this.sel.r,600-this.sel.r) };
  },
  /* 放開：長按/拖曳 → 立刻停；快速輕點 → 保留目標走到定點 */
  _pointerUp(){
    if (!this._steer) return;
    const held=Date.now()-this._steer.t;
    if (!(held<260 && !this._steer.moved)) this.moveTarget=null;
    this._steer=null;
  },
  _toWorld(clientX, clientY){
    const r=this.canvas.getBoundingClientRect();
    return [ (clientX-r.left)*(this.canvas.width/r.width), (clientY-r.top)*(this.canvas.height/r.height) ];
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
    if (this.state==="enemy"){
      // 敵方回合逐幀單步會讓玩家枯等近一分鐘（見 lessons L-007）。
      // 每個可見幀推進多個固定子步，把牆鐘壓到數秒，動畫仍連續。
      for (let i=0;i<ENEMY_SUBSTEPS && this.state==="enemy"; i++) this.updateEnemy(0.033);
    }
    this.fx = this.fx.filter(f=>(f.t+=dt) < (f.type==="tracer"?0.25:f.type==="boom"?0.5:0.9));
    this.render();
  },

  inAny(rects,x,y){ return rects && rects.some(r=>ptInRect(x,y,r)); },
  isWater(x,y){ const m=this.map; return this.inAny(m.waters,x,y)||this.inAny(m.deepwaters,x,y)||this.inAny(m.shallows,x,y); },

  moveUnit(u, dx, dy, dt){
    let speed = u.domain==="air" ? 160 : u.domain==="sea" ? (u.big?60:95) : (u.cls==="tank"?70:100); // px/s
    if (this.state==="enemy") speed *= 2.5; // 敵方階段快轉（戰棋慣例，不影響規則）
    let nx = u.x + dx*speed*dt, ny = u.y + dy*speed*dt;
    nx = clamp(nx, u.r, 960-u.r); ny = clamp(ny, u.r, 600-u.r);
    // 作戰域地形限制（GDD/04 §1-2）
    if (u.domain==="sea"){
      if (!this.isWater(nx,ny)) return false;                                  // 艦艇不能上陸
    } else if (u.domain==="land"){
      if (this.inAny(this.map.waters,nx,ny)||this.inAny(this.map.deepwaters,nx,ny)) return false; // 陸軍只能涉淺灘
    }
    if (u.domain!=="air" && this.map.solids.some(s=>circleRectHit(nx,ny,u.r,s))){ // 空軍飛越地形
      if (!this.map.solids.some(s=>circleRectHit(nx,u.y,u.r,s))) ny=u.y;
      else if (!this.map.solids.some(s=>circleRectHit(u.x,ny,u.r,s))) nx=u.x;
      else return false;
    }
    // 空中單位不互相碰撞（不同高度）；地面/海面單位同域碰撞繞行
    if (u.domain!=="air"){
      const bump = (px,py)=> this.units.some(o=>o!==u&&o.alive&&o.domain===u.domain
        && Math.hypot(o.x-px,o.y-py)<o.r+u.r
        && Math.hypot(o.x-px,o.y-py) < Math.hypot(o.x-u.x,o.y-u.y));
      if (bump(nx,ny)){ // 撞到單位：沿軸滑行繞過
        if (!bump(nx,u.y)) ny=u.y;
        else if (!bump(u.x,ny)) nx=u.x;
        else return false;
      }
    }
    const moved = Math.hypot(nx-u.x, ny-u.y);
    let apCost = moved/3; // 1 AP = 3px（GDD/01 §2）
    if (u.domain==="land" && this.inAny(this.map.shallows,nx,ny)) apCost*=2; // 涉淺灘
    if (Combat.inBush(this.map,u) && NATIONS[u.nationId].trait.id==="tunnel_war") apCost*=0.5; // 越南
    if (u.ap < apCost) return false;
    u.ap -= apCost; u.x=nx; u.y=ny; u.facing=Math.atan2(dy,dx);
    if (this.state==="act" && u.side===this.playerSide){ this._fogT=(this._fogT||0)+dt; if(this._fogT>0.1){ this._fogT=0; Fog.recompute(); } }
    return moved>0;
  },

  updateAct(dt){
    const u=this.sel; if(!u||!u.alive){ this.endAction(); return; }
    let dx=0,dy=0;
    if (this.keys["w"]||this.keys["arrowup"]) dy-=1;
    if (this.keys["s"]||this.keys["arrowdown"]) dy+=1;
    if (this.keys["a"]||this.keys["arrowleft"]) dx-=1;
    if (this.keys["d"]||this.keys["arrowright"]) dx+=1;
    if (dx||dy) this.moveTarget=null;               // 鍵盤操作時取消點擊移動目標
    // 點擊移動：朝目標點前進（手機主要移動方式）
    if (!dx && !dy && this.moveTarget){
      const mx=this.moveTarget.x-u.x, my=this.moveTarget.y-u.y, d=Math.hypot(mx,my);
      if (d<8 || u.ap<2){ this.moveTarget=null; }
      else { dx=mx/d; dy=my/d; }
    }
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
    // 走不到位就別讓玩家等：2.5 秒模擬時間內未到位即放棄移動，直接進開火/結束
    if ((p.age+=dt) > 2.5) u.ap = 0;
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
  /* 一次性把靜態地形預渲染到離屏 canvas（每幀只需貼上，手機也順） */
  buildTerrain(m){
    const cv = this._bg = document.createElement("canvas");
    cv.width=960; cv.height=600; this._bgMap=m;
    const c = cv.getContext("2d");
    let seed=97; const rnd=()=>((seed=seed*16807%2147483647)/2147483647);
    c.fillStyle=m.ground; c.fillRect(0,0,960,600);
    // 草地紋理：深淺斑塊 + 草點
    for (let i=0;i<170;i++){ const x=rnd()*960,y=rnd()*600,r=8+rnd()*26;
      c.fillStyle="rgba(0,0,0,"+(0.03+rnd()*0.05).toFixed(3)+")"; c.beginPath(); c.ellipse(x,y,r,r*0.7,0,0,7); c.fill(); }
    for (let i=0;i<260;i++){ const x=rnd()*960,y=rnd()*600;
      c.strokeStyle="rgba(255,255,255,0.045)"; c.beginPath(); c.moveTo(x,y); c.lineTo(x+rnd()*3-1.5,y-2-rnd()*3); c.stroke(); }
    // 水域：帶波紋
    const water=(list,base,wave)=>{ for(const w of (list||[])){
      c.fillStyle=base; c.fillRect(w.x,w.y,w.w,w.h);
      c.strokeStyle=wave; c.lineWidth=1;
      for(let y=w.y+6;y<w.y+w.h;y+=10){ c.beginPath();
        for(let x=w.x;x<w.x+w.w;x+=8){ c.lineTo(x, y+Math.sin((x+y)*0.12)*1.6); } c.stroke(); }
    }};
    water(m.deepwaters,"#244b66","rgba(130,175,205,0.10)");
    water(m.waters,"#356782","rgba(155,200,225,0.13)");
    water(m.shallows,"#6ea3b8","rgba(225,242,250,0.18)");
    for(const w of (m.reefs||[])){ c.fillStyle="#5a5f52"; c.fillRect(w.x,w.y,w.w,w.h);
      c.fillStyle="#6b7062"; c.beginPath(); c.arc(w.x+w.w*0.5,w.y+w.h*0.5,w.w*0.35,0,7); c.fill();
      c.strokeStyle="#3f4438"; c.strokeRect(w.x,w.y,w.w,w.h); }
    // 樹叢：陰影 + 三層樹冠
    for(const b of m.bushes){
      c.fillStyle="rgba(0,0,0,0.18)"; c.beginPath(); c.ellipse(b.x+5,b.y+7,b.r,b.r*0.7,0,0,7); c.fill();
      c.fillStyle="#2f5228"; c.beginPath(); c.arc(b.x,b.y,b.r,0,7); c.fill();
      c.fillStyle="#3c6b32"; c.beginPath(); c.arc(b.x-b.r*0.22,b.y-b.r*0.22,b.r*0.72,0,7); c.fill();
      c.fillStyle="#4e8540"; c.beginPath(); c.arc(b.x-b.r*0.33,b.y-b.r*0.33,b.r*0.42,0,7); c.fill();
    }
    // 沙包：一排麻袋
    for(const s of m.sandbags){
      const horiz=s.w>=s.h, n=Math.max(2,Math.round((horiz?s.w:s.h)/14));
      for(let i=0;i<n;i++){ const cx=horiz? s.x+(i+0.5)*s.w/n : s.x+s.w/2,
        cy=horiz? s.y+s.h/2 : s.y+(i+0.5)*s.h/n;
        c.fillStyle="#b09761"; c.beginPath(); c.ellipse(cx,cy,8,6,0,0,7); c.fill();
        c.strokeStyle="#7d6a44"; c.stroke();
        c.strokeStyle="rgba(80,66,40,0.5)"; c.beginPath(); c.moveTo(cx-5,cy); c.lineTo(cx+5,cy); c.stroke(); }
    }
    // 建築：陰影 + 屋頂高光 + 窗
    for(const s of m.solids){
      c.fillStyle="rgba(0,0,0,0.22)"; c.fillRect(s.x+4,s.y+5,s.w,s.h);
      c.fillStyle="#6e6a63"; c.fillRect(s.x,s.y,s.w,s.h);
      c.fillStyle="#807b72"; c.fillRect(s.x,s.y,s.w,6);
      c.strokeStyle="#403d38"; c.lineWidth=2; c.strokeRect(s.x,s.y,s.w,s.h); c.lineWidth=1;
      c.fillStyle="rgba(28,28,32,0.5)";
      for(let wx=s.x+8;wx<s.x+s.w-8;wx+=18) for(let wy=s.y+12;wy<s.y+s.h-8;wy+=18) c.fillRect(wx,wy,7,9);
    }
  },

  render(){
    const c=this.ctx, m=this.map;
    c.clearRect(0,0,960,600);
    if (this.state==="menu"||!m) return;
    if (!this._bg || this._bgMap!==m) this.buildTerrain(m);
    c.drawImage(this._bg, 0, 0);
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
    for (const u of this.units) if(u.alive && u.side!==this.playerSide) this.drawUnit(c,u); // 敵方（迷霧內才現形）
    Fog.render(c);                                                                          // 迷霧遮罩
    for (const u of this.units) if(u.alive && u.side===this.playerSide) this.drawUnit(c,u);  // 我方（永遠可見）
    if (this.state==="act" && this.sel){ // 射程圈
      c.strokeStyle="rgba(255,255,255,0.35)"; c.setLineDash([4,6]);
      c.beginPath(); c.arc(this.sel.x,this.sel.y,this.sel.weapon.range,0,7); c.stroke(); c.setLineDash([]);
    }
    for (const f of this.fx) this.drawFx(c,f);
    this.drawHint(c);
  },

  /* 畫面底部操作提示條（新手引導） */
  drawHint(c){
    let tip = null;
    if (this.state==="deploy") tip = "部署：① 右側面板點兵種 → ② 點藍色虛線框內放置 → ③ 點「開始戰鬥」";
    else if (this.state==="cmd") tip = "你的回合：點選我方部隊（藍圈）下令行動　·　打完點「結束回合」交給敵方";
    else if (this.state==="act") tip = "行動中：按住拖曳移動、放開即停（或點自己停）　·　點敵人開火　·　點「結束行動」";
    else if (this.state==="enemy") tip = "敵方行動中…";
    if (!tip) return;
    c.fillStyle="rgba(0,0,0,0.6)"; c.fillRect(0,572,960,28);
    c.fillStyle="#ffe9a8"; c.font="14px 'Microsoft JhengHei',sans-serif"; c.textAlign="center"; c.textBaseline="middle";
    c.fillText(tip, 480, 587); c.textBaseline="alphabetic";
  },

  /* 敵方單位是否對我方可見（迷霧 + 視線 + 隱蔽） */
  enemyVisible(u){
    if (this.state==="deploy") return true;   // 部署階段看得到敵軍佈署，才好佈署對策
    if (Fog.enabled && !Fog.visibleAt(u.x,u.y)) return false;
    return this.units.some(o=>o.alive && o.side===this.playerSide && Combat.canSee(this.map,o,u,this.turn));
  },

  drawUnit(c,u){
    const isPlayer = u.side===this.playerSide;
    if (!isPlayer && !this.enemyVisible(u)) return;
    const hidden = Combat.inBush(this.map,u) && !u.revealed && isPlayer;
    c.globalAlpha = hidden ? 0.6 : 1;
    Sprites.tryLoad(u);
    Sprites.drawBody(c,u,isPlayer);
    // 血條/AP條
    const w = u.big?34 : u.cls==="tank"?32 : 22, x0=u.x-w/2, y0=u.y-u.r-9;
    c.fillStyle="#222"; c.fillRect(x0,y0,w,3);
    c.fillStyle=u.hp>u.maxhp*0.3?"#4fd05e":"#e04b3a"; c.fillRect(x0,y0,w*clamp(u.hp/u.maxhp,0,1),3);
    if (this.sel===u){ c.fillStyle="#222"; c.fillRect(x0,y0+4,w,3);
      c.fillStyle="#ffd83d"; c.fillRect(x0,y0+4,w*clamp(u.ap/u.maxap,0,1),3);
      c.strokeStyle="#ffd83d"; c.lineWidth=2; c.beginPath(); c.arc(u.x,u.y,u.r+6,0,7); c.stroke(); c.lineWidth=1;
    }
    c.globalAlpha=1;
  },

  drawFx(c,f){
    if (f.type==="tracer"){
      const k=1-f.t/0.25;
      c.strokeStyle=(f.hit?"rgba(255,225,120,":"rgba(210,210,210,")+k.toFixed(2)+")"; c.lineWidth=2;
      c.beginPath(); c.moveTo(f.x1,f.y1); c.lineTo(f.x2,f.y2); c.stroke(); c.lineWidth=1;
      if (f.t<0.08){ c.fillStyle="rgba(255,220,120,"+(1-f.t/0.08).toFixed(2)+")"; c.beginPath(); c.arc(f.x1,f.y1,4,0,7); c.fill(); }
      if (f.hit && f.t<0.12){ c.strokeStyle="rgba(255,200,80,"+(1-f.t/0.12).toFixed(2)+")";
        for(let a=0;a<4;a++){ const ang=a*1.57+(f.x2%3); c.beginPath(); c.moveTo(f.x2,f.y2); c.lineTo(f.x2+Math.cos(ang)*5,f.y2+Math.sin(ang)*5); c.stroke(); } }
    } else if (f.type==="boom"){
      const k=f.t/0.5;
      c.strokeStyle="rgba(255,160,60,"+((1-k)*0.8).toFixed(2)+")"; c.lineWidth=3;
      c.beginPath(); c.arc(f.x,f.y,f.r*(0.4+k*1.3),0,7); c.stroke(); c.lineWidth=1;
      c.fillStyle="rgba(255,120,40,"+((1-k)*0.75).toFixed(2)+")"; c.beginPath(); c.arc(f.x,f.y,f.r*(0.5+k*0.4),0,7); c.fill();
      c.fillStyle="rgba(255,235,150,"+(1-k).toFixed(2)+")"; c.beginPath(); c.arc(f.x,f.y,f.r*0.3*(1-k),0,7); c.fill();
      for(let i=0;i<7;i++){ const ang=i*0.9+(f.x%6), d=f.r*(0.5+k*1.6);
        c.fillStyle="rgba(90,70,55,"+(1-k).toFixed(2)+")"; c.beginPath(); c.arc(f.x+Math.cos(ang)*d,f.y+Math.sin(ang)*d,2,0,7); c.fill(); }
      c.fillStyle="rgba(70,70,70,"+((1-k)*0.35).toFixed(2)+")"; c.beginPath(); c.arc(f.x,f.y-k*10,f.r*(0.6+k),0,7); c.fill();
    } else if (f.type==="hitfx"){
      c.fillStyle=f.heal?"#5eff8a":"#ffe08a"; c.font="bold 13px sans-serif"; c.textAlign="center";
      c.globalAlpha=1-f.t/0.9; c.fillText(f.heal?f.dmg:"-"+f.dmg, f.x, f.y-14-f.t*22); c.globalAlpha=1;
    } else if (f.type==="death"){
      const k=1-f.t/0.9;
      c.fillStyle="rgba(80,80,80,"+(k*0.4).toFixed(2)+")"; c.beginPath(); c.arc(f.x,f.y-f.t*12,10+f.t*10,0,7); c.fill();
      c.strokeStyle="rgba(50,50,50,"+k.toFixed(2)+")"; c.beginPath();
      c.moveTo(f.x-8,f.y-8); c.lineTo(f.x+8,f.y+8); c.moveTo(f.x+8,f.y-8); c.lineTo(f.x-8,f.y+8); c.stroke();
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
