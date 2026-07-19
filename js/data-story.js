/* ============================================================
 * data-story.js — 劇情模式章節資料（規格：GDD/09）
 * 原創架空劇本：反派=虛構傭兵集團「灰幕兵團」（enemy 欄=其擄獲裝備所屬國兵種表）。
 * side：玩家操作方（0=進攻 1=防守）。★=暫用地圖，待新圖後替換。
 * ============================================================ */
"use strict";

const STORY = [
  { n:1,  title:"灰色黎明",   map:"tutorial", player:"taiwan",  enemy:"china",   side:1,
    brief:"2034 年 3 月，灰幕兵團發動「灰色黎明」行動，同步襲擊十四國軍火庫。你值勤的濱海基地是其中之一。帶著倉促集結的守備隊撐住第一夜——活下來，就是勝利。",
    debrief:"守住了。清點戰場時你在敵屍上找不到任何國籍identification——只有灰色臂章。上級來電：聯合特遣隊「曙光」正在組建，指名要你。" },
  { n:2,  title:"平原上的旗", map:"plain",    player:"usa",     enemy:"russia",  side:0,
    brief:"曙光特遣隊成軍第一戰：奪回被灰幕佔據的邊境哨站。他們用的是擄獲的俄式裝備——別因為裝備熟悉就手軟。攻下敵方主堡，把旗升回去。",
    debrief:"旗升回去了。狙擊手韓沐霜上尉在你身後說：「每一發子彈都要有名字。今天的都有了。」" },
  { n:3,  title:"絞肉機重演", map:"verdun",   player:"uk",      enemy:"germany", side:0,
    brief:"灰幕在舊戰場挖出了新塹壕：兩道鐵絲網、機槍堡、無人地帶。一百年前的絞肉機重新開張。用工兵、迫砲和耐心，一段一段咬穿它。",
    debrief:"突破了。機槍手雷諾盯著壕溝裡的灰色臂章很久。「我認得這個編制，」他說，「因為我待過。」你決定先不上報。" },
  { n:4,  title:"無聲的村莊", map:"town",     player:"france",  enemy:"germany", side:0,
    brief:"灰幕把整座村莊扣為人質，藏兵於民宅之間。重砲全部留在後方——這一仗只能用步槍與雙腳，一棟一棟敲門。",
    debrief:"村長握著你的手不放。雷諾把口糧全分給了孩子。你開始相信：他不是內鬼。" },
  { n:5,  title:"沙暴走廊",   map:"desert",   player:"usa",     enemy:"iran",    side:0,
    brief:"灰幕裝甲縱隊正穿越沙漠走廊撤往港口。第一次，你手上有制空權——但他們的防空飛彈也在等你的飛機。追上去，別讓一輛坦克跑掉。",
    debrief:"沙暴散去，走廊上是燃燒的鋼鐵。但審訊俘虜得到的情報令人不安：這批裝備的流向清單上，有曙光內部的簽名。" },
  { n:6,  title:"林海伏擊",   map:"forest",   player:"vietnam", enemy:"thailand",side:1,
    brief:"車隊在林海被包了餃子——這是圈套，有人洩露了行軍路線。利用樹障與高草，把伏擊者變成獵物。",
    debrief:"突圍了，但代價寫在陣亡名單上。雷諾主動交出通訊紀錄自證清白。內鬼另有其人，而且軍階不低。" },
  { n:7,  title:"斷橋之城",   map:"urban",    player:"germany", enemy:"france",  side:0,
    brief:"州府巷戰。灰幕指揮官在廣播裡直呼雷諾的名字，稱他「逃兵」。雷諾被暫時解除武裝——這一仗，你沒有機槍手。逐街收復，證明不靠任何人也打得下來。",
    debrief:"城收復了。雷諾隔著鐵絲網對你說出全部：他曾是灰幕創始隊員，因拒絕對平民開火而逃走。你把他的槍還給了他。" },
  { n:8,  title:"紅色灘頭",   map:"beach",    player:"japan",   enemy:"china",   side:0,
    brief:"反攻從海上開始。LST 登陸艦將把部隊送上灰幕控制的海岸——灘頭有碉堡，淺灘有鐵絲網。艦砲開路，兩波搶灘，天黑前建立灘頭堡。",
    debrief:"灘頭插上了曙光的旗。工兵顧問白老師在碉堡殘骸裡找到成箱的仿製零件——灰幕不只擄裝備，他們在量產。" },
  { n:9,  title:"海峽封鎖線", map:"strait",   player:"korea",   enemy:"japan",   side:0,
    brief:"三艘補給船必須通過海峽，而灰幕的潛艦與飛彈艇在水下與霧中等待。驅逐艦反潛開路、戰機撐傘——一艘都不能沉。",
    debrief:"船團靠港。聲納兵摘下耳機時手還在抖。韓沐霜在甲板上說：「海上的仗沒有掩體，只有先看見。」" },
  { n:10, title:"霧港疑雲",   map:"harbor",   player:"uk",      enemy:"russia",  side:0,
    brief:"夜霧籠罩軍港。這是一場不能開大燈的仗：前段靜默滲透，查獲走私貨櫃、揪出把行軍路線賣給灰幕的內鬼；後段強攻奪港。",
    debrief:"貨櫃裡的文件指向聯絡官布蘭特——六章林海的血債有主了。他被押走時對你笑：「灰王說，你會是最後一個懂他的人。」" },
  { n:11, title:"群山之肩",   map:"verdun",   player:"taiwan",  enemy:"korea",   side:0,
    brief:"（★暫用地形）隘口在上，灰幕在棱線後架好了砲。高地給他們視野，工事給他們掩體——你有迫砲的拋物線，和不肯繞路的決心。",
    debrief:"峰頂觀察哨換了主人。從這裡能看見灰幕腹地：燈火通明的離島兵工廠，晝夜不停。" },
  { n:12, title:"鋼鐵洪流",   map:"plain",    player:"ukraine", enemy:"russia",  side:1,
    brief:"灰幕傾巢反撲：裝甲集群將在三十回合內三波衝擊你的防線。鐵絲網、反戰車壕、警戒射擊網——把平原變成他們的墓園。撐過去。",
    debrief:"第三十回合的鐘聲像停戰協定。陣地前的殘骸排到地平線。灰幕的機動兵力，就折在了這裡。" },
  { n:13, title:"孤島要塞",   map:"strait",   player:"usa",     enemy:"iran",    side:0,
    brief:"（★暫用地形）三軍聯合：潛艦先斷岸防，艦隊破封鎖，LST 送陸軍上島——目標是灰幕的心臟：仿製裝備兵工廠。今天把它的爐火熄掉。",
    debrief:"兵工廠的火熄了。生產線終端還亮著最後一份圖紙的投影——落款是灰王的本名，以及一段你熟悉的軍籍編號。" },
  { n:14, title:"灰幕之後",   map:"urban",    player:"israel",  enemy:"germany", side:0,
    brief:"（夜戰）斬首行動前夜。六人小隊潛入首都圈：竊取檔案、摸清哨戒、儘量不留屍體。雷諾要求同行——他的舊部就駐在城裡，他想親口勸他們放下槍。",
    debrief:"檔案攤在桌上：灰王曾是聯軍最年輕的名將，因堅持撤僑抗命而被除名——那次撤僑救了三千人，也毀了他。雷諾的舊部有一半連夜放下了武器。" },
  { n:15, title:"黎明線",     map:"urban",    player:"usa",     enemy:"russia",  side:0,
    brief:"（★暫用地形）總攻要塞。海空壓制外環、陸軍破牆、直取指揮中樞。灰王在最後的廣播裡只說了一句：「讓我看看，正規軍還記不記得自己為何而戰。」讓他看看。",
    debrief:"槍聲停在黎明。灰王交出的不是佩槍，而是一份三千人的撤僑名單——「這是我唯一打贏過的仗。」戰爭結束了；曙光特遣隊的名字，留在了每一座收復城市的碑上。（全劇終——感謝遊玩）" }
];

/* 進度存取（localStorage）：已解鎖至第幾章（1-based） */
const StoryProgress = {
  key: "bf_story_unlocked",
  get(){ const v = parseInt(localStorage.getItem(this.key) || "1", 10); return isNaN(v) ? 1 : Math.min(Math.max(v, 1), STORY.length); },
  unlock(n){ if (n > this.get()) localStorage.setItem(this.key, String(Math.min(n, STORY.length))); },
  reset(){ localStorage.removeItem(this.key); }
};
