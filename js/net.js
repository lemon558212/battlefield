/* ============================================================
 * net.js — 跨裝置連線對戰（WebRTC P2P + 手動交換連線碼，零後端）
 * 流程：主機 host()→邀請碼 ；加入方 join(邀請碼)→回應碼 ；主機 accept(回應碼)
 * 連上後：當前回合方為權威，行動後 sendState() 廣播完整狀態，對方 apply。
 * 本模組不主動改動遊戲流程；由 game.js/ui.js 呼叫與掛接 callback。
 * ============================================================ */
"use strict";

const Net = {
  pc:null, ch:null, connected:false, myside:null, active:false,
  onReady:null, onState:null, onHello:null, onClose:null,

  _mkPC(){
    const pc = new RTCPeerConnection({ iceServers:[{ urls:"stun:stun.l.google.com:19302" }] });
    pc.onconnectionstatechange = ()=>{
      if (["disconnected","failed","closed"].includes(pc.connectionState)){
        this.connected=false; if(this.onClose) this.onClose();
      }
    };
    return pc;
  },

  // 等 ICE 候選蒐集完成，讓連線碼自包含（免 trickle signaling）
  _waitIce(pc){
    return new Promise(res=>{
      if (pc.iceGatheringState==="complete") return res();
      const chk=()=>{ if(pc.iceGatheringState==="complete"){ pc.removeEventListener("icegatheringstatechange",chk); res(); } };
      pc.addEventListener("icegatheringstatechange", chk);
      setTimeout(res, 4000); // 保險上限
    });
  },

  _setupCh(ch){
    this.ch = ch;
    ch.onopen = ()=>{ this.connected=true; if(this.onReady) this.onReady(); };
    ch.onclose = ()=>{ this.connected=false; if(this.onClose) this.onClose(); };
    ch.onmessage = e=>{
      let m; try{ m=JSON.parse(e.data); }catch(_){ return; }
      if (m.t==="state" && this.onState) this.onState(m.d);
      else if (m.t==="hello" && this.onHello) this.onHello(m.d);
    };
  },

  // 主機：建立連線，回傳邀請碼（貼給對方）
  async host(){
    this.active=true; this.myside=0;
    const pc = this.pc = this._mkPC();
    this._setupCh(pc.createDataChannel("game"));
    await pc.setLocalDescription(await pc.createOffer());
    await this._waitIce(pc);
    return Net.encode(pc.localDescription);
  },

  // 加入方：吃邀請碼，回傳回應碼（貼回主機）
  async join(inviteCode){
    this.active=true; this.myside=1;
    const pc = this.pc = this._mkPC();
    pc.ondatachannel = e=>this._setupCh(e.channel);
    await pc.setRemoteDescription(Net.decode(inviteCode));
    await pc.setLocalDescription(await pc.createAnswer());
    await this._waitIce(pc);
    return Net.encode(pc.localDescription);
  },

  // 主機：吃回應碼，完成連線
  async accept(answerCode){
    await this.pc.setRemoteDescription(Net.decode(answerCode));
  },

  encode(desc){ return btoa(unescape(encodeURIComponent(JSON.stringify({ type:desc.type, sdp:desc.sdp })))); },
  decode(code){ return JSON.parse(decodeURIComponent(escape(atob(code.trim())))); },

  send(t, d){ if (this.ch && this.ch.readyState==="open") this.ch.send(JSON.stringify({ t, d })); },

  // 廣播目前遊戲完整狀態（權威方呼叫）
  sendState(){ this.send("state", this.serialize()); },

  serialize(){
    const g = Game;
    return {
      map: g.map.id, nations: g.nations, turn: g.turn, cp: g.cp, cpMax: g.cpMax, turnOwner: g.turnOwner,
      over: g.over,
      units: g.units.map(u=>({
        id:u.id, side:u.side, nationId:u.nationId, cls:u.cls,
        x:Math.round(u.x), y:Math.round(u.y), hp:u.hp, ap:u.ap,
        alive:u.alive, facing:u.facing, actedCount:u.actedCount, revealed:u.revealed
      }))
    };
  },

  // 是否輪到我方下令（連線對戰時用於鎖定輸入）
  myTurn(){ return !this.connected || Game.turn==null ? true : (Game.playerSide===this.myside && Game.state!=="enemy"); },

  reset(){
    try{ if(this.ch) this.ch.close(); if(this.pc) this.pc.close(); }catch(_){}
    this.pc=null; this.ch=null; this.connected=false; this.myside=null; this.active=false;
  }
};
