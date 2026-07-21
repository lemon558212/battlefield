/* 17 兵種 3D 來源清單。status=approved 才算正式資產。
 * 步兵策略（2026-07-19 定案）：共用輕量動畫人形（Quaternius CC0，含 idle/walk/shoot）
 * ＋ engine3d._classGear 兵種專屬裝備差異化（狙擊長槍/機槍腳架/火箭筒…）。
 * 未來升級路線：Quaternius Ultimate Modular Men + Universal Animation Library（CC0）
 * 可組出真正的每兵種專屬模型，屆時逐兵種替換 url 並改 status。 */
"use strict";

/* 步兵九兵種＝九個不同角色模型（Quaternius Ultimate Modular Men, CC0，各含 24 動畫）。
 * lazy:true＝按需載入（該兵種首次出現才下載，避免一次載入 28MB）。 */
const MODEL_ASSETS = Object.freeze({
  rifleman: {url:"assets/models/chars/rifleman-tripo.glb", alt:"assets/models/chars/hero-rifleman.bin", b64:"js/model-data-rifleman.js", b64key:"rifleman", h:19, rotY:0, source:"Tripo image-to-3D（丁小滿立繪生成）", status:"provisional", lazy:true, selfGear:true},
  assault:  {b64:"js/model-data-assault.js", b64key:"assault", url:"assets/models/chars/assault.glb",  h:19, rotY:Math.PI/2, source:"Quaternius UMM Punk CC0", status:"approved", lazy:true},
  mg:       {url:"assets/models/chars/mg-tripo.glb", alt:"assets/models/chars/hero-mg.bin", b64:"js/model-data-mg.js", b64key:"mg", h:19, rotY:0, source:"Tripo image-to-3D（雷諾立繪生成）", status:"provisional", lazy:true, selfGear:true},
  mortar:   {b64:"js/model-data-mortar.js", b64key:"mortar", url:"assets/models/chars/mortar.glb",   h:19, rotY:Math.PI/2, source:"Quaternius UMM Suit CC0", status:"approved", lazy:true},
  sniper:   {url:"assets/models/chars/sniper-tripo3.glb", alt:"assets/models/chars/hero-sniper.bin", b64:"js/model-data-sniper.js", b64key:"sniper", h:19, rotY:0, source:"Tripo image-to-3D（韓沐霜立繪生成，20k面·noToon）", status:"provisional", lazy:true, selfGear:true},
  at:       {b64:"js/model-data-at.js", b64key:"at", url:"assets/models/chars/at.glb",       h:19, rotY:Math.PI/2, source:"Quaternius UMM Casual_2 CC0", status:"approved", lazy:true},
  engineer: {b64:"js/model-data-engineer.js", b64key:"engineer", url:"assets/models/chars/engineer.glb", h:19, rotY:Math.PI/2, source:"Quaternius UMM Worker CC0", status:"approved", lazy:true},
  specops:  {b64:"js/model-data-specops.js", b64key:"specops", url:"assets/models/chars/specops.glb",  h:19, rotY:Math.PI/2, source:"Quaternius UMM Swat CC0", status:"approved", lazy:true},
  sam:      {b64:"js/model-data-sam.js", b64key:"sam", url:"assets/models/chars/sam.glb",      h:19, rotY:Math.PI/2, source:"Quaternius UMM Spacesuit CC0", status:"approved", lazy:true},
  tank:      {b64:"js/model-data-tank.js", b64key:"tank", url:"assets/models/tank.glb", len:34, rotY:Math.PI, source:"Quaternius CC0", status:"approved"},
  destroyer: {b64:"js/model-data-destroyer.js", b64key:"destroyer", url:"assets/models/destroyer.glb", len:46, rotY:Math.PI, source:"Original project guided-missile destroyer", status:"provisional"},
  missileboat:{b64:"js/model-data-missileboat.js", b64key:"missileboat", url:"assets/models/missileboat.glb", len:32, rotY:Math.PI, source:"Original project fast missile craft", status:"provisional"},
  lst:        {b64:"js/model-data-lst.js", b64key:"lst", url:"assets/models/lst.glb", len:42, rotY:Math.PI, source:"Original project LST mesh", status:"provisional"},
  submarine: {b64:"js/model-data-submarine.js", b64key:"submarine", url:"assets/models/submarine.glb", len:34, rotY:Math.PI, source:"Original project modern attack submarine", status:"provisional"},
  fighter:   {b64:"js/model-data-fighter.js", b64key:"fighter", url:"assets/models/fighter.glb", len:34, rotY:0, source:"Original project modern fighter", status:"provisional"},
  attacker:  {b64:"js/model-data-attacker.js", b64key:"attacker", url:"assets/models/attacker.glb", len:36, rotY:0, source:"Original project twin-engine attacker", status:"provisional"},
  gunship:   {b64:"js/model-data-gunship.js", b64key:"gunship", url:"assets/models/gunship.glb", len:30, rotY:0, source:"Original project armed rotorcraft", status:"provisional"}
});
