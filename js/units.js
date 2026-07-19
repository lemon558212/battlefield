/* ============================================================
 * units.js — 單位工廠與幾何工具
 * 數值權威：GDD/02；schema：GDD/03
 * 國家特性(trait)實作切分：
 *   引擎實作：air_recon, marksmanship, conscript_drill, island_defense,
 *             homeland_defense, jungle_craft, tunnel_war, drone_recon,
 *             asymmetric, panzer_doctrine, rapid_reaction
 *   已折算進 mods（程式不再另行處理）：mass_infantry(中), artillery_doctrine(俄),
 *             intel_superiority(以)
 * ============================================================ */
"use strict";

let UNIT_SEQ = 1;

function makeUnit(nationId, clsKey, side, x, y){
  const nation = NATIONS[nationId], base = CLASS_BASE[clsKey], spec = nation.units[clsKey];
  const w = Object.assign({ type: base.wtype }, WEAPON_BASE[base.wtype]);
  const m = spec.mods || {};
  for (const k of Object.keys(m)){
    if (!MOD_KEYS.includes(k)){ console.error("未知 mod 鍵(GDD/03 §2):", nationId, clsKey, k); continue; }
  }
  w.atk   += (m.atk||0);  w.shots += (m.shots||0);
  w.range += (m.range||0); w.acc  = Math.min(0.99, w.acc + (m.acc||0));
  let hp = base.hp + (m.hp||0), ap = base.ap + (m.ap||0), def = base.def + (m.def||0), cost = base.cost + (m.cost||0);
  if (nation.trait.id === "conscript_drill") ap = Math.round(ap * 1.05);
  const domain = base.domain || "land";
  const radius = domain==="sea" ? (base.big?18:12) : domain==="air" ? 13 : (clsKey==="tank"?16:10);
  return {
    id: UNIT_SEQ++, side, nationId, cls: clsKey,
    label: spec.label, weaponName: spec.weapon, weapon: w,
    x, y, r: radius,
    hp, maxhp: hp, ap, maxap: ap, def, cost,
    alive: true, actedCount: 0, hasFired: false, revealed: false,
    crouched: false, terrainAction: null,
    alert: base.alert, canCap: base.canCap,
    domain, mobility: base.mobility || domain, sight: base.sight||120, airSight: base.airSight||0,
    flying: domain==="air", stealth: !!base.stealth, big: !!base.big,
    carried: [],           // lst 載運的 land 單位
    facing: side === 0 ? 0 : Math.PI
  };
}

function unitCost(nationId, clsKey){
  return CLASS_BASE[clsKey].cost + ((NATIONS[nationId].units[clsKey].mods||{}).cost || 0);
}

/* ---------- 幾何 ---------- */
const dist = (a,b)=> Math.hypot(a.x-b.x, a.y-b.y);
const clamp = (v,lo,hi)=> v<lo?lo : v>hi?hi : v;

function ptInRect(px,py,r){ return px>=r.x && px<=r.x+r.w && py>=r.y && py<=r.y+r.h; }

/* 線段與矩形是否相交（視線判定用） */
function segRect(x1,y1,x2,y2,r){
  if (ptInRect(x1,y1,r) || ptInRect(x2,y2,r)) return true;
  const edges = [
    [r.x,r.y,r.x+r.w,r.y],[r.x,r.y+r.h,r.x+r.w,r.y+r.h],
    [r.x,r.y,r.x,r.y+r.h],[r.x+r.w,r.y,r.x+r.w,r.y+r.h]
  ];
  return edges.some(e=>segSeg(x1,y1,x2,y2,e[0],e[1],e[2],e[3]));
}
function segSeg(a,b,c,d,p,q,r,s){
  const det=(c-a)*(s-q)-(r-p)*(d-b);
  if (Math.abs(det)<1e-9) return false;
  const l=((s-q)*(r-a)+(p-r)*(s-b))/det, g=((b-d)*(r-a)+(c-a)*(s-b))/det;
  return l>=0&&l<=1&&g>=0&&g<=1;
}

function circleRectHit(cx,cy,cr,r){
  const nx=clamp(cx,r.x,r.x+r.w), ny=clamp(cy,r.y,r.y+r.h);
  return (cx-nx)*(cx-nx)+(cy-ny)*(cy-ny) <= cr*cr;
}
