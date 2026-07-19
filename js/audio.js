/* ============================================================
 * audio.js — 程序化音效引擎（WebAudio 合成，零素材零依賴）
 * 職責：武器射擊/爆炸/受擊/死亡/介面 音效。依賴：無（獨立模組）。
 * 掛載：combat 事件經 Game.pushFx → Sfx.event(e)；UI 直呼 Sfx.play(name)。
 * 手機自動播放政策：首次觸控/點擊才建立 AudioContext（見檔尾監聽器）。
 * ============================================================ */
"use strict";

const Sfx = {
  ctx: null, master: null,
  _last: {},          // 同名音效節流（毫秒時間戳）
  _noiseBuf: null,

  _ac(){
    if (!this.ctx){
      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return null;
      this.ctx = new AC();
      this.master = this.ctx.createGain();
      this.master.gain.value = 0.55;
      this.master.connect(this.ctx.destination);
    }
    if (this.ctx.state === "suspended") this.ctx.resume();
    if (this._bgm.want && !this._bgm.timer && this._bgm.cur !== this._bgm.want){
      const w = this._bgm.want; this._bgm.cur = null; this.bgm(w);   // 解鎖後補啟動配樂
    }
    return this.ctx;
  },

  /* 同名音效最小間隔（機槍連發不炸耳、群體受擊不疊爆） */
  _gate(name, gapMs){
    const now = performance.now();
    if (now - (this._last[name] || 0) < gapMs) return false;
    this._last[name] = now;
    return true;
  },

  _noise(){
    if (!this._noiseBuf){
      const sr = this.ctx.sampleRate, buf = this.ctx.createBuffer(1, sr, sr);
      const d = buf.getChannelData(0);
      for (let i = 0; i < sr; i++) d[i] = Math.random() * 2 - 1;
      this._noiseBuf = buf;
    }
    return this._noiseBuf;
  },

  /* 白噪音經濾波＋音量包絡：槍聲/爆炸的基底。atk=起音秒數（消喀噠聲） */
  _burst({ dur = 0.1, vol = 0.5, type = "lowpass", freq = 800, freqEnd = 0, q = 1, at = 0, atk = 0.004 }){
    const c = this.ctx, t0 = c.currentTime + at;
    const src = c.createBufferSource(); src.buffer = this._noise(); src.loop = true;
    const flt = c.createBiquadFilter(); flt.type = type; flt.Q.value = q;
    flt.frequency.setValueAtTime(freq, t0);
    if (freqEnd) flt.frequency.exponentialRampToValueAtTime(Math.max(30, freqEnd), t0 + dur);
    const g = c.createGain();
    g.gain.setValueAtTime(0.0001, t0);
    g.gain.linearRampToValueAtTime(vol, t0 + atk);
    g.gain.exponentialRampToValueAtTime(0.001, t0 + dur);
    src.connect(flt); flt.connect(g); g.connect(this.master);
    src.start(t0); src.stop(t0 + dur + 0.05);
  },

  /* 振盪器單音：滑音包絡（砲擊低鳴/介面音/配樂）。atk=起音秒數 */
  _tone({ freq = 440, freqEnd = 0, dur = 0.15, vol = 0.25, type = "sine", at = 0, atk = 0.008 }){
    const c = this.ctx, t0 = c.currentTime + at;
    const o = c.createOscillator(); o.type = type;
    o.frequency.setValueAtTime(freq, t0);
    if (freqEnd) o.frequency.exponentialRampToValueAtTime(Math.max(20, freqEnd), t0 + dur);
    const g = c.createGain();
    g.gain.setValueAtTime(0.0001, t0);
    g.gain.linearRampToValueAtTime(vol, t0 + atk);
    g.gain.exponentialRampToValueAtTime(0.001, t0 + dur);
    o.connect(g); g.connect(this.master);
    o.start(t0); o.stop(t0 + dur + 0.05);
  },

  /* ---------- 音色庫 ---------- */
  _lib: {
    rifle(S){ S._burst({ dur: 0.09, vol: 0.4, type: "highpass", freq: 900 });
              S._burst({ dur: 0.14, vol: 0.22, freq: 500, freqEnd: 120 }); },          // 清脆單發＋短尾
    smg(S){   S._burst({ dur: 0.06, vol: 0.3, type: "highpass", freq: 1200 });
              S._burst({ dur: 0.08, vol: 0.15, freq: 600, freqEnd: 200 }); },          // 輕快連點
    mg(S){    S._burst({ dur: 0.05, vol: 0.34, type: "highpass", freq: 700 });
              S._burst({ dur: 0.09, vol: 0.2, freq: 420, freqEnd: 150 }); },           // 重機槍嗒嗒
    sniper(S){S._burst({ dur: 0.14, vol: 0.5, type: "highpass", freq: 600 });
              S._burst({ dur: 0.5, vol: 0.25, freq: 700, freqEnd: 90 });               // 巨響＋山谷回音尾
              S._burst({ dur: 0.35, vol: 0.1, freq: 400, freqEnd: 80, at: 0.12 }); },
    cannon(S){S._tone({ freq: 70, freqEnd: 28, dur: 0.55, vol: 0.55 });
              S._burst({ dur: 0.5, vol: 0.5, freq: 350, freqEnd: 60 });
              S._burst({ dur: 0.08, vol: 0.35, type: "highpass", freq: 500 }); },      // 坦克/艦砲：胸腔震
    rocket(S){S._burst({ dur: 0.4, vol: 0.35, type: "bandpass", freq: 320, freqEnd: 1400, q: 2 });
              S._burst({ dur: 0.12, vol: 0.2, type: "highpass", freq: 800, at: 0.02 }); }, // 咻——
    mortar(S){S._tone({ freq: 150, freqEnd: 55, dur: 0.28, vol: 0.4, type: "triangle" });
              S._burst({ dur: 0.15, vol: 0.18, freq: 300, freqEnd: 100 }); },          // 出膛悶響
    torpedo(S){S._burst({ dur: 0.5, vol: 0.3, freq: 250, freqEnd: 500, q: 3, type: "bandpass" });
               S._tone({ freq: 90, freqEnd: 45, dur: 0.4, vol: 0.2 }); },              // 入水推進
    boom(S){  S._tone({ freq: 55, freqEnd: 24, dur: 0.8, vol: 0.6 });
              S._burst({ dur: 0.7, vol: 0.55, freq: 300, freqEnd: 45 });
              S._burst({ dur: 0.25, vol: 0.3, type: "highpass", freq: 400 });
              S._burst({ dur: 0.4, vol: 0.15, freq: 900, freqEnd: 200, at: 0.1 }); },  // 爆炸：低鳴＋碎響
    hit(S){   S._burst({ dur: 0.06, vol: 0.22, freq: 520, freqEnd: 160 }); },          // 命中悶擊
    death(S){ S._tone({ freq: 330, freqEnd: 110, dur: 0.4, vol: 0.16, type: "square" });
              S._burst({ dur: 0.25, vol: 0.15, freq: 400, freqEnd: 90 }); },           // 步兵倒下
    vboom(S){ S._tone({ freq: 60, freqEnd: 22, dur: 1.0, vol: 0.6 });
              S._burst({ dur: 0.9, vol: 0.55, freq: 260, freqEnd: 40 });
              S._burst({ dur: 0.5, vol: 0.2, freq: 800, freqEnd: 150, at: 0.15 });
              S._burst({ dur: 0.35, vol: 0.15, freq: 700, freqEnd: 120, at: 0.4 }); }, // 載具殉爆（二次爆）
    select(S){S._tone({ freq: 620, freqEnd: 880, dur: 0.07, vol: 0.14, type: "triangle" }); },
    move(S){  S._tone({ freq: 440, freqEnd: 520, dur: 0.06, vol: 0.12, type: "triangle" }); },
    capture(S){S._tone({ freq: 523, dur: 0.1, vol: 0.16, type: "triangle" });
               S._tone({ freq: 784, dur: 0.16, vol: 0.16, type: "triangle", at: 0.1 }); },
    victory(S){ [523, 659, 784, 1047].forEach((f, i) =>
                 S._tone({ freq: f, dur: i === 3 ? 0.5 : 0.18, vol: 0.2, type: "triangle", at: i * 0.16 })); },
    defeat(S){  [392, 330, 262, 196].forEach((f, i) =>
                 S._tone({ freq: f, dur: i === 3 ? 0.6 : 0.22, vol: 0.18, type: "sine", at: i * 0.2 })); }
  },

  /* 同名節流間隔（未列＝80ms） */
  _gaps: { mg: 70, smg: 70, rifle: 100, hit: 90, boom: 150, cannon: 200, sniper: 250,
           death: 150, vboom: 300, select: 120, move: 150 },

  play(name){
    if (name === "victory" || name === "defeat"){            // 結算短曲優先用檔案版
      const el = this._el(name);
      if (el && !this.muted){ el.currentTime = 0; el.volume = 0.5; el.play().catch(() => {}); return; }
    }
    if (!this._ac()) return;
    const f = this._lib[name];
    if (!f || !this._gate(name, this._gaps[name] || 80)) return;
    try { f(this); } catch (e) { /* 音效失敗不得影響遊戲 */ }
  },

  /* 武器 type → 音色（combat tracer 事件帶 w=weapon.type） */
  _wmap: { rifle: "rifle", carbine: "smg", lmg: "mg", naval_mg: "mg",
           sniper: "sniper", mortar: "mortar", rocket: "rocket",
           cannon: "cannon", naval_gun: "cannon", torpedo: "torpedo",
           antiship_missile: "rocket", aam: "rocket", agm: "rocket",
           rocket_pod: "rocket", sam_missile: "rocket" },

  /* 戰鬥事件入口（Game.pushFx 逐事件轉呼） */
  event(e){
    if (e.type === "tracer" || e.type === "boom" || e.type === "death")
      this._lastCombatAt = performance.now();               // 供 BGM 平時↔激戰切換
    if (e.type === "tracer")      this.play(this._wmap[e.w] || "rifle");
    else if (e.type === "boom")   this.play("boom");
    else if (e.type === "hitfx"){ if (!e.heal) this.play("hit"); }
    else if (e.type === "death"){
      this.play(e.vehicle ? "vboom" : "death");
      if (e.unit && e.unit.charName) this.voice(e.unit.cls, "down");   // 具名角色倒地語音
    }
  },

  /* ---------- 角色語音（OpenAI TTS 預生成檔，assets/audio/voice/） ---------- */
  _voiceLast: { sel: 0, atk: 0 },
  voice(cls, evt){
    if (this.muted || !cls) return;
    const now = performance.now();
    if ((evt === "sel" || evt === "atk") && now - (this._voiceLast[evt] || 0) < 3500) return;
    this._voiceLast[evt] = now;
    const a = new Audio(`assets/audio/voice/${cls}_${evt}.mp3`);
    a.volume = 0.8; a.play().catch(() => {});
  },

  /* ---------- 程序化環境音（風/浪/鳥，零素材；隨戰場開始/結束啟停） ---------- */
  _amb: { nodes: [], timer: null },
  ambient(mapId, domains){
    this.ambientStop();
    if (!this._ac()) return;
    const c = this.ctx, A = this._amb;
    const wind = c.createBufferSource(); wind.buffer = this._noise(); wind.loop = true;
    const wf = c.createBiquadFilter(); wf.type = "lowpass"; wf.frequency.value = 240;
    const wg = c.createGain(); wg.gain.value = 0.028;
    const lfo = c.createOscillator(); lfo.frequency.value = 0.13;
    const lfoG = c.createGain(); lfoG.gain.value = 0.014;
    lfo.connect(lfoG); lfoG.connect(wg.gain);
    wind.connect(wf); wf.connect(wg); wg.connect(this.master);
    wind.start(); lfo.start();
    A.nodes.push(wind, lfo);
    const sea = domains && domains.includes("sea");
    const woodsy = ["forest", "plain", "town", "verdun", "tutorial"].includes(mapId);
    A.timer = setInterval(() => {
      try {
        if (sea){                                   // 浪湧：帶通噪音緩起緩落
          this._burst({ dur: 2.6, vol: 0.05, type: "bandpass", freq: 420, q: 0.6, atk: 1.1 });
        } else if (woodsy && Math.random() < 0.4){  // 鳥鳴：兩聲短哨
          const f = 2200 + Math.random() * 1400;
          this._tone({ freq: f, freqEnd: f * 1.25, dur: 0.09, vol: 0.02, type: "sine", atk: 0.02 });
          this._tone({ freq: f * 1.1, freqEnd: f * 0.9, dur: 0.12, vol: 0.016, type: "sine", at: 0.15, atk: 0.02 });
        }
      } catch (e) {}
    }, sea ? 3800 : 2600);
  },
  ambientStop(){
    const A = this._amb;
    if (A.timer){ clearInterval(A.timer); A.timer = null; }
    for (const n of A.nodes){ try { n.stop(); } catch (e) {} }
    A.nodes = [];
  },

  /* ---------- 程序化配樂（BGM）----------
   * 零素材：WebAudio 前瞻排程合成。menu=低音氛圍和聲墊；battle=軍鼓行進＋小調動機。
   * 音量刻意壓低（墊在音效底下）。首次手勢解鎖前呼叫會記住意圖，_ac() 就緒後自動開始。 */
  _bgm: { want: null, cur: null, timer: null, step: 0, nextAt: 0 },

  /* ---------- 檔案版 BGM（Kevin MacLeod / incompetech, CC-BY 4.0，署名見 assets/audio/README.md）
   * battle 主題依「6 秒內有無交火」在 battle_calm / battle_intense 間交叉淡切。
   * 任一檔載入失敗 → 該主題自動退回下方程序化合成（_bgmTick），遊戲不中斷。 */
  _files: { menu: "assets/audio/menu.mp3", battle: "assets/audio/battle_calm.mp3",
            battle_intense: "assets/audio/battle_intense.mp3",
            victory: "assets/audio/victory.mp3", defeat: "assets/audio/defeat.mp3" },
  _audio: {}, _fileBroken: {}, _fadeTimer: null, _lastCombatAt: 0, muted: false,
  _vols: { menu: 0.35, battle: 0.4, battle_intense: 0.42 },
  _el(name){
    if (this._fileBroken[name] || !this._files[name]) return null;
    let a = this._audio[name];
    if (!a){
      a = new Audio(this._files[name]); a.preload = "auto";
      a.loop = (name !== "victory" && name !== "defeat"); a.volume = 0;
      a.addEventListener("error", () => { this._fileBroken[name] = true; });
      this._audio[name] = a;
    }
    return a;
  },
  setMuted(m){
    this.muted = m;
    if (m){ for (const k in this._audio){ this._audio[k].pause(); }
      if (this.ctx) this.ctx.suspend(); }
    else if (this.ctx) this.ctx.resume();
  },
  _fadeTick(){
    const B = this._bgm;
    let want = B.want;
    if (want === "battle" && performance.now() - this._lastCombatAt < 6000) want = "battle_intense";
    for (const name of ["menu", "battle", "battle_intense"]){
      const el = this._el(name); if (!el) continue;
      const target = (!this.muted && !document.hidden && name === want) ? this._vols[name] : 0;
      const dv = target - el.volume;
      el.volume = Math.abs(dv) < 0.045 ? target : el.volume + Math.sign(dv) * 0.045;
      if (target > 0 && el.paused) el.play().catch(() => {});
      if (target === 0 && el.volume <= 0.001 && !el.paused) el.pause();
    }
    if (!B.want && this._fadeTimer && ["menu","battle","battle_intense"].every(n => { const e = this._audio[n]; return !e || e.paused; })){
      clearInterval(this._fadeTimer); this._fadeTimer = null;
    }
  },
  bgm(theme){
    const B = this._bgm;
    B.want = theme;
    if (B.timer){ clearInterval(B.timer); B.timer = null; }   // 停程序化合成
    B.cur = theme;
    const baseFile = theme === "battle" ? "battle" : theme;
    if (theme && this._el(baseFile)){                          // 檔案模式
      if (!this._fadeTimer) this._fadeTimer = setInterval(() => this._fadeTick(), 200);
      this._fadeTick();
      return;
    }
    if (this._fadeTimer) this._fadeTick();                     // 淡出殘留檔案音軌
    if (!theme) return;
    if (!this.ctx) return;                                     // 合成 fallback 需 ctx；_ac() 會補啟動
    B.step = 0; B.nextAt = this.ctx.currentTime + 0.15;
    B.timer = setInterval(() => this._bgmTick(), 120);
  },
  _bgmTick(){
    const B = this._bgm, c = this.ctx;
    if (!c || !B.cur){ if (B.timer){ clearInterval(B.timer); B.timer = null; } return; }
    const beat = B.cur === "battle" ? 0.24 : 0.5;            // 每步秒數
    while (B.nextAt < c.currentTime + 0.7){                  // 前瞻 0.7s 排程
      const at = B.nextAt - c.currentTime, s = B.step;
      try {
        if (B.cur === "battle"){
          // 小鼓：鼓身共鳴(190Hz 速降)＋響線(帶通噪音)，皆有起音——不再是喀噠聲
          const snare = [1,0,0,1, 0,0,1,0, 1,0,1,0, 0,1,1,1][s % 16];
          if (snare){
            const acc = s % 4 === 0 ? .022 : 0;
            this._tone({ freq: 190, freqEnd: 120, dur: .1, vol: .05 + acc, type: "triangle", at, atk: .003 });
            this._burst({ dur: .11, vol: .04 + acc, type: "bandpass", freq: 2600, q: 0.8, at, atk: .003 });
          }
          // 低音行進提高到手機喇叭放得出的音域（D3/C3），並疊八度加厚
          if (s % 8 === 0){ this._tone({ freq: 146.8, dur: .5, vol: .05, type: "triangle", at, atk: .02 });
                            this._tone({ freq: 73.4,  dur: .5, vol: .04, type: "sine", at, atk: .02 }); }
          if (s % 8 === 4){ this._tone({ freq: 130.8, dur: .5, vol: .045, type: "triangle", at, atk: .02 });
                            this._tone({ freq: 65.4,  dur: .5, vol: .035, type: "sine", at, atk: .02 }); }
          const motif = [440,0,0,392, 0,349,0,0, 440,0,494,0, 392,0,0,0][s % 16];                 // A 小調動機(高八度)
          if (motif && s % 32 >= 16) this._tone({ freq: motif, dur: .32, vol: .03, type: "triangle", at, atk: .03 });
        } else {                                                                                   // menu 氛圍墊
          if (s % 8 === 0){
            const chords = [[220,329.6,440],[174.6,261.6,349.2],[196,293.7,392],[164.8,246.9,329.6]]; // Am F G Em(高八度)
            const ch = chords[(s / 8 | 0) % 4];
            for (const f of ch){ this._tone({ freq: f, dur: beat * 8.4, vol: .022, type: "triangle", at, atk: .8 });
                                 this._tone({ freq: f * 1.003, dur: beat * 8.4, vol: .014, type: "sine", at, atk: .9 }); } // 微失諧加寬
            this._tone({ freq: ch[0] / 2, dur: beat * 8, vol: .03, type: "triangle", at, atk: .6 });   // 根音
          }
          if (s % 8 === 5) this._tone({ freq: 880, dur: 1.6, vol: .012, type: "sine", at, atk: .5 });  // 高空泛音點綴
        }
      } catch (e) { /* 配樂失敗不得影響遊戲 */ }
      B.step++; B.nextAt += beat;
    }
  }
};

/* 手機/桌機自動播放政策：首次手勢建立 AudioContext */
addEventListener("pointerdown", () => Sfx._ac(), { passive: true });
addEventListener("touchstart",  () => Sfx._ac(), { passive: true });

/* 切到背景/關閉頁面 → 立即停聲；回前景 → 恢復（修「關掉還在響」） */
document.addEventListener("visibilitychange", () => {
  if (document.hidden){ for (const k in Sfx._audio) Sfx._audio[k].pause(); }
  if (!Sfx.ctx) return;
  if (document.hidden){
    if (Sfx._bgm.timer){ clearInterval(Sfx._bgm.timer); Sfx._bgm.timer = null; }
    Sfx.ctx.suspend();
  } else {
    Sfx.ctx.resume();
    if (Sfx._bgm.cur){ const w = Sfx._bgm.cur; Sfx._bgm.cur = null; Sfx.bgm(w); }
  }
});
addEventListener("pagehide", () => { if (Sfx.ctx){ try{ Sfx.ctx.close(); }catch(e){} Sfx.ctx = null;
  if (Sfx._bgm.timer){ clearInterval(Sfx._bgm.timer); Sfx._bgm.timer = null; } Sfx._bgm.cur = null; } });
