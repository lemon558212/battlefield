/* ============================================================
 * combat.js — 命中/傷害/視線/掩體/警戒射擊
 * 公式唯一權威：GDD/01-戰鬥系統.md §3~§4，改公式先改 GDD
 * ============================================================ */
"use strict";

const Combat = {

  /* 視線是否被 solid/bunker 阻擋。
     規則：blocker 若「包含目標點」則對該目標不生效（碉堡內佔員可經射口被看見/射擊）。 */
  losBlocked(map, x1,y1,x2,y2){
    const blockers = (map.solids||[]).concat(map.bunkers||[]);
    return blockers.some(s => !ptInRect(x2,y2,s) && segRect(x1,y1,x2,y2,s));
  },

  inBush(map, u){
    return (map.bushes||[]).some(b=> Math.hypot(u.x-b.x,u.y-b.y) <= b.r);
  },

  /* 目標命中倍率（越小越受保護）。取所有掩體最佳者。
     沙包/礁石：方向性（射線穿過且貼身 ≤28px）。工事：站進去即生效（角度無關）。 */
  coverFactor(map, sx,sy, t){
    if (!t.crouched) return 1.0;
    let f = 1.0;
    for (const sb of (map.sandbags||[]).concat(map.reefs||[])){
      const nx=clamp(t.x,sb.x,sb.x+sb.w), ny=clamp(t.y,sb.y,sb.y+sb.h);
      if (Math.hypot(t.x-nx,t.y-ny)<=28 && segRect(sx,sy,t.x,t.y,sb)){ f=Math.min(f,0.5); break; }
    }
    for (const b of (map.bunkers||[]))  if (ptInRect(t.x,t.y,b))  { f=Math.min(f,0.3); break; } // 碉堡：重掩體
    for (const tr of (map.trenches||[])) if (ptInRect(t.x,t.y,tr)) { f=Math.min(f,0.4); break; } // 壕溝
    for (const h of (map.foxholes||[]).concat(map.craters||[]))
      if (Math.hypot(t.x-h.x,t.y-h.y)<=h.r) { f=Math.min(f,0.5); break; }                        // 散兵坑/彈坑
    for(const s of (map.solids||[])){
      const nx=clamp(t.x,s.x,s.x+s.w),ny=clamp(t.y,s.y,s.y+s.h);
      if(!ptInRect(t.x,t.y,s)&&Math.hypot(t.x-nx,t.y-ny)<=24){f=Math.min(f,0.65);break;}
    }
    return f;
  },

  /* 隱蔽判定：目標在草叢且未暴露 → 看不見（除非近距/特性） */
  canSee(map, viewer, t, turn){
    if (!t.alive) return false;
    if (!t.flying && this.losBlocked(map, viewer.x,viewer.y,t.x,t.y)) return false;  // 空中單位無視地形遮蔽
    if (t.stealth && !t.revealed){                                                    // 潛艦潛航：近距或驅逐艦反潛才可見
      if (dist(viewer,t) > 80 && viewer.cls!=="destroyer") return false;
    }
    if (this.inBush(map,t) && t.crouched && !t.revealed){
      let detect = 60;
      if (NATIONS[t.nationId].trait.id==="jungle_craft") detect = 30;               // 泰國
      if (t.cls==="specops") detect = 0;                                            // 特種兵草叢完全隱蔽
      if (NATIONS[viewer.nationId].trait.id==="drone_recon" && turn<=3) return true; // 烏克蘭
      return dist(viewer,t) < detect;
    }
    return true;
  },

  /* 命中率（GDD/01 §4）。part: "body"|"head"|"radiator" */
  hitChance(map, shooter, t, part){
    const w = shooter.weapon;
    const d = dist(shooter,t);
    if (d > w.range) return 0;
    let c = w.acc;
    if (NATIONS[shooter.nationId].trait.id==="marksmanship") c += 0.03; // 英國
    if (typeof bondAllyNear==="function" && bondAllyNear(shooter)) c += 0.04; // 羈絆（§C⑤）：搭檔在附近
    c *= d/w.range <= 0.5 ? 1.0 : 1.0 - 0.45*((d/w.range)-0.5)/0.5;
    c *= part==="head" ? 0.55 : part==="radiator" ? 0.75 : 1.0;
    if (this.domainMult(w,t)<=0) return 0;            // 武器打不到此域（如步槍打飛機）
    if (!w.arc){
      if (!t.flying && this.losBlocked(map, shooter.x,shooter.y,t.x,t.y)) return 0; // 空中目標不被地形擋
      if (!t.flying) c *= this.coverFactor(map, shooter.x,shooter.y,t);
    } else {
      c *= 0.7; // 拋物線武器
    }
    return clamp(c,0,0.99);
  },

  partMult(part){ return part==="head" ? 2.0 : part==="radiator" ? 3.0 : 1.0; },

  /* 單發傷害 */
  /* 跨作戰域剋制倍率（GDD/04 §8）。回傳 0 = 此武器打不到該域目標 */
  domainMult(w, t){
    const dom = t.domain || "land";
    if (w.antiAirOnly) return dom==="air" ? 1.0 : 0;          // SAM 只打空
    if (w.seaOnly)     return dom==="sea" ? 1.0 : 0;          // 魚雷只打海
    if (dom==="air")   return (w.antiAir!=null ? w.antiAir : 0); // 打空需具對空能力
    if (dom==="sea"){
      const heavyNaval = w.antiShip || ["naval_gun","torpedo","agm","rocket_pod"].includes(w.type);
      if (t.big) return w.antiShip ? w.antiShip : (heavyNaval ? 1.0 : 0.06); // 大艦：輕武器刮漆
      return w.antiShip ? w.antiShip : 1.0;                   // 小艇：誰都能傷
    }
    let mm = 1.0;                                             // land
    if (w.antiGround) mm *= w.antiGround;
    if (w.airToGround!=null) mm *= w.airToGround;             // 戰機對地弱
    return mm;
  },

  damage(shooter, t, part, interception=false){
    const w = shooter.weapon;
    let mult = this.domainMult(w, t);
    if (mult<=0) return 0;                                    // 打不到此域
    if ((t.domain||"land")==="land"){                         // 陸戰坦克剋制（沿用 v1）
      if (!w.antiTank && !w.arc && !w.antiGround && t.cls==="tank") return 1; // 槍械刮漆坦克
      if (w.antiTank && t.cls!=="tank") mult *= 0.6;          // 火箭打步兵濺傷減半
    }
    let def = t.def;
    if (NATIONS[t.nationId].trait.id==="island_defense" && Game.onOwnHalf(t)) def += 3; // 日本
    const effAtk = w.atk * mult;
    let dmg = effAtk * this.partMult(part) * Math.max(0.1, 1 - def/Math.max(1,effAtk)*0.5);
    if (interception) dmg *= 0.5;
    if (NATIONS[t.nationId].trait.id==="homeland_defense" && t.side===1) dmg *= 0.9;    // 台灣
    if (typeof bondAllyNear==="function" && bondAllyNear(t)) dmg *= 0.94;               // 羈絆（§C⑤）：搭檔在附近較敢戰
    return Math.max(1, Math.round(dmg));
  },

  /* 開火：回傳事件陣列供渲染。part 僅第一目標，濺射一律 body */
  fire(map, shooter, target, part, interception=false){
    const w = shooter.weapon, ev = [];
    let scatterX = target.x, scatterY = target.y;
    if (w.arc){ // 迫砲/砲彈落點散布（GDD/01 §4）
      let sc = dist(shooter,target)*0.08;
      if (NATIONS[shooter.nationId].trait.id==="air_recon") sc *= 0.8; // 美國
      const a = Math.random()*Math.PI*2, rr = Math.random()*sc;
      scatterX += Math.cos(a)*rr; scatterY += Math.sin(a)*rr;
    }
    for (let i=0;i<w.shots;i++){
      const chance = this.hitChance(map, shooter, target, part);
      const hit = Math.random() < chance;
      ev.push({type:"tracer", x1:shooter.x,y1:shooter.y, x2:scatterX+(Math.random()*8-4), y2:scatterY+(Math.random()*8-4), hit, w:w.type});
      if (hit){
        const dmg = this.damage(shooter, target, part, interception);
        target.hp -= dmg;
        ev.push({type:"hitfx", x:target.x, y:target.y, dmg});
      }
    }
    if (w.splash>0){ // 濺射
      ev.push({type:"boom", x:scatterX, y:scatterY, r:w.splash});
      for (const u of Game.units){
        if (!u.alive || u===target) continue;
        if (Math.hypot(u.x-scatterX,u.y-scatterY) <= w.splash){
          const dmg = Math.round(this.damage(shooter,u,"body",interception)*0.5);
          u.hp -= dmg; ev.push({type:"hitfx", x:u.x,y:u.y, dmg});
        }
      }
    }
    // 開火暴露（伊朗不對稱作戰：火箭兵首次開火不暴露）
    const iranStealth = NATIONS[shooter.nationId].trait.id==="asymmetric" && shooter.cls==="at" && !shooter.hasFired;
    if (!iranStealth) shooter.revealed = true;
    shooter.hasFired = true;
    for (const u of Game.units){ if (u.alive && u.hp<=0){ u.alive=false;
      // 養成（§C⑤）：具名隊員擊殺得經驗（載具 60／步兵 35），跨戰役累積
      if (Game.storyChapter && shooter.charName && u.side !== shooter.side && typeof CharGrowth !== "undefined"){
        let gain = ((u.domain||"land")!=="land"||u.cls==="tank") ? 60 : 35;
        if (u.isAce) gain *= 2;                                             // 敵將雙倍經驗（§C⑥）
        const before = CharGrowth.level(shooter.cls);
        CharGrowth.award(shooter.cls, gain);
        if (CharGrowth.level(shooter.cls) > before) ev.push({type:"text", x:shooter.x, y:shooter.y, msg:`★${shooter.charName} 升級！`});
      }
      if (u.isAce) ev.push({type:"text", x:u.x, y:u.y, msg:`☠ 敵將 ${u.label.split("｜")[0].slice(1)} 陣亡！`});
      ev.push({type:"death", x:u.x,y:u.y, unit:u, vehicle:(u.domain||"land")!=="land"||u.cls==="tank"}); } }
    return ev;
  },

  /* 警戒射擊（GDD/01 §3）：mover 移動中，敵方警戒單位檢查開火
     回傳事件陣列。呼叫端負責節流（0.5s / 機槍 0.25s） */
  interceptTick(map, mover, elapsed){
    const ev = [];
    for (const u of Game.units){
      if (!u.alive || u.side===mover.side || !u.alert) continue;
      const gap = u.cls==="mg" ? 0.25 : 0.5;
      u._iceTimer = (u._iceTimer||0) + elapsed;
      if (u._iceTimer < gap) continue;
      if (dist(u,mover) > u.weapon.range*0.8) continue;
      if (this.domainMult(u.weapon, mover)<=0) continue;   // 只在打得到該域時攔截（步兵不空放對空、SAM 不打地面）
      if (!this.canSee(map, u, mover, Game.turn)) continue;
      u._iceTimer = 0;
      ev.push(...this.fire(map, u, mover, "body", true));
    }
    return ev;
  }
};
