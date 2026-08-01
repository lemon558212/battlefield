#!/bin/bash
# run_stress_all_v2.sh — 逐章測試跑批（run_stress_all.sh 的接替版）。
#
# 相對舊版修掉兩個坑：
# 1. **舊日誌污染**：每章固定檔名，批次跑到哪、後面那些章就還留著上一輪內容，
#    直接 grep 全部 log 會把舊結果當成本次成績（2026-08-01 差點誤報全綠）。
#    → 開跑時先在每個目標 log 寫入本批次 ID，總表只認帶本批次 ID 的 log。
# 2. **搶 GPU**：舊版只在註解寫「不要並行開 Godot」。生成模型也吃 GPU，
#    我曾因此把 stress ch02 撞崩。→ 開跑前呼叫 gpu_guard.sh 確認 GPU 乾淨。
#
# 用法：tools/run_stress_all_v2.sh [stress|walk] [起章] [迄章]
G="/c/Users/User/Desktop/Godot_v4.7.1-stable_win64.exe"
MODE="${1:-stress}"
FROM="${2:-1}"
TO="${3:-15}"
cd "$(dirname "$0")/.."
mkdir -p logs

BATCH_ID="BATCH-$(date +%Y%m%d-%H%M%S)"
echo "本批次 ID：$BATCH_ID"

if ! bash tools/gpu_guard.sh 2000; then
  echo "GPU 不乾淨，批次不啟動（避免測試被外部工作撞崩）"
  exit 1
fi

# 先把本批次要跑的每一章 log 標記起來：沒跑到的章節不會留著舊內容冒充
for i in $(seq "$FROM" "$TO"); do
  ch=$(printf "ch%02d" "$i")
  printf '%s PENDING\n' "$BATCH_ID" > "logs/${MODE}_${ch}.log"
done

for i in $(seq "$FROM" "$TO"); do
  ch=$(printf "ch%02d" "$i")
  echo "=== $MODE $ch  $(date +%H:%M:%S) ==="
  {
    printf '%s\n' "$BATCH_ID"
    "$G" --path godot/ -- "$MODE" "$ch" 2>&1
  } > "logs/${MODE}_${ch}.log"
  line=$(grep -E "\[(stress|walk)\] ch[0-9]+ FAILS=" "logs/${MODE}_${ch}.log")
  if [ -z "$line" ]; then
    echo "$ch 沒跑到結尾（崩潰或卡死）—— tail："
    tail -5 "logs/${MODE}_${ch}.log"
  else
    echo "$line"
  fi
done

echo "=== 總表（$MODE ch$FROM..ch$TO，只認 $BATCH_ID）==="
ok=0; bad=0; miss=0
for i in $(seq "$FROM" "$TO"); do
  ch=$(printf "ch%02d" "$i")
  f="logs/${MODE}_${ch}.log"
  head -1 "$f" | grep -q "$BATCH_ID" || { echo "$ch 不屬於本批次(檔案被外部覆寫)"; miss=$((miss+1)); continue; }
  line=$(grep -E "\[(stress|walk)\] ch[0-9]+ FAILS=" "$f")
  if [ -z "$line" ]; then echo "$ch 未完成"; miss=$((miss+1));
  elif echo "$line" | grep -qE "FAILS=[1-9]"; then echo "$line"; bad=$((bad+1));
  else echo "$line"; ok=$((ok+1)); fi
done
echo "本批次：$ok 章 0 FAIL／$bad 章有 FAIL／$miss 章未完成"
[ "$bad" -eq 0 ] && [ "$miss" -eq 0 ]
