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
    tank:    { label:"裝甲兵",   weapon:"M1A2 SEPv3 艾布蘭",  mods:{ hp:40, ap:-14, cost:30 } },
    sam: { label:"防空兵", weapon:"愛國者 PAC-3", mods:{} },
    destroyer: { label:"驅逐艦", weapon:"阿利·柏克級 神盾艦", mods:{} },
    missileboat: { label:"濱海戰鬥艦", weapon:"LCS 瀕海戰鬥艦", mods:{} },
    lst: { label:"登陸艦", weapon:"聖安東尼奧級 LPD", mods:{} },
    submarine: { label:"潛艦", weapon:"維吉尼亞級", mods:{} },
    fighter: { label:"戰鬥機", weapon:"F-22 猛禽", mods:{atk:8} },
    attacker: { label:"攻擊機", weapon:"F-15E 打擊鷹", mods:{} },
    gunship: { label:"武裝直升機", weapon:"AH-64E 阿帕契", mods:{} }
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
    tank:    { label:"裝甲兵",   weapon:"挑戰者2 主戰坦克", mods:{ hp:60, ap:-20, cost:20 } },
    sam: { label:"防空兵", weapon:"天空軍刀 Sky Sabre", mods:{} },
    destroyer: { label:"驅逐艦", weapon:"45型驅逐艦", mods:{} },
    missileboat: { label:"巡邏艦", weapon:"河號級 OPV", mods:{} },
    lst: { label:"登陸艦", weapon:"海灣級 LSD", mods:{} },
    submarine: { label:"潛艦", weapon:"機敏級", mods:{} },
    fighter: { label:"戰鬥機", weapon:"颱風戰鬥機", mods:{} },
    attacker: { label:"攻擊機", weapon:"F-35B 閃電II", mods:{} },
    gunship: { label:"武裝直升機", weapon:"AH-64E 阿帕契", mods:{} }
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
    tank:    { label:"裝甲兵",   weapon:"K2 黑豹主戰坦克",   mods:{ ap:10, hp:-20 } },
    sam: { label:"防空兵", weapon:"天弓 M-SAM", mods:{} },
    destroyer: { label:"驅逐艦", weapon:"世宗大王級", mods:{} },
    missileboat: { label:"飛彈快艇", weapon:"尹永夏級", mods:{} },
    lst: { label:"登陸艦", weapon:"獨島級 LPH", mods:{} },
    submarine: { label:"潛艦", weapon:"島山安昌浩級", mods:{} },
    fighter: { label:"戰鬥機", weapon:"F-15K 勇士鷹", mods:{} },
    attacker: { label:"攻擊機", weapon:"KF-21 梟龍", mods:{} },
    gunship: { label:"武裝直升機", weapon:"AH-64E 阿帕契", mods:{} }
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
    tank:    { label:"機甲科",     weapon:"10式戰車",           mods:{ ap:16, hp:-40, cost:-10 } },
    sam: { label:"防空兵", weapon:"03式中SAM改", mods:{} },
    destroyer: { label:"護衛艦", weapon:"摩耶級 神盾艦", mods:{} },
    missileboat: { label:"飛彈艇", weapon:"隼級", mods:{} },
    lst: { label:"輸送艦", weapon:"大隅級", mods:{} },
    submarine: { label:"潛艦", weapon:"蒼龍級", mods:{} },
    fighter: { label:"戰鬥機", weapon:"F-35A 閃電II", mods:{} },
    attacker: { label:"支援戰鬥機", weapon:"F-2", mods:{} },
    gunship: { label:"武裝直升機", weapon:"AH-64DJP 阿帕契", mods:{} }
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
    tank:    { label:"裝甲兵",     weapon:"M1A2T 艾布蘭",      mods:{ hp:40, ap:-14, cost:20 } },
    sam: { label:"防空兵", weapon:"天弓三型", mods:{} },
    destroyer: { label:"驅逐艦", weapon:"基隆級", mods:{} },
    missileboat: { label:"巡邏艦", weapon:"沱江級", mods:{} },
    lst: { label:"登陸艦", weapon:"玉山級 LPD", mods:{} },
    submarine: { label:"潛艦", weapon:"海鯤級", mods:{} },
    fighter: { label:"戰鬥機", weapon:"F-16V Block 70", mods:{} },
    attacker: { label:"攻擊機", weapon:"經國號 IDF", mods:{} },
    gunship: { label:"武裝直升機", weapon:"AH-64E 阿帕契", mods:{} }
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
    tank:    { label:"裝甲兵",     weapon:"99A式 主戰坦克",    mods:{ atk:10, hp:-30 } },
    sam: { label:"防空兵", weapon:"紅旗-9B", mods:{} },
    destroyer: { label:"驅逐艦", weapon:"055型", mods:{} },
    missileboat: { label:"飛彈快艇", weapon:"022型", mods:{cost:-20} },
    lst: { label:"船塢登陸艦", weapon:"071型", mods:{} },
    submarine: { label:"核潛艦", weapon:"093型", mods:{} },
    fighter: { label:"戰鬥機", weapon:"殲-20 威龍", mods:{} },
    attacker: { label:"攻擊機", weapon:"殲轟-7A 飛豹", mods:{} },
    gunship: { label:"武裝直升機", weapon:"武直-10", mods:{} }
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
    tank:    { label:"裝甲兵",       weapon:"VT-4 主戰坦克",     mods:{ cost:-25, hp:-40 } },
    sam: { label:"防空兵", weapon:"斯帕達2000", mods:{} },
    destroyer: { label:"巡防艦", weapon:"布米蓬·阿杜德級", mods:{} },
    missileboat: { label:"巡邏艦", weapon:"拉達那哥欣級", mods:{} },
    lst: { label:"登陸艦", weapon:"安通級 LPD", mods:{} },
    submarine: { label:"潛艦", weapon:"S26T 元級(建造中)", mods:{cost:-40} },
    fighter: { label:"戰鬥機", weapon:"JAS-39 獅鷲", mods:{} },
    attacker: { label:"攻擊機", weapon:"F-5TH 超級虎", mods:{} },
    gunship: { label:"武裝直升機", weapon:"AH-1F 眼鏡蛇", mods:{} }
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
    tank:    { label:"裝甲兵",   weapon:"T-90S 主戰坦克",    mods:{ cost:-20, hp:-50 } },
    sam: { label:"防空兵", weapon:"S-300PMU1", mods:{} },
    destroyer: { label:"巡防艦", weapon:"獵豹3.9級", mods:{} },
    missileboat: { label:"飛彈艇", weapon:"閃電級", mods:{} },
    lst: { label:"登陸艦", weapon:"波爾諾契級", mods:{} },
    submarine: { label:"潛艦", weapon:"基洛級 636", mods:{} },
    fighter: { label:"戰鬥機", weapon:"Su-30MK2", mods:{} },
    attacker: { label:"攻擊機", weapon:"Su-22", mods:{} },
    gunship: { label:"武裝直升機", weapon:"Mi-24 雌鹿", mods:{} }
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
    tank:    { label:"裝甲兵",     weapon:"T-64BV 主戰坦克",  mods:{ cost:-25, hp:-60, atk:-10 } },
    sam: { label:"防空兵", weapon:"NASAMS", mods:{} },
    destroyer: { label:"巡防艦", weapon:"Ada級 馬澤帕號", mods:{} },
    missileboat: { label:"突擊艇", weapon:"半人馬座級", mods:{cost:-40} },
    lst: { label:"登陸艦", weapon:"奧列菲連科號", mods:{} },
    submarine: { label:"攻擊無人艇", weapon:"Magura V5", mods:{cost:-120, hp:-200} },
    fighter: { label:"戰鬥機", weapon:"F-16 戰隼", mods:{} },
    attacker: { label:"攻擊機", weapon:"Su-25 蛙足", mods:{} },
    gunship: { label:"武裝直升機", weapon:"Mi-24V 雌鹿", mods:{} }
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
    tank:    { label:"裝甲兵",     weapon:"T-90M 主戰坦克",    mods:{ atk:8, ap:-10 } },
    sam: { label:"防空兵", weapon:"鎧甲-S1", mods:{} },
    destroyer: { label:"護衛艦", weapon:"戈爾什科夫級", mods:{} },
    missileboat: { label:"飛彈艦", weapon:"毒蜘蛛級", mods:{} },
    lst: { label:"登陸艦", weapon:"羅普查級", mods:{} },
    submarine: { label:"核潛艦", weapon:"亞森級", mods:{} },
    fighter: { label:"戰鬥機", weapon:"蘇-35S", mods:{} },
    attacker: { label:"戰鬥轟炸機", weapon:"蘇-34", mods:{} },
    gunship: { label:"武裝直升機", weapon:"卡-52 短吻鱷", mods:{} }
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
    tank:    { label:"裝甲兵",   weapon:"Karrar 主戰坦克",   mods:{ cost:-30, hp:-40, atk:-8 } },
    sam: { label:"防空兵", weapon:"巴瓦爾-373", mods:{} },
    destroyer: { label:"巡防艦", weapon:"莫杰級 賈馬蘭號", mods:{cost:-40} },
    missileboat: { label:"飛彈快艇", weapon:"佩坎級三型", mods:{cost:-30} },
    lst: { label:"戰車登陸艦", weapon:"亨甘級", mods:{} },
    submarine: { label:"潛艦", weapon:"基洛級/加迪爾級", mods:{cost:-40} },
    fighter: { label:"戰鬥機", weapon:"F-14A 雄貓", mods:{hp:-30, cost:-40} },
    attacker: { label:"攻擊機", weapon:"蘇-24", mods:{} },
    gunship: { label:"武裝直升機", weapon:"AH-1J 颶風", mods:{} }
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
    tank:    { label:"裝甲兵",         weapon:"梅卡瓦 Mk4",       mods:{ hp:70, ap:-20, cost:25 } },
    sam: { label:"防空兵", weapon:"鐵穹 Iron Dome", mods:{} },
    destroyer: { label:"護衛艦", weapon:"薩爾6型", mods:{} },
    missileboat: { label:"飛彈快艇", weapon:"薩爾4.5型", mods:{} },
    lst: { label:"登陸艇", weapon:"機械化登陸艇 LCM", mods:{} },
    submarine: { label:"潛艦", weapon:"海豚級", mods:{} },
    fighter: { label:"戰鬥機", weapon:"F-35I 阿迪爾", mods:{acc:0.05} },
    attacker: { label:"攻擊機", weapon:"F-16I 暴風", mods:{} },
    gunship: { label:"武裝直升機", weapon:"AH-64D 薩拉夫", mods:{} }
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
    tank:    { label:"裝甲兵",     weapon:"豹2A8",            mods:{ hp:30, atk:6, cost:35 } },
    sam: { label:"防空兵", weapon:"IRIS-T SLM", mods:{} },
    destroyer: { label:"巡防艦", weapon:"F125 巴登-符騰堡級", mods:{} },
    missileboat: { label:"巡邏艦", weapon:"K130 布藍茲維克級", mods:{} },
    lst: { label:"登陸艇", weapon:"多用途登陸艇", mods:{} },
    submarine: { label:"潛艦", weapon:"212A型", mods:{} },
    fighter: { label:"戰鬥機", weapon:"颱風 Tranche 4", mods:{} },
    attacker: { label:"攻擊機", weapon:"F-35A 閃電II", mods:{} },
    gunship: { label:"武裝直升機", weapon:"虎式 UHT", mods:{} }
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
    tank:    { label:"裝甲兵",         weapon:"勒克萊爾 XLR", mods:{ ap:14, hp:-30 } },
    sam: { label:"防空兵", weapon:"SAMP/T 曼巴", mods:{} },
    destroyer: { label:"巡防艦", weapon:"FREMM 阿基坦級", mods:{} },
    missileboat: { label:"巡邏艦", weapon:"POM 遠洋巡邏艦", mods:{} },
    lst: { label:"突擊艦", weapon:"西北風級 LHD", mods:{} },
    submarine: { label:"核潛艦", weapon:"梭魚級", mods:{} },
    fighter: { label:"戰鬥機", weapon:"飆風 Rafale", mods:{} },
    attacker: { label:"攻擊機", weapon:"幻象2000D", mods:{} },
    gunship: { label:"武裝直升機", weapon:"虎式 HAD-F", mods:{} }
  }
}
};

/* 兵種與武器「基準表」— 陸軍權威 GDD/02、海空權威 GDD/04，此處為引擎鏡像。
 * domain: land/sea/air（GDD/04 §1）；sight: 視野半徑 px（GDD/05 §2） */
const CLASS_BASE = {
  rifleman:{ zh:"步兵",   hp:100, ap:240, def:5,  cost:80,  wtype:"rifle",   alert:true,  canCap:true,  domain:"land", mobility:"scout",    sight:170 },
  assault: { zh:"突擊兵", hp:130, ap:160, def:10, cost:110, wtype:"carbine", alert:true,  canCap:true,  domain:"land", mobility:"foot",     sight:120 },
  mg:      { zh:"機槍兵", hp:120, ap:120, def:10, cost:120, wtype:"lmg",     alert:true,  canCap:false, domain:"land", mobility:"heavy",    sight:120 },
  mortar:  { zh:"迫砲兵", hp:90,  ap:100, def:5,  cost:130, wtype:"mortar",  alert:false, canCap:false, domain:"land", mobility:"heavy",    sight:120 },
  sniper:  { zh:"狙擊兵", hp:80,  ap:100, def:0,  cost:140, wtype:"sniper",  alert:false, canCap:false, domain:"land", mobility:"foot",     sight:150 },
  at:      { zh:"火箭兵", hp:110, ap:120, def:15, cost:140, wtype:"rocket",  alert:false, canCap:false, domain:"land", mobility:"heavy",    sight:120 },
  engineer:{ zh:"工兵",   hp:90,  ap:200, def:5,  cost:90,  wtype:"carbine", alert:false, canCap:true,  domain:"land", mobility:"engineer", sight:120 },
  specops: { zh:"特種兵", hp:110, ap:220, def:8,  cost:160, wtype:"carbine", alert:true,  canCap:true,  domain:"land", mobility:"special",  sight:150 },
  tank:    { zh:"裝甲兵", hp:600, ap:140, def:60, cost:400, wtype:"cannon",  alert:true,  canCap:false, domain:"land", mobility:"tracked",  sight:130 },
  // ── 防空兵（land 域，只打空軍）
  sam:     { zh:"防空兵", hp:120, ap:110, def:5,  cost:150, wtype:"sam_missile", alert:true, canCap:false, domain:"land", mobility:"heavy", sight:110, airSight:300 },
  // ── 海軍（sea 域，只在水域移動）
  destroyer:  { zh:"驅逐艦",   hp:900, ap:140, def:50, cost:520, wtype:"naval_gun",        alert:true,  canCap:false, domain:"sea", mobility:"naval", sight:200, big:true },
  missileboat:{ zh:"飛彈快艇", hp:260, ap:220, def:15, cost:220, wtype:"antiship_missile", alert:false, canCap:false, domain:"sea", mobility:"naval", sight:150 },
  lst:        { zh:"登陸艦",   hp:700, ap:120, def:30, cost:300, wtype:"naval_mg",         alert:true,  canCap:false, domain:"sea", mobility:"naval", sight:150, big:true },
  submarine:  { zh:"潛艦",     hp:400, ap:160, def:20, cost:360, wtype:"torpedo",          alert:false, canCap:false, domain:"sea", mobility:"naval", sight:150, stealth:true },
  // ── 空軍（air 域，飛行、無視地形阻擋）
  fighter: { zh:"戰鬥機",     hp:220, ap:320, def:10, cost:340, wtype:"aam",        alert:true,  canCap:false, domain:"air", mobility:"air", sight:240 },
  attacker:{ zh:"攻擊機",     hp:260, ap:300, def:10, cost:320, wtype:"agm",        alert:false, canCap:false, domain:"air", mobility:"air", sight:240 },
  gunship: { zh:"武裝直升機", hp:300, ap:240, def:15, cost:300, wtype:"rocket_pod", alert:true,  canCap:false, domain:"air", mobility:"air", sight:240 }
};

/* 地形移動倍率：null=不可進入；數值=每像素 AP 倍率（GDD/04 §2c）。 */
const TERRAIN_MOBILITY = {
  scout:    { ground:1, shallow:1.35, water:null, deepwater:null, hill:1.10, trench:1.15, crater:1.10, wire:1.8,  bush:0.85 },
  foot:     { ground:1, shallow:1.55, water:null, deepwater:null, hill:1.15, trench:1.25, crater:1.15, wire:2.0,  bush:0.90 },
  heavy:    { ground:1, shallow:1.80, water:null, deepwater:null, hill:1.25, trench:1.40, crater:1.25, wire:2.4,  bush:1.00 },
  engineer: { ground:1, shallow:1.20, water:2.40, deepwater:null, hill:1.10, trench:1.10, crater:1.00, wire:1.1,  bush:0.90 },
  special:  { ground:1, shallow:1.20, water:1.80, deepwater:null, hill:1.00, trench:1.00, crater:1.00, wire:1.35, bush:0.65 },
  tracked:  { ground:1, shallow:1.50, water:null, deepwater:null, hill:1.35, trench:null, crater:1.35, wire:1.1,  bush:1.25 },
  naval:    { ground:null, shallow:1.35, water:1.00, deepwater:1.00, hill:null, trench:null, crater:null, wire:null, bush:null },
  air:      { ground:1, shallow:1.00, water:1.00, deepwater:1.00, hill:1.00, trench:1.00, crater:1.00, wire:1.00, bush:1.00 }
};

const WEAPON_BASE = {
  rifle:  { atk:22,  shots:3, range:210, acc:0.80, splash:0  },
  carbine:{ atk:16,  shots:5, range:160, acc:0.75, splash:0  },
  lmg:    { atk:14,  shots:8, range:190, acc:0.70, splash:0  },
  mortar: { atk:55,  shots:1, range:300, acc:0.70, splash:36, arc:true },
  sniper: { atk:85,  shots:1, range:380, acc:0.95, splash:0  },
  rocket: { atk:180, shots:1, range:200, acc:0.75, splash:24, antiTank:true },
  cannon: { atk:220, shots:1, range:260, acc:0.85, splash:30, antiTank:true },
  // ── 海空武器（GDD/04 §5）。flag：antiAir(對空傷害倍率,0=不可對空)、
  //    seaOnly(僅對海)、antiAirOnly(僅對空)、antiShip/antiGround(對該域加成)
  naval_gun:       { atk:90,  shots:1, range:340, acc:0.80, splash:40, antiAir:0.5 },
  antiship_missile:{ atk:260, shots:1, range:300, acc:0.80, splash:0,  antiAir:0,   antiShip:1.5 },
  naval_mg:        { atk:16,  shots:6, range:180, acc:0.72, splash:0,  antiAir:0.5 },
  torpedo:         { atk:320, shots:1, range:220, acc:0.85, splash:0,  antiAir:0,   seaOnly:true },
  aam:             { atk:120, shots:2, range:300, acc:0.85, splash:0,  antiAir:1.0, airToGround:0.2 },
  agm:             { atk:150, shots:1, range:240, acc:0.80, splash:28, antiAir:0,   antiGround:1.3 },
  rocket_pod:      { atk:70,  shots:3, range:200, acc:0.72, splash:24, antiAir:0.5, antiGround:1.1 },
  sam_missile:     { atk:200, shots:1, range:420, acc:0.85, splash:0,  antiAirOnly:true }
};

const MOD_KEYS = ["atk","shots","range","acc","hp","ap","def","cost"];
