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

  /* 白噪音經濾波＋音量包絡：槍聲/爆炸的基底 */
  _burst({ dur = 0.1, vol = 0.5, type = "lowpass", freq = 800, freqEnd = 0, q = 1, at = 0 }){
    const c = this.ctx, t0 = c.currentTime + at;
    const src = c.createBufferSource(); src.buffer = this._noise(); src.loop = true;
    const flt = c.createBiquadFilter(); flt.type = type; flt.Q.value = q;
    flt.frequency.setValueAtTime(freq, t0);
    if (freqEnd) flt.frequency.exponentialRampToValueAtTime(Math.max(30, freqEnd), t0 + dur);
    const g = c.createGain();
    g.gain.setValueAtTime(vol, t0);
    g.gain.exponentialRampToValueAtTime(0.001, t0 + dur);
    src.connect(flt); flt.connect(g); g.connect(this.master);
    src.start(t0); src.stop(t0 + dur + 0.05);
  },

  /* 振盪器單音：滑音包絡（砲擊低鳴/介面音/勝敗旋律） */
  _tone({ freq = 440, freqEnd = 0, dur = 0.15, vol = 0.25, type = "sine", at = 0 }){
    const c = this.ctx, t0 = c.currentTime + at;
    const o = c.createOscillator(); o.type = type;
    o.frequency.setValueAtTime(freq, t0);
    if (freqEnd) o.frequency.exponentialRampToValueAtTime(Math.max(20, freqEnd), t0 + dur);
    const g = c.createGain();
    g.gain.setValueAtTime(vol, t0);
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
    if (e.type === "tracer")      this.play(this._wmap[e.w] || "rifle");
    else if (e.type === "boom")   this.play("boom");
    else if (e.type === "hitfx"){ if (!e.heal) this.play("hit"); }
    else if (e.type === "death")  this.play(e.vehicle ? "vboom" : "death");
  },

  /* ---------- 程序化配樂（BGM）----------
   * 零素材：WebAudio 前瞻排程合成。menu=低音氛圍和聲墊；battle=軍鼓行進＋小調動機。
   * 音量刻意壓低（墊在音效底下）。首次手勢解鎖前呼叫會記住意圖，_ac() 就緒後自動開始。 */
  _bgm: { want: null, cur: null, timer: null, step: 0, nextAt: 0 },
  bgm(theme){
    const B = this._bgm;
    B.want = theme;
    if (!this.ctx) return;                       // 尚未解鎖：_ac() 會補啟動
    if (B.cur === theme) return;
    if (B.timer){ clearInterval(B.timer); B.timer = null; }
    B.cur = theme;
    if (!theme) return;
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
          const snare = [1,0,0,1, 0,0,1,0, 1,0,1,0, 0,1,1,1][s % 16];
          if (snare) this._burst({ dur: .05, vol: .05 + (s % 4 === 0 ? .03 : 0), type: "highpass", freq: 1800, at });
          if (s % 8 === 0) this._tone({ freq: 73.4, dur: .45, vol: .06, type: "sine", at });      // D2 低音行進
          if (s % 8 === 4) this._tone({ freq: 65.4, dur: .45, vol: .05, type: "sine", at });      // C2
          const motif = [220,0,0,196, 0,175,0,0, 220,0,247,0, 196,0,0,0][s % 16];                 // A 小調動機
          if (motif && s % 32 >= 16) this._tone({ freq: motif, dur: .3, vol: .028, type: "triangle", at });
        } else {                                                                                   // menu 氛圍墊
          if (s % 8 === 0){
            const chords = [[110,164.8,220],[87.3,130.8,174.6],[98,146.8,196],[82.4,123.5,164.8]]; // Am F G E
            const ch = chords[(s / 8 | 0) % 4];
            for (const f of ch) this._tone({ freq: f, dur: beat * 8.4, vol: .02, type: "sine", at });
            this._tone({ freq: ch[0] / 2, dur: beat * 8, vol: .03, type: "triangle", at });        // 低八度根音
          }
        }
      } catch (e) { /* 配樂失敗不得影響遊戲 */ }
      B.step++; B.nextAt += beat;
    }
  }
};

/* 手機/桌機自動播放政策：首次手勢建立 AudioContext */
addEventListener("pointerdown", () => Sfx._ac(), { passive: true });
addEventListener("touchstart",  () => Sfx._ac(), { passive: true });
