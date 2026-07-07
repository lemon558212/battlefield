# -*- coding: utf-8 -*-
import io
p="js/game.js"; s=io.open(p,encoding="utf-8").read(); orig=s
report=[]

# --- 1) render() 的地形繪製改為貼上離屏預渲染地形 ---
old_terrain = '''    c.fillStyle=m.ground; c.fillRect(0,0,960,600);
    for (const w of (m.deepwaters||[])){ c.fillStyle="#2b5570"; c.fillRect(w.x,w.y,w.w,w.h); }
    for (const w of (m.waters||[])){ c.fillStyle="#3f7391"; c.fillRect(w.x,w.y,w.w,w.h); }
    for (const w of (m.shallows||[])){ c.fillStyle="#6ea3b8"; c.fillRect(w.x,w.y,w.w,w.h); }
    for (const w of (m.reefs||[])){ c.fillStyle="#5a5f52"; c.fillRect(w.x,w.y,w.w,w.h); c.strokeStyle="#3f4438"; c.strokeRect(w.x,w.y,w.w,w.h); }
    for (const b of m.bushes){ c.fillStyle="rgba(40,90,35,0.85)"; c.beginPath(); c.arc(b.x,b.y,b.r,0,7); c.fill(); }
    for (const s of m.sandbags){ c.fillStyle="#b09761"; c.fillRect(s.x,s.y,s.w,s.h); c.strokeStyle="#7d6a44"; c.strokeRect(s.x,s.y,s.w,s.h); }
    for (const s of m.solids){ c.fillStyle="#6e6e6e"; c.fillRect(s.x,s.y,s.w,s.h); c.strokeStyle="#4a4a4a"; c.strokeRect(s.x,s.y,s.w,s.h); }'''
new_terrain = '''    if (!this._bg || this._bgMap!==m) this.buildTerrain(m);
    c.drawImage(this._bg, 0, 0);'''
if old_terrain in s: s=s.replace(old_terrain,new_terrain,1); report.append("terrain:OK")
else: report.append("terrain:MISS")

# --- 2) 新增 buildTerrain 方法（插在 render(){ 之前）---
build = '''  /* 一次性把靜態地形預渲染到離屏 canvas（每幀只需貼上，手機也順） */
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

  render(){'''
if '  render(){' in s: s=s.replace('  render(){', build, 1); report.append("build:OK")
else: report.append("build:MISS")

# --- 3) drawFx 升級（槍口閃光/命中火花/爆炸碎片煙/死亡煙）---
old_fx_anchor = 'drawFx(c,f){'
i=s.find(old_fx_anchor)
j=s.find('\n  },', i)
old_fx = s[i:j+4]
new_fx = '''drawFx(c,f){
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
  },'''
if old_fx and old_fx.startswith('drawFx'): s=s.replace(old_fx,new_fx,1); report.append("fx:OK")
else: report.append("fx:MISS")

io.open(p,"w",encoding="utf-8").write(s)
print(report, "len", len(orig), "->", len(s))
