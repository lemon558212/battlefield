/* ============================================================
 * data-characters.js — 曙光特遣隊具名隊員（角色部門，規格：GDD/09）
 * 原創角色。劇情模式中：玩家每兵種第一個部署的單位由對應角色出任，
 * 套用 trait 數值修正並顯示名字與立繪。mods 鍵沿用 GDD/03 MOD_KEYS。
 * ============================================================ */
"use strict";

const CHARACTERS = {
  sniper: {
    unlockCh: 1,
    name: "韓沐霜", callsign: "霜", portrait: "assets/portraits/sniper.jpg", fullPortrait: "assets/portraits-full/sniper.jpg",
    moods: { angry: "assets/portraits-full/sniper_angry.jpg", hurt: "assets/portraits-full/sniper_hurt.jpg", smile: "assets/portraits-full/sniper_smile.jpg" },
    line: "每一發子彈都要有名字。",
    trait: { desc: "神射手：命中 +6%", mods: { acc: 0.06 } }
  },
  mg: {
    unlockCh: 2,
    name: "雷諾．佛斯", callsign: "老雷", portrait: "assets/portraits/mg.jpg", fullPortrait: "assets/portraits-full/mg.jpg",
    moods: { angry: "assets/portraits-full/mg_angry.jpg", hurt: "assets/portraits-full/mg_hurt.jpg", smile: "assets/portraits-full/mg_smile.jpg" },
    line: "我知道他們怎麼想——因為我曾是他們。",
    trait: { desc: "壓制本能：攻擊 +2、HP +40", mods: { atk: 2, hp: 40 } }
  },
  rifleman: {
    unlockCh: 1,
    name: "丁小滿", callsign: "小滿", portrait: "assets/portraits/rifleman.jpg", fullPortrait: "assets/portraits-full/rifleman.jpg",
    moods: { angry: "assets/portraits-full/rifleman_angry.jpg", hurt: "assets/portraits-full/rifleman_hurt.jpg", smile: "assets/portraits-full/rifleman_smile.jpg" },
    line: "班長說跟著我走，準沒錯。",
    trait: { desc: "老兵之勇：HP +60", mods: { hp: 60 } }
  },
  assault: {
    unlockCh: 2,
    name: "艾拉．科瓦奇", callsign: "火花", portrait: "assets/portraits/assault.jpg", fullPortrait: "assets/portraits-full/assault.jpg",
    moods: { angry: "assets/portraits-full/assault_angry.jpg", hurt: "assets/portraits-full/assault_hurt.jpg", smile: "assets/portraits-full/assault_smile.jpg" },
    line: "衝第一個的人，看得最清楚。",
    trait: { desc: "突擊先鋒：AP +12", mods: { ap: 12 } }
  },
  at: {
    unlockCh: 3,
    name: "巴頓．歐克", callsign: "鐵鎚", portrait: "assets/portraits/at.jpg", fullPortrait: "assets/portraits-full/at.jpg",
    moods: { angry: "assets/portraits-full/at_angry.jpg", hurt: "assets/portraits-full/at_hurt.jpg", smile: "assets/portraits-full/at_smile.jpg" },
    line: "坦克？那只是比較大的靶子。",
    trait: { desc: "獵殺本能：攻擊 +3", mods: { atk: 3 } }
  },
  mortar: {
    unlockCh: 3,
    name: "賽琳．杜瓦", callsign: "雨傘", portrait: "assets/portraits/mortar.jpg", fullPortrait: "assets/portraits-full/mortar.jpg",
    moods: { angry: "assets/portraits-full/mortar_angry.jpg", hurt: "assets/portraits-full/mortar_hurt.jpg", smile: "assets/portraits-full/mortar_smile.jpg" },
    line: "拋物線是世界上最誠實的曲線。",
    trait: { desc: "精算落點：命中 +5%、射程 +10", mods: { acc: 0.05, range: 10 } }
  },
  engineer: {
    unlockCh: 1,
    name: "白老師", callsign: "白老師", portrait: "assets/portraits/engineer.jpg", fullPortrait: "assets/portraits-full/engineer.jpg",
    moods: { angry: "assets/portraits-full/engineer_angry.jpg", hurt: "assets/portraits-full/engineer_hurt.jpg", smile: "assets/portraits-full/engineer_smile.jpg" },
    line: "壞掉的東西都能修，人心也是。",
    trait: { desc: "巧手：HP +40、AP +8", mods: { hp: 40, ap: 8 } }
  },
  sam: {
    unlockCh: 5,
    name: "汀娜．烏梅", callsign: "望天", portrait: "assets/portraits/sam.jpg", fullPortrait: "assets/portraits-full/sam.jpg",
    moods: { angry: "assets/portraits-full/sam_angry.jpg", hurt: "assets/portraits-full/sam_hurt.jpg", smile: "assets/portraits-full/sam_smile.jpg" },
    line: "天上飛的，遲早要下來。",
    trait: { desc: "鷹眼：命中 +6%", mods: { acc: 0.06 } }
  },
  specops: {
    unlockCh: 4,
    name: "影山靜", callsign: "無聲", portrait: "assets/portraits/specops.jpg", fullPortrait: "assets/portraits-full/specops.jpg",
    moods: { angry: "assets/portraits-full/specops_angry.jpg", hurt: "assets/portraits-full/specops_hurt.jpg", smile: "assets/portraits-full/specops_smile.jpg" },
    line: "……（點了點頭）",
    trait: { desc: "幽影：AP +10、HP +20", mods: { ap: 10, hp: 20 } }
  }
};

/* 載具依章解鎖（GDD/09 名冊制） */
const VEHICLE_UNLOCK = { tank:5, fighter:5, attacker:5, gunship:5, destroyer:8, lst:8, missileboat:9, submarine:9 };

/* 載具立繪（無具名角色的兵種：戰車/海軍/空軍，角色卡用） */
const VEHICLE_ART = {
  tank:        "assets/portraits-full/tank.jpg",
  destroyer:   "assets/portraits-full/destroyer.jpg",
  missileboat: "assets/portraits-full/missileboat.jpg",
  lst:         "assets/portraits-full/lst.jpg",
  submarine:   "assets/portraits-full/submarine.jpg",
  fighter:     "assets/portraits-full/fighter.jpg",
  attacker:    "assets/portraits-full/attacker.jpg",
  gunship:     "assets/portraits-full/gunship.jpg"
};

/* ---------- 養成（§C⑤ 2026-07-21）：具名隊員經驗/等級，localStorage 跨戰役持久 ---------- */
const CharGrowth = {
  key: "bf_char_xp",
  data(){ try { return JSON.parse(localStorage.getItem(this.key) || "{}"); } catch(e){ return {}; } },
  _save(d){ try { localStorage.setItem(this.key, JSON.stringify(d)); } catch(e){} },
  xp(cls){ return this.data()[cls] || 0; },
  level(cls){ return Math.min(5, 1 + Math.floor(this.xp(cls) / 120)); },      // 120 經驗一級，上限 Lv5
  award(cls, amt){ const d = this.data(); d[cls] = (d[cls] || 0) + amt; this._save(d); },
  reset(){ localStorage.removeItem(this.key); }
};

/* 羈絆（§C⑤）：劇情配對；戰場上兩人相距 130 內互相加成（命中+4%／受傷-6%）。 */
const BONDS = [["sniper","rifleman"],["engineer","rifleman"],["mg","assault"],["mortar","at"],["specops","assault"],["sam","mortar"]];
function bondAllyNear(u){
  if (!u.charName || !Game.storyChapter) return false;
  for (const [a, b] of BONDS){
    if (u.cls !== a && u.cls !== b) continue;
    const mate = u.cls === a ? b : a;
    const m = Game.units.find(x => x.alive && x.side === u.side && x.cls === mate && x.charName);
    if (m && Math.hypot(m.x - u.x, m.y - u.y) <= 130) return true;
  }
  return false;
}

/* 劇情模式：套用具名角色到單位（名冊制 GDD/09：玩家明確選擇具名條目才指派，每場一次）。 */
function assignCharacter(u, wantNamed){
  if (!Game.storyChapter || u.side !== Game.playerSide || !wantNamed) return null;
  const ch = CHARACTERS[u.cls];
  if (!ch) return null;
  if ((ch.unlockCh || 1) > Game.storyChapter) return null;
  Game._charAssigned = Game._charAssigned || {};
  if (Game._charAssigned[u.cls]) return null;
  Game._charAssigned[u.cls] = true;
  const m = ch.trait.mods || {};
  u.weapon.atk += (m.atk || 0); u.weapon.range += (m.range || 0);
  u.weapon.acc = Math.min(0.99, u.weapon.acc + (m.acc || 0));
  u.hp += (m.hp || 0); u.maxhp += (m.hp || 0);
  u.ap += (m.ap || 0); u.maxap += (m.ap || 0);
  // 等級加成（§C⑤）：每級 +6% 攻擊、+8% HP、+2% 命中（Lv1 無加成，上限 Lv5）
  const lv = (typeof CharGrowth !== "undefined") ? CharGrowth.level(u.cls) : 1;
  if (lv > 1){
    const k = lv - 1;
    u.weapon.atk = Math.round(u.weapon.atk * (1 + 0.06 * k));
    u.weapon.acc = Math.min(0.99, u.weapon.acc + 0.02 * k);
    const hpUp = Math.round(u.maxhp * 0.08 * k);
    u.hp += hpUp; u.maxhp += hpUp;
  }
  u.charLv = lv;
  u.charName = ch.name; u.label = "★" + ch.name + (lv > 1 ? ` Lv.${lv}` : "") + "｜" + u.label;
  return ch;
}
