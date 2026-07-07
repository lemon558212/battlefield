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
    // 迷霧公平性（GDD/05 §5）：AI 只鎖定己方視野看得到的敵人
    const foes = ()=> Game.units.filter(u=>u.alive && u.side!==side && Fog.sideCanSee(side,u));
    let cp = Game.cpFor(side);
    const plans = [];
    /* 花 CP 順序：先坦克後步兵（GDD/01 §6） */
    const order = my.slice().sort((a,b)=> (b.cls==="tank")-(a.cls==="tank"));
    for (const u of order){
      const cost = (u.cls==="tank" || u.big || u.domain==="air") ? 2 : 1;
      if (cp < cost) break;
      const plan = this.planUnit(map, u, foes());
      if (!plan) continue;
      cp -= cost;
      plans.push(plan);
    }
    return plans;
  },

  planUnit(map, u, foes){
    const myBase  = Game.map.bases.find(b=>b.side===u.side);
    const foeBase = Game.map.bases.find(b=>b.side!==u.side);
    // 看不到任何敵人（迷霧）→ 前進偵察，推向敵主堡（不可呆站，否則永不接敵）
    if (!foes.length) return { unit:u, destX:foeBase.x, destY:foeBase.y, targetId:null };
    // 只鎖定「打得到的」敵人（三軍剋制 GDD/04 §8）；全打不到則推進佔點
    const hittable = foes.filter(f=>Combat.domainMult(u.weapon,f)>0);

    /* 1. 殘血撤退 */
    if (u.hp < u.maxhp*0.3){
      const cover = this.nearestCover(map, u, myBase);
      return { unit:u, destX:cover.x, destY:cover.y, targetId:null };
    }
    if (!hittable.length) return { unit:u, destX:foeBase.x, destY:foeBase.y, targetId:null }; // 看得到但打不到→推進

    const pool = hittable;
    const nearest = pool.reduce((a,b)=> dist(u,a)<=dist(u,b)?a:b);
    /* 2. 職責行為 */
    let target = null, standoff = 0.6;
    switch(u.cls){
      case "at": {
        const tanks = pool.filter(f=>f.cls==="tank");
        target = tanks.length ? tanks.reduce((a,b)=>dist(u,a)<=dist(u,b)?a:b) : nearest;
        break;
      }
      case "sniper": {
        const soft = pool.filter(f=>f.cls!=="tank");
        target = soft.length ? soft.reduce((a,b)=>a.hp<=b.hp?a:b) : nearest;
        standoff = 0.9; break;
      }
      case "mg": {
        const sb = this.nearestSandbag(map, u);
        return { unit:u, destX:sb.x, destY:sb.y, targetId:nearest.id, part:"body" };
      }
      case "sam": case "fighter": standoff = 0.7; target = nearest; break;   // 對空（pool 已是可打的空目標）
      case "destroyer": case "missileboat": case "submarine": {              // 反艦：大艦優先
        const big = pool.filter(f=>f.big);
        target = big.length ? big.reduce((a,b)=>dist(u,a)<=dist(u,b)?a:b) : nearest; standoff = 0.7; break;
      }
      case "mortar": case "attacker": case "gunship": target = nearest; standoff = 0.82; break;
      case "tank": {
        const pri = f => f.cls==="tank"?3 : f.cls==="at"?2 : 1;
        target = pool.slice().sort((a,b)=> pri(b)-pri(a) || dist(u,a)-dist(u,b))[0];
        break;
      }
      case "engineer": {
        const hurt = Game.units.filter(x=>x.alive&&x.side===u.side&&x.cls==="tank"&&x.hp<x.maxhp*0.7);
        if (hurt.length){
          const t = hurt.reduce((a,b)=>dist(u,a)<=dist(u,b)?a:b);
          return { unit:u, destX:t.x+24, destY:t.y, repairId:t.id };
        }
        target = nearest; break;
      }
      default: target = nearest;
    }
    if (target){
      const d = u.weapon.range * standoff;
      const ang = Math.atan2(target.y-u.y, target.x-u.x);
      return { unit:u, destX: target.x - Math.cos(ang)*d, destY: target.y - Math.sin(ang)*d, targetId: target.id, part:"body" };
    }
    return { unit:u, destX:foeBase.x, destY:foeBase.y, targetId:null };
  },

  nearestCover(map, u, base){
    let best = base, bd = Infinity;
    for (const sb of (map.sandbags||[])){
      const p = {x:sb.x+sb.w/2, y:sb.y+sb.h+16};
      const d = dist(u,p);
      if (d<bd){ bd=d; best=p; }
    }
    return best;
  },

  nearestSandbag(map, u){
    let best={x:u.x,y:u.y}, bd=Infinity;
    for (const sb of (map.sandbags||[])){
      const p={x:sb.x+sb.w/2, y:sb.y+sb.h+16};
      const d=dist(u,p); if(d<bd){bd=d;best=p;}
    }
    return best;
  }
};
