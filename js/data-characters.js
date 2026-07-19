/* ============================================================
 * data-characters.js — 曙光特遣隊具名隊員（角色部門，規格：GDD/09）
 * 原創角色。劇情模式中：玩家每兵種第一個部署的單位由對應角色出任，
 * 套用 trait 數值修正並顯示名字與立繪。mods 鍵沿用 GDD/03 MOD_KEYS。
 * ============================================================ */
"use strict";

const CHARACTERS = {
  sniper: {
    name: "韓沐霜", callsign: "霜", portrait: "assets/portraits/sniper.jpg", fullPortrait: "assets/portraits-full/sniper.jpg",
    line: "每一發子彈都要有名字。",
    trait: { desc: "神射手：命中 +6%", mods: { acc: 0.06 } }
  },
  mg: {
    name: "雷諾．佛斯", callsign: "老雷", portrait: "assets/portraits/mg.jpg", fullPortrait: "assets/portraits-full/mg.jpg",
    line: "我知道他們怎麼想——因為我曾是他們。",
    trait: { desc: "壓制本能：攻擊 +2、HP +40", mods: { atk: 2, hp: 40 } }
  },
  rifleman: {
    name: "丁小滿", callsign: "小滿", portrait: "assets/portraits/rifleman.jpg", fullPortrait: "assets/portraits-full/rifleman.jpg",
    line: "班長說跟著我走，準沒錯。",
    trait: { desc: "老兵之勇：HP +60", mods: { hp: 60 } }
  },
  assault: {
    name: "艾拉．科瓦奇", callsign: "火花", portrait: "assets/portraits/assault.jpg", fullPortrait: "assets/portraits-full/assault.jpg",
    line: "衝第一個的人，看得最清楚。",
    trait: { desc: "突擊先鋒：AP +12", mods: { ap: 12 } }
  },
  at: {
    name: "巴頓．歐克", callsign: "鐵鎚", portrait: "assets/portraits/at.jpg", fullPortrait: "assets/portraits-full/at.jpg",
    line: "坦克？那只是比較大的靶子。",
    trait: { desc: "獵殺本能：攻擊 +3", mods: { atk: 3 } }
  },
  mortar: {
    name: "賽琳．杜瓦", callsign: "雨傘", portrait: "assets/portraits/mortar.jpg", fullPortrait: "assets/portraits-full/mortar.jpg",
    line: "拋物線是世界上最誠實的曲線。",
    trait: { desc: "精算落點：命中 +5%、射程 +10", mods: { acc: 0.05, range: 10 } }
  },
  engineer: {
    name: "白老師", callsign: "白老師", portrait: "assets/portraits/engineer.jpg", fullPortrait: "assets/portraits-full/engineer.jpg",
    line: "壞掉的東西都能修，人心也是。",
    trait: { desc: "巧手：HP +40、AP +8", mods: { hp: 40, ap: 8 } }
  },
  sam: {
    name: "汀娜．烏梅", callsign: "望天", portrait: "assets/portraits/sam.jpg", fullPortrait: "assets/portraits-full/sam.jpg",
    line: "天上飛的，遲早要下來。",
    trait: { desc: "鷹眼：命中 +6%", mods: { acc: 0.06 } }
  },
  specops: {
    name: "影山靜", callsign: "無聲", portrait: "assets/portraits/specops.jpg", fullPortrait: "assets/portraits-full/specops.jpg",
    line: "……（點了點頭）",
    trait: { desc: "幽影：AP +10、HP +20", mods: { ap: 10, hp: 20 } }
  }
};

/* 劇情模式：套用角色到單位（每兵種每場一次）。回傳角色或 null。 */
function assignCharacter(u){
  if (!Game.storyChapter || u.side !== Game.playerSide) return null;
  const ch = CHARACTERS[u.cls];
  if (!ch) return null;
  Game._charAssigned = Game._charAssigned || {};
  if (Game._charAssigned[u.cls]) return null;
  Game._charAssigned[u.cls] = true;
  const m = ch.trait.mods || {};
  u.weapon.atk += (m.atk || 0); u.weapon.range += (m.range || 0);
  u.weapon.acc = Math.min(0.99, u.weapon.acc + (m.acc || 0));
  u.hp += (m.hp || 0); u.maxhp += (m.hp || 0);
  u.ap += (m.ap || 0); u.maxap += (m.ap || 0);
  u.charName = ch.name; u.label = "★" + ch.name + "｜" + u.label;
  return ch;
}
