/* ============================================================
 * ui.js — DOM 介面（主選單/部署面板/HUD/瞄準面板/戰報）
 * 只做 DOM，不含遊戲規則；規則一律呼叫 Game / Combat。
 * ============================================================ */
"use strict";

const UI = {
  el(id){ return document.getElementById(id); },

  /* ---------- 主選單 ---------- */
  showMenu(){
    this.hideAll();
    if (typeof Sfx!=="undefined") Sfx.bgm("menu");
    const natOpts = Object.values(NATIONS).map(n=>`<option value="${n.id}">${n.name}</option>`).join("");
    const mapOpts = Object.values(MAPS).filter(m=>!m.tutorial).map(m=>`<option value="${m.id}">${m.name}（${(m.allow||["land"]).map(d=>({land:"陸",sea:"海",air:"空"}[d])).join("")}）</option>`).join("");
    this.el("menu").innerHTML = `
      <h1>戰　場</h1><p class="sub">真實軍備 × 戰場女武神式戰術</p>
      <button id="btnStory" class="big" style="background:#7a4a2a">📖 劇情模式：曙光作戰（15 章）</button>
      <button id="btnTutorial" class="big">教學關：台海防衛</button>
      <div class="panel">
        <h3>遭遇戰</h3>
        <label>進攻方（左） <select id="selAtk">${natOpts}</select></label>
        <label>防守方（右） <select id="selDef">${natOpts}</select></label>
        <label>地圖 <select id="selMap">${mapOpts}</select></label>
        <label>我操作 <select id="selSide"><option value="0">進攻方</option><option value="1" selected>防守方</option></select></label>
        <button id="btnSkirmish" class="big">開始遭遇戰</button>
      </div>
      <p class="fine">各國兵種與武器均取自公開資訊（見 research/），數值為遊戲化平衡。</p>`;
    this.el("menu").style.display="flex";
    this.el("selAtk").value="china"; this.el("selDef").value="taiwan";
    this.el("btnTutorial").onclick = ()=>{ Game.storyChapter=null; const f=MAPS.tutorial.fixedNations; Game.startBattle("tutorial", f.atk, f.def, f.playerSide); };
    this.el("btnStory").onclick = ()=>this.showStory();
    const mpBtn=document.createElement("button"); mpBtn.className="big";
    mpBtn.textContent="🌐 連線對戰（跨裝置）"; mpBtn.style.marginTop="6px";
    mpBtn.onclick=()=>this.showConnect();
    this.el("menu").appendChild(mpBtn);
    this.el("btnSkirmish").onclick = ()=>{
      const a=this.el("selAtk").value, d=this.el("selDef").value;
      Game.startBattle(this.el("selMap").value, a, d, parseInt(this.el("selSide").value,10));
    };
  },

  /* ---------- 劇情模式 ---------- */
  showStory(){
    this.hideAll();
    if (typeof Sfx!=="undefined") Sfx.bgm("menu");
    const unlocked = StoryProgress.get();
    const rows = STORY.map(ch=>{
      const lock = ch.n > unlocked;
      return `<button class="storyCh${lock?" locked":""}" data-ch="${ch.n}" ${lock?"disabled":""}>
        第 ${ch.n} 章｜${lock?"🔒 ？？？":ch.title}</button>`;
    }).join("");
    const M=this.el("menu"); M.style.display="flex";
    M.innerHTML=`
      <h1 style="font-size:26px">📖 曙光作戰</h1>
      <p class="sub">2034，無旗幟的戰爭。反派「灰幕兵團」為虛構勢力。</p>
      <div class="panel storyList">${rows}</div>
      <button id="stBack">返回主選單</button>`;
    M.querySelectorAll(".storyCh:not(.locked)").forEach(b=>{
      b.onclick=()=>this.showBriefing(parseInt(b.dataset.ch,10));
    });
    this.el("stBack").onclick=()=>this.showMenu();
  },
  showBriefing(n){
    const ch = STORY[n-1];
    const roster = Object.values(CHARACTERS).map(c =>
      `<img class="rosterFace" src="${c.portrait}" title="${c.name}（${c.trait.desc}）" alt="${c.name}">`).join("");
    const M=this.el("menu"); M.style.display="flex";
    M.innerHTML=`
      <h1 style="font-size:24px">第 ${ch.n} 章｜${ch.title}</h1>
      <div class="panel briefing"><p>${ch.brief}</p>
        <p class="fine">地圖：${MAPS[ch.map].name}　我方：${NATIONS[ch.player].name}（${ch.side===0?"進攻":"防守"}）</p>
        <div class="roster">${roster}</div>
        <p class="fine">曙光小隊：部署時各兵種首位由具名隊員出任（附特質加成）</p></div>
      <button id="stGo" class="big">🎖 出擊</button>
      <button id="stBack2">返回章節</button>`;
    const launch=()=>{
      Game.storyChapter = n;
      const atk = ch.side===0 ? ch.player : ch.enemy;
      const def = ch.side===0 ? ch.enemy : ch.player;
      Game.startBattle(ch.map, atk, def, ch.side);
    };
    this.el("stGo").onclick=()=>{
      if (ch.dialog && ch.dialog.length) this.showDialog(ch.dialog, launch);
      else launch();
    };
    this.el("stBack2").onclick=()=>this.showStory();
  },

  /* ---------- 戰場角色卡：選中單位常駐大立繪（人的靈魂在立繪，3D 是棋子） ---------- */
  showCharCard(u){
    let el = document.getElementById("charCard");
    if (!el){
      el = document.createElement("div"); el.id = "charCard";
      document.getElementById("stage").appendChild(el);
    }
    if (!u || u.domain !== "land" || u.cls === "tank"){ el.style.display = "none"; return; }
    const chr = (typeof CHARACTERS !== "undefined") ? CHARACTERS[u.cls] : null;
    const img = chr ? (chr.fullPortrait || chr.portrait) : null;
    if (!img){ el.style.display = "none"; return; }
    const named = !!u.charName;
    el.innerHTML = `
      <img src="${img}" alt="">
      <div class="cc-info">
        <div class="cc-name">${named ? "★" + u.charName : u.label}</div>
        ${named && chr ? `<div class="cc-trait">${chr.trait.desc}</div>` : ""}
        <div class="cc-hp">HP ${Math.max(0, Math.round(u.hp))}/${u.maxhp}</div>
      </div>`;
    el.style.display = "flex";
  },
  hideCharCard(){ const el = document.getElementById("charCard"); if (el) el.style.display = "none"; },

  /* ---------- 對話演出（演出部門）：立繪＋名牌＋逐句推進 ---------- */
  showDialog(script, onDone){
    let i = 0;
    const M = this.el("menu"); M.style.display = "flex";
    const step = () => {
      if (i >= script.length){ onDone && onDone(); return; }
      const d = script[i];
      const chr = Object.values(CHARACTERS).find(c => c.name === d.who);
      const img = d.img || (chr && ((d.mood && chr.moods && chr.moods[d.mood]) || chr.fullPortrait || chr.portrait)) || "";
      M.innerHTML = `
        <div class="dlgWrap" id="dlgNext">
          ${img ? `<img class="dlgFace ${d.pos==="right"?"r":""}" src="${img}" alt="">` : ""}
          <div class="dlgBox">
            <div class="dlgName">${d.who || ""}</div>
            <div class="dlgText">${d.text}</div>
            <div class="dlgHint">▼ 點擊繼續（${i+1}/${script.length}）</div>
          </div>
        </div>`;
      this.el("dlgNext").onclick = () => { i++; step(); };
    };
    step();
  },

  /* ---------- 連線對戰介面 ---------- */
  showConnect(){
    this.hideAll();
    const natOpts = Object.values(NATIONS).map(n=>`<option value="${n.id}">${n.name}</option>`).join("");
    const mapOpts = Object.values(MAPS).filter(m=>!m.tutorial).map(m=>`<option value="${m.id}">${m.name}</option>`).join("");
    const M=this.el("menu"); M.style.display="flex";
    M.innerHTML=`
      <h1 style="font-size:28px">🌐 連線對戰</h1>
      <p class="sub">兩台裝置直連。一人「主持」、一人「加入」，用任何聊天軟體互傳連線碼即可。</p>
      <div class="panel">
        <h3>① 我是主持方</h3>
        <label>地圖 <select id="mpMap">${mapOpts}</select></label>
        <label>我方(先手) <select id="mpAtk">${natOpts}</select></label>
        <label>對手 <select id="mpDef">${natOpts}</select></label>
        <button id="mpGenInvite">產生邀請碼</button>
        <p class="fine">把下面整段「邀請碼」傳給朋友：</p>
        <textarea id="mpInvite" rows="2" style="width:100%" readonly placeholder="按上面按鈕產生"></textarea>
        <p class="fine">貼上朋友回傳的「回應碼」，再按開始：</p>
        <textarea id="mpAnswer" rows="2" style="width:100%" placeholder="貼上回應碼"></textarea>
        <button id="mpConnect" class="big">完成連線並開始</button>
      </div>
      <div class="panel">
        <h3>② 我是加入方</h3>
        <p class="fine">貼上朋友給的「邀請碼」：</p>
        <textarea id="mpInvIn" rows="2" style="width:100%" placeholder="貼上邀請碼"></textarea>
        <button id="mpGenAnswer">產生回應碼</button>
        <p class="fine">把下面整段「回應碼」傳回主持方，然後等待開局：</p>
        <textarea id="mpAnsOut" rows="2" style="width:100%" readonly></textarea>
      </div>
      <button id="mpBack">返回主選單</button>
      <div id="mpStatus" class="hint" style="display:none"></div>`;
    const st=(m)=>{ const e=this.el("mpStatus"); e.style.display="block"; e.textContent=m; };
    Net.onState = d=>Game.applyNetState(d);
    Net.onClose = ()=>st("⚠ 連線中斷，請返回重連");
    Net.onReady = ()=>{
      if (Net.myside===0){ st("✅ 已連線！請布署你的部隊"); Game.mpHostBegin(this.el("mpMap").value, this.el("mpAtk").value, this.el("mpDef").value); }
      else { st("✅ 已連線！等待主持方設定…"); }
    };
    this.el("mpGenInvite").onclick = async ()=>{ st("產生邀請碼中…（約 1–4 秒）");
      try{ this.el("mpInvite").value = await Net.host(); st("邀請碼已產生，傳給朋友。"); }
      catch(e){ st("產生失敗："+e.message); } };
    this.el("mpConnect").onclick = async ()=>{ const code=this.el("mpAnswer").value.trim();
      if(!code){ st("請先貼上朋友的回應碼"); return; }
      try{ await Net.accept(code); st("連線中…（等對方就緒）"); }catch(e){ st("連線失敗："+e.message); } };
    this.el("mpGenAnswer").onclick = async ()=>{ const code=this.el("mpInvIn").value.trim();
      if(!code){ st("請先貼上主持方的邀請碼"); return; } st("產生回應碼中…");
      try{ this.el("mpAnsOut").value = await Net.join(code); st("回應碼已產生，傳回主持方，等待開局…"); }
      catch(e){ st("產生失敗："+e.message); } };
    this.el("mpBack").onclick = ()=>{ Net.reset(); this.showMenu(); };
  },

  /* ---------- 部署 ---------- */
  showDeploy(){
    this.hideAll();
    this.el("side").style.display="block";
    this.refreshDeploy();
  },
  refreshDeploy(){
    const nat = NATIONS[Game.nations[Game.playerSide]];
    const allow = Game.mapAllow();
    const groups = { land:"🪖 陸軍", sea:"⚓ 海軍", air:"✈ 空軍" };
    let rows = "";
    for (const dom of ["land","sea","air"]){
      if (!allow.includes(dom)) continue;
      const keys = Object.keys(CLASS_BASE).filter(k=>CLASS_BASE[k].domain===dom);
      rows += `<div class="grpHead">${groups[dom]}</div>`;
      rows += keys.map(k=>{
        const c = unitCost(nat.id,k), u=nat.units[k];
        const cp = (k==="tank"||CLASS_BASE[k].big||dom==="air")?2:1;
        const on = Game.deployCls===k?" on":"";
        return `<button class="unitBtn${on}" data-cls="${k}">
          <span class="unitArt art-${k}" aria-hidden="true"></span>
          <span class="unitCopy"><b>${CLASS_BASE[k].zh}</b>｜${u.label}<br><span class="weapon">${u.weapon}</span></span>
          <em>${c}點·${cp}CP</em></button>`;
      }).join("");
    }
    this.el("side").innerHTML = `
      <h3>部署（${nat.name}）</h3>
      <p>剩餘點數 <b id="bud">${Game.budgetLeft}</b> / ${Game.map.budget}</p>
      <p class="fine">特性：${nat.trait.desc}</p>
      <div class="ulist">${rows}</div>
      <p class="fine">左鍵放置於藍框（艦艇需放水域）、右鍵移除。坦克/大艦上限各 2。</p>
      <button id="btnGo" class="big">開始戰鬥 ▶</button>
      <button id="btnBack">返回主選單</button>
      <div id="log"></div>`;
    for (const b of this.el("side").querySelectorAll(".unitBtn"))
      b.onclick = ()=>{ Game.deployCls=b.dataset.cls; this.refreshDeploy(); };
    this.el("btnGo").onclick = ()=>Game.finishDeploy();
    this.el("btnBack").onclick = ()=>{ Game.state="menu"; Game.map=null; this.showMenu(); };
  },
  /* ---------- 戰鬥 HUD ---------- */
  showBattle(){
    this.hideAll();
    this.el("side").style.display="block";
    this.el("side").innerHTML = `
      <h3 id="hudTurn"></h3><div id="hudCp" class="cp"></div>
      <div id="selInfo" class="panel"></div>
      <button id="btnTerrain" style="display:none">蹲伏掩蔽 (C)</button>
      <button id="btnUnload" style="display:none">放下跳板並卸載</button>
      <button id="btnFireEnd" style="display:none">結束行動 (E)</button>
      <button id="btnCapture" style="display:none">佔領主堡</button>
      <button id="btnEndTurn">結束回合</button>
      <div id="hint" class="hint" style="display:none"></div>
      <div id="log"></div>`;
    this.el("btnEndTurn").onclick=()=>{ if(Game.state==="cmd") Game.endTurn(); };
    this.el("btnTerrain").onclick=()=>Game.toggleTerrainAction();
    this.el("btnUnload").onclick=()=>Game.unloadLST();
    this.el("btnFireEnd").onclick=()=>{ if(Game.state==="act") Game.endAction(); };
    this.el("btnCapture").onclick=()=>Game.tryCapture();
    window.addEventListener("keydown",e=>{ if(e.key.toLowerCase()==="e"&&Game.state==="act") Game.endAction(); });
    this.refreshHud();
  },

  refreshHud(){
    if (!this.el("hudTurn")) return;
    const _ph = Net.connected ? (Net.myside===Game.turnOwner?"你的回合 ▶":"對方回合…") : (Game.state==="enemy"?"敵方階段":"我方階段");
    this.el("hudTurn").textContent = `第 ${Game.turn}/30 回合 — ${_ph}`;
    this.el("hudCp").innerHTML = "CP "+"●".repeat(Game.cp)+"○".repeat(Math.max(0,Game.cpMax-Game.cp));
    this.refreshActBar();
  },

  refreshActBar(){
    const u=Game.sel, info=this.el("selInfo");
    if (!info) return;
    if (u){
      const terrain=Game.terrainActionAt(u), crouch=u.crouched;
      info.innerHTML = `<b>${u.label}</b>（${CLASS_BASE[u.cls].zh}）<br>${u.weaponName}<br>
        HP ${Math.max(0,Math.round(u.hp))}/${u.maxhp}<br>AP <progress max="${u.maxap}" value="${u.ap}"></progress>
        ${crouch?`<br>掩蔽：${terrain?terrain.label:"蹲伏"}`:""}
        ${u.cls==="lst"?`<br>載員：${(u.carried||[]).map(p=>p.label).join("、")||"無"}`:""}
        ${Game.selFired?"<br>⚠ 已用掉開火機會":""}`;
      this.el("btnFireEnd").style.display="block";
      this.el("btnTerrain").style.display=(crouch||terrain)?"block":"none";
      this.el("btnTerrain").textContent=crouch?"站起 (C)":terrain?`蹲伏掩蔽：${terrain.label} (C)`:"蹲伏掩蔽 (C)";
      this.el("btnUnload").style.display=(u.cls==="lst"&&(u.carried||[]).length)?"block":"none";
      this.el("btnUnload").disabled=!Game.canUnloadLST(u);
      const base=Game.map.bases.find(b=>b.side!==u.side);
      this.el("btnCapture").style.display = (u.canCap&&dist(u,base)<34)?"block":"none";
    } else {
      info.innerHTML = "點選我方單位下令（1 CP，坦克 2 CP）";
      this.el("btnFireEnd").style.display="none";
      this.el("btnTerrain").style.display="none";
      this.el("btnUnload").style.display="none";
      this.el("btnCapture").style.display="none";
    }
  },

  /* ---------- 瞄準面板 ---------- */
  showAim(shooter, t){
    const box=this.el("aim");
    const parts = t.cls==="tank" ? [["body","車體 ×1"],["radiator","散熱器 ×3"]]
      : t.domain==="land" ? [["body","軀幹 ×1"],["head","頭部 ×2"]]
      : [["body","命中 ×1"]];  // 艦艇/飛機無部位弱點
    const btns = parts.map(([p,label])=>{
      const ch=Math.round(Combat.hitChance(Game.map,shooter,t,p)*100);
      return `<button data-part="${p}" ${ch===0?"disabled":""}>${label}<br>命中 ${ch}%</button>`;
    }).join("");
    box.innerHTML = `<b>瞄準：${t.label}</b>（HP ${Math.max(0,Math.round(t.hp))}）<br>
      武器 ${shooter.weaponName} × ${shooter.weapon.shots} 發<div class="parts">${btns}</div>
      <button id="aimCancel">取消</button>`;
    box.style.display="block";
    for (const b of box.querySelectorAll("[data-part]"))
      b.onclick=()=>Game.playerFire(b.dataset.part);
    this.el("aimCancel").onclick=()=>{ Game.aimTarget=null; this.hideAim(); };
    if (Game.selFired){ box.innerHTML="<b>本次行動已開過火</b><br><button id='aimCancel'>關閉</button>";
      this.el("aimCancel").onclick=()=>this.hideAim(); }
  },
  hideAim(){ this.el("aim").style.display="none"; },

  /* ---------- 其他 ---------- */
  hint(text){ const h=this.el("hint"); if(!h) return; h.style.display="block"; h.textContent="💡 "+text; },
  log(msg){
    const l=this.el("log"); if(!l) return;
    const d=document.createElement("div"); d.textContent=msg;
    l.prepend(d); while(l.children.length>8) l.lastChild.remove();
  },
  showEnd(){
    const win = Game.over.winner===Game.playerSide;
    if (typeof Sfx!=="undefined"){ Sfx.bgm(null); Sfx.play(win?"victory":"defeat"); }
    const chN = Game.storyChapter, ch = chN ? STORY[chN-1] : null;
    let extra = "";
    if (ch && win){
      StoryProgress.unlock(chN + 1);
      extra = `<div class="panel briefing"><p>${ch.debrief}</p></div>` +
        (chN < STORY.length ? `<button id="btnNextCh" class="big">▶ 下一章：${STORY[chN].title}</button>` : "");
    } else if (ch && !win){
      extra = `<button id="btnRetry" class="big">↻ 重打本章</button>`;
    }
    this.el("menu").innerHTML = `
      <h1>${win?"🏆 勝利":"💀 敗北"}</h1>
      <p class="sub">${Game.over.why}（${NATIONS[Game.nations[Game.over.winner]].name} 獲勝）</p>
      ${extra}
      <button id="btnAgain" class="big">回主選單</button>`;
    this.el("menu").style.display="flex";
    const reset=()=>{ Game.state="menu"; Game.map=null; Game.units=[]; };
    if (this.el("btnNextCh")) this.el("btnNextCh").onclick=()=>{ reset(); this.showBriefing(chN+1); };
    if (this.el("btnRetry"))  this.el("btnRetry").onclick =()=>{ reset(); this.showBriefing(chN); };
    this.el("btnAgain").onclick=()=>{ reset(); Game.storyChapter=null; this.showMenu(); };
  },
  hideAll(){ this.el("menu").style.display="none"; this.el("side").style.display="none"; this.hideAim(); }
};
