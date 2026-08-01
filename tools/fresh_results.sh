#!/bin/bash
# fresh_results.sh — 只報「本次批次」的測試結果，不吃殘留的舊 log。
#
# 為什麼需要：logs/ 裡每章一個固定檔名，批次跑到哪一章、後面那些章就還留著
# 上一輪的內容。直接 grep 全部 log 會把舊結果混進來當成本次成績
# （2026-08-01 差點這樣誤報——舊 walk 全綠、其實本批次還沒跑到）。
#
# 用法：bash tools/fresh_results.sh [基準檔]
#   基準檔預設 logs/play_clean.log（批次的第一個產物），比它新的才算本批次。
cd "$(dirname "$0")/.."
REF="${1:-logs/play_clean.log}"
if [ ! -f "$REF" ]; then
  echo "找不到基準檔 $REF —— 先跑批次或指定基準"
  exit 1
fi
echo "基準：$REF（$(date -r "$REF" '+%m-%d %H:%M')）以後的結果才算本批次"
echo "---- play ----"
grep -hE "^\[play\] FAILS=" "$REF" 2>/dev/null || echo "(無)"
for mode in stress walk; do
  echo "---- $mode ----"
  n=0; bad=0
  for f in $(find logs -name "${mode}_ch*.log" -newer "$REF" 2>/dev/null | sort); do
    line=$(grep -hE "\[$mode\] ch[0-9]+ FAILS=" "$f")
    if [ -z "$line" ]; then
      echo "$(basename "$f") 未跑到結尾（崩潰或仍在跑）"
    else
      echo "$line"
      n=$((n+1))
      echo "$line" | grep -qE "FAILS=[1-9]" && bad=$((bad+1))
    fi
  done
  echo "$mode：本批次完成 $n 章，其中 $bad 章有 FAIL"
done
