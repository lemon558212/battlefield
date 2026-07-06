/* ============================================================
 * data-nations.js — 14 國建制兵種與制式武器（公開資訊）
 * Schema 權威：GDD/03-國家資料規格.md
 * 武器查證：research/各國軍備研究.md（標「※」者未完全確認）
 * mods 白名單：atk shots range acc hp ap def cost（±15% 內）
 * ============================================================ */
"use strict";

const NATIONS = {

usa: {
  id:"usa", name:"美國", flagColors:["#3C3B6E","#B22234","#FFFFFF"], uniformColor:"#5a5f45",
  trait:{ id:"air_recon", desc:"空中偵蒐：迫砲落點散布 -20%" },
  units:{
    rifleman:{ label:"步槍兵",   weapon:"M4A1 卡賓槍",        mods:{ acc:0.04 } },
    assault: { label:"突擊步兵", weapon:"M4A1 + M320榴彈器",  mods:{ atk:1 } },
    mg:      { label:"機槍兵",   weapon:"M240B 通用機槍",     mods:{} },
    mortar:  { label:"迫砲兵",   weapon:"M252 81mm迫擊砲",    mods:{} },
    sniper:  { label:"狙擊手",   weapon:"MK22 精準狙擊步槍", mods:{} },
    at:      { label:"反裝甲兵", weapon:"FGM-148 標槍飛彈",   mods:{ atk:20, cost:15 } },
    engineer:{ label:"戰鬥工兵", weapon:"M4 卡賓槍",          mods:{} },
    specops: { label:"三角洲部隊",weapon:"HK416",             mods:{ cost:10 } },
    tank:    { label:"裝甲兵",   weapon:"M1A2 SEPv3 艾布蘭",  mods:{ hp:40, ap:-14, cost:30 } }
  }
},

uk: {
  id:"uk", name:"英國", flagColors:["#012169","#C8102E","#FFFFFF"], uniformColor:"#4b543b",
  trait:{ id:"marksmanship", desc:"精準射術：全員基礎命中 +3%" },
  units:{
    rifleman:{ label:"步槍兵",   weapon:"L85A3 突擊步槍",   mods:{} },
    assault: { label:"突擊步兵", weapon:"L119A2 卡賓槍",    mods:{} },
    mg:      { label:"機槍兵",   weapon:"L7A2 通用機槍",    mods:{ range:10 } },
    mortar:  { label:"迫砲兵",   weapon:"L16 81mm迫擊砲",   mods:{} },
    sniper:  { label:"狙擊手",   weapon:"L115A3 狙擊步槍",  mods:{ range:20, cost:10 } },
    at:      { label:"反裝甲兵", weapon:"NLAW 反坦克飛彈",  mods:{ atk:10 } },
    engineer:{ label:"皇家工兵", weapon:"L22A2 卡賓槍",     mods:{} },
    specops: { label:"SAS 特勤團",weapon:"L119A2",          mods:{ ap:10, cost:10 } },
    tank:    { label:"裝甲兵",   weapon:"挑戰者2 主戰坦克", mods:{ hp:60, ap:-20, cost:20 } }
  }
},

korea: {
  id:"korea", name:"南韓", flagColors:["#003478","#C60C30","#FFFFFF"], uniformColor:"#57604a",
  trait:{ id:"conscript_drill", desc:"精實操演：全員滿 AP +5%" },
  units:{
    rifleman:{ label:"步槍兵",   weapon:"K2 突擊步槍",     mods:{} },
    assault: { label:"突擊步兵", weapon:"K1A 衝鋒卡賓槍",    mods:{ ap:8 } },
    mg:      { label:"機槍兵",   weapon:"K3 輕機槍",      mods:{} },
    mortar:  { label:"迫砲兵",   weapon:"KM187 81mm迫擊砲",  mods:{} },
    sniper:  { label:"狙擊手",   weapon:"K14 狙擊步槍",      mods:{} },
    at:      { label:"反裝甲兵", weapon:"鐵拳3 (Panzerfaust 3)",   mods:{ atk:8 } },
    engineer:{ label:"工兵",     weapon:"K2 摺疊托步槍",     mods:{} },
    specops: { label:"707特殊任務團",weapon:"HK416",         mods:{} },
    tank:    { label:"裝甲兵",   weapon:"K2 黑豹主戰坦克",   mods:{ ap:10, hp:-20 } }
  }
},

japan: {
  id:"japan", name:"日本", flagColors:["#FFFFFF","#BC002D","#9c9c9c"], uniformColor:"#4e5b45",
  trait:{ id:"island_defense", desc:"專守防衛：我方半場內全員防禦 +3" },
  units:{
    rifleman:{ label:"普通科隊員", weapon:"20式小銃",           mods:{ acc:0.03 } },
    assault: { label:"突擊隊員",   weapon:"89式小銃(摺托)",     mods:{} },
    mg:      { label:"機關銃手",   weapon:"62式 7.62mm機槍",    mods:{ ap:8 } },
    mortar:  { label:"迫擊砲手",   weapon:"L16 81mm迫擊砲",     mods:{} },
    sniper:  { label:"狙擊手",     weapon:"M24 狙擊步槍",       mods:{} },
    at:      { label:"對戰車兵",   weapon:"01式輕對戰車誘導彈", mods:{ acc:0.05 } },
    engineer:{ label:"施設科隊員", weapon:"89式小銃",           mods:{ ap:10 } },
    specops: { label:"特殊作戰群", weapon:"HK416",           mods:{} },
    tank:    { label:"機甲科",     weapon:"10式戰車",           mods:{ ap:16, hp:-40, cost:-10 } }
  }
},

taiwan: {
  id:"taiwan", name:"台灣", flagColors:["#000095","#FE0000","#FFFFFF"], uniformColor:"#3d4f3d",
  trait:{ id:"homeland_defense", desc:"衛土：防守方（地圖右側）時全員受傷 -10%" },
  units:{
    rifleman:{ label:"步兵",       weapon:"T91 戰鬥步槍",      mods:{} },
    assault: { label:"突擊步兵",   weapon:"XT112 突擊步槍",    mods:{ atk:1 } },
    mg:      { label:"機槍兵",     weapon:"T74 排用機槍",      mods:{} },
    mortar:  { label:"迫砲兵",     weapon:"T75 60mm迫擊砲",    mods:{ ap:10, atk:-4 } },
    sniper:  { label:"狙擊手",     weapon:"T93 狙擊步槍",      mods:{} },
    at:      { label:"火箭兵",     weapon:"紅隼反裝甲火箭",    mods:{ cost:-10 } },
    engineer:{ label:"工兵",       weapon:"T91 短管型",        mods:{} },
    specops: { label:"涼山特勤隊", weapon:"XT112",             mods:{} },
    tank:    { label:"裝甲兵",     weapon:"M1A2T 艾布蘭",      mods:{ hp:40, ap:-14, cost:20 } }
  }
},

china: {
  id:"china", name:"中國", flagColors:["#DE2910","#FFDE00","#8a1a0a"], uniformColor:"#66603f",
  trait:{ id:"mass_infantry", desc:"人海：步兵/突擊兵 cost -10%" },
  units:{
    rifleman:{ label:"步兵",       weapon:"QBZ-95-1 自動步槍",  mods:{ cost:-8 } },
    assault: { label:"突擊步兵",   weapon:"QBZ-95B 短步槍",    mods:{ cost:-11 } },
    mg:      { label:"機槍兵",     weapon:"QJB-95 班用機槍",  mods:{} },
    mortar:  { label:"迫砲兵",     weapon:"PP89 82mm迫擊砲",  mods:{} },
    sniper:  { label:"狙擊手",     weapon:"QBU-88 狙擊步槍",  mods:{ atk:-8, cost:-10 } },
    at:      { label:"火箭兵",     weapon:"PF-98 120mm火箭筒", mods:{ atk:8, acc:-0.05 } },
    engineer:{ label:"工兵",       weapon:"QBZ-95B",           mods:{} },
    specops: { label:"蛟龍突擊隊", weapon:"QBZ-95-1",           mods:{} },
    tank:    { label:"裝甲兵",     weapon:"99A式 主戰坦克",    mods:{ atk:10, hp:-30 } }
  }
},

thailand: {
  id:"thailand", name:"泰國", flagColors:["#A51931","#2D2A4A","#F4F5F8"], uniformColor:"#5d5a41",
  trait:{ id:"jungle_craft", desc:"叢林戰：草叢內單位被發現距離減半" },
  units:{
    rifleman:{ label:"步兵",         weapon:"TAR-21 突擊步槍",  mods:{} },
    assault: { label:"突擊步兵",     weapon:"M4A1 卡賓槍",       mods:{} },
    mg:      { label:"機槍兵",       weapon:"FN MAG 通用機槍",   mods:{} },
    mortar:  { label:"迫砲兵",       weapon:"M29 81mm迫擊砲",    mods:{} },
    sniper:  { label:"狙擊手",       weapon:"巴雷特 M82",          mods:{} },
    at:      { label:"火箭兵",       weapon:"拖式飛彈 (BGM-71 TOW)",   mods:{ shots:0, cost:-8 } },
    engineer:{ label:"工兵",         weapon:"M4 卡賓槍",         mods:{ cost:-5 } },
    specops: { label:"海軍海豹部隊", weapon:"M4A1",              mods:{ cost:-10 } },
    tank:    { label:"裝甲兵",       weapon:"VT-4 主戰坦克",     mods:{ cost:-25, hp:-40 } }
  }
},

vietnam: {
  id:"vietnam", name:"越南", flagColors:["#DA251D","#FFFF00","#8a1510"], uniformColor:"#5e6b3c",
  trait:{ id:"tunnel_war", desc:"地道戰：全員在草叢中移動 AP 消耗減免 50%" },
  units:{
    rifleman:{ label:"步兵",     weapon:"STV-380 步槍",      mods:{ cost:-6 } },
    assault: { label:"突擊步兵", weapon:"Galil ACE 31",      mods:{} },
    mg:      { label:"機槍兵",   weapon:"PKM 通用機槍",      mods:{ atk:1 } },
    mortar:  { label:"迫砲兵",   weapon:"82mm 迫擊砲",       mods:{ atk:3, acc:-0.04 } },
    sniper:  { label:"狙擊手",   weapon:"SVD 德拉古諾夫",    mods:{ atk:-6, cost:-12 } },
    at:      { label:"火箭兵",   weapon:"9M113 反坦克飛彈",   mods:{ cost:-12, acc:-0.05 } },
    engineer:{ label:"工兵",     weapon:"AKM 突擊步槍",      mods:{} },
    specops: { label:"特工部隊", weapon:"Galil ACE",         mods:{ cost:-15 } },
    tank:    { label:"裝甲兵",   weapon:"T-90S 主戰坦克",    mods:{ cost:-20, hp:-50 } }
  }
},

ukraine: {
  id:"ukraine", name:"烏克蘭", flagColors:["#0057B7","#FFD700","#003a7a"], uniformColor:"#54573e",
  trait:{ id:"drone_recon", desc:"無人機偵蒐：敵草叢隱蔽對我無效（開戰前3回合）" },
  units:{
    rifleman:{ label:"步兵",       weapon:"AK-74 突擊步槍",   mods:{ cost:-5 } },
    assault: { label:"突擊步兵",   weapon:"Malyuk 犢牛式",    mods:{} },
    mg:      { label:"機槍兵",     weapon:"PKM 通用機槍",     mods:{} },
    mortar:  { label:"迫砲兵",     weapon:"82mm 迫擊砲",      mods:{} },
    sniper:  { label:"狙擊手",     weapon:"UAR-10 狙擊步槍",  mods:{} },
    at:      { label:"火箭兵",     weapon:"NLAW / 標槍",      mods:{ atk:12, cost:8 } },
    engineer:{ label:"戰鬥工兵",   weapon:"AKS-74U",          mods:{ ap:8 } },
    specops: { label:"特種作戰軍", weapon:"M4A1",             mods:{} },
    tank:    { label:"裝甲兵",     weapon:"T-64BV 主戰坦克",  mods:{ cost:-25, hp:-60, atk:-10 } }
  }
},

russia: {
  id:"russia", name:"俄羅斯", flagColors:["#0039A6","#D52B1E","#FFFFFF"], uniformColor:"#4f5747",
  trait:{ id:"artillery_doctrine", desc:"砲兵教條：迫砲兵攻擊 +12%" },
  units:{
    rifleman:{ label:"摩托化步兵", weapon:"AK-12 突擊步槍",    mods:{ cost:-5 } },
    assault: { label:"突擊步兵",   weapon:"AK-12K 短管型",     mods:{} },
    mg:      { label:"機槍兵",     weapon:"PKP 佩切涅格",      mods:{ atk:1 } },
    mortar:  { label:"迫砲兵",     weapon:"2B14 82mm迫擊砲",   mods:{ atk:6 } },
    sniper:  { label:"狙擊手",     weapon:"SVD 德拉古諾夫",    mods:{ atk:-6, cost:-10 } },
    at:      { label:"火箭兵",     weapon:"RPG-7V2",           mods:{ cost:-15, acc:-0.06 } },
    engineer:{ label:"工兵",       weapon:"AKS-74U",           mods:{} },
    specops: { label:"阿爾法小組", weapon:"AK-105",            mods:{} },
    tank:    { label:"裝甲兵",     weapon:"T-90M 主戰坦克",    mods:{ atk:8, ap:-10 } }
  }
},

iran: {
  id:"iran", name:"伊朗", flagColors:["#239F40","#DA0000","#FFFFFF"], uniformColor:"#5c5c44",
  trait:{ id:"asymmetric", desc:"不對稱作戰：火箭兵警戒不觸發敵反擊（首次開火不暴露）" },
  units:{
    rifleman:{ label:"步兵",     weapon:"G3A6 戰鬥步槍",   mods:{ cost:-8, acc:-0.04 } },
    assault: { label:"突擊步兵", weapon:"KH-2002 海白爾",        mods:{ cost:-8 } },
    mg:      { label:"機槍兵",   weapon:"PKM 仿製型",        mods:{ cost:-6 } },
    mortar:  { label:"迫砲兵",   weapon:"HM-16 81mm迫擊砲",   mods:{} },
    sniper:  { label:"狙擊手",   weapon:"Nakhjir 狙擊步槍",  mods:{ cost:-8 } },
    at:      { label:"火箭兵",   weapon:"Ghadir 火箭筒 (RPG-29仿)",mods:{ atk:6 } },
    engineer:{ label:"工兵",     weapon:"AKM",               mods:{} },
    specops: { label:"聖城軍",   weapon:"AK-103",            mods:{ cost:-12 } },
    tank:    { label:"裝甲兵",   weapon:"Karrar 主戰坦克",   mods:{ cost:-30, hp:-40, atk:-8 } }
  }
},

israel: {
  id:"israel", name:"以色列", flagColors:["#0038B8","#FFFFFF","#002a8a"], uniformColor:"#6b6a4f",
  trait:{ id:"intel_superiority", desc:"情報優勢：特種兵 cost -15%、視野 +20%" },
  units:{
    rifleman:{ label:"步兵",           weapon:"Tavor X95",        mods:{ acc:0.03 } },
    assault: { label:"突擊步兵",       weapon:"X95 短管型",       mods:{} },
    mg:      { label:"機槍兵",         weapon:"Negev NG7",        mods:{ ap:8 } },
    mortar:  { label:"迫砲兵",         weapon:"81mm 迫擊砲",     mods:{} },
    sniper:  { label:"狙擊手",         weapon:"M24 狙擊步槍",      mods:{} },
    at:      { label:"火箭兵",         weapon:"長釘飛彈 (Spike-MR)",   mods:{ acc:0.05, cost:8 } },
    engineer:{ label:"戰鬥工兵",       weapon:"X95",              mods:{ ap:8 } },
    specops: { label:"總參偵察部隊",   weapon:"X95 消音型",       mods:{ cost:-24 } },
    tank:    { label:"裝甲兵",         weapon:"梅卡瓦 Mk4",       mods:{ hp:70, ap:-20, cost:25 } }
  }
},

germany: {
  id:"germany", name:"德國", flagColors:["#000000","#DD0000","#FFCE00"], uniformColor:"#4a4f42",
  trait:{ id:"panzer_doctrine", desc:"裝甲教條：坦克 CP 消耗 2→1（每回合首次）" },
  units:{
    rifleman:{ label:"擲彈兵",     weapon:"G95A1 突擊步槍",     mods:{ acc:0.03 } },
    assault: { label:"突擊步兵",   weapon:"G95K 短管型",       mods:{} },
    mg:      { label:"機槍兵",     weapon:"MG5 通用機槍",      mods:{ atk:1 } },
    mortar:  { label:"迫砲兵",     weapon:"Tampella 120mm迫擊砲", mods:{ atk:5, ap:-10 } },
    sniper:  { label:"狙擊手",     weapon:"G28 狙擊步槍",    mods:{} },
    at:      { label:"火箭兵",     weapon:"鐵拳3 (Pzf 3)",     mods:{} },
    engineer:{ label:"裝甲工兵",   weapon:"G95K",              mods:{} },
    specops: { label:"KSK 特種部隊",weapon:"G95K",             mods:{} },
    tank:    { label:"裝甲兵",     weapon:"豹2A8",            mods:{ hp:30, atk:6, cost:35 } }
  }
},

france: {
  id:"france", name:"法國", flagColors:["#002395","#ED2939","#FFFFFF"], uniformColor:"#4d5646",
  trait:{ id:"rapid_reaction", desc:"快速反應：第 1 回合全員 AP +20%" },
  units:{
    rifleman:{ label:"步兵",           weapon:"HK416F",            mods:{} },
    assault: { label:"突擊步兵",       weapon:"HK416F 短管型",     mods:{ ap:8 } },
    mg:      { label:"機槍兵",         weapon:"FN Minimi 輕機槍",         mods:{} },
    mortar:  { label:"迫砲兵",         weapon:"MEPAC 120mm迫砲",    mods:{} },
    sniper:  { label:"狙擊手",         weapon:"FR-F2 狙擊步槍",    mods:{} },
    at:      { label:"火箭兵",         weapon:"Akeron MP (MMP) 飛彈",    mods:{ acc:0.04, cost:6 } },
    engineer:{ label:"工兵",           weapon:"HK416F 短管型",     mods:{} },
    specops: { label:"第1海陸傘兵團",  weapon:"HK416F",            mods:{ ap:10 } },
    tank:    { label:"裝甲兵",         weapon:"勒克萊爾 XLR", mods:{ ap:14, hp:-30 } }
  }
}
};

/* 兵種與武器「基準表」— 唯一權威在 GDD/02，此處為引擎用鏡像 */
const CLASS_BASE = {
  rifleman:{ zh:"步兵",   hp:100, ap:240, def:5,  cost:80,  wtype:"rifle",   alert:true,  canCap:true  },
  assault: { zh:"突擊兵", hp:130, ap:160, def:10, cost:110, wtype:"carbine", alert:true,  canCap:true  },
  mg:      { zh:"機槍兵", hp:120, ap:120, def:10, cost:120, wtype:"lmg",     alert:true,  canCap:false },
  mortar:  { zh:"迫砲兵", hp:90,  ap:100, def:5,  cost:130, wtype:"mortar",  alert:false, canCap:false },
  sniper:  { zh:"狙擊兵", hp:80,  ap:100, def:0,  cost:140, wtype:"sniper",  alert:false, canCap:false },
  at:      { zh:"火箭兵", hp:110, ap:120, def:15, cost:140, wtype:"rocket",  alert:false, canCap:false },
  engineer:{ zh:"工兵",   hp:90,  ap:200, def:5,  cost:90,  wtype:"carbine", alert:false, canCap:true  },
  specops: { zh:"特種兵", hp:110, ap:220, def:8,  cost:160, wtype:"carbine", alert:true,  canCap:true  },
  tank:    { zh:"裝甲兵", hp:600, ap:140, def:60, cost:400, wtype:"cannon",  alert:true,  canCap:false }
};

const WEAPON_BASE = {
  rifle:  { atk:22,  shots:3, range:210, acc:0.80, splash:0  },
  carbine:{ atk:16,  shots:5, range:160, acc:0.75, splash:0  },
  lmg:    { atk:14,  shots:8, range:190, acc:0.70, splash:0  },
  mortar: { atk:55,  shots:1, range:300, acc:0.70, splash:36, arc:true },
  sniper: { atk:85,  shots:1, range:380, acc:0.95, splash:0  },
  rocket: { atk:180, shots:1, range:200, acc:0.75, splash:24, antiTank:true },
  cannon: { atk:220, shots:1, range:260, acc:0.85, splash:30, antiTank:true }
};

const MOD_KEYS = ["atk","shots","range","acc","hp","ap","def","cost"];
