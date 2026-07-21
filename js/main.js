/* main.js — 進入點：等 DOM 就緒後啟動 */
"use strict";
/* UI 等比縮放（2026-07-21 全視窗化配套）：--uik = 畫面實際寬/960，
 * 所有 DOM 覆層（選單/面板/角色卡/瞄準）transform:scale 跟畫面同步長大。 */
function updateUIScale(){
  const st = document.getElementById("stage");
  if (!st) return;
  const k = Math.max(0.5, st.getBoundingClientRect().width / 960);
  document.documentElement.style.setProperty("--uik", k.toFixed(4));
}
window.addEventListener("resize", updateUIScale);
window.addEventListener("orientationchange", updateUIScale);
window.addEventListener("DOMContentLoaded", ()=>{ updateUIScale(); Game.init(); });
