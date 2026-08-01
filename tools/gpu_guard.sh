#!/bin/bash
# gpu_guard.sh — 跑任何吃 GPU 的重工作（模型生成/貼圖）之前先問這支。
#
# 為什麼需要：2026-08-01 我在全量重跑進行中跑 Hunyuan3D 生成，
# 貼圖階段把 8GB VRAM 榨乾，**連帶把批次的 stress ch02 撞崩**
# （Godot 錯誤 BLIT_PASS/UI_PASS＝顯卡裝置遺失），整章要重跑。
# 舊規矩只寫「跑批期間不可再開 Godot」，但真正的規則是
# 「跑批期間不可跑任何吃 GPU 的重工作」——靠記憶力遵守會漏，做成檢查。
#
# 用法：bash tools/gpu_guard.sh && <你的生成指令>
#   有 Godot 在跑，或 VRAM 已用超過門檻，就回傳非 0 擋下來。
FREE_MIN_MB="${1:-5000}"

if ps -W 2>/dev/null | grep -qi "Godot_v4.7"; then
  echo "[gpuguard] 擋下：有 Godot 行程在跑（測試批次進行中），不可搶 GPU"
  exit 1
fi

used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)
total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
if [ -z "$used" ]; then
  echo "[gpuguard] 讀不到 nvidia-smi，保守放行（但請自行確認沒有其他 GPU 工作）"
  exit 0
fi
free=$((total - used))
if [ "$free" -lt "$FREE_MIN_MB" ]; then
  echo "[gpuguard] 擋下：可用 VRAM ${free}MB < 需要 ${FREE_MIN_MB}MB（已用 ${used}/${total}）"
  exit 1
fi
echo "[gpuguard] 放行：無 Godot 行程，可用 VRAM ${free}MB"
exit 0
