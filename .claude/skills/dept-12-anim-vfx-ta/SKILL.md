---
name: dept-12-anim-vfx-ta
description: 動畫、視覺特效與技術美術部：角色動作（待機/奔跑/射擊/受擊/倒地）、槍口火光爆炸煙塵特效、水彩Shader管線（賽璐璐/描邊/紙質）、骨架與掛點。改動畫、特效、渲染管線時用。
---

# 動畫、視覺特效與技術美術部

## 職責（文件第八節：動畫＋VFX＋技術美術 三合一）
- 動畫：待機、奔跑、轉向、蹲伏、掩體、射擊、換彈、受擊、倒地、救援、勝敗
- VFX：槍口火光、曳光、彈著、爆炸、煙霧、塵土、天候、據點占領演出
- 技術美術：手繪/輪廓線/紙張/水彩 Shader、批次資源檢查、骨架與武器掛點

## 主要產出
engine3d.js 渲染管線（_toonify/_renderOutline/_paperGrade）、syncFx 特效、動畫切換機。

## 水彩管線現況（技術權威）
- 賽璐璐：_toonify 三階硬色階（地面 noToon 豁免）；純色先 _linearize
- 描邊：_renderOutline 全解析度深度 RT＋硬閾值（半解析度＝糊邊事故）
- 紙質：_paperGrade（顆粒+暖罩+vignette）；迷霧＝藍灰紗柔邊（fog.js）

## 動畫鐵則（GDD/10 事故一）
骨骼由 AnimationMixer 全權驅動——**禁止每幀對骨骼 +=/\*= 疊加**；
掛件次級動作只准絕對值賦值。模型含 24 動畫（clip 名 CharacterArmature|Xxx）。

## 待做清單
蹲伏/掩體姿態、換彈演出、排線(hatching)著色、爆炸衝擊波、天候粒子（雨雪）、
擊殺特寫 slow-mo（與 dept-04 相機協作）。

## 完成定義
動畫切換無 T-pose 閃幀、骨骼 scale 300 幀穩定、特效幀時入預算、風格過 dept-02 支柱 2。
