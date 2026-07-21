/* ============================================================
 * game.js — 主狀態機、迴圈、輸入、渲染
 * 狀態：menu → deploy → cmd(指令模式) ⇄ act(行動模式) → enemy → over
 * 規則權威：GDD/01。本檔只實作，不自創規則。
 * ============================================================ */
"use strict";

const ENEMY_TIME_SCALE = 1; // moveUnit 已對敵軍加速 2.5×；此處不再疊加時間跳步

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
  budgetLeft:0, deployCls:null, deployNamed:false,
  keys:{}, lastTs:0, over:null, hintIdx:0, _pickCycle:null,

  /* ---------- 生命週期 ---------- */
  init(){
    this.canvas = document.getElementById("game");
    this.ctx = this.canvas.getContext("2d");
    const editable=e=>e.target&&(/^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName)||e.target.isContentEditable);
    window.addEventListener("keydown", e=>{ const k=e.key.toLowerCase();
      if(this.state==="act"&&!editable(e)&&k==="c"&&!e.repeat){e.preventDefault();this.toggleTerrainAction();return;}
      if(this.state==="act"&&!editable(e)&&["arrowup","arrowdown","arrowleft","arrowright"].includes(k))e.preventDefault();
      if(!editable(e))this.keys[k]=true;
    });
    window.addEventListener("keyup",e=>{ this.keys[e.key.toLowerCase()]=false; });
    window.addEventListener("blur",()=>this._clearControls());
    document.addEventListener("visibilitychange",()=>{
      if(document.hidden)this._clearControls();
      else{this.lastTs=performance.now();if(typeof Engine3D!=="undefined")Engine3D._at=performance.now();}
    });
    this.canvas.addEventListener("mousedown", e=>{ this._mouseDown=e.button===0; this.onClick(e); });
    window.addEventListener("mousemove", e=>{ if(this._mouseDown) this._pointerMove(e.clientX,e.clientY); });
    window.addEventListener("mouseup", ()=>{ this._mouseDown=false; this._pointerUp(); });
    // 手機觸控：單指=點擊/拖曳；雙指=捏合縮放（縮放時取消移動操控）
    const pinchD = e => Math.hypot(e.touches[0].clientX-e.touches[1].clientX, e.touches[0].clientY-e.touches[1].clientY);
    this.canvas.addEventListener("touchstart", e=>{ if(e.cancelable) e.preventDefault(); this._touch=true;
      if (e.touches.length>=2){ this._pinch=pinchD(e); this._steer3d=null; this._mapDrag=null; return; }
      const t=e.changedTouches[0]; if(t) this.onClickXY(t.clientX,t.clientY,0,"touch"); }, {passive:false});
    this.canvas.addEventListener("touchmove", e=>{ if(e.cancelable) e.preventDefault();
      if (e.touches.length>=2){ const d=pinchD(e); if(this._pinch){ Camera3D.setZoom(Camera3D.zoom*this._pinch/d); } this._pinch=d; return; }
      const t=e.changedTouches[0]; if(t) this._pointerMove(t.clientX,t.clientY); }, {passive:false});
    this.canvas.addEventListener("touchend", e=>{ if(e.cancelable) e.preventDefault(); if(e.touches.length<2) this._pinch=null; this._pointerUp(); }, {passive:false});
    this.canvas.addEventListener("touchcancel", e=>{ if(e.cancelable) e.preventDefault(); this._pinch=null; this._steer3d=null; this._mapDrag=null; }, {passive:false});
    this.canvas.addEventListener("contextmenu", e=>e.preventDefault());
    // 滾輪縮放（桌機）
    this.canvas.addEventListener("wheel", e=>{ e.preventDefault(); Camera3D.setZoom(Camera3D.zoom*(e.deltaY>0?1.1:0.9)); }, {passive:false});
    this._initJoystick();
    if (typeof Camera3D !== "undefined") Camera3D.selfTest(); // P1 投影校正（GDD/07），console 應見 PASS
    if (typeof Engine3D !== "undefined") Engine3D.init();      // 真 3D（GDD/08）；失敗採 fail-closed，不得偽 3D 降級
    UI.showMenu();
    // 可重現的瀏覽器發布閘門情境；只組合正式公開流程，不建立第二套規則。
    const qaScenario=new URLSearchParams(location.search).get("qaScenario");
    if(qaScenario==="lst")setTimeout(()=>{
      this.startBattle("beach","china","taiwan",0);
      this.aiDeploy(0);
      if(!this.units.some(u=>u.side===0&&u.cls==="lst"))this.units.push(makeUnit("china","lst",0,200,300));
      if(!this.units.some(u=>u.side===0&&u.cls==="rifleman"))this.units.push(makeUnit("china","rifleman",0,500,240));
      if(!this.units.some(u=>u.side===0&&u.cls==="assault"))this.units.push(makeUnit("china","assault",0,500,360));
      this.finishDeploy();
      const ship=this.units.find(u=>u.side===0&&u.cls==="lst");
      if(ship){ship.x=270*(this.map._k||1);ship.y=300*(this.map._k||1);this.enterAction(ship);UI.refreshActBar();}
    },0);
    if(qaScenario==="all17")setTimeout(()=>{
      this.startBattle("harbor","china","taiwan",0);
      this.units=[];
      const infantry=["rifleman","assault","mg","mortar","sniper","at","engineer","specops","sam"];
      infantry.forEach((cls,i)=>this.units.push(makeUnit("china",cls,0,(245+(i%5)*105)*(this.map._k||1),(65+Math.floor(i/5)*105)*(this.map._k||1))));
      this.units.push(makeUnit("china","tank",0,760*(this.map._k||1),210*(this.map._k||1)));
      ["destroyer","missileboat","lst","submarine"].forEach((cls,i)=>this.units.push(makeUnit("china",cls,0,(170+i*205)*(this.map._k||1),470*(this.map._k||1))));
      ["fighter","attacker","gunship"].forEach((cls,i)=>this.units.push(makeUnit("china",cls,0,(340+i*160)*(this.map._k||1),335*(this.map._k||1))));
      this.state="cmd";this.turnOwner=0;this.beginTurn(0);Camera3D.setZoom(.5);UI.showBattle();UI.log("QA：17 兵種真 3D 實載檢查");
    },0);
    if(qaScenario==="missileboat")setTimeout(()=>{
      this.startBattle("harbor","china","taiwan",0);this.units=[];
      const k=this.map._k||1,boat=makeUnit("china","missileboat",0,180*k,500*k),target=makeUnit("taiwan","destroyer",1,280*k,500*k);
      this.units=[boat,target];this.state="cmd";this.turnOwner=0;this.beginTurn(0);this.enterAction(boat);this.aimTarget=target;Camera3D.setZoom(.6);UI.showBattle();UI.refreshActBar();
    },0);
    if(qaScenario==="riflemove")setTimeout(()=>{
      this.startBattle("plain","china","taiwan",0);this.units=[];
      const k=this.map._k||1,rifleman=makeUnit("china","rifleman",0,300*k,520*k),target=makeUnit("taiwan","rifleman",1,390*k,520*k);
      this.units=[rifleman,target];this.state="cmd";this.turnOwner=0;this.beginTurn(0);this.enterAction(rifleman);Camera3D.setZoom(.6);UI.showBattle();UI.refreshActBar();
    },0);
    const raf=ts=>{if(!document.hidden)this.loop(ts);else this.lastTs=ts;requestAnimationFrame(raf);};
    requestAnimationFrame(raf);
  },

  _clearControls(){
    this.keys={};this._mouseDown=false;this._steer3d=null;this._mapDrag=null;this._joy=null;
    if(this._joyKnob)this._joyKnob.style.transform="translate(-50%,-50%)";
  },

  startBattle(mapId, atkNation, defNation, playerSide){
    if (typeof Sfx!=="undefined") Sfx.bgm("battle");
    this._charAssigned = {};                 // 劇情模式具名角色每場重新指派
    this.map = MAPS[mapId];
    this.enrichMap(this.map); this._bg = null;
    this.nations[0]=atkNation; this.nations[1]=defNation;
    this.playerSide = playerSide;
    this.units=[]; this.fx=[]; this.turn=1; this.over=null; this.hintIdx=0;
    if (typeof Camera3D!=="undefined") Camera3D.resetView();   // 縮放/平移歸位
    Fog.reset();
    this.budgetLeft = this.map.budget;
    this.deployCls = null; this.deployNamed = false;
    this.aiDeploy(1-playerSide);
    this.prepareLSTCargo(1-playerSide);
    this.state="deploy";
    UI.showDeploy();
    if (this.map.tutorial) UI.hint(this.map.hints[0]);
  },

  /* ---------- 戰鬥中存檔（§C⑧ 2026-07-21）：單位皆純資料，整包 JSON 進 localStorage ---------- */
  saveBattle(){
    if (this.state !== "cmd" || Net.connected || this.over){ UI.log("僅能在我方指令階段存檔"); return false; }
    const snap = {
      v: 1, at: Date.now(),
      mapId: this.map.id, nations: [this.nations[0], this.nations[1]], playerSide: this.playerSide,
      storyChapter: this.storyChapter || null, turn: this.turn, cp: this.cp, cpMax: this.cpMax,
      charAssigned: this._charAssigned || {}, eventsFired: this._eventsFired || {},
      wavesDone: this._wavesDone || {}, silence: !!this._silenceBroken, stealth: !!this._stealthBusted,
      units: this.units, explored: [...Fog.explored]
    };
    try { localStorage.setItem("bf_battle_save", JSON.stringify(snap)); UI.log("💾 戰況已存檔（主選單可續戰）"); return true; }
    catch(e){ UI.log("存檔失敗：" + e.message); return false; }
  },
  hasBattleSave(){ try { return !!localStorage.getItem("bf_battle_save"); } catch(e){ return false; } },
  clearBattleSave(){ try { localStorage.removeItem("bf_battle_save"); } catch(e){} },
  loadBattle(){
    let snap = null;
    try { snap = JSON.parse(localStorage.getItem("bf_battle_save")); } catch(e){}
    if (!snap || !MAPS[snap.mapId]) return false;
    if (typeof Sfx!=="undefined") Sfx.bgm("battle");
    this.map = MAPS[snap.mapId]; this.enrichMap(this.map); this._bg = null;
    this.nations[0] = snap.nations[0]; this.nations[1] = snap.nations[1];
    this.playerSide = snap.playerSide; this.storyChapter = snap.storyChapter;
    this.units = snap.units; this.fx = []; this.turn = snap.turn; this.over = null; this.sel = null;
    this.cp = snap.cp; this.cpMax = snap.cpMax;
    this._charAssigned = snap.charAssigned; this._eventsFired = snap.eventsFired;
    this._wavesDone = snap.wavesDone; this._silenceBroken = snap.silence; this._stealthBusted = snap.stealth;
    let maxId = 0; for (const u of this.units) maxId = Math.max(maxId, u.id || 0);
    UNIT_SEQ = maxId + 1;                              // 防 id 撞號
    if (typeof Camera3D !== "undefined") Camera3D.resetView();
    Fog.reset();
    for (const k of (snap.explored || [])) Fog.explored.add(k);
    Fog.recompute();
    this.state = "cmd";
    UI.showBattle(); UI.log(`📂 已讀取戰況：第 ${this.turn} 回合`);
    return true;
  },

  /* 地圖允許的作戰域（預設純陸戰） */
  mapAllow(){ return this.map.allow || ["land"]; },

  /* 我方部署區是否有陸地可站（§C⑧ 回歸發現：ch8 攻方部署區全水面，步兵卡不該出現） */
  deployZoneHasLand(){
    if (this._dzLandMap === this.map) return this._dzLand;
    this._dzLandMap = this.map;
    const z = this.map.deploy && this.map.deploy[this.playerSide];
    if (!z){ this._dzLand = true; return true; }
    const probe = { cls:"rifleman", domain:"land", mobility:"foot" };
    for (let x = z.x + 10; x < z.x + z.w; x += 24)
      for (let y = z.y + 10; y < z.y + z.h; y += 24)
        if (this.canOccupyTerrain(probe, x, y)){ this._dzLand = true; return true; }
    this._dzLand = false; return false;
  },

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
    let perDomain = {
      land:["tank","mg","at","sniper","assault","rifleman","rifleman","engineer","sam"],
      sea:["destroyer","missileboat","submarine","lst"],
      air:["fighter","attacker","gunship"]
    };
    // 劇情火力對等（規則03部 2026-07-21 使用者裁定）：敵軍武力鏡射玩家解鎖進度——
    // 載具未解鎖章節敵軍也不得投放（第1章出坦克＝不合邏輯前科）；
    // 敵步兵數上限＝玩家已解鎖具名隊員數+1，避免前期人數輾壓。
    const chN = this.storyChapter;
    if (chN && typeof VEHICLE_UNLOCK !== "undefined"){
      const vOk = cls => !VEHICLE_UNLOCK[cls] || VEHICLE_UNLOCK[cls] <= chN;
      const namedN = (typeof CHARACTERS !== "undefined")
        ? Object.values(CHARACTERS).filter(c=>(c.unlockCh||1)<=chN).length : 9;
      perDomain = {
        land: perDomain.land.filter(vOk).slice(0, namedN + 1),
        sea:  perDomain.sea.filter(vOk),
        air:  perDomain.air.filter(vOk)
      };
    }
    const doms = allow.filter(d=>perDomain[d] && perDomain[d].length);
    const quota = this.map.budget / doms.length;
    for (const dom of doms){
      let b = quota;
      for (const cls of perDomain[dom]){
        const c = unitCost(nation, cls);
        if (c > b) continue;
        const spot = this.findDeploySpot(cls, zone);
        if (!spot) continue;
        b -= c;
        this.units.push(makeUnit(nation, cls, side, spot.x, spot.y));
      }
    }
    // 王牌敵將（§C⑥ 2026-07-21，VC 慣例）：指定章節把一名敵軍升格為具名敵將——
    // HP×1.6／攻×1.25，擊殺者領雙倍經驗；標籤前綴☠，戰報可辨。
    const ace = chN && STORY[chN-1].ace;
    if (ace){
      const pool = this.units.filter(u => u.side === side && u.alive);
      const pick = pool.find(u => u.cls === ace.cls) || pool[0];
      if (pick){
        pick.isAce = true;
        pick.maxhp = Math.round(pick.maxhp * 1.6); pick.hp = pick.maxhp;
        pick.weapon.atk = Math.round(pick.weapon.atk * 1.25);
        pick.label = "☠" + ace.name + "｜" + pick.label;
      }
    }
  },

  /* 在部署區找一個符合兵種移動輪廓的生成點 */
  findDeploySpot(cls, zone){
    const base = CLASS_BASE[cls], probe = { cls, domain:base.domain||"land", mobility:base.mobility||base.domain||"land" };
    for (let t=0;t<100;t++){
      const x = zone.x + 20 + Math.random()*Math.max(1,zone.w-40);
      const y = zone.y + 20 + Math.random()*Math.max(1,zone.h-40);
      if (this.map.solids.some(s=>circleRectHit(x,y,18,s))) continue;
      if (this.units.some(o=>o.alive&&Math.hypot(o.x-x,o.y-y)<o.r+20)) continue;
      if (!this.canOccupyTerrain(probe,x,y)) continue;
      return {x,y};
    }
    return null;
  },

  finishDeploy(){
    if (!this.units.some(u=>u.side===this.playerSide)){ UI.log("至少部署一名單位"); return; }
    this.prepareLSTCargo(this.playerSide);
    if (Net.connected){ this.mpReady(); return; }
    this.state="cmd";
    Fog.recompute();
    this.beginTurn(this.playerSide);
    UI.showBattle();
    if (this.map.tutorial) UI.hint(this.map.hints[1]);
  },

  /* LST v1 預載：依 GDD/04 §6，每艘優先裝載突擊兵／步槍兵，最多兩名。
   * 載員自戰場陣列移除，避免被看見、瞄準、碰撞或計入視線；卸載時還原同一物件。 */
  prepareLSTCargo(side){
    const lsts=this.units.filter(u=>u.alive&&u.side===side&&u.cls==="lst");
    for(const ship of lsts){
      ship.carried=ship.carried||[];
      if(ship.carried.length)continue;
      const priority={assault:0,rifleman:1};
      const candidates=this.units.filter(u=>u!==ship&&u.alive&&u.side===side&&u.domain==="land"&&u.cls!=="tank")
        .sort((a,b)=>(priority[a.cls]??5)-(priority[b.cls]??5)||dist(a,ship)-dist(b,ship));
      for(const passenger of candidates.slice(0,2)){
        ship.carried.push(passenger);
        const idx=this.units.indexOf(passenger);if(idx>=0)this.units.splice(idx,1);
      }
      if(ship.carried.length&&side===this.playerSide)UI.log(`${ship.label} 已預載 ${ship.carried.map(u=>u.label).join("、")}`);
    }
  },

  _unloadSpot(ship, passenger, ordinal){
    const m=this.map,scale=m._k||1;
    for(let ring=30*scale;ring<=72*scale;ring+=10*scale){
      for(let i=0;i<16;i++){
        const angle=ship.facing+(i+ordinal*5)*Math.PI/8,x=ship.x+Math.cos(angle)*ring,y=ship.y+Math.sin(angle)*ring;
        if(x<passenger.r||y<passenger.r||x>(m.w||960)-passenger.r||y>(m.h||600)-passenger.r)continue;
        if(this.inAny(m.deepwaters,x,y)||this.inAny(m.waters,x,y)||this.inAny(m.shallows,x,y))continue;
        if(!this.canOccupyTerrain(passenger,x,y))continue;
        if((m.solids||[]).some(s=>circleRectHit(x,y,passenger.r,s)))continue;
        if(this.units.some(o=>o.alive&&Math.hypot(o.x-x,o.y-y)<o.r+passenger.r+3))continue;
        return {x,y};
      }
    }
    return null;
  },

  canUnloadLST(ship){
    if(!ship||ship.cls!=="lst"||!(ship.carried||[]).length)return false;
    const nearRect=r=>{const nx=clamp(ship.x,r.x,r.x+r.w),ny=clamp(ship.y,r.y,r.y+r.h);return Math.hypot(ship.x-nx,ship.y-ny)<=48*(this.map._k||1);};
    if(!(this.map.shallows||[]).some(nearRect))return false;
    return ship.carried.some((p,i)=>!!this._unloadSpot(ship,p,i));
  },

  unloadLST(){
    const ship=this.sel;
    if(this.state!=="act"||!this.canUnloadLST(ship)){UI.hint("登陸艦須靠近淺灘，且相鄰陸地要有足夠卸載空間");return false;}
    const landed=[],remaining=[];
    for(const passenger of ship.carried){
      const spot=this._unloadSpot(ship,passenger,landed.length);
      if(!spot){remaining.push(passenger);continue;}
      passenger.x=spot.x;passenger.y=spot.y;passenger.facing=ship.facing;passenger.ap=passenger.maxap;
      passenger.crouched=false;passenger.terrainAction=null;this.units.push(passenger);landed.push(passenger);
    }
    ship.carried=remaining;
    ship.unloadingUntil=performance.now()+1600;
    UI.log(`${ship.label} 放下艦艏跳板，卸載 ${landed.map(u=>u.label).join("、")}`);
    Fog.recompute();UI.refreshActBar();if(Net.connected)Net.sendState();return landed.length>0;
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
    Fog.recompute();
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
    this.budgetLeft = this.map.budget; this.deployCls = null; this.deployNamed = false; this._charAssigned = {}; this._eventsFired = {}; this._wavesDone = {}; this._silenceBroken = false; this._stealthBusted = false;
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

  _restoreNetUnit(su, fallbackSide){
    const side = Number.isInteger(su.side) ? su.side : fallbackSide;
    const u = makeUnit(su.nationId, su.cls, side, su.x, su.y);
    if(Number.isFinite(su.id))u.id=su.id;
    if(Number.isFinite(su.hp))u.hp=su.hp;
    if(Number.isFinite(su.ap))u.ap=su.ap;
    if(Number.isFinite(su.facing))u.facing=su.facing;
    if(Number.isFinite(su.actedCount))u.actedCount=su.actedCount;
    if(typeof su.alive==="boolean")u.alive=su.alive;
    if(typeof su.revealed==="boolean")u.revealed=su.revealed;
    u.crouched=!!su.crouched;
    u.terrainAction=su.terrainAction||null;
    u.carried=(su.carried||[]).map(passenger=>this._restoreNetUnit(passenger,side));
    return u;
  },

  _maxUnitIdDeep(units){
    let maxid=0;
    const visit=list=>{for(const u of list||[]){if(Number.isFinite(u.id)&&u.id>maxid)maxid=u.id;visit(u.carried);}};
    visit(units);return maxid;
  },
  // 主機權威合併雙方部隊、開打並廣播
  _mpHostStart(){
    let maxid = 0; for (const u of this.units) if (u.id>maxid) maxid=u.id;
    const opp = this._mpGuestUnits.map(su=>this._restoreNetUnit(su,1));
    const reassignIds=list=>{for(const u of list){u.id=++maxid;reassignIds(u.carried||[]);}};
    reassignIds(opp);
    this.units = this.units.filter(u=>u.side===0).concat(opp);
    this.turnOwner = 0; this.playerSide = 0; this.state = "cmd";
    Fog.recompute(); this.beginTurn(0);
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
    this.units = d.units.map(su=>this._restoreNetUnit(su,su.side));
    const maxid=this._maxUnitIdDeep(this.units);
    UNIT_SEQ = Math.max(UNIT_SEQ||1, maxid+1);
    this.sel=null; this.aimTarget=null; this.moveTarget=null;
    this.state = this.over ? "over" : "cmd";
    Fog.recompute();
    if (this.over) UI.showEnd(); else UI.showBattle();
    UI.refreshHud();
  },

  beginTurn(side){
    this.cp = this.cpMax = this.cpFor(side);
    this.germanyTankDiscountUsed = false;
    for (const u of this.units){ if(u.side===side){ u.actedCount=0; } u._iceTimer=0; }
    Fog.recompute();
    UI.refreshHud();
    this.checkSpecialRules(side);
    this.checkStoryEvents(side);
  },

  /* 章節特殊規則（GDD/09）：增援波次／靜默滲透 */
  storySpecial(){ return this.storyChapter && STORY[this.storyChapter-1].special || null; },
  storySpawnEnemies(n, classes){
    const es = 1 - this.playerSide, zone = this.map.deploy[es];
    let added = 0, tries = 0;
    while (added < n && tries < 300){
      tries++;
      const x = zone.x + Math.random() * zone.w, y = zone.y + Math.random() * zone.h;
      const cls = classes[added % classes.length], base = CLASS_BASE[cls];
      const probe = { cls, domain: base.domain, mobility: base.mobility || base.domain };
      if (this.map.solids.some(s2 => circleRectHit(x, y, 14, s2))) continue;
      if (!this.canOccupyTerrain(probe, x, y)) continue;
      this.units.push(makeUnit(this.nations[es], cls, es, x, y));
      added++;
    }
    if (added){ Fog.recompute(); UI.refreshHud(); }
    return added;
  },
  checkSpecialRules(side){
    const sp = this.storySpecial();
    if (!sp || side !== this.playerSide) return;
    if (sp.type === "stealth"){
      const kills = this.units.filter(u => u.side !== this.playerSide && !u.alive).length;
      if (kills > sp.limit && !this._stealthBusted){
        this._stealthBusted = true;
        const got = this.storySpawnEnemies(5, ["assault", "mg", "rifleman", "specops"]);
        UI.log(`⚠ 行動曝光！擊殺超過 ${sp.limit}——敵軍大批增援（${got} 個單位）`);
      }
    }
    // 限時追擊（§C④ 2026-07-21）：期限內未分勝負＝目標逃脫，判敗
    if (sp.type === "timelimit" && this.turn > sp.turns && !this.over){
      this.over = { winner: 1 - this.playerSide, why: `超過 ${sp.turns} 回合期限，敵縱隊逃出走廊` };
      this.state = "over"; UI.showEnd(); return;
    }
    if (sp.type === "timelimit" && this.turn === sp.turns - 4){
      UI.log(`⏳ 剩 4 回合！敵縱隊即將逃出走廊——加快追擊`);
    }
    if (sp.type === "waves" && sp.turns.includes(this.turn)){
      this._wavesDone = this._wavesDone || {};
      if (!this._wavesDone[this.turn]){
        this._wavesDone[this.turn] = true;
        const got = this.storySpawnEnemies(4, ["tank", "assault", "mg", "rifleman"]);
        UI.log(`⚠ 敵軍增援抵達！（第 ${this.turn} 回合波次：${got} 個單位）`);
        if (typeof Sfx !== "undefined") Sfx.play("boom");
      }
    }
  },
  onPlayerFired(){
    const sp = this.storySpecial();
    if (sp && sp.type === "silence" && this.turn <= sp.turns && !this._silenceBroken){
      this._silenceBroken = true;
      const got = this.storySpawnEnemies(3, ["assault", "mg", "rifleman"]);
      UI.log(`⚠ 靜默被打破！港區警報大作——敵軍增援 ${got} 個單位`);
    }
  },

  /* 戰中事件（GDD/09）：章節 events 於指定回合開始時觸發對白 */
  checkStoryEvents(side){
    if (!this.storyChapter || side !== this.playerSide) return;
    const ch = STORY[this.storyChapter - 1];
    if (!ch || !ch.events) return;
    this._eventsFired = this._eventsFired || {};
    for (let i = 0; i < ch.events.length; i++){
      const ev = ch.events[i];
      if (this._eventsFired[i]) continue;
      if (ev.turn && this.turn !== ev.turn) continue;
      this._eventsFired[i] = true;
      UI.showDialog(ev.dialog, () => { UI.el("menu").style.display = "none"; });
      break;
    }
  },

  onOwnHalf(u){
    if (!this.map) return false;
    const mid = 480;
    return u.side===0 ? u.x<mid : u.x>mid;
  },

  /* ---------- 輸入 ---------- */
  onClick(e){ this.onClickXY(e.clientX, e.clientY, e.button||0, "mouse"); },
  onClickXY(clientX, clientY, button, pointerType){
    const rect = this.canvas.getBoundingClientRect();
    const x = (clientX-rect.left) * (this.canvas.width/rect.width);
    const y = (clientY-rect.top) * (this.canvas.height/rect.height);
    if (this.state==="menu"||!this.map) return;
    pointerType = pointerType || "mouse";
    // 只讀取最後一幀真正顯示的相機；輸入時不得瞬移相機，否則畫面與命中座標會錯位。
    const w = (typeof Camera3D!=="undefined") ? Camera3D.unproject(x,y) : [x,y];
    // 敵方回合也可自由平移鏡頭（2026-07-21 使用者回饋：看不到就自己拉畫面）
    if (this.state==="enemy"){
      if (button!==0) return;
      this._mapDrag = { sx:x, sy:y, cx:clientX, cy:clientY, wx:null, wy:null,
        pick:null, pointerType, moved:false, t:Date.now() };
      return;
    }
    if (this.state==="deploy" || this.state==="cmd"){
      const pick = this.pickUnitAtScreen(x,y,this.playerSide,pointerType);
      if (button===2){
        if (this.state==="deploy"){
          if (pick) this.removeDeployedUnit(pick);
          else if (w) this.deployClick(w[0],w[1],2);
        }
        return;
      }
      if(button!==0)return;
      // 按下先記錄：輕點=選兵/部署、按住拖曳=平移視角（俯瞰可看清敵陣）
      this._mapDrag = { sx:x, sy:y, cx:clientX, cy:clientY, wx:(w?w[0]:null), wy:(w?w[1]:null),
        pick, pointerType, moved:false, t:Date.now() };
      return;
    }
    if (this.state==="act"){
      // 行動模式相對操控：按下先記步（拖曳=轉向/前進、快速輕點=瞄準/停）
      if(button!==0)return;
      if (Net.connected && Net.myside!==this.turnOwner) return;
      const pick = this.pickUnitAtScreen(x,y,null,pointerType);
      this._steer3d = { sx:x, sy:y, cx:clientX, cy:clientY, wx:(w?w[0]:null), wy:(w?w[1]:null),
        pick, pointerType, fwd:0, turn:0, moved:false, t:Date.now() };
      return;
    }
  },

  /* 可見 3D 模型的螢幕命中：空軍不再錯投到 wz=0 地面。
   * 回傳按下當下命中的單位，pointerup 不重新追逐已移動的模型。 */
  pickUnitAtScreen(sx,sy,side=null,pointerType="mouse"){
    if (typeof Camera3D==="undefined") return null;
    const rect=this.canvas.getBoundingClientRect();
    const kx=this.canvas.width/Math.max(1,rect.width), ky=this.canvas.height/Math.max(1,rect.height);
    const touch=pointerType==="touch", minW=(touch?48:36)*kx, minH=(touch?48:36)*ky;
    const padX=(touch?10:6)*kx, padY=(touch?10:6)*ky, hits=[];
    for (const u of this.units){
      if (!u.alive || (side!==null && u.side!==side)) continue;
      if (u.side!==this.playerSide && !this.enemyVisible(u)) continue;
      let b = (typeof Engine3D!=="undefined" && Engine3D.ok) ? Engine3D.unitScreenBounds(u,Camera3D) : null;
      if (!b){
        const alt=u.domain==="air"?52:u.domain==="sea"?0:
          ((typeof Engine3D!=="undefined"&&Engine3D.ok)?Engine3D.heightAt(u.x,u.y):0);
        const h=u.cls==="tank"?18:u.domain==="sea"?14:u.domain==="air"?14:22;
        const p=Camera3D.project(u.x,u.y,alt+h*0.5);
        if (!p) continue;
        const hw=(u.domain==="air"?15:u.domain==="sea"?(u.big?26:20):u.cls==="tank"?18:7)*p.scale;
        const hh=Math.max(5,h*p.scale*0.55);
        b={left:p.sx-hw,top:p.sy-hh,right:p.sx+hw,bottom:p.sy+hh,depth:p.depth};
      }
      const rawW=Math.max(1,b.right-b.left), rawH=Math.max(1,b.bottom-b.top);
      const cx=(b.left+b.right)/2, cy=(b.top+b.bottom)/2;
      const halfW=Math.max(rawW/2,minW/2)+padX, halfH=Math.max(rawH/2,minH/2)+padY;
      if (sx<cx-halfW || sx>cx+halfW || sy<cy-halfH || sy>cy+halfH) continue;
      const raw=sx>=b.left&&sx<=b.right&&sy>=b.top&&sy<=b.bottom;
      const norm=((sx-cx)/halfW)**2+((sy-cy)/halfH)**2;
      hits.push({u,raw,norm,depth:b.depth||Infinity});
    }
    hits.sort((a,b)=>(b.raw-a.raw)||(a.depth-b.depth)||(a.norm-b.norm));
    if(!hits.length){this._pickCycle=null;return null;}
    let chosen=hits[0].u;
    const now=Date.now(),key=hits.map(h=>h.u.id).join(","),prev=this._pickCycle;
    if(hits.length>1&&prev&&now-prev.t<900&&Math.hypot(sx-prev.sx,sy-prev.sy)<12&&prev.key===key){
      const at=hits.findIndex(h=>h.u.id===prev.id);chosen=hits[(at+1+hits.length)%hits.length].u;
    }
    this._pickCycle={sx,sy,t:now,key,id:chosen.id};
    return chosen;
  },

  deployClick(x,y,btn){
    const zone = this.map.deploy[this.playerSide];
    if (btn===2){ // 右鍵移除
      const u = this.unitAt(x,y,this.playerSide);
      if (u) this.removeDeployedUnit(u);
      return;
    }
    if (!this.deployCls) { UI.log("先在右側選擇兵種"); return; }
    if (this.storyChapter){                                   // 名冊制（GDD/09）
      const vu = (typeof VEHICLE_UNLOCK !== "undefined") && VEHICLE_UNLOCK[this.deployCls];
      if (vu && vu > this.storyChapter){ UI.log(`該載具第 ${vu} 章解鎖`); return; }
      const spB = this.storySpecial();
      if (spB && spB.type === "ban" && spB.cls === this.deployCls){ UI.log("本章此兵種不可部署（劇情限制）"); return; }
      if (this.deployNamed){
        this._charAssigned = this._charAssigned || {};
        if (this._charAssigned[this.deployCls]){ UI.log("該隊員已出戰（具名角色每場僅一次）"); return; }
      }
    }
    if (!ptInRect(x,y,zone)) { UI.log("只能部署在我方藍框區域內"); return; }
    if (this.map.solids.some(s=>circleRectHit(x,y,14,s))) return;
    const base = CLASS_BASE[this.deployCls], dom = base.domain;
    const probe = { cls:this.deployCls, domain:dom, mobility:base.mobility||dom };
    if (!this.canOccupyTerrain(probe,x,y)){ UI.log("此兵種無法進入該地形"); return; }
    const c = unitCost(this.nations[this.playerSide], this.deployCls);
    if (c > this.budgetLeft){ UI.log("點數不足"); return; }
    if (this.deployCls==="tank" && this.units.filter(u=>u.side===this.playerSide&&u.cls==="tank").length>=2){ UI.log("坦克每隊最多 2 輛"); return; }
    if (CLASS_BASE[this.deployCls].big && this.units.filter(u=>u.side===this.playerSide&&CLASS_BASE[u.cls].big).length>=2){ UI.log("大型艦每隊最多 2 艘"); return; }
    if (dom==="air" && this.units.filter(u=>u.side===this.playerSide&&u.domain==="air").length>=4){ UI.log("空軍每隊最多 4 架"); return; }
    this.budgetLeft -= c;
    const nu = makeUnit(this.nations[this.playerSide], this.deployCls, this.playerSide, x, y);
    this.units.push(nu);
    if (typeof assignCharacter === "function"){
      const chr = assignCharacter(nu, this.deployNamed);
      if (chr){ UI.log(`★${chr.name}：「${chr.line}」（${chr.trait.desc}）`); this.deployNamed = false; this.deployCls = null; }
    }
    UI.refreshDeploy();
  },

  removeCharAssign(u){ // 部署階段移除具名單位時，允許重新指派該兵種角色
    if (u.charName && this._charAssigned) delete this._charAssigned[u.cls];
  },

  removeDeployedUnit(u){
    const i=this.units.indexOf(u);
    if (i<0 || u.side!==this.playerSide) return;
    this.removeCharAssign(u);
    this.units.splice(i,1); this.budgetLeft+=u.cost; UI.refreshDeploy();
  },

  unitAt(x,y,side=null){
    return this.units.find(u=>u.alive && (side===null||u.side===side) && Math.hypot(u.x-x,u.y-y)<=u.r+6);
  },

  cmdClick(x,y){
    if (Net.connected && Net.myside!==this.turnOwner){ UI.log("等待對方行動…"); return; }
    const u = this.unitAt(x,y,this.playerSide);
    if (u) this.cmdUnit(u);
  },

  cmdUnit(u){
    if (!u || !u.alive || u.side!==this.playerSide) return;
    if (Net.connected && Net.myside!==this.turnOwner){ UI.log("等待對方行動…"); return; }
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
    this.sel = u; this.selFired = false; this.state="act"; this.moveTarget = null; this._steer3d = null; this._actUiT=0;
    if (typeof Sfx!=="undefined") Sfx.play("select");
    UI.showCharCard && UI.showCharCard(u);
    let mult = Math.pow(0.7, u.actedCount);
    if (NATIONS[u.nationId].trait.id==="rapid_reaction" && this.turn===1) mult *= 1.2; // 法國
    u.ap = u.maxap * mult;
    u.actedCount++;
    for (const e of this.units) e._iceTimer = 0;
    UI.refreshHud();
    if (this.map.tutorial && this.hintIdx<2){ this.hintIdx=2; UI.hint(this.map.hints[2]); }
  },

  endAction(){
    this.sel=null;this.aimTarget=null;this.moveTarget=null;this._clearControls();UI.hideAim();
    UI.hideCharCard && UI.hideCharCard();
    this.state="cmd";
    this.checkVictory();
    if (Net.connected && !this.over) Net.sendState();
    if (!this.over && this.cp<=0) this.endTurn();
    UI.refreshHud();
  },

  endTurn(){
    this.sel=null;this.aimTarget=null;this._clearControls();UI.hideAim();
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
    if (foe){ this.actUnitClick(foe); return; }
    // 空地：開始操控移動（按住拖曳持續操控、放開即停；快速輕點=走到該點）
    this.moveTarget = { x: clamp(x, this.sel.r, (this.map.w||960)-this.sel.r), y: clamp(y, this.sel.r, (this.map.h||600)-this.sel.r) };
    this._steer = { t: Date.now(), sx:x, sy:y, moved:false };
  },

  actUnitClick(foe){
    if (!foe || !foe.alive || !this.sel) return;
    if (foe && foe.side!==this.playerSide && Combat.canSee(this.map,this.sel,foe,this.turn)){
      this.aimTarget = foe; UI.showAim(this.sel, foe); this._steer=null; return;
    }
    if(foe.side!==this.playerSide){UI.hint("目前單位與目標之間沒有可用射線");return;}
    // 工兵修理：點自己坦克
    if (this.sel.cls==="engineer" && foe && foe.side===this.playerSide && foe.cls==="tank"
        && dist(this.sel,foe)<60 && !this.selFired && foe.hp<foe.maxhp){
      foe.hp = Math.min(foe.maxhp, foe.hp+300);
      this.selFired = true;
      this.fx.push({type:"hitfx", x:foe.x,y:foe.y, dmg:"+300", t:0, heal:true});
      UI.log(`${this.sel.label} 修理了 ${foe.label}（+300）`);
      UI.refreshActBar();
      return;
    }
    // 點自己選中的部隊 → 立刻停止
    if (foe===this.sel){ this.moveTarget=null; this._steer=null; return; }
  },

  /* 拖曳操控：手指/滑鼠移動時持續更新移動目標 */
  /* 行動模式相對操控：拖曳的垂直分量=前進/後退、水平分量=轉向（沿用相機 yaw，穩定不甩） */
  _pointerMove(clientX, clientY){
    // 俯瞰（指令/部署）拖曳 → 平移視角
    if (this._mapDrag){
      const [cx,cy]=this._toWorld(clientX,clientY);
      const dx = cx - this._mapDrag.sx, dy = cy - this._mapDrag.sy;
      const slop=this._mapDrag.pointerType==="touch"?12:6;
      if (Math.hypot(clientX-this._mapDrag.cx,clientY-this._mapDrag.cy) > slop) this._mapDrag.moved = true;
      if (this._mapDrag.moved){
        Camera3D.panBy(dx, dy, this.map);
        this._mapDrag.sx = cx; this._mapDrag.sy = cy;
      }
      return;
    }
    if (this.state!=="act" || !this._steer3d || !this.sel) return;
    if (Net.connected && Net.myside!==this.turnOwner) return;
    const [cx,cy]=this._toWorld(clientX,clientY);           // 螢幕(canvas)座標
    const dxs = cx - this._steer3d.sx, dys = this._steer3d.sy - cy; // 上為正
    const slop=this._steer3d.pointerType==="touch"?12:6;
    const drag=Math.hypot(clientX-this._steer3d.cx,clientY-this._steer3d.cy);
    if(!this._steer3d.moved&&drag<=slop){this._steer3d.fwd=0;this._steer3d.turn=0;return;}
    if(drag>slop)this._steer3d.moved=true;
    this._steer3d.fwd  = clamp(dys/70, -1, 1);              // 拖上→前進、拖下→後退
    this._steer3d.turn = clamp(dxs/110, -1, 1);             // 拖右→右轉、拖左→左轉
  },
  /* 放開：未越 dead-zone=瞄準/停（按住多久都有效）；拖曳=結束操控 */
  _pointerUp(){
    // 俯瞰：輕點才觸發原本的選兵/部署
    if (this._mapDrag){
      const d = this._mapDrag; this._mapDrag = null;
      if (!d.moved){
        if (this.state==="deploy" && d.wx!=null) this.deployClick(d.wx, d.wy, 0);
        else if (this.state==="cmd") d.pick ? this.cmdUnit(d.pick) : (d.wx!=null&&this.cmdClick(d.wx,d.wy));
      }
      return;
    }
    if (!this._steer3d) return;
    if (!this._steer3d.moved){
      // 輕點：點到敵人立繪 → 瞄準；否則視為停止
      const foe=this._steer3d.pick;
      if (foe && this.sel) this.actUnitClick(foe);
    }
    this._steer3d = null;   // 放開即停
  },
  _toWorld(clientX, clientY){
    const r=this.canvas.getBoundingClientRect();
    return [ (clientX-r.left)*(this.canvas.width/r.width), (clientY-r.top)*(this.canvas.height/r.height) ];
  },

  /* 虛擬搖桿（觸控裝置、行動模式才顯示）：上=前進/下=後退、左右=轉向。
     事件 stopPropagation → 不影響畫面點擊（瞄準/停止）。 */
  _initJoystick(){
    const joy=document.createElement("div");
    joy.id="joy";
    joy.style.cssText="position:absolute;left:14px;bottom:14px;width:112px;height:112px;border-radius:50%;"+
      "background:rgba(20,28,20,0.35);border:2px solid rgba(255,255,255,0.28);display:none;z-index:6;touch-action:none;";
    const knob=document.createElement("div");
    knob.style.cssText="position:absolute;left:50%;top:50%;width:48px;height:48px;border-radius:50%;"+
      "background:rgba(255,255,255,0.38);border:1.5px solid rgba(255,255,255,0.5);transform:translate(-50%,-50%);";
    joy.appendChild(knob);
    document.getElementById("stage").appendChild(joy);
    this._joyEl=joy;this._joyKnob=knob;this._joy=null;
    const setJoy=(t)=>{
      const r=joy.getBoundingClientRect(), cx=r.left+r.width/2, cy=r.top+r.height/2;
      let dx=t.clientX-cx, dy=t.clientY-cy;
      const d=Math.hypot(dx,dy)||1, max=r.width/2-8;
      if(d>max){ dx*=max/d; dy*=max/d; }
      knob.style.transform=`translate(calc(-50% + ${dx}px), calc(-50% + ${dy}px))`;
      this._joy={ fwd: clamp(-dy/(max*0.8),-1,1), turn: clamp(dx/(max*0.8),-1,1) };
    };
    const end=e=>{ if(e.cancelable) e.preventDefault(); e.stopPropagation(); this._joy=null; knob.style.transform="translate(-50%,-50%)"; };
    joy.addEventListener("touchstart",e=>{ if(e.cancelable) e.preventDefault(); e.stopPropagation(); setJoy(e.changedTouches[0]); },{passive:false});
    joy.addEventListener("touchmove", e=>{ if(e.cancelable) e.preventDefault(); e.stopPropagation(); setJoy(e.changedTouches[0]); },{passive:false});
    joy.addEventListener("touchend",end,{passive:false});
    joy.addEventListener("touchcancel",end,{passive:false});
  },

  /* 玩家在瞄準面板按下開火 */
  playerFire(part){
    if (this.selFired || !this.aimTarget) return;
    const t = this.aimTarget;
    if (this.sel && this.sel.charName && typeof Sfx !== "undefined" && Math.random() < 0.5)
      Sfx.voice(this.sel.cls, "atk");                       // 具名角色開火戰吼（節流在 Sfx.voice）
    this.onPlayerFired();                                   // 章節特殊規則：靜默滲透檢查
    this.sel.facing = Math.atan2(t.y - this.sel.y, t.x - this.sel.x); // 合理化：開火必轉身面向目標（槍口對人）
    const ev = Combat.fire(this.map, this.sel, t, part);
    this.pushFx(ev);
    this.selFired = true;
    this.aimTarget = null; UI.hideAim();
    UI.log(`${this.sel.label}（${this.sel.weaponName}）開火`);
    UI.refreshActBar();
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

  /* 動作合理化（dept-12 2026-07-21 使用者通則裁定）：步兵開火先「舉槍」再出彈——
   * 開火當下立即起手 shoot 動畫，彈道/音效/傷害演出整批延遲 0.3s（負 t 起算），
   * 讓子彈在動畫舉到位時才離膛。載具/艦炮無舉槍動作，維持即時。 */
  pushFx(ev){
    const raised = new Set();
    const firstTracer = ev.find(e => e.type === "tracer" && /rifle|carbine|lmg|sniper|rocket|mortar/.test(e.w || ""));
    // 延遲量依開火者 shoot 動畫實際長度計（38% 時點離膛）；查不到動畫＝0（載具即時）
    const RAISE = firstTracer && typeof Engine3D !== "undefined" && Engine3D.ok
      ? (Engine3D.shootDelayAt(firstTracer.x1, firstTracer.y1) || 0.28) : 0; // 查不到動畫（模型熱替換瞬間）退 0.28s，步兵永不瞬發
    const needRaise = RAISE > 0;
    for(const e of ev){
      e.t = needRaise ? -RAISE : 0;
      this.fx.push(e);
      if (needRaise && e.type === "tracer" && !raised.has(e.x1 + "," + e.y1)){
        raised.add(e.x1 + "," + e.y1); e._preRaised = true;
        if (typeof Engine3D !== "undefined" && Engine3D.ok) Engine3D._tryShootAnim(e.x1, e.y1);
      }
      if (typeof Sfx!=="undefined"){
        if (needRaise) setTimeout(() => Sfx.event(e), RAISE * 1000);
        else Sfx.event(e);
      }
    }
  },

  /* ---------- 主迴圈 ---------- */
  loop(ts){
    const dt = Math.min(0.05,(ts-this.lastTs)/1000||0.016); this.lastTs=ts;
    if (this.state==="act")   this.updateAct(dt);
    if (this.state==="enemy"){
      // 依實際 dt 快轉，但每個可見幀只產生一個位置，避免一幀跳過 6 個中間狀態。
      this.updateEnemy(dt*ENEMY_TIME_SCALE);
    }
    this.fx = this.fx.filter(f=>(f.t+=dt) < (f.type==="tracer"?0.25:f.type==="boom"?0.5:0.9));
    if (this._joyEl) this._joyEl.style.display = (this.state==="act" && this._touch) ? "block" : "none";
    this.render(dt);
  },

  inAny(rects,x,y){ return rects && rects.some(r=>ptInRect(x,y,r)); },
  isWater(x,y){ const m=this.map; return this.inAny(m.waters,x,y)||this.inAny(m.deepwaters,x,y)||this.inAny(m.shallows,x,y); },

  /* 兵種地形輪廓（GDD/04 §2c）：null=不可進入，倍率=AP 成本。 */
  terrainProfile(u){
    const key = u.mobility || (CLASS_BASE[u.cls] && CLASS_BASE[u.cls].mobility) || u.domain || "foot";
    return TERRAIN_MOBILITY[key] || TERRAIN_MOBILITY.foot;
  },

  terrainMoveFactor(u,x,y){
    if ((u.mobility||u.domain)==="air" || u.domain==="air") return 1;
    const m=this.map, p=this.terrainProfile(u);
    const mobility=u.mobility||(CLASS_BASE[u.cls]&&CLASS_BASE[u.cls].mobility)||u.domain||"foot";
    let baseKey="ground";
    if (this.inAny(m.deepwaters,x,y)) baseKey="deepwater";
    else if (this.inAny(m.waters,x,y)) baseKey="water";
    else if (this.inAny(m.shallows,x,y)) baseKey="shallow";
    let f=p[baseKey];
    if (f==null) return Infinity;
    const layers=[];
    if ((m.hills||[]).some(h=>Math.hypot(h.x-x,h.y-y)<=h.r)) layers.push("hill");
    if (this.inAny(m.trenches,x,y)) layers.push("trench");
    if ((m.craters||[]).concat(m.foxholes||[]).some(c=>Math.hypot(c.x-x,c.y-y)<=c.r)) layers.push("crater");
    if (this.inAny(m.wires,x,y)) layers.push("wire");
    if ((m.bushes||[]).some(b=>Math.hypot(b.x-x,b.y-y)<=b.r)) layers.push("bush");
    for (const key of layers){ if (p[key]==null) return Infinity; f*=p[key]; }
    if(this.inAny(m.roadblocks,x,y))f*=mobility==="engineer"?1.08:mobility==="tracked"?2.35:mobility==="heavy"?1.45:1.25;
    if(this.inAny(m.tanktraps,x,y)){
      if(mobility==="tracked")return Infinity;
      f*=mobility==="engineer"?1.0:mobility==="heavy"?1.3:1.12;
    }
    const onRoad=(m.roads||[]).some(r=>{
      const vx=r.x2-r.x1,vy=r.y2-r.y1,den=vx*vx+vy*vy||1;
      const t=clamp(((x-r.x1)*vx+(y-r.y1)*vy)/den,0,1);
      return Math.hypot(x-(r.x1+vx*t),y-(r.y1+vy*t))<=r.w*.5;
    });
    if(onRoad)f*=mobility==="tracked"?.72:mobility==="scout"?.86:mobility==="foot"?.92:.96;
    return f;
  },

  canOccupyTerrain(u,x,y){ return Number.isFinite(this.terrainMoveFactor(u,x,y)); },

  /* Terrain Action（GDD/01 §5a）：地面人員須主動蹲伏才取得掩體／高草隱蔽。 */
  terrainActionAt(u){
    if (!u || u.domain!=="land" || u.cls==="tank") return null;
    const m=this.map; if(!m) return null;
    if ((m.bunkers||[]).some(r=>ptInRect(u.x,u.y,r))) return {id:"bunker",label:"碉堡",factor:0.3};
    if ((m.trenches||[]).some(r=>ptInRect(u.x,u.y,r))) return {id:"trench",label:"壕溝",factor:0.4};
    if ((m.foxholes||[]).some(h=>Math.hypot(u.x-h.x,u.y-h.y)<=h.r)) return {id:"foxhole",label:"散兵坑",factor:0.5};
    if ((m.craters||[]).some(h=>Math.hypot(u.x-h.x,u.y-h.y)<=h.r)) return {id:"crater",label:"彈坑",factor:0.5};
    if ((m.sandbags||[]).some(sb=>{
      const nx=clamp(u.x,sb.x,sb.x+sb.w),ny=clamp(u.y,sb.y,sb.y+sb.h);
      return Math.hypot(u.x-nx,u.y-ny)<=28;
    })) return {id:"sandbag",label:"沙包",factor:0.5};
    if ((m.solids||[]).some(s=>{
      const nx=clamp(u.x,s.x,s.x+s.w),ny=clamp(u.y,s.y,s.y+s.h);
      return !ptInRect(u.x,u.y,s)&&Math.hypot(u.x-nx,u.y-ny)<=24;
    })) return {id:"building",label:"建築外牆",factor:0.65};
    if ((m.bushes||[]).some(b=>Math.hypot(u.x-b.x,u.y-b.y)<=b.r)) return {id:"bush",label:"高草",factor:1};
    return null;
  },

  toggleTerrainAction(){
    const u=this.sel; if(this.state!=="act"||!u||!u.alive)return false;
    if(u.crouched){u.crouched=false;u.terrainAction=null;UI.log(`${u.label} 站起`);}
    else{
      const action=this.terrainActionAt(u);
      if(!action){UI.hint("靠近沙包或建築外牆，或進入高草、壕溝、散兵坑、彈坑、碉堡後才能蹲伏");return false;}
      u.crouched=true;u.terrainAction=action.id;
      if(action.id==="bush")u.revealed=false;
      UI.log(`${u.label} 在${action.label}蹲伏掩蔽`);
    }
    Fog.recompute();UI.refreshActBar();if(Net.connected)Net.sendState();return true;
  },

  moveUnit(u, dx, dy, dt, setFacing=true){
    let speed = u.domain==="air" ? 160 : u.domain==="sea" ? (u.big?60:95) : (u.cls==="tank"?70:100); // px/s
    speed *= (this.map._k||1);              // 大地圖等比加速，牆鐘節奏不變
    if (this.state==="enemy") speed *= 2.5; // 敵方階段快轉（戰棋慣例，不影響規則）
    let nx = u.x + dx*speed*dt, ny = u.y + dy*speed*dt;
    nx = clamp(nx, u.r, (this.map.w||960)-u.r); ny = clamp(ny, u.r, (this.map.h||600)-u.r);
    // 資料化地形限制（GDD/04 §2c）；斜貼邊界時沿合法單軸滑行。
    const terrainBlocked=(px,py)=>!this.canOccupyTerrain(u,px,py);
    if(terrainBlocked(nx,ny)){
      if(!terrainBlocked(nx,u.y))ny=u.y;
      else if(!terrainBlocked(u.x,ny))nx=u.x;
      else return false;
    }
    if (u.domain!=="air" && this.map.solids.some(s=>circleRectHit(nx,ny,u.r,s))){ // 空軍飛越地形
      if (!this.map.solids.some(s=>circleRectHit(nx,u.y,u.r,s))) ny=u.y;
      else if (!this.map.solids.some(s=>circleRectHit(u.x,ny,u.r,s))) nx=u.x;
      else return false;
    }
    const mobility=u.mobility||(CLASS_BASE[u.cls]&&CLASS_BASE[u.cls].mobility)||u.domain;
    if(mobility==="tracked"&&(this.map.tanktraps||[]).some(s=>circleRectHit(nx,ny,u.r,s))){
      if(!(this.map.tanktraps||[]).some(s=>circleRectHit(nx,u.y,u.r,s)))ny=u.y;
      else if(!(this.map.tanktraps||[]).some(s=>circleRectHit(u.x,ny,u.r,s)))nx=u.x;
      else return false;
    }
    if (u.domain==="land"){
      // 樹木＝真障礙（樹幹圓形碰撞，沿軸滑行繞過）
      const trunk = (px,py)=> (this.map.trees||[]).some(t=> Math.hypot(t.x-px,t.y-py) < Math.max(5,t.r*0.3)+u.r );
      if (trunk(nx,ny)){
        if (!trunk(nx,u.y)) ny=u.y;
        else if (!trunk(u.x,ny)) nx=u.x;
        else return false;
      }
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
    let moved = Math.hypot(nx-u.x, ny-u.y);
    if(moved<=0.0001)return false;
    let apCost = moved/(3*(this.map._k||1)); // 1 AP = 3px；大地圖依 _k 折算維持節奏（data-maps 檔頭）
    apCost *= this.terrainMoveFactor(u,nx,ny);
    if (Combat.inBush(this.map,u) && NATIONS[u.nationId].trait.id==="tunnel_war") apCost*=0.5; // 越南
    if(u.ap<apCost&&apCost>0){const ratio=clamp(u.ap/apCost,0,1);nx=u.x+(nx-u.x)*ratio;ny=u.y+(ny-u.y)*ratio;moved*=ratio;apCost=u.ap;}
    u.ap=Math.max(0,u.ap-apCost);u.x=nx;u.y=ny;if(setFacing)u.facing=Math.atan2(dy,dx);
    if(moved>0&&u.crouched){u.crouched=false;u.terrainAction=null;}
    if (this.state==="act" && u.side===this.playerSide){ this._fogT=(this._fogT||0)+dt; if(this._fogT>0.1){ this._fogT=0; Fog.recompute(); } }
    return moved>0;
  },

  updateAct(dt){
    const u=this.sel; if(!u||!u.alive){ this.endAction(); return; }
    // 相對相機操控（GDD/07 P3）：前進沿面向、轉向改面向 → 相機 yaw 跟著平滑，不左右亂甩
    let fwd=0, turn=0;
    if (this.keys["w"]||this.keys["arrowup"])   fwd+=1;
    if (this.keys["s"]||this.keys["arrowdown"]) fwd-=1;
    if (this.keys["a"]||this.keys["arrowleft"]) turn-=1;
    if (this.keys["d"]||this.keys["arrowright"])turn+=1;
    if (this._steer3d){ fwd+=this._steer3d.fwd; turn+=this._steer3d.turn; }
    if (this._joy){ fwd+=this._joy.fwd; turn+=this._joy.turn; }   // 虛擬搖桿
    fwd=clamp(fwd,-1,1); turn=clamp(turn,-1,1);
    if (turn) u.facing += turn * 2.2 * dt;          // 轉向速率 2.2 rad/s
    if (Math.abs(fwd)>0.02){
      const moved = this.moveUnit(u, Math.cos(u.facing)*fwd, Math.sin(u.facing)*fwd, dt, false); // false=不由移動覆寫面向
      if (moved){
        this.pushFx(Combat.interceptTick(this.map,u,dt)); // 敵方警戒射擊
        if (!u.alive || u.hp<=0){ this.endAction(); return; }
        if (this.map.tutorial && this.hintIdx<3 && u.ap<u.maxap*0.6){ this.hintIdx=3; UI.hint(this.map.hints[3]); }
      }
    }
    this._actUiT=(this._actUiT||0)+dt;
    if (this._actUiT>=0.1){ this._actUiT%=0.1; UI.refreshActBar(); }
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
      p.fired=false; p.didFire=false; p.stuck=0; p.age=0; p.detourT=0;
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
        u.facing = Math.atan2(target.y - u.y, target.x - u.x);   // 敵軍開火同樣先轉身面向目標
        this.pushFx(Combat.fire(this.map,u,target,p.part||"body"));
        p.didFire=true;
        UI.log(`敵 ${u.label}（${u.weaponName}）開火`);
      }
      p.fired=true;
    }
    const terrain=this.terrainActionAt(u);
    if(terrain){u.crouched=true;u.terrainAction=terrain.id;if(terrain.id==="bush"&&!p.didFire)u.revealed=false;}
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
    const W=m.w||960, H=m.h||600, AR=(W*H)/(960*600);   // 面積倍率：紋理數量等比
    const cv = this._bg = document.createElement("canvas");
    cv.width=W; cv.height=H; this._bgMap=m;
    const c = cv.getContext("2d");
    let seed=97; const rnd=()=>((seed=seed*16807%2147483647)/2147483647);
    c.fillStyle=m.ground; c.fillRect(0,0,W,H);
    // 草地紋理：深淺斑塊 + 草點
    for (let i=0;i<170*AR;i++){ const x=rnd()*W,y=rnd()*H,r=8+rnd()*26;
      c.fillStyle="rgba(0,0,0,"+(0.03+rnd()*0.05).toFixed(3)+")"; c.beginPath(); c.ellipse(x,y,r,r*0.7,0,0,7); c.fill(); }
    for (let i=0;i<260*AR;i++){ const x=rnd()*W,y=rnd()*H;
      c.strokeStyle="rgba(255,255,255,0.045)"; c.beginPath(); c.moveTo(x,y); c.lineTo(x+rnd()*3-1.5,y-2-rnd()*3); c.stroke(); }
    // 大片地貌色斑帶（乾草/深綠/土斑），打破單色感
    for (let i=0;i<7*AR;i++){ const x=rnd()*W,y=rnd()*H,r=60+rnd()*120,a=rnd()*7;
      const hues=["rgba(150,140,80,0.10)","rgba(60,80,40,0.12)","rgba(130,105,70,0.10)","rgba(160,155,110,0.09)"];
      c.fillStyle=hues[i%hues.length]; c.beginPath(); c.ellipse(x,y,r,r*(0.45+rnd()*0.4),a,0,7); c.fill(); }
    // 基地間泥土道路（僅陸戰圖）：帶寬度抖動的土色帶 + 車轍
    if ((m.allow||["land"]).includes("land") && m.bases && m.bases.length===2 && !m.deepwaters){
      const A=m.bases[0], B=m.bases[1], mx=(A.x+B.x)/2+(rnd()*120-60), my=(A.y+B.y)/2+(rnd()*160-80);
      const pt=t=>{ const ix=(1-t)*(1-t)*A.x+2*(1-t)*t*mx+t*t*B.x, iy=(1-t)*(1-t)*A.y+2*(1-t)*t*my+t*t*B.y; return [ix,iy]; };
      c.strokeStyle="rgba(122,100,66,0.85)"; c.lineCap="round";
      for(let s=0;s<=40;s++){ const [x1,y1]=pt(s/40),[x2,y2]=pt(Math.min(1,(s+1)/40));
        c.lineWidth=14+rnd()*8; c.beginPath(); c.moveTo(x1,y1); c.lineTo(x2,y2); c.stroke(); }
      c.strokeStyle="rgba(80,64,40,0.5)"; c.lineWidth=2;   // 車轍兩道
      for(const off of [-4,4]){ c.beginPath();
        for(let s=0;s<=40;s++){ const [x,y]=pt(s/40); s?c.lineTo(x,y+off):c.moveTo(x,y+off); } c.stroke(); }
    }
    // 碎石群
    for (let i=0;i<26*AR;i++){ const x=rnd()*W,y=rnd()*H,r=1.5+rnd()*3;
      c.fillStyle=`rgba(${110+rnd()*40|0},${110+rnd()*35|0},${100+rnd()*30|0},0.8)`;
      c.beginPath(); c.arc(x,y,r,0,7); c.fill();
      c.fillStyle="rgba(0,0,0,0.15)"; c.beginPath(); c.arc(x+1,y+1,r*0.8,0,7); c.fill(); }
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
    // 陣地工事（GDD/04 §2b）
    for(const t of (m.craters||[])){ // 彈坑：焦黑凹坑
      c.fillStyle="rgba(0,0,0,0.28)"; c.beginPath(); c.ellipse(t.x,t.y,t.r,t.r*0.8,0,0,7); c.fill();
      c.fillStyle="#5c4d3a"; c.beginPath(); c.ellipse(t.x,t.y,t.r*0.8,t.r*0.62,0,0,7); c.fill();
      c.fillStyle="#3a2f22"; c.beginPath(); c.ellipse(t.x,t.y,t.r*0.45,t.r*0.34,0,0,7); c.fill();
    }
    for(const t of (m.trenches||[])){ // 壕溝：凹陷土溝＋護牆
      c.fillStyle="#6a5c44"; c.fillRect(t.x-2,t.y-2,t.w+4,t.h+4);           // 護牆(土堆)
      c.fillStyle="#3f3626"; c.fillRect(t.x,t.y,t.w,t.h);                    // 溝底(陰影)
      c.fillStyle="#4e4531"; c.fillRect(t.x+2,t.y+2,Math.max(0,t.w-4),Math.max(0,t.h-4));
    }
    for(const t of (m.foxholes||[])){ // 散兵坑：小圓坑
      c.fillStyle="#6a5c44"; c.beginPath(); c.arc(t.x,t.y,t.r+2,0,7); c.fill();
      c.fillStyle="#3f3626"; c.beginPath(); c.arc(t.x,t.y,t.r,0,7); c.fill();
    }
    for(const t of (m.wires||[])){ // 鐵絲網：X 交錯鐵刺
      c.strokeStyle="rgba(60,60,60,0.85)"; c.lineWidth=1.5;
      const horiz=t.w>=t.h, len=horiz?t.w:t.h, cxm=t.x+t.w/2, cym=t.y+t.h/2;
      for(let s=0;s<len;s+=10){ const px=horiz?t.x+s:cxm, py=horiz?cym:t.y+s;
        c.beginPath(); c.moveTo(px-5,py-5); c.lineTo(px+5,py+5); c.moveTo(px+5,py-5); c.lineTo(px-5,py+5); c.stroke(); }
      c.strokeStyle="rgba(40,40,40,0.7)"; c.beginPath();
      if(horiz){ c.moveTo(t.x,cym); c.lineTo(t.x+t.w,cym); } else { c.moveTo(cxm,t.y); c.lineTo(cxm,t.y+t.h); } c.stroke();
    }
    // 草叢（隱蔽帶，可走入）：一片高草——底色斑 + 大量草葉（戰場女武神式）
    for(const b of (m.bushes||[])){
      c.fillStyle="rgba(40,74,32,0.5)"; c.beginPath(); c.ellipse(b.x,b.y,b.r,b.r*0.8,0,0,7); c.fill();
      c.fillStyle="rgba(66,110,48,0.55)"; c.beginPath(); c.ellipse(b.x,b.y,b.r*0.78,b.r*0.6,0,0,7); c.fill();
      let bs=b.x*7+b.y; const brnd=()=>((bs=bs*16807%2147483647)/2147483647);
      for(let i=0;i<Math.round(b.r*1.6);i++){
        const a=brnd()*6.283, rr=brnd()*b.r*0.9, gx=b.x+Math.cos(a)*rr, gy=b.y+Math.sin(a)*rr*0.8;
        c.strokeStyle=`rgba(${96+brnd()*40|0},${140+brnd()*40|0},${70+brnd()*30|0},0.8)`; c.lineWidth=1.3;
        c.beginPath(); c.moveTo(gx,gy); c.quadraticCurveTo(gx+brnd()*4-2, gy-4-brnd()*5, gx+brnd()*6-3, gy-7-brnd()*6); c.stroke();
      }
    }
    // 樹木（真障礙）：貼圖上畫樹影+樹幹根部；樹冠由 3D billboard 畫
    for(const t of (m.trees||[])){
      c.fillStyle="rgba(0,0,0,0.20)"; c.beginPath(); c.ellipse(t.x+4,t.y+5,t.r*0.9,t.r*0.55,0,0,7); c.fill();
      c.fillStyle="#4a3826"; c.beginPath(); c.arc(t.x,t.y,Math.max(4,t.r*0.22),0,7); c.fill();
    }
    // 沙包：一排麻袋
    for(const s of (m.sandbags||[])){
      const horiz=s.w>=s.h, n=Math.max(2,Math.round((horiz?s.w:s.h)/14));
      for(let i=0;i<n;i++){ const cx=horiz? s.x+(i+0.5)*s.w/n : s.x+s.w/2,
        cy=horiz? s.y+s.h/2 : s.y+(i+0.5)*s.h/n;
        c.fillStyle="#b09761"; c.beginPath(); c.ellipse(cx,cy,8,6,0,0,7); c.fill();
        c.strokeStyle="#7d6a44"; c.stroke();
        c.strokeStyle="rgba(80,66,40,0.5)"; c.beginPath(); c.moveTo(cx-5,cy); c.lineTo(cx+5,cy); c.stroke(); }
    }
    // 建築：陰影 + 屋頂高光 + 窗
    for(const s of (m.solids||[])){
      c.fillStyle="rgba(0,0,0,0.22)"; c.fillRect(s.x+4,s.y+5,s.w,s.h);
      c.fillStyle="#6e6a63"; c.fillRect(s.x,s.y,s.w,s.h);
      c.fillStyle="#807b72"; c.fillRect(s.x,s.y,s.w,6);
      c.strokeStyle="#403d38"; c.lineWidth=2; c.strokeRect(s.x,s.y,s.w,s.h); c.lineWidth=1;
      c.fillStyle="rgba(28,28,32,0.5)";
      for(let wx=s.x+8;wx<s.x+s.w-8;wx+=18) for(let wy=s.y+12;wy<s.y+s.h-8;wy+=18) c.fillRect(wx,wy,7,9);
    }
    // 碉堡：混凝土塊 + 射口（可進入掩蔽）
    for(const b of (m.bunkers||[])){
      c.fillStyle="rgba(0,0,0,0.28)"; c.fillRect(b.x+3,b.y+4,b.w,b.h);
      c.fillStyle="#8d8a80"; c.fillRect(b.x,b.y,b.w,b.h);                  // 混凝土
      c.fillStyle="#a3a096"; c.fillRect(b.x,b.y,b.w,5);
      c.strokeStyle="#4a473f"; c.lineWidth=2; c.strokeRect(b.x,b.y,b.w,b.h); c.lineWidth=1;
      c.fillStyle="#2a2723"; c.fillRect(b.x+b.w*0.2,b.y+b.h*0.42,b.w*0.6,Math.max(4,b.h*0.16)); // 射口(embrasure)
    }
    // 出圖前整體提飽和（視覺感官部門：對照上市遊戲，死灰地面是廉價感主因）
    try{
      const tmp=document.createElement("canvas"); tmp.width=W; tmp.height=H;
      const tc=tmp.getContext("2d"); tc.drawImage(cv,0,0);
      c.filter="saturate(1.55) contrast(1.09) brightness(0.99)"; c.drawImage(tmp,0,0); c.filter="none"; // 2026-07-21 對照 VC 濃彩再加深（粉彩洗白回饋）
    }catch(e){ /* 舊瀏覽器無 canvas filter：跳過 */ }
  },

  render(dt){
    const c=this.ctx, m=this.map;
    c.clearRect(0,0,960,600);
    if (this.state==="menu"||!m) return;
    // 真 3D（GDD/08）：WebGL 畫世界、2D canvas 疊 HUD
    if (typeof Engine3D!=="undefined" && Engine3D.ok){
      Camera3D.applyFor(this,false,dt);
      Engine3D.render(this);
      Fog.renderProjected(c,Camera3D,(x,y)=>Engine3D.heightAt(x,y));
      Engine3D.overlay(c, this);
      this.drawHint(c);
      return;
    }
    // 正式流程禁止靜默回退偽 3D／俯視；否則使用者會看到舊地圖卻不知道 WebGL 已失效。
    c.save();c.fillStyle="#111820";c.fillRect(0,0,960,600);
    c.fillStyle="#ff665a";c.textAlign="center";c.font="bold 30px sans-serif";
    c.fillText("真 3D 引擎啟動失敗",480,250);
    c.fillStyle="#eef3f7";c.font="18px sans-serif";
    const reason=(typeof Engine3D!=="undefined"&&Engine3D.failureReason)||"瀏覽器不支援 WebGL 或 Three.js 未載入";
    c.fillText(reason,480,292);c.font="15px sans-serif";
    c.fillText("已阻止切回舊 2D／偽 3D 戰場，請開啟開發者主控台查看錯誤。",480,330);c.restore();return;
    // 下方舊俯視碼只保留作歷史診斷；正式流程不可抵達。
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
    if (this.state==="deploy") return false;  // 部署屬隱藏資訊；開戰後才套用迷霧與視線
    if (Fog.enabled && !Fog.visibleAt(u.x,u.y)) return false;
    return this.units.some(o=>o.alive && o.side===this.playerSide && Combat.canSee(this.map,o,u,this.turn));
  },

  drawUnit(c,u){
    const isPlayer = u.side===this.playerSide;
    if (!isPlayer && !this.enemyVisible(u)) return;
    const hidden = Combat.inBush(this.map,u) && u.crouched && !u.revealed && isPlayer;
    c.globalAlpha = hidden ? 0.6 : 1;
    Sprites.tryLoad(u);
    Sprites.drawBody(c,u,isPlayer);
    // 血條/AP條
    const w = u.big?34 : u.cls==="tank"?32 : 22, x0=u.x-w/2, y0=u.y-u.r-9;
    c.fillStyle="#222"; c.fillRect(x0,y0,w,3);
    c.fillStyle=isPlayer?(u.hp>u.maxhp*0.3?"#4fd05e":"#e04b3a"):"#e53935";
    c.fillRect(x0,y0,w*clamp(u.hp/u.maxhp,0,1),3);
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

// 發布閘門與瀏覽器反驗證入口；指向實際遊戲單例，不複製或繞過任何規則。
if(typeof window!=="undefined")window.BATTLEFIELD_GAME=Game;
