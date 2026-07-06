/* ============================================================
 * ai.js — 敵方 AI（狀態機，權威：GDD/01 §6）
 * 設計原則：可預測、可解釋。禁止加入隨機大雜燴。
 * 執行模型：AI 回合被拆成「一連串計畫(plan)」，由 game.js
 * 主迴圈逐幀執行（移動有動畫、會觸發玩家警戒射擊）。
 * ============================================================ */
"use strict";

const AI = {

  /* 產生本回合所有計畫。回傳 [{unit, destX, destY, targetId, part}] */
  planTurn(map, side){
    const my = Game.units.filter(u=>u.alive && u.side===side);
    const foes = ()=> Game.units.filter(u=>u.alive && u.side!==side);
    let cp = Game.cpFor(side);
    const plans = [];
    /* 花 CP 順序：先坦克後步兵（GDD/01 §6） */
    const order = my.slice().sort((a,b)=> (b.cls==="tank")-(a.cls==="tank"));
    for (const u of order){
      const cost = u.cls==="tank" ? 2 : 1;
      if (cp < cost) break;
      const plan = this.planUnit(map, u, foes());
      if (!plan) continue;
      cp -= cost;
      plans.push(plan);
    }
    return plans;
  },

  planUnit(map, u, foes){
    if (!foes.length) return null;
    const myBase  = Game.map.bases.find(b=>b.side===u.side);
    const foeBase = Game.map.bases.find(b=>b.side!==u.side);
    const nearest = foes.reduce((a,b)=> dist(u,a)<=dist(u,b)?a:b);

    /* 1. 殘血撤退 */
    if (u.hp < u.maxhp*0.3){
      const cover = this.nearestCover(map, u, myBase);
      return { unit:u, destX:cover.x, destY:cover.y, targetId:null };
    }
    /* 2. 職責行為 */
    let target = null, standoff = 0.6;
    switch(u.cls){
      case "at": {
        const tanks = foes.filter(f=>f.cls==="tank");
        target = tanks.length ? tanks.reduce((a,b)=>dist(u,a)<=dist(u,b)?a:b) : nearest;
        break;
      }
      case "sniper": {
        const soft = foes.filter(f=>f.cls!=="tank");
        target = soft.length ? soft.reduce((a,b)=>a.hp<=b.hp?a:b) : null;
        standoff = 0.9; break;
      }
      case "mg": { // 佔掩體警戒：走向最近沙包後對最近敵開火
        const sb = this.nearestSandbag(map, u);
        return { unit:u, destX:sb.x, destY:sb.y, targetId:nearest.id, part:"body" };
      }
      case "mortar": target = nearest; standoff = 0.85; break;
      case "tank": { // 轟最高價值：坦克>火箭兵>其他
        const pri = f => f.cls==="tank"?3 : f.cls==="at"?2 : 1;
        target = foes.slice().sort((a,b)=> pri(b)-pri(a) || dist(u,a)-dist(u,b))[0];
        break;
      }
      case "engineer": { // 修最近受損友方坦克，否則推進
        const hurt = Game.units.filter(x=>x.alive&&x.side===u.side&&x.cls==="tank"&&x.hp<x.maxhp*0.7);
        if (hurt.length){
          const t = hurt.reduce((a,b)=>dist(u,a)<=dist(u,b)?a:b);
          return { unit:u, destX:t.x+24, destY:t.y, repairId:t.id };
        }
        target = nearest; break;
      }
      default: target = nearest; // 步兵/突擊/特種：推進開火
    }
    if (target){
      const d = u.weapon.range * standoff;
      const ang = Math.atan2(target.y-u.y, target.x-u.x);
      const part = (target.cls==="tank" && u.weapon.antiTank) ? "body" : "body";
      return { unit:u,
        destX: target.x - Math.cos(ang)*d,
        destY: target.y - Math.sin(ang)*d,
        targetId: target.id, part };
    }
    /* 3. 無目標：推向敵主堡 */
    return { unit:u, destX:foeBase.x, destY:foeBase.y, targetId:null };
  },

  nearestCover(map, u, base){
    let best = base, bd = Infinity;
    for (const sb of map.sandbags){
      const p = {x:sb.x+sb.w/2, y:sb.y+sb.h+16};
      const d = dist(u,p);
      if (d<bd){ bd=d; best=p; }
    }
    return best;
  },

  nearestSandbag(map, u){
    let best={x:u.x,y:u.y}, bd=Infinity;
    for (const sb of map.sandbags){
      const p={x:sb.x+sb.w/2, y:sb.y+sb.h+16};
      const d=dist(u,p); if(d<bd){bd=d;best=p;}
    }
    return best;
  }
};
