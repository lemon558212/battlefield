#!/bin/bash
# 逐章壓力測試跑批（使用者第 5 項）。嚴格序列：同一時間只能有一個 Godot 行程，
# 兩個一起開 import 快取會打架、走查會靜默中斷（2026-07-28 教訓，見記憶檔）。
# 用法：tools/run_stress_all.sh [stress|walk] [起章] [迄章]
G="/c/Users/User/Desktop/Godot_v4.7.1-stable_win64.exe"
MODE="${1:-stress}"
FROM="${2:-1}"
TO="${3:-15}"
cd "$(dirname "$0")/.."
mkdir -p logs
for i in $(seq "$FROM" "$TO"); do
  ch=$(printf "ch%02d" "$i")
  echo "=== $MODE $ch  $(date +%H:%M:%S) ==="
  "$G" --path godot/ -- "$MODE" "$ch" > "logs/${MODE}_${ch}.log" 2>&1
  line=$(grep -E "\[(stress|walk)\] ch[0-9]+ FAILS=" "logs/${MODE}_${ch}.log")
  if [ -z "$line" ]; then
    echo "$ch 沒跑到結尾（崩潰或卡死）—— tail："
    tail -5 "logs/${MODE}_${ch}.log"
  else
    echo "$line"
  fi
done
echo "=== 總表（$MODE ch$FROM..ch$TO）==="
grep -h -E "\[(stress|walk)\] ch[0-9]+ FAILS=" logs/${MODE}_ch*.log 2>/dev/null
